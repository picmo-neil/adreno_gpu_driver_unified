#!/system/bin/sh
# ============================================================
# ADRENO DRIVER MODULE — GAME EXCLUSION DAEMON
# ============================================================
#
# Developer  : @pica_pica_picachu
# Channel    : @zesty_pic (driver channel)
#
# ⚠️  ANTI-THEFT NOTICE ⚠️
# This module was developed by @pica_pica_picachu.
# If someone claims this as their own work and asks for
# donations — report them immediately to @zesty_pic.
#
# ============================================================
#
# ZERO-OVERHEAD EVENT-DRIVEN ARCHITECTURE
# ========================================
# This daemon prevents the dual-VkDevice crash that occurs when a
# native-Vulkan game and HWUI's skiavk renderer both hold a VkDevice
# in the same process. It switches debug.hwui.renderer to skiagl the
# moment a game from the exclusion list launches, and restores it to
# the configured skiavk mode the instant all such games have exited.
#
# HOW IT ACHIEVES ZERO OVERHEAD:
#
#   DETECTING GAME START — logcat events buffer:
#     ActivityManager posts an am_proc_start binary event to the events
#     log buffer every time any app process is created. This daemon opens
#     a streaming logcat session against that buffer with -v brief format.
#     The read() syscall on the logcat pipe blocks in TASK_INTERRUPTIBLE
#     state inside the kernel (the pipe is backed by logd's epoll loop).
#     Between game launches the daemon is parked in the kernel — zero CPU,
#     zero wakeups. It wakes only when logd has a new event line ready.
#     One logcat process covers ALL packages in the exclusion list.
#     NOTE: -v raw must NOT be used. It strips the event tag ("am_proc_start")
#     from every output line, causing the pre-filter to never match and
#     zero games to be detected. -v brief keeps the tag in each line.
#
#   DETECTING GAME EXIT — /proc/$PID existence:
#     The kernel removes /proc/$PID atomically when the process group
#     leader exits. A sub-daemon runs `sleep 1; [ -d /proc/$PID ]`
#     in a tight loop. sleep(1) maps to nanosleep(1s) which puts the
#     process in TASK_INTERRUPTIBLE — genuine kernel sleep, ~1 µs CPU
#     per second per active game. Between game sessions no sub-daemons
#     exist, so overhead is exactly zero.
#
#   inotify on /proc is intentionally NOT used: the procfs pseudo-
#   filesystem does not generate IN_DELETE_SELF events reliably on
#   Android (tested across Android 9-15, kernels 4.14-6.1). The sleep
#   loop is the only universally reliable mechanism in shell.
#
# REFERENCE COUNTING — handles multiple simultaneous games:
#   A flat counter file tracks how many excluded games are active.
#   0 -> 1: switch to skiagl.
#   N -> N-1: if reaches 0, restore skiavk/skiavk_all.
#   Locking: atomic `mkdir` on ext4/F2FS (guaranteed atomic by POSIX
#   and both filesystems). No flock/fcntl needed.
#
# USAGE:
#   /system/bin/sh game_excl_daemon.sh [skiavk|skiavk_all]
#   Called by post-fs-data.sh after boot_completed+2s.
#   $1 = the configured render mode to restore when games exit.
#
# STATE FILES (all in /data/local/tmp/):
#   adreno_ged_pid      - main daemon PID (guards against duplicate launch)
#   adreno_ged_count    - number of currently active excluded games
#   adreno_ged.lock/    - atomic lock directory (created/deleted per op)
# ============================================================

# ── Configuration ─────────────────────────────────────────────────────────────
_DAEMON_PID_FILE="/data/local/tmp/adreno_ged_pid"
_ACTIVE_COUNT_FILE="/data/local/tmp/adreno_ged_count"
# adreno_ged_active: matches the state file written by the native ged.c binary.
# Written here so the GOS prop watchdog in service.sh can read the same file
# regardless of whether it's the native binary or this shell daemon that's running.
# "1" = at least one excluded game is active (renderer = skiagl)
# "0" = no excluded game active (renderer = skiavk/skiavk_all)
_GED_ACTIVE_FILE="/data/local/tmp/adreno_ged_active"
_LOCK_DIR="/data/local/tmp/adreno_ged.lock"

# The renderer to restore when all games exit.
# Passed as $1 from post-fs-data.sh; defaults to skiavk if absent/invalid.
_SKIAVK_MODE="${1:-skiavk}"
case "$_SKIAVK_MODE" in
  skiavk|skiavk_all) ;;
  *) _SKIAVK_MODE="skiavk" ;;
