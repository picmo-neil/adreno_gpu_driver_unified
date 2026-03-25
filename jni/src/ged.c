/*
 * adreno_ged.c — Adreno GPU Driver: Game Exclusion Daemon
 *
 * ══════════════════════════════════════════════════════════════════════
 * ARCHITECTURE (Encore Tweaks-inspired)
 * ══════════════════════════════════════════════════════════════════════
 *
 * Previous approach (BROKEN / causing bootloops):
 *   Netlink CN_PROC: required CAP_NET_ADMIN, burst-dropped events,
 *   heavy /proc scanning every 500ms, fork() in set_renderer() races
 *   with CN_PROC FORK events, caused watchdog reboots on some ROMs.
 *
 * New approach — identical to Encore Tweaks:
 *
 *   Java companion (system_monitor.apk via app_process):
 *     Uses IActivityTaskManager.getFocusedRootTaskInfo() via reflection —
 *     the same internal API Android uses to track the foreground app.
 *     Polls every 500ms, writes to STATUS_FILE:
 *
 *       focused_app <pkg> <pid> <uid>
 *       screen_awake <0|1>
 *       battery_saver <0|1>
 *       zen_mode <int>
 *
 *   This C daemon (zero CPU overhead):
 *     • Watches STATUS_FILE via inotify IN_CLOSE_WRITE (blocks in kernel
 *       between writes — genuinely zero CPU idle overhead)
 *     • On file change: parse focused_app + PID; check exclusion list
 *     • game_open:  set debug.hwui.renderer=skiagl via resetprop
 *                   arm pidfd_open + epoll for instant process-death notification
 *     • game_close: restore debug.hwui.renderer=<restore_mode>
 *     • timerfd (5s): re-enforce skiagl while game active (GOS/OEM reset guard)
 *                     evict dead games for non-pidfd fallback path
 *     • signalfd: SIGTERM/SIGINT → clean shutdown; SIGCHLD → reap children;
 *                 SIGHUP → reload exclusion list
 *
 * TWO GROUPS of excluded packages:
 *
 *   GROUP 1 — Dual-VkDevice crash (UE4 / native-Vulkan games):
 *     Game engine creates VkDevice on RHI thread. HWUI in skiavk creates a
 *     second VkDevice in the same process → SIGSEGV in libgsl.so.
 *     Fix: skiagl while ANY process in the exclusion list is ALIVE (even
 *     backgrounded) so only the game's VkDevice exists.
 *
 *   GROUP 2 — Green scan-line artifact (Meta apps):
 *     HWUI Vulkan swapchain UBWC tile-layout mismatch with Meta native layers.
 *     Fix: skiagl while the Meta process is alive.
 *
 *   Both groups use the same policy: skiagl for the LIFETIME of the process,
 *   not just while it is focused.  Process death (pidfd epoll) triggers restore.
 *
 * Usage: adreno_ged <restore_mode> <moddir> <status_file>
 *   restore_mode: skiavk | skiagl
 *   moddir:       module directory (game_exclusion_list.sh is here)
 *   status_file:  full path written by system_monitor.apk
 */

#define _GNU_SOURCE

#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <fnmatch.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <sys/epoll.h>
#include <sys/inotify.h>
#include <sys/signalfd.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/timerfd.h>
#include <sys/types.h>
#include <sys/wait.h>

#include <sys/system_properties.h>   /* __system_property_get / PROP_VALUE_MAX */

/* ── pidfd_open syscall (Linux 5.3+; arm64=434, arm=434) ─────────────── */
#ifndef __NR_pidfd_open
#  define __NR_pidfd_open 434
#endif
static inline int sys_pidfd_open(pid_t pid, unsigned int flags) {
    return (int)syscall((long)__NR_pidfd_open,
                        (long)pid,
                        (long)(unsigned long)flags);
}

/* ════════════════════════════════════════════════════════════════════════
 * Constants
 * ════════════════════════════════════════════════════════════════════════ */

