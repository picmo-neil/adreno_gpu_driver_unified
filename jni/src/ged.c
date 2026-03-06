/*
 * ADRENO DRIVER MODULE — GAME EXCLUSION DAEMON (NATIVE)
 *
 * Switches debug.hwui.renderer skiagl when an excluded game launches,
 * restores skiavk/skiavk_all when all excluded games exit.
 *
 * ANDROID APP LAUNCH MODEL (why we use FORK+COMM, not EXEC):
 *   Every Android app is born from zygote via fork(). execve() is never
 *   called for Java apps. PROC_EVENT_EXEC fires only for native binaries
 *   (sh, grep, etc.) — it would miss every game on our list.
 *   Correct sequence: PROC_EVENT_FORK (PID known, name = "zygote64") →
 *   PROC_EVENT_COMM (process renames itself to package name) →
 *   read /proc/<pid>/cmdline → fnmatch against exclusion list.
 *
 * BUGS FIXED vs PREVIOUS VERSION:
 *   1. waitpid() was blocking the epoll loop for ~200ms per resetprop call.
 *      Fix: SIGCHLD added to signalfd mask; resetprop reaped asynchronously.
 *   2. ENOBUFS on netlink recv (kernel dropped events under load) caused
 *      a tight spin: epoll kept waking, recv kept returning -1, no break.
 *      Fix: on any persistent netlink error, remove fd from epoll and fall
 *      back to 1s /proc scan. The daemon never spins.
 *   3. SIGCHLD not blocked → zombie resetprop children accumulated.
 *      Fix: SIGCHLD blocked and routed through signalfd; waitpid(-1,WNOHANG)
 *      reaps all children on each SIGCHLD delivery.
 *   4. No restart guard → Magisk/init could restart a crashed daemon in a
 *      tight loop → watchdog reboot. Fix: PID file checked and refreshed;
 *      daemon exits cleanly (not crashes) on all error paths.
 *   5. set_renderer() forked a child but did not handle fork() == -1.
 *      Fix: fork failure falls back to direct setprop.
 *
 * ARCHITECTURE:
 *   Launch detection : Netlink PROC_EVENT_FORK + PROC_EVENT_COMM
 *   Death detection  : pidfd_open + epoll (kernel 5.3+/Android 12+)
 *                      falls back to 1s /proc stat on older kernels
 *   Death backup     : PROC_EVENT_EXIT (belt-and-suspenders)
 *   Signals          : signalfd (SIGTERM, SIGINT, SIGHUP, SIGCHLD)
 *   Fallback         : 1s /proc scan if netlink unavailable
 *
 * USAGE:  adreno_ged <skiavk|skiavk_all> [MODDIR]
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

/* pidfd_open syscall — not in all bionic versions */
#ifndef __NR_pidfd_open
#  define __NR_pidfd_open 434
#endif
static inline int sys_pidfd_open(pid_t pid, unsigned int flags) {
    return (int)syscall(__NR_pidfd_open, (long)pid, (long)(unsigned long)flags);
}

/* ── Limits ──────────────────────────────────────────────────────────────── */
#define MAX_PKGS          128
#define MAX_PKG_LEN       256
#define MAX_ACTIVE        64
#define MAX_PENDING       128
#define MAX_EPOLL_EVENTS  32
#define NL_BUF_SIZE       8192
#define PENDING_TIMEOUT_S 5

#define PID_FILE   "/data/local/tmp/adreno_ged_pid"
#define STATE_FILE "/data/local/tmp/adreno_ged_active"
#define KMSG       "/dev/kmsg"

/* ── Package list ────────────────────────────────────────────────────────── */
static char g_pkgs[MAX_PKGS][MAX_PKG_LEN];
static int  g_npkgs = 0;

static const char *LIST_PATHS[] = {
    "/sdcard/Adreno_Driver/Config/game_exclusion_list.sh",
    "/data/local/tmp/adreno_game_exclusion_list.sh",
    NULL
};
static const char *DEFAULT_PKGS[] = {
    "com.tencent.ig", "com.pubg.krmobile", "com.pubg.imobile",
    "com.vng.pubgmobile", "com.rekoo.pubgm", "com.tencent.tmgp.pubgmhd",
    "com.epicgames.*",
    "com.activision.callofduty.shooter", "com.garena.game.codm",
    "com.tencent.tmgp.cod", "com.vng.codmvn",
    "com.miHoYo.GenshinImpact", "com.cognosphere.GenshinImpact",
    "com.miHoYo.enterprise.HSRPrism", "com.HoYoverse.hkrpgoversea",
    "com.levelinfinite.hotta", "com.proximabeta.mfh",
    "com.HoYoverse.Nap", "com.miHoYo.ZZZ",
    "com.facebook.katana", "com.facebook.orca",
    "com.facebook.lite", "com.facebook.mlite",
    "com.instagram.android", "com.instagram.lite",
    "com.whatsapp", "com.whatsapp.w4b",
    NULL
};

