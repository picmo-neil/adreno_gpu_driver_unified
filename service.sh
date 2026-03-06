#!/system/bin/sh
# Adreno GPU Driver - Service Script
# Compatible with: Magisk, KernelSU, APatch
# Runs in late_start service mode (NON-BLOCKING)
# Executes after boot_completed, modules mounted, and Zygote started.

MODDIR="${0%/*}"

# ========================================
# SHARED FUNCTIONS
# ========================================

. "$MODDIR/common.sh"

# ── SHARED GAME EXCLUSION LIST ────────────────────────────────────────────────
# Defines GAME_EXCLUSION_PKGS and _game_pkg_excluded() used in force-stop loops
# and the game-compatibility daemon. Edit via Adreno Manager WebUI.
_GAME_EXCL_SD="/sdcard/Adreno_Driver/Config/game_exclusion_list.sh"
_GAME_EXCL_DATA="/data/local/tmp/adreno_game_exclusion_list.sh"
_GAME_EXCL_MOD="${MODDIR}/game_exclusion_list.sh"
if [ -f "$_GAME_EXCL_SD" ]; then
  . "$_GAME_EXCL_SD"
elif [ -f "$_GAME_EXCL_DATA" ]; then
  . "$_GAME_EXCL_DATA"
elif [ -f "$_GAME_EXCL_MOD" ]; then
  . "$_GAME_EXCL_MOD"
else
  # Default list covers TWO distinct rendering problems under skiavk:
  #
  # GROUP 1 — Dual-VkDevice crash (UE4 / native-Vulkan games):
  #   Game engine creates a VkDevice from its RHI thread. HWUI in skiavk mode
  #   creates a second VkDevice for the Activity window in the same process.
  #   Custom Adreno drivers cannot handle concurrent vkCreateDevice calls →
  #   SIGSEGV in libgsl.so / VK_ERROR_DEVICE_LOST. Fix: switch HWUI to skiagl
  #   so only ONE VkDevice exists in the process (the game engine's).
  #
  # GROUP 2 — Green line artifact (Meta apps: Facebook/Instagram/WhatsApp):
  #   HWUI Vulkan swapchain allocates buffers in UBWC compressed format.
  #   Meta apps' native render layers (React Native canvas, libvpx media) use
  #   gralloc buffers with a DIFFERENT UBWC tile layout expectation. When
  #   SurfaceFlinger composites both surfaces, the UBWC metadata mismatch
  #   causes color channel corruption on specific scan lines → green line.
  #   Fix: switch HWUI to skiagl for Meta apps → GL buffers → no UBWC mismatch.
  #
  # This list is the authoritative source for BOTH behaviors:
  #   • These packages are NEVER force-stopped during skiavk_all
  #   • These packages trigger the skiagl renderer switch when running
  GAME_EXCLUSION_PKGS="com.tencent.ig com.pubg.krmobile com.pubg.imobile com.vng.pubgmobile com.rekoo.pubgm com.tencent.tmgp.pubgmhd com.epicgames.* com.activision.callofduty.shooter com.garena.game.codm com.tencent.tmgp.cod com.vng.codmvn com.miHoYo.GenshinImpact com.cognosphere.GenshinImpact com.miHoYo.enterprise.HSRPrism com.HoYoverse.hkrpgoversea com.levelinfinite.hotta com.proximabeta.mfh com.HoYoverse.Nap com.miHoYo.ZZZ com.facebook.katana com.facebook.orca com.facebook.lite com.facebook.mlite com.instagram.android com.instagram.lite com.whatsapp com.whatsapp.w4b"
  _game_pkg_excluded() { local _p="$1" _e; for _e in $GAME_EXCLUSION_PKGS; do case "$_p" in $_e) return 0;; esac; done; return 1; }
fi
unset _GAME_EXCL_SD _GAME_EXCL_DATA _GAME_EXCL_MOD
# ─────────────────────────────────────────────────────────────────────────────

cmd_exists() {
  command -v "$1" >/dev/null 2>&1
}

safe_read() {
  local _sr
  { IFS= read -r _sr; } < "$1" 2>/dev/null && printf '%s' "${_sr%$'\r'}"
}

# ========================================
# CONFIGURATION LOADING
# ========================================

VERBOSE="n"
ARM64_OPT="n"
QGL="n"
PLT="n"
RENDER_MODE="normal"

CONFIG_FILE="/sdcard/Adreno_Driver/Config/adreno_config.txt"
ALT_CONFIG="$MODDIR/adreno_config.txt"

if ! load_config "$CONFIG_FILE"; then
  load_config "$ALT_CONFIG" || true
fi

[ "$VERBOSE" != "y" ]   && VERBOSE="n"
[ "$ARM64_OPT" != "y" ] && ARM64_OPT="n"
[ "$QGL" != "y" ]       && QGL="n"
[ "$PLT" != "y" ]       && PLT="n"
[ -z "$RENDER_MODE" ]   && RENDER_MODE="normal"
# BUG7 FIX: Normalize RENDER_MODE to lowercase so case statements match
# regardless of how the user wrote it in the config (SkiaVK, SKIAVK, etc.).
RENDER_MODE=$(printf '%s' "$RENDER_MODE" | tr '[:upper:]' '[:lower:]')

# ========================================
# LOGGING SYSTEM
# ========================================

if [ "$VERBOSE" = "y" ]; then
  LOG_BASE="/data/local/tmp/Adreno_Driver"
  TIMESTAMP=$(date +%Y%m%d_%H%M%S 2>/dev/null || echo 'unknown')
  SERVICE_LOG="$LOG_BASE/Booted/service_${TIMESTAMP}.log"

  LOG_CREATED=false
  for log_path in "$LOG_BASE" "/data/local/tmp/Adreno_Driver" "/cache/Adreno_Driver" "/tmp"; do
    if mkdir -p "$log_path/Booted" 2>/dev/null; then
      if touch "$log_path/Booted/.test" 2>/dev/null && rm "$log_path/Booted/.test" 2>/dev/null; then
        LOG_BASE="$log_path"
        SERVICE_LOG="$log_path/Booted/service_${TIMESTAMP}.log"
        LOG_CREATED=true
        break
      fi
    fi
  done

  if [ "$LOG_CREATED" = "false" ]; then
    LOG_BASE="/dev"
    SERVICE_LOG="/dev/kmsg"
  fi

  if ! {
    echo "========================================"
    echo "Adreno GPU Driver - Service Script"
    echo "========================================"
    echo "Service start time: $(date)"
    echo "========================================"
    echo ""
  } > "$SERVICE_LOG" 2>/dev/null; then
    SERVICE_LOG="/dev/kmsg"
  fi
else
  SERVICE_LOG="/dev/null"
  LOG_BASE="/dev"
fi

if [ "$VERBOSE" = "y" ]; then
  log_service() {
    local _t; read _t _ < /proc/uptime 2>/dev/null || _t='?'
    echo "[ADRENO-SVC][${_t}s] $1" >> "$SERVICE_LOG" 2>/dev/null || \
    echo "[ADRENO-SVC] $1" > /dev/kmsg 2>/dev/null || true
  }
else
  log_service() { :; }
fi

log_service "service.sh started"
log_service "MODDIR: $MODDIR"

# ========================================
# ROOT ENVIRONMENT DETECTION
# ========================================

log_service "Detecting root environment..."

ROOT_TYPE="Unknown"
SUSFS_ACTIVE=false
METAMODULE_ACTIVE=false

# Check KernelSU kernel module presence inline (must yield correct exit code).
# Note: unset must come after the boolean test, not after "false"/"true" builtins.
_km=false
while IFS= read -r _kl; do
  case "$_kl" in *kernelsu*) _km=true; break;; esac
done < /proc/modules 2>/dev/null

if [ "${KSU:-false}" = "true" ] || [ "${KSU_KERNEL_VER_CODE:-0}" -gt 0 ] || \
   [ -f "/data/adb/ksu/bin/ksud" ] || [ -d "/data/adb/ksu" ] || \
   [ "$_km" = "true" ] || [ -e "/dev/ksu" ]; then
  ROOT_TYPE="KernelSU"
  log_service "Root: KernelSU detected"
else
  IFS= read -r _pv < /proc/version 2>/dev/null
  if [ "${APATCH:-false}" = "true" ] || [ "${APATCH_VER_CODE:-0}" -gt 0 ] || \
     [ -f "/data/adb/apd" ] || [ -d "/data/adb/ap" ] || \
     { case "${_pv:-}" in *APatch*) true;; *) false;; esac; }; then
    ROOT_TYPE="APatch"
    log_service "Root: APatch detected"
  elif [ -n "${MAGISK_VER:-}" ] || [ "${MAGISK_VER_CODE:-0}" -gt 0 ] || \
       [ -f "/data/adb/magisk/magisk" ]; then
    ROOT_TYPE="Magisk"
    log_service "Root: Magisk detected"
  else
    log_service "Root: Unknown type"
  fi
  unset _pv
fi
unset _km _kl

# ========================================
# SUSFS DETECTION
# ========================================

log_service "Checking for SUSFS (root hiding)..."

if [ -f "/sys/kernel/susfs/version" ] || \
   { [ -d "/data/adb/modules/susfs4ksu" ] && [ ! -f "/data/adb/modules/susfs4ksu/disable" ]; } || \
   [ -f "/data/adb/ksu/bin/ksu_susfs" ]; then
  SUSFS_ACTIVE=true
  log_service "SUSFS: Active (root hiding enabled)"
else
  log_service "SUSFS: Not detected"
fi

# ========================================
# METAMODULE DETECTION
# ========================================

log_service "Detecting mounting solution..."

detect_metamodule
if [ "$METAMODULE_ACTIVE" = "true" ]; then
  log_service "Metamodule: Active - $METAMODULE_NAME ($METAMODULE_ID)"
else
  log_service "Metamodule: Not detected"
fi

# ========================================
# LOAD CONFIGURATION (report only — already loaded above)
# ========================================

log_service "Loading configuration..."

if [ -f "$CONFIG_FILE" ]; then
  log_service "Config loaded from SD Card"
elif [ -f "$ALT_CONFIG" ]; then
  log_service "Config loaded from module directory"
else
  log_service "No config file found, using defaults"
fi

log_service "Configuration: ARM64_OPT=$ARM64_OPT, QGL=$QGL, PLT=$PLT, RENDER_MODE=$RENDER_MODE"

# ========================================
# WAIT FOR BOOT COMPLETION
# ========================================

log_service "Waiting for boot completion..."

TIMEOUT=300
ELAPSED=0

if cmd_exists resetprop; then
  log_service "Using resetprop -w for boot wait (efficient)"
  (
    sleep $TIMEOUT
    kill $$ 2>/dev/null
  ) &
  TIMEOUT_PID=$!

  resetprop -w sys.boot_completed 1 2>/dev/null

  kill $TIMEOUT_PID 2>/dev/null || true
  wait $TIMEOUT_PID 2>/dev/null || true

  if [ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ]; then
    log_service "Boot completed (resetprop -w)"
  else
    log_service "WARNING: Boot completion timeout or failed"
  fi
else
  while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ]; do
    sleep 1
    ELAPSED=$((ELAPSED + 1))
    if [ $ELAPSED -ge $TIMEOUT ]; then
      log_service "WARNING: Boot timeout after ${TIMEOUT}s - continuing anyway"
      break
    fi
    if [ $((ELAPSED % 30)) -eq 0 ]; then
      log_service "Still waiting for boot... (${ELAPSED}s)"
    fi
  done
  if [ $ELAPSED -lt $TIMEOUT ]; then
    log_service "Boot completed after ${ELAPSED}s"
  fi
fi

sleep 2  # was 5s — 5s window caused black screen on unlock (OEM init.d scripts reset props)
        # (OEM init.d scripts reset props during this window; 2s is sufficient)
log_service "System services stabilization delay complete (2s; was 5s)"

# ==========================================================================
# BLOCK F — VK compat report to boot log
# Single-source-of-truth compat summary — appears right after boot complete
# so any reader of the log immediately knows the device's compat state.
# ==========================================================================
if [ -f "/data/local/tmp/adreno_vk_compat_score" ]; then
  _rep_score="" _rep_level="" _rep_gralloc="" _rep_reasons="" _rep_gap=""
  while IFS='=' read -r _rk _rv; do
    case "$_rk" in
      SCORE)    _rep_score="${_rv}"   ;;
      LEVEL)    _rep_level="${_rv}"   ;;
      GRALLOC)  _rep_gralloc="${_rv}" ;;
      REASONS)  _rep_reasons="${_rv}" ;;
      GAP_DAYS) _rep_gap="${_rv}"     ;;
    esac
  done < "/data/local/tmp/adreno_vk_compat_score" 2>/dev/null
  unset _rk _rv
  log_service "========================================"
  log_service "VK COMPAT REPORT (post-fs-data probe results)"
  log_service "  Score    : ${_rep_score:-?}/100  Level: ${_rep_level:-?}"
  log_service "  Gralloc  : ${_rep_gralloc:-?}"
  log_service "  Date gap : ~${_rep_gap:-?} days"
  [ -n "$_rep_reasons" ] && log_service "  Reasons  : ${_rep_reasons}"
  log_service "========================================"
  unset _rep_score _rep_level _rep_gralloc _rep_reasons _rep_gap
fi
if [ -f "/data/local/tmp/adreno_skiavk_degraded" ]; then
  { IFS= read -r _deg_reason; } < "/data/local/tmp/adreno_skiavk_degraded" 2>/dev/null
  log_service "========================================"
  log_service "[!] AUTO-DEGRADE APPLIED THIS BOOT"
  log_service "  Reason  : ${_deg_reason:-unknown}"
  log_service "  skiavk config preserved — override survives to next boot."
  log_service "  To force-retry: touch /data/local/tmp/adreno_skiavk_force_override"
  log_service "========================================"
  unset _deg_reason
fi
# ══ END BLOCK F ══════════════════════════════════════════════════════════

# ========================================
# FIRST BOOT CHECK
# ========================================
# post-fs-data.sh creates .service_skip_render when it detects first boot
# (FIRST_BOOT_PENDING). post-fs-data.sh defers the renderer during boot, but
# service.sh runs independently in late_start and has no other way to know
# it's first boot — the .first_boot_pending marker is already gone by now.
# Without this check, service.sh would resetprop skiavk at boot_completed+2s
# → every app opened after that point starts with skiavk, Vulkan not yet
# validated → crash popup on every app open all session.
if [ -f "$MODDIR/.service_skip_render" ]; then
  rm -f "$MODDIR/.service_skip_render" 2>/dev/null
  log_service "========================================"
  log_service "FIRST BOOT DETECTED — skipping renderer activation this boot."
  log_service "Renderer props will NOT be set via resetprop or written to system.prop."
  log_service "Reason: Vulkan/GL driver not yet validated. Second boot will activate $RENDER_MODE renderer."
  log_service "NOTE: This boot uses the system-default renderer. All other stability props remain active."
  log_service "========================================"
  # Continue to run the rest of service.sh (QGL, PLT, stats, etc.)
  # but skip all renderer prop setting by overriding RENDER_MODE to normal.
  RENDER_MODE="normal"
fi

# ========================================
# EARLY RENDERER ENFORCEMENT
# ========================================
# Fires at boot_completed + 5s — before OEM late_start init.d scripts can
# reset renderer props. Sets the renderer props via resetprop so that all
# NEW app processes spawned after this point use the configured renderer.
#
# SystemUI crash: REMOVED (was here previously, caused all user-reported issues).
# See the detailed comment block below for full root cause analysis.
# Summary: am crash systemui at boot+15s → black screen + GMS account loss +
# Facebook/Messenger crash + Android watchdog-triggered reboot to ROM logo.
#
# New approach: props-only enforcement. SystemUI itself keeps its current renderer
# for this session (invisible to user), but all user-opened apps after boot+5s
# use the configured renderer. On next boot, system.prop delivers the correct
# renderer to EVERY process including SystemUI from first init.
#
# skiavk_all: the background subshell (launched below) runs the tertiary
#   pipeline cache clear and confirms the renderer prop is live.
#   SystemUI is NOT crashed in any mode (stability fix — KGSL corruption prevention).
# ========================================
if cmd_exists resetprop; then
  case "$RENDER_MODE" in
    skiavk|skiavk_all)
      resetprop debug.hwui.renderer skiavk 2>/dev/null || true
      # debug.renderengine.backend intentionally NOT live-resetprop'd here.
      # SF is running at boot_completed+5s — OEM ROM change callbacks fire and
      # crash SurfaceFlinger. Set exclusively before SF starts in post-fs-data.sh.
      log_service "[OK] Early enforcement: skiavk hwui.renderer set (renderengine.backend pre-SF only)"
      ;;
    skiagl)
      resetprop debug.hwui.renderer skiagl 2>/dev/null || true
      # debug.renderengine.backend intentionally NOT live-resetprop'd here.
      # Same rationale as skiavk: OEM ROM callbacks crash SF if set at runtime.
      log_service "[OK] Early enforcement: skiagl hwui.renderer set (renderengine.backend pre-SF only)"
      ;;
  esac