#define MAX_PKGS          256
#define MAX_PKG_LEN       256
#define MAX_ACTIVE         32
#define ENFORCE_SECS        5   /* re-enforce skiagl every N seconds */
#define INOTIFY_BUF       (16 * (sizeof(struct inotify_event) + NAME_MAX + 1))

#define PID_FILE          "/data/local/tmp/adreno_ged_pid"
#define STATE_FILE        "/data/local/tmp/adreno_ged_active"
#define KMSG_PATH         "/dev/kmsg"

/* ════════════════════════════════════════════════════════════════════════
 * Global state
 * ════════════════════════════════════════════════════════════════════════ */

/* ── Package exclusion list ─────────────────────────────────────────── */
static char  g_pkgs[MAX_PKGS][MAX_PKG_LEN];
static int   g_npkgs = 0;

/* ── Paths ──────────────────────────────────────────────────────────── */
static char  g_restore_mode[32]   = "skiavk";
static char  g_moddir[512]        = "";
static char  g_status_file[512]   = "";
static char  g_status_dir[512]    = "";   /* parent dir of status file  */
static char  g_status_fname[256]  = "";   /* just the filename          */

/* ── Event-loop fds ─────────────────────────────────────────────────── */
static int   g_epoll_fd   = -1;
static int   g_inotify_fd = -1;
static int   g_inotify_wd = -1;
static int   g_timer_fd   = -1;
static int   g_sig_fd     = -1;
static int   g_kmsg_fd    = -1;

/* ── Active game table ──────────────────────────────────────────────── */
typedef struct {
    pid_t pid;
    int   pidfd;                /* >=0 → epoll-tracked; -1 → /proc fallback */
    char  pkg[MAX_PKG_LEN];
} ActiveGame;

static ActiveGame g_active[MAX_ACTIVE];
static int        g_nactive    = 0;   /* entries in table           */
static int        g_active_cnt = 0;   /* currently "open" games     */

/* ════════════════════════════════════════════════════════════════════════
 * Logging
 * ════════════════════════════════════════════════════════════════════════ */

static void klog(const char *fmt, ...) {
    if (g_kmsg_fd < 0) return;
    char body[480];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(body, sizeof(body), fmt, ap);
    va_end(ap);
    char msg[512];
    int n = snprintf(msg, sizeof(msg), "[ADRENO-GED] %s\n", body);
    if (n > 0) (void)write(g_kmsg_fd, msg, (size_t)n);
}

/* ════════════════════════════════════════════════════════════════════════
 * Package matching (fnmatch glob support for com.epicgames.* etc.)
 * ════════════════════════════════════════════════════════════════════════ */

static int pkg_matches(const char *pkg) {
    int i;
    for (i = 0; i < g_npkgs; i++)
        if (fnmatch(g_pkgs[i], pkg, 0) == 0)
            return 1;
    return 0;
}

/* ════════════════════════════════════════════════════════════════════════
 * Package list loading
 * Parses the shell-script format used by game_exclusion_list.sh.
 * Supports both single-line (GAME_EXCLUSION_PKGS="a b c") and
 * multi-line heredoc forms.
 * ════════════════════════════════════════════════════════════════════════ */

static const char *DEFAULT_PKGS[] = {
    /* GROUP 1 — UE4 / native-Vulkan (dual-VkDevice crash) */
    "com.tencent.ig",
    "com.pubg.krmobile", "com.pubg.imobile", "com.pubg.newstate",
    "com.vng.pubgmobile", "com.rekoo.pubgm", "com.tencent.tmgp.pubgmhd",
    "com.epicgames.*",
    "com.activision.callofduty.shooter",
    "com.garena.game.codm", "com.tencent.tmgp.cod", "com.vng.codmvn",
    "com.miHoYo.GenshinImpact", "com.cognosphere.GenshinImpact",
    "com.miHoYo.enterprise.HSRPrism", "com.HoYoverse.hkrpgoversea",
    "com.levelinfinite.hotta", "com.proximabeta.mfh",
    "com.HoYoverse.Nap", "com.miHoYo.ZZZ",
    /* GROUP 2 — Meta apps (UBWC green-line artefact) */
    "com.facebook.katana", "com.facebook.orca",
    "com.facebook.lite",   "com.facebook.mlite",
    "com.instagram.android", "com.instagram.lite", "com.instagram.barcelona",
    "com.whatsapp", "com.whatsapp.w4b",
    NULL
};