esac

# BUG A FIX: _RESTORE_HWUI is the actual debug.hwui.renderer value to pass to
# resetprop on game exit.  _SKIAVK_MODE may be "skiavk_all" (informational mode
# string from service.sh) which is NOT a valid debug.hwui.renderer value — HWUI
# silently ignores it and stays at skiagl forever.  Normalize to "skiavk".
_RESTORE_HWUI="$_SKIAVK_MODE"
[ "$_RESTORE_HWUI" = "skiavk_all" ] && _RESTORE_HWUI="skiavk"

# FIX: Accept MODDIR override from $2 (service.sh passes it explicitly).
# On KernelSU without meta-module, MODDIR is not exported to the environment;
# without this the _GAME_EXCL_MOD path below resolves to "/game_exclusion_list.sh"
# (empty MODDIR prefix) and the module's bundled exclusion list is silently skipped,
# falling back to the inline hardcoded defaults instead of the user's edits.
[ -n "${2:-}" ] && MODDIR="$2"

# ── Duplicate-instance guard ──────────────────────────────────────────────────
# Only one daemon may run at a time. Check the PID file; if the recorded
# process is still alive, exit immediately.
if [ -f "$_DAEMON_PID_FILE" ]; then
  _existing_pid=""
  { IFS= read -r _existing_pid; } < "$_DAEMON_PID_FILE" 2>/dev/null || true
  if [ -n "$_existing_pid" ] && kill -0 "$_existing_pid" 2>/dev/null; then
    echo "[ADRENO-GED] Already running as PID ${_existing_pid} -- exiting duplicate" \
      > /dev/kmsg 2>/dev/null || true
    exit 0
  fi
  unset _existing_pid
fi

# ── Source game exclusion list ────────────────────────────────────────────────
# Uses the same lookup order as post-fs-data.sh so edits via WebUI are picked
# up without a module reflash. Falls back to a hardcoded inline list if no
# external file is found (covers the case where MODDIR is not set).
_GAME_EXCL_SD="/sdcard/Adreno_Driver/Config/game_exclusion_list.sh"
_GAME_EXCL_MOD="${MODDIR:-}/game_exclusion_list.sh"
_GAME_EXCL_DATA="/data/local/tmp/adreno_game_exclusion_list.sh"

if [ -f "$_GAME_EXCL_SD" ] && [ -r "$_GAME_EXCL_SD" ]; then
  # shellcheck source=/dev/null
  . "$_GAME_EXCL_SD"
elif [ -f "$_GAME_EXCL_DATA" ] && [ -r "$_GAME_EXCL_DATA" ]; then
  # shellcheck source=/dev/null
  . "$_GAME_EXCL_DATA"
elif [ -n "$_GAME_EXCL_MOD" ] && [ -f "$_GAME_EXCL_MOD" ] && [ -r "$_GAME_EXCL_MOD" ]; then
  # shellcheck source=/dev/null
  . "$_GAME_EXCL_MOD"
else
  # Inline fallback -- mirrors the defaults in game_exclusion_list.sh.
  # Kept in sync with the bundled file; covers offline/module-dir-unknown cases.
  GAME_EXCLUSION_PKGS="
com.tencent.ig
com.pubg.krmobile
com.pubg.imobile
com.pubg.newstate
com.vng.pubgmobile
com.rekoo.pubgm
com.tencent.tmgp.pubgmhd
com.epicgames.*
com.activision.callofduty.shooter
com.garena.game.codm
com.tencent.tmgp.cod
com.vng.codmvn
com.miHoYo.GenshinImpact
com.cognosphere.GenshinImpact
com.miHoYo.enterprise.HSRPrism
com.HoYoverse.hkrpgoversea
com.levelinfinite.hotta
com.proximabeta.mfh
com.HoYoverse.Nap
com.miHoYo.ZZZ
com.facebook.katana
com.facebook.orca
com.facebook.lite
com.facebook.mlite
com.instagram.android
com.instagram.lite
com.instagram.barcelona
com.whatsapp
com.whatsapp.w4b
"
  _game_pkg_excluded() {
    local _p="$1" _e
    for _e in $GAME_EXCLUSION_PKGS; do
      # shellcheck disable=SC2254
      case "$_p" in $_e) return 0 ;; esac
    done
    return 1
  }
  echo "[ADRENO-GED] WARNING: game_exclusion_list.sh not found -- using inline fallback" \
    > /dev/kmsg 2>/dev/null || true
