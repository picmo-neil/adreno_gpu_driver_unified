/*
 * ============================================================
 * ADRENO DRIVER MODULE — GAME EXCLUSION DAEMON (NATIVE)
 * ============================================================
 *
 * PURPOSE:
 *   Prevents dual-VkDevice crashes when native-Vulkan games run under
 *   skiavk/skiavk_all. Switches debug.hwui.renderer to skiagl when an
 *   excluded game launches; restores when all excluded games have exited.
 *
 * HOW ANDROID ACTUALLY LAUNCHES APPS (critical to get right):
 *
 *   Every Android app process is born from zygote via fork(), NOT exec().
 *   The sequence is:
 *     1. zygote calls fork()
 *        PROC_EVENT_FORK fires  → child_pid known, but cmdline = "zygote64"
 *     2. Child calls SpecializeAppProcess(), which calls:
 *        prctl(PR_SET_NAME, "com.tencent.ig")
 *        PROC_EVENT_COMM fires  → comm = truncated name (≤16 chars)
 *        /proc/<pid>/cmdline is now set to the real package name
 *     3. ART starts running the app
 *        PROC_EVENT_EXEC: NEVER fires (no execve in normal app launch)
 *
 *   This means PROC_EVENT_EXEC is WRONG for Android app detection.
 *   Both our previous version and a naive port would silently miss every
 *   game launch. The correct events are FORK + COMM.
 *
 * ARCHITECTURE:
 *
 *   LAUNCH DETECTION — Netlink Connector PROC_EVENT_FORK + PROC_EVENT_COMM:
 *
 *     On PROC_EVENT_FORK: if parent is zygote64 (or zygote32), record the
 *     child PID in a pending table. We know an app is being born but we
 *     don't know which one yet.
 *
 *     On PROC_EVENT_COMM: look up the PID in the pending table. The comm
 *     field is ≤16 chars (kernel limit), so we can't match long package
 *     names directly. Instead we use it as a cheap pre-filter: if the
 *     comm starts with a known prefix ("com.", "org.", etc.) we read
 *     the full /proc/<pid>/cmdline and do the real fnmatch check.
 *     Non-app processes (kernel threads, daemons) are rejected instantly.
 *
 *     Between events: recvfrom() blocks in TASK_INTERRUPTIBLE. Zero CPU.
 *
 *   DEATH DETECTION — pidfd_open + epoll (kernel 5.3+ / Android 12+):
 *     pidfd fd becomes readable exactly when the process exits. Zero CPU.
 *     PROC_EVENT_EXIT also handled as belt-and-suspenders fallback.
 *     Falls back to 1s /proc stat poll on older kernels automatically.
 *
 *   ZYGOTE TRACKING:
 *     We find zygote64/zygote32 PIDs at startup by scanning /proc once.
 *     We refresh them on PROC_EVENT_FORK from PID 1 (init respawns zygote
 *     after a crash). This means we survive zygote restarts.
 *
 *   PENDING TABLE:
 *     Small fixed array mapping child_pid → entry. Entries time out after
 *     5 seconds (cleaned up on each COMM event) to prevent unbounded growth
 *     from non-app forks (kernel workers, etc.).
 *
 *   SIGNAL HANDLING — signalfd + epoll:
 *     SIGTERM/SIGINT/SIGHUP in the same epoll. No async-signal-safety issues.
 *     SIGHUP reloads the exclusion list live.
 *
 *   FALLBACK — /proc polling (1s):
 *     If netlink bind fails (CONFIG_PROC_EVENTS=n, extremely rare on Android),
 *     the daemon falls back to scanning /proc every second. Inferior but
 *     functional on all kernels.
 *
 * STATE FILES:
 *   /data/local/tmp/adreno_ged_pid    — our PID (duplicate instance guard)
 *   /data/local/tmp/adreno_ged_active — "1" game running, "0" idle
 *
 * USAGE:
 *   adreno_ged <skiavk|skiavk_all> [MODDIR]
 *
 * KERNEL REQUIREMENTS:
 *   Netlink connector: Linux 2.6.15+ (all Android kernels)
 *   pidfd_open:        Linux 5.3+   (Android 12+); falls back to /proc poll
 *   epoll + signalfd:  Linux 2.6.27+ (all Android kernels)
 *   NDK headers:       cn_proc.h available since API 26 (Android 8)
 * ============================================================
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <fnmatch.h>
#include <dirent.h>
#include <ctype.h>
#include <stdarg.h>
#include <time.h>

#include <sys/epoll.h>
#include <sys/signalfd.h>
#include <sys/syscall.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <sys/socket.h>

#include <linux/netlink.h>
#include <linux/connector.h>
#include <linux/cn_proc.h>

/* ── pidfd_open syscall (not in all bionic versions) ─────────────────────── */
#ifndef __NR_pidfd_open
#  define __NR_pidfd_open 434   /* arm64, arm, x86_64, x86 all use 434 */
#endif