static void load_from_file(const char *path) {
    FILE *f = fopen(path, "r");
    if (!f) return;

    int inside = 0, loaded = 0;
    char line[MAX_PKG_LEN + 64];

    while (fgets(line, (int)sizeof(line), f)) {
        /* strip trailing CR/LF */
        size_t len = strlen(line);
        while (len > 0 && (line[len-1] == '\n' || line[len-1] == '\r'))
            line[--len] = '\0';

        if (!inside) {
            if (!strstr(line, "GAME_EXCLUSION_PKGS=")) continue;
            inside = 1;

            /* single-line form: GAME_EXCLUSION_PKGS="pkg1 pkg2 ..." */
            char *q = strchr(line, '"');
            if (q) {
                q++; /* skip opening quote */
                char *end_q = strchr(q, '"');
                char tmp[MAX_PKG_LEN * 8];
                if (end_q) {
                    strncpy(tmp, q, (size_t)(end_q - q));
                    tmp[end_q - q] = '\0';
                } else {
                    strncpy(tmp, q, sizeof(tmp) - 1);
                    tmp[sizeof(tmp)-1] = '\0';
                }
                /* tokenise on whitespace */
                char *tok = strtok(tmp, " \t\n\r");
                while (tok && loaded < MAX_PKGS) {
                    if (isalpha((unsigned char)*tok)) {
                        strncpy(g_pkgs[loaded], tok, MAX_PKG_LEN-1);
                        g_pkgs[loaded++][MAX_PKG_LEN-1] = '\0';
                    }
                    tok = strtok(NULL, " \t\n\r");
                }
                if (end_q) break; /* single-line: done */
            }
            continue;
        }

        /* multi-line heredoc: closing quote ends the block */
        if (strchr(line, '"')) break;

        const char *p = line;
        while (*p == ' ' || *p == '\t') p++;
        if (*p == '\0' || *p == '#') continue;
        if (isalpha((unsigned char)*p) && loaded < MAX_PKGS) {
            strncpy(g_pkgs[loaded], p, MAX_PKG_LEN-1);
            g_pkgs[loaded++][MAX_PKG_LEN-1] = '\0';
        }
    }

    fclose(f);
    if (loaded > 0) {
        g_npkgs = loaded;
        klog("pkg list: %s (%d packages)", path, loaded);
    }
}

static void load_pkg_list(void) {
    char paths[4][512];
    snprintf(paths[0], sizeof(paths[0]),
             "/sdcard/Adreno_Driver/Config/game_exclusion_list.sh");
    snprintf(paths[1], sizeof(paths[1]),
             "/data/local/tmp/adreno_game_exclusion_list.sh");
    snprintf(paths[2], sizeof(paths[2]),
             "%s/game_exclusion_list.sh", g_moddir);
    paths[3][0] = '\0';

    g_npkgs = 0;
    int i;
    for (i = 0; i < 4 && paths[i][0]; i++) {
        load_from_file(paths[i]);
        if (g_npkgs > 0) return;
    }

    /* Built-in defaults */
    klog("no list file found — using built-in defaults");
    for (i = 0; DEFAULT_PKGS[i] && g_npkgs < MAX_PKGS; i++) {
        strncpy(g_pkgs[g_npkgs], DEFAULT_PKGS[i], MAX_PKG_LEN-1);
        g_pkgs[g_npkgs++][MAX_PKG_LEN-1] = '\0';
    }
    klog("defaults loaded (%d packages)", g_npkgs);
}

/* ════════════════════════════════════════════════════════════════════════
 * PID file / state file helpers
 * ════════════════════════════════════════════════════════════════════════ */

static void write_pid_file(void) {
    char buf[32];
    int n = snprintf(buf, sizeof(buf), "%d\n", (int)getpid());
    int fd = open(PID_FILE, O_WRONLY|O_CREAT|O_TRUNC|O_CLOEXEC, 0644);
    if (fd < 0) return;
    (void)write(fd, buf, (size_t)n);
    close(fd);
}