fi

# Guard: abort if list is empty -- nothing to monitor
if [ -z "${GAME_EXCLUSION_PKGS:-}" ]; then
  echo "[ADRENO-GED] GAME_EXCLUSION_PKGS empty -- daemon not needed, exiting" \
    > /dev/kmsg 2>/dev/null || true
  exit 0
fi

unset _GAME_EXCL_SD _GAME_EXCL_MOD _GAME_EXCL_DATA

# ── Defensive guard: ensure _game_pkg_excluded() is always defined ────────────
# If none of the sourcing paths succeeded (file missing, unreadable, or the
# sourced file was truncated/corrupted and did not define the function), provide
# a safe fallback using the inline GAME_EXCLUSION_PKGS variable.  Without this,
# the first call to _game_pkg_excluded() in the event loop would produce
# "sh: _game_pkg_excluded: not found", silently treating every package as
# non-excluded and breaking all game detection.
if ! command -v _game_pkg_excluded >/dev/null 2>&1; then
  _game_pkg_excluded() {
    local _p="$1" _e
    for _e in $GAME_EXCLUSION_PKGS; do
      # shellcheck disable=SC2254
      case "$_p" in $_e) return 0 ;; esac
    done
    return 1
  }
  echo "[ADRENO-GED] WARNING: _game_pkg_excluded() undefined after sourcing -- using inline definition" \
    > /dev/kmsg 2>/dev/null || true
fi

# ── Atomic locking helpers ────────────────────────────────────────────────────
# mkdir is atomic on ext4 (Android >= 4.4) and F2FS (Android >= 9).
# 200-iteration cap: prevents infinite spin if a SIGKILL'd holder left the lock.
# At ~1 us per failed mkdir attempt, 200 iterations = ~200 us worst-case spin.
_acquire_lock() {
  local _i=0
  while ! mkdir "$_LOCK_DIR" 2>/dev/null; do
    _i=$((_i + 1))
    # Stale-lock threshold: 200 iterations at 50 ms = ~10 s, which is generous
    # for a lock that is held for <1 ms in normal operation.  When only sleep 1
    # is available (no busybox usleep, no fractional sleep), cap at 15 iterations
    # (15 s) rather than letting the fallback spin for 200 s.
    if busybox usleep 50000 2>/dev/null || sleep 0.05 2>/dev/null; then
      [ $_i -ge 200 ] && break
    else
      sleep 1 2>/dev/null || true
      [ $_i -ge 15 ] && break
    fi
  done
  # Force-clear a stale lock after the iteration cap is hit.
  if ! mkdir "$_LOCK_DIR" 2>/dev/null; then
    rmdir "$_LOCK_DIR" 2>/dev/null || rm -rf "$_LOCK_DIR" 2>/dev/null || true
    mkdir "$_LOCK_DIR" 2>/dev/null || true
  fi
}

_release_lock() {
  rmdir "$_LOCK_DIR" 2>/dev/null || true
}

# ── Renderer control ──────────────────────────────────────────────────────────
# Tries resetprop first (Magisk / KernelSU / standard APatch magic-mount).
# Falls back to setprop for APatch lite-mode where resetprop is unavailable.
# Both change only the in-memory property value -- no build.prop is touched.
# The change takes effect for every app process started AFTER this call;
# debug.hwui.renderer is read once per process at its first HWUI init.
#
# BUG-6 NOTE (setprop path): Unlike resetprop, setprop goes through
# property_service and will trigger any on:property=debug.hwui.renderer
# init.rc watchers present on OEM ROMs (MIUI/HyperOS, One UI). Such watchers
# may re-override the renderer within ~1-2s. This is a best-effort path only;
# if the renderer flip is immediately overridden, the daemon will re-detect
# and re-apply on its next poll cycle. No deadlock risk in service context.
_set_renderer() {
  local _r="$1"
  if command -v resetprop >/dev/null 2>&1; then
    resetprop debug.hwui.renderer "$_r" 2>/dev/null
  else
    # APatch lite-mode: resetprop unavailable. setprop is the only option.
    # Logged to kmsg below; OEM init.rc watcher interference is possible.
    setprop debug.hwui.renderer "$_r" 2>/dev/null || true
    echo "[ADRENO-GED] WARN: used setprop (APatch lite-mode; OEM watcher may override)" \
      > /dev/kmsg 2>/dev/null || true
  fi
  echo "[ADRENO-GED] renderer -> ${_r}" > /dev/kmsg 2>/dev/null || true
}

