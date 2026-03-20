/*
 * adreno_ged — Adreno Game Exclusion Daemon
 *
 * Switches debug.hwui.renderer to skiagl when an excluded game or app
 * enters the foreground, then restores the configured renderer once all
 * excluded processes have exited.
 *
 * ══════════════════════════════════════════════════════════════════════
 * DESIGN — ENCORE-INSPIRED PURE-C ARCHITECTURE
 * ══════════════════════════════════════════════════════════════════════
 *
 * Encore Tweaks (github.com/Rem01Gaming/encore) uses a Java companion
 * daemon (app_process + system_monitor.apk) to call ActivityManager and
 * write the currently-focused app to a status file.  Its C++ daemon then
 * watches that file via inotify and acts on focus changes.
 *
 * We replicate the same "which app is active" signal in pure C using
 * oom_score_adj.  ActivityManagerService continuously updates this value:
 *
 *   /proc/[pid]/oom_score_adj values (AOSP ProcessList.java, stable since
 *   Android 5.0):
 *     0   FOREGROUND_APP_ADJ  — top app, receiving input
 *     100 VISIBLE_APP_ADJ     — visible (split-screen, overlay, PiP)
 *     200 PERCEPTIBLE_APP_ADJ — audible in background, navigation GPS
 *     ≥200 services, cached, empty processes
 *
 * Reading oom_score_adj ≤ 100 is structurally equivalent to Encore's
 * "focused_app" query.  It correctly rejects persistent background
 * service processes (e.g. Facebook :service has adj ≥ 200 while the
 * app is not open).
 *
 * ── Detection pipeline ────────────────────────────────────────────────
 *
 *  PRIMARY  Netlink CN_PROC  FORK + COMM + EXIT  (zero CPU overhead)
 *           On PROC_EVENT_COMM for a matching package:
 *             ● adj ≤ 100 → game_open() immediately (minimum latency)
 *             ● adj > 100 → deferred; proc_scan catches it at next tick
 *
 *  SECONDARY  timerfd 500 ms periodic /proc scan
 *           ● Startup: games already running when daemon started
 *           ● GROUP-2 Meta apps coming to foreground from persistent
 *             background (oom_score_adj change, no new COMM event)
 *           ● Missed netlink events (belt-and-suspenders)
 *           Structurally equivalent to Encore's inotify-on-status-file.
 *
 *  DEATH    pidfd_open + epoll  (identical to Encore's PIDTracker)
 *           Kernel wakes epoll the instant the process exits.
 *           Fallback: /proc existence check every 500 ms tick.
 *
 *  BACKUP   PROC_EVENT_EXIT — instant exit notification from kernel.
 *
 * ── Two groups of excluded packages ──────────────────────────────────
 *
 *  GROUP 1 — UE4 / native-Vulkan games (PUBG, Genshin, CoD, …)
 *    Problem: game engine creates VkDevice on RHI thread; HWUI in
 *    skiavk creates a second VkDevice in the same process → SIGSEGV.
 *    Fix: skiagl while any such process is alive, because vkDestroyDevice
 *    is only called on process exit.
 *
 *  GROUP 2 — Meta apps (Facebook, Instagram, WhatsApp)
 *    Problem: HWUI Vulkan swapchain uses UBWC tile layout incompatible
 *    with Meta native render layers → green scan-line artefact.
 *    Fix: skiagl while any Meta process is in the foreground.
 *    These processes are persistent; oom_score_adj is the only signal.
 *
 * ── Bugs fixed vs initial ged.c ──────────────────────────────────────
 *
 *  BUG-A  PROC_EVENT_COMM: missing pid == tgid guard → worker-thread
 *         COMM events (RenderThread, FinalizerDaemon, …) consumed pending
 *         entries before the main thread sent its package name.
 *
 *  BUG-B  comm_could_be_app() called AFTER pending_remove() →
 *         "<pre-initialized>" COMM consumed the entry 1-15 s too early.
 *
 *  BUG-C  Zygote restart detection placed after comm_could_be_app() —
 *         dead code; "zygote64" has no dot, fails the filter.
 *
 *  BUG-D  waitpid() inside set_renderer child-path blocked the epoll
 *         loop ~200 ms → ENOBUFS netlink drops → tight spin → watchdog.
 *         Fixed: SIGCHLD via signalfd, children reaped asynchronously.
 *
 *  BUG-E  On ENOBUFS the netlink fd was left in epoll → recv returned
 *         -1 on every wakeup → infinite tight spin → 100% CPU.
 *
 *  BUG-F  No foreground verification → Meta background service COMM
 *         events (adj ≥ 200) indistinguishable from foreground launches.
 *
 *  BUG-G  time(NULL) used for pending TTL → vulnerable to system clock
 *         changes.  Fixed: CLOCK_MONOTONIC via clock_gettime().
 *
 *  BUG-H  pidfd_open(pid, 0) does not set FD_CLOEXEC on kernels < 5.10.
 *         Fixed: explicit fcntl(F_SETFD, FD_CLOEXEC) after every open.
 *
 *  BUG-I  proc_scan eviction only checked pidfd==-1 games; epoll-tracked
 *         games could get stuck if the epoll event was missed.
 *         Fixed: evict ALL active games whose /proc entry has vanished.
 *
 *  BUG-J  Pending table expired only inside pending_add(); under low
 *         fork rate it could fill with stale entries and drop new ones.
 *         Fixed: pending_expire() called on every 500 ms timer tick.
 *
 *  BUG-K  NL_BUF_SIZE 8192 too small for burst of events at boot.
 *         Fixed: raised to 16384 (≈ 200 CN_PROC events per recv).
 *
 * USAGE:  adreno_ged <restore-mode> [MODDIR]
 *         restore-mode: skiavk | skiavk_all | skiavkthreaded | skiagl
 *         MODDIR: module directory path (for game_exclusion_list.sh)
 */