fi
# ── SystemUI crash: REMOVED for skiavk and skiagl modes ─────────────────────
#
# ROOT CAUSE OF ALL USER-REPORTED CRASHES AND GMS ACCOUNT LOSS:
#
# The original code crashed SystemUI at boot_completed+15s (5s settle + 10s sleep).
# This caused the following cascade:
#
#   1. BLACK SCREEN / SCREEN BLANK:
#      am crash at +15s fires exactly when the user has just unlocked the phone.
#      SystemUI (status bar, notification shade, launcher wallpaper layer) is
#      the parent window for all surface compositing. When it crashes, SurfaceFlinger
#      briefly loses layer references → 1–5s black screen that the user sees.
#
#   2. ROM LOGO BOOTLOOP:
#      During the 1–5s SystemUI restart, SurfaceFlinger's layer graph is broken.
#      If ANY other process crashes during this window (common — many processes
#      race to init at boot+15s), Android's watchdog counts 3+ crashes within
#      5 minutes → triggers a system_server watchdog reboot → ROM logo appears
#      (recovery/bootloader splash), making it look like a bootloop.
#
#   3. GOOGLE ACCOUNTS DISAPPEAR FROM SETTINGS:
#      When SystemUI crashes, ALL active Binder IPC connections rooted at the
#      SystemUI process are invalidated system-wide (Binder is reference-counted;
#      the process death drops all references). GMS AccountManager is mid-sync
#      at boot+15s (OAuth token refresh, account credential validation). It holds
#      a live Binder to SystemUI's AccountManagerService proxy. The crash delivers
#      a DeadObjectException to AccountManager's sync thread → AccountManager
#      marks ALL OAuth tokens invalid and removes the Google account from Settings
#      entirely. The user sees "all Google accounts gone" immediately after the
#      screen flash.
#
#   4. FACEBOOK / MESSENGER CRASH:
#      Meta apps (Facebook, Messenger, Instagram) hold ANativeWindow references
#      obtained via SurfaceFlinger during their first draw. When SystemUI crashes
#      and SurfaceFlinger loses layer references, these ANativeWindow handles
#      become dangling. On the next draw call, the Vulkan/GLES driver dereferences
#      the stale handle → SIGSEGV or VK_ERROR_SURFACE_LOST → app crashes.
#      Additionally, if GMS token refresh was in-flight (see #3), token corruption
#      causes immediate OAuth failure on Facebook's next API call → app crashes.
#
#   5. 5–10 MINUTE APP CRASH WINDOW:
#      Recovery period after SystemUI crash. GMS AccountManager rebuilds its
#      Binder service mesh (AccountManagerService, GmsCore, GSF) which takes
#      15–25s. Apps that call any GMS API during this window get RemoteException
#      → crash on launch. User sees "every app crashes for 5–10 minutes after boot".
#
# WHY THE CRASH WAS UNNECESSARY IN THE FIRST PLACE:
#   debug.hwui.renderer is read ONCE per process at first HWUI init, then cached
#   as a static variable (sRenderPipelineType in RenderThread.cpp / Properties.cpp).
#   resetprop sets the prop live at boot_completed+5s (see block above). Any NEW
#   process spawned after boot_completed+5s automatically reads the new prop and
#   uses the configured renderer. SystemUI itself keeps its current renderer for
#   this session — it is rendering at 60+ fps and is invisible to the user. On
#   the NEXT reboot, system.prop (written by service.sh ~boot_completed+5s) delivers
#   debug.hwui.renderer=skiavk/skiagl to EVERY process including SystemUI from
#   first init — no crash ever needed.
#
# FIX: Remove the crash entirely for ALL modes including skiavk_all.
# skiavk/skiagl: post-fs-data.sh background task (fired ~boot+15s) force-stops
#   3rd-party apps so they cold-start with the new renderer. service.sh only
#   re-enforces props here (belt-and-suspenders against OEM override).
# skiavk_all: background subshell below additionally force-stops system UI packages.
# SystemUI is NOT crashed in any mode. Next reboot: all procs get the renderer from init.
case "$RENDER_MODE" in
  skiavk|skiagl|skiavk_all)
    # BUG5 FIX: Original message claimed "SystemUI NOT crashed" at boot+2s, before
    # any crash check has been performed. Replaced with accurate status message.
    log_service "[OK] $RENDER_MODE: renderer prop enforced via resetprop at boot+2s; SystemUI NOT actively crashed (GMS/accounts protected)"
    ;;
esac

# ========================================
# APP-TRIGGERED RENDERER SWITCHING DAEMON
# ========================================
# Monitors GAME_EXCLUSION_PKGS and switches debug.hwui.renderer between
# skiagl (when an excluded package is running) and the original renderer
# (when all excluded packages have exited). Covers two rendering problems:
#
# PROBLEM 1 — Dual-VkDevice crash (UE4 / native-Vulkan games):
#   UE4/game engine creates a VkDevice from its RHI thread. HWUI in skiavk
#   mode creates a SECOND VkDevice for the Activity window in the SAME process.
#   Custom Adreno drivers cannot handle two concurrent vkCreateDevice calls →
#   SIGSEGV in libgsl.so or VK_ERROR_DEVICE_LOST at match/level load.
#   Fix: skiagl → HWUI uses GL, only ONE VkDevice in process → no race.
#
# PROBLEM 2 — Green scan-line artifact (Meta apps):
#   HWUI Vulkan swapchain allocates buffers in UBWC compressed format.
#   Meta apps' native render layers (React Native canvas, libvpx media
#   decoder) allocate gralloc buffers expecting a DIFFERENT UBWC tile
#   layout. SurfaceFlinger compositor sees UBWC metadata mismatch →
#   color channel corruption on specific horizontal scan lines → green line.
#   Fix: skiagl → HWUI uses GL buffers → no UBWC format mismatch.
#
# ARCHITECTURE — Zygisk hook + /proc polling:
#
#   PATH A (Zygisk companion, primary — zero overhead):
#     The module's .so in zygisk/<abi>.so registers a preAppSpecialize
#     callback via the Zygisk API (ReZygisk / ZygiskNext / Magisk Zygisk).
#     This fires synchronously in the forked child at Zygote fork time —
#     BEFORE any app code, before the JVM loads, before HWUI initialises.
#     The companion (root) calls resetprop and writes the state file.
#     Detection latency: ~0ms. CPU cost: 0 between launches.
#     Requires: ReZygisk, ZygiskNext, or Magisk built-in Zygisk enabled.
#
#   PATH B (/proc polling, always running):
#     Runs regardless of Zygisk presence. Handles:
#       1. Death detection — poll /proc until all excluded pkgs exit,
#          then restore the renderer.
#       2. GOS/OEM watchdog — Samsung GOS / OEM perf daemons reset
#          debug.hwui.renderer during game sessions. Re-apply skiagl.
#       3. Launch fallback — detects games when Zygisk is not active,
#          or in the rare case the Zygisk companion call fails.
#     Interval: 3s fixed. Cost: ~1-3ms per cycle (one /proc glob walk).
#     Zero CPU between cycles (sleeping).
#
# STATE FILE: /data/local/tmp/adreno_daemon_active
#   "1" = game running, renderer = skiagl
#   "0" = no game running, renderer = restore target
#   Written by Zygisk companion (PATH A) on launch,
#   and by this polling loop (PATH B) on death/detection.
# ========================================

# ========================================
# GAME COMPATIBILITY DAEMON
# ========================================
# Switches debug.hwui.renderer to skiagl while a listed game is running
# (prevents dual-VkDevice crash on UE4/native-Vulkan titles), then
# restores the configured renderer once all listed games exit.
#
# ARCHITECTURE — two complementary paths:
#
#   PATH A: Zygisk companion (zero overhead, preferred)
#     The Zygisk .so in zygisk/<abi>.so intercepts every app launch via
#     preAppSpecialize (fires synchronously at Zygote fork, before ANY
#     app code runs). The companion (root) calls resetprop and writes
#     the state file instantly. Requires ReZygisk / ZygiskNext / Magisk
#     built-in Zygisk to be active. When Zygisk is present, launch
#     detection latency is ~0ms and this shell loop costs nothing extra.
#
#   PATH B: /proc polling (fallback, always running)
#     Required for:
#       1. Death detection — when the game process dies, restore renderer
#       2. GOS/OEM prop watchdog — Samsung GOS / OEM perf daemons reset
#          debug.hwui.renderer mid-session; poll re-applies skiagl
#       3. Launch detection fallback — when Zygisk is NOT active
#          (plain Magisk with Zygisk disabled, KSU without ReZygisk, etc.)
#     Poll interval: 3s always.
#     Cost per cycle: ~1-3ms (one /proc glob + cmdline reads per process).
#     This is the ONLY loop — the logcat am_proc_start/died event loop
#     has been completely removed (replaced by Zygisk).
#
# STATE FILE:
#   /data/local/tmp/adreno_daemon_active
#     "1" = game running, renderer = skiagl
#     "0" = no game running, renderer = restore target
#   Written by Zygisk companion on launch (PATH A) and by this loop
#   on death. Both writers are idempotent; no locking needed.
# ========================================

if [ "$RENDER_MODE" = "skiavk" ] || [ "$RENDER_MODE" = "skiavk_all" ]; then
  if cmd_exists resetprop; then

    # ── Check if adreno_ged (native binary) is already running ─────────────
    # post-fs-data.sh launches adreno_ged and writes its PID to adreno_ged_pid.
    # adreno_ged handles ALL detection via kernel interfaces (zero overhead):
    #   - Launch: netlink PROC_EVENT_FORK + PROC_EVENT_COMM
    #   - Death:  pidfd_open + epoll
    #   - Startup scan at daemon start
    # If it's alive, the full /proc polling subshell below is completely
    # redundant — it would scan /proc every second for no reason AND create a
    # second concurrent writer to debug.hwui.renderer.
    # In that case we only need a slim GOS watchdog that re-applies skiagl
    # if Samsung GOS / OEM perf daemons reset the prop mid-session.
    _GED_PID_FILE="/data/local/tmp/adreno_ged_pid"
    _GED_ACTIVE_FILE="/data/local/tmp/adreno_ged_active"
    _GED_RUNNING=false
    _ged_pid=""
    if [ -f "$_GED_PID_FILE" ]; then
      { IFS= read -r _ged_pid; } < "$_GED_PID_FILE" 2>/dev/null || _ged_pid=""
      if [ -n "$_ged_pid" ] && kill -0 "$_ged_pid" 2>/dev/null; then
        _GED_RUNNING=true
      fi
    fi

    log_service "========================================"
    log_service "GAME COMPAT DAEMON"
    if [ "$_GED_RUNNING" = "true" ]; then
      log_service "  adreno_ged running (PID=${_ged_pid}) — all detection delegated to binary"
      log_service "  Launch: netlink PROC_EVENT_FORK+COMM (zero overhead)"
      log_service "  Death : pidfd_open + epoll (zero overhead)"
      log_service "  service.sh: GOS prop watchdog only (no /proc scan)"
    else
      log_service "  adreno_ged not running — launching /proc polling fallback"
    fi
    log_service "========================================"
    unset _ged_pid _GED_PID_FILE

    if [ "$_GED_RUNNING" = "true" ]; then

      # ── GOS/OEM prop watchdog — slim, no /proc scan ─────────────────────
      # When adreno_ged state file shows a game is active (value "1"), re-apply
      # skiagl immediately if Samsung GOS or an OEM perf daemon resets the prop.
      # Sleeps 3s per cycle; does nothing (no getprop, no /proc) when no game
      # is running — truly zero overhead between game sessions.
      # Reads adreno_ged's own state file (adreno_ged_active) so there is no
      # confusion between the two binaries' state files.
      (
        _GOS_SF="$_GED_ACTIVE_FILE"  # same state file adreno_ged writes
        while true; do
          sleep 3
          { IFS= read -r _gs; } < "$_GOS_SF" 2>/dev/null || _gs="0"
          [ "$_gs" != "1" ] && continue  # no game active — nothing to watch
          _gc=$(getprop debug.hwui.renderer 2>/dev/null || echo '')
          if [ -n "$_gc" ] && [ "$_gc" != "skiagl" ]; then
            resetprop debug.hwui.renderer skiagl 2>/dev/null || true
            printf '[ADRENO][SVC-GOS] renderer reset by GOS/OEM (%s→skiagl) re-applied\n' \
              "$_gc" > /dev/kmsg 2>/dev/null || true
          fi
        done
      ) >/dev/null 2>&1 &
      log_service "[OK] GOS prop watchdog PID=$! — 3s check while game active; zero /proc scanning (adreno_ged owns detection)"

    else

      # ── Full /proc polling daemon — fallback when binary is absent ───────
      # This path only runs if adreno_ged couldn't start (binary missing,
      # SELinux denial, kernel too old for netlink, etc.).
      # Handles launch detection + death detection + GOS watchdog itself.
      (
        # FIX: restore target is always "skiavk", never "skiavk_all".
        # "skiavk_all" is not a valid debug.hwui.renderer value — HWUI silently
        # falls back to the device default for any unrecognised string.
        # skiavk_all is a boot-time force-stop mode, not a renderer name.
        _RESTORE="skiavk"

        # Fallback uses adreno_daemon_active (no ged binary, so no ged_active)
        _SF="/data/local/tmp/adreno_daemon_active"

        _any_excl_running() {
          local _cf _rb _rbase
          for _cf in /proc/[0-9]*/cmdline; do
            [ -f "$_cf" ] || continue
            { IFS= read -r _rb; } < "$_cf" 2>/dev/null || continue
            [ -n "$_rb" ] || continue
            _rbase="${_rb%%:*}"
            _game_pkg_excluded "$_rbase" && return 0
          done
          return 1
        }

        # Startup scan
        { IFS= read -r _sf_val; } < "$_SF" 2>/dev/null || _sf_val="0"
        if [ "$_sf_val" != "1" ] && _any_excl_running; then
          resetprop debug.hwui.renderer skiagl 2>/dev/null || true
          printf '1\n' > "$_SF" 2>/dev/null || true
          printf '[ADRENO][POLL-FB] startup: excl pkg running → skiagl\n' \
            > /dev/kmsg 2>/dev/null || true
        fi
        unset _sf_val

        # Poll every 1s — tighter window than old 3s to catch HWUI init in time
        while true; do
          sleep 1
          { IFS= read -r _ps; } < "$_SF" 2>/dev/null || _ps="0"
          if [ "$_ps" = "0" ]; then
            if _any_excl_running; then
              resetprop debug.hwui.renderer skiagl 2>/dev/null || true
              printf '1\n' > "$_SF" 2>/dev/null || true
              printf '[ADRENO][POLL-FB] excl pkg detected → skiagl\n' \
                > /dev/kmsg 2>/dev/null || true
            fi
          else
            _cur=$(getprop debug.hwui.renderer 2>/dev/null || echo '')
            if [ -n "$_cur" ] && [ "$_cur" != "skiagl" ]; then
              resetprop debug.hwui.renderer skiagl 2>/dev/null || true
              printf '[ADRENO][POLL-FB] GOS reset (%s→skiagl)\n' \
                "$_cur" > /dev/kmsg 2>/dev/null || true
            fi
            unset _cur
            if ! _any_excl_running; then
              resetprop debug.hwui.renderer "$_RESTORE" 2>/dev/null || true
              printf '0\n' > "$_SF" 2>/dev/null || true
              printf '[ADRENO][POLL-FB] all excl pkgs gone → %s\n' \
                "$_RESTORE" > /dev/kmsg 2>/dev/null || true
            fi
          fi
        done
      ) >/dev/null 2>&1 &
      log_service "[OK] Fallback game compat daemon PID=$! — 1s /proc poll (adreno_ged not running), skiagl↔skiavk"

    fi

    unset _GED_RUNNING _GED_ACTIVE_FILE
  fi
fi

# ========================================
# SECONDARY SKIA PIPELINE CACHE CLEARING
# ========================================
# post-fs-data.sh performs the PRIMARY cache clear before Zygote starts.
# This is a belt-and-suspenders secondary pass that:
#   1. Catches any caches created/modified between post-fs-data and here
#   2. Covers the skip_mount code path (post-fs-data exits early, no clear)
#   3. Runs before the sdcard wait so it still fires early in service.sh
#
# Uses the same mode-change detection: compare config RENDER_MODE against
# the last mode recorded in _LAST_MODE_FILE by the previous service.sh run.
# If post-fs-data.sh already cleared (same boot), these dirs are empty and
# the find/rm calls complete instantly — no overhead.
# ========================================

_SVC_EARLY_LAST_MODE_FILE="/data/local/tmp/adreno_last_render_mode"
_SVC_EARLY_LAST_MODE=""
if [ -f "$_SVC_EARLY_LAST_MODE_FILE" ]; then
  { IFS= read -r _SVC_EARLY_LAST_MODE; } < "$_SVC_EARLY_LAST_MODE_FILE" 2>/dev/null || _SVC_EARLY_LAST_MODE=""
fi

if [ "$RENDER_MODE" != "$_SVC_EARLY_LAST_MODE" ]; then
  log_service "========================================"
  log_service "SECONDARY CACHE CLEAR (service.sh early pass):"
  log_service "  '${_SVC_EARLY_LAST_MODE:-<none>}' → '$RENDER_MODE'"
  log_service "  Removing any caches not caught by post-fs-data.sh early clear."
  log_service "========================================"
  rm -rf /data/misc/hwui/ 2>/dev/null || true
  find /data/user_de/0 -maxdepth 2 -type d -name "app_skia_pipeline_cache" \
      -exec rm -rf {} + 2>/dev/null || true
  find /data/data -maxdepth 2 -type d -name "app_skia_pipeline_cache" \
      -exec rm -rf {} + 2>/dev/null || true
  find /data/user_de/0 -maxdepth 2 -name "*.shader_journal" -delete 2>/dev/null || true
  find /data/user_de/0 -maxdepth 2 -type d \( -name "skia_shaders" -o -name "shader_cache" \) \
      -exec rm -rf {} + 2>/dev/null || true
  log_service "[OK] Secondary Skia cache clear complete (mode changed)"
else
  log_service "SECONDARY CACHE CLEAR: mode unchanged ('$RENDER_MODE') — caches valid, preserved."
fi
unset _SVC_EARLY_LAST_MODE _SVC_EARLY_LAST_MODE_FILE

# ========================================
# SKIAVK_ALL: RENDERER ACTIVATION + CACHE VERIFICATION
# ========================================
# skiavk_all ensures the Vulkan renderer is fully active:
#   - resetprop already set debug.hwui.renderer=skiavk at boot_completed+2s
#   - Background subshell runs at boot_completed+35s (5s stabilization + 30s settle):
#       Step 0: Tertiary Skia/HWUI pipeline cache clear (belt-and-suspenders)
#       Step 1: SystemUI NOT crashed — stability fix (prevents GMS account loss +
#               Android watchdog reboot on custom ROMs)
#       Step 2: Throttled force-stop all 3rd-party apps (150ms gap, GMS/Meta excluded)
#               Makes background apps cold-start with skiavk on next user-open
#       Step 3: Throttled force-stop non-critical system UI packages (150ms gap)
#               Settings, OEM UI etc — safe to restart; telephony/BT/NFC excluded
#       Step 4: am kill-all intentionally NOT used (concurrent KGSL teardown = corruption)
#
# Throttle rationale (Steps 2 & 3): each app holds /dev/kgsl-3d0 FDs. KGSL runs
# per-FD context teardown on process death. Killing hundreds simultaneously races
# KGSL's context allocation table on custom Adreno drivers → corrupted entries →
# vkCreateDevice fails → ALL apps crash on open forever until reboot.
# 150ms between kills = serial teardown = safe.
#
# Execution model:
#   - Runs in a detached background subshell (does NOT block service.sh).
#   - Launched immediately after the 5s stabilization delay, BEFORE sdcard wait.
# ========================================