static void write_state(int active) {
    int fd = open(STATE_FILE, O_WRONLY|O_CREAT|O_TRUNC|O_CLOEXEC, 0644);
    if (fd < 0) return;
    (void)write(fd, active ? "1\n" : "0\n", 2);
    close(fd);
}

/* ════════════════════════════════════════════════════════════════════════
 * Renderer control — non-blocking (fork+exec resetprop)
 *
 * The parent returns immediately.  The child is reaped asynchronously
 * via SIGCHLD → signalfd in the event loop.
 * ════════════════════════════════════════════════════════════════════════ */

static void set_renderer(const char *mode) {
    pid_t child = fork();
    if (child == 0) {
        /* All parent fds carry O_CLOEXEC — auto-closed on exec. */
        char *argv[] = { "resetprop",
                         "debug.hwui.renderer",
                         (char *)mode, NULL };
        execv("/data/adb/magisk/resetprop",  argv);
        execv("/data/adb/ksu/bin/resetprop", argv);
        execv("/data/adb/ap/bin/resetprop",  argv);
        execv("/system/bin/resetprop",       argv);
        execvp("resetprop",                  argv);
        /* resetprop not available — fall back to setprop */
        char *sargv[] = { "setprop",
                          "debug.hwui.renderer",
                          (char *)mode, NULL };
        execvp("setprop", sargv);
        _exit(1);
    }
    /* child < 0: fork failed — not fatal, GOS re-enforcement will retry */
    if (child > 0)
        klog("renderer -> %s  (fork pid=%d)", mode, (int)child);
    else
        klog("WARN: fork failed setting renderer -> %s: %s", mode, strerror(errno));
}

/* ════════════════════════════════════════════════════════════════════════
 * /proc liveness check (fallback for kernels without pidfd_open)
 * ════════════════════════════════════════════════════════════════════════ */

static int pid_alive(pid_t pid) {
    char path[64];
    snprintf(path, sizeof(path), "/proc/%d", (int)pid);
    struct stat st;
    return stat(path, &st) == 0;
}

/* ════════════════════════════════════════════════════════════════════════
 * Game open / close
 * ════════════════════════════════════════════════════════════════════════ */

static void game_open(const char *pkg, pid_t pid) {
    int i;

    /* Reject duplicate PID */
    for (i = 0; i < g_nactive; i++)
        if (g_active[i].pid == pid) return;

    if (g_nactive >= MAX_ACTIVE) {
        klog("WARN: active table full — dropping %s pid=%d", pkg, (int)pid);
        return;
    }

    /* Arm pidfd for zero-overhead process-death notification.
     * Requires Linux 5.3+ (arm64 kernel 5.4 ships on Android 11+).
     * Falls back to periodic /proc check via timerfd if unavailable.      */
    int pfd = sys_pidfd_open(pid, 0);
    if (pfd >= 0) {
        /* Ensure FD_CLOEXEC so the fd doesn't leak into resetprop children. */
        int fl = fcntl(pfd, F_GETFD);
        if (fl >= 0) fcntl(pfd, F_SETFD, fl | FD_CLOEXEC);

        struct epoll_event ev;
        ev.events  = EPOLLIN;
        ev.data.fd = pfd;
        if (epoll_ctl(g_epoll_fd, EPOLL_CTL_ADD, pfd, &ev) < 0) {
            close(pfd);
            pfd = -1;  /* fall back to /proc poll */
        }
    }

    ActiveGame *ag = &g_active[g_nactive++];
    ag->pid   = pid;
    ag->pidfd = pfd;
    strncpy(ag->pkg, pkg, MAX_PKG_LEN-1);
    ag->pkg[MAX_PKG_LEN-1] = '\0';

    g_active_cnt++;
    if (g_active_cnt == 1) {
        set_renderer("skiagl");
        write_state(1);
    }

    klog("OPEN  pkg=%s  pid=%d  pidfd=%s  active=%d",
         pkg, (int)pid,
         pfd >= 0 ? "yes(epoll)" : "fallback(/proc)",
         g_active_cnt);
}

