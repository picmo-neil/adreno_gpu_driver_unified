use std::collections::HashSet;
use std::env;
use std::ffi::CString;
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::io::{AsRawFd, FromRawFd};
use std::path::Path;
use std::sync::{mpsc, Arc, Mutex, OnceLock};

const SOCKET_NAME: &[u8] = b"adreno_qgl";
const QGL_TARGET: &str = "/data/vendor/gpu/qgl_config.txt";
const QGL_DIR: &str = "/data/vendor/gpu";
const QGL_DISABLED_MARKER: &str = "/data/local/tmp/.qgl_disabled";
const SELINUX_CONTEXT: &[u8] = b"u:object_r:same_process_hal_file:s0";
const XATTR_NAME: &[u8] = b"security.selinux\0";
const SYSTEM_PKGS_PATH: &str = "/data/local/tmp/qgl_system_packages.txt";
const DEBOUNCE_MS: u64 = 300;

const CONFIG_DIRS: &[&str] = &[
    "/sdcard/Adreno_Driver/Config",
    "/data/local/tmp",
];

static MODDIR: OnceLock<String> = OnceLock::new();

struct Ucred {
    pid: i32,
    uid: i32,
    gid: i32,
}

struct DaemonState {
    last_pkg: String,
    last_applied: String,
    last_switch_ms: u64,
    system_packages: HashSet<String>,
    qgl_system_apps: bool,
    apk_connected: bool,
}

impl DaemonState {
    fn new() -> Self {
        let system_packages = load_system_packages();
        let qgl_system_apps = read_qgl_system_apps_flag();
        log_kmsg(&format!(
            "daemon state: {} system packages, QGL_SYSTEM_APPS={}",
            system_packages.len(),
            qgl_system_apps
        ));
        Self {
            last_pkg: String::new(),
            last_applied: String::new(),
            last_switch_ms: 0,
            system_packages,
            qgl_system_apps,
            apk_connected: false,
        }
    }

    fn is_system_app(&self, pkg: &str) -> bool {
        self.system_packages.contains(pkg)
    }
}

fn log_msg(msg: &str) {
    let _ = writeln!(std::io::stderr(), "[adreno_qgl_daemon] {}", msg);
}

fn log_kmsg(msg: &str) {
    if let Ok(mut f) = fs::OpenOptions::new().write(true).open("/dev/kmsg") {
        let _ = write!(f, "[ADRENO-QGL-DAEMON] {}\n", msg);
    }
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

fn set_selinux_context(path: &str, context: &[u8]) -> std::io::Result<()> {
    let path_c = CString::new(path)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidInput, e))?;
    let xattr_c = XATTR_NAME.as_ptr() as *const libc::c_char;
    let ctx_with_null: Vec<u8> = context.iter().chain(&[0]).copied().collect();
    let ret = unsafe {
        libc::setxattr(
            path_c.as_ptr(),
            xattr_c,
            ctx_with_null.as_ptr() as *const libc::c_void,
            ctx_with_null.len(),
            0,
        )
    };
    if ret != 0 {
        Err(std::io::Error::last_os_error())
    } else {
        Ok(())
    }
}

fn get_peer_cred(fd: i32) -> Option<Ucred> {
    let mut ucred: libc::ucred = unsafe { std::mem::zeroed() };
    let mut len = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
    let ret = unsafe {
        libc::getsockopt(
            fd,
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            &mut ucred as *mut _ as *mut libc::c_void,
            &mut len,
        )
    };
    if ret == 0 {
        Some(Ucred {
            pid: ucred.pid,
            uid: ucred.uid as i32,
            gid: ucred.gid as i32,
        })
    } else {
        None
    }
}

fn is_app_uid(uid: i32) -> bool {
    let app_id = uid % 100_000;
    app_id >= 10000 && app_id <= 19999
}