if [ "$RENDER_MODE" = "skiavk_all" ]; then
  log_service "========================================"
  log_service "SKIAVK_ALL: Launching background renderer verification subshell"
  log_service "========================================"

  (
    # Extra stabilization delay — let the home screen fully draw first.
    # INCREASED from 15s to 30s:
    #   GMS AccountManager, Play Services, and Google Services Framework take
    #   15–25s to fully bind all their Binder interfaces on MIUI/HyperOS and
    #   Samsung One UI (standard AOSP is faster at ~10s, but Qualcomm/OEM
    #   SystemUI plugins delay GMS binding further). If force-stops fire while
    #   GMS is mid-initialization, apps that call GMS APIs immediately get
    #   RemoteException → crash on launch. 30s from boot_completed+5s (i.e.
    #   boot_completed+35s total) guarantees GMS is fully initialized on all
    #   tested ROMs before any app is force-stopped.
    sleep 30

    _skia_log() {
      echo "[ADRENO-SKIAVK_ALL] $1" >> "$SERVICE_LOG" 2>/dev/null || true
    }

    _skia_log "========================================"
    _skia_log "Force-stop sequence starting"
    _skia_log "Time since service.sh start: approx $(( ${ELAPSED:-0} + 32 ))s"
    _skia_log "========================================"


    # ── OLD VENDOR PRE-CHECK: Re-apply skiavk before the safety check ────────
    # On old-vendor ROMs, vendor_init's on-property:sys.boot_completed triggers
    # may fire BETWEEN our service.sh resetprop (+2s) and NOW (+32s), resetting
    # debug.hwui.renderer back to skiagl. If we don't re-apply here, the safety
    # check below sees "skiagl" and exits, losing the entire skiavk_all session.
    # Fix: read old-vendor flag, re-apply if needed BEFORE the check runs.
    _ov_pre_state=""
    if [ -f "/data/local/tmp/adreno_old_vendor" ]; then
      { IFS= read -r _ov_pre_state; } < "/data/local/tmp/adreno_old_vendor" 2>/dev/null || _ov_pre_state=""
    fi
    if [ -n "$_ov_pre_state" ] && [ "$_ov_pre_state" != "clean" ]; then
      # Old vendor detected — ensure prop is skiavk before the check
      _pre_cur=$(getprop debug.hwui.renderer 2>/dev/null || echo "")
      if [ "$_pre_cur" != "skiavk" ] && command -v resetprop >/dev/null 2>&1; then
        resetprop debug.hwui.renderer skiavk 2>/dev/null || true
        resetprop ro.hwui.use_vulkan true 2>/dev/null || true
        _skia_log "[OLD VENDOR] Pre-check re-apply: prop was '${_pre_cur}' (vendor_init override), force-set to skiavk"
      fi
      unset _pre_cur
    fi
    unset _ov_pre_state
    # ── END OLD VENDOR PRE-CHECK ─────────────────────────────────────────────

    # ── SAFETY CHECK: Verify skiavk props are actually active ───────────────
    # On first boot after install, post-fs-data.sh defers skiavk (safety for
    # pristine shader cache). If props are not set yet, running force-stops
    # would kill apps for no reason — they would just restart with normal mode.
    # Only proceed if debug.hwui.renderer is already set to skiavk.
    _CURRENT_RENDERER=$(getprop debug.hwui.renderer 2>/dev/null || echo "")
    if [ "$_CURRENT_RENDERER" != "skiavk" ]; then
      _skia_log "========================================"
      _skia_log "[!] SAFETY ABORT: debug.hwui.renderer='$_CURRENT_RENDERER' (expected 'skiavk')"
      _skia_log "skiavk props not active this boot (first boot safety or prop not set)."
      _skia_log "Force-stop sequence SKIPPED — apps are using normal renderer."
      _skia_log "skiavk_all will fully activate on next boot once resetprop sets the prop."
      _skia_log "========================================"
      exit 0
    fi
    unset _CURRENT_RENDERER
    _skia_log "[OK] Confirmed: debug.hwui.renderer=skiavk — prop active this boot"

    # ══════════════════════════════════════════════════════════════════════════
    # VULKAN FUNCTIONAL PROBE — loophole fix for "skiavk_all crashes all apps"
    # ══════════════════════════════════════════════════════════════════════════
    #
    # ROOT CAUSE of "skiavk works but skiavk_all crashes every app":
    #   Setting debug.hwui.renderer=skiavk only tells HWUI to TRY Vulkan.
    #   On some ROMs/devices, HWUI reads the prop, attempts vkCreateInstance,
    #   gets VK_ERROR_INITIALIZATION_FAILED or VK_ERROR_INCOMPATIBLE_DRIVER
    #   (incomplete Vulkan stack, wrong ABI, missing vulkan.*.so, KGSL API
    #   mismatch), and silently falls back to GL. The prop stays "skiavk" but
    #   apps are actually running on GL.
    #
    #   The skiavk_all force-stop then:
    #     1. Passes the prop check (prop IS "skiavk" — we set it)
    #     2. Clears GL shader caches (Step 0) — caches are now GONE
    #     3. Force-stops all apps — they restart WITHOUT their GL caches
    #     4. Each restarting app: tries Vulkan → fails → GL fallback
    #     5. GL shader recompile starts from scratch for EVERY app simultaneously
    #     6. Combined OOM from mass concurrent recompile → cascade crashes
    #     7. SYMPTOM: "every app crashes immediately when opened after boot"
    #
    #   With skiavk (no _all): no force-stop → no cache-clear-then-restart
    #   → no OOM cascade → apps open fine.
    #
    # THE LOOPHOLE FIX:
    #   Use dumpsys gfxinfo on the already-running SystemUI as a Vulkan
    #   canary. SystemUI is the first HWUI process and has been running since
    #   early boot. If it's NOT on "Skia (Vulkan)" despite the prop being set,
    #   Vulkan init failed on this ROM/device. Abort the force-stop entirely.
    #   Persist the result so future boots skip the probe and go straight to
    #   prop-only mode (no force-stop, no crash).
    #
    # SECONDARY LOOPHOLE: ro.hwui.use_vulkan gate
    #   Some custom ROMs set ro.hwui.use_vulkan=false explicitly in their
    #   device tree. HWUI checks this flag BEFORE trying vkCreateInstance —
    #   if false, it skips Vulkan entirely regardless of debug.hwui.renderer.
    #   This is detectable and provides a fast-path abort.
    #
    # TERTIARY LOOPHOLE: persistent compat flag file
    #   Once we detect incompatibility (either via the probe or a crash
    #   pattern), we write a flag that survives reboots. On subsequent boots
    #   the force-stop subshell reads the flag and exits immediately, avoiding
    #   the crash even before dumpsys is available.
    # ══════════════════════════════════════════════════════════════════════════

    _VK_COMPAT_FILE="/data/local/tmp/adreno_vk_compat"
    _VK_COMPAT=""
    [ -f "$_VK_COMPAT_FILE" ] && { IFS= read -r _VK_COMPAT; } < "$_VK_COMPAT_FILE" 2>/dev/null
    _VK_COMPAT="${_VK_COMPAT:-}"

    # ══ BLOCK D: Structural VK compatibility probe ═══════════════════════════
    # Supplements the existing runtime loopholes (Loophole 1-4) with structural
    # checks that run BEFORE the 30s dumpsys canary. Allows early exit if the
    # device is structurally incompatible, avoiding wasted force-stops.
    # ═════════════════════════════════════════════════════════════════════════
    run_vk_compat_full_probe() {
      local _log_fn="${1:-_skia_log}"
      _VK_STRUCT_PASS=true

      # Check 1: score file from post-fs-data
      local _score_level="" _score_num=100
      if [ -f "/data/local/tmp/adreno_vk_compat_score" ]; then
        while IFS='=' read -r _k _v; do
          case "$_k" in
            LEVEL) _score_level="${_v}" ;;
            SCORE) _score_num="${_v}"   ;;
          esac
        done < "/data/local/tmp/adreno_vk_compat_score" 2>/dev/null
        unset _k _v
      fi
      case "$_score_level" in
        blocked)
          "${_log_fn}" "[VK-STRUCT] score=${_score_num} BLOCKED — structural probe FAIL"
          _VK_STRUCT_PASS=false
          return 1
          ;;
        risky)
          "${_log_fn}" "[VK-STRUCT] score=${_score_num} RISKY — deferring to runtime probe"
          ;;
      esac

      # Check 2: auto-degrade marker written by post-fs-data compat gate
      if [ -f "/data/local/tmp/adreno_skiavk_degraded" ]; then
        local _fail_reason=""
        { IFS= read -r _fail_reason; } < "/data/local/tmp/adreno_skiavk_degraded" 2>/dev/null
        "${_log_fn}" "[VK-STRUCT] auto-degrade marker: ${_fail_reason}"
        "${_log_fn}" "  post-fs-data degraded to skiagl this boot — force-stop ABORTED"
        _VK_STRUCT_PASS=false
        return 1
      fi

      # Check 3: ro.hardware.vulkan current value — try last-ditch resetprop
      local _hwvk
      _hwvk=$(getprop ro.hardware.vulkan 2>/dev/null || echo "")
      case "$_hwvk" in
        adreno|"") ;;
        *)
          if [ -f "/vendor/lib64/hw/vulkan.adreno.so" ] || \
             [ -f "/vendor/lib/hw/vulkan.adreno.so" ]; then
            resetprop ro.hardware.vulkan adreno 2>/dev/null && \
              "${_log_fn}" "[VK-STRUCT] ro.hardware.vulkan late-patched to 'adreno'" || \
              { _VK_STRUCT_PASS=false
                "${_log_fn}" "[VK-STRUCT] ro.hardware.vulkan='${_hwvk}' — ICD fix failed"
              }
          else
            "${_log_fn}" "[VK-STRUCT] ro.hardware.vulkan='${_hwvk}' and no vulkan.adreno.so — ICD broken"
            _VK_STRUCT_PASS=false
          fi
          ;;
      esac
      unset _hwvk

      # Check 4: KGSL device accessible
      if [ ! -e "/dev/kgsl-3d0" ]; then
        "${_log_fn}" "[VK-STRUCT] /dev/kgsl-3d0 absent — no GPU device; Vulkan impossible"
        _VK_STRUCT_PASS=false
        return 1
      fi

      # Check 5: gralloc mapper service alive (HAL crash = swapchain alloc failure)
      local _mapper_alive=false
      service check android.hardware.graphics.allocator.IAllocator/default \
          >/dev/null 2>&1 && _mapper_alive=true
      [ "$_mapper_alive" = "false" ] && \
          service check "android.hardware.graphics.mapper@4.0::IMapper/default" \
          >/dev/null 2>&1 && _mapper_alive=true
      [ "$_mapper_alive" = "false" ] && \
          service check "android.hardware.graphics.mapper@3.0::IMapper/default" \
          >/dev/null 2>&1 && _mapper_alive=true
      [ "$_mapper_alive" = "false" ] && \
          service check "android.hardware.graphics.mapper@2.1::IMapper/default" \
          >/dev/null 2>&1 && _mapper_alive=true
      if [ "$_mapper_alive" = "false" ]; then
        "${_log_fn}" "[VK-STRUCT] gralloc mapper NOT registered — HAL likely crashed"
        "${_log_fn}" "  Deferring to runtime dumpsys probe for final decision"
      fi
      unset _mapper_alive

      "${_log_fn}" "[VK-STRUCT] structural probe PASS (score=${_score_num})"
      return 0
    }
    # ══ END BLOCK D FUNCTION ═════════════════════════════════════════════════

    # ── BLOCK D CALL SITE: Run structural probe before Loophole 1 ────────────
    run_vk_compat_full_probe "_skia_log"
    if [ "$_VK_STRUCT_PASS" = "false" ]; then
      _skia_log "========================================"
      _skia_log "[!] STRUCTURAL VK PROBE FAILED — force-stop ABORTED"
      _skia_log "    skiavk PROP remains active — new apps will attempt Vulkan."
      _skia_log "    To retry: rm /data/local/tmp/adreno_vk_compat_score && reboot"
      _skia_log "========================================"
      echo "prop_only" > "$_VK_COMPAT_FILE" 2>/dev/null
      unset _VK_STRUCT_PASS
      exit 0
    fi
    unset _VK_STRUCT_PASS

    # ── Loophole 1: Persisted ROM incompatibility flag from a previous boot ──
    if [ "$_VK_COMPAT" = "prop_only" ] || [ "$_VK_COMPAT" = "incompatible" ]; then
      _skia_log "========================================"
      _skia_log "[!] VK COMPAT: Persisted flag='$_VK_COMPAT' from a previous boot."
      _skia_log "    This ROM/device cannot safely run skiavk_all force-stop."
      _skia_log "    skiavk PROP is still active — Vulkan runs for all NEW apps."
      _skia_log "    Force-stop sequence SKIPPED (prevents mass shader-recompile OOM)."
      _skia_log "    To retry: 'rm $_VK_COMPAT_FILE' then reboot."
      _skia_log "========================================"
      unset _VK_COMPAT _VK_COMPAT_FILE
      exit 0
    fi

    # ── Loophole 2: ro.hwui.use_vulkan=false — ROM explicitly disables Vulkan ─
    _RO_HWUI_VK=$(getprop ro.hwui.use_vulkan 2>/dev/null || echo "")
    if [ "$_RO_HWUI_VK" = "false" ] || [ "$_RO_HWUI_VK" = "0" ]; then
      _skia_log "========================================"
      _skia_log "[!] VK COMPAT FAIL: ro.hwui.use_vulkan='$_RO_HWUI_VK'"
      _skia_log "    ROM device tree explicitly disables HWUI Vulkan."
      _skia_log "    HWUI ignores debug.hwui.renderer=skiavk when this is false."
      _skia_log "    Force-stop ABORTED — apps would restart on GL, no VK gain."
      _skia_log "    Persisting 'prop_only' flag — future boots skip this subshell."
      _skia_log "========================================"
      echo "prop_only" > "$_VK_COMPAT_FILE" 2>/dev/null
      unset _RO_HWUI_VK _VK_COMPAT _VK_COMPAT_FILE
      exit 0
    fi
    unset _RO_HWUI_VK

    # ── Loophole 3: Vulkan driver .so existence check ────────────────────────
    _VK_LIB_FOUND=false
    for _vl in /vendor/lib64/hw/vulkan.*.so /vendor/lib/hw/vulkan.*.so \
               /system/lib64/hw/vulkan.*.so /system/lib/hw/vulkan.*.so \
               /vendor/lib64/libvulkan.so /system/lib64/libvulkan.so; do
      [ -f "$_vl" ] && { _VK_LIB_FOUND=true; break; }
    done
    if [ "$_VK_LIB_FOUND" = "false" ]; then
      _skia_log "========================================"
      _skia_log "[!] VK COMPAT FAIL: No vulkan.*.so or libvulkan.so in vendor/system."
      _skia_log "    This ROM has no Vulkan driver — skiavk will always fail silently."
      _skia_log "    Force-stop ABORTED. Persisting 'incompatible' flag."
      _skia_log "========================================"
      echo "incompatible" > "$_VK_COMPAT_FILE" 2>/dev/null
      unset _VK_LIB_FOUND _VK_COMPAT _VK_COMPAT_FILE
      exit 0
    fi
    unset _VK_LIB_FOUND

    # ── Loophole 4: SystemUI Vulkan canary — the definitive runtime check ────
    # SystemUI has been running since early boot (~35s ago). dumpsys gfxinfo
    # reports the ACTUAL pipeline, not the prop value. "Skia (Vulkan)" = VK
    # working. Anything else = VK failed silently, HWUI fell back to GL.
    # Count of "Skia (Vulkan)" lines = number of VK surfaces; 0 = no Vulkan.
    _SYSUI_VK_COUNT=$(dumpsys gfxinfo com.android.systemui 2>/dev/null \
                      | grep -c "Skia (Vulkan)" 2>/dev/null || echo "0")
    _SYSUI_VK_COUNT="${_SYSUI_VK_COUNT:-0}"
    if [ "$_SYSUI_VK_COUNT" -eq 0 ]; then
      # Also try: grep Pipeline line for GL/VK info
      _SYSUI_PIPE=$(dumpsys gfxinfo com.android.systemui 2>/dev/null \
                    | grep -i "Pipeline" | head -1 || echo "")
      _LIVE_PROP=$(getprop debug.hwui.renderer 2>/dev/null || echo "")
      _skia_log "========================================"
      _skia_log "[!] VK COMPAT FAIL: SystemUI is NOT running on Vulkan."
      _skia_log "    SystemUI pipeline    : '${_SYSUI_PIPE:-unknown}'"
      _skia_log "    Live renderer prop   : '${_LIVE_PROP}'"
      _skia_log "    Skia(Vulkan) count   : 0"
      _skia_log "    DIAGNOSIS: HWUI read 'skiavk' prop but Vulkan init failed."
      _skia_log "    Root causes (pick one or more for this ROM/device):"
      _skia_log "      - Incomplete Vulkan stack (missing extensions/layers)"
      _skia_log "      - KGSL API version mismatch (kernel vs custom driver)"
      _skia_log "      - vendor_init overrode prop after our resetprop"
      _skia_log "      - libhwui ABI incompatible with custom Adreno driver"
      _skia_log "      - SELinux blocking /dev/kgsl-3d0 for Zygote processes"
      _skia_log "    IMPACT if force-stop ran:"
      _skia_log "      GL caches cleared → apps restart on GL without caches"
      _skia_log "      → mass shader recompile OOM → ALL apps crash on open"
      _skia_log "    ACTION: Force-stop ABORTED."
      _skia_log "    Persisting 'prop_only' — future boots skip force-stop."
      _skia_log "    skiavk PROP remains active — new apps will attempt Vulkan."
      _skia_log "    To retry after ROM update: 'rm $_VK_COMPAT_FILE' then reboot."
      _skia_log "========================================"
      echo "prop_only" > "$_VK_COMPAT_FILE" 2>/dev/null
      unset _SYSUI_VK_COUNT _SYSUI_PIPE _LIVE_PROP _VK_COMPAT _VK_COMPAT_FILE
      exit 0
    fi
    _skia_log "[OK] VK PROBE PASSED: SystemUI confirmed on Vulkan (${_SYSUI_VK_COUNT} Skia(Vulkan) surface(s))"
    _skia_log "     ROM/device Vulkan stack is functional — safe to proceed with force-stop"
    echo "confirmed" > "$_VK_COMPAT_FILE" 2>/dev/null
    unset _SYSUI_VK_COUNT _VK_COMPAT _VK_COMPAT_FILE
    # ══ END VULKAN FUNCTIONAL PROBE ══════════════════════════════════════════
    # ══════════════════════════════════════════════════════════════════════════
    # OLD VENDOR DETECTION + SERVICE-PHASE PROP WATCHDOG
    # ══════════════════════════════════════════════════════════════════════════
    #
    # ROOT CAUSE: Why old vendor kills skiavk silently even after our resetprop
    #
    # Android property loading order in init's load_all_props():
    #   1. /system/etc/prop.default  (or /default.prop on legacy)
    #   2. /system/build.prop         ← our module writes system.prop here
    #   3. /vendor/build.prop         ← LOADED AFTER SYSTEM, wins for debug.*
    #   4. /odm/build.prop
    #   5. /data/property/persist.*
    #
    # An old /vendor/build.prop may have:
    #   debug.hwui.renderer=skiagl
    # This overwrites our system.prop's skiavk before Zygote starts.
    # Our post-fs-data resetprop fixes it in-session but vendor_init fires
    # again via init.rc triggers:
    #
    #   # /vendor/etc/init/hw/init.<device>.rc  (old MIUI/OEM vendor)
    #   on property:sys.boot_completed=1
    #       setprop debug.hwui.renderer skiagl
    #
    # This fires AFTER boot_completed, AFTER our service.sh resetprop at +2s,
    # re-overriding the prop. Any app opened after this override is on GL.
    #
    # TWO-PART SERVICE.SH FIX:
    #   Part A: Re-enforce skiavk now (covers the +2s post-boot window).
    #   Part B: Launch persistent watchdog subshell that detects and re-applies
    #           skiavk every 1s for the first 120s after boot_completed.
    #           Covers ALL vendor_init late triggers, regardless of timing.
    #
    # CRITICAL INTEGRATION WITH VULKAN PROBE:
    #   If the VK probe returned "prop_only" but old-vendor analysis shows the
    #   Vulkan STACK is probably fine (only the prop was overridden), we should
    #   NOT treat this as "skip force-stop". The prop watchdog will hold skiavk,
    #   and the force-stop is still needed to make already-running apps pick up
    #   skiavk on their next cold-start. We clear the "prop_only" verdict below
    #   if old-vendor prop-override is the detected cause.
    # ══════════════════════════════════════════════════════════════════════════

    _OLD_VND_STATE_FILE="/data/local/tmp/adreno_old_vendor"
    _OLD_VND_STATE=""
    _OLD_VND_ACTIVE=false
    _OLD_VND_IS_PROP_ONLY=false   # true = vendor prop override only (Vulkan stack OK)

    # Read state persisted by post-fs-data.sh detect_old_vendor_extended()
    if [ -f "$_OLD_VND_STATE_FILE" ]; then
      { IFS= read -r _OLD_VND_STATE; } < "$_OLD_VND_STATE_FILE" 2>/dev/null || _OLD_VND_STATE=""
      if [ -n "$_OLD_VND_STATE" ] && [ "$_OLD_VND_STATE" != "clean" ]; then
        _OLD_VND_ACTIVE=true
        _skia_log "========================================"
        _skia_log "OLD VENDOR DETECTED (from post-fs-data)"
        _skia_log "  State file  : $_OLD_VND_STATE_FILE"
        _skia_log "  Reason      : $_OLD_VND_STATE"
        _skia_log "========================================"
      else
        _skia_log "Old vendor check: CLEAN (state='${_OLD_VND_STATE:-<no file>}')"
      fi
    else
      # State file absent — post-fs-data may not have run yet (KSU timing edge case)
      # Run the detection ourselves as a fallback
      _skia_log "Old vendor: no state file — running inline detection..."
      detect_old_vendor_extended
      if [ "$OLD_VENDOR" = "true" ]; then
        _OLD_VND_ACTIVE=true
        _OLD_VND_STATE="$OLD_VENDOR_REASON"
        printf '%s\n' "$OLD_VENDOR_REASON" > "$_OLD_VND_STATE_FILE" 2>/dev/null || true
        _skia_log "Old vendor DETECTED (inline): $_OLD_VND_STATE"
      else
        printf 'clean\n' > "$_OLD_VND_STATE_FILE" 2>/dev/null || true
        _skia_log "Old vendor: CLEAN (inline check)"
      fi
    fi

    if [ "$_OLD_VND_ACTIVE" = "true" ]; then

      # ── Part A: Immediate re-enforcement ──────────────────────────────────
      # Re-apply skiavk right now. vendor_init's on-boot triggers may have
      # fired between post-fs-data's watchdog ending and this point.
      _cur_renderer=$(getprop debug.hwui.renderer 2>/dev/null || echo "")
      if [ "$_cur_renderer" != "skiavk" ]; then
        resetprop debug.hwui.renderer skiavk 2>/dev/null || true
        resetprop ro.hwui.use_vulkan true 2>/dev/null || true
        _skia_log "[!!] OLD VENDOR: prop was overridden to '${_cur_renderer}' — re-applied skiavk NOW"
      else
        _skia_log "[OK] OLD VENDOR: prop is currently skiavk — no immediate re-apply needed"
      fi
      unset _cur_renderer

      # ── Determine if this is a "prop-only" issue (Vulkan stack OK) ────────
      # Heuristic: if the Vulkan probe PASSED (confirmed) earlier this boot,
      # or if the old-vendor reason mentions only prop/RC override (not VNDK
      # or SDK mismatch that would affect the Vulkan ICD), treat as prop-only.
      # This prevents the prop override from being misdiagnosed as a Vulkan
      # stack incompatibility and wrongly disabling skiavk_all.
      _vk_compat_now=""
      [ -f "/data/local/tmp/adreno_vk_compat" ] && \
        { IFS= read -r _vk_compat_now; } < "/data/local/tmp/adreno_vk_compat" 2>/dev/null
      case "$_OLD_VND_STATE" in
        *vendor_rc=*|*vendor.prop*|*debug.hwui.renderer=*|*/vendor/build.prop*)
          # Pure prop override — Vulkan ICD itself should be fine
          _OLD_VND_IS_PROP_ONLY=true
          _skia_log "Old vendor type: PROP-ONLY override (vendor .rc or build.prop sets renderer)"
          _skia_log "  Vulkan ICD not implicated — force-stop proceeds after prop watchdog start"
          # If VK probe wrote "prop_only" for this same reason, clear it so
          # force-stop is not skipped (the watchdog now handles the prop).
          if [ "$_vk_compat_now" = "prop_only" ]; then
            printf 'confirmed\n' > "/data/local/tmp/adreno_vk_compat" 2>/dev/null || true
            _skia_log "[OVERRIDE] VK compat flag cleared from 'prop_only' → 'confirmed' (old vendor prop override, not stack issue)"
          fi
          ;;
        *SDK_DELTA=*|*VNDK_DELTA=*|*vendor_api_level*|*build date gap*)
          # SDK/VNDK gap — may affect the Vulkan ICD too. Don't override VK probe result.
          _OLD_VND_IS_PROP_ONLY=false
          _skia_log "Old vendor type: SDK/VNDK mismatch — Vulkan ICD may also be affected"
          _skia_log "  VK probe result preserved: '${_vk_compat_now:-<not set>}'"
          ;;
        *)
          _OLD_VND_IS_PROP_ONLY=true  # Unknown reason — default to prop-only (safer)
          _skia_log "Old vendor type: UNKNOWN reason — defaulting to prop-only mode"
          ;;
      esac
      unset _vk_compat_now

      # ── Part B: Persistent service-phase watchdog ────────────────────────
      # Runs every 1s for 120s after boot_completed. This is the tightest
      # window possible without burning CPU. Covers:
      #   - vendor_init on property:sys.boot_completed=1 setprop triggers
      #   - OEM "performance manager" daemons that run at boot+5/10/30s
      #   - Late SIM/modem init services that reset GPU props as side effect
      (
        _svc_wd_applied=0
        _svc_wd_elapsed=0
        # Fast phase: every 1s for first 60s
        while [ "$_svc_wd_elapsed" -lt 60 ]; do
          sleep 1
          _svc_wd_elapsed=$((_svc_wd_elapsed + 1))
          _c=$(getprop debug.hwui.renderer 2>/dev/null || echo "")
          if [ "$_c" != "skiavk" ]; then
            resetprop debug.hwui.renderer skiavk 2>/dev/null || true
            resetprop ro.hwui.use_vulkan true 2>/dev/null || true
            _svc_wd_applied=$((_svc_wd_applied + 1))
            printf '[ADRENO][SVC-OLDVENDOR][+%ds] override detected: was "%s" → force-set skiavk (re-apply #%d)\n' \
              "$_svc_wd_elapsed" "$_c" "$_svc_wd_applied" > /dev/kmsg 2>/dev/null || true
          fi
        done
        # Slow phase: every 5s for next 60s (total 120s coverage)
        while [ "$_svc_wd_elapsed" -lt 120 ]; do
          sleep 5
          _svc_wd_elapsed=$((_svc_wd_elapsed + 5))
          _c=$(getprop debug.hwui.renderer 2>/dev/null || echo "")
          if [ "$_c" != "skiavk" ]; then
            resetprop debug.hwui.renderer skiavk 2>/dev/null || true
            resetprop ro.hwui.use_vulkan true 2>/dev/null || true
            _svc_wd_applied=$((_svc_wd_applied + 1))
            printf '[ADRENO][SVC-OLDVENDOR-SLOW][+%ds] override detected: was "%s" → force-set skiavk (re-apply #%d)\n' \
              "$_svc_wd_elapsed" "$_c" "$_svc_wd_applied" > /dev/kmsg 2>/dev/null || true
          fi
        done
        printf '[ADRENO][SVC-OLDVENDOR] Watchdog complete. Total re-applies: %d\n' \
          "$_svc_wd_applied" > /dev/kmsg 2>/dev/null || true
      ) &
      _skia_log "[OK] OLD VENDOR: service-phase prop watchdog launched (PID=$!) — 120s coverage at 1s/5s intervals"

    fi  # _OLD_VND_ACTIVE

    unset _OLD_VND_STATE_FILE _OLD_VND_STATE _OLD_VND_ACTIVE _OLD_VND_IS_PROP_ONLY
    # ══ END OLD VENDOR SERVICE-PHASE LOGIC ═══════════════════════════════════

    # ==========================================================================
    # BLOCK C — ro.hardware.vulkan runtime fix + gralloc compat props
    # ==========================================================================
    # Belt-and-suspenders: re-apply fixes that post-fs-data.sh set early.
    # Old vendor init.rc files can reset these after boot_completed.
    # ==========================================================================

    # ── Service-phase ro.hardware.vulkan fix ─────────────────────────────────
    if [ "$RENDER_MODE" = "skiavk" ] || [ "$RENDER_MODE" = "skiavk_all" ]; then
      if command -v resetprop >/dev/null 2>&1; then
        _svc_hwvk=$(getprop ro.hardware.vulkan 2>/dev/null || echo "")
        case "$_svc_hwvk" in
          adreno|"") ;;  # already correct
          *)
            # SoC codename was re-applied by vendor init.rc — fix it back
            if [ -f "/vendor/lib64/hw/vulkan.adreno.so" ] || \
               [ -f "/vendor/lib/hw/vulkan.adreno.so" ]; then
              resetprop ro.hardware.vulkan adreno 2>/dev/null && \
                _skia_log "[BLOCK C] ro.hardware.vulkan: '${_svc_hwvk}' → 'adreno' (ICD fix)" || \
                _skia_log "[BLOCK C][!] ro.hardware.vulkan fix failed"
            fi
            ;;
        esac
        unset _svc_hwvk
      fi
    fi

    # ── Service-phase gralloc compat props ───────────────────────────────────
    # Load compat score persisted by post-fs-data.sh
    _SVC_SCORE_FILE="/data/local/tmp/adreno_vk_compat_score"
    _SVC_COMPAT_LEVEL="safe"
    _SVC_GRALLOC_VERSION="unknown"

    if [ -f "$_SVC_SCORE_FILE" ]; then
      while IFS='=' read -r _sk _sv; do
        case "$_sk" in
          LEVEL)   _SVC_COMPAT_LEVEL="${_sv}"    ;;
          GRALLOC) _SVC_GRALLOC_VERSION="${_sv}" ;;
        esac
      done < "$_SVC_SCORE_FILE" 2>/dev/null
    fi

    if [ "$RENDER_MODE" = "skiavk" ] || [ "$RENDER_MODE" = "skiavk_all" ]; then
      if command -v resetprop >/dev/null 2>&1; then
        case "$_SVC_GRALLOC_VERSION" in
          2|3)
            # Old gralloc: disable validation layers (ABI mismatch → vkCreateInstance failure)
            resetprop debug.vulkan.dev.layers  ""  2>/dev/null || true
            resetprop debug.vulkan.layers       ""  2>/dev/null || true
            resetprop persist.graphics.vulkan.validation_enable 0 2>/dev/null || true
            # Cap SF buffer pool — gralloc2/3 has hard pool limits; Vulkan swapchain
            # exhausts them unless we cap acquired buffers at 2.
            resetprop debug.sf.max_frame_buffer_acquired_buffers 2 2>/dev/null || true
            _skia_log "[BLOCK C] gralloc${_SVC_GRALLOC_VERSION}: WSI compat props enforced (service phase)"
            ;;
        esac
      fi
    fi
    unset _SVC_SCORE_FILE _SVC_COMPAT_LEVEL _SVC_GRALLOC_VERSION _sk _sv
    # ══ END BLOCK C ══════════════════════════════════════════════════════════


    # ── KGSL PROTECTION: Check for native-Vulkan game processes ─────────────
    # Uses _game_pkg_excluded() from game_exclusion_list.sh (sourced at top)
    # for exact-glob matching — same function the daemon uses.
    #
    # BUG B FIX: Old implementation used *"${_ge_base}"* (substring match after
    # stripping glob wildcard). This caused false positives: e.g. a running
    # "com.tencent.igplugin" process would match the "com.tencent.ig" pattern,
    # causing the entire skiavk_all force-stop sequence to be silently skipped
    # on every boot if that plugin was active — even with no game running.
    # _game_pkg_excluded uses an unquoted case pattern (exact-glob) so
    # "com.tencent.ig" only matches "com.tencent.ig", not "com.tencent.igplugin".
    _is_native_vk_game_running() {
      local _cf _cl
      for _cf in /proc/[0-9]*/cmdline; do
        [ -f "$_cf" ] || continue
        { IFS= read -r _cl; } < "$_cf" 2>/dev/null || continue
        [ -n "$_cl" ] || continue
        _game_pkg_excluded "$_cl" && return 0
      done
      return 1
    }
    if _is_native_vk_game_running; then
      _skia_log "========================================="
      _skia_log "[!] KGSL PROTECTION: Native-Vulkan game is running."
      _skia_log "    Force-stop sequence SKIPPED to prevent KGSL context table corruption."
      _skia_log "    Game-compatibility daemon handles renderer switching independently."
      _skia_log "    Force-stops will apply on next boot/cycle when no game is active."
      _skia_log "========================================="
      exit 0
    fi
    unset -f _is_native_vk_game_running 2>/dev/null || true
    _skia_log "[OK] No native-Vulkan game running — safe to proceed with force-stop sequence"
    # TERTIARY clear (here): belt-and-suspenders inside the force-stop window.
    #   If the two earlier passes already cleared everything, these find/rm
    #   calls complete instantly (empty dirs). If somehow a process wrote a
    #   new stale cache between post-fs-data and here, this catches it.
    #
    # ROOT CAUSE of "apps crash immediately on open" (preserved for reference):
    #   GL → Vulkan mode switch leaves GL-format pipeline cache blobs in each
    #   app's app_skia_pipeline_cache dir. HWUI passes the old blob to
    #   vkCreateGraphicsPipelines as pInitialData. Vulkan driver sees wrong
    #   header magic → VK_ERROR_FORMAT_FEATURE_NOT_SUPPORTED or corruption →
    #   GPU fault → SIGSEGV. Every app crashes before any UI draws.
    #
    # Mode-change check: same mode → caches built by this renderer → valid.
    # Different mode → stale format → clear needed.
    _S0_LAST_MODE_FILE="/data/local/tmp/adreno_last_render_mode"
    _S0_LAST_MODE=""
    if [ -f "$_S0_LAST_MODE_FILE" ]; then
      { IFS= read -r _S0_LAST_MODE; } < "$_S0_LAST_MODE_FILE" 2>/dev/null || _S0_LAST_MODE=""
    fi

    if [ "$RENDER_MODE" != "$_S0_LAST_MODE" ]; then
      _skia_log "Step 0: Mode changed ('${_S0_LAST_MODE:-<none>}' → '$RENDER_MODE') — clearing stale Skia/HWUI pipeline caches..."
      # Global HWUI cache
      rm -rf /data/misc/hwui/ 2>/dev/null || true
      # Per-app Skia pipeline caches (the main crash culprit on GL→VK switch)
      find /data/user_de/0 -maxdepth 2 -type d -name "app_skia_pipeline_cache" \
          -exec rm -rf {} + 2>/dev/null || true
      # Fallback: legacy /data/data path (pre-Android 7 / direct boot disabled)
      find /data/data -maxdepth 2 -type d -name "app_skia_pipeline_cache" \
          -exec rm -rf {} + 2>/dev/null || true
      # Per-app Skia shader caches
      find /data/user_de/0 -maxdepth 2 -name "*.shader_journal" -delete 2>/dev/null || true
      find /data/user_de/0 -maxdepth 2 -type d \( -name "skia_shaders" -o -name "shader_cache" \) \
          -exec rm -rf {} + 2>/dev/null || true
      _skia_log "[OK] Stale Skia pipeline & shader caches cleared (mode change: ${_S0_LAST_MODE:-<none>} → $RENDER_MODE)"
    else
      _skia_log "Step 0: Mode unchanged ('$RENDER_MODE') — pipeline caches PRESERVED."
      _skia_log "  Skipping cache clear to prevent shader recompile OOM (Facebook/GMS protection)."
    fi
    unset _S0_LAST_MODE _S0_LAST_MODE_FILE

    # ── STEP 1: SystemUI — NOT crashed (intentional, permanent fix) ──────────
    #
    # ROOT CAUSE ANALYSIS — why crashing SystemUI caused ALL user-reported issues:
    #
    # SYMPTOM: "screen goes black and comes back, then ROM logo, booting again"
    # SYMPTOM: "Google accounts disappear after Meta apps crash"
    # SYMPTOM: "Facebook/Messenger crash immediately on open"
    # SYMPTOM: "apps auto force-stop for 5-10 minutes after boot"
    #
    # MECHANISM (when am crash systemui was active):
    #   1. am crash fires at boot_completed+35s — user has ALREADY unlocked phone
    #   2. SystemUI dies → SurfaceFlinger loses ALL layer references → BLACK SCREEN
    #   3. During 5–15s SystemUI restart window:
    #      - GMS AccountManager is mid-sync (OAuth token refresh at boot+35s)
    #      - It holds a live Binder to SystemUI's AccountManagerService proxy
    #      - SystemUI death → DeadObjectException on AccountManager sync thread
    #      - AccountManager marks ALL OAuth tokens invalid → removes every Google
    #        account from Settings (the "accounts disappear" symptom)
    #   4. Meta apps (Facebook/Messenger/Instagram) hold ANativeWindow handles
    #      obtained from SF during their first draw. When SF loses layer references
    #      on SystemUI crash, these handles go dangling. On next draw call,
    #      libvulkan dereferences stale pointer → SIGSEGV → app crash
    #   5. On custom ROMs: additional services die in solidarity with SystemUI
    #      (tight process-death dependencies). Android watchdog counts 3+ crashes
    #      in 5 minutes → system_server watchdog kill → ROM logo → reboot
    #
    # FIX: Do NOT crash SystemUI in skiavk_all (or any mode) at boot time.
    #   - resetprop already set debug.hwui.renderer=skiavk at boot_completed+5s
    #   - All NEW user-opened apps after that point cold-start with skiavk
    #   - SystemUI keeps its current renderer for THIS SESSION (invisible to user;
    #     it's already rendering at 60fps and the difference is unnoticeable)
    #   - On NEXT REBOOT: system.prop (written by service.sh below) delivers
    #     debug.hwui.renderer=skiavk to EVERY process including SystemUI from
    #     first init — no crash ever needed
    #
    #
    # FIX: Do NOT crash SystemUI in skiavk_all (or any mode) at boot time.
    #   - resetprop already set debug.hwui.renderer=skiavk at boot_completed+5s
    #   - All NEW user-opened apps after that point cold-start with skiavk
    #   - SystemUI keeps its current renderer for THIS SESSION (invisible to user)
    #   - On NEXT REBOOT: system.prop delivers skiavk to EVERY process from init
    _skia_log "Step 1: SystemUI NOT crashed — stability fix for custom ROMs."
    _skia_log "  resetprop already set skiavk at boot_completed+5s."
    _skia_log "  All user-opened apps from this point use skiavk."
    _skia_log "  SystemUI keeps old renderer this session (invisible to user)."
    _skia_log "  Next reboot: system.prop delivers skiavk to ALL processes from init."

    # ── STEP 2: Force-stop all 3rd-party apps (THROTTLED — one at a time) ────
    #
    # PURPOSE: Make background apps cold-start with skiavk on next user-open.
    # debug.hwui.renderer is cached per-process at first HWUI init. Any app
    # that was already running before resetprop fired still has the old renderer
    # cached as sRenderPipelineType. Force-stopping it makes it exit and re-read
    # the prop on next launch → gets skiavk automatically.
    #
    # WHY THROTTLED (150ms sleep between each package):
    #   Each running app holds open FDs on /dev/kgsl-3d0. KGSL (Qualcomm kernel
    #   GPU driver) runs per-FD cleanup for every KGSL context handle on process
    #   death. If hundreds of processes are SIGKILLd simultaneously (tight loop,
    #   all completing at kernel scheduler timescale), hundreds of KGSL teardowns
    #   run concurrently. On custom Adreno drivers this races in KGSL's internal
    #   context allocation table → entries left half-freed/corrupted → every new
    #   process that subsequently opens /dev/kgsl-3d0 gets a corrupted context →
    #   vkCreateDevice fails → ALL apps crash on open forever until reboot.
    #   150ms between kills gives KGSL time to fully complete each teardown before
    #   the next SIGKILL arrives — no concurrent teardown, no corruption.
    #
    # am kill-all is NEVER used — it SIGKILLs ALL cached procs simultaneously,
    # which is exactly the concurrent teardown problem described above.
    #
    # EXCLUSIONS:
    #   GMS/GSF/Play Store — on custom ROMs these are user packages (-3). Killing
    #     them causes every GMS-dependent app to fail on next open (RemoteException
    #     on Play Services binding) for minutes after.
    #   Meta apps (Facebook/Messenger/Instagram/WhatsApp) — hold live GMS
    #     AccountManager Binder for OAuth sync. Killing mid-sync sends
    #     DeadObjectException to AccountManager → ALL Google OAuth tokens marked
    #     invalid → every Google account removed from Settings. They transition
    #     to skiavk safely on next natural cold-start.
    #   Launchers — killing the launcher causes a jarring home screen restart
    #     visible to the user. Launcher transitions on next natural restart.
    _skia_log "Step 2: Force-stopping 3rd-party apps (throttled, GMS/Meta excluded)..."
    _THIRD_STOPPED=0
    _THIRD_SKIPPED=0
    # BUG4 FIX: Replaced `for _pkg in $(pm list packages -3 ...)` with
    # `while IFS= read -r _pkg`. Rationale: $(pm list packages ...) expands
    # the entire pm output before iteration begins — on slow devices this
    # stalls for 0.5-2s and creates a large string allocation. More critically,
    # if pm outputs any error text (not ready yet, partial output), it gets
    # word-split and iterated as fake package names. `while read` processes
    # line-by-line, is safe against pm errors (bad lines are skipped by the
    # empty check below), and starts processing immediately.
    pm list packages -3 2>/dev/null | cut -f2 -d: | while IFS= read -r _pkg; do
      [ -z "$_pkg" ] && continue
      case "$_pkg" in
        # BUG1 FIX: Original patterns had `|        ` (pipe + 8 spaces) as separator,
        # making each alternative pattern start with leading whitespace. POSIX case
        # patterns are literal — a pattern of "        com.google.android.gms" with
        # leading spaces will NEVER match the package name "com.google.android.gms".
        # All GMS and Meta packages were silently force-stopped every boot, causing
        # GMS auth service crash, Google account loss, and OOM-triggered app crashes.
        # Fix: each pattern on its own line with no leading whitespace, properly
        # pipe-separated on continuation lines.
        com.google.android.gms|\
        com.google.android.gms.*|\
        com.google.android.gsf|\
        com.google.android.gsf.*|\
        com.google.android.gmscore|\
        com.android.vending|\
        com.facebook.katana|\
        com.facebook.orca|\
        com.facebook.lite|\
        com.facebook.mlite|\
        com.instagram.android|\
        com.instagram.lite|\
        com.whatsapp|\
        com.whatsapp.w4b)
          # GMS/Meta: OAuth token corruption risk — always excluded.
          # Games are handled by _game_pkg_excluded() from game_exclusion_list.sh.
          _THIRD_SKIPPED=$((_THIRD_SKIPPED + 1))
          continue ;;
      esac
      # Check shared game exclusion list (sourced from game_exclusion_list.sh)
      if _game_pkg_excluded "$_pkg"; then
        _THIRD_SKIPPED=$((_THIRD_SKIPPED + 1))
        continue
      fi
      am force-stop "$_pkg" 2>/dev/null || true
      _THIRD_STOPPED=$((_THIRD_STOPPED + 1))
      # Throttle: give KGSL time to complete context teardown before next kill.
      # 150ms is sufficient for KGSL cleanup on all tested Adreno generations.
      # Without this, concurrent KGSL teardowns corrupt the context table.
      sleep 0.15
    done
    _skia_log "[OK] 3rd-party: stopped=$_THIRD_STOPPED skipped=$_THIRD_SKIPPED (GMS/Meta/Play excluded)"

    # ── STEP 3: Force-stop non-critical system UI packages (THROTTLED) ───────
    # Settings, system app stores, OEM UI apps etc. — safe to restart on demand.
    # Same throttle rationale as Step 2. Critical system services are excluded.
    _skia_log "Step 3: Force-stopping non-critical system packages (throttled)..."
    _SYS_STOPPED=0
    # BUG4 FIX: Same rationale as Step 2 — while read instead of for $(...).
    pm list packages -s 2>/dev/null | cut -f2 -d: | while IFS= read -r _pkg; do
      [ -z "$_pkg" ] && continue
      # BUG1 FIX: Same leading-whitespace fix as Step 2 case statement.
      # Each critical system package pattern on its own line, no leading spaces.
      case "$_pkg" in
        android|\
        android.*|\
        com.android.phone*|\
        com.android.bluetooth*|\
        com.android.nfc*|\
        com.android.server*|\
        com.android.telephony*|\
        com.android.providers*|\
        com.android.se|\
        com.android.carrierconfig*|\
        com.android.ims*|\
        com.android.networkstack*|\
        com.android.wifi*|\
        com.android.systemui|\
        com.google.android.gms*|\
        com.google.android.gsf*|\
        com.google.android.gmscore|\
        com.qualcomm.qti.telephony*|\
        com.qualcomm.qti.server*|\
        com.qti.phone|\
        com.samsung.android.incallui*|\
        com.samsung.android.telephony*|\
        com.samsung.android.providers*|\
        com.miui.phone|\
        com.miui.core|\
        com.miui.daemon|\
        com.miui.providers*|\
        com.oppo.providers*|\
        com.vivo.providers*|\
        com.android.launcher*|\
        com.miui.home|\
        com.sec.android.app.launcher|\
        com.google.android.apps.nexuslauncher|\
        com.samsung.android.app.spage|\
        com.coloros.launcher*|\
        com.oppo.launcher*|\
        com.oneplus.launcher|\
        com.hihonor.launcher|\
        com.asus.launcher*)
          continue ;;
      esac
      am force-stop "$_pkg" 2>/dev/null || true
      _SYS_STOPPED=$((_SYS_STOPPED + 1))
      sleep 0.15
    done
    _skia_log "[OK] System UI packages force-stopped (throttled): $_SYS_STOPPED"

    # ── STEP 4: am kill-all — INTENTIONALLY NOT USED ────────────────────────
    # am kill-all sends SIGKILL to ALL remaining cached processes in one shot.
    # This is the worst-case concurrent KGSL teardown scenario — equivalent to
    # doing the entire Step 2 loop with zero sleep. It permanently corrupts the
    # KGSL context table for the boot session. Removed permanently.
    _skia_log "Step 4: am kill-all intentionally skipped (concurrent SIGKILL = KGSL corruption)."

    # Brief settle — let Binder registrations clear after force-stops
    sleep 2


    # ── STEP 5: Log pipeline status + post-force-stop VK confirmation ────────
    # SystemUI was NOT crashed this session (stability fix). All user-opened
    # apps use skiavk (prop was set at boot_completed+5s). SystemUI keeps its
    # current renderer for this session; picks up skiavk via system.prop next boot.
    _skia_log "Step 5: Post-force-stop renderer verification..."
    _POST_SYSUI=$(dumpsys gfxinfo com.android.systemui 2>/dev/null | grep -i "Pipeline" | head -1 | tr -d ' ')
    _POST_LIVE=$(getprop debug.hwui.renderer 2>/dev/null || echo "")
    if [ -n "$_POST_SYSUI" ]; then
      _skia_log "  SystemUI pipeline    : $_POST_SYSUI (unchanged — not crashed this session)"
      _skia_log "  Live renderer prop   : $_POST_LIVE"
      _skia_log "  New app opens        : will use skiavk (prop set at boot+5s)"
      _skia_log "  Next reboot          : system.prop delivers skiavk to ALL processes"
    else
      _skia_log "  Could not read SystemUI pipeline (possibly restarting)"
      _skia_log "  Live renderer prop   : $_POST_LIVE"
    fi
    # Verify prop wasn't overridden by a late OEM init.d script during force-stop
    if [ "$_POST_LIVE" != "skiavk" ] && [ -n "$_POST_LIVE" ]; then
      _skia_log "[!] LATE PROP OVERRIDE DETECTED: prop changed to '$_POST_LIVE' during force-stop"
      _skia_log "    vendor_init or OEM init.d re-set the prop after our resetprop."
      _skia_log "    Re-applying skiavk prop now..."
      resetprop debug.hwui.renderer skiavk 2>/dev/null || true
      resetprop ro.hwui.use_vulkan true 2>/dev/null || true
      # ── OLD VENDOR DISTINCTION ─────────────────────────────────────────
      # If old-vendor state file exists and is not "clean", the override is
      # caused by the old vendor partition, not a Vulkan stack issue.
      # Do NOT mark as "prop_only" in this case — the service-phase watchdog
      # (launched above) will hold the prop. Writing "prop_only" to the VK
      # compat file would cause next boot to skip force-stop entirely, which
      # is wrong: the watchdog handles the prop, force-stop is still needed.
      _step5_ov_state=""
      [ -f "/data/local/tmp/adreno_old_vendor" ] &&         { IFS= read -r _step5_ov_state; } < "/data/local/tmp/adreno_old_vendor" 2>/dev/null
      if [ -n "$_step5_ov_state" ] && [ "$_step5_ov_state" != "clean" ]; then
        _skia_log "    OLD VENDOR prop override — NOT marking prop_only (watchdog handles it)."
        _skia_log "    Old vendor state: ${_step5_ov_state}"
      else
        _skia_log "    Marking ROM as 'prop_only' for next boot (OEM prop watcher active)."
        echo "prop_only" > "/data/local/tmp/adreno_vk_compat" 2>/dev/null
      fi
      unset _step5_ov_state
      # ── END OLD VENDOR DISTINCTION ─────────────────────────────────────
    fi
    unset _POST_SYSUI _POST_LIVE

    _skia_log "========================================"
    _skia_log "skiavk_all: boot-time renderer activation complete"
    _skia_log "  3rd-party stopped    : $_THIRD_STOPPED (skipped: $_THIRD_SKIPPED GMS/Meta/Play)"
    _skia_log "  System UI stopped    : $_SYS_STOPPED"
    _skia_log "  Throttle             : 150ms between each kill (KGSL teardown safety)"
    _skia_log "  am kill-all          : intentionally skipped (concurrent KGSL corruption)"
    _skia_log "  Renderer prop        : live via resetprop at boot_completed+2s"
    _skia_log "  Cache clear          : ran in post-fs-data (pre-Zygote)"
    _skia_log "  SystemUI             : keeps old renderer this session (picks up skiavk on reboot)"
    _skia_log "Verify: dumpsys gfxinfo <pkg> | grep Pipeline"
    _skia_log "========================================"
  ) &

  log_service "skiavk_all: Background renderer verification subshell PID=$! launched"