/* Remove the entry at @idx using swap-remove, decrement counters,
 * and restore the renderer when the last game exits.              */
static void game_close_at(int idx) {
    char  pkg[MAX_PKG_LEN];
    pid_t pid = g_active[idx].pid;

    strncpy(pkg, g_active[idx].pkg, MAX_PKG_LEN-1);
    pkg[MAX_PKG_LEN-1] = '\0';

    if (g_active[idx].pidfd >= 0) {
        epoll_ctl(g_epoll_fd, EPOLL_CTL_DEL, g_active[idx].pidfd, NULL);
        close(g_active[idx].pidfd);
    }

    /* Swap-remove: move last entry into this slot. */
    g_active[idx] = g_active[--g_nactive];

    if (g_active_cnt > 0) g_active_cnt--;
    if (g_active_cnt == 0) {
        set_renderer(g_restore_mode);
        write_state(0);
    }

    klog("CLOSE pkg=%s  pid=%d  active=%d", pkg, (int)pid, g_active_cnt);
}

static void game_close_by_pidfd(int pidfd) {
    int i;
    for (i = 0; i < g_nactive; i++)
        if (g_active[i].pidfd == pidfd) { game_close_at(i); return; }
}

/* Evict all active games whose process has died.
 * Used by the timerfd path (belt-and-suspenders for non-pidfd games)
 * and after any status change to ensure stale entries are purged.   */
static void evict_dead_games(void) {
    int i;
    for (i = g_nactive - 1; i >= 0; i--) {
        if (!pid_alive(g_active[i].pid)) {
            klog("evict: %s  pid=%d  dead",
                 g_active[i].pkg, (int)g_active[i].pid);
            game_close_at(i);
        }
    }
}

/* ════════════════════════════════════════════════════════════════════════
 * Status file parsing
 *
 * File written by system_monitor.apk every 500ms:
 *   focused_app <pkg> <pid> <uid>
 *   screen_awake <0|1>
 *   battery_saver <0|1>
 *   zen_mode <int>
 * ════════════════════════════════════════════════════════════════════════ */

typedef struct {
    char  focused_app[MAX_PKG_LEN];
    pid_t focused_pid;
    uid_t focused_uid;
    int   screen_awake;
} StatusInfo;

static int read_status(const char *path, StatusInfo *out) {
    FILE *f = fopen(path, "r");
    if (!f) return 0;

    memset(out, 0, sizeof(*out));
    int parsed = 0;
    char line[256];

    while (fgets(line, (int)sizeof(line), f)) {
        char pkg[MAX_PKG_LEN] = {};
        int  pid = 0, uid = 0, ival = 0;

        if (sscanf(line, "focused_app %255s %d %d", pkg, &pid, &uid) >= 1) {
            strncpy(out->focused_app, pkg, MAX_PKG_LEN-1);
            out->focused_app[MAX_PKG_LEN-1] = '\0';
            out->focused_pid = (pid_t)pid;
            out->focused_uid = (uid_t)uid;
            parsed = 1;
        } else if (sscanf(line, "screen_awake %d", &ival) == 1) {
            out->screen_awake = ival;
        }
    }

    fclose(f);
    return parsed;
}

/* ════════════════════════════════════════════════════════════════════════
 * Status change handler — called on every IN_CLOSE_WRITE event
 * ════════════════════════════════════════════════════════════════════════ */

static void handle_status_change(void) {
    StatusInfo si;
    if (!read_status(g_status_file, &si)) return;

    /* Skip sentinel / error values from system_monitor */
    if (!si.focused_app[0]                        ||
        strcmp(si.focused_app, "unknown") == 0    ||
        strcmp(si.focused_app, "none")    == 0)
        return;

    /* Always evict dead game processes first (handles silent exits). */
    evict_dead_games();

    klog("focus: %s  pid=%d", si.focused_app, (int)si.focused_pid);

    /* Open a new game session if the focused app matches the list
     * and has a valid PID (sysmon may temporarily write pid=0 during
     * process startup; we'll catch it on the next 500ms write).    */
    if (si.focused_pid > 0 && pkg_matches(si.focused_app)) {
        /* Check whether this exact PID is already tracked. */
        int already = 0, i;
        for (i = 0; i < g_nactive; i++)
            if (g_active[i].pid == si.focused_pid) { already = 1; break; }
        if (!already)
            game_open(si.focused_app, si.focused_pid);
    }
}