fn bind_abstract_socket(name: &[u8]) -> std::io::Result<i32> {
    let fd = unsafe { libc::socket(libc::AF_UNIX, libc::SOCK_STREAM, 0) };
    if fd < 0 {
        return Err(std::io::Error::last_os_error());
    }

    let mut addr: libc::sockaddr_un = unsafe { std::mem::zeroed() };
    addr.sun_family = libc::AF_UNIX as libc::sa_family_t;
    addr.sun_path[0] = 0;
    let name_len = name.len().min(addr.sun_path.len() - 1);
    addr.sun_path[1..1 + name_len].copy_from_slice(&name[..name_len]);
    let addr_len = std::mem::size_of::<libc::sa_family_t>() + 1 + name_len;

    let ret = unsafe {
        libc::bind(
            fd,
            &addr as *const _ as *const libc::sockaddr,
            addr_len as libc::socklen_t,
        )
    };
    if ret != 0 {
        let err = std::io::Error::last_os_error();
        unsafe { libc::close(fd) };
        return Err(err);
    }

    let ret = unsafe { libc::listen(fd, 4) };
    if ret != 0 {
        let err = std::io::Error::last_os_error();
        unsafe { libc::close(fd) };
        return Err(err);
    }

    Ok(fd)
}

fn file_exists(path: &str) -> bool {
    Path::new(path).exists()
}

fn file_is_nonempty(path: &str) -> bool {
    match fs::metadata(path) {
        Ok(m) => m.len() > 0,
        Err(_) => false,
    }
}

fn file_mtime(path: &str) -> u64 {
    fs::metadata(path)
        .and_then(|m| {
            m.modified()
                .map(|t| t.duration_since(std::time::UNIX_EPOCH).unwrap_or_default())
                .map(|d| d.as_secs())
        })
        .unwrap_or(0)
}

fn grep_line(path: &str, needle: &str) -> bool {
    if let Ok(f) = fs::File::open(path) {
        let reader = BufReader::new(f);
        for line in reader.lines() {
            if let Ok(l) = line {
                let trimmed = l.trim_end_matches(|c| c == '\r' || c == '\n' || c == ' ');
                if trimmed == needle {
                    return true;
                }
            }
        }
    }
    false
}

fn get_moddir() -> &'static str {
    MODDIR.get().map(|s| s.as_str()).unwrap_or("")
}

fn find_config(pkg: &str) -> Option<(String, u64, bool)> {
    for dir in CONFIG_DIRS {
        let perapp = format!("{}/qgl_config.txt.{}", dir, pkg);
        if file_exists(&perapp) && file_is_nonempty(&perapp) {
            return Some((perapp.clone(), file_mtime(&perapp), true));
        }
    }

    for dir in CONFIG_DIRS {
        let default_cfg = format!("{}/qgl_config.txt", dir);
        if file_exists(&default_cfg) && file_is_nonempty(&default_cfg) {
            return Some((default_cfg.clone(), file_mtime(&default_cfg), false));
        }
    }

    let moddir = get_moddir();
    if !moddir.is_empty() {
        let default_cfg = format!("{}/qgl_config.txt", moddir);
        if file_exists(&default_cfg) && file_is_nonempty(&default_cfg) {
            return Some((default_cfg.clone(), file_mtime(&default_cfg), false));
        }
    }

    None
}

fn is_noqgl(pkg: &str) -> bool {
    for dir in CONFIG_DIRS {
        let f = format!("{}/no_qgl_packages.txt", dir);
        if file_exists(&f) && grep_line(&f, pkg) {
            return true;
        }
    }
    false
}

fn load_system_packages() -> HashSet<String> {
    let mut set = HashSet::new();
    if let Ok(f) = fs::File::open(SYSTEM_PKGS_PATH) {
        let reader = BufReader::new(f);
        for line in reader.lines() {
            if let Ok(l) = line {
                let trimmed = l.trim();
                if !trimmed.is_empty() && trimmed.contains('.') {
                    set.insert(trimmed.to_string());
                }
            }
        }
    }
    set
}

fn read_qgl_system_apps_flag() -> bool {
    let moddir = get_moddir();
    for dir in CONFIG_DIRS {
        let cfg = format!("{}/adreno_config.txt", dir);
        if file_exists(&cfg) && grep_line(&cfg, "QGL_SYSTEM_APPS=y") {
            return true;
        }
    }
    if !moddir.is_empty() {
        let cfg = format!("{}/adreno_config.txt", moddir);
        if file_exists(&cfg) && grep_line(&cfg, "QGL_SYSTEM_APPS=y") {
            return true;
        }
    }
    false
}