# ── Counter helpers ───────────────────────────────────────────────────────────
_read_count() {
  local _c=0
  { IFS= read -r _c; } < "$_ACTIVE_COUNT_FILE" 2>/dev/null || _c=0
  # Strip non-digits to tolerate corrupted data (e.g. from a hard reboot mid-write)
  _c="${_c%%[^0-9]*}"
  printf '%s' "${_c:-0}"
}

# ── Game-open handler ─────────────────────────────────────────────────────────
# Called on the main loop thread when an excluded game's process is created.
# Increments the reference counter; switches renderer to skiagl on first game.
_game_open() {
  local _pkg="$1" _pid="$2" _cnt
  _acquire_lock
  _cnt=$(_read_count)
  _cnt=$((_cnt + 1))
  printf '%s\n' "$_cnt" > "$_ACTIVE_COUNT_FILE" 2>/dev/null || true
  _release_lock

  # Mark this PID as actively monitored so _startup_scan (called on every outer
  # loop iteration in proc-poll mode) does not double-register the same game.
  # The flag file is removed by _game_closed() and on SIGTERM cleanup.
  touch "/data/local/tmp/adreno_ged_w_${_pid}" 2>/dev/null || true

  if [ "$_cnt" -eq 1 ]; then
    # First excluded game opened -- HWUI must use GL to prevent dual-VkDevice crash
    _set_renderer skiagl
    # Write state file so GOS watchdog in service.sh (and the native ged.c path)
    # both know a game is active regardless of which daemon is running.
    printf '1\n' > "$_GED_ACTIVE_FILE" 2>/dev/null || true
    echo "[ADRENO-GED] GAME OPEN: ${_pkg} (PID=${_pid}) -- active=1 -> skiagl" \
      > /dev/kmsg 2>/dev/null || true
  else
    echo "[ADRENO-GED] GAME OPEN: ${_pkg} (PID=${_pid}) -- active=${_cnt}, already skiagl" \
      > /dev/kmsg 2>/dev/null || true
  fi
}

# ── Game-closed handler ───────────────────────────────────────────────────────
# Called by a sub-daemon when /proc/$PID disappears (game process exited).
# Decrements the reference counter; restores the configured renderer on last exit.
_game_closed() {
  local _pkg="$1" _pid="$2" _cnt
  _acquire_lock
  _cnt=$(_read_count)
  [ "$_cnt" -gt 0 ] && _cnt=$((_cnt - 1))
  printf '%s\n' "$_cnt" > "$_ACTIVE_COUNT_FILE" 2>/dev/null || true
  _release_lock

  # Remove PID tracking flag so this PID is not skipped if the daemon restarts
  # and finds the slot still occupied (proc recycling edge case).
  rm -f "/data/local/tmp/adreno_ged_w_${_pid}" 2>/dev/null || true

  if [ "$_cnt" -eq 0 ]; then
    # Last excluded game exited -- restore Vulkan renderer.
    # Use _RESTORE_HWUI (normalized: skiavk_all → skiavk) not _SKIAVK_MODE.
    # skiavk_all is not a valid debug.hwui.renderer value; HWUI ignores it.
    _set_renderer "$_RESTORE_HWUI"
    # Clear state file so service.sh GOS watchdog stops watching
    printf '0\n' > "$_GED_ACTIVE_FILE" 2>/dev/null || true
    echo "[ADRENO-GED] GAME CLOSED: ${_pkg} (PID=${_pid}) -- active=0 -> ${_RESTORE_HWUI}" \
      > /dev/kmsg 2>/dev/null || true
  else
    echo "[ADRENO-GED] GAME CLOSED: ${_pkg} (PID=${_pid}) -- active=${_cnt}, staying skiagl" \
      > /dev/kmsg 2>/dev/null || true
  fi
}