/* ════════════════════════════════════════════════════════════════════════
 * Inotify handler
 * ════════════════════════════════════════════════════════════════════════ */

static void handle_inotify(void) {
    char buf[INOTIFY_BUF]
         __attribute__((aligned(__alignof__(struct inotify_event))));

    ssize_t len = read(g_inotify_fd, buf, sizeof(buf));
    if (len < 0) {
        if (errno != EAGAIN && errno != EWOULDBLOCK)
            klog("inotify read: %s", strerror(errno));
        return;
    }

    ssize_t i = 0;
    while (i < len) {
        struct inotify_event *ev =
            (struct inotify_event *)(buf + i);

        /* Only act on our specific file, fully written (CLOSE_WRITE). */
        if (ev->wd == g_inotify_wd &&
            (ev->mask & IN_CLOSE_WRITE) &&
            ev->len > 0 &&
            strcmp(ev->name, g_status_fname) == 0) {
            handle_status_change();
        }

        i += (ssize_t)(sizeof(struct inotify_event) + ev->len);
    }
}

/* ════════════════════════════════════════════════════════════════════════
 * Timer handler — fires every ENFORCE_SECS seconds
 * ════════════════════════════════════════════════════════════════════════ */

static void handle_timer(void) {
    uint64_t expirations;
    (void)read(g_timer_fd, &expirations, sizeof(expirations));

    if (g_active_cnt <= 0) return;

    /* Evict any games that died without triggering a pidfd event
     * (non-pidfd fallback path; also belt-and-suspenders for pidfd).  */
    evict_dead_games();

    if (g_active_cnt <= 0) return;   /* all games exited during eviction */

    /* GOS / OEM re-enforcement: some Samsung/MIUI perf daemons reset
     * debug.hwui.renderer between our set_renderer() calls.
     * Re-read via system_properties (no fork/popen needed).          */
    char cur[PROP_VALUE_MAX] = "";
    __system_property_get("debug.hwui.renderer", cur);
    if (cur[0] && strcmp(cur, "skiagl") != 0) {
        klog("GOS-ENFORCE: was '%s', re-applying skiagl", cur);
        set_renderer("skiagl");
    }
}

/* ════════════════════════════════════════════════════════════════════════
 * Cleanup — called before exit
 * ════════════════════════════════════════════════════════════════════════ */

static void do_cleanup(void) {
    if (g_active_cnt > 0) {
        set_renderer(g_restore_mode);
        write_state(0);
    }

    /* Reap outstanding renderer children */
    while (waitpid(-1, NULL, WNOHANG) > 0) {}

    int i;
    for (i = 0; i < g_nactive; i++)
        if (g_active[i].pidfd >= 0) close(g_active[i].pidfd);

    if (g_inotify_wd >= 0) inotify_rm_watch(g_inotify_fd, g_inotify_wd);
    if (g_inotify_fd >= 0) { close(g_inotify_fd); g_inotify_fd = -1; }
    if (g_timer_fd   >= 0) { close(g_timer_fd);   g_timer_fd   = -1; }
    if (g_sig_fd     >= 0) { close(g_sig_fd);     g_sig_fd     = -1; }
    if (g_epoll_fd   >= 0) { close(g_epoll_fd);   g_epoll_fd   = -1; }

    unlink(PID_FILE);
}

/* ════════════════════════════════════════════════════════════════════════
 * Signal handler — driven by signalfd, never called in signal context
 * ════════════════════════════════════════════════════════════════════════ */