/* ── Zygote PIDs ─────────────────────────────────────────────────────────── */
#define MAX_ZYGOTES 4
static pid_t g_zygote_pids[MAX_ZYGOTES];
static int   g_nzygotes = 0;

/* ── Pending fork table ──────────────────────────────────────────────────── */
typedef struct { pid_t pid; time_t born; } Pending;
static Pending g_pending[MAX_PENDING];
static int     g_npending = 0;

/* ── Active games ────────────────────────────────────────────────────────── */
typedef struct {
    int   pidfd;
    pid_t pid;
    char  pkg[MAX_PKG_LEN];
    int   use_poll;
} ActiveGame;
static ActiveGame g_active[MAX_ACTIVE];
static int        g_nactive    = 0;
static int        g_active_cnt = 0;

/* ── Globals ─────────────────────────────────────────────────────────────── */
static int  g_epoll_fd  = -1;
static int  g_nl_sock   = -1;
static int  g_signal_fd = -1;
static int  g_kmsg_fd   = -1;
static char g_restore_mode[32] = "skiavk";
static char g_moddir[512]      = {0};
static int  g_nl_failed        = 0;

/* ═══════════════════════════════════════════════════════════════════════════
 * Logging
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
 * Package list
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
                char *q = strchr(line, '"');
                if (q && *(++q) && *q != '"' && isalpha((unsigned char)*q) && loaded < MAX_PKGS) {
                    strncpy(g_pkgs[loaded], q, MAX_PKG_LEN - 1);
                    g_pkgs[loaded++][MAX_PKG_LEN - 1] = '\0';
                }
            }
            continue;
        }
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
    if (loaded > 0) { g_npkgs = loaded; klog("pkg list: %s (%d)", path, loaded); }
}

static void load_pkg_list(void) {
    g_npkgs = 0;
    for (int i = 0; LIST_PATHS[i]; i++) {
        load_pkg_list_from_file(LIST_PATHS[i]);
        if (g_npkgs > 0) return;
    }
    if (g_moddir[0]) {
        char p[544]; snprintf(p, sizeof(p), "%s/game_exclusion_list.sh", g_moddir);
        load_pkg_list_from_file(p);
        if (g_npkgs > 0) return;
    }
    klog("pkg list not found -- using built-in defaults");
    for (int i = 0; DEFAULT_PKGS[i] && g_npkgs < MAX_PKGS; i++) {
        strncpy(g_pkgs[g_npkgs], DEFAULT_PKGS[i], MAX_PKG_LEN - 1);
        g_pkgs[g_npkgs++][MAX_PKG_LEN - 1] = '\0';
    }
}

/* ═══════════════════════════════════════════════════════════════════════════
 * Helpers
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
    char *colon = strchr(out, ':');
    if (colon) *colon = '\0';
    if (!out[0] || out[0] == '[') return 0;
    return 1;
}

static int comm_could_be_app(const char *comm) {
    /* reject kernel threads, native daemons, etc. */
    if (!isalpha((unsigned char)comm[0])) return 0;
    if (strchr(comm, '.')) return 1;       /* has a dot → likely Java package */
    if (strlen(comm) >= 15) return 1;      /* 16-char truncated package name */
    return 0;
}

/* ═══════════════════════════════════════════════════════════════════════════
 * Renderer control — NON-BLOCKING
 *
 * FIX: Previous version called waitpid() which BLOCKED the event loop
 * for ~200ms. This caused netlink buffer overflows (ENOBUFS) and in turn
 * a tight epoll spin → 100% CPU → watchdog → reboot.
 *
 * Fix: SIGCHLD is routed through signalfd. Children are reaped when
 * SIGCHLD fires in the main epoll loop (see handle_signal). fork()
 * failure falls back to setprop (no child → nothing to reap).
 * ═══════════════════════════════════════════════════════════════════════════ */