static inline int sys_pidfd_open(pid_t pid, unsigned int flags) {
    return (int)syscall(__NR_pidfd_open, (long)pid, (long)(unsigned long)flags);
}

/* ── Constants ───────────────────────────────────────────────────────────── */
#define MAX_PKGS         128
#define MAX_PKG_LEN      256
#define MAX_ACTIVE       64       /* max simultaneously tracked games */
#define MAX_PENDING      128      /* max pending fork→comm resolutions */
#define MAX_EPOLL_EVENTS 32
#define NL_BUF_SIZE      8192
#define PENDING_TIMEOUT_S 5       /* drop pending entry after 5 seconds */

#define PID_FILE    "/data/local/tmp/adreno_ged_pid"
#define STATE_FILE  "/data/local/tmp/adreno_ged_active"
#define KMSG        "/dev/kmsg"

/* ── Package list ────────────────────────────────────────────────────────── */
static char g_pkgs[MAX_PKGS][MAX_PKG_LEN];
static int  g_npkgs = 0;

static const char *LIST_PATHS[] = {
    "/sdcard/Adreno_Driver/Config/game_exclusion_list.sh",
    "/data/local/tmp/adreno_game_exclusion_list.sh",
    NULL   /* MODDIR path filled at runtime */
};

static const char *DEFAULT_PKGS[] = {
    "com.tencent.ig",        /* PUBG Mobile */
    "com.pubg.krmobile",
    "com.pubg.imobile",
    "com.vng.pubgmobile",
    "com.rekoo.pubgm",
    "com.tencent.tmgp.pubgmhd",
    "com.epicgames.*",       /* Fortnite + all Epic titles */
    "com.activision.callofduty.shooter",
    "com.garena.game.codm",
    "com.tencent.tmgp.cod",
    "com.vng.codmvn",
    "com.miHoYo.GenshinImpact",
    "com.cognosphere.GenshinImpact",
    "com.miHoYo.enterprise.HSRPrism",
    "com.HoYoverse.hkrpgoversea",
    "com.levelinfinite.hotta",
    "com.proximabeta.mfh",
    "com.HoYoverse.Nap",
    "com.miHoYo.ZZZ",
    "com.facebook.katana",   /* Facebook — UBWC green-line group */
    "com.facebook.orca",
    "com.facebook.lite",
    "com.facebook.mlite",
    "com.instagram.android",
    "com.instagram.lite",
    "com.whatsapp",
    "com.whatsapp.w4b",
    NULL
};

/* ── Zygote PIDs ─────────────────────────────────────────────────────────── */
#define MAX_ZYGOTES 4
static pid_t g_zygote_pids[MAX_ZYGOTES];
static int   g_nzygotes = 0;

/* ── Pending fork table: child_pid born from zygote, waiting for COMM ────── */
typedef struct {
    pid_t    pid;
    time_t   born;    /* time_t of fork event, for timeout eviction */
} Pending;

static Pending g_pending[MAX_PENDING];
static int     g_npending = 0;

/* ── Active game tracking ────────────────────────────────────────────────── */
typedef struct {
    int   pidfd;
    pid_t pid;
    char  pkg[MAX_PKG_LEN];
    int   use_poll;
} ActiveGame;

static ActiveGame g_active[MAX_ACTIVE];
static int        g_nactive    = 0;
static int        g_active_cnt = 0;

/* ── Global fds ──────────────────────────────────────────────────────────── */
static int g_epoll_fd  = -1;
static int g_nl_sock   = -1;
static int g_signal_fd = -1;
static int g_kmsg_fd   = -1;

static char g_restore_mode[32] = "skiavk";
static int  g_nl_failed = 0;
static char g_moddir[512] = {0};

/* ═══════════════════════════════════════════════════════════════════════════
 * Logging to /dev/kmsg (visible in dmesg, logcat -b kernel)
 * ═══════════════════════════════════════════════════════════════════════════ */
