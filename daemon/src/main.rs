use std::env;
use std::ffi::CString;
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::io::{AsRawFd, FromRawFd};
use std::path::Path;

const SOCKET_NAME: &[u8] = b"adreno_qgl";
const QGL_TARGET: &str = "/data/vendor/gpu/qgl_config.txt";
const QGL_DIR: &str = "/data/vendor/gpu";
const QGL_DISABLED_MARKER: &str = "/data/local/tmp/.qgl_disabled";
const SELINUX_CONTEXT: &[u8] = b"u:object_r:same_process_hal_file:s0";
const XATTR_NAME: &[u8] = b"security.selinux\0";

const CONFIG_DIRS: &[&str] = &[
    "/sdcard/Adreno_Driver/Config",
    "/data/local/tmp",
];

struct Ucred {
    pid: i32,
    uid: i32,
    gid: i32,
}

fn log_msg(msg: &str) {
    let _ = writeln!(std::io::stderr(), "[adreno_qgl_daemon] {}", msg);
}

fn log_kmsg(msg: &str) {
    if let Ok(mut f) = fs::OpenOptions::new().write(true).open("/dev/kmsg") {
        let _ = write!(f, "[ADRENO-QGL-DAEMON] {}\n", msg);
    }
}

fn set_selinux_context(path: &str, context: &[u8]) -> std::io::Result<()> {
    let path_c = CString::new(path).map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidInput, e))?;
    let xattr_c = unsafe { XATTR_NAME.as_ptr() as *const libc::c_char };
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
    uid >= 10000 && uid <= 19999
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
    let addr_len = 1 + 1 + name_len;

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
        .and_then(|m| m.modified().map(|t| t.duration_since(std::time::UNIX_EPOCH).unwrap_or_default()).map(|d| d.as_secs()))
        .unwrap_or(0)
}

fn grep_line(path: &str, needle: &str) -> bool {
    if let Ok(f) = fs::File::open(path) {
        let reader = BufReader::new(f);
        for line in reader.lines() {
            if let Ok(l) = line {
                if l == needle {
                    return true;
                }
            }
        }
    }
    false
}

fn find_config(pkg: &str) -> Option<(String, u64, bool)> {
    for dir in CONFIG_DIRS {
        let perapp = format!("{}/qgl_config.txt.{}", dir, pkg);
        if file_exists(&perapp) && file_is_nonempty(&perapp) {
            return Some((perapp, file_mtime(&perapp), true));
        }
    }

    for dir in CONFIG_DIRS {
        let default_cfg = format!("{}/qgl_config.txt", dir);
        if file_exists(&default_cfg) && file_is_nonempty(&default_cfg) {
            return Some((default_cfg, file_mtime(&default_cfg), false));
        }
    }

    if let Ok(moddir) = env::var("ADRENO_MODDIR") {
        let default_cfg = format!("{}/qgl_config.txt", moddir);
        if file_exists(&default_cfg) && file_is_nonempty(&default_cfg) {
            return Some((default_cfg, file_mtime(&default_cfg), false));
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

fn atomic_apply(src: &str, dst: &str) -> String {
    let tmp = format!("{}.tmp.{}", dst, std::process::id());

    if let Err(e) = fs::create_dir_all(QGL_DIR) {
        let _ = set_selinux_context(QGL_DIR, SELINUX_CONTEXT);
        let _ = log_kmsg(&format!("mkdir {} failed: {}, trying chcon+continue", QGL_DIR, e));
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

    if let Err(e) = fs::rename(&tmp, dst) {
        let _ = fs::remove_file(&tmp);
        return format!("FAIL:mv:{}", e);
    }

    let _ = set_selinux_context(dst, SELINUX_CONTEXT);
    let _ = fs::set_permissions(dst, fs::Permissions::from_mode(0o644));

    let mtime = file_mtime(src);
    format!("APPLIED:{}:{}", src, mtime)
}

fn remove_qgl() -> String {
    if !file_exists(QGL_TARGET) {
        return "SAME".to_string();
    }
    match fs::remove_file(QGL_TARGET) {
        Ok(_) => "REMOVED:DELETED".to_string(),
        Err(_) => {
            match fs::File::create(QGL_TARGET) {
                Ok(_) => "REMOVED:TRUNCATED".to_string(),
                Err(e) => format!("FAIL:rm:{}", e),
            }
        }
    }
}

fn handle_switch(pkg: &str, sys_flag: i32, last_applied: &str) -> String {
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

fn handle_client(stream: std::os::unix::net::UnixStream) {
    let fd = stream.as_raw_fd();
    if let Some(cred) = get_peer_cred(fd) {
        if !is_app_uid(cred.uid) {
            log_msg(&format!("rejecting connection from uid={} (not app range)", cred.uid));
            return;
        }
    } else {
        log_msg("failed to get peer credentials, rejecting");
        return;
    }

    let writer = match stream.try_clone() {
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
                        let last_applied = if parts.len() > 3 { parts[3] } else { "" };
                        handle_switch(pkg, sys_flag, last_applied)
                    }
                } else if l.starts_with("READ_QGL_SYSTEM_APPS") {
                    let mut result = "n".to_string();
                    for dir in CONFIG_DIRS {
                        let cfg = format!("{}/adreno_config.txt", dir);
                        if file_exists(&cfg) && grep_line(&cfg, "QGL_SYSTEM_APPS=y") {
                            result = "y".to_string();
                            break;
                        }
                    }
                    if let Ok(moddir) = env::var("ADRENO_MODDIR") {
                        let cfg = format!("{}/adreno_config.txt", moddir);
                        if result != "y" && file_exists(&cfg) && grep_line(&cfg, "QGL_SYSTEM_APPS=y") {
                            result = "y".to_string();
                        }
                    }
                    format!("QGL_SYSTEM_APPS={}", result)
                } else {
                    "FAIL:unknown_command".to_string()
                };

                let _ = writeln!(&writer, "{}", response);
                let _ = writer.flush();
            }
            Err(_) => break,
        }
    }
}

fn setup_signal_handler() {
    unsafe {
        libc::signal(libc::SIGTERM, libc::SIG_DFL);
        libc::signal(libc::SIGPIPE, libc::SIG_IGN);
    }
}

fn main() {
    setup_signal_handler();

    let moddir = env::var("ADRENO_MODDIR").unwrap_or_else(|_| "/data/adb/modules/adreno_gpu_driver_unified".to_string());
    if env::var("ADRENO_MODDIR").is_err() {
        env::set_var("ADRENO_MODDIR", &moddir);
    }

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

    log_msg(&format!("listening on abstract socket \\0{}", std::str::from_utf8(SOCKET_NAME).unwrap_or("?")));
    log_kmsg("daemon listening on abstract socket");

    let listener = unsafe { std::os::unix::net::UnixListener::from_raw_fd(fd) };

    for stream in listener.incoming() {
        match stream {
            Ok(stream) => {
                handle_client(stream);
            }
            Err(e) => {
                log_msg(&format!("accept error: {}", e));
            }
        }
    }
}