fn atomic_apply(src: &str, dst: &str) -> String {
    let tid = format!("{:?}", std::thread::current().id());
    let tmp = format!("{}.tmp.{}", dst, tid);

    if let Err(e) = fs::create_dir_all(QGL_DIR) {
        let _ = set_selinux_context(QGL_DIR, SELINUX_CONTEXT);
        let _ = log_kmsg(&format!(
            "mkdir {} failed: {}, trying chcon+continue",
            QGL_DIR, e
        ));
    }
    let _ = set_selinux_context(QGL_DIR, SELINUX_CONTEXT);

    if let Err(e) = fs::copy(src, &tmp) {
        let _ = fs::remove_file(&tmp);
        return format!("FAIL:cp:{}", e);
    }

    if let Err(e) = set_selinux_context(&tmp, SELINUX_CONTEXT) {
        let _ = fs::remove_file(&tmp);
        return format!("FAIL:chcon_tmp:{}", e);
    }

    if let Err(e) = fs::set_permissions(&tmp, fs::Permissions::from_mode(0o644)) {
        let _ = fs::remove_file(&tmp);
        return format!("FAIL:chmod_tmp:{}", e);
    }

    // fsync temp file before rename for crash consistency
    let tmp_fd = unsafe { libc::open(tmp.as_ptr(), libc::O_RDONLY) };
    if tmp_fd >= 0 {
        unsafe { libc::fsync(tmp_fd) };
        unsafe { libc::close(tmp_fd) };
    }

    if let Err(e) = fs::rename(&tmp, dst) {
        let _ = fs::remove_file(&tmp);
        return format!("FAIL:mv:{}", e);
    }

    // fsync parent directory after rename for durability
    let dir_fd = unsafe { libc::open(QGL_DIR.as_ptr(), libc::O_RDONLY | libc::O_DIRECTORY) };
    if dir_fd >= 0 {
        unsafe { libc::fsync(dir_fd) };
        unsafe { libc::close(dir_fd) };
    }

    let mtime = file_mtime(src);
    format!("APPLIED:{}:{}", src, mtime)
}

fn remove_qgl() -> String {
    if !file_exists(QGL_TARGET) {
        return "SAME".to_string();
    }
    match fs::remove_file(QGL_TARGET) {
        Ok(_) => "REMOVED:DELETED".to_string(),
        Err(_) => match fs::File::create(QGL_TARGET) {
            Ok(_) => {
                let _ = set_selinux_context(QGL_TARGET, SELINUX_CONTEXT);
                let _ = fs::set_permissions(QGL_TARGET, fs::Permissions::from_mode(0o644));
                "REMOVED:TRUNCATED".to_string()
            }
            Err(e) => format!("FAIL:rm:{}", e),
        },
    }
}

fn is_valid_package_name(pkg: &str) -> bool {
    if pkg.is_empty() || pkg.len() > 255 {
        return false;
    }
    if pkg.contains('/') || pkg.contains('\\') || pkg.contains("..") {
        return false;
    }
    pkg.chars().all(|c| c.is_alphanumeric() || c == '.' || c == '_')
}

fn handle_switch(pkg: &str, sys_flag: i32, last_applied: &str) -> String {
    if !is_valid_package_name(pkg) {
        return format!("FAIL:invalid_package:{}", pkg);
    }
    if file_exists(QGL_DISABLED_MARKER) {
        if last_applied == "NO_QGL" {
            return "SAME".to_string();
        }
        return remove_qgl().replace("REMOVED", "REMOVED:DISABLED");
    }

    if is_noqgl(pkg) {
        if last_applied == "NO_QGL" {
            return "SAME".to_string();
        }
        return remove_qgl().replace("REMOVED", "REMOVED:NOQGL");
    }

    match find_config(pkg) {
        Some((src, mtime, is_perapp)) => {
            if sys_flag == 1 && !is_perapp {
                if last_applied == "NO_QGL" {
                    return "SAME".to_string();
                }
                return remove_qgl().replace("REMOVED", "REMOVED:SYS_DEFAULT");
            }

            let hash = format!("{}:{}", src, mtime);
            if hash == last_applied {
                return format!("SAME:{}", hash);
            }

            atomic_apply(&src, QGL_TARGET)
        }
        None => {
            if last_applied != "NO_QGL" {
                remove_qgl().replace("REMOVED", "REMOVED:NO_CONFIG")
            } else {
                "SAME".to_string()
            }
        }
    }
}