static void klog(const char *fmt, ...) {
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    if (g_kmsg_fd >= 0) {
        char msg[540];
        int n = snprintf(msg, sizeof(msg), "[ADRENO-GED] %s\n", buf);
        (void)write(g_kmsg_fd, msg, (size_t)n);
    }
}

/* ═══════════════════════════════════════════════════════════════════════════
 * Package list — parses GAME_EXCLUSION_PKGS from game_exclusion_list.sh
 * ═══════════════════════════════════════════════════════════════════════════ */
static void load_pkg_list_from_file(const char *path) {
    FILE *f = fopen(path, "r");
    if (!f) return;

    int  inside = 0, loaded = 0;
    char line[MAX_PKG_LEN + 32];

    while (fgets(line, (int)sizeof(line), f)) {
        size_t len = strlen(line);
        while (len > 0 && (line[len-1] == '\n' || line[len-1] == '\r'))
            line[--len] = '\0';

        if (!inside) {
            if (strstr(line, "GAME_EXCLUSION_PKGS=")) {
                inside = 1;
                /* handle packages on same line after opening quote */
                char *q = strchr(line, '"');
                if (q) {
                    q++;
                    while (*q == ' ' || *q == '\t') q++;
                    if (*q && *q != '"' && *q != '#' && isalpha((unsigned char)*q))
                        if (loaded < MAX_PKGS) {
                            strncpy(g_pkgs[loaded], q, MAX_PKG_LEN - 1);
                            g_pkgs[loaded++][MAX_PKG_LEN - 1] = '\0';
                        }
                }
            }
            continue;
        }
        /* closing quote ends the list */
        if (strchr(line, '"')) break;

        const char *p = line;
        while (*p == ' ' || *p == '\t') p++;
        if (!*p || *p == '#' || !isalpha((unsigned char)*p)) continue;
        if (loaded < MAX_PKGS) {
            strncpy(g_pkgs[loaded], p, MAX_PKG_LEN - 1);
            g_pkgs[loaded++][MAX_PKG_LEN - 1] = '\0';
        }
    }
    fclose(f);
    if (loaded > 0) {
        g_npkgs = loaded;
        klog("pkg list from %s (%d entries)", path, loaded);
    }
}

static void load_pkg_list(void) {
    g_npkgs = 0;
    for (int i = 0; LIST_PATHS[i]; i++) {
        load_pkg_list_from_file(LIST_PATHS[i]);
        if (g_npkgs > 0) return;
    }
    if (g_moddir[0]) {
        char path[512 + 32];
        snprintf(path, sizeof(path), "%s/game_exclusion_list.sh", g_moddir);
        load_pkg_list_from_file(path);
        if (g_npkgs > 0) return;
    }
    klog("pkg list not found -- using built-in defaults");
    for (int i = 0; DEFAULT_PKGS[i] && g_npkgs < MAX_PKGS; i++) {
        strncpy(g_pkgs[g_npkgs], DEFAULT_PKGS[i], MAX_PKG_LEN - 1);
        g_pkgs[g_npkgs++][MAX_PKG_LEN - 1] = '\0';
    }
}

/* ═══════════════════════════════════════════════════════════════════════════
 * Matching helpers
 * ═══════════════════════════════════════════════════════════════════════════ */
static int pkg_matches(const char *pkg) {
    for (int i = 0; i < g_npkgs; i++)
        if (fnmatch(g_pkgs[i], pkg, 0) == 0) return 1;
    return 0;
}

static int read_cmdline(pid_t pid, char *out, size_t outsz) {
    char path[64];
    snprintf(path, sizeof(path), "/proc/%d/cmdline", (int)pid);
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return 0;
    ssize_t n = read(fd, out, (ssize_t)outsz - 1);
    close(fd);
    if (n <= 0) return 0;
    out[n] = '\0';
    /* cmdline is NUL-separated: first field is argv[0] = package name */
    /* strip :processname suffix (e.g. "com.tencent.ig:remote") */
    char *colon = strchr(out, ':');
    if (colon) *colon = '\0';
    if (!out[0] || out[0] == '[' || out[0] == ' ') return 0;
    return 1;
}

/*
 * Quick pre-filter on PROC_EVENT_COMM before reading full cmdline.
 * comm is ≤16 chars. We only do the full cmdline read if comm looks
 * like it could be a Java package name or a known game prefix.
 * Rejects kernel threads ([kworker], [migration]), native daemons
 * (/sbin/adbd, surfaceflinger), etc. instantly.
 */