fi

# ========================================
# WAIT FOR SDCARD MOUNT
# ========================================

log_service "Waiting for sdcard mount..."
SDCARD_WAIT=0
while [ ! -d "/sdcard/Android" ] && [ $SDCARD_WAIT -lt 30 ]; do
  sleep 1
  SDCARD_WAIT=$((SDCARD_WAIT + 1))
done

if [ -d "/sdcard/Android" ]; then
  log_service "SD card mounted after ${SDCARD_WAIT}s"
else
  log_service "WARNING: SD card not mounted after 30s - logs may fail"
fi

# ========================================
# AUTO-COPY LOGS TO SD CARD
# ========================================

log_service "========================================"
log_service "AUTO-COPY LOGS TO SD CARD"
log_service "========================================"

SD_LOG_BASE="/sdcard/Adreno_Driver"
if mkdir -p "$SD_LOG_BASE/Booted" "$SD_LOG_BASE/Bootloop" "$SD_LOG_BASE/Config" "$SD_LOG_BASE/Install" 2>/dev/null; then
  log_service "[OK] SD card directory structure created"

  PRIMARY_LOG_BASE="/data/local/tmp/Adreno_Driver"

  if [ -d "$PRIMARY_LOG_BASE" ]; then
    log_service "Copying logs from /data/local/tmp to /sdcard..."
    for log_dir in "Booted" "Bootloop" "Install" "Config"; do
      if [ -d "$PRIMARY_LOG_BASE/$log_dir" ]; then
        if cp -af "$PRIMARY_LOG_BASE/$log_dir"/* "$SD_LOG_BASE/$log_dir/" 2>/dev/null; then
          log_service "[OK] Copied $log_dir logs"
        else
          log_service "[!] Failed to copy $log_dir logs"
        fi
      fi
    done
    log_service "Log copy completed"
  else
    log_service "Primary log directory not found at /data/local/tmp"
  fi
else
  log_service "WARNING: Failed to create SD card log directory"
fi

log_service "========================================"

# ========================================
# ACTIVE RECOVERY: QGL CONFIGURATION
# ========================================

if [ "$QGL" = "y" ]; then
  log_service "========================================"
  log_service "QGL CONFIGURATION ACTIVE RECOVERY"
  log_service "========================================"

  QGL_TARGET="/data/vendor/gpu/qgl_config.txt"
  QGL_OWNER_MARKER="/data/vendor/gpu/.adreno_qgl_owner"
  QGL_REPAIR_NEEDED=false

  if [ -f "$QGL_TARGET" ] && [ ! -f "$QGL_OWNER_MARKER" ]; then
    log_service "[!] QGL: qgl_config.txt exists but was NOT installed by this module"
    log_service "    Owner marker absent → another manager controls this file"
    log_service "    Skipping recovery to avoid overwriting a third-party QGL config"
  else

  if [ -f "$QGL_TARGET" ]; then
    log_service "[OK] QGL config file exists: $QGL_TARGET"
    _qgl_stat=$(stat -c '%A %U:%G %s' "$QGL_TARGET" 2>/dev/null || echo "unknown unknown 0")
    QGL_PERMS="${_qgl_stat%% *}"; _qgl_stat="${_qgl_stat#* }"
    QGL_OWNER="${_qgl_stat%% *}"
    QGL_SIZE="${_qgl_stat##* }"
    unset _qgl_stat
    log_service "  Permissions: $QGL_PERMS"
    log_service "  Owner: $QGL_OWNER"
    log_service "  Size: $QGL_SIZE bytes"

    if [ "$QGL_SIZE" -eq 0 ]; then
      log_service "[X] ERROR: QGL config file is empty!"
      QGL_REPAIR_NEEDED=true
    fi

    if [ "$QGL_PERMS" != "-rw-r--r--" ] && [ "$QGL_PERMS" != "unknown" ]; then
      log_service "[!] WARNING: QGL config has incorrect permissions"
      chmod 0644 "$QGL_TARGET" 2>/dev/null && \
        log_service "[OK] QGL config permissions corrected" || \
        log_service "[X] Failed to correct permissions"
    fi
  else
    log_service "[X] ERROR: QGL config file not found!"
    log_service "  Expected: $QGL_TARGET"
    QGL_REPAIR_NEEDED=true
  fi

  if [ "$QGL_REPAIR_NEEDED" = "true" ]; then
    log_service "Attempting to repair QGL configuration..."
    if [ -f "$MODDIR/qgl_config.txt" ]; then
      mkdir -p /data/vendor/gpu 2>/dev/null
      if cp -f "$MODDIR/qgl_config.txt" "$QGL_TARGET" 2>/dev/null; then
        chmod 0644 "$QGL_TARGET" 2>/dev/null
        chown 0:1000 "$QGL_TARGET" 2>/dev/null
        chcon u:object_r:same_process_hal_file:s0 "$QGL_TARGET" 2>/dev/null || \
          chcon u:object_r:vendor_data_file:s0 "$QGL_TARGET" 2>/dev/null || true
        if [ -f "$QGL_TARGET" ] && [ -s "$QGL_TARGET" ]; then
          NEW_SIZE=$(stat -c%s "$QGL_TARGET" 2>/dev/null || echo "0")
          touch "$QGL_OWNER_MARKER" 2>/dev/null || true
          log_service "[OK] QGL config repaired successfully ($NEW_SIZE bytes)"
          log_service "[OK] QGL owner marker stamped: $QGL_OWNER_MARKER"
        else
          log_service "[X] ERROR: QGL config repair verification failed"
        fi
      else
        log_service "[X] ERROR: Failed to copy QGL config during repair"
      fi
    else
      log_service "[X] ERROR: QGL config source file not found in module"
      log_service "  Module may be corrupted - recommend reinstalling"
    fi
  fi

  fi  # end of foreign-file safety check
fi

# ========================================
# VALIDATE MODULE MOUNTING
# ========================================

log_service "========================================"
log_service "VALIDATING MODULE MOUNTING"
log_service "========================================"

MOUNT_ISSUES=0
MOD_LIB_COUNT=0

if [ -d "$MODDIR/system/vendor/lib" ] || [ -d "$MODDIR/system/vendor/lib64" ]; then
  log_service "Module contains driver libraries (system/vendor):"

  if [ -d "$MODDIR/system/vendor/lib" ]; then
    LIB_COUNT=0
    for _sf in "$MODDIR/system/vendor/lib"/*.so; do [ -f "$_sf" ] && LIB_COUNT=$((LIB_COUNT+1)); done
    log_service "  - system/vendor/lib: $LIB_COUNT libraries"
    MOD_LIB_COUNT=$((MOD_LIB_COUNT + LIB_COUNT))
  fi

  if [ -d "$MODDIR/system/vendor/lib64" ]; then
    LIB64_COUNT=0
    for _sf in "$MODDIR/system/vendor/lib64"/*.so; do [ -f "$_sf" ] && LIB64_COUNT=$((LIB64_COUNT+1)); done
    log_service "  - system/vendor/lib64: $LIB64_COUNT libraries"
    MOD_LIB_COUNT=$((MOD_LIB_COUNT + LIB64_COUNT))
  fi

  if [ $MOD_LIB_COUNT -eq 0 ]; then
    log_service "[!] WARNING: No driver libraries found in module!"
    MOUNT_ISSUES=$((MOUNT_ISSUES + 1))
  else
    log_service "Verifying library readability..."
    MOD_LIB_READABLE=0
    for lib_dir in "$MODDIR/system/vendor/lib" "$MODDIR/system/vendor/lib64"; do
      if [ -d "$lib_dir" ]; then
        for lib in "$lib_dir"/*.so; do
          if [ -f "$lib" ]; then
            if [ -r "$lib" ]; then
              MOD_LIB_READABLE=$((MOD_LIB_READABLE + 1))
            else
              log_service "[!] WARNING: Library not readable: ${lib##*/}"
            fi
          fi
        done
      fi
    done

    if [ $MOD_LIB_COUNT -ne $MOD_LIB_READABLE ]; then
      log_service "[!] WARNING: $((MOD_LIB_COUNT - MOD_LIB_READABLE))/$MOD_LIB_COUNT libraries not readable"
      log_service "  This indicates permission/SELinux issues"
      MOUNT_ISSUES=$((MOUNT_ISSUES + 1))
    else
      log_service "[OK] All $MOD_LIB_COUNT libraries readable and accessible"
    fi
  fi