fn update_state_from_result(state: &mut DaemonState, pkg: &str, result: &str) {
    state.last_pkg = pkg.to_string();
    state.last_switch_ms = now_ms();
    if result.starts_with("APPLIED:") {
        state.last_applied = result[8..].to_string();
    } else if result.starts_with("REMOVED:") {
        state.last_applied = "NO_QGL".to_string();
    } else if result.starts_with("SAME:") {
        // keep last_applied unchanged
    } else if result.starts_with("FAIL:") {
        state.last_applied = String::new();
    }
    write_daemon_state(state);
}

fn write_daemon_state(state: &DaemonState) {
    let mode = if state.apk_connected {
        "apk"
    } else {
        "logcat"
    };
    let qgl_status = if state.last_applied.is_empty() {
        "error"
    } else if state.last_applied == "NO_QGL" {
        "none"
    } else {
        "active"
    };
    let qgl_config = if Path::new("/data/vendor/gpu/qgl_config.txt").exists() {
        "present"
    } else {
        "absent"
    };
    let content = format!(
        "daemon=running\nmode={}\nlast_pkg={}\nqgl_status={}\nqgl_hash={}\nqgl_config_file={}\nts={}\n",
        mode,
        state.last_pkg,
        qgl_status,
        state.last_applied,
        qgl_config,
        state.last_switch_ms,
    );
    let tmp = "/data/local/tmp/qgl_daemon_state.txt";
    let tmp_new = format!("{}.tmp", tmp);
    if let Ok(mut f) = fs::File::create(&tmp_new) {
        if f.write_all(content.as_bytes()).is_ok() {
            let _ = f.sync_all();
            let _ = fs::rename(&tmp_new, tmp);
        } else {
            let _ = fs::remove_file(&tmp_new);
        }
    }
}

fn handle_client(stream: std::os::unix::net::UnixStream, daemon_state: Arc<Mutex<DaemonState>>) {
    let fd = stream.as_raw_fd();
    if let Some(cred) = get_peer_cred(fd) {
        if !is_app_uid(cred.uid) {
            log_msg(&format!(
                "rejecting connection from uid={} (not app range)",
                cred.uid
            ));
            return;
        }
    } else {
        log_msg("failed to get peer credentials, rejecting");
        return;
    }

    {
        let mut st = match daemon_state.lock() {
            Ok(s) => s,
            Err(e) => {
                log_msg(&format!("state lock poisoned: {}, recovering", e));
                e.into_inner()
            }
        };
        st.apk_connected = true;
        log_msg("APK client connected — logcat fallback disabled");
        write_daemon_state(&st);
    }

    let mut writer = match stream.try_clone() {
        Ok(w) => w,
        Err(e) => {
            log_msg(&format!("failed to clone stream for writing: {}", e));
            return;
        }
    };

    let reader = BufReader::new(stream);

    for line in reader.lines() {
        match line {
            Ok(l) => {
                let response = if l == "PING" {
                    "PONG".to_string()
                } else if l.starts_with("SWITCH ") {
                    let parts: Vec<&str> = l.splitn(4, ' ').collect();
                    if parts.len() < 3 {
                        "FAIL:bad_request".to_string()
                    } else {
                        let pkg = parts[1];
                        let sys_flag: i32 = parts[2].parse().unwrap_or(0);
                        let last_applied = if parts.len() > 3 {
                            parts[3]
                        } else {
                            ""
                        };
                        let result = handle_switch(pkg, sys_flag, last_applied);
                        {
                            let mut st = match daemon_state.lock() {
                                Ok(s) => s,
                                Err(e) => {
                                    log_msg(&format!("state lock poisoned: {}, recovering", e));
                                    e.into_inner()
                                }
                            };
                            update_state_from_result(&mut st, pkg, &result);
                        }
                        result
                    }
                } else if l.starts_with("READ_QGL_SYSTEM_APPS") {
                    let st = match daemon_state.lock() {
                    Ok(s) => s,
                    Err(e) => e.into_inner(),
                };
                format!("QGL_SYSTEM_APPS={}", if st.qgl_system_apps { "y" } else { "n" })
                } else {
                    "FAIL:unknown_command".to_string()
                };

                let _ = writeln!(&writer, "{}", response);
                let _ = writer.flush();
            }
            Err(_) => break,
        }
    }

    {
        let mut st = match daemon_state.lock() {
            Ok(s) => s,
            Err(e) => {
                log_msg(&format!("state lock poisoned on disconnect: {}", e));
                e.into_inner()
            }
        };
        st.apk_connected = false;
        log_msg("APK client disconnected — logcat fallback enabled");
        write_daemon_state(&st);
    }
}