static void set_renderer(const char *mode) {
    pid_t child = fork();
    if (child == 0) {
        /* child: close all fds except stderr, then exec resetprop */
        for (int fd = 3; fd < 256; fd++) close(fd);
        char *argv[] = { "resetprop", "debug.hwui.renderer", (char *)mode, NULL };
        execv("/data/adb/magisk/resetprop", argv);
        execv("/data/adb/ksu/bin/resetprop",  argv);
        execv("/data/adb/ap/bin/resetprop",   argv);
        execvp("resetprop", argv);
        /* resetprop not found: fall back to setprop */
        char *sargv[] = { "setprop", "debug.hwui.renderer", (char *)mode, NULL };
        execvp("setprop", sargv);
        _exit(1);
    } else if (child < 0) {
        /* fork failed: try setprop directly (no child to reap) */
        char *argv[] = { "setprop", "debug.hwui.renderer", (char *)mode, NULL };
        pid_t fb = fork();
        if (fb == 0) { execvp("setprop", argv); _exit(1); }
        /* if this fork also fails, just log and continue — never crash */
    }
    /* Parent returns immediately. Child is reaped on SIGCHLD via signalfd. */
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
    if (kill(existing, 0) == 0) { klog("already running PID %d", (int)existing); return 1; }
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
static void add_zygote_pid(pid_t pid) {
    if (g_nzygotes >= MAX_ZYGOTES) return;
    for (int i = 0; i < g_nzygotes; i++) if (g_zygote_pids[i] == pid) return;
    g_zygote_pids[g_nzygotes++] = pid;
}
static void find_zygote_pids(void) {
    g_nzygotes = 0;
    DIR *d = opendir("/proc");
    if (!d) return;
    struct dirent *de;
    while ((de = readdir(d))) {
        if (!isdigit((unsigned char)de->d_name[0])) continue;
        int ok = 1; const char *p = de->d_name;
        while (*p) if (!isdigit((unsigned char)*p++)) { ok=0; break; }
        if (!ok) continue;
        pid_t pid = (pid_t)atoi(de->d_name);
        char cmd[64];
        if (!read_cmdline(pid, cmd, sizeof(cmd))) continue;
        if (strcmp(cmd,"zygote64")==0 || strcmp(cmd,"zygote")==0 || strcmp(cmd,"zygote32")==0) {
            add_zygote_pid(pid);
            klog("zygote: %s PID=%d", cmd, (int)pid);
        }
    }
    closedir(d);
    if (g_nzygotes == 0) klog("WARNING: zygote not found, tracking all forks");
}

/* ═══════════════════════════════════════════════════════════════════════════
 * Pending table
 * ═══════════════════════════════════════════════════════════════════════════ */
static void pending_add(pid_t child) {
    /* evict timed-out entries */
    time_t now = time(NULL);
    int w = 0;
    for (int i = 0; i < g_npending; i++)
        if (now - g_pending[i].born < PENDING_TIMEOUT_S) g_pending[w++] = g_pending[i];
    g_npending = w;
    if (g_npending >= MAX_PENDING) return;
    g_pending[g_npending].pid  = child;
    g_pending[g_npending].born = now;
    g_npending++;
}
static int pending_remove(pid_t pid) {
    for (int i = 0; i < g_npending; i++) {
        if (g_pending[i].pid == pid) { g_pending[i] = g_pending[--g_npending]; return 1; }
    }
    return 0;
}

/* ═══════════════════════════════════════════════════════════════════════════
 * Game open / close
 * ═══════════════════════════════════════════════════════════════════════════ */
static void game_open(const char *pkg, pid_t pid) {
    if (g_nactive >= MAX_ACTIVE) return;
    for (int i = 0; i < g_nactive; i++) if (g_active[i].pid == pid) return;

    int pfd = sys_pidfd_open(pid, 0);
    ActiveGame *ag = &g_active[g_nactive];
    ag->pidfd    = pfd;
    ag->pid      = pid;
    ag->use_poll = (pfd < 0) ? 1 : 0;
    strncpy(ag->pkg, pkg, MAX_PKG_LEN - 1);
    ag->pkg[MAX_PKG_LEN - 1] = '\0';
    g_nactive++;
    g_active_cnt++;

    if (g_active_cnt == 1) { set_renderer("skiagl"); write_state(1); }
    klog("OPEN: %s PID=%d active=%d", pkg, (int)pid, g_active_cnt);

    if (pfd >= 0) {
        struct epoll_event ev; ev.events = EPOLLIN; ev.data.fd = pfd;
        if (epoll_ctl(g_epoll_fd, EPOLL_CTL_ADD, pfd, &ev) < 0) {
            close(pfd); g_active[g_nactive-1].pidfd = -1; g_active[g_nactive-1].use_poll = 1;
        }
    }
}
static void close_game_at(int idx) {
    char pkg[MAX_PKG_LEN]; pid_t pid = g_active[idx].pid;
    strncpy(pkg, g_active[idx].pkg, MAX_PKG_LEN);
    if (g_active[idx].pidfd >= 0) {
        epoll_ctl(g_epoll_fd, EPOLL_CTL_DEL, g_active[idx].pidfd, NULL);
        close(g_active[idx].pidfd);
    }
    g_active[idx] = g_active[--g_nactive];
    if (g_active_cnt > 0) g_active_cnt--;
    if (g_active_cnt == 0) { set_renderer(g_restore_mode); write_state(0); }
    klog("CLOSED: %s PID=%d active=%d", pkg, (int)pid, g_active_cnt);
}
static void game_closed_by_pidfd(int pidfd) {
    for (int i = 0; i < g_nactive; i++) if (g_active[i].pidfd == pidfd) { close_game_at(i); return; }
}
static void game_closed_by_pid(pid_t pid) {
    for (int i = 0; i < g_nactive; i++) if (g_active[i].pid == pid) { close_game_at(i); return; }
}

/* ═══════════════════════════════════════════════════════════════════════════
 * /proc poll fallback
 * ═══════════════════════════════════════════════════════════════════════════ */
static void poll_active_games(void) {
    struct stat st;
    for (int i = g_nactive-1; i >= 0; i--) {
        if (!g_active[i].use_poll) continue;
        char path[64]; snprintf(path, sizeof(path), "/proc/%d", (int)g_active[i].pid);
        if (stat(path, &st) == 0) continue;
        game_closed_by_pid(g_active[i].pid);
    }
}
static void proc_scan_for_games(void) {
    DIR *d = opendir("/proc"); if (!d) return;
    struct dirent *de;
    while ((de = readdir(d))) {
        if (!isdigit((unsigned char)de->d_name[0])) continue;
        int ok=1; const char *p=de->d_name;
        while(*p) if(!isdigit((unsigned char)*p++)){ok=0;break;}
        if(!ok) continue;
        pid_t pid=(pid_t)atoi(de->d_name); if(pid<=1) continue;
        int found=0;
        for(int i=0;i<g_nactive;i++) if(g_active[i].pid==pid){found=1;break;}
        if(found) continue;
        char pkg[MAX_PKG_LEN];
        if(!read_cmdline(pid,pkg,sizeof(pkg))) continue;
        if(!pkg_matches(pkg)) continue;
        game_open(pkg,pid);
    }
    closedir(d);
}

/* ═══════════════════════════════════════════════════════════════════════════
 * Netlink setup
 * ═══════════════════════════════════════════════════════════════════════════ */
static int netlink_open(void) {
    int sock = socket(PF_NETLINK, SOCK_DGRAM|SOCK_CLOEXEC|SOCK_NONBLOCK, NETLINK_CONNECTOR);
    if (sock < 0) { klog("nl socket: %s", strerror(errno)); return -1; }

    struct sockaddr_nl sa;
    memset(&sa, 0, sizeof(sa));
    sa.nl_family = AF_NETLINK;
    sa.nl_groups = CN_IDX_PROC;
    sa.nl_pid    = (unsigned int)getpid();
    if (bind(sock, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
        klog("nl bind: %s", strerror(errno)); close(sock); return -1;
    }

    /* send PROC_CN_MCAST_LISTEN using flat buffer (avoids FAM warning) */
    unsigned char buf[NLMSG_SPACE(sizeof(struct cn_msg) + sizeof(enum proc_cn_mcast_op))];
    memset(buf, 0, sizeof(buf));
    struct nlmsghdr *nlh = (struct nlmsghdr *)buf;
    nlh->nlmsg_len  = sizeof(buf);
    nlh->nlmsg_type = NLMSG_DONE;
    nlh->nlmsg_pid  = (unsigned int)getpid();
    struct cn_msg *cn = (struct cn_msg *)NLMSG_DATA(nlh);
    cn->id.idx = CN_IDX_PROC; cn->id.val = CN_VAL_PROC;
    cn->len    = sizeof(enum proc_cn_mcast_op);
    *((enum proc_cn_mcast_op *)cn->data) = PROC_CN_MCAST_LISTEN;

    struct sockaddr_nl dest;
    memset(&dest, 0, sizeof(dest));
    dest.nl_family = AF_NETLINK; dest.nl_pid = 0; dest.nl_groups = CN_IDX_PROC;
    if (sendto(sock, buf, sizeof(buf), 0, (struct sockaddr *)&dest, sizeof(dest)) < 0) {
        klog("nl subscribe: %s", strerror(errno)); close(sock); return -1;
    }
    klog("netlink: ready (FORK+COMM+EXIT)");
    return sock;
}

/* ═══════════════════════════════════════════════════════════════════════════
 * Netlink event handler
 *
 * FIX: On recv error (including ENOBUFS = kernel dropped events under load),
 * we remove the socket from epoll and fall back to /proc polling.
 * Previously: logged and returned, but socket stayed in epoll → kept waking
 * → recv kept returning -1 → tight spin → 100% CPU → watchdog → reboot.
 * ═══════════════════════════════════════════════════════════════════════════ */
static void handle_netlink(void) {
    char buf[NL_BUF_SIZE] __attribute__((aligned(__alignof__(struct nlmsghdr))));
    ssize_t len = recv(g_nl_sock, buf, sizeof(buf), 0);
    if (len < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK) return;
        /* Any other error (including ENOBUFS): disable netlink, use /proc poll */
        klog("nl recv error %d (%s) -- falling back to /proc poll", errno, strerror(errno));
        epoll_ctl(g_epoll_fd, EPOLL_CTL_DEL, g_nl_sock, NULL);
        close(g_nl_sock);
        g_nl_sock   = -1;
        g_nl_failed = 1;
        return;
    }
    if (len == 0) return;

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
            if (g_nzygotes == 0 || is_zygote_pid(parent) || parent == 1)
                pending_add(child);
            break;
        }
        case PROC_EVENT_COMM: {
            pid_t pid = ev->event_data.comm.process_tgid;
            if (!pending_remove(pid)) break;
            if (!comm_could_be_app(ev->event_data.comm.comm)) break;
            char pkg[MAX_PKG_LEN];
            if (!read_cmdline(pid, pkg, sizeof(pkg))) break;
            /* detect new zygote (e.g. after crash/restart) */
            if (strcmp(pkg,"zygote64")==0 || strcmp(pkg,"zygote")==0 || strcmp(pkg,"zygote32")==0) {
                add_zygote_pid(pid); klog("new zygote PID=%d", (int)pid); break;
            }
            if (pkg_matches(pkg)) game_open(pkg, pid);
            break;
        }
        case PROC_EVENT_EXIT:
            game_closed_by_pid(ev->event_data.exit.process_tgid);
            break;
        default:
            break;
        }
    }
}