# ── Sub-daemon: monitor a single game process ─────────────────────────────────
# Spawned as a background subshell (&) for each game instance that opens.
#
# sleep 1 = nanosleep(1s) = TASK_INTERRUPTIBLE kernel state.
# Overhead between wakeups: one [ -d /proc/$PID ] = one stat() syscall (~1 us).
# Total: ~1 us CPU per second per active game. Zero CPU between game sessions.
#
# /proc/$PID is removed atomically by the kernel when the process group leader
# exits. The directory is absent before any wait(2) returns, so we never see
# a zombie state here. The check is a simple directory existence test.
_wait_game_death() {
  local _pkg="$1" _pid="$2" _itr=0 _cur

  # Handle the race where the process already exited before we started watching
  if [ ! -d "/proc/${_pid}" ]; then
    _game_closed "$_pkg" "$_pid"
    return
  fi

  # Zero-overhead sleep loop: wakes every 1 second, checks /proc/$PID.
  # Every 5 iterations (~5 s) also re-enforces debug.hwui.renderer=skiagl.
  # Samsung GOS and some OEM perf daemons can reset the property mid-session;
  # without this check the game would get a dual-VkDevice crash the next time
  # it calls vkCreateDevice after the renderer was reset back to skiavk.
  # getprop is a tiny binder call (~0.5 ms); running it every 5 s adds no
  # meaningful CPU load while fully closing the GOS reset window.
  while [ -d "/proc/${_pid}" ]; do
    sleep 1
    _itr=$((_itr + 1))
    if [ $((_itr % 5)) -eq 0 ]; then
      _cur=$(getprop debug.hwui.renderer 2>/dev/null || echo "")
      # Guard against getprop returning empty (binder error, init not ready):
      # an empty value compares != "skiagl" and would trigger a spurious re-set.
      if [ -n "$_cur" ] && [ "$_cur" != "skiagl" ]; then
        _set_renderer skiagl
        echo "[ADRENO-GED] RE-ENFORCE: skiagl (was '${_cur}') for ${_pkg} (PID=${_pid})" \
          > /dev/kmsg 2>/dev/null || true
      fi
    fi
  done

  # /proc/$PID gone -> process exited -> update counter and renderer
  _game_closed "$_pkg" "$_pid"
}

# ── Startup scan ──────────────────────────────────────────────────────────────
# One-time scan of /proc at daemon start. Handles the edge case where the
# daemon is started (or restarted after a crash) while an excluded game is
# already running. Without this scan, the daemon would not know about games
# that launched before it and would never restore the renderer when they exit.
# This is O(number-of-running-processes) -- acceptable as a one-time operation.
#
# In /proc-poll fallback mode (logcat unavailable) this function is invoked
# every 5s as the primary detection mechanism.  The PID tracking flag files
# (adreno_ged_w_$PID) created by _game_open() prevent double-registration
# across repeated calls: if a game is already tracked its flag exists and
# we skip it.  Death detection is still handled by the existing _wait_game_death
# sub-daemon spawned on first detection.
_startup_scan() {
  local _dir _pid _pkg
  # Suppress the "checking for running excluded games" kmsg log in proc-poll
  # mode where this function runs every 5 seconds — /dev/kmsg would flood.
  # Only emit the log on the very first call (counter == 0 before increment).
  _GED_SCAN_COUNT=$((_GED_SCAN_COUNT + 1))
  if [ "$_GED_SCAN_COUNT" -le 1 ] || [ "$_GED_USE_PROC_POLL" = "false" ]; then
    echo "[ADRENO-GED] startup scan: checking for running excluded games..." \
      > /dev/kmsg 2>/dev/null || true
  fi

  for _dir in /proc/[0-9]*; do
    _pid="${_dir##*/}"
    [ -d "$_dir" ] || continue

    # Skip PIDs already being tracked (set by _game_open, cleared by _game_closed).
    # Prevents double-counting in /proc-poll mode where this runs every 5s.
    [ -f "/data/local/tmp/adreno_ged_w_${_pid}" ] && continue

    # Read argv[0] from /proc/pid/cmdline. The kernel stores argv as NUL-separated
    # strings (POSIX: "a set of strings separated by null bytes").
    # tr replaces NUL separators with newlines; head -1 then returns exactly argv[0].
    # This is portable across bash, mksh, ash, and busybox sh.
    # Background: the previous approach used $'\0' (an ANSI-C bash extension).
    # In mksh (Android's /system/bin/sh on Android 11 and earlier) $'\0' expands
    # to an empty string, so %%$'\0'* became %%* which stripped the entire _pkg
    # variable, causing every excluded game to be missed during startup scans.
    _pkg=""
    _pkg=$(tr '\0' '\n' < "${_dir}/cmdline" 2>/dev/null | head -1)
    [ -z "$_pkg" ] && continue

    # Strip :processname suffix (e.g. "com.tencent.ig:remote" -> "com.tencent.ig")
    _pkg="${_pkg%%:*}"

    [ -z "$_pkg" ] && continue

    _game_pkg_excluded "$_pkg" || continue

    # BUG2 FIX: skip Meta background services in startup scan.
    # Meta apps (Facebook/WhatsApp/Instagram/Messenger) are on the exclusion
    # list for GROUP 2 (UBWC green line artifact on active HWUI surfaces).
    # Their background service processes live in /proc permanently — detecting
    # them here would set skiagl forever since they never exit.
    # am_proc_start (main loop) handles Meta correctly: it fires only when the
    # user opens the app and a new process is created, not for pre-existing
    # background services. Skip them in the startup scan entirely.
    case "$_pkg" in
      com.facebook.*|com.instagram.*|com.whatsapp|com.whatsapp.w4b)
        echo "[ADRENO-GED] startup scan: skipping Meta background service ${_pkg} (PID=${_pid})" \
          > /dev/kmsg 2>/dev/null || true
        continue ;;
    esac

    echo "[ADRENO-GED] startup scan: found running game ${_pkg} (PID=${_pid})" \
      > /dev/kmsg 2>/dev/null || true
    _game_open "$_pkg" "$_pid"
    _wait_game_death "$_pkg" "$_pid" &
  done
}