// ── Autonomous app switch detection ─────────────────────────────────────

fn parse_am_focused_app(line: &str) -> Option<String> {
    let line = line.trim();
    let start = line.find('[')?;
    let end = line.rfind(']')?;
    if end <= start {
        return None;
    }
    let inner = &line[start + 1..end];
    let parts: Vec<&str> = inner.splitn(3, ',').collect();
    let pkg = if parts.len() >= 2 {
        parts[1].trim()
    } else {
        parts[0].trim()
    };
    if pkg.contains('.') && pkg.len() >= 5 && !pkg.is_empty() {
        Some(pkg.to_string())
    } else {
        None
    }
}

fn spawn_logcat_watcher(tx: mpsc::Sender<String>) {
    std::thread::Builder::new()
        .name("qgl-logcat-watcher".to_string())
        .spawn(move || {
            log_msg("logcat watcher thread starting");
            log_kmsg("logcat watcher starting");
            loop {
                let child = std::process::Command::new("logcat")
                    .args(&[
                        "-b",
                        "events",
                        "-v",
                        "brief",
                        "am_focused_activity",
                    ])
                    .stdout(std::process::Stdio::piped())
                    .stderr(std::process::Stdio::null())
                    .spawn();

                match child {
                    Ok(mut c) => {
                        if let Some(stdout) = c.stdout.take() {
                            let reader = BufReader::new(stdout);
                            for line in reader.lines() {
                                match line {
                                    Ok(l) => {
                                        if let Some(pkg) = parse_am_focused_app(&l) {
                                            log_msg(&format!("logcat: fg={}", pkg));
                                            let _ = tx.send(pkg);
                                        }
                                    }
                                    Err(_) => break,
                                }
                            }
                        }
                        let _ = c.wait();
                        log_msg("logcat watcher exited, restarting in 2s");
                        log_kmsg("logcat watcher exited, restarting");
                    }
                    Err(e) => {
                        log_msg(&format!("logcat spawn failed: {}", e));
                        log_kmsg(&format!("logcat spawn failed: {}", e));
                    }
                }
                std::thread::sleep(std::time::Duration::from_secs(2));
            }
        })
        .expect("failed to spawn logcat watcher");
}