#define _GNU_SOURCE

#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <fnmatch.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <sys/epoll.h>
#include <sys/signalfd.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/timerfd.h>
#include <sys/types.h>
#include <sys/wait.h>

#include <linux/cn_proc.h>
#include <linux/connector.h>
#include <linux/netlink.h>

#include <sys/system_properties.h>

/* ── pidfd_open syscall number ──────────────────────────────────────── */
#ifndef __NR_pidfd_open
#  define __NR_pidfd_open 434   /* arm64 and arm both use 434 */
#endif
static inline int sys_pidfd_open(pid_t pid, unsigned int flags)
{
    return (int)syscall((long)__NR_pidfd_open, (long)pid,
                        (long)(unsigned long)flags);
}

/* ════════════════════════════════════════════════════════════════════════
 * Constants
 * ════════════════════════════════════════════════════════════════════════ */

#define MAX_PKGS      256
#define MAX_PKG_LEN   256
#define MAX_ACTIVE     64
#define MAX_ZYGOTES     4
#define MAX_PENDING   256

/*
 * oom_score_adj threshold.  Values from AOSP ProcessList.java (stable
 * since Android 5.0):
 *   FOREGROUND_APP_ADJ  =   0
 *   VISIBLE_APP_ADJ     = 100
 *   PERCEPTIBLE_APP_ADJ = 200   ← first background tier
 * Threshold 100 captures exactly the processes the user can see.
 */
#define FOREGROUND_ADJ_THRESHOLD 100

/* NL_BUF_SIZE: BUG-K fix — 16384 holds ≈200 CN_PROC events per recv. */
#define NL_BUF_SIZE     16384
#define MAX_EPOLL_EVENTS 64

/* timerfd: fires every 500 ms */
#define TIMER_INTERVAL_MS 500

/* /proc scan every PROC_SCAN_TICKS × 500 ms = 1 s */
#define PROC_SCAN_TICKS   2

/* GOS re-enforcement every ENFORCE_TICKS × 500 ms = 5 s */
#define ENFORCE_TICKS    10

/* Pending TTL in seconds (BUG-G: CLOCK_MONOTONIC milliseconds) */
#define PENDING_TTL_MS  (20 * 1000LL)

#define PID_FILE    "/data/local/tmp/adreno_ged_pid"
#define STATE_FILE  "/data/local/tmp/adreno_ged_active"
#define KMSG_PATH   "/dev/kmsg"

/* ════════════════════════════════════════════════════════════════════════
 * Package list
 * ════════════════════════════════════════════════════════════════════════ */

static char g_pkgs[MAX_PKGS][MAX_PKG_LEN];
static int  g_npkgs = 0;

#define LIST_PATHS_MAX 4
static const char *g_list_paths[LIST_PATHS_MAX] = {
    "/sdcard/Adreno_Driver/Config/game_exclusion_list.sh",
    "/data/local/tmp/adreno_game_exclusion_list.sh",
    NULL, /* filled from MODDIR at startup */
    NULL  /* sentinel */
};

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

/* ════════════════════════════════════════════════════════════════════════
 * Global event-loop fds
 * ════════════════════════════════════════════════════════════════════════ */

static int g_epoll_fd  = -1;
static int g_nl_sock   = -1;
static int g_sig_fd    = -1;
static int g_timer_fd  = -1;
static int g_kmsg_fd   = -1;
static int g_nl_failed = 0;

static char g_restore_hwui[32] = "skiavk";
static char g_moddir[512]      = {0};

/* ── Active game table ──────────────────────────────────────────────── */
typedef struct {
    pid_t pid;
    int   pidfd;          /* ≥ 0: epoll-tracked; -1: /proc fallback */
    char  pkg[MAX_PKG_LEN];
} ActiveGame;

static ActiveGame g_active[MAX_ACTIVE];
static int        g_nactive    = 0;
static int        g_active_cnt = 0;

/* ── Zygote PID set ─────────────────────────────────────────────────── */
static pid_t g_zygote_pids[MAX_ZYGOTES];
static int   g_nzygotes = 0;

/* ── Pending-fork table ─────────────────────────────────────────────── */
typedef struct {
    pid_t    pid;
    long long born_ms;   /* CLOCK_MONOTONIC milliseconds — BUG-G fix */
} Pending;

static Pending g_pending[MAX_PENDING];
static int     g_npending = 0;

/* ── Timer counter ──────────────────────────────────────────────────── */
static int g_timer_ticks = 0;

/* ════════════════════════════════════════════════════════════════════════
 * Monotonic clock (BUG-G fix: immune to system clock changes)
 * ════════════════════════════════════════════════════════════════════════ */

static long long monotonic_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000LL + (long long)(ts.tv_nsec / 1000000);
}

/* ════════════════════════════════════════════════════════════════════════
 * Logging
 * ════════════════════════════════════════════════════════════════════════ */