# ── SIGTERM/SIGINT cleanup handler ────────────────────────────────────────────
# On shutdown (from uninstall.sh kill or manual kill), restore the renderer
# to skiavk if the daemon currently has it set to skiagl. This ensures the
# renderer is always in a valid state after the daemon exits.
trap '
  _trap_cnt=0
  [ -f "$_ACTIVE_COUNT_FILE" ] && { IFS= read -r _trap_cnt; } < "$_ACTIVE_COUNT_FILE" 2>/dev/null || _trap_cnt=0
  _trap_cnt="${_trap_cnt%%[^0-9]*}"; _trap_cnt="${_trap_cnt:-0}"
  if [ "$_trap_cnt" -gt 0 ]; then
    _set_renderer "$_RESTORE_HWUI"
    printf "0\n" > "$_GED_ACTIVE_FILE" 2>/dev/null || true
    echo "[ADRENO-GED] SIGTERM: restored ${_RESTORE_HWUI} (was skiagl, count=${_trap_cnt})" \
      > /dev/kmsg 2>/dev/null || true
  fi
  rm -f "$_DAEMON_PID_FILE" "$_ACTIVE_COUNT_FILE" "$_GED_ACTIVE_FILE" 2>/dev/null || true
  rmdir "$_LOCK_DIR" 2>/dev/null || true
  # Clean up all PID tracking flag files created by _game_open()
  rm -f /data/local/tmp/adreno_ged_w_* 2>/dev/null || true
  exit 0
' TERM INT

# ── Initialize state ──────────────────────────────────────────────────────────
printf '%s\n' "$$" > "$_DAEMON_PID_FILE" 2>/dev/null || true
printf '0\n'       > "$_ACTIVE_COUNT_FILE" 2>/dev/null || true
printf '0\n'       > "$_GED_ACTIVE_FILE" 2>/dev/null || true
rmdir "$_LOCK_DIR" 2>/dev/null || true  # clear any stale lock from a previous crash

echo "[ADRENO-GED] Started (PID=$$, restore_mode=${_SKIAVK_MODE})" \
  > /dev/kmsg 2>/dev/null || true

# ── Main monitoring loop — survives logcat/logd restarts ──────────────────────────
# BUG1 FIX: was "exec /system/bin/sh $0" at pipe exit — exec keeps same PID,
# duplicate guard killed the restart immediately. Now a while-true outer loop
# keeps the daemon alive; _startup_scan re-runs after each logcat restart to
# catch games that launched during the down window.
#
# BUG4 FIX: SELinux logcat fallback.
# On some OEM ROMs (MIUI/HyperOS 1.x, older Samsung One UI), logcat access
# from the module's shell context is blocked by SELinux policy. The logcat
# process starts but exits immediately (0 lines read, < 2s runtime). After
# 3 consecutive fast exits, the daemon switches to /proc-poll mode:
#   - _startup_scan() is called every 5s as the detection mechanism.
#   - _startup_scan skips already-tracked PIDs (adreno_ged_w_$PID flag files)
#     so repeated calls do not double-count running games.
#   - Death detection is still handled by _wait_game_death sub-daemons which
#     are already running and do not depend on logcat.
# When in /proc-poll mode, new game launches are detected within ≤5s (vs ~0s
# via logcat). Acceptable for the targeted game titles (PUBG, Genshin, etc.).
# The native ged.c binary is entirely immune to this issue (uses kernel netlink
# rather than logcat), so this fallback path only matters when the binary is
# absent (wrong ABI or not built).
_GED_LOGCAT_FAST_EXITS=0
_GED_USE_PROC_POLL=false
_GED_SCAN_COUNT=0