fn spawn_autonomous_switch_handler(rx: mpsc::Receiver<String>, daemon_state: Arc<Mutex<DaemonState>>) {
    std::thread::Builder::new()
        .name("qgl-switch-handler".to_string())
        .spawn(move || {
            log_msg("autonomous switch handler starting");
            log_kmsg("autonomous switch handler starting");

            for pkg in rx {
                let now = now_ms();
                let should_skip = {
                    let state = match daemon_state.lock() {
                        Ok(s) => s,
                        Err(e) => e.into_inner(),
                    };
                    if state.apk_connected {
                        continue;
                    }
                    state.last_pkg == pkg && (now - state.last_switch_ms) < DEBOUNCE_MS
                };
                if should_skip {
                    continue;
                }

                let (sys_flag, last_applied) = {
                    let state = match daemon_state.lock() {
                        Ok(s) => s,
                        Err(e) => e.into_inner(),
                    };
                    let is_system = !state.qgl_system_apps && state.is_system_app(&pkg);
                    let sys_flag = if is_system { 1 } else { 0 };
                    (sys_flag, state.last_applied.clone())
                };

                let result = handle_switch(&pkg, sys_flag, &last_applied);
                log_msg(&format!(
                    "auto-switch: pkg={} sys={} result={}",
                    pkg, sys_flag, result
                ));
                log_kmsg(&format!("auto-switch: {}={}", pkg, &result[..result.len().min(60)]));

                {
                    let mut state = match daemon_state.lock() {
                        Ok(s) => s,
                        Err(e) => e.into_inner(),
                    };
                    update_state_from_result(&mut state, &pkg, &result);
                }
            }
        })
        .expect("failed to spawn autonomous switch handler");
}

fn setup_signal_handler() {
    unsafe {
        libc::signal(libc::SIGTERM, libc::SIG_DFL);
        libc::signal(libc::SIGPIPE, libc::SIG_IGN);
    }
}

fn set_oom_protection() {
    let oom_path = "/proc/self/oom_score_adj";
    if let Ok(mut f) = fs::File::create(oom_path) {
        use std::io::Write;
        let _ = writeln!(f, "-1000");
        log_msg("OOM protection enabled: oom_score_adj=-1000");
    }
}

fn main() {
    setup_signal_handler();
    set_oom_protection();

    let moddir = env::var("ADRENO_MODDIR")
        .unwrap_or_else(|_| "/data/adb/modules/adreno_gpu_driver_unified".to_string());
    MODDIR.set(moddir.clone()).ok();

    log_msg(&format!("starting (moddir={})", moddir));
    log_kmsg("daemon starting");

    let fd = match bind_abstract_socket(SOCKET_NAME) {
        Ok(fd) => fd,
        Err(e) => {
            log_msg(&format!("FATAL: bind abstract socket failed: {}", e));
            log_kmsg(&format!("FATAL: bind failed: {}", e));
            std::process::exit(1);
        }
    };

    log_msg(&format!(
        "listening on abstract socket \\0{}",
        std::str::from_utf8(SOCKET_NAME).unwrap_or("?")
    ));
    log_kmsg("daemon listening on abstract socket");

    let mirror_done = "/data/local/tmp/.qgl_mirror_done";
    let mut waited = 0;
    while !Path::new(mirror_done).exists() && waited < 30 {
        std::thread::sleep(std::time::Duration::from_secs(1));
        waited += 1;
    }
    if waited > 0 {
        log_msg(&format!("waited {}s for {}", waited, mirror_done));
        log_kmsg(&format!("waited {}s for mirror_done", waited));
    }

    // Clean up stale tmp files from previous daemon crash
    if let Ok(entries) = fs::read_dir(QGL_DIR) {
        for entry in entries.flatten() {
            let name = entry.file_name();
            let name_str = name.to_string_lossy();
            if name_str.starts_with("qgl_config.txt.tmp.") {
                let _ = fs::remove_file(entry.path());
            }
        }
    }

    let daemon_state: Arc<Mutex<DaemonState>> = Arc::new(Mutex::new(DaemonState::new()));
    {
        let st = match daemon_state.lock() {
            Ok(s) => s,
            Err(e) => e.into_inner(),
        };
        write_daemon_state(&st);
    }

    let (tx, rx) = mpsc::channel::<String>();
    spawn_logcat_watcher(tx);
    spawn_autonomous_switch_handler(rx, Arc::clone(&daemon_state));

    let listener = unsafe { std::os::unix::net::UnixListener::from_raw_fd(fd) };

    for stream in listener.incoming() {
        match stream {
            Ok(stream) => {
                let state = Arc::clone(&daemon_state);
                std::thread::spawn(move || handle_client(stream, state));
            }
            Err(e) => {
                log_msg(&format!("accept error: {}", e));
            }
        }
    }
}