static void klog(const char *fmt, ...)
{
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
 * /proc helpers
 * ════════════════════════════════════════════════════════════════════════ */

/*
 * Read argv[0] from /proc/[pid]/cmdline into @out.
 * Strips ":processname" suffix:  "com.foo:worker" → "com.foo"
 * Returns 1 on success, 0 if the entry is missing or a kernel thread.
 */
static int read_cmdline(pid_t pid, char *out, size_t sz)
{
    char path[64];
    snprintf(path, sizeof(path), "/proc/%d/cmdline", (int)pid);
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return 0;
    ssize_t n = read(fd, out, (ssize_t)sz - 1);
    close(fd);
    if (n <= 0) return 0;
    out[n] = '\0';
    out[strlen(out)] = '\0';   /* truncate at first embedded NUL (argv[0] end) */
    char *colon = strchr(out, ':');
    if (colon) *colon = '\0';
    return (out[0] != '\0' && out[0] != '[');
}

/*
 * Read /proc/[pid]/oom_score_adj.
 * Returns INT_MAX on any error (treat as background or already gone).
 */
static int read_oom_adj(pid_t pid)
{
    char path[64];
    snprintf(path, sizeof(path), "/proc/%d/oom_score_adj", (int)pid);
    FILE *f = fopen(path, "r");
    if (!f) return 0x7fffffff;
    int adj = 0x7fffffff;
    (void)fscanf(f, "%d", &adj);
    fclose(f);
    return adj;
}

/* Returns 1 if /proc/[pid] exists (process alive). */
static int pid_alive(pid_t pid)
{
    char path[64];
    snprintf(path, sizeof(path), "/proc/%d", (int)pid);
    struct stat st;
    return (stat(path, &st) == 0);
}

/* ════════════════════════════════════════════════════════════════════════
 * Package matching
 * ════════════════════════════════════════════════════════════════════════ */

static int pkg_matches(const char *pkg)
{
    int i;
    for (i = 0; i < g_npkgs; i++)
        if (fnmatch(g_pkgs[i], pkg, 0) == 0)
            return 1;
    return 0;
}

/*
 * Heuristic pre-filter on a 15-char COMM string to avoid the more
 * expensive read_cmdline() for every rename event.
 * Returns 1 if the comm could plausibly be an Android package name.
 */
static int comm_could_be_app(const char *comm)
{
    if (!isalpha((unsigned char)comm[0])) return 0;
    if (strchr(comm, '.'))               return 1;   /* has a dot */
    return (strlen(comm) >= 14);                     /* likely truncated */
}

/* ════════════════════════════════════════════════════════════════════════
 * PID file / state file
 * ════════════════════════════════════════════════════════════════════════ */

static void write_pid_file(void)
{
    char buf[32];
    int n = snprintf(buf, sizeof(buf), "%d\n", (int)getpid());
    int fd = open(PID_FILE, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0) return;
    (void)write(fd, buf, (size_t)n);
    close(fd);
}

static void write_state(int active)
{
    int fd = open(STATE_FILE, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0) return;
    (void)write(fd, active ? "1\n" : "0\n", 2);
    close(fd);
}

static int daemon_already_running(void)
{
    int fd = open(PID_FILE, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return 0;
    char buf[32] = {0};
    (void)read(fd, buf, sizeof(buf) - 1);
    close(fd);
    pid_t existing = (pid_t)atoi(buf);
    if (existing <= 0 || existing == getpid()) return 0;
    return (kill(existing, 0) == 0);
}

/* ════════════════════════════════════════════════════════════════════════
 * Renderer control — non-blocking (BUG-D fix)
 *
 * fork() + exec resetprop/setprop.  All parent fds carry O_CLOEXEC so
 * they close automatically on exec — no manual close loop.  The child
 * is reaped asynchronously via SIGCHLD through signalfd; the event loop
 * is never blocked.
 * ════════════════════════════════════════════════════════════════════════ */

static void set_renderer(const char *mode)
{
    pid_t child = fork();
    if (child == 0) {
        /* O_CLOEXEC on all parent fds means they close on exec automatically. */
        char *argv[] = { "resetprop", "debug.hwui.renderer", (char *)mode, NULL };
        execv("/data/adb/magisk/resetprop",  argv);
        execv("/data/adb/ksu/bin/resetprop", argv);
        execv("/data/adb/ap/bin/resetprop",  argv);
        execv("/system/bin/resetprop",       argv);
        execvp("resetprop", argv);
        /* resetprop not available: fall back to setprop */
        char *sargv[] = { "setprop", "debug.hwui.renderer", (char *)mode, NULL };
        execvp("setprop", sargv);
        _exit(1);
    } else if (child < 0) {
        /* fork failed: try setprop via a second fork */
        pid_t fb = fork();
        if (fb == 0) {
            char *sargv[] = { "setprop", "debug.hwui.renderer", (char *)mode, NULL };
            execvp("setprop", sargv);
            _exit(1);
        }
    }
    /* Parent returns immediately; child reaped on SIGCHLD. */
    klog("renderer -> %s", mode);
}

/* ════════════════════════════════════════════════════════════════════════
 * Game open / close
 * ════════════════════════════════════════════════════════════════════════ */

static void game_open(const char *pkg, pid_t pid)
{
    int i;
    /* Reject duplicate PID */
    for (i = 0; i < g_nactive; i++)
        if (g_active[i].pid == pid) return;

    if (g_nactive >= MAX_ACTIVE) {
        klog("WARN: active table full, dropping %s PID=%d", pkg, (int)pid);
        return;
    }

    /*
     * Open a pidfd for instant zero-overhead exit detection.
     * This is identical to Encore's PIDTracker mechanism:
     *   pidfd + epoll wakes the instant the process dies.
     *
     * BUG-H fix: pidfd_open(pid, 0) does not set FD_CLOEXEC on kernels
     * earlier than 5.10 (where PIDFD_CLOEXEC was introduced).  Set it
     * explicitly so the fd does not leak into the resetprop child.
     */
    int pfd = sys_pidfd_open(pid, 0);
    if (pfd >= 0) {
        if (fcntl(pfd, F_SETFD, FD_CLOEXEC) < 0) {
            close(pfd);
            pfd = -1;
        }
    }

    ActiveGame *ag = &g_active[g_nactive];
    ag->pid   = pid;
    ag->pidfd = pfd;
    strncpy(ag->pkg, pkg, MAX_PKG_LEN - 1);
    ag->pkg[MAX_PKG_LEN - 1] = '\0';
    g_nactive++;

    if (pfd >= 0) {
        struct epoll_event ev;
        ev.events  = EPOLLIN;
        ev.data.fd = pfd;
        if (epoll_ctl(g_epoll_fd, EPOLL_CTL_ADD, pfd, &ev) < 0) {
            close(pfd);
            ag->pidfd = -1;   /* fall back to /proc poll */
        }
    }

    g_active_cnt++;
    if (g_active_cnt == 1) {
        set_renderer("skiagl");
        write_state(1);
    }

    klog("OPEN  %s  PID=%d  adj=%d  active=%d  pidfd=%s",
         pkg, (int)pid, read_oom_adj(pid), g_active_cnt,
         (ag->pidfd >= 0) ? "yes" : "no(fallback)");
}

/* Remove the entry at index @idx and update active count / renderer. */
static void close_game_at(int idx)
{
    char  pkg[MAX_PKG_LEN];
    pid_t pid = g_active[idx].pid;

    strncpy(pkg, g_active[idx].pkg, MAX_PKG_LEN - 1);
    pkg[MAX_PKG_LEN - 1] = '\0';

    if (g_active[idx].pidfd >= 0) {
        epoll_ctl(g_epoll_fd, EPOLL_CTL_DEL, g_active[idx].pidfd, NULL);
        close(g_active[idx].pidfd);
    }

    /* Swap-remove to avoid shifting */
    g_active[idx] = g_active[--g_nactive];

    if (g_active_cnt > 0) g_active_cnt--;
    if (g_active_cnt == 0) {
        set_renderer(g_restore_hwui);
        write_state(0);
    }

    klog("CLOSE %s  PID=%d  active=%d", pkg, (int)pid, g_active_cnt);
}

static void game_closed_by_pidfd(int pidfd)
{
    int i;
    for (i = 0; i < g_nactive; i++)
        if (g_active[i].pidfd == pidfd) { close_game_at(i); return; }
}

static void game_closed_by_pid(pid_t pid)
{
    int i;
    for (i = 0; i < g_nactive; i++)
        if (g_active[i].pid == pid) { close_game_at(i); return; }
}

/* ════════════════════════════════════════════════════════════════════════
 * Zygote tracking
 * ════════════════════════════════════════════════════════════════════════ */

static void add_zygote(pid_t pid)
{
    int i;
    for (i = 0; i < g_nzygotes; i++)
        if (g_zygote_pids[i] == pid) return;
    if (g_nzygotes < MAX_ZYGOTES)
        g_zygote_pids[g_nzygotes++] = pid;
}

static int is_zygote(pid_t pid)
{
    int i;
    for (i = 0; i < g_nzygotes; i++)
        if (g_zygote_pids[i] == pid) return 1;
    return 0;
}

static void discover_zygotes(void)
{
    DIR *d;
    struct dirent *de;

    g_nzygotes = 0;
    d = opendir("/proc");
    if (!d) return;

    while ((de = readdir(d)) != NULL) {
        int ok = 1;
        const char *p = de->d_name;
        char cmd[32];
        pid_t pid;

        if (!isdigit((unsigned char)*p)) continue;
        while (*p) { if (!isdigit((unsigned char)*p++)) { ok = 0; break; } }
        if (!ok) continue;

        pid = (pid_t)atoi(de->d_name);
        if (!read_cmdline(pid, cmd, sizeof(cmd))) continue;
        if (!strcmp(cmd, "zygote64") || !strcmp(cmd, "zygote") ||
            !strcmp(cmd, "zygote32")) {
            add_zygote(pid);
            klog("zygote: %s PID=%d", cmd, (int)pid);
        }
    }
    closedir(d);

    if (g_nzygotes == 0)
        klog("WARN: no zygote found; tracking all forks as candidates");
}

/* ════════════════════════════════════════════════════════════════════════
 * Pending-fork table
 * ════════════════════════════════════════════════════════════════════════ */

/*
 * Evict entries older than PENDING_TTL_MS milliseconds.
 * Called from both pending_add() and the 500 ms timer tick (BUG-J fix).
 */
static void pending_expire(void)
{
    long long now = monotonic_ms();
    int i, w = 0;
    for (i = 0; i < g_npending; i++) {
        if ((now - g_pending[i].born_ms) < PENDING_TTL_MS)
            g_pending[w++] = g_pending[i];
    }
    g_npending = w;
}

static void pending_add(pid_t pid)
{
    pending_expire();
    if (g_npending < MAX_PENDING) {
        g_pending[g_npending].pid     = pid;
        g_pending[g_npending].born_ms = monotonic_ms();
        g_npending++;
    }
}

/* Returns 1 and removes the entry if pid is found; 0 otherwise. */
static int pending_remove(pid_t pid)
{
    int i;
    for (i = 0; i < g_npending; i++) {
        if (g_pending[i].pid == pid) {
            g_pending[i] = g_pending[--g_npending];
            return 1;
        }
    }
    return 0;
}

/* ════════════════════════════════════════════════════════════════════════
 * Package list loading (defined before handle_signals so SIGHUP can call
 * load_pkg_list() directly without a forward declaration)
 * ════════════════════════════════════════════════════════════════════════ */

static void load_from_file(const char *path)
{
    FILE *f;
    int inside = 0, loaded = 0;
    char line[MAX_PKG_LEN + 64];

    f = fopen(path, "r");
    if (!f) return;

    while (fgets(line, (int)sizeof(line), f)) {
        size_t len = strlen(line);
        while (len > 0 && (line[len-1] == '\n' || line[len-1] == '\r'))
            line[--len] = '\0';

        if (!inside) {
            if (strstr(line, "GAME_EXCLUSION_PKGS=")) {
                inside = 1;
                /* Single-line form: GAME_EXCLUSION_PKGS="pkg1 pkg2" */
                char *q = strchr(line, '"');
                if (q && *(++q) && *q != '"' &&
                    isalpha((unsigned char)*q) && loaded < MAX_PKGS) {
                    strncpy(g_pkgs[loaded], q, MAX_PKG_LEN - 1);
                    g_pkgs[loaded++][MAX_PKG_LEN - 1] = '\0';
                }
            }
            continue;
        }

        /* Multi-line heredoc ends at the closing quote */
        if (strchr(line, '"')) break;

        {
            const char *p = line;
            while (*p == ' ' || *p == '\t') p++;
            if (!*p || *p == '#' || !isalpha((unsigned char)*p)) continue;
            if (loaded < MAX_PKGS) {
                strncpy(g_pkgs[loaded], p, MAX_PKG_LEN - 1);
                g_pkgs[loaded++][MAX_PKG_LEN - 1] = '\0';
            }
        }
    }

    fclose(f);
    if (loaded > 0) {
        g_npkgs = loaded;
        klog("pkg list: %s  (%d packages)", path, loaded);
    }
}

static void load_pkg_list(void)
{
    int i;
    g_npkgs = 0;
    for (i = 0; g_list_paths[i] != NULL; i++) {
        load_from_file(g_list_paths[i]);
        if (g_npkgs > 0) return;
    }
    klog("no list file found — using built-in defaults");
    for (i = 0; DEFAULT_PKGS[i] != NULL && g_npkgs < MAX_PKGS; i++) {
        strncpy(g_pkgs[g_npkgs], DEFAULT_PKGS[i], MAX_PKG_LEN - 1);
        g_pkgs[g_npkgs++][MAX_PKG_LEN - 1] = '\0';
    }
    klog("built-in defaults loaded (%d packages)", g_npkgs);
}

/* ════════════════════════════════════════════════════════════════════════
 * /proc scan — primary "focused-app" detection
 *
 * Structurally equivalent to Encore reading its inotify-fed system_status
 * cache populated by the Java ActivityManager companion.  We achieve the
 * same result by directly reading oom_score_adj from procfs.
 *
 * BUG-I fix: evict ALL active games whose /proc entry has vanished, not
 * only the pidfd==-1 (fallback) subset.  pidfd-tracked games with a lost
 * epoll event would otherwise stay in the table forever.
 * ════════════════════════════════════════════════════════════════════════ */

static void proc_scan(void)
{
    DIR *d;
    struct dirent *de;
    int i;

    /* Step 1: evict all active games that are no longer alive (BUG-I fix) */
    for (i = g_nactive - 1; i >= 0; i--) {
        if (!pid_alive(g_active[i].pid)) {
            klog("scan-evict: %s PID=%d gone",
                 g_active[i].pkg, (int)g_active[i].pid);
            close_game_at(i);
        }
    }

    /* Step 2: scan /proc for foreground matching processes */
    d = opendir("/proc");
    if (!d) return;

    while ((de = readdir(d)) != NULL) {
        int ok = 1, tracked = 0;
        const char *p = de->d_name;
        pid_t pid;
        int adj;
        char pkg[MAX_PKG_LEN];

        if (!isdigit((unsigned char)*p)) continue;
        while (*p) { if (!isdigit((unsigned char)*p++)) { ok = 0; break; } }
        if (!ok) continue;

        pid = (pid_t)atoi(de->d_name);
        if (pid <= 1) continue;

        for (i = 0; i < g_nactive; i++) {
            if (g_active[i].pid == pid) { tracked = 1; break; }
        }
        if (tracked) continue;

        /*
         * Foreground check BEFORE reading cmdline — oom_score_adj is a
         * single integer read vs cmdline which requires opening and reading
         * a file.  Reject background processes cheaply.
         *
         * This is the Encore-inspired detection: adj ≤ 100 ≡ "focused_app"
         * as set by ActivityManagerService.
         */
        adj = read_oom_adj(pid);
        if (adj > FOREGROUND_ADJ_THRESHOLD) continue;

        if (!read_cmdline(pid, pkg, sizeof(pkg))) continue;
        if (!pkg_matches(pkg)) continue;

        klog("scan: foreground match  %s  PID=%d  adj=%d", pkg, (int)pid, adj);
        game_open(pkg, pid);
    }
    closedir(d);
}

/* ════════════════════════════════════════════════════════════════════════
 * PROC_EVENT_COMM handler
 *
 * All three COMM bugs (A, B, C) fixed here.
 * ════════════════════════════════════════════════════════════════════════ */

static void handle_comm(pid_t pid, pid_t tgid, const char *comm)
{
    char pkg[MAX_PKG_LEN];
    int adj;

    /*
     * BUG-A fix: reject worker-thread COMM events.
     *
     * Kernel cn_proc.h documents:
     *   process_pid  = task->pid   (TID of the calling thread)
     *   process_tgid = task->tgid  (userspace process PID)
     *
     * Worker threads (RenderThread, FinalizerDaemon, HeapTaskDaemon, …)
     * have pid != tgid.  Only the main thread sets the process's visible
     * name.  Rejecting pid != tgid prevents worker-thread renames from
     * consuming pending entries before the main thread's package-name COMM.
     */
    if (pid != tgid) return;

    /*
     * BUG-C fix: detect zygote restart BEFORE the app-name filter.
     *
     * "zygote64" has no '.' and length < 14, so it would be discarded by
     * comm_could_be_app().  The old code placed this check after that
     * filter — dead code for every genuine zygote restart.
     */
    if (!strcmp(comm, "zygote64") || !strcmp(comm, "zygote") ||
        !strcmp(comm, "zygote32")) {
        if (pending_remove(tgid)) {
            add_zygote(tgid);
            klog("new zygote PID=%d", (int)tgid);
        }
        return;
    }

    /*
     * BUG-B fix: pre-filter comm BEFORE consuming the pending entry.
     *
     * ActivityThread.main() calls Process.setArgV0("<pre-initialized>")
     * immediately after fork.  This fires PROC_EVENT_COMM on the main
     * thread (pid == tgid) with comm = "<pre-initialized>", which fails
     * isalpha at comm[0].
     *
     * OLD order: pending_remove() → comm_could_be_app() → return
     *   The entry was consumed on "<pre-initialized>"; the real package-
     *   name COMM arrived 1–15 s later to find an empty pending table.
     *
     * NEW order: filter first; pending_remove() is non-gating cleanup.
     * The pending entry is preserved for the real package-name COMM.
     */
    if (!comm_could_be_app(comm)) return;

    /*
     * Non-gating cleanup.  USAP-pool processes may have been pre-forked
     * minutes ago; their pending entries may already have expired.
     * The absence of a pending entry must NOT block game detection.
     */
    pending_remove(tgid);

    if (!read_cmdline(tgid, pkg, sizeof(pkg))) return;
    if (!pkg_matches(pkg)) return;

    /*
     * BUG-F fix: foreground verification via oom_score_adj.
     *
     * When a game is freshly launched, AMS sets adj = 0 within a few ms.
     * When a Meta :service process renames itself (OS background restart),
     * adj is typically ≥ 200 — the user has not opened the app.
     *
     *   adj ≤ threshold → open immediately (minimum detection latency)
     *   adj > threshold → defer; proc_scan() opens it at next 500 ms tick
     *                     once AMS sets adj ≤ 100 (real foreground)
     *
     * This gives correctness (no false positives from background services)
     * AND low latency (typically ≤ first COMM event for game launches).
     */
    adj = read_oom_adj(tgid);
    if (adj <= FOREGROUND_ADJ_THRESHOLD) {
        klog("COMM: immediate  %s  PID=%d  adj=%d", pkg, (int)tgid, adj);
        game_open(pkg, tgid);
    } else {
        klog("COMM: deferred(adj=%d)  %s  PID=%d", adj, pkg, (int)tgid);
    }
}

/* ════════════════════════════════════════════════════════════════════════
 * Netlink socket setup and teardown
 * ════════════════════════════════════════════════════════════════════════ */

static void nl_send_mcast_op(int sock, enum proc_cn_mcast_op op)
{
    unsigned char buf[NLMSG_SPACE(sizeof(struct cn_msg) +
                                  sizeof(enum proc_cn_mcast_op))];
    struct nlmsghdr *nlh;
    struct cn_msg *cn;
    struct sockaddr_nl dst;

    memset(buf, 0, sizeof(buf));
    nlh = (struct nlmsghdr *)buf;
    nlh->nlmsg_len  = sizeof(buf);
    nlh->nlmsg_type = NLMSG_DONE;
    nlh->nlmsg_pid  = (unsigned int)getpid();

    cn = (struct cn_msg *)NLMSG_DATA(nlh);
    cn->id.idx = CN_IDX_PROC;
    cn->id.val = CN_VAL_PROC;
    cn->len    = sizeof(enum proc_cn_mcast_op);
    *((enum proc_cn_mcast_op *)cn->data) = op;

    memset(&dst, 0, sizeof(dst));
    dst.nl_family = AF_NETLINK;
    dst.nl_pid    = 0;
    dst.nl_groups = CN_IDX_PROC;

    (void)sendto(sock, buf, sizeof(buf), 0,
                 (struct sockaddr *)&dst, sizeof(dst));
}

static int netlink_open(void)
{
    int sock;
    struct sockaddr_nl sa;

    sock = socket(PF_NETLINK,
                  SOCK_DGRAM | SOCK_CLOEXEC | SOCK_NONBLOCK,
                  NETLINK_CONNECTOR);
    if (sock < 0) {
        klog("netlink socket: %s", strerror(errno));
        return -1;
    }

    memset(&sa, 0, sizeof(sa));
    sa.nl_family = AF_NETLINK;
    sa.nl_groups = CN_IDX_PROC;
    sa.nl_pid    = (unsigned int)getpid();

    if (bind(sock, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
        klog("netlink bind: %s", strerror(errno));
        close(sock);
        return -1;
    }

    nl_send_mcast_op(sock, PROC_CN_MCAST_LISTEN);
    klog("netlink ready (FORK + COMM + EXIT)");
    return sock;
}

/*
 * Send PROC_CN_MCAST_IGNORE before closing so the kernel decrements
 * proc_event_num_listeners correctly.  Without this, a daemon crash-
 * restart loop accumulates the counter (harmless functionally, but wrong).
 */
static void netlink_close_gracefully(void)
{
    if (g_nl_sock < 0) return;
    nl_send_mcast_op(g_nl_sock, PROC_CN_MCAST_IGNORE);
    close(g_nl_sock);
    g_nl_sock = -1;
}

/* ════════════════════════════════════════════════════════════════════════
 * Netlink event dispatch
 * ════════════════════════════════════════════════════════════════════════ */

static void handle_netlink(void)
{
    /* BUG-K fix: 16384-byte buffer holds ≈200 CN_PROC events per recv */
    char buf[NL_BUF_SIZE] __attribute__((aligned(NLMSG_ALIGNTO)));
    ssize_t len = recv(g_nl_sock, buf, sizeof(buf), 0);

    if (len < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK) return;
        /*
         * BUG-E fix: any persistent recv error (ENOBUFS under burst load,
         * ECONNRESET, etc.) must remove the fd from epoll.
         * Previously the fd was left in epoll after the error, causing
         * recv() to return -1 on every wakeup → infinite spin → watchdog.
         */
        klog("netlink recv: %s — disabling, /proc scan is now primary",
             strerror(errno));
        epoll_ctl(g_epoll_fd, EPOLL_CTL_DEL, g_nl_sock, NULL);
        netlink_close_gracefully();
        g_nl_sock   = -1;
        g_nl_failed = 1;
        return;
    }

    {
        struct nlmsghdr *nlh = (struct nlmsghdr *)buf;
        for (; NLMSG_OK(nlh, (unsigned int)len); nlh = NLMSG_NEXT(nlh, len)) {
            const struct proc_event *ev;
            struct cn_msg *cn;

            if (nlh->nlmsg_type != NLMSG_DONE) continue;

            cn = (struct cn_msg *)NLMSG_DATA(nlh);
            if (cn->id.idx != CN_IDX_PROC || cn->id.val != CN_VAL_PROC)
                continue;

            ev = (const struct proc_event *)cn->data;
            switch (ev->what) {

            case PROC_EVENT_FORK: {
                pid_t parent = ev->event_data.fork.parent_tgid;
                pid_t child  = ev->event_data.fork.child_tgid;
                /*
                 * Track children of zygote.  When zygote is unknown
                 * (discover_zygotes() ran before any zygote was up),
                 * fall back to tracking all forks from init (parent==1)
                 * and from any process.
                 */
                if (g_nzygotes == 0 || is_zygote(parent) || parent == 1)
                    pending_add(child);
                break;
            }

            case PROC_EVENT_COMM:
                /*
                 * process_pid  = TID of the renaming thread (task->pid)
                 * process_tgid = process PID as seen in userspace (task->tgid)
                 * comm         = char[TASK_COMM_LEN=16], NUL-terminated
                 */
                handle_comm(ev->event_data.comm.process_pid,
                            ev->event_data.comm.process_tgid,
                            ev->event_data.comm.comm);
                break;

            case PROC_EVENT_EXIT:
                game_closed_by_pid(ev->event_data.exit.process_tgid);
                break;

            default:
                break;
            }
        }
    }
}

/* ════════════════════════════════════════════════════════════════════════
 * Timer handler — fires every 500 ms
 * ════════════════════════════════════════════════════════════════════════ */

static void handle_timer(void)
{
    uint64_t expirations;
    (void)read(g_timer_fd, &expirations, sizeof(expirations));
    g_timer_ticks++;

    /* BUG-J fix: expire stale pending entries on every tick, not only on
     * pending_add().  Under low fork rate the table could fill otherwise. */
    pending_expire();

    /*
     * /proc scan.
     * Every tick in netlink-failed mode; every PROC_SCAN_TICKS ticks (1 s)
     * otherwise.  The scan is the primary GROUP-2 Meta detection mechanism:
     * persistent Meta processes don't generate new COMM events when they
     * come to the foreground — only their oom_score_adj changes, exactly
     * like how Encore detects focused_app changes via its inotify cache.
     */
    if (g_nl_failed || (g_timer_ticks % PROC_SCAN_TICKS == 0))
        proc_scan();

    /*
     * GOS / OEM re-enforcement every ENFORCE_TICKS × 500 ms = 5 s.
     * Samsung GOS and some OEM perf daemons reset debug.hwui.renderer
     * mid-session; re-read and correct if needed.
     */
    if (g_active_cnt > 0 && (g_timer_ticks % ENFORCE_TICKS == 0)) {
        char cur[PROP_VALUE_MAX] = "";
        __system_property_get("debug.hwui.renderer", cur);
        if (strcmp(cur, "skiagl") != 0) {
            klog("GOS-ENFORCE: was '%s', re-applying skiagl", cur);
            set_renderer("skiagl");
        }
    }
}

/* ════════════════════════════════════════════════════════════════════════
 * Cleanup — called on shutdown
 * ════════════════════════════════════════════════════════════════════════ */

static void do_cleanup(void)
{
    int i;

    if (g_active_cnt > 0) {
        set_renderer(g_restore_hwui);
        write_state(0);
    }

    /* Reap outstanding resetprop/setprop children (BUG-D) */
    while (waitpid(-1, NULL, WNOHANG) > 0) {}

    for (i = 0; i < g_nactive; i++)
        if (g_active[i].pidfd >= 0)
            close(g_active[i].pidfd);

    netlink_close_gracefully();
    unlink(PID_FILE);

    if (g_timer_fd  >= 0) { close(g_timer_fd);  g_timer_fd  = -1; }
    if (g_sig_fd    >= 0) { close(g_sig_fd);    g_sig_fd    = -1; }
    if (g_epoll_fd  >= 0) { close(g_epoll_fd);  g_epoll_fd  = -1; }
    if (g_kmsg_fd   >= 0) { close(g_kmsg_fd);   g_kmsg_fd   = -1; }
}

/* ════════════════════════════════════════════════════════════════════════
 * Signal handler — runs in event loop via signalfd, never in signal context
 * ════════════════════════════════════════════════════════════════════════ */

static void handle_signals(void)
{
    struct signalfd_siginfo si;
    while (read(g_sig_fd, &si, sizeof(si)) == (ssize_t)sizeof(si)) {
        switch (si.ssi_signo) {

        case SIGCHLD:
            /* BUG-D fix: reap children asynchronously, never block */
            while (waitpid(-1, NULL, WNOHANG) > 0) {}
            break;

        case SIGHUP:
            /* Reload package list from disk (e.g. after WebUI edit) */
            klog("SIGHUP: reloading package list");
            load_pkg_list();   /* defined above — no forward declaration needed */
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
 * main
 * ════════════════════════════════════════════════════════════════════════ */

int main(int argc, char *argv[])
{
    sigset_t mask;
    static char moddir_path[520];
    struct epoll_event ev;
    struct itimerspec its;

    /* ── Parse arguments ────────────────────────────────────────────── */
    if (argc >= 2) {
        const char *m = argv[1];
        if (!strcmp(m, "skiavk") || !strcmp(m, "skiavk_all") ||
            !strcmp(m, "skiavkthreaded"))
            strncpy(g_restore_hwui, "skiavk", sizeof(g_restore_hwui) - 1);
        else if (!strcmp(m, "skiagl") || !strcmp(m, "skiaglthreaded"))
            strncpy(g_restore_hwui, "skiagl", sizeof(g_restore_hwui) - 1);
        else
            strncpy(g_restore_hwui, "skiavk", sizeof(g_restore_hwui) - 1);
        g_restore_hwui[sizeof(g_restore_hwui) - 1] = '\0';
    }
    if (argc >= 3) {
        strncpy(g_moddir, argv[2], sizeof(g_moddir) - 1);
        g_moddir[sizeof(g_moddir) - 1] = '\0';
    }

    /* ── /dev/kmsg first so we can log from here on ─────────────────── */
    g_kmsg_fd = open(KMSG_PATH, O_WRONLY | O_CLOEXEC);

    /* ── Singleton guard ─────────────────────────────────────────────── */
    if (daemon_already_running()) {
        klog("already running — exiting duplicate");
        return 0;
    }

    /* ── Package list ────────────────────────────────────────────────── */
    if (g_moddir[0]) {
        snprintf(moddir_path, sizeof(moddir_path),
                 "%s/game_exclusion_list.sh", g_moddir);
        g_list_paths[2] = moddir_path;
    }
    load_pkg_list();
    if (g_npkgs == 0) { klog("FATAL: empty package list"); return 1; }

    /* ── PID file and initial state ──────────────────────────────────── */
    write_pid_file();
    write_state(0);
    klog("started  PID=%d  restore=%s  packages=%d  moddir=%s",
         (int)getpid(), g_restore_hwui, g_npkgs,
         g_moddir[0] ? g_moddir : "(none)");

    /*
     * Block all handled signals before creating signalfd so no signal
     * is delivered between sigprocmask and signalfd creation.
     * SIGCHLD must be blocked so exiting children don't kill the daemon.
     */
    sigemptyset(&mask);
    sigaddset(&mask, SIGTERM);
    sigaddset(&mask, SIGINT);
    sigaddset(&mask, SIGHUP);
    sigaddset(&mask, SIGCHLD);
    sigprocmask(SIG_BLOCK, &mask, NULL);
    signal(SIGPIPE, SIG_IGN);

    /* ── epoll ────────────────────────────────────────────────────────── */
    g_epoll_fd = epoll_create1(EPOLL_CLOEXEC);
    if (g_epoll_fd < 0) {
        klog("epoll_create1: %s", strerror(errno));
        return 1;
    }

    /* ── signalfd ─────────────────────────────────────────────────────── */
    g_sig_fd = signalfd(-1, &mask, SFD_CLOEXEC | SFD_NONBLOCK);
    if (g_sig_fd < 0) {
        klog("signalfd: %s", strerror(errno));
        return 1;
    }
    ev.events  = EPOLLIN;
    ev.data.fd = g_sig_fd;
    epoll_ctl(g_epoll_fd, EPOLL_CTL_ADD, g_sig_fd, &ev);

    /* ── timerfd 500 ms, CLOCK_MONOTONIC ─────────────────────────────── */
    g_timer_fd = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC | TFD_NONBLOCK);
    if (g_timer_fd < 0) {
        klog("timerfd_create: %s", strerror(errno));
        return 1;
    }
    its.it_value.tv_sec  = 0;
    its.it_value.tv_nsec = (long)TIMER_INTERVAL_MS * 1000000L;
    its.it_interval      = its.it_value;
    timerfd_settime(g_timer_fd, 0, &its, NULL);
    ev.events  = EPOLLIN;
    ev.data.fd = g_timer_fd;
    epoll_ctl(g_epoll_fd, EPOLL_CTL_ADD, g_timer_fd, &ev);

    /* ── Discover zygote PIDs before subscribing to proc events ──────── */
    discover_zygotes();

    /* ── Netlink CN_PROC ─────────────────────────────────────────────── */
    g_nl_sock = netlink_open();
    if (g_nl_sock >= 0) {
        ev.events  = EPOLLIN;
        ev.data.fd = g_nl_sock;
        epoll_ctl(g_epoll_fd, EPOLL_CTL_ADD, g_nl_sock, &ev);
        g_nl_failed = 0;
    } else {
        klog("netlink unavailable — /proc scan is primary detection");
        g_nl_failed = 1;
    }

    /* ── Startup scan: pick up games already running ─────────────────── */
    klog("startup scan...");
    proc_scan();

    /* ── Main event loop ─────────────────────────────────────────────── */
    klog("loop: netlink=%s  scan=%dms  enforce=%dms",
         g_nl_failed ? "off" : "on",
         PROC_SCAN_TICKS  * TIMER_INTERVAL_MS,
         ENFORCE_TICKS    * TIMER_INTERVAL_MS);

    {
        struct epoll_event events[MAX_EPOLL_EVENTS];
        for (;;) {
            int nev = epoll_wait(g_epoll_fd, events, MAX_EPOLL_EVENTS, -1);
            int i;
            if (nev < 0) {
                if (errno == EINTR) continue;
                klog("epoll_wait: %s", strerror(errno));
                break;
            }
            for (i = 0; i < nev; i++) {
                int fd = events[i].data.fd;
                if      (fd == g_sig_fd)                    handle_signals();
                else if (fd == g_timer_fd)                  handle_timer();
                else if (g_nl_sock >= 0 && fd == g_nl_sock) handle_netlink();
                else if (events[i].events & EPOLLIN)
                    /* pidfd event: tracked game process exited */
                    game_closed_by_pidfd(fd);
            }
        }
    }

    do_cleanup();
    return 0;
}