static int comm_could_be_app(const char *comm) {
    /* Java package names start with a letter and contain dots */
    if (!isalpha((unsigned char)comm[0])) return 0;
    /* Must contain a dot (package separator) or be long enough */
    if (strchr(comm, '.')) return 1;
    /* Could be truncated package name (16 chars, dot got cut off) */
    if (strlen(comm) >= 15) return 1;
    return 0;
}

/* ═══════════════════════════════════════════════════════════════════════════
 * Zygote tracking
 * ═══════════════════════════════════════════════════════════════════════════ */
static int is_zygote_pid(pid_t pid) {
    for (int i = 0; i < g_nzygotes; i++)
        if (g_zygote_pids[i] == pid) return 1;
    return 0;
}

static void find_zygote_pids(void) {
    g_nzygotes = 0;
    DIR *d = opendir("/proc");
    if (!d) return;
    struct dirent *de;
    while ((de = readdir(d)) && g_nzygotes < MAX_ZYGOTES) {
        if (!isdigit((unsigned char)de->d_name[0])) continue;
        int ok = 1;
        const char *p = de->d_name;
        while (*p) if (!isdigit((unsigned char)*p++)) { ok = 0; break; }
        if (!ok) continue;
        pid_t pid = (pid_t)atoi(de->d_name);
        char cmd[64];
        if (!read_cmdline(pid, cmd, sizeof(cmd))) continue;
        if (strcmp(cmd, "zygote64") == 0 || strcmp(cmd, "zygote") == 0 ||
            strcmp(cmd, "zygote32") == 0) {
            g_zygote_pids[g_nzygotes++] = pid;
            klog("found zygote: %s PID=%d", cmd, (int)pid);
        }
    }
    closedir(d);
    if (g_nzygotes == 0)
        klog("WARNING: no zygote found in /proc -- all forks will be checked");
}

/* ═══════════════════════════════════════════════════════════════════════════
 * Pending fork table
 * ═══════════════════════════════════════════════════════════════════════════ */
static void pending_add(pid_t child_pid) {
    /* Evict timed-out entries first */
    time_t now = time(NULL);
    int w = 0;
    for (int i = 0; i < g_npending; i++) {
        if (now - g_pending[i].born < PENDING_TIMEOUT_S)
            g_pending[w++] = g_pending[i];
    }
    g_npending = w;

    if (g_npending >= MAX_PENDING) return;  /* table full, skip */
    g_pending[g_npending].pid  = child_pid;
    g_pending[g_npending].born = now;
    g_npending++;
}

/* Returns 1 if pid was in pending table (and removes it) */
static int pending_remove(pid_t pid) {
    for (int i = 0; i < g_npending; i++) {
        if (g_pending[i].pid == pid) {
            g_pending[i] = g_pending[--g_npending];
            return 1;
        }
    }
    return 0;
}

/* ═══════════════════════════════════════════════════════════════════════════
 * Renderer control
 * ═══════════════════════════════════════════════════════════════════════════ */
static void set_renderer(const char *mode) {
    pid_t child = fork();
    if (child == 0) {
        char *argv[] = { "resetprop", "debug.hwui.renderer", (char *)mode, NULL };
        execv("/data/adb/magisk/resetprop", argv);
        execv("/data/adb/ksu/bin/resetprop",  argv);
        execv("/data/adb/ap/bin/resetprop",   argv);
        execvp("resetprop", argv);
        _exit(1);
    }
    if (child > 0) { int st; waitpid(child, &st, 0); }
    klog("renderer -> %s", mode);
}

/* ═══════════════════════════════════════════════════════════════════════════
 * State files + duplicate guard
 * ═══════════════════════════════════════════════════════════════════════════ */
static void write_state(int active) {
    int fd = open(STATE_FILE, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0) return;
    (void)write(fd, active ? "1\n" : "0\n", 2);
    close(fd);
}

static void write_pid(void) {
    char buf[32];
    int n = snprintf(buf, sizeof(buf), "%d\n", (int)getpid());
    int fd = open(PID_FILE, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0) return;
    (void)write(fd, buf, (size_t)n);
    close(fd);
}