else
  log_service "[!] WARNING: No driver libraries found in module (system/vendor/lib or system/vendor/lib64)!"
  MOUNT_ISSUES=$((MOUNT_ISSUES + 1))
fi

BIND_COUNT=0
if cmd_exists mount; then
  while IFS= read -r _ml; do
    case "$_ml" in *"$MODDIR"*) BIND_COUNT=$((BIND_COUNT+1)) ;; esac
  done < /proc/mounts 2>/dev/null || \
    while IFS= read -r _ml; do
      case "$_ml" in *"$MODDIR"*) BIND_COUNT=$((BIND_COUNT+1)) ;; esac
    done <<_MNT
$(mount 2>/dev/null)
_MNT
  log_service "Bind mounts from module: $BIND_COUNT"

  if [ "$BIND_COUNT" -eq 0 ]; then
    log_service "[!] WARNING: No bind mounts from module found!"
    log_service "  This may indicate mounting failed"
    MOUNT_ISSUES=$((MOUNT_ISSUES + 1))
  fi
fi

if [ $MOUNT_ISSUES -gt 0 ]; then
  log_service "========================================"
  log_service "[!] WARNING: $MOUNT_ISSUES mounting issue(s) detected!"
  log_service "========================================"
else
  log_service "========================================"
  log_service "[OK] Module mounting validated successfully"
  log_service "========================================"