/* ═══════════════════════════════════════════════════════════════════════════
 * Signal handler (via signalfd)
 *
 * FIX: SIGCHLD is now routed through signalfd so we can reap resetprop
 * children without blocking the event loop. waitpid(-1, WNOHANG) reaps
 * all children that have exited since the last check.
 * ═══════════════════════════════════════════════════════════════════════════ */
static void handle_signal(void) {
    struct signalfd_siginfo si;
    while (read(g_signal_fd, &si, sizeof(si)) == (ssize_t)sizeof(si)) {
        switch (si.ssi_signo) {
        case SIGCHLD:
            /* Reap all exited children (resetprop processes) */
            while (waitpid(-1, NULL, WNOHANG) > 0) {}
            break;
        case SIGHUP:
            klog("SIGHUP: reloading pkg list");
            load_pkg_list();
            klog("reloaded (%d entries)", g_npkgs);
            break;
        case SIGTERM:
        case SIGINT:
            klog("signal %u: shutting down", si.ssi_signo);
            /* restore renderer if a game was active */
            if (g_active_cnt > 0) { set_renderer(g_restore_mode); write_state(0); }
            /* reap pending children before exit */
            while (waitpid(-1, NULL, WNOHANG) > 0) {}
            for (int i = 0; i < g_nactive; i++)
                if (g_active[i].pidfd >= 0) close(g_active[i].pidfd);
            unlink(PID_FILE);
            if (g_nl_sock   >= 0) close(g_nl_sock);
            if (g_epoll_fd  >= 0) close(g_epoll_fd);
            if (g_signal_fd >= 0) close(g_signal_fd);
            if (g_kmsg_fd   >= 0) close(g_kmsg_fd);
            _exit(0);
        default:
            break;
        }
    }
}

