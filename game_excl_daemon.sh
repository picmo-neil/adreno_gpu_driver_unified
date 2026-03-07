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
#     a streaming logcat session against that buffer. The read() syscall
#     on the logcat pipe blocks in TASK_INTERRUPTIBLE state inside the
#     kernel (the pipe is backed by logd's epoll loop). Between game
#     launches the daemon is parked in the kernel — zero CPU, zero
#     wakeups. It wakes only when logd has a new event line ready.
#     One logcat process covers ALL packages in the exclusion list.
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

# ── Atomic locking helpers ────────────────────────────────────────────────────
# mkdir is atomic on ext4 (Android >= 4.4) and F2FS (Android >= 9).
# 200-iteration cap: prevents infinite spin if a SIGKILL'd holder left the lock.
# At ~1 us per failed mkdir attempt, 200 iterations = ~200 us worst-case spin.
_acquire_lock() {
  local _i=0
  while ! mkdir "$_LOCK_DIR" 2>/dev/null; do
    _i=$((_i + 1))
    if [ $_i -ge 200 ]; then
      # Stale lock: force-remove and re-acquire
      rmdir "$_LOCK_DIR" 2>/dev/null || rm -rf "$_LOCK_DIR" 2>/dev/null || true
      mkdir "$_LOCK_DIR" 2>/dev/null || true
      break
    fi
  done
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
_set_renderer() {
  local _r="$1"
  if command -v resetprop >/dev/null 2>&1; then
    resetprop debug.hwui.renderer "$_r" 2>/dev/null
  else
    setprop debug.hwui.renderer "$_r" 2>/dev/null || true
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

  if [ "$_cnt" -eq 0 ]; then
    # Last excluded game exited -- restore Vulkan renderer
    _set_renderer "$_SKIAVK_MODE"
    # Clear state file so service.sh GOS watchdog stops watching
    printf '0\n' > "$_GED_ACTIVE_FILE" 2>/dev/null || true
    echo "[ADRENO-GED] GAME CLOSED: ${_pkg} (PID=${_pid}) -- active=0 -> ${_SKIAVK_MODE}" \
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
  local _pkg="$1" _pid="$2"

  # Handle the race where the process already exited before we started watching
  if [ ! -d "/proc/${_pid}" ]; then
    _game_closed "$_pkg" "$_pid"
    return
  fi

  # Zero-overhead sleep loop: wakes every 1 second, checks /proc/$PID
  while [ -d "/proc/${_pid}" ]; do
    sleep 1
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
_startup_scan() {
  local _dir _pid _cmdline _pkg
  echo "[ADRENO-GED] startup scan: checking for running excluded games..." \
    > /dev/kmsg 2>/dev/null || true

  for _dir in /proc/[0-9]*; do
    _pid="${_dir##*/}"
    [ -d "$_dir" ] || continue

    # Read the process cmdline file (NUL-separated argv array)
    _cmdline=""
    { IFS= read -r _cmdline; } < "${_dir}/cmdline" 2>/dev/null || continue
    [ -z "$_cmdline" ] && continue

    # Extract the package name from argv[0]:
    #   - Strip :processname suffix (e.g. com.tencent.ig:remote)
    #   - Strip NUL bytes that may appear from the raw read
    _pkg="${_cmdline%%:*}"
    _pkg="${_pkg%%${_pkg##*[! ]}}"    # rtrim spaces (POSIX parameter expansion)
    _pkg="${_pkg##"${_pkg%%[! ]*}"}"  # ltrim spaces
    # Strip any embedded NUL (shell reads NUL as end-of-string on most Android sh)
    _pkg="${_pkg%%$'\0'*}"

    [ -z "$_pkg" ] && continue

    _game_pkg_excluded "$_pkg" || continue

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
    _set_renderer "$_SKIAVK_MODE"
    printf "0\n" > "$_GED_ACTIVE_FILE" 2>/dev/null || true
    echo "[ADRENO-GED] SIGTERM: restored ${_SKIAVK_MODE} (was skiagl, count=${_trap_cnt})" \
      > /dev/kmsg 2>/dev/null || true
  fi
  rm -f "$_DAEMON_PID_FILE" "$_ACTIVE_COUNT_FILE" "$_GED_ACTIVE_FILE" 2>/dev/null || true
  rmdir "$_LOCK_DIR" 2>/dev/null || true
  exit 0
' TERM INT

# ── Initialize state ──────────────────────────────────────────────────────────
printf '%s\n' "$$" > "$_DAEMON_PID_FILE" 2>/dev/null || true
printf '0\n'       > "$_ACTIVE_COUNT_FILE" 2>/dev/null || true
printf '0\n'       > "$_GED_ACTIVE_FILE" 2>/dev/null || true
rmdir "$_LOCK_DIR" 2>/dev/null || true  # clear any stale lock from a previous crash

echo "[ADRENO-GED] Started (PID=$$, restore_mode=${_SKIAVK_MODE})" \
  > /dev/kmsg 2>/dev/null || true

# ── Startup scan (one-time, before main loop) ─────────────────────────────────
_startup_scan

# ── Main event loop ───────────────────────────────────────────────────────────
# logcat -b events streams Android's binary event log buffer.
#
# am_proc_start event format (logcat -v raw output):
#   I am_proc_start: [user,pid,uid,package,type,component]
#
# Example line:
#   I am_proc_start: [0,9876,10123,com.tencent.ig,activity,com.tencent.ig/.MainActivity]
#
# Comma-separated fields inside the brackets (1-indexed):
#   1 = user         (Android multi-user ID, usually 0)
#   2 = pid          (the new process's Linux PID -- what we need)
#   3 = uid          (Android app UID, e.g. 10123)
#   4 = package name (what we need to match against exclusion list)
#   5 = type         (activity / service / provider / receiver)
#   6 = component    (full package/class component name)
#
# -v raw: strips logcat timestamp/header prefix so each line is just the
# tag and payload. Simplifies parsing and avoids extra string allocation.
#
# The read() syscall on this pipe blocks in TASK_INTERRUPTIBLE inside the
# kernel's pipe wait queue (logd uses epoll internally). Zero CPU between
# process-start events -- the daemon is truly asleep in the kernel.
logcat -b events -v raw 2>/dev/null | while IFS= read -r _line; do

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
  _f1="${_payload%%,*}";  _rest="${_payload#*,}"   # discard field 1 (user)
  _pid="${_rest%%,*}";    _rest="${_rest#*,}"       # field 2 = pid
  _uid="${_rest%%,*}";    _rest="${_rest#*,}"       # discard field 3 (uid)
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

done
# ── Pipe exit ─────────────────────────────────────────────────────────────────
# logcat should never exit during normal operation. If it does (e.g. logd
# restart, OOM kill of logcat itself), wait 5 seconds and re-exec this daemon
# to restore the monitoring. Pass the restore mode through the re-exec.
echo "[ADRENO-GED] logcat pipe exited unexpectedly -- restarting in 5s" \
  > /dev/kmsg 2>/dev/null || true
sleep 5
exec /system/bin/sh "$0" "$_SKIAVK_MODE"