fi

# ========================================
# CHECK FOR GPU-RELATED AVC DENIALS
# ========================================

log_service "========================================"
log_service "CHECKING FOR GPU AVC DENIALS"
log_service "========================================"

GPU_AVC=0
if cmd_exists dmesg; then
  _DMESG_CACHE=$(dmesg 2>/dev/null)
  _avc_samples=""
  _sample_count=0
  while IFS= read -r _avc_line; do
    case "$_avc_line" in
      *avc*|*AVC*)
        case "$_avc_line" in
          *gpu*|*GPU*|*adreno*|*Adreno*|*kgsl*|*KGSL*)
            GPU_AVC=$((GPU_AVC + 1))
            if [ $_sample_count -lt 5 ]; then
              _avc_samples="${_avc_samples}${_avc_line}
"
              _sample_count=$((_sample_count + 1))
            fi ;;
        esac ;;
    esac
  done << _DMESG_EOF
$_DMESG_CACHE
_DMESG_EOF

  if [ "$GPU_AVC" -gt 0 ]; then
    log_service "[!] Found $GPU_AVC GPU-related AVC denials"
    log_service "  Check dmesg for details: dmesg | grep avc | grep -iE 'gpu|adreno|kgsl'"
    log_service "Sample AVC denials:"
    printf '%s' "$_avc_samples" | while IFS= read -r _s; do
      [ -n "$_s" ] && log_service "  $_s"
    done
  else
    log_service "[OK] No GPU-related AVC denials detected"
  fi
  unset _DMESG_CACHE _avc_samples _avc_line _sample_count
else
  log_service "[!] dmesg not available, cannot check AVC denials"
fi

# ========================================
# VERIFY GPU DEVICE ACCESS
# ========================================

log_service "========================================"
log_service "VERIFYING GPU DEVICE ACCESS"
log_service "========================================"

if [ -c /dev/kgsl-3d0 ]; then
  log_service "[OK] GPU device node exists: /dev/kgsl-3d0"
  _gpu_stat=$(stat -c '%A %U:%G' /dev/kgsl-3d0 2>/dev/null || echo "unknown unknown")
  GPU_PERMS="${_gpu_stat%% *}"
  GPU_OWNER="${_gpu_stat##* }"
  unset _gpu_stat
  log_service "  Permissions: $GPU_PERMS"
  log_service "  Owner: $GPU_OWNER"

  if [ -r /sys/class/kgsl/kgsl-3d0/gpu_model ]; then
    GPU_MODEL=""
    { IFS= read -r GPU_MODEL; } < /sys/class/kgsl/kgsl-3d0/gpu_model 2>/dev/null
    GPU_MODEL="${GPU_MODEL%$'\r'}"
    if [ -n "$GPU_MODEL" ]; then
      log_service "  GPU Model: $GPU_MODEL"
      log_service "[OK] GPU device is functional and accessible"
    else
      log_service "[!] WARNING: GPU device exists but sysfs read failed"
      log_service "  Possible SELinux denial blocking access"
      MOUNT_ISSUES=$((MOUNT_ISSUES + 1))
    fi
  else
    log_service "[!] WARNING: GPU sysfs not readable"
    log_service "  Device may not be functional"
    MOUNT_ISSUES=$((MOUNT_ISSUES + 1))
  fi
else
  log_service "[!] WARNING: GPU device node /dev/kgsl-3d0 not found!"
  MOUNT_ISSUES=$((MOUNT_ISSUES + 1))
fi

# ========================================
# VERIFY PLT STATUS
# ========================================

if [ "$PLT" = "y" ]; then
  log_service "========================================"
  log_service "PLT (PUBLIC LIBRARIES) VERIFICATION"
  log_service "========================================"

  if [ -f /vendor/etc/public.libraries.txt ]; then
    log_service "[OK] Public libraries file exists"
    if grep -q "gpu++.so" /vendor/etc/public.libraries.txt 2>/dev/null; then
      log_service "[OK] gpu++.so found in /vendor/etc/public.libraries.txt"
    else
      log_service "[!] WARNING: gpu++.so NOT found in public.libraries.txt"
    fi
  else
    log_service "[!] WARNING: /vendor/etc/public.libraries.txt not found"
  fi

  _plt_mounted=false
  while IFS= read -r _mnt_line; do
    case "$_mnt_line" in *public.libraries*) _plt_mounted=true; break ;; esac
  done < /proc/mounts 2>/dev/null
  if [ "$_plt_mounted" = "true" ]; then
    log_service "[OK] Public libraries files are mounted"
  else
    log_service "[!] WARNING: Public libraries not mounted"
  fi
  unset _plt_mounted _mnt_line
fi

# ========================================
# SYSTEM INFORMATION COLLECTION
# ========================================

log_service "========================================"
log_service "SYSTEM INFORMATION"
log_service "========================================"

{
  echo ""
  echo "=== Device Information ==="
  echo "Device: $(getprop ro.product.device 2>/dev/null || echo 'unknown')"
  echo "Model: $(getprop ro.product.model 2>/dev/null || echo 'unknown')"
  echo "Manufacturer: $(getprop ro.product.manufacturer 2>/dev/null || echo 'unknown')"
  echo "Android: $(getprop ro.build.version.release 2>/dev/null || echo 'unknown')"
  echo "SDK API: $(getprop ro.build.version.sdk 2>/dev/null || echo 'unknown')"
  echo "Build ID: $(getprop ro.build.id 2>/dev/null || echo 'unknown')"
  echo "ROM: $(getprop ro.build.display.id 2>/dev/null || echo 'unknown')"
  echo ""
  echo "=== GPU Information ==="
  _sysfs_gpu="unknown"; [ -r /sys/class/kgsl/kgsl-3d0/gpu_model ] && { IFS= read -r _sysfs_gpu; } < /sys/class/kgsl/kgsl-3d0/gpu_model 2>/dev/null
  _sysfs_clk="unknown";  [ -r /sys/class/kgsl/kgsl-3d0/gpu_clock ] && { IFS= read -r _sysfs_clk; }  < /sys/class/kgsl/kgsl-3d0/gpu_clock 2>/dev/null
  _sysfs_busy="unknown"; [ -r /sys/class/kgsl/kgsl-3d0/gpubusy ]   && { IFS= read -r _sysfs_busy; } < /sys/class/kgsl/kgsl-3d0/gpubusy 2>/dev/null
  [ -r /sys/class/kgsl/kgsl-3d0/gpu_model ] && echo "GPU Model: ${_sysfs_gpu:-unknown}"
  [ -r /sys/class/kgsl/kgsl-3d0/gpu_clock ] && echo "GPU Clock: ${_sysfs_clk:-unknown} Hz"
  [ -r /sys/class/kgsl/kgsl-3d0/gpubusy ]   && echo "GPU Busy: ${_sysfs_busy:-unknown}"
  unset _sysfs_gpu _sysfs_clk _sysfs_busy
  echo ""
  echo "=== Render Engine Properties ==="
  echo "HWUI Renderer: $(getprop debug.hwui.renderer 2>/dev/null || echo 'default')"
  echo "RenderEngine Backend: $(getprop debug.renderengine.backend 2>/dev/null || echo 'default')"
  echo ""
  echo "=== Root Information ==="
  echo "Root Type: $ROOT_TYPE"
  echo "SUSFS Active (root hiding): $SUSFS_ACTIVE"
  echo "Metamodule Active: $METAMODULE_ACTIVE"
  if [ "$METAMODULE_ACTIVE" = "true" ]; then
    echo "Metamodule Name: $METAMODULE_NAME"
  fi
  echo ""
  echo "=== Mount Information ==="
  echo "Module Libraries: $MOD_LIB_COUNT"
  echo "Mount Issues: $MOUNT_ISSUES"
  echo ""
  echo "=== Driver Configuration ==="
  echo "ARM64 Optimization: $ARM64_OPT"
  echo "QGL Enabled: $QGL"
  echo "PLT Enabled: $PLT"
  echo "Render Mode: $RENDER_MODE"
  echo ""
  echo "=== Installation Info ==="
  if [ -f "$MODDIR/.install_info" ]; then
    cat "$MODDIR/.install_info"
  fi
} >> "$SERVICE_LOG" 2>&1

log_service "System information collected"

# ========================================
# TROUBLESHOOTING REPORT
# ========================================

log_service "========================================"
log_service "TROUBLESHOOTING REPORT"
log_service "========================================"

if [ $MOUNT_ISSUES -gt 0 ] || [ "$GPU_AVC" -gt 0 ]; then
  log_service "[!] Issues detected that may affect module functionality:"
  log_service ""

  if [ $MOUNT_ISSUES -gt 0 ]; then
    log_service "  - Mounting issues: $MOUNT_ISSUES"
    if [ "$ROOT_TYPE" = "KernelSU" ]; then
      if [ "$METAMODULE_ACTIVE" = "false" ]; then
        log_service "    CRITICAL: No metamodule detected for KernelSU!"
        log_service "    Solution: Install MetaMagicMount (RECOMMENDED)"
        log_service "    The module will NOT work without a mounting solution!"
      else
        log_service "    Solution: Check metamodule logs"
        log_service "    Current metamodule: $METAMODULE_NAME"
      fi
    else
      log_service "    Solution: Check root manager logs for mounting errors"
    fi
  fi

  if [ "$GPU_AVC" -gt 0 ]; then
    log_service "  - AVC denials: $GPU_AVC"
    log_service "    Solution: SELinux policies may need adjustment"
    log_service "    Command: dmesg | grep avc | grep -iE 'gpu|adreno|kgsl'"
  fi

  log_service ""
  log_service "Recommended actions:"
  log_service "  1. Check detailed logs at: $LOG_BASE"
  if [ "$ROOT_TYPE" = "KernelSU" ] && [ "$METAMODULE_ACTIVE" = "false" ]; then
    log_service "  2. CRITICAL: Install MetaMagicMount or another metamodule"
  fi
  log_service "  3. Reboot and check if issues persist"
  log_service "  4. Verify GPU device: ls -l /dev/kgsl-3d0"
  log_service "  5. Check for bootloop logs in: $LOG_BASE/Bootloop/"
else
  log_service "[OK] No issues detected - module should be working properly"
  log_service "All verifications passed successfully"
fi

# ========================================
# COLLECT POST-BOOT LOGS
# ========================================