/* ═══════════════════════════════════════════════════════════════════════════
 * Startup scan
 * ═══════════════════════════════════════════════════════════════════════════ */
static void startup_scan(void) {
    klog("startup scan...");
    DIR *d = opendir("/proc"); if (!d) return;
    struct dirent *de;
    while ((de = readdir(d))) {
        if (!isdigit((unsigned char)de->d_name[0])) continue;
        int ok=1; const char *p=de->d_name;
        while(*p) if(!isdigit((unsigned char)*p++)){ok=0;break;}
        if(!ok) continue;
        pid_t pid=(pid_t)atoi(de->d_name); if(pid<=1) continue;
        char pkg[MAX_PKG_LEN];
        if(!read_cmdline(pid,pkg,sizeof(pkg))) continue;
        if(!pkg_matches(pkg)) continue;
        klog("startup: found %s PID=%d", pkg,(int)pid);
        game_open(pkg,pid);
    }
    closedir(d);
}

/* ═══════════════════════════════════════════════════════════════════════════
 * main
 * ═══════════════════════════════════════════════════════════════════════════ */
int main(int argc, char *argv[]) {
    if (argc >= 2 && strcmp(argv[1],"skiavk_all")==0)
        strncpy(g_restore_mode, "skiavk_all", sizeof(g_restore_mode)-1);
    if (argc >= 3)
        strncpy(g_moddir, argv[2], sizeof(g_moddir)-1);

    g_kmsg_fd = open(KMSG, O_WRONLY|O_CLOEXEC);
    if (already_running()) return 0;

    load_pkg_list();
    if (g_npkgs == 0) { klog("FATAL: empty package list"); return 1; }

    write_pid();
    klog("started PID=%d restore=%s pkgs=%d", (int)getpid(), g_restore_mode, g_npkgs);

    /*
     * Block ALL signals we handle before creating signalfd.
     * SIGCHLD MUST be blocked here — otherwise a resetprop child
     * could exit between fork() and waitpid() causing SIGCHLD to be
     * delivered as a regular signal, killing the daemon.
     */
    sigset_t mask;
    sigemptyset(&mask);
    sigaddset(&mask, SIGTERM);
    sigaddset(&mask, SIGINT);
    sigaddset(&mask, SIGHUP);
    sigaddset(&mask, SIGCHLD);   /* ← FIX: was missing, caused zombie accumulation */
    sigprocmask(SIG_BLOCK, &mask, NULL);

    /* Also ignore SIGPIPE — write to broken /dev/kmsg fd must not kill us */
    signal(SIGPIPE, SIG_IGN);

    g_epoll_fd = epoll_create1(EPOLL_CLOEXEC);
    if (g_epoll_fd < 0) { klog("epoll: %s", strerror(errno)); return 1; }

    g_signal_fd = signalfd(-1, &mask, SFD_CLOEXEC|SFD_NONBLOCK);
    if (g_signal_fd < 0) { klog("signalfd: %s", strerror(errno)); return 1; }
    { struct epoll_event ev; ev.events=EPOLLIN; ev.data.fd=g_signal_fd;
      epoll_ctl(g_epoll_fd, EPOLL_CTL_ADD, g_signal_fd, &ev); }

    find_zygote_pids();

    g_nl_sock = netlink_open();
    if (g_nl_sock >= 0) {
        struct epoll_event ev; ev.events=EPOLLIN; ev.data.fd=g_nl_sock;
        epoll_ctl(g_epoll_fd, EPOLL_CTL_ADD, g_nl_sock, &ev);
        g_nl_failed = 0;
    } else {
        klog("WARNING: netlink failed -- /proc poll 1s fallback");
        g_nl_failed = 1;
    }

    startup_scan();
    klog("loop: %s", g_nl_failed ? "proc-poll 1s" : "netlink+pidfd (zero overhead)");

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
        if (nev < 0) { if (errno==EINTR) continue; klog("epoll_wait: %s",strerror(errno)); break; }

        if (nev == 0) {
            if (g_nl_failed) proc_scan_for_games();
            poll_active_games();
            continue;
        }

        for (int i = 0; i < nev; i++) {
            int fd = events[i].data.fd;
            if (fd == g_signal_fd)  { handle_signal();  continue; }
            if (fd == g_nl_sock)    { handle_netlink();  continue; }
            if (events[i].events & EPOLLIN) game_closed_by_pidfd(fd);
        }
    }

    /* Should never reach here, but clean up anyway */
    if (g_active_cnt > 0) { set_renderer(g_restore_mode); write_state(0); }
    unlink(PID_FILE);
    return 0;
}