static void handle_signals(void) {
    struct signalfd_siginfo si;
    while (read(g_sig_fd, &si, sizeof(si)) == (ssize_t)sizeof(si)) {
        switch (si.ssi_signo) {
        case SIGCHLD:
            /* Reap resetprop / setprop children asynchronously. */
            while (waitpid(-1, NULL, WNOHANG) > 0) {}
            break;
        case SIGHUP:
            klog("SIGHUP: reloading package list");
            load_pkg_list();
            klog("reload done (%d packages)", g_npkgs);
            break;
        case SIGTERM:
        case SIGINT:
            klog("signal %u: shutting down", si.ssi_signo);
            do_cleanup();
            _exit(0);
        default:
            break;
        }
    }
}

/* ════════════════════════════════════════════════════════════════════════
 * Singleton guard
 * ════════════════════════════════════════════════════════════════════════ */

static int already_running(void) {
    int fd = open(PID_FILE, O_RDONLY|O_CLOEXEC);
    if (fd < 0) return 0;
    char buf[32] = {0};
    (void)read(fd, buf, sizeof(buf)-1);
    close(fd);
    pid_t existing = (pid_t)atoi(buf);
    if (existing <= 0 || existing == getpid()) return 0;
    return kill(existing, 0) == 0;
}

/* ════════════════════════════════════════════════════════════════════════
 * main
 * ════════════════════════════════════════════════════════════════════════ */