while true; do

_startup_scan

if [ "$_GED_USE_PROC_POLL" = "true" ]; then
  # /proc poll mode: logcat is unavailable. _startup_scan above detects new
  # game launches by scanning all /proc/[0-9]*/cmdline entries.
  # 5s interval: reduces the ~300-600 file reads/scan to at most 12/min.
  # Detection lag is acceptable in this fallback path (native binary preferred).
  sleep 5
  continue
fi

# ── Main event loop ───────────────────────────────────────────────────────────
# logcat -b events streams Android's binary event log buffer.
#
# am_proc_start event format — tag ID 30014, stable since Android 4.x:
#   (User|1|5),(PID|1|5),(UID|1|5),(Process Name|3),(Type|3),(Component|3)
#
# Example line with -v brief (what we use):
#   I/am_proc_start(1): [0,9876,10123,com.tencent.ig,activity,com.tencent.ig/.MainActivity]
#
# Comma-separated fields inside the brackets (1-indexed):
#   1 = user         (Android multi-user ID, usually 0)
#   2 = pid          (the new process's Linux PID -- what we need)
#   3 = uid          (Android app UID, e.g. 10123)
#   4 = package name (what we need to match against exclusion list)
#   5 = type         (activity / service / provider / receiver)
#   6 = component    (full package/class component name)
#
# FORMAT NOTES — why we use -v brief and not -v raw:
#
#   -v raw (BROKEN):
#     Strips the event tag entirely from output. A line looks like:
#       [0,9876,10123,com.tencent.ig,activity,com.tencent.ig/.MainActivity]
#     The string "am_proc_start" is completely absent.
#     The *am_proc_start* pre-filter below NEVER matches.
#     Result: zero games ever detected. This was the original bug.
#
#   -v brief (what we specify):
#     Outputs: I/am_proc_start(PID): [fields]
#     The tag is always present. Pre-filter matches. Parser finds '[' correctly.
#     Consistent across all Android versions (4.x through 15+).
#
#   No -v flag (DO NOT USE):
#     Default varies by Android version — "brief" on Android ≤6, "threadtime"
#     on Android ≥7.  threadtime output looks like:
#       MM-DD HH:MM:SS.mmm  PID  TID  I  am_proc_start: [...]
#     The tag is still present so the pre-filter would still match, but the
#     format is device-version-dependent. Specifying -v brief is safer and
#     produces the simplest, most predictable output.
#
# The read() syscall on this pipe blocks in TASK_INTERRUPTIBLE inside the
# kernel's pipe wait queue (logd uses epoll internally). Zero CPU between
# process-start events -- the daemon is truly asleep in the kernel.
# Record the start time using /proc/uptime (integer seconds since boot) as the
# primary source — available on every Android kernel regardless of toybox/busybox
# date capabilities.  date +%s is tried first as it returns wall-clock seconds and
# avoids any wrap-around concern, but /proc/uptime is the reliable fallback.
_uptime_secs() {
  local _u
  if { IFS= read -r _u; } < /proc/uptime 2>/dev/null; then
    # /proc/uptime: "<total_uptime_secs>.<hundredths> <idle_secs>"
    # Strip decimal and idle columns to get integer uptime seconds.
    _u="${_u%%.*}"
    echo "${_u:-0}"
  else
    echo 0
  fi
}
_logcat_t0=$(date +%s 2>/dev/null) || _logcat_t0=$(_uptime_secs)
logcat -b events -v brief -T 1 2>/dev/null | while IFS= read -r _line; do

  # ── Fast pre-filter ───────────────────────────────────────────────────────
  # The events buffer contains many event types (gc_heap_info, am_activity_launch,
  # binder_sample, etc.). Skip everything that is not am_proc_start with a single
  # case match -- this is a pattern match in the shell interpreter, no fork needed.
  case "$_line" in
    *am_proc_start*) ;;
    *) continue ;;
  esac

  # ── Extract bracket payload ───────────────────────────────────────────────
  # Strip everything up to and including the '[' after "am_proc_start", then
  # everything from the first ']' onward. Result: "user,pid,uid,pkg,type,comp"
  _payload="${_line#*am_proc_start*[}"
  # Verify the substitution matched (if no '[' was found _payload equals _line)
  [ "$_payload" = "$_line" ] && continue
  _payload="${_payload%%]*}"

  # ── Parse comma-separated fields (no subprocess -- pure parameter expansion) ─
  _rest="${_payload#*,}"                            # skip field 1 (user) — not needed
  _pid="${_rest%%,*}";    _rest="${_rest#*,}"       # field 2 = pid
  _rest="${_rest#*,}"                               # skip field 3 (uid) — not needed
  _pkg="${_rest%%,*}"                               # field 4 = package

  # ── Trim leading/trailing spaces ──────────────────────────────────────────
  _pid="${_pid## }"; _pid="${_pid%% }"
  _pkg="${_pkg## }"; _pkg="${_pkg%% }"

  # Strip :processname suffix (e.g. "com.tencent.ig:remote" -> "com.tencent.ig")
  _pkg="${_pkg%%:*}"

  # ── Validate PID: must be a non-empty string of digits only ──────────────
  case "$_pid" in
    ''|*[!0-9]*) continue ;;
  esac

  # ── Validate package: must be non-empty ──────────────────────────────────
  [ -z "$_pkg" ] && continue

  # ── Check against exclusion list ─────────────────────────────────────────
  # _game_pkg_excluded() is an O(n) scan; fast for <50 entries.
  # Only called once per process-start event, not on every poll iteration.
  _game_pkg_excluded "$_pkg" || continue

  # ── Game launch confirmed ─────────────────────────────────────────────────
  echo "[ADRENO-GED] DETECTED: ${_pkg} (PID=${_pid})" \
    > /dev/kmsg 2>/dev/null || true

  # Register game: increment counter, switch renderer if first active game
  _game_open "$_pkg" "$_pid"

  # Spawn a sub-daemon to watch this specific PID.
  # The sub-daemon inherits all functions from this shell session and runs
  # independently until the game process exits. & = background, no blocking.
  _wait_game_death "$_pkg" "$_pid" &

  # Clean up local parse variables so they don't bleed into the next iteration.
  unset _payload _rest _pid _pkg 2>/dev/null || true