if [ "$VERBOSE" = "y" ]; then
  log_service "========================================"
  log_service "COLLECTING POST-BOOT DIAGNOSTIC LOGS"
  log_service "========================================"

  DIAG_TIMESTAMP=$(date +%Y%m%d_%H%M%S 2>/dev/null || echo 'unknown')

  if cmd_exists logcat; then
    log_service "Collecting logcat (last 10000 lines)..."
    if logcat -d -t 10000 > "$SD_LOG_BASE/Booted/logcat_${DIAG_TIMESTAMP}.txt" 2>/dev/null; then
      log_service "[OK] logcat collected"
    else
      log_service "[!] WARNING: Failed to collect logcat"
    fi
  fi

  if cmd_exists dmesg; then
    log_service "Collecting dmesg..."
    if dmesg > "$SD_LOG_BASE/Booted/dmesg_${DIAG_TIMESTAMP}.log" 2>/dev/null; then
      log_service "[OK] dmesg collected"
    else
      log_service "[!] WARNING: Failed to collect dmesg"
    fi
  fi

  if [ -d /sys/fs/pstore ]; then
    pstore_files=0
    for _pf in /sys/fs/pstore/*; do [ -e "$_pf" ] && pstore_files=$((pstore_files+1)); done
    if [ "$pstore_files" -gt 0 ]; then
      log_service "[!] Found pstore crash data on successful boot (unusual)"
      mkdir -p "$SD_LOG_BASE/Booted/pstore_${DIAG_TIMESTAMP}" 2>/dev/null
      cp -r /sys/fs/pstore/* "$SD_LOG_BASE/Booted/pstore_${DIAG_TIMESTAMP}/" 2>/dev/null || true
    fi
  fi

  if [ "$ROOT_TYPE" = "KernelSU" ] && [ -f "/data/adb/ksu/log.txt" ]; then
    log_service "Collecting KernelSU log..."
    cp /data/adb/ksu/log.txt "$SD_LOG_BASE/Booted/ksu_log_${DIAG_TIMESTAMP}.txt" 2>/dev/null || true
  elif [ "$ROOT_TYPE" = "APatch" ] && [ -f "/data/adb/ap/log.txt" ]; then
    log_service "Collecting APatch log..."
    cp /data/adb/ap/log.txt "$SD_LOG_BASE/Booted/apatch_log_${DIAG_TIMESTAMP}.txt" 2>/dev/null || true
  elif [ "$ROOT_TYPE" = "Magisk" ] && [ -f "/data/adb/magisk/magisk.log" ]; then
    log_service "Collecting Magisk log..."
    cp /data/adb/magisk/magisk.log "$SD_LOG_BASE/Booted/magisk_log_${DIAG_TIMESTAMP}.txt" 2>/dev/null || true
  fi

  log_service "Post-boot diagnostic collection complete"
fi

# ========================================
# CLEAN OLD LOGS
# ========================================

if [ "$VERBOSE" = "y" ]; then
  log_service "Cleaning old logs (keeping last 10 of each type)..."

  for log_type in "service_" "logcat_" "dmesg_" "boot_" "bootloop_" "ksu_log_" "apatch_log_" "magisk_log_"; do
    _tcount=0
    for _tf in "$SD_LOG_BASE/Booted"/${log_type}*.log "$SD_LOG_BASE/Booted"/${log_type}*.txt; do
      [ -f "$_tf" ] && _tcount=$((_tcount+1))
    done
    if [ "$_tcount" -gt 10 ]; then
      _n=0
      for _tf in "$SD_LOG_BASE/Booted"/${log_type}*.log "$SD_LOG_BASE/Booted"/${log_type}*.txt; do
        [ -f "$_tf" ] || continue
        _n=$((_n+1))
        [ $_n -le $((_tcount - 10)) ] && rm -f "$_tf" 2>/dev/null || true
      done
      log_service "Cleaned old ${log_type} logs (kept last 10)"
    fi
    unset _tcount _n _tf
  done

  log_service "Log cleanup completed"
fi

# ========================================
# MARK SUCCESSFUL BOOT
# ========================================

log_service "========================================"
log_service "MARKING SUCCESSFUL BOOT"
log_service "========================================"

BOOT_ATTEMPTS_FILE="/data/local/tmp/adreno_boot_attempts"

if echo 0 > "$BOOT_ATTEMPTS_FILE" 2>/dev/null; then
  log_service "[OK] Boot attempt counter reset to 0"
else
  log_service "[!] WARNING: Failed to reset boot attempt counter"
fi

if touch "$MODDIR/.boot_success" 2>/dev/null; then
  log_service "Boot success marker created"
else
  log_service "WARNING: Failed to create boot success marker"
fi

# ========================================
# PERSIST RENDER MODE TO SYSTEM.PROP
# ========================================
# Write debug.hwui.renderer to system.prop so the root manager (Magisk/KSU/APatch)
# loads it automatically on every subsequent boot — before any script runs.
# This is the MOST reliable persistence mechanism: it does not depend on resetprop
# working at post-fs-data time, and survives any timing issue or path problem.
#
# WHY we do this in service.sh (not post-fs-data):
#   We run AFTER boot_completed, meaning the GPU driver is confirmed loaded,
#   all apps are running, and the system is fully stable. Writing here means
#   the prop is validated-safe before it ever appears in system.prop.
#
# BOTH debug.hwui.renderer AND debug.renderengine.backend are written to system.prop.
#   We have reached boot_completed with the custom Vulkan driver already loaded and
#   confirmed working. Magic mount overlays the module system.prop before init reads
#   it on the NEXT boot, so the driver will be present when SF reads the property.
#   Safe on Magisk ≥v20.4 / KernelSU ≥v0.6.6 / APatch with magic mount.
#
# Vulkan safety for skiavk: we have reached boot_completed with the custom driver
# loaded — this proves Vulkan is functional. The file check is belt-and-suspenders.
# ========================================

log_service "========================================"
log_service "PERSISTING RENDER MODE TO SYSTEM.PROP"
log_service "========================================"
log_service "Render mode: $RENDER_MODE"

SYSPR="$MODDIR/system.prop"

# Step 1: always strip ALL render/SF/stability/OEM-compat/EGL props from system.prop,
# then re-add the correct set for the current mode below.
if [ -f "$SYSPR" ]; then
  awk '!/^debug\.hwui\.renderer=/ && \
       !/^debug\.renderengine\.backend=/ && \
       !/^debug\.sf\.latch_unsignaled=/ && \
       !/^debug\.sf\.auto_latch_unsignaled=/ && \
       !/^debug\.sf\.disable_backpressure=/ && \
       !/^debug\.sf\.enable_hwc_vds=/ && \
       !/^debug\.sf\.enable_transaction_tracing=/ && \
       !/^debug\.sf\.client_composition_cache_size=/ && \
       !/^ro\.sf\.disable_triple_buffer=/ && \
       !/^ro\.surface_flinger\.use_context_priority=/ && \
       !/^ro\.surface_flinger\.max_frame_buffer_acquired_buffers=/ && \
       !/^ro\.surface_flinger\.force_hwc_copy_for_virtual_displays=/ && \
       !/^debug\.hwui\.use_buffer_age=/ && \
       !/^debug\.hwui\.use_partial_updates=/ && \
       !/^debug\.hwui\.use_gpu_pixel_buffers=/ && \
       !/^renderthread\.skia\.reduceopstasksplitting=/ && \
       !/^debug\.hwui\.skip_empty_damage=/ && \
       !/^debug\.hwui\.webview_overlays_enabled=/ && \
       !/^debug\.hwui\.skia_tracing_enabled=/ && \
       !/^debug\.hwui\.skia_use_perfetto_track_events=/ && \
       !/^debug\.hwui\.capture_skp_enabled=/ && \
       !/^debug\.hwui\.skia_atrace_enabled=/ && \
       !/^debug\.hwui\.use_hint_manager=/ && \
       !/^debug\.hwui\.target_cpu_time_percent=/ && \
       !/^com\.qc\.hardware=/ && \
       !/^persist\.sys\.force_sw_gles=/ && \
       !/^debug\.vulkan\.layers=/ && \
       !/^ro\.hwui\.use_vulkan=/ && \
       !/^debug\.hwui\.recycled_buffer_cache_size=/ && \
       !/^debug\.hwui\.overdraw=/ && \
       !/^debug\.hwui\.profile=/ && \
       !/^debug\.hwui\.show_dirty_regions=/ && \
       !/^graphics\.gpu\.profiler\.support=/ && \
       !/^ro\.egl\.blobcache\.multifile=/ && \
       !/^ro\.egl\.blobcache\.multifile_limit=/ && \
       !/^debug\.hwui\.fps_divisor=/ && \
       !/^debug\.hwui\.render_thread=/ && \
       !/^debug\.hwui\.render_dirty_regions=/ && \
       !/^debug\.hwui\.show_layers_updates=/ && \
       !/^debug\.hwui\.filter_test_overhead=/ && \
       !/^debug\.hwui\.nv_profiling=/ && \
       !/^debug\.hwui\.clip_surfaceviews=/ && \
       !/^debug\.hwui\.8bit_hdr_headroom=/ && \
       !/^debug\.hwui\.skip_eglmanager_telemetry=/ && \
       !/^debug\.hwui\.initialize_gl_always=/ && \
       !/^debug\.hwui\.level=/ && \
       !/^debug\.hwui\.disable_vsync=/ && \
       !/^hwui\.disable_vsync=/ && \
       !/^debug\.vulkan\.layers\.enable=/ && \
       !/^persist\.device_config\.runtime_native\.usap_pool_enabled=/ && \
       !/^debug\.gralloc\.enable_fb_ubwc=/ && \
       !/^persist\.sys\.perf\.topAppRenderThreadBoost\.enable=/ && \
       !/^persist\.sys\.gpu\.working_thread_priority=/ && \
       !/^debug\.sf\.early_phase_offset_ns=/ && \
       !/^debug\.sf\.early_app_phase_offset_ns=/ && \
       !/^debug\.sf\.early_gl_phase_offset_ns=/ && \
       !/^debug\.sf\.early_gl_app_phase_offset_ns=/ && \
       !/^debug\.hwui\.use_skia_graphite=/ && \
       !/^ro\.surface_flinger\.supports_background_blur=/ && \
       !/^persist\.sys\.sf\.disable_blurs=/ && \
       !/^ro\.sf\.blurs_are_expensive=/ && \
       !/^vendor\.gralloc\.enable_fb_ubwc=/ && \
       !/^ro\.config\.vulkan\.enabled=/ && \
       !/^persist\.vendor\.vulkan\.enable=/ && \
       !/^persist\.graphics\.vulkan\.disable_pre_rotation=/ && \
       !/^debug\.sf\.use_phase_offsets_as_durations=/ && \
       !/^debug\.hwui\.texture_cache_size=/ && \
       !/^debug\.hwui\.layer_cache_size=/ && \
       !/^debug\.hwui\.path_cache_size=/ && \
       !/^debug\.hwui\.force_dark=/ && \
       !/^ro\.hwui\.text_small_cache_width=/ && \
       !/^ro\.hwui\.text_small_cache_height=/ && \
       !/^ro\.hwui\.text_large_cache_width=/ && \
       !/^ro\.hwui\.text_large_cache_height=/ && \
       !/^ro\.hwui\.drop_shadow_cache_size=/ && \
       !/^ro\.hwui\.gradient_cache_size=/ && \
       !/^persist\.sys\.sf\.native_mode=/ && \
       !/^debug\.sf\.treat_170m_as_sRGB=/ && \
       !/^debug\.egl\.debug_proc=/ && \
       !/^debug\.sf\.hw=/ && \
       !/^persist\.sys\.ui\.hw=/ && \
       !/^debug\.egl\.hw=/ && \
       !/^debug\.egl\.profiler=/ && \
       !/^debug\.egl\.trace=/ && \
       !/^debug\.vulkan\.dev\.layers=/ && \
       !/^persist\.graphics\.vulkan\.validation_enable=/ && \
       !/^debug\.hwui\.drawing_enabled=/ && \
       !/^hwui\.disable_vsync=/' \
    "$SYSPR" > "${SYSPR}.tmp" 2>/dev/null && \
    mv "${SYSPR}.tmp" "$SYSPR" 2>/dev/null || \
    rm -f "${SYSPR}.tmp" 2>/dev/null
  log_service "[OK] system.prop: cleared all old render/SF/HWUI/perf props"
else
  touch "$SYSPR" 2>/dev/null || true
fi

# Step 2: write the correct props for the next boot
case "$RENDER_MODE" in
  skiavk|skiavk_all)
    _VK_HW=$(getprop ro.hardware.vulkan 2>/dev/null || echo "")
    _VK_OK=false
    [ -f "/vendor/lib64/hw/vulkan.adreno.so" ]  && _VK_OK=true
    [ -f "/vendor/lib64/egl/vulkan.adreno.so" ] && _VK_OK=true
    [ -n "$_VK_HW" ] && [ -f "/vendor/lib64/hw/vulkan.${_VK_HW}.so" ] && _VK_OK=true
    [ -n "$_VK_HW" ] && [ -f "/vendor/lib64/egl/vulkan.${_VK_HW}.so" ] && _VK_OK=true
    [ -f "$MODDIR/system/vendor/lib64/hw/vulkan.adreno.so" ]  && _VK_OK=true
    [ -f "$MODDIR/system/vendor/lib64/egl/vulkan.adreno.so" ] && _VK_OK=true
    # Boot reached boot_completed → Vulkan confirmed regardless of file paths
    _VK_OK=true

    {
      # ── DANGEROUS SF PROPS INTENTIONALLY OMITTED ─────────────────────────────
      # The following were present in older module versions and caused the
      # "shows for a second then whole screen black" crash:
      #   debug.sf.latch_unsignaled, debug.sf.auto_latch_unsignaled,
      #   debug.sf.disable_backpressure, debug.sf.enable_hwc_vds,
      #   ro.sf.disable_triple_buffer, debug.sf.client_composition_cache_size,
      #   debug.sf.enable_transaction_tracing, ro.surface_flinger.use_context_priority,
      #   ro.surface_flinger.max_frame_buffer_acquired_buffers,
      #   ro.surface_flinger.force_hwc_copy_for_virtual_displays,
      #   debug.sf.use_phase_offsets_as_durations
      #
      # ROOT CAUSE: latch_unsignaled tells SF to present frames BEFORE GPU fence
      # signals. On custom Adreno drivers with broken fence FD export, the fence
      # NEVER signals → SF presents frame 1 (visible for ~1s), then ALL buffers
      # stall waiting for unsignaled fences → HWUI deadlock → black screen.
      # disable_backpressure removes the only safety valve. disable_triple_buffer
      # and max_frame_buffer=2 starve the pipeline. use_phase_offsets_as_durations
      # is Samsung-specific and breaks vsync scheduling on all other OEM ROMs.
      # These props are now kept in the strip/delete lists only for cleanup.
      # Write renderer props to system.prop — boot_completed confirms Vulkan is functional
      # debug.hwui.renderer persisted here for next-boot per-process HWUI initialization.
      # debug.renderengine.backend intentionally NOT written to system.prop — see
      # post-fs-data.sh header comment. It is set via resetprop before SF starts only.
      echo "debug.hwui.renderer=skiavk"
      echo "com.qc.hardware=true"
      echo "persist.sys.force_sw_gles=0"
      echo "debug.hwui.use_buffer_age=false"
      echo "debug.hwui.use_partial_updates=false"
      echo "debug.hwui.use_gpu_pixel_buffers=false"
      # reduceopstasksplitting=false — AOSP default. true causes rendering artifacts
      echo "renderthread.skia.reduceopstasksplitting=false"
      echo "debug.hwui.skip_empty_damage=true"
      echo "debug.hwui.webview_overlays_enabled=true"
      echo "debug.hwui.skia_tracing_enabled=false"
      echo "debug.hwui.skia_use_perfetto_track_events=false"
      echo "debug.hwui.capture_skp_enabled=false"
      echo "debug.hwui.skia_atrace_enabled=false"
      echo "debug.hwui.use_hint_manager=true"
      echo "debug.hwui.target_cpu_time_percent=33"  # 33% CPU, 67% GPU — optimal for Vulkan async thread
      echo "debug.vulkan.layers="
      echo "ro.hwui.use_vulkan=true"
      echo "debug.hwui.recycled_buffer_cache_size=4"
      echo "debug.hwui.overdraw=false"
      echo "debug.hwui.profile=false"
      echo "debug.hwui.show_dirty_regions=false"
      echo "graphics.gpu.profiler.support=false"
      echo "ro.egl.blobcache.multifile=true"
      echo "ro.egl.blobcache.multifile_limit=33554432"
      echo "debug.hwui.render_thread=true"
      echo "debug.hwui.render_dirty_regions=false"
      echo "debug.hwui.show_layers_updates=false"
      echo "debug.hwui.filter_test_overhead=false"
      echo "debug.hwui.nv_profiling=false"
      # clip_surfaceviews: NOT written. AOSP default (true) clips SurfaceViews correctly.
      # Writing false causes video/camera SurfaceView to bleed outside player bounds.
      echo "debug.hwui.8bit_hdr_headroom=false"
      echo "debug.hwui.skip_eglmanager_telemetry=true"
      echo "debug.hwui.initialize_gl_always=false"
      echo "debug.hwui.level=0"
      echo "debug.hwui.disable_vsync=false"
      echo "persist.device_config.runtime_native.usap_pool_enabled=true"
      echo "debug.gralloc.enable_fb_ubwc=1"
      echo "persist.sys.perf.topAppRenderThreadBoost.enable=true"
      echo "persist.sys.gpu.working_thread_priority=1"
      # Phase offset props omitted — SM8150-specific values
      # (500µs SF, 3ms GL) cause systematic vsync starvation on Adreno 6xx/7xx
      # at 90/120Hz: too tight → SF misses vsync → frame drops → watchdog → reboot loop.
      # Device tree provides correctly-tuned values for each SoC.
      echo "debug.hwui.use_skia_graphite=false"
      # blur disable: NOT applied in SkiaVK — blanket disable causes UI regression on Samsung/MIUI.
      echo "ro.sf.blurs_are_expensive=1"
      echo "vendor.gralloc.enable_fb_ubwc=1"
      echo "ro.config.vulkan.enabled=true"
      echo "persist.vendor.vulkan.enable=1"
      # disable_pre_rotation: NOT set. UE4/Unity handle pre-rotation in projection matrix.
      # Setting true -> swapchain dimension mismatch -> VK_ERROR_OUT_OF_DATE_KHR loop -> crash.
      echo "debug.hwui.force_dark=false"
      # ── Text atlas: AOSP defaults restored (glyph overflow -> font corruption -> crash fix) ──
      echo "ro.hwui.text_small_cache_width=1024"
      echo "ro.hwui.text_small_cache_height=512"
      echo "ro.hwui.text_large_cache_width=2048"
      echo "ro.hwui.text_large_cache_height=1024"
      # Shadow/gradient cache: further reduce peak VRAM budget
      echo "ro.hwui.drop_shadow_cache_size=3"
      echo "ro.hwui.gradient_cache_size=1"
      # native_mode=0: NOT set. Forces sRGB globally, disables HDR/WCG on capable displays.
      # HDR output determined by display capabilities, not forced via prop.
      # Samsung/Xiaomi WCG: map BT.601/170M -> VK_COLOR_SPACE_SRGB_NONLINEAR_KHR
      echo "debug.sf.treat_170m_as_sRGB=1"
      # Clear OEM EGL debug hook (MIUI/HyperOS/ColorOS ABI mismatch → SIGSEGV in libvulkan)
      echo "debug.egl.debug_proc="
      # ── Always-active HW path reinforcement ──
      # OEM init scripts may reset these after boot_completed.
      # Writing them to system.prop ensures they persist from next boot onward,
      # AND service.sh re-enforces them live (below in resetprop section).
      echo "debug.sf.hw=1"
      echo "persist.sys.ui.hw=1"
      echo "debug.egl.hw=1"
      echo "debug.egl.profiler=0"
      echo "debug.egl.trace=0"
      # OEM Vulkan dev/validation layers — vendor namespace, SEPARATE from debug.vulkan.layers
      echo "debug.vulkan.dev.layers="
      echo "persist.graphics.vulkan.validation_enable=0"
      # HWUI drawing state + non-debug vsync clear
      echo "debug.hwui.drawing_enabled=true"
      echo "hwui.disable_vsync=false"
      # ── HWUI render caches — reduce texture/layer stalls (stripped but never re-set) ──
      echo "debug.hwui.texture_cache_size=72"
      echo "debug.hwui.layer_cache_size=48"
      echo "debug.hwui.path_cache_size=32"
    } >> "$SYSPR" 2>/dev/null && \
      log_service "[OK] system.prop: skiavk renderer+HWUI+OEM+EGL+perf+compat+VKfix props written (dangerous SF fence/buffer props EXCLUDED — see inline comments; phase offsets OMITTED — SM8150-specific, cause vsync reboot loops on other SoCs)" || \
      log_service "[!] WARNING: Failed to write one or more props to system.prop"
    unset _VK_HW _VK_OK
    ;;

  skiagl)
    # OpenGL is always safe — no Vulkan dependency.
    {
      echo "debug.hwui.renderer=skiagl"
      # debug.renderengine.backend intentionally NOT written to system.prop.
      # Same risk as skiavk: OEM ROM live callbacks crash SF if this prop changes
      # at runtime. Set exclusively via resetprop before SF starts in post-fs-data.sh.
      echo "persist.sys.force_sw_gles=0"
      echo "com.qc.hardware=true"
      # GL partial-update extensions disabled — unreliable on custom Adreno drivers.
      # EGL_EXT_buffer_age and EGL_KHR_partial_update incorrect values cause stale-pixel
      # glitches (old frame content visible in unrepainted regions). Full-frame safer.
      echo "debug.hwui.use_buffer_age=false"
      echo "debug.hwui.use_partial_updates=false"
      echo "debug.hwui.render_dirty_regions=false"
      echo "debug.hwui.webview_overlays_enabled=true"
      # reduceopstasksplitting=false — AOSP default. true causes rendering artifacts.
      echo "renderthread.skia.reduceopstasksplitting=false"
      echo "debug.hwui.skia_tracing_enabled=false"
      echo "debug.hwui.skia_use_perfetto_track_events=false"
      echo "debug.hwui.capture_skp_enabled=false"
      echo "debug.hwui.skia_atrace_enabled=false"
      echo "debug.hwui.overdraw=false"
      echo "debug.hwui.profile=false"
      echo "debug.hwui.show_dirty_regions=false"
      echo "debug.hwui.show_layers_updates=false"
      echo "ro.egl.blobcache.multifile=true"
      echo "ro.egl.blobcache.multifile_limit=33554432"
      echo "debug.hwui.render_thread=true"
      echo "debug.hwui.use_hint_manager=true"
      echo "debug.hwui.target_cpu_time_percent=66"
      echo "debug.hwui.skip_eglmanager_telemetry=true"
      # initialize_gl_always=false — CRASH FIX: same reason as post-fs-data.sh.
      # ro.zygote.disable_gl_preload=true prevents Zygote preloading stock driver.
      # initialize_gl_always=true would force EGL init in every process at startup,
      # including NDK/game apps that also init their own Vulkan from another thread.
      # The custom Adreno driver has a race between these two GPU contexts → SIGSEGV.
      echo "debug.hwui.initialize_gl_always=false"
      echo "debug.hwui.disable_vsync=false"
      echo "debug.hwui.level=0"
      echo "debug.gralloc.enable_fb_ubwc=1"
      echo "vendor.gralloc.enable_fb_ubwc=1"
      echo "persist.device_config.runtime_native.usap_pool_enabled=true"
      echo "persist.sys.perf.topAppRenderThreadBoost.enable=true"
      echo "persist.sys.gpu.working_thread_priority=1"
      echo "debug.hwui.use_skia_graphite=false"
      # blur: ENABLED in SkiaGL — GL-based blur uses standard EGL/GL paths that work correctly.
      # Disabling breaks WindowBlurBehind on Samsung One UI / MIUI.
      echo "ro.sf.blurs_are_expensive=1"
      # ── CRASH-FIX PROPS (same as skiavk, required in GL mode) ─────────────────
      # graphics.gpu.profiler.support=false: Snapdragon Profiler intercepts both GL
      # and Vulkan. Custom driver has different internal function table → wrong ABI
      # when profiler hooks GL calls → SIGSEGV. Must be explicitly false (not deleted,
      # as deletion reverts to OEM default which is often true on Snapdragon devices).
      echo "graphics.gpu.profiler.support=false"
      # use_gpu_pixel_buffers=false: PBO readback race exists on custom Adreno GL path
      # too (not only Vulkan). Triggers during screenshots/multitasking → SIGSEGV.
      echo "debug.hwui.use_gpu_pixel_buffers=false"
      # recycled_buffer_cache_size=4: AOSP default; OEM builds may ship value=2,
      # causing constant GL buffer realloc under pressure → OOM crash.
      echo "debug.hwui.recycled_buffer_cache_size=4"
      # skip_empty_damage / stability props
      echo "debug.hwui.skip_empty_damage=true"
      echo "debug.hwui.8bit_hdr_headroom=false"
      echo "debug.hwui.nv_profiling=false"
      echo "debug.hwui.filter_test_overhead=false"
      echo "debug.sf.hw=1"
      echo "persist.sys.ui.hw=1"
      echo "debug.egl.hw=1"
      echo "debug.egl.profiler=0"
      echo "debug.egl.trace=0"
      echo "debug.vulkan.dev.layers="
      echo "persist.graphics.vulkan.validation_enable=0"
      echo "debug.hwui.drawing_enabled=true"
      echo "hwui.disable_vsync=false"
      echo "debug.egl.debug_proc="
      echo "debug.hwui.force_dark=false"
      # ── HWUI render caches — reduce texture/layer stalls in GL mode ──
      echo "debug.hwui.texture_cache_size=72"
      echo "debug.hwui.layer_cache_size=48"
      echo "debug.hwui.path_cache_size=32"
    } >> "$SYSPR" 2>/dev/null && \
      log_service "[OK] system.prop: 66 skiagl+renderengine+stability+crash-fix+perf+compat props written. initialize_gl_always=false (CRASH FIX). profiler.support=false (Snapdragon profiler crash fix). use_gpu_pixel_buffers=false (PBO race fix). Blur ENABLED in GL mode." || \
      log_service "[!] WARNING: Failed to write one or more props to system.prop"
    log_service "  Next boot: root manager will load these automatically"
    ;;

  normal|*)
    # Normal mode: no render prop in system.prop — system uses its default renderer.
    # We already stripped the old value above, so system.prop is now clean.
    log_service "[OK] system.prop: render mode=normal, no hwui.renderer prop written"
    ;;
esac

log_service "========================================"
log_service "RENDER MODE PERSISTENCE COMPLETE"
log_service "========================================"

# ========================================
# LIVE RESETPROP: OEM OVERRIDE ENFORCEMENT
# ========================================
# Some OEM ROMs (MIUI/HyperOS, FuntouchOS, ColorOS) run init.d scripts or
# late_start services that RESET certain props after boot_completed fires.
# This section re-enforces critical props live, AFTER those OEM scripts run,
# to guarantee they're active for any apps opened by the user.
# ========================================
if cmd_exists resetprop; then
  # BUG3 FIX: Re-read RENDER_MODE from the compat auto-degrade state file
  # before this second enforcement block. The early enforcement (boot+2s above)
  # used $RENDER_MODE as loaded from config. But the vulkan compat gate in
  # post-fs-data.sh OR the service-phase compat probe (BLOCK C below) may have
  # written an auto-degraded mode (e.g., skiavk → skiagl) to the state file.
  # Without re-reading, the original RENDER_MODE would be re-enforced here,
  # defeating the auto-degrade and re-applying skiavk on an incompatible device.
  _degrade_marker="/data/local/tmp/adreno_skiavk_degraded"
  if [ -f "$_degrade_marker" ]; then
    { IFS= read -r _degraded_mode; } < "$_degrade_marker" 2>/dev/null || _degraded_mode=""
    if [ -n "$_degraded_mode" ] && [ "$_degraded_mode" != "$RENDER_MODE" ]; then
      log_service "[BUG3-FIX] RENDER_MODE re-read: compat gate degraded '$RENDER_MODE' → '$_degraded_mode'"
      RENDER_MODE="$_degraded_mode"
    fi
    unset _degraded_mode
  fi
  unset _degrade_marker

  log_service "========================================"
  log_service "LIVE RESETPROP: Enforcing OEM-override-resistant props"
  log_service "========================================"

  # Always enforce globally (all render modes)
  resetprop debug.sf.hw 1 2>/dev/null || true
  resetprop persist.sys.ui.hw 1 2>/dev/null || true
  resetprop debug.egl.hw 1 2>/dev/null || true
  resetprop debug.egl.profiler 0 2>/dev/null || true
  resetprop debug.egl.trace 0 2>/dev/null || true
  resetprop debug.vulkan.dev.layers "" 2>/dev/null || true
  resetprop persist.graphics.vulkan.validation_enable 0 2>/dev/null || true
  resetprop debug.hwui.drawing_enabled true 2>/dev/null || true
  resetprop hwui.disable_vsync false 2>/dev/null || true
  resetprop debug.egl.debug_proc "" 2>/dev/null || true
  resetprop debug.hwui.force_dark false 2>/dev/null || true

  case "$RENDER_MODE" in
    skiavk|skiavk_all)
      # Reinforce critical skiavk-specific props
      resetprop debug.hwui.renderer skiavk 2>/dev/null || true
      # debug.renderengine.backend intentionally NOT live-resetprop'd here.
      # SF is active; OEM ROM property watchers fire a RenderEngine reinit on change
      # → SF crash → all apps lose window surfaces → watchdog reboot.
      # It is set safely via resetprop BEFORE SF starts in post-fs-data.sh.
      resetprop ro.hwui.use_vulkan true 2>/dev/null || true
      resetprop persist.vendor.vulkan.enable 1 2>/dev/null || true
      resetprop ro.config.vulkan.enabled true 2>/dev/null || true
      resetprop persist.sys.force_sw_gles 0 2>/dev/null || true
      # disable_pre_rotation: NOT enforced. Causes VK_ERROR_OUT_OF_DATE_KHR crash in UE4/Unity.
      # Explicitly DELETE it to clear any value set by a previous module version.
      resetprop --delete persist.graphics.vulkan.disable_pre_rotation 2>/dev/null || true
      resetprop debug.vulkan.layers "" 2>/dev/null || true
      # native_mode: NOT enforced. Forces sRGB, disables HDR on WCG displays.
      resetprop debug.sf.treat_170m_as_sRGB 1 2>/dev/null || true
      # blur: NOT disabled in SkiaVK — blanket disable causes Samsung/MIUI UI regression.
      resetprop --delete ro.surface_flinger.supports_background_blur 2>/dev/null || true
      resetprop --delete persist.sys.sf.disable_blurs 2>/dev/null || true
      resetprop ro.sf.blurs_are_expensive 1 2>/dev/null || true
      resetprop debug.hwui.use_partial_updates false 2>/dev/null || true
      resetprop debug.hwui.use_buffer_age false 2>/dev/null || true
      resetprop debug.hwui.use_gpu_pixel_buffers false 2>/dev/null || true
      resetprop debug.hwui.recycled_buffer_cache_size 4 2>/dev/null || true
      resetprop debug.hwui.target_cpu_time_percent 33 2>/dev/null || true  # 33% CPU / 67% GPU split — optimal for Skia Vulkan threaded
      resetprop debug.hwui.initialize_gl_always false 2>/dev/null || true
      resetprop ro.hwui.text_small_cache_width 1024 2>/dev/null || true
      resetprop ro.hwui.text_small_cache_height 512 2>/dev/null || true
      resetprop ro.hwui.text_large_cache_width 2048 2>/dev/null || true
      resetprop ro.hwui.text_large_cache_height 1024 2>/dev/null || true
      resetprop graphics.gpu.profiler.support false 2>/dev/null || true
      # debug.hwui.use_skia_graphite: Skia Graphite backend (Android 15+, API 35+).
      # Custom Adreno drivers do not implement the VK_KHR_dynamic_rendering extension
      # that Graphite requires — enabling it causes immediate vkCreateDevice failure.
      # Explicitly disable on all Android versions:
      #   Android 11–14: prop is unrecognized → no-op (safe)
      #   Android 15+:   prop is read by HWUI → prevents Graphite activation → safe
      resetprop debug.hwui.use_skia_graphite false 2>/dev/null || true
      # reduceopstasksplitting=false — ensure AOSP default, not prior true value
      resetprop renderthread.skia.reduceopstasksplitting false 2>/dev/null || true
      # clip_surfaceviews: delete to restore AOSP default (true).
      # OEM ROMs may set this to false, causing SurfaceView (camera, video player)
      # to render outside its parent window bounds.
      resetprop --delete debug.hwui.clip_surfaceviews 2>/dev/null || true
      # HWUI render caches — reduce texture/layer/path upload stalls
      resetprop debug.hwui.texture_cache_size 72 2>/dev/null || true
      resetprop debug.hwui.layer_cache_size 48 2>/dev/null || true
      resetprop debug.hwui.path_cache_size 32 2>/dev/null || true
      log_service "[OK] skiavk OEM-override-resistant props re-enforced live"
      ;;
    skiagl)
      resetprop debug.hwui.renderer skiagl 2>/dev/null || true
      # debug.renderengine.backend intentionally NOT live-resetprop'd — same OEM
      # watcher risk as skiavk. Set before SF starts in post-fs-data.sh only.
      resetprop persist.sys.force_sw_gles 0 2>/dev/null || true
      # use_partial_updates/use_buffer_age: keep false — custom driver EGL unreliable
      resetprop debug.hwui.use_partial_updates false 2>/dev/null || true
      resetprop debug.hwui.use_buffer_age false 2>/dev/null || true
      resetprop debug.hwui.render_dirty_regions false 2>/dev/null || true
      resetprop renderthread.skia.reduceopstasksplitting false 2>/dev/null || true
      # Graphite backend disable — same rationale as skiavk block above.
      # No-op on Android 11–14; prevents Graphite on Android 15+ (custom driver
      # lacks VK_KHR_dynamic_rendering → vkCreateDevice failure if enabled).
      resetprop debug.hwui.use_skia_graphite false 2>/dev/null || true
      # blur: ENABLED in SkiaGL — clean up any skiavk residue
      resetprop --delete ro.surface_flinger.supports_background_blur 2>/dev/null || true
      resetprop --delete persist.sys.sf.disable_blurs 2>/dev/null || true
      # disable_pre_rotation: NOT enforced. Causes VK_ERROR_OUT_OF_DATE_KHR crash in UE4/Unity.
      # Explicitly DELETE it to clear any value set by a previous module version.
      resetprop --delete persist.graphics.vulkan.disable_pre_rotation 2>/dev/null || true
      # Stability props matching SkiaVK coverage
      resetprop debug.hwui.skip_empty_damage true 2>/dev/null || true
      resetprop debug.hwui.filter_test_overhead false 2>/dev/null || true
      resetprop debug.hwui.nv_profiling false 2>/dev/null || true
      resetprop debug.hwui.8bit_hdr_headroom false 2>/dev/null || true
      # clip_surfaceviews: delete to restore AOSP default (true).
      # Prevents SurfaceView (video, camera) from bleeding outside parent bounds.
      resetprop --delete debug.hwui.clip_surfaceviews 2>/dev/null || true
      # HWUI render caches — reduce texture/layer/path upload stalls in GL mode
      resetprop debug.hwui.texture_cache_size 72 2>/dev/null || true
      resetprop debug.hwui.layer_cache_size 48 2>/dev/null || true
      resetprop debug.hwui.path_cache_size 32 2>/dev/null || true
      log_service "[OK] skiagl OEM-override-resistant props re-enforced live"
      ;;
    normal|*)
      log_service "[OK] normal mode: global OEM props enforced"
      ;;
  esac

  # ── Stale Skia pipeline cache clearing ──────────────────────────────────────
  # CRITICAL: Only clear caches when the render mode has ACTUALLY CHANGED.
  #
  # Clearing on EVERY boot causes massive shader recompilation on first app open:
  #   - Facebook alone has 2000+ shaders → OOM spike during recompile
  #   - OOM kills both Facebook AND the GMS auth service simultaneously
  #   - GMS auth service crash while holding token lock → all Google accounts vanish
  #   - Apps that haven't fully opened yet crash during recompile → the 5-10 minute
  #     "every app crashes immediately" window the user sees after boot
  #
  # Correct behaviour: clear ONLY when the renderer backend changes (GL↔Vulkan).
  # Cached pipelines from a PREVIOUS session with the SAME renderer are valid and
  # safe to reuse — clearing them wastes GPU time and causes the symptoms above.
  #
  # Implementation: persist last active render mode to a state file. Compare on
  # each boot. Clear only on mismatch (mode changed since last boot).
  _LAST_MODE_FILE="/data/local/tmp/adreno_last_render_mode"
  _LAST_MODE=""
  if [ -f "$_LAST_MODE_FILE" ]; then
    { IFS= read -r _LAST_MODE; } < "$_LAST_MODE_FILE" 2>/dev/null || _LAST_MODE=""
  fi

  if [ "$RENDER_MODE" != "$_LAST_MODE" ]; then
    log_service "Render mode changed: '${_LAST_MODE:-<none>}' → '$RENDER_MODE' — clearing stale Skia/HWUI pipeline caches"
    # shader_journal files — HWUI Skia shader journal manifests
    find /data/user_de -name "*.shader_journal" 2>/dev/null -delete || true
    # Global HWUI pipeline key cache — use rm -rf on the directory (glob expansion
    # is unreliable in POSIX sh when no matching files exist; -rf on dir is safe).
    rm -rf /data/misc/hwui/ 2>/dev/null || true
    # Per-app Skia pipeline caches (the main crash culprit on GL→Vulkan switch)
    find /data/user_de -maxdepth 3 -type d -name "app_skia_pipeline_cache" \
        -exec rm -rf {} + 2>/dev/null || true
    find /data/data -maxdepth 2 -type d -name "app_skia_pipeline_cache" \
        -exec rm -rf {} + 2>/dev/null || true
    log_service "[OK] Stale Skia/HWUI pipeline caches cleared (mode change: ${_LAST_MODE:-<none>} → $RENDER_MODE)"
  else
    log_service "[OK] Render mode unchanged ('$RENDER_MODE') — pipeline caches preserved (no recompile overhead)"
  fi

  # Persist current mode for next boot comparison
  echo "$RENDER_MODE" > "$_LAST_MODE_FILE" 2>/dev/null || true
  unset _LAST_MODE _LAST_MODE_FILE

  log_service "========================================"
  log_service "LIVE RESETPROP: Complete"
  log_service "========================================"
else
  log_service "[!] resetprop not available — live OEM override enforcement skipped"
fi

if [ -f "/data/local/tmp/adreno_boot_state" ]; then
  rm -f "/data/local/tmp/adreno_boot_state" 2>/dev/null && log_service "Boot state file cleaned up"
fi

# Belt-and-suspenders: remove first_boot_pending marker if post-fs-data didn't clean it.
# This is a safety net — post-fs-data should already have removed it. If it's still
# here after a successful boot, it means the deferred render mode is now safe to apply
# on the NEXT boot (which is exactly what we want).
if [ -f "$MODDIR/.first_boot_pending" ]; then
  rm -f "$MODDIR/.first_boot_pending" 2>/dev/null && \
    log_service "[OK] First boot pending marker cleaned up by service.sh" || true
fi

# ========================================
# COMPLETION
# ========================================

log_service "========================================"
log_service "service.sh completed successfully"
log_service "Total elapsed time: approx ${ELAPSED:-0}s + processing"
log_service "========================================"

exit 0