int main(int argc, char *argv[]) {
    /* ── Parse arguments ──────────────────────────────────────────── */
    if (argc < 4) {
        fprintf(stderr,
                "Usage: %s <restore_mode> <moddir> <status_file>\n"
                "  restore_mode: skiavk | skiagl\n"
                "  moddir:       module directory (for game_exclusion_list.sh)\n"
                "  status_file:  path written by system_monitor.apk\n",
                argv[0]);
        return 1;
    }

    strncpy(g_restore_mode, argv[1], sizeof(g_restore_mode)-1);
    g_restore_mode[sizeof(g_restore_mode)-1] = '\0';
    /* Normalise legacy mode names */
    if (strcmp(g_restore_mode, "skiavkthreaded") == 0 ||
        strcmp(g_restore_mode, "skiavk_all")     == 0)
        strncpy(g_restore_mode, "skiavk", sizeof(g_restore_mode)-1);
    if (strcmp(g_restore_mode, "skiaglthreaded") == 0)
        strncpy(g_restore_mode, "skiagl", sizeof(g_restore_mode)-1);

    strncpy(g_moddir,      argv[2], sizeof(g_moddir)-1);
    g_moddir[sizeof(g_moddir)-1] = '\0';
    strncpy(g_status_file, argv[3], sizeof(g_status_file)-1);
    g_status_file[sizeof(g_status_file)-1] = '\0';

    /* ── Open /dev/kmsg for logging ───────────────────────────────── */
    g_kmsg_fd = open(KMSG_PATH, O_WRONLY|O_CLOEXEC);

    /* ── Singleton ────────────────────────────────────────────────── */
    if (already_running()) {
        klog("already running — exiting duplicate");
        return 0;
    }

    /* ── Package list ─────────────────────────────────────────────── */
    load_pkg_list();
    if (g_npkgs == 0) {
        klog("FATAL: empty package list");
        return 1;
    }

    write_pid_file();
    write_state(0);
    klog("started  pid=%d  restore=%s  packages=%d",
         (int)getpid(), g_restore_mode, g_npkgs);
    klog("watching: %s", g_status_file);

    /* ── Block handled signals before creating signalfd ──────────── */
    sigset_t mask;
    sigemptyset(&mask);
    sigaddset(&mask, SIGTERM);
    sigaddset(&mask, SIGINT);
    sigaddset(&mask, SIGHUP);
    sigaddset(&mask, SIGCHLD);
    sigprocmask(SIG_BLOCK, &mask, NULL);
    signal(SIGPIPE, SIG_IGN);

    /* ── epoll ────────────────────────────────────────────────────── */
    g_epoll_fd = epoll_create1(EPOLL_CLOEXEC);
    if (g_epoll_fd < 0) {
        klog("epoll_create1: %s", strerror(errno));
        return 1;
    }

    /* ── signalfd ─────────────────────────────────────────────────── */
    g_sig_fd = signalfd(-1, &mask, SFD_CLOEXEC|SFD_NONBLOCK);
    if (g_sig_fd < 0) {
        klog("signalfd: %s", strerror(errno));
        return 1;
    }
    {
        struct epoll_event ev = { .events = EPOLLIN, .data.fd = g_sig_fd };
        epoll_ctl(g_epoll_fd, EPOLL_CTL_ADD, g_sig_fd, &ev);
    }

    /* ── timerfd (ENFORCE_SECS repeating) ────────────────────────── */
    g_timer_fd = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC|TFD_NONBLOCK);
    if (g_timer_fd < 0) {
        klog("timerfd_create: %s", strerror(errno));
        return 1;
    }
    {
        struct itimerspec its;
        its.it_value.tv_sec  = ENFORCE_SECS;
        its.it_value.tv_nsec = 0;
        its.it_interval      = its.it_value;
        timerfd_settime(g_timer_fd, 0, &its, NULL);
        struct epoll_event ev = { .events = EPOLLIN, .data.fd = g_timer_fd };
        epoll_ctl(g_epoll_fd, EPOLL_CTL_ADD, g_timer_fd, &ev);
    }

    /* ── inotify: watch the directory containing the status file ──── */
    {
        char *last_slash = strrchr(g_status_file, '/');
        if (!last_slash) {
            klog("FATAL: status_file has no directory component: %s",
                 g_status_file);
            return 1;
        }
        size_t dlen = (size_t)(last_slash - g_status_file);
        strncpy(g_status_dir,   g_status_file, dlen);
        g_status_dir[dlen] = '\0';
        strncpy(g_status_fname, last_slash + 1, sizeof(g_status_fname)-1);
        g_status_fname[sizeof(g_status_fname)-1] = '\0';

        /* Ensure directory exists */
        mkdir(g_status_dir, 0755);

        g_inotify_fd = inotify_init1(IN_NONBLOCK|IN_CLOEXEC);
        if (g_inotify_fd < 0) {
            klog("inotify_init1: %s", strerror(errno));
            return 1;
        }

        /* Watch for file-close-write events in the directory.
         * We filter by filename in handle_inotify() so only status
         * file changes trigger the handler.                          */
        g_inotify_wd = inotify_add_watch(g_inotify_fd,
                                          g_status_dir,
                                          IN_CLOSE_WRITE);
        if (g_inotify_wd < 0) {
            klog("inotify_add_watch(%s): %s",
                 g_status_dir, strerror(errno));
            return 1;
        }

        struct epoll_event ev = { .events = EPOLLIN, .data.fd = g_inotify_fd };
        epoll_ctl(g_epoll_fd, EPOLL_CTL_ADD, g_inotify_fd, &ev);
    }

    klog("loop ready  inotify=%s/%s  enforce=%ds",
         g_status_dir, g_status_fname, ENFORCE_SECS);

    /* Initial read: if the file already exists from a prior sysmon
     * run, process it immediately so we don't miss games already
     * running when the GED starts.                                   */
    handle_status_change();

    /* ════════════════════════════════════════════════════════════════
     * Main event loop
     * ════════════════════════════════════════════════════════════════ */
    struct epoll_event events[64];
    for (;;) {
        int nev = epoll_wait(g_epoll_fd, events, 64, -1);
        if (nev < 0) {
            if (errno == EINTR) continue;
            klog("epoll_wait: %s", strerror(errno));
            break;
        }

        int i;
        for (i = 0; i < nev; i++) {
            int fd = events[i].data.fd;

            if      (fd == g_sig_fd)     handle_signals();
            else if (fd == g_timer_fd)   handle_timer();
            else if (fd == g_inotify_fd) handle_inotify();
            else {
                /* Must be a pidfd for a tracked game process.
                 * EPOLLIN fires when the process has exited.          */
                game_close_by_pidfd(fd);
            }
        }
    }

    do_cleanup();
    return 0;
}