done
# ── Pipe exited — check for SELinux-blocked logcat ────────────────────────────
_logcat_t1=$(date +%s 2>/dev/null) || _logcat_t1=$(_uptime_secs)
_logcat_runtime=$(( _logcat_t1 - _logcat_t0 ))

if [ "$_logcat_runtime" -lt 2 ]; then
  # logcat exited suspiciously fast — count consecutive fast exits.
  # Root cause: SELinux blocks the 'events' log buffer read for this process
  # context on some OEM ROMs. The pipe opens and closes without blocking.
  _GED_LOGCAT_FAST_EXITS=$(( _GED_LOGCAT_FAST_EXITS + 1 ))
  echo "[ADRENO-GED] logcat exited in ${_logcat_runtime}s (fast exit #${_GED_LOGCAT_FAST_EXITS})" \
    > /dev/kmsg 2>/dev/null || true

  if [ "$_GED_LOGCAT_FAST_EXITS" -ge 3 ]; then
    # 3 consecutive sub-2s exits: logcat is permanently unavailable.
    # Switch to /proc-poll mode. The native ged.c binary is immune to this
    # issue (uses NETLINK_CONNECTOR proc events, not logcat). If this message
    # appears, the native binary should be preferred.
    _GED_USE_PROC_POLL=true
    echo "[ADRENO-GED] WARNING: logcat unavailable after ${_GED_LOGCAT_FAST_EXITS} fast exits" \
      > /dev/kmsg 2>/dev/null || true
    echo "[ADRENO-GED] WARNING: switching to /proc-poll mode (5s interval)" \
      > /dev/kmsg 2>/dev/null || true
    echo "[ADRENO-GED] NOTE: native adreno_ged binary is immune to this -- prefer binary over shell" \
      > /dev/kmsg 2>/dev/null || true
    # No sleep — loop immediately to start polling
    continue
  fi
else
  # logcat ran for a reasonable time — reset fast-exit counter.
  _GED_LOGCAT_FAST_EXITS=0
fi

echo "[ADRENO-GED] logcat pipe exited -- restarting in 5s" \
  > /dev/kmsg 2>/dev/null || true
sleep 5

done  # outer while true