static int already_running(void) {
    int fd = open(PID_FILE, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return 0;
    char buf[32] = {0};
    (void)read(fd, buf, sizeof(buf) - 1);
    close(fd);
    pid_t existing = (pid_t)atoi(buf);
    if (existing <= 0 || existing == getpid()) return 0;
    if (kill(existing, 0) == 0) {
        klog("already running as PID %d -- exiting", (int)existing);
        return 1;
    }
    return 0;
}

/* ═══════════════════════════════════════════════════════════════════════════
 * Game open / close
 * ═══════════════════════════════════════════════════════════════════════════ */
static void game_open(const char *pkg, pid_t pid) {
    if (g_nactive >= MAX_ACTIVE) return;
    for (int i = 0; i < g_nactive; i++)
        if (g_active[i].pid == pid) return;  /* already tracked */

    int pfd      = sys_pidfd_open(pid, 0);
    int use_poll = (pfd < 0) ? 1 : 0;

    ActiveGame *ag = &g_active[g_nactive];
    ag->pidfd    = pfd;
    ag->pid      = pid;
    ag->use_poll = use_poll;
    strncpy(ag->pkg, pkg, MAX_PKG_LEN - 1);
    ag->pkg[MAX_PKG_LEN - 1] = '\0';
    g_nactive++;
    g_active_cnt++;

    if (g_active_cnt == 1) {
        set_renderer("skiagl");
        write_state(1);
        klog("GAME OPEN: %s PID=%d -> skiagl", pkg, (int)pid);
    } else {
        klog("GAME OPEN: %s PID=%d (active=%d, already skiagl)", pkg, (int)pid, g_active_cnt);
    }

    if (pfd >= 0) {
        struct epoll_event ev;
        ev.events  = EPOLLIN;
        ev.data.fd = pfd;
        if (epoll_ctl(g_epoll_fd, EPOLL_CTL_ADD, pfd, &ev) < 0) {
            close(pfd);
            g_active[g_nactive - 1].pidfd    = -1;
            g_active[g_nactive - 1].use_poll = 1;
        }
    }
}

static void _close_game_at(int idx) {
    char pkg[MAX_PKG_LEN];
    pid_t pid = g_active[idx].pid;
    strncpy(pkg, g_active[idx].pkg, MAX_PKG_LEN);

    if (g_active[idx].pidfd >= 0) {
        epoll_ctl(g_epoll_fd, EPOLL_CTL_DEL, g_active[idx].pidfd, NULL);
        close(g_active[idx].pidfd);
    }
    g_active[idx] = g_active[--g_nactive];
    if (g_active_cnt > 0) g_active_cnt--;

    if (g_active_cnt == 0) {
        set_renderer(g_restore_mode);
        write_state(0);
        klog("GAME CLOSED: %s PID=%d -> %s", pkg, (int)pid, g_restore_mode);
    } else {
        klog("GAME CLOSED: %s PID=%d (active=%d, staying skiagl)", pkg, (int)pid, g_active_cnt);
    }
}

static void game_closed_by_pidfd(int pidfd) {
    for (int i = 0; i < g_nactive; i++)
        if (g_active[i].pidfd == pidfd) { _close_game_at(i); return; }
}

static void game_closed_by_pid(pid_t pid) {
    for (int i = 0; i < g_nactive; i++)
        if (g_active[i].pid == pid) { _close_game_at(i); return; }
}

/* ═══════════════════════════════════════════════════════════════════════════
 * /proc poll fallback
 * ═══════════════════════════════════════════════════════════════════════════ */
static void poll_active_games(void) {
    for (int i = g_nactive - 1; i >= 0; i--) {
        if (!g_active[i].use_poll) continue;
        char path[64];
        snprintf(path, sizeof(path), "/proc/%d", (int)g_active[i].pid);
        struct stat st;
        if (stat(path, &st) == 0) continue;
        game_closed_by_pid(g_active[i].pid);
    }
}

/* Full /proc scan — only when netlink unavailable */
static void proc_scan_for_games(void) {
    DIR *d = opendir("/proc");
    if (!d) return;
    struct dirent *de;
    while ((de = readdir(d))) {
        if (!isdigit((unsigned char)de->d_name[0])) continue;
        int ok = 1;
        const char *p = de->d_name;
        while (*p) if (!isdigit((unsigned char)*p++)) { ok = 0; break; }
        if (!ok) continue;
        pid_t pid = (pid_t)atoi(de->d_name);
        if (pid <= 1) continue;
        int found = 0;
        for (int i = 0; i < g_nactive; i++)
            if (g_active[i].pid == pid) { found = 1; break; }
        if (found) continue;
        char pkg[MAX_PKG_LEN];
        if (!read_cmdline(pid, pkg, sizeof(pkg))) continue;
        if (!pkg_matches(pkg)) continue;
        game_open(pkg, pid);
    }
    closedir(d);
}

/* ═══════════════════════════════════════════════════════════════════════════
 * Netlink connector setup
 * ═══════════════════════════════════════════════════════════════════════════ */
static int netlink_open(void) {
    int sock = socket(PF_NETLINK,
                      SOCK_DGRAM | SOCK_CLOEXEC | SOCK_NONBLOCK,
                      NETLINK_CONNECTOR);
    if (sock < 0) { klog("netlink socket: %s", strerror(errno)); return -1; }

    struct sockaddr_nl sa;
    memset(&sa, 0, sizeof(sa));
    sa.nl_family = AF_NETLINK;
    sa.nl_groups = CN_IDX_PROC;
    sa.nl_pid    = (unsigned int)getpid();

    if (bind(sock, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
        klog("netlink bind: %s", strerror(errno));
        close(sock);
        return -1;
    }

    /*
     * Subscribe to proc events via PROC_CN_MCAST_LISTEN.
     * We send a struct { nlmsghdr + cn_msg header + op } as a flat
     * byte buffer to avoid the -Wpedantic flexible array member warning.
     */
    unsigned char buf[NLMSG_SPACE(sizeof(struct cn_msg) +
                                   sizeof(enum proc_cn_mcast_op))];
    memset(buf, 0, sizeof(buf));

    struct nlmsghdr *nlh = (struct nlmsghdr *)buf;
    nlh->nlmsg_len  = sizeof(buf);
    nlh->nlmsg_type = NLMSG_DONE;
    nlh->nlmsg_pid  = (unsigned int)getpid();

    struct cn_msg *cn = (struct cn_msg *)NLMSG_DATA(nlh);
    cn->id.idx = CN_IDX_PROC;
    cn->id.val = CN_VAL_PROC;
    cn->len    = sizeof(enum proc_cn_mcast_op);

    enum proc_cn_mcast_op *op = (enum proc_cn_mcast_op *)cn->data;
    *op = PROC_CN_MCAST_LISTEN;

    struct sockaddr_nl dest;
    memset(&dest, 0, sizeof(dest));
    dest.nl_family = AF_NETLINK;
    dest.nl_pid    = 0;
    dest.nl_groups = CN_IDX_PROC;

    if (sendto(sock, buf, sizeof(buf), 0,
               (struct sockaddr *)&dest, sizeof(dest)) < 0) {
        klog("netlink subscribe: %s", strerror(errno));
        close(sock);
        return -1;
    }

    klog("netlink: subscribed (PROC_EVENT_FORK + PROC_EVENT_COMM + PROC_EVENT_EXIT)");
    return sock;
}

/* ═══════════════════════════════════════════════════════════════════════════
 * Handle netlink proc events
 *
 * FORK event: if parent is zygote → add child to pending table
 * COMM event: if child is in pending table AND comm looks like an app
 *             → read full cmdline → check against package list
 * EXIT event: if PID is an active game → close it
 * ═══════════════════════════════════════════════════════════════════════════ */
static void handle_netlink(void) {
    char buf[NL_BUF_SIZE]
        __attribute__((aligned(__alignof__(struct nlmsghdr))));

    ssize_t len = recv(g_nl_sock, buf, sizeof(buf), 0);
    if (len <= 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK) return;
        klog("netlink recv: %s", strerror(errno));
        return;
    }

    struct nlmsghdr *nlh = (struct nlmsghdr *)buf;
    for (; NLMSG_OK(nlh, (unsigned int)len); nlh = NLMSG_NEXT(nlh, len)) {
        if (nlh->nlmsg_type != NLMSG_DONE) continue;

        struct cn_msg *cn = (struct cn_msg *)NLMSG_DATA(nlh);
        if (cn->id.idx != CN_IDX_PROC || cn->id.val != CN_VAL_PROC) continue;

        const struct proc_event *ev = (const struct proc_event *)cn->data;

        switch (ev->what) {

        case PROC_EVENT_FORK: {
            pid_t parent = ev->event_data.fork.parent_tgid;
            pid_t child  = ev->event_data.fork.child_tgid;

            /*
             * If we have no zygote PIDs (unusual), accept all forks.
             * Otherwise only track forks from zygote.
             * Also track if parent==1 (init): could be zygote restarting.
             */
            if (g_nzygotes == 0 || is_zygote_pid(parent) || parent == 1) {
                if (parent == 1) {
                    /*
                     * init is forking something — could be new zygote.
                     * Add child to pending and re-scan for zygote on COMM.
                     */
                }
                pending_add(child);
            }
            break;
        }

        case PROC_EVENT_COMM: {
            pid_t pid = ev->event_data.comm.process_tgid;

            /* Only process PIDs we saw born from zygote */
            if (!pending_remove(pid)) break;

            /* Quick pre-filter on the 16-char comm name */
            const char *comm = ev->event_data.comm.comm;
            if (!comm_could_be_app(comm)) break;

            /* Read full cmdline — this is the real package name */
            char pkg[MAX_PKG_LEN];
            if (!read_cmdline(pid, pkg, sizeof(pkg))) break;

            /* If this was a new zygote, record its PID */
            if ((strcmp(pkg, "zygote64") == 0 || strcmp(pkg, "zygote") == 0 ||
                 strcmp(pkg, "zygote32") == 0) && g_nzygotes < MAX_ZYGOTES) {
                g_zygote_pids[g_nzygotes++] = pid;
                klog("new zygote detected: %s PID=%d", pkg, (int)pid);
                break;
            }

            if (pkg_matches(pkg))
                game_open(pkg, pid);
            break;
        }

        case PROC_EVENT_EXIT: {
            pid_t pid = ev->event_data.exit.process_tgid;
            /*
             * pidfd fires first (instant). This is the belt-and-suspenders
             * backup for the poll-fallback case and any edge cases.
             */
            game_closed_by_pid(pid);
            break;
        }

        default:
            break;
        }
    }
}

/* ═══════════════════════════════════════════════════════════════════════════
 * Startup scan — catch games already running when daemon starts
 * ═══════════════════════════════════════════════════════════════════════════ */
static void startup_scan(void) {
    klog("startup scan...");
    DIR *d = opendir("/proc");
    if (!d) return;
    struct dirent *de;
    while ((de = readdir(d))) {
        if (!isdigit((unsigned char)de->d_name[0])) continue;
        int ok = 1;
        const char *p = de->d_name;
        while (*p) if (!isdigit((unsigned char)*p++)) { ok = 0; break; }
        if (!ok) continue;
        pid_t pid = (pid_t)atoi(de->d_name);
        if (pid <= 1) continue;
        char pkg[MAX_PKG_LEN];
        if (!read_cmdline(pid, pkg, sizeof(pkg))) continue;
        if (!pkg_matches(pkg)) continue;
        klog("startup scan: found %s PID=%d", pkg, (int)pid);
        game_open(pkg, pid);
    }
    closedir(d);
}

/* ═══════════════════════════════════════════════════════════════════════════
 * Clean shutdown — restore renderer if a game was running
 * ═══════════════════════════════════════════════════════════════════════════ */
static void shutdown_daemon(int restore) {
    if (restore && g_active_cnt > 0) {
        set_renderer(g_restore_mode);
        write_state(0);
        klog("shutdown: restored %s", g_restore_mode);
    }
    for (int i = 0; i < g_nactive; i++) {
        if (g_active[i].pidfd >= 0) {
            epoll_ctl(g_epoll_fd, EPOLL_CTL_DEL, g_active[i].pidfd, NULL);
            close(g_active[i].pidfd);
        }
    }
    unlink(PID_FILE);
    if (g_nl_sock   >= 0) close(g_nl_sock);
    if (g_epoll_fd  >= 0) close(g_epoll_fd);
    if (g_signal_fd >= 0) close(g_signal_fd);
    if (g_kmsg_fd   >= 0) close(g_kmsg_fd);
}

/* ═══════════════════════════════════════════════════════════════════════════
 * main
 * ═══════════════════════════════════════════════════════════════════════════ */
int main(int argc, char *argv[]) {
    if (argc >= 2 && strcmp(argv[1], "skiavk_all") == 0)
        strncpy(g_restore_mode, "skiavk_all", sizeof(g_restore_mode) - 1);

    if (argc >= 3)
        strncpy(g_moddir, argv[2], sizeof(g_moddir) - 1);

    g_kmsg_fd = open(KMSG, O_WRONLY | O_CLOEXEC);
    if (already_running()) return 0;

    load_pkg_list();
    if (g_npkgs == 0) { klog("FATAL: empty package list"); return 1; }

    write_pid();
    klog("started PID=%d restore=%s pkgs=%d", (int)getpid(), g_restore_mode, g_npkgs);

    /* Block signals before creating signalfd — avoids race */
    sigset_t mask;
    sigemptyset(&mask);
    sigaddset(&mask, SIGTERM);
    sigaddset(&mask, SIGINT);
    sigaddset(&mask, SIGHUP);
    sigprocmask(SIG_BLOCK, &mask, NULL);

    g_epoll_fd = epoll_create1(EPOLL_CLOEXEC);
    if (g_epoll_fd < 0) { klog("epoll_create1: %s", strerror(errno)); return 1; }

    g_signal_fd = signalfd(-1, &mask, SFD_CLOEXEC | SFD_NONBLOCK);
    if (g_signal_fd < 0) { klog("signalfd: %s", strerror(errno)); return 1; }
    {
        struct epoll_event ev;
        ev.events  = EPOLLIN;
        ev.data.fd = g_signal_fd;
        epoll_ctl(g_epoll_fd, EPOLL_CTL_ADD, g_signal_fd, &ev);
    }

    /* Find zygote PIDs before subscribing to netlink */
    find_zygote_pids();

    /* Netlink connector */
    g_nl_sock = netlink_open();
    if (g_nl_sock >= 0) {
        struct epoll_event ev;
        ev.events  = EPOLLIN;
        ev.data.fd = g_nl_sock;
        epoll_ctl(g_epoll_fd, EPOLL_CTL_ADD, g_nl_sock, &ev);
        g_nl_failed = 0;
    } else {
        klog("WARNING: netlink unavailable -- /proc poll fallback (1s)");
        g_nl_failed = 1;
    }

    /* Catch already-running games (race window between netlink subscribe
     * and startup; games running before first boot of daemon) */
    startup_scan();

    klog("main loop: %s",
         g_nl_failed
             ? "fallback: /proc scan 1s"
             : "netlink FORK+COMM events + pidfd (zero overhead)");

    /* ═══════════════════════════════════════════════════════════════════════
     * MAIN EVENT LOOP
     *
     * epoll_wait(-1): this process sleeps in TASK_INTERRUPTIBLE — zero CPU.
     *
     * Woken only by:
     *   g_nl_sock:   PROC_EVENT_FORK / PROC_EVENT_COMM / PROC_EVENT_EXIT
     *   pidfd (N):   exact moment each tracked game exits
     *   g_signal_fd: SIGTERM / SIGINT / SIGHUP
     *
     * timeout=-1 (infinite) unless:
     *   netlink failed → 1s full /proc scan
     *   any game uses pidfd poll fallback → 1s /proc stat check
     * ═══════════════════════════════════════════════════════════════════════ */
    struct epoll_event events[MAX_EPOLL_EVENTS];

    for (;;) {
        int timeout = -1;
        if (g_nl_failed) {
            timeout = 1000;
        } else {
            for (int i = 0; i < g_nactive; i++)
                if (g_active[i].use_poll) { timeout = 1000; break; }
        }

        int nev = epoll_wait(g_epoll_fd, events, MAX_EPOLL_EVENTS, timeout);

        if (nev < 0) {
            if (errno == EINTR) continue;
            klog("epoll_wait: %s", strerror(errno));
            break;
        }

        if (nev == 0) {
            /* Timeout: /proc fallback */
            if (g_nl_failed) proc_scan_for_games();
            poll_active_games();
            continue;
        }

        for (int i = 0; i < nev; i++) {
            int fd = events[i].data.fd;

            if (fd == g_signal_fd) {
                struct signalfd_siginfo si;
                if (read(g_signal_fd, &si, sizeof(si)) != (ssize_t)sizeof(si))
                    continue;
                if (si.ssi_signo == SIGHUP) {
                    klog("SIGHUP: reloading pkg list");
                    load_pkg_list();
                    klog("reloaded (%d entries)", g_npkgs);
                } else {
                    klog("signal %u: shutting down", si.ssi_signo);
                    shutdown_daemon(1);
                    return 0;
                }
                continue;
            }

            if (fd == g_nl_sock) {
                handle_netlink();
                continue;
            }

            /* pidfd: game process exited */
            if (events[i].events & EPOLLIN)
                game_closed_by_pidfd(fd);
        }
    }

    shutdown_daemon(1);
    return 0;
}
