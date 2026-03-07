#!/system/bin/sh
# ============================================================
# ADRENO DRIVER MODULE — POST-FS-DATA
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
# Compatible with: Magisk, KernelSU, APatch
#
# NOTE: Renderer props (debug.hwui.renderer, debug.renderengine.backend)
# are now intentionally persisted to system.prop by service.sh after a
# confirmed successful skiavk boot.  Stripping them here would fight that
# mechanism and cause SF to miss the renderer on the next boot.
# The render-mode case below strips/rewrites all render props atomically.
# ========================================

# ========================================
# SHARED FUNCTIONS
# ========================================

. "$MODDIR/common.sh"

# ========================================
# EARLY ROOT DETECTION
# ========================================

# Initialize metamodule state so it is always defined regardless of root type
METAMODULE_ACTIVE=false
METAMODULE_NAME=""
METAMODULE_ID=""

# Note: KernelSU also sets MAGISK_VER_CODE=25200 for compat — check KSU first.
ROOT_TYPE="Unknown"

_km=false
while IFS= read -r _kl; do
  case "$_kl" in *kernelsu*) _km=true; break;; esac
done < /proc/modules 2>/dev/null

if [ "${KSU:-false}" = "true" ] || [ "${KSU_KERNEL_VER_CODE:-0}" -gt 0 ] || \
   [ -f "/data/adb/ksu/bin/ksud" ] || [ -d "/data/adb/ksu" ] || \
   [ "$_km" = "true" ] || [ -e "/dev/ksu" ]; then
  ROOT_TYPE="KernelSU"
else
  IFS= read -r _pv < /proc/version 2>/dev/null
  if [ "${APATCH:-false}" = "true" ] || [ "${APATCH_VER_CODE:-0}" -gt 0 ] || \
     [ -f "/data/adb/apd" ] || [ -d "/data/adb/ap" ] || \
     { case "${_pv:-}" in *APatch*) true;; *) false;; esac; }; then
    ROOT_TYPE="APatch"
  elif [ -n "${MAGISK_VER:-}" ] || [ "${MAGISK_VER_CODE:-0}" -gt 0 ] || \
       [ -f "/data/adb/magisk/magisk" ]; then
    ROOT_TYPE="Magisk"
  fi
  unset _pv
fi
unset _km _kl

# ========================================
# BOOT COUNTER FILE PATH — defined here so it is available to ALL code
# paths below, including the early skip_mount exit and the rollback mechanism.
# ========================================
BOOT_ATTEMPTS_FILE="/data/local/tmp/adreno_boot_attempts"

# ── SHARED GAME EXCLUSION LIST ────────────────────────────────────────────────
# Defines GAME_EXCLUSION_PKGS and _game_pkg_excluded() used in force-stop loops.
# Edit via Adreno Manager WebUI (Config → Game Exclusion List) or manually.
# Stored at SD_CONFIG first, then module path as fallback.
_GAME_EXCL_SD="/sdcard/Adreno_Driver/Config/game_exclusion_list.sh"
_GAME_EXCL_MOD="${MODDIR}/game_exclusion_list.sh"
_GAME_EXCL_DATA="/data/local/tmp/adreno_game_exclusion_list.sh"
if [ -f "$_GAME_EXCL_SD" ]; then
  # shellcheck source=/dev/null
  . "$_GAME_EXCL_SD"
elif [ -f "$_GAME_EXCL_DATA" ]; then
  # shellcheck source=/dev/null
  . "$_GAME_EXCL_DATA"
elif [ -f "$_GAME_EXCL_MOD" ]; then
  # shellcheck source=/dev/null
  . "$_GAME_EXCL_MOD"
else
  # Fallback inline definition (matches bundled game_exclusion_list.sh defaults)
  GAME_EXCLUSION_PKGS="com.tencent.ig com.pubg.krmobile com.pubg.imobile com.vng.pubgmobile com.rekoo.pubgm com.tencent.tmgp.pubgmhd com.epicgames.* com.activision.callofduty.shooter com.garena.game.codm com.tencent.tmgp.cod com.vng.codmvn com.miHoYo.GenshinImpact com.cognosphere.GenshinImpact com.miHoYo.enterprise.HSRPrism com.HoYoverse.hkrpgoversea com.levelinfinite.hotta com.proximabeta.mfh com.HoYoverse.Nap com.miHoYo.ZZZ"
  _game_pkg_excluded() { local _p="$1" _e; for _e in $GAME_EXCLUSION_PKGS; do case "$_p" in $_e) return 0;; esac; done; return 1; }
fi
unset _GAME_EXCL_SD _GAME_EXCL_MOD _GAME_EXCL_DATA
# ─────────────────────────────────────────────────────────────────────────────

# ========================================
# APATCH MODE DETECTION
# ========================================
# APatch switched to Magic Mount as default in v0.10.8+ (build 11039, Feb 2025).
# OverlayFS: opt-in via /data/adb/.overlay_enable
# Lite mode: opt-in via /data/adb/.litemode_enable

APATCH_MODE="unknown"
APATCH_OVERLAYFS=false
APATCH_LITEMODE=false

if [ "$ROOT_TYPE" = "APatch" ]; then
  if [ -f "/data/adb/.overlay_enable" ]; then
    APATCH_MODE="overlayfs"
    APATCH_OVERLAYFS=true
  elif [ -f "/data/adb/.litemode_enable" ]; then
    APATCH_MODE="litemode"
    APATCH_LITEMODE=true
  else
    APATCH_MODE="magic_mount"
  fi
  if [ -x "/data/adb/ap/bin/busybox" ]; then
    APATCH_BUSYBOX="/data/adb/ap/bin/busybox"
  fi
fi

# ========================================
# EARLY LOG_BOOT STUB
# ========================================
# log_boot() is fully defined later (after logging setup). The stub below
# writes to a temp buffer file so early messages are NOT silently swallowed.
# BUG2 FIX: Original stub was `log_boot() { :; }` — a pure no-op. Any calls
# between here and the real definition (line ~362) including skip_mount
# removal and metamodule detection are silently lost, making the log
# show no entry for those operations. The fixed stub writes to a temp
# buffer that the real log_boot() drains and re-logs on first call.
_EARLY_LOG_BUFFER="/data/local/tmp/adreno_early_log_buffer.$$"
log_boot() {
  # Write to temp buffer until real log_boot is defined and drains it.
  mkdir -p /data/local/tmp 2>/dev/null
  printf '[EARLY] %s\n' "$1" >> "$_EARLY_LOG_BUFFER" 2>/dev/null || true
}

# ========================================
# KERNELSU: METAMODULE CHECK + SKIP_MOUNT
# ========================================

if [ "$ROOT_TYPE" = "KernelSU" ]; then
  detect_metamodule

  if [ "$METAMODULE_ACTIVE" = "true" ]; then
    # Metamodule is now active — remove any stale skip_mount that may have been
    # created on a previous boot when metamodule was absent.
    # Without this removal the module stays permanently broken even after the
    # user installs a metamodule, because the skip_mount check below fires first.
    if [ -f "$MODDIR/skip_mount" ]; then
      rm -f "$MODDIR/skip_mount" 2>/dev/null
      log_boot "[OK] Removed stale skip_mount — metamodule ($METAMODULE_NAME) is now active"
    fi
  else
    touch "$MODDIR/skip_mount" 2>/dev/null
    mkdir -p /data/local/tmp 2>/dev/null
    {
      echo "========================================"
      echo "CRITICAL: KernelSU without metamodule"
      echo "Time: $(date 2>/dev/null)"
      echo "========================================"
      echo "No metamodule detected for KernelSU"
      echo "Auto-created skip_mount to prevent mounting failures"
      echo "Install MetaMagicMount, Meta-OverlayFS, or Meta-Hybrid to use this module"
      echo "Module will NOT work without a metamodule!"
      echo "========================================"
    } > /data/local/tmp/adreno_no_metamodule.log 2>/dev/null
  fi
fi

# ========================================
# CHECK SKIP_MOUNT MARKER
# ========================================

if [ -f "$MODDIR/skip_mount" ]; then
  LOG_FILE="/data/local/tmp/adreno_skip_mount.log"
  {
    echo "========================================"
    echo "Adreno GPU Driver - skip_mount detected"
    echo "Time: $(date 2>/dev/null || echo 'unknown')"
    echo "========================================"
    echo "skip_mount file found - skipping all mounting operations"
    echo "Module scripts will still run, but system directory won't be mounted"
    if [ "$ROOT_TYPE" = "KernelSU" ]; then
      echo ""
      echo "Reason: KernelSU without metamodule detected"
      echo "Solution: Install MetaMagicMount or Meta-OverlayFS"
    fi
    echo "========================================"
  } > "$LOG_FILE" 2>/dev/null || true

  # CRITICAL: Reset boot attempt counter so the module does NOT auto-disable
  # itself after 4 consecutive skip_mount early-exits. skip_mount is an
  # intentional no-op state (waiting for metamodule), not a failure state.
  echo 0 > "$BOOT_ATTEMPTS_FILE" 2>/dev/null || true

  exit 0
fi

# ========================================
# AUTOMATIC ROLLBACK MECHANISM
# ========================================

MAX_BOOT_ATTEMPTS=3

{ IFS= read -r BOOT_ATTEMPTS; } < "$BOOT_ATTEMPTS_FILE" 2>/dev/null
BOOT_ATTEMPTS="${BOOT_ATTEMPTS:-0}"
BOOT_ATTEMPTS=$((BOOT_ATTEMPTS + 1))

echo "$BOOT_ATTEMPTS" > "$BOOT_ATTEMPTS_FILE" 2>/dev/null

if [ "$BOOT_ATTEMPTS" -gt "$MAX_BOOT_ATTEMPTS" ]; then
  touch "$MODDIR/disable" 2>/dev/null
  {
    echo "========================================"
    echo "CRITICAL: Module Auto-Disabled"
    echo "Time: $(date 2>/dev/null)"
    echo "========================================"
    echo "Module disabled after $BOOT_ATTEMPTS failed boot attempts"
    echo ""
    echo "To re-enable:"
    echo "1. Boot system (module is now disabled)"
    echo "2. Remove $MODDIR/disable"
    echo "3. Remove $BOOT_ATTEMPTS_FILE"
    echo "4. Reboot"
    echo "========================================"
  } > "/data/local/tmp/adreno_auto_disabled.log" 2>/dev/null
  echo 0 > "$BOOT_ATTEMPTS_FILE" 2>/dev/null
  exit 0
fi

# ========================================
# CONFIGURATION LOADING
# ========================================

VERBOSE="n"
ARM64_OPT="n"
QGL="n"
PLT="n"
RENDER_MODE="normal"
GAME_EXCLUSION_DAEMON="n"
FORCE_SKIAVKTHREADED_BACKEND="n"

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
[ "$GAME_EXCLUSION_DAEMON" != "y" ] && GAME_EXCLUSION_DAEMON="n"
# BUG A FIX: Normalize RENDER_MODE to lowercase so every case statement matches
# regardless of how the user typed it (SkiaVK, SKIAVK, SkiaGL, etc.).
# service.sh already does this. post-fs-data.sh was missing it — any uppercase
# variant silently fell through all case branches and renderer was never set.
RENDER_MODE=$(printf '%s' "$RENDER_MODE" | tr '[:upper:]' '[:lower:]')
# Legacy: skiavkthreaded/skiaglthreaded were removed as standalone RENDER_MODE values.
# common.sh normalizes them on load, but guard here defensively.
[ "$RENDER_MODE" = "skiavkthreaded" ] && RENDER_MODE="skiavk"
[ "$RENDER_MODE" = "skiaglthreaded" ] && RENDER_MODE="skiagl"
[ "$FORCE_SKIAVKTHREADED_BACKEND" != "y" ] && FORCE_SKIAVKTHREADED_BACKEND="n"

# ========================================
# LOGGING SETUP
# ========================================

if [ "$VERBOSE" = "y" ]; then
  LOG_BASE_DIR="/sdcard/Adreno_Driver"
  _LOG_TS=$(date +%Y%m%d_%H%M%S 2>/dev/null || echo 'unknown')
  BOOT_LOG="${LOG_BASE_DIR}/Booted/boot_${_LOG_TS}.log"
  BOOTLOOP_LOG="${LOG_BASE_DIR}/Bootloop/bootloop_${_LOG_TS}.log"
  BOOT_STATE_FILE="/data/local/tmp/adreno_boot_state"

  LOG_DIR_CREATED=false
  for base_try in "/sdcard/Adreno_Driver" "/data/local/tmp/Adreno_Driver" "/cache/Adreno_Driver"; do
    if mkdir -p "${base_try}/Booted" "${base_try}/Bootloop" 2>/dev/null; then
      if touch "${base_try}/Booted/.test" 2>/dev/null && rm "${base_try}/Booted/.test" 2>/dev/null; then
        LOG_BASE_DIR="$base_try"
        BOOT_LOG="${LOG_BASE_DIR}/Booted/boot_${_LOG_TS}.log"
        BOOTLOOP_LOG="${LOG_BASE_DIR}/Bootloop/bootloop_${_LOG_TS}.log"
        LOG_DIR_CREATED=true
        break
      fi
    fi
  done
  unset _LOG_TS

  if [ "$LOG_DIR_CREATED" = "false" ]; then
    LOG_BASE_DIR="/tmp/Adreno_Driver"
    mkdir -p "${LOG_BASE_DIR}/Booted" "${LOG_BASE_DIR}/Bootloop" 2>/dev/null || true
    { read _TS_FB _; } < /proc/uptime 2>/dev/null || _TS_FB='unknown'
    _TS_FB="${_TS_FB%%.*}"
    BOOT_LOG="${LOG_BASE_DIR}/Booted/boot_${_TS_FB}.log"
    BOOTLOOP_LOG="${LOG_BASE_DIR}/Bootloop/bootloop_${_TS_FB}.log"
    unset _TS_FB
  fi
else
  CURRENT_LOG="/dev/null"
  LOG_BASE_DIR="/dev"
fi

# ========================================
# BOOTLOOP DETECTION
# ========================================

IN_BOOTLOOP=false

if [ "$VERBOSE" = "y" ]; then
  detect_bootloop() {
    local _raw; read _raw _ < /proc/uptime 2>/dev/null || _raw='0'
    local current_time="${_raw%%.*}"
    local boot_count=0
    local last_boot_time=0
    local boot_uptime="$current_time"

    if [ -f "$BOOT_STATE_FILE" ]; then
      while IFS='=' read -r _bk _bv; do
        case "$_bk" in
          BOOT_COUNT) boot_count="${_bv:-0}" ;;
          LAST_BOOT)  last_boot_time="${_bv:-0}" ;;
        esac
      done < "$BOOT_STATE_FILE"
    fi

    BOOTLOOP_THRESHOLD=60

    if [ $((current_time - last_boot_time)) -lt $BOOTLOOP_THRESHOLD ]; then
      boot_count=$((boot_count + 1))
    else
      boot_count=1
    fi

    if cat > "$BOOT_STATE_FILE" <<STATE_EOF
BOOT_COUNT=$boot_count
LAST_BOOT=$current_time
UPTIME=$boot_uptime
THRESHOLD=$BOOTLOOP_THRESHOLD
STATE_EOF
    then
      : # State saved
    else
      BOOT_STATE_FILE="/tmp/adreno_boot_state"
      cat > "$BOOT_STATE_FILE" <<STATE_EOF
BOOT_COUNT=$boot_count
LAST_BOOT=$current_time
UPTIME=$boot_uptime
THRESHOLD=$BOOTLOOP_THRESHOLD
STATE_EOF
    fi

    if [ "$boot_uptime" -lt 60 ] && [ "$boot_count" -gt 2 ]; then
      return 0
    fi
    if [ "$boot_count" -gt 4 ]; then
      return 0
    else
      return 1
    fi
  }

  if detect_bootloop; then
    CURRENT_LOG="$BOOTLOOP_LOG"
    IN_BOOTLOOP=true
  else
    CURRENT_LOG="$BOOT_LOG"
    IN_BOOTLOOP=false
  fi

  if ! {
    echo "========================================"
    echo "Adreno GPU Driver - Post-FS-Data Boot Log"
    echo "========================================"
    echo "Boot time: $(date)"
    echo "Bootloop detected: $IN_BOOTLOOP"
    echo "Root type: $ROOT_TYPE"
    echo "Log file: $CURRENT_LOG"
    echo "========================================"
    echo ""
  } > "$CURRENT_LOG" 2>/dev/null; then
    CURRENT_LOG="/dev/kmsg"
  fi
else
  CURRENT_LOG="/dev/null"
  BOOT_STATE_FILE="/dev/null"
fi

if [ "$VERBOSE" = "y" ]; then
  log_boot() {
    local _t; read _t _ < /proc/uptime 2>/dev/null || _t='?'
    echo "[ADRENO][${_t}s] $1" >> "$CURRENT_LOG" 2>/dev/null || \
    echo "[ADRENO] $1" > /dev/kmsg 2>/dev/null || true
  }
else
  log_boot() { :; }
fi

# BUG2 FIX: Drain the early log buffer now that the real log_boot() is live.
if [ -f "${_EARLY_LOG_BUFFER:-}" ]; then
  while IFS= read -r _buf_line; do
    log_boot "$_buf_line"
  done < "$_EARLY_LOG_BUFFER" 2>/dev/null
  rm -f "$_EARLY_LOG_BUFFER" 2>/dev/null
fi
unset _EARLY_LOG_BUFFER
log_boot "MODDIR: $MODDIR"
log_boot "Bootloop status: $IN_BOOTLOOP"
log_boot "Root type: $ROOT_TYPE"
if [ "$ROOT_TYPE" = "APatch" ] && [ -n "$APATCH_MODE" ]; then
  log_boot "APatch mode: $APATCH_MODE"
fi

# ========================================
# COLLECT PREVIOUS BOOT LOGS
# ========================================

if [ "$VERBOSE" = "y" ]; then
  log_boot "========================================"
  log_boot "COLLECTING PREVIOUS BOOT DIAGNOSTICS"
  log_boot "========================================"

  { read _bl_raw _; } < /proc/uptime 2>/dev/null || _bl_raw='0'
  BL_TIMESTAMP="${_bl_raw%%.*}"

  if [ -f /proc/last_kmsg ]; then
    log_boot "[PREV BOOT] Collecting /proc/last_kmsg..."
    cp /proc/last_kmsg "${LOG_BASE_DIR}/Bootloop/last_kmsg_${BL_TIMESTAMP}.log" 2>/dev/null && \
      log_boot "[PREV BOOT] [OK] last_kmsg saved" || \
      log_boot "[PREV BOOT] [X] Failed to collect last_kmsg"
  else
    log_boot "[PREV BOOT] [!] /proc/last_kmsg not available"
  fi

  if [ -d /sys/fs/pstore ]; then
    log_boot "[PREV BOOT] Collecting pstore crash dumps..."
    pstore_count=0
    for _pf in /sys/fs/pstore/*; do [ -e "$_pf" ] && pstore_count=$((pstore_count+1)); done

    if [ "$pstore_count" -gt 0 ]; then
      mkdir -p "${LOG_BASE_DIR}/Bootloop/pstore_${BL_TIMESTAMP}" 2>/dev/null
      cp -r /sys/fs/pstore/* "${LOG_BASE_DIR}/Bootloop/pstore_${BL_TIMESTAMP}/" 2>/dev/null && \
        log_boot "[PREV BOOT] [OK] pstore collected ($pstore_count files)" || \
        log_boot "[PREV BOOT] [X] Failed to collect pstore"
    else
      log_boot "[PREV BOOT] [i] pstore directory empty"
    fi
  else
    log_boot "[PREV BOOT] [!] /sys/fs/pstore not available"
  fi

  log_boot "[CURRENT BOOT] Collecting current dmesg..."
  dmesg > "${LOG_BASE_DIR}/Bootloop/dmesg_current_${BL_TIMESTAMP}.log" 2>&1 && \
    log_boot "[CURRENT BOOT] [OK] dmesg saved" || \
    log_boot "[CURRENT BOOT] [X] Failed to collect dmesg"

  log_boot "[CURRENT BOOT] Collecting current logcat..."
  logcat -d -t 5000 > "${LOG_BASE_DIR}/Bootloop/logcat_current_${BL_TIMESTAMP}.txt" 2>&1 && \
    log_boot "[CURRENT BOOT] [OK] logcat saved" || \
    log_boot "[CURRENT BOOT] [X] Failed to collect logcat"

  log_boot "========================================"
  log_boot "PREVIOUS BOOT LOG COLLECTION COMPLETE"
  log_boot "========================================"
fi

# ========================================
# SUSFS DETECTION
# ========================================

log_boot "Checking SUSFS (root hiding)..."

SUSFS_ACTIVE=false
if [ -f "/sys/kernel/susfs/version" ]; then
  SUSFS_VER="unknown"
  { IFS= read -r SUSFS_VER; } < /sys/kernel/susfs/version 2>/dev/null
  SUSFS_ACTIVE=true
  log_boot "SUSFS: Active (version $SUSFS_VER)"
elif [ -d "/data/adb/modules/susfs4ksu" ] && [ ! -f "/data/adb/modules/susfs4ksu/disable" ]; then
  SUSFS_ACTIVE=true
  log_boot "SUSFS: Active (module detected)"
elif [ -f "/data/adb/ksu/bin/ksu_susfs" ]; then
  SUSFS_ACTIVE=true
  log_boot "SUSFS: Active (binary detected)"
else
  log_boot "SUSFS: Not detected"
fi

# ========================================
# OEM ROM DETECTION
# ========================================

log_boot "Detecting OEM ROM..."

HYPEROS_ROM=false
ONEUI_ROM=false
COLOROS_ROM=false
REALME_ROM=false
FUNTOUCH_ROM=false
OEM_TYPE=""

MANUFACTURER="$(getprop ro.product.manufacturer 2>/dev/null)"

MIUI_VERSION="$(getprop ro.miui.ui.version.name 2>/dev/null)"
MIUI_CODE="$(getprop ro.miui.ui.version.code 2>/dev/null)"
HYPEROS_VERSION="$(getprop ro.mi.os.version.incremental 2>/dev/null)"

if [ -n "$HYPEROS_VERSION" ] || [ "$MIUI_VERSION" = "V140" ] || [ "${MIUI_CODE:-0}" -ge 14 ] 2>/dev/null; then
  HYPEROS_ROM=true
  OEM_TYPE="HyperOS"
  log_boot "OEM ROM: HyperOS detected"
elif [ -n "$MIUI_VERSION" ] || [ -f "/system/etc/miui.apklist" ] || [ -d "/system/priv-app/MiuiSystemUI" ]; then
  HYPEROS_ROM=true
  OEM_TYPE="MIUI"
  log_boot "OEM ROM: MIUI detected"
fi

if [ -f "/system/etc/floating_feature.xml" ] || \
   [ "$MANUFACTURER" = "samsung" ] || [ "$MANUFACTURER" = "Samsung" ]; then
  ONEUI_ROM=true
  OEM_TYPE="OneUI"
  log_boot "OEM ROM: Samsung OneUI detected"
elif ONEUI_VERSION="$(getprop ro.build.version.oneui 2>/dev/null)" && [ -n "$ONEUI_VERSION" ]; then
  ONEUI_ROM=true
  OEM_TYPE="OneUI"
  log_boot "OEM ROM: Samsung OneUI detected"
fi

if [ "$MANUFACTURER" = "OPPO" ] || [ "$MANUFACTURER" = "oppo" ] || [ -d "/system/priv-app/OPPOColorOS" ]; then
  COLOROS_ROM=true
  OEM_TYPE="ColorOS"
  log_boot "OEM ROM: ColorOS detected"
elif COLOROS_VERSION="$(getprop ro.build.version.opporom 2>/dev/null)" && [ -n "$COLOROS_VERSION" ]; then
  COLOROS_ROM=true
  OEM_TYPE="ColorOS"
  log_boot "OEM ROM: ColorOS detected"
fi

if [ "$MANUFACTURER" = "realme" ] || [ "$MANUFACTURER" = "Realme" ] || [ -d "/system/priv-app/RealmeSystemUI" ]; then
  REALME_ROM=true
  OEM_TYPE="RealmeUI"
  log_boot "OEM ROM: RealmeUI detected"
elif REALME_VERSION="$(getprop ro.build.version.realmeui 2>/dev/null)" && [ -n "$REALME_VERSION" ]; then
  REALME_ROM=true
  OEM_TYPE="RealmeUI"
  log_boot "OEM ROM: RealmeUI detected"
fi

if [ "$MANUFACTURER" = "vivo" ] || [ "$MANUFACTURER" = "Vivo" ] || [ -d "/system/priv-app/VivoSystemUI" ]; then
  FUNTOUCH_ROM=true
  OEM_TYPE="FuntouchOS"
  log_boot "OEM ROM: FuntouchOS detected"
elif FUNTOUCH_VERSION="$(getprop ro.vivo.os.version 2>/dev/null)" && [ -n "$FUNTOUCH_VERSION" ]; then
  FUNTOUCH_ROM=true
  OEM_TYPE="FuntouchOS"
  log_boot "OEM ROM: FuntouchOS detected"
fi

if [ -z "$OEM_TYPE" ]; then
  OEM_TYPE="AOSP/Custom"
  log_boot "OEM ROM: AOSP or Custom ROM"
fi

# ========================================
# LOAD CONFIGURATION (report only — already loaded above)
# ========================================

log_boot "Loading configuration..."

if [ -f "$CONFIG_FILE" ]; then
  log_boot "Config loaded from SD Card"
elif [ -f "$ALT_CONFIG" ]; then
  log_boot "Config loaded from module"
else
  log_boot "No config found, using defaults"
fi

log_boot "Configuration: PLT=$PLT, QGL=$QGL, ARM64_OPT=$ARM64_OPT, RENDER=$RENDER_MODE, GAME_EXCLUSION_DAEMON=$GAME_EXCLUSION_DAEMON"

# ========================================
# SYNC MODULE STATE TO CURRENT CONFIG
# ========================================

log_boot "========================================"
log_boot "SYNCING MODULE STATE TO CONFIG"
log_boot "========================================"

QGL_OWNER_MARKER="/data/vendor/gpu/.adreno_qgl_owner"
if [ "$QGL" = "n" ]; then
  if [ -f "$QGL_OWNER_MARKER" ]; then
    rm -f "/data/vendor/gpu/qgl_config.txt" 2>/dev/null && \
      log_boot "[OK] QGL disabled → removed module-owned /data/vendor/gpu/qgl_config.txt" || \
      log_boot "[!] QGL disabled but failed to remove qgl_config.txt"
    rm -f "$QGL_OWNER_MARKER" 2>/dev/null && log_boot "[OK] QGL owner marker removed" || true
  elif [ -f "/data/vendor/gpu/qgl_config.txt" ]; then
    log_boot "QGL disabled → qgl_config.txt present but owned by another manager — leaving untouched"
  else
    log_boot "QGL disabled → qgl_config.txt not present (nothing to remove)"
  fi
else
  log_boot "QGL enabled → config will be installed in QGL section below"
fi

PLT_DIR="$MODDIR/system/vendor/etc"
PATCH_LINE="gpu++.so"

if [ "$PLT" = "n" ]; then
  REMOVED_PLT=0
  for plt_file in "$PLT_DIR"/public.libraries*.txt; do
    [ -f "$plt_file" ] || continue
    rm -f "$plt_file" 2>/dev/null && REMOVED_PLT=$((REMOVED_PLT + 1))
    log_boot "[OK] PLT disabled → removed ${plt_file##*/} from module overlay"
  done
  [ $REMOVED_PLT -eq 0 ] && log_boot "PLT disabled → no patched files found in module (already clean)"
else
  PATCHED_PLT=0
  for vendor_etc in "/vendor/etc" "/system/vendor/etc"; do
    [ -d "$vendor_etc" ] || continue
    for src_file in "$vendor_etc"/public.libraries*.txt; do
      [ -f "$src_file" ] || continue
      DEST="$PLT_DIR/${src_file##*/}"
      mkdir -p "$PLT_DIR" 2>/dev/null
      if [ ! -f "$DEST" ]; then
        cp -f "$src_file" "$DEST" 2>/dev/null && \
          log_boot "PLT: copied ${src_file##*/} into module" || \
          log_boot "[!] PLT: failed to copy ${src_file##*/}"
      fi
      if [ -f "$DEST" ]; then
        [ -n "$(tail -c1 "$DEST" 2>/dev/null)" ] && echo >> "$DEST"
        if ! grep -qF "$PATCH_LINE" "$DEST" 2>/dev/null; then
          echo "$PATCH_LINE" >> "$DEST" 2>/dev/null && \
            PATCHED_PLT=$((PATCHED_PLT + 1)) && \
            log_boot "[OK] PLT: patched ${src_file##*/} with $PATCH_LINE"
        fi
      fi
    done
  done
  [ $PATCHED_PLT -gt 0 ] && \
    log_boot "[OK] PLT enabled → $PATCHED_PLT file(s) patched" || \
    log_boot "PLT enabled → files already patched (no changes needed)"
fi

if [ "$ARM64_OPT" = "y" ]; then
  REMOVED_32=0
  for lib32 in "$MODDIR/system/vendor/lib" "$MODDIR/system/lib"; do
    if [ -d "$lib32" ]; then
      rm -rf "$lib32" 2>/dev/null && \
        REMOVED_32=$((REMOVED_32 + 1)) && \
        log_boot "[OK] ARM64_OPT enabled → removed 32-bit dir: $lib32"
    fi
  done
  [ $REMOVED_32 -eq 0 ] && log_boot "ARM64_OPT enabled → no 32-bit dirs present (already clean)"
else
  HAS_32BIT=false
  [ -d "$MODDIR/system/vendor/lib" ] && HAS_32BIT=true
  [ -d "$MODDIR/system/lib" ]  && HAS_32BIT=true
  if [ "$HAS_32BIT" = "true" ]; then
    log_boot "ARM64_OPT disabled → 32-bit libs present in module (OK)"
  else
    log_boot "[!] ARM64_OPT disabled but 32-bit lib dirs are MISSING from module"
    log_boot "    Reinstall the module to restore 32-bit libraries"
  fi
fi

log_boot "VERBOSE: $VERBOSE (read fresh from config each boot — no sync needed)"

log_boot "========================================"
log_boot "MODULE STATE SYNC COMPLETE"
# SELinux policy injection moved BEFORE render-mode activation so that GPU
# device access rules are live before any resetprop activates skiavk/skiagl.
# ── SELinux injection now runs here (moved from end of script) ───────────
log_boot "Log cleanup completed"

# ========================================
# DYNAMIC SEPOLICY INJECTION (SYNCHRONOUS)
# ========================================

log_boot "========================================"
log_boot "Starting Dynamic SELinux Policy Injection"
log_boot "========================================"

SEPOLICY_TOOL=""
TOOL_FOUND=false

log_boot "Detecting SELinux policy injection tool for $ROOT_TYPE..."

# Fast path: try known binary locations directly first.
# magiskpolicy is available from the very start of post-fs-data on Magisk
# (placed in PATH by Magisk's own init) and on KernelSU via ksud internals.
# Polling 30× with sleep 1 adds up to 30s of synchronous boot delay.
# Instead: check known paths immediately, then retry briefly (max ~2s).

_find_magiskpolicy() {
  for _mp in \
      "$(command -v magiskpolicy 2>/dev/null)" \
      "/sbin/magiskpolicy" \
      "/data/adb/magisk/magiskpolicy" \
      "/data/adb/ksu/bin/magiskpolicy" \
      "/system/bin/magiskpolicy" \
      "/system/xbin/magiskpolicy"; do
    [ -z "$_mp" ] && continue
    [ -f "$_mp" ] && [ -x "$_mp" ] || continue
    if "$_mp" --help >/dev/null 2>&1; then
      SEPOLICY_TOOL="$_mp"
      TOOL_FOUND=true
      return 0
    fi
  done
  return 1
}

# Try immediately
_find_magiskpolicy

# If not found yet, retry 3× with 1s sleep (3s max wait, not 30s)
if [ "$TOOL_FOUND" = "false" ]; then
  _retry=0
  while [ $_retry -lt 3 ] && [ "$TOOL_FOUND" = "false" ]; do
    sleep 1
    _find_magiskpolicy
    _retry=$((_retry + 1))
  done
  unset _retry
fi
unset -f _find_magiskpolicy 2>/dev/null || true

if [ "$TOOL_FOUND" = "true" ]; then
  log_boot "[OK] SEPolicy tool found: $SEPOLICY_TOOL ($ROOT_TYPE)"
  log_boot "System ready, beginning policy injection..."

  inject() {
    "$SEPOLICY_TOOL" --live "$1" >/dev/null 2>&1
  }

  log_boot "Testing policy injection capability..."
  TOOL_VERIFIED=false
  if inject "allow domain domain process signal"; then
    TOOL_VERIFIED=true
    log_boot "[OK] Policy injection test successful - tool functional"
  else
    log_boot "[!] WARNING: Policy injection test failed - rules may not apply"
  fi

  RULES_SUCCESS=0
  RULES_FAILED=0
  CRITICAL_RULES_FAILED=0

  _RULES_TMP="/dev/tmp/adreno_sepolicy_$$"
  mkdir -p /dev/tmp 2>/dev/null || true

  cat > "$_RULES_TMP" << 'SELINUX_RULES_BATCH'
allow hal_graphics_composer_default gpu_device chr_file { read write open ioctl getattr }
allow hal_graphics_composer_default same_process_hal_file file { read open getattr execute map }
allow hal_graphics_composer_default vendor_file file { read open getattr execute map }
allow hal_graphics_allocator_default gpu_device chr_file { read write open ioctl getattr }
allow hal_graphics_allocator_default same_process_hal_file file { read open getattr execute map }
allow hal_graphics_mapper_default gpu_device chr_file { read write open ioctl getattr }
allow hal_graphics_mapper_default same_process_hal_file file { read open getattr execute map }
allow surfaceflinger gpu_device chr_file { read write open ioctl getattr }
allow surfaceflinger same_process_hal_file file { read open getattr execute map }
allow surfaceflinger vendor_file file { read open getattr execute map }
allow surfaceflinger vendor_data_file dir { read search getattr }
allow surfaceflinger vendor_data_file file { read open getattr }
allow system_server gpu_device chr_file { read write open ioctl getattr }
allow system_server same_process_hal_file file { read open getattr execute map }
allow system_server vendor_file file { read open getattr execute map }
allow system_server vendor_data_file dir { read search getattr write add_name create setattr }
allow system_server vendor_data_file file { read open getattr create write setattr }
allow zygote gpu_device chr_file { read write open ioctl getattr }
allow zygote same_process_hal_file file { read open getattr execute map }
allow zygote vendor_file file { read open getattr execute map }
allow appdomain gpu_device chr_file { read write open ioctl getattr }
allow untrusted_app gpu_device chr_file { read write open ioctl getattr }
allow platform_app gpu_device chr_file { read write open ioctl getattr }
allow priv_app gpu_device chr_file { read write open ioctl getattr }
allow isolated_app gpu_device chr_file { read write open ioctl getattr }
allow init same_process_hal_file file { read open getattr execute map }
allow init vendor_file file { read open getattr execute execute_no_trans }
allow init gpu_device chr_file { read write open ioctl getattr setattr }
allow init vendor_data_file dir { create read write open add_name remove_name search setattr getattr }
allow init vendor_data_file file { create read write open getattr setattr unlink }
allow hal_graphics_composer_default self capability dac_read_search
allow hal_graphics_allocator_default self capability dac_read_search
allow hal_graphics_mapper_default self capability dac_read_search
allow surfaceflinger self capability dac_read_search
allow system_server self capability dac_read_search
allow vendor_init gpu_device chr_file { read write open ioctl getattr setattr }
allow vendor_init vendor_data_file dir { create read write search add_name setattr }
allow vendor_init vendor_data_file file { create read write setattr }
allow vendor_init vendor_firmware_file dir { search read getattr }
allow vendor_init vendor_firmware_file file { read open getattr }
SELINUX_RULES_BATCH
# NOTE: The following 4 rules were INTENTIONALLY REMOVED from this batch:
#   allow domain vendor_firmware_file dir { search getattr read }
#   allow domain vendor_firmware_file file { read open getattr map }
#   allow domain firmware_file file { read open getattr }
#   allow vendor_init self capability { chown fowner }
#
# Root cause of OEM bootloops: when ANY rule in the --apply batch conflicts with
# an OEM neverallow rule, magiskpolicy rejects the ENTIRE batch (0 rules applied).
#
#   Samsung OneUI neverallow:
#     neverallow { untrusted_app isolated_app } vendor_firmware_file:file read
#   'domain' attribute is a superset containing untrusted_app + isolated_app.
#   The batch rule grants read to the entire domain (including untrusted_app) →
#   neverallow violation → entire 40-rule batch rejected → no GPU SELinux rules
#   applied → GPU HAL cannot access driver libs → SurfaceFlinger crash → bootloop.
#
#   MIUI/HyperOS neverallow:
#     neverallow domain firmware_file:file { read open }
#   Direct neverallow on 'domain' attribute. Same cascade failure.
#
#   Samsung Knox neverallow:
#     neverallow vendor_init self:capability { chown fowner }
#   Knox security policy explicitly blocks vendor_init from changing file ownership.
#
# Fix: these 4 rules are moved to individual silent-fail injection below.
# They fail silently on strict OEM ROMs — expected and non-critical.
# The 40-rule batch now succeeds on ALL OEM ROMs.

  log_boot "========================================"
  log_boot "Injecting SELinux rules (batch mode)"
  log_boot "========================================"

  if [ -f "$_RULES_TMP" ] && "$SEPOLICY_TOOL" --live --apply "$_RULES_TMP" >/dev/null 2>&1; then
    RULES_SUCCESS=40
    log_boot "[OK] BATCH injection: 40 core rules applied in 1 magiskpolicy spawn"
  else
    log_boot "[!] Batch --apply failed — falling back to individual injection"
    rm -f "$_RULES_TMP" 2>/dev/null

    if inject "allow hal_graphics_composer_default gpu_device chr_file { read write open ioctl getattr }"; then
      RULES_SUCCESS=$((RULES_SUCCESS + 1)); log_boot "  [OK] Graphics composer -> GPU device"
    else
      RULES_FAILED=$((RULES_FAILED + 1)); CRITICAL_RULES_FAILED=$((CRITICAL_RULES_FAILED + 1))
      log_boot "  [X] CRITICAL: Graphics composer -> GPU device FAILED"
    fi
    if inject "allow hal_graphics_composer_default same_process_hal_file file { read open getattr execute map }"; then
      RULES_SUCCESS=$((RULES_SUCCESS + 1)); log_boot "  [OK] Graphics composer -> HAL libraries"
    else
      RULES_FAILED=$((RULES_FAILED + 1)); CRITICAL_RULES_FAILED=$((CRITICAL_RULES_FAILED + 1))
      log_boot "  [X] CRITICAL: Graphics composer -> HAL libraries FAILED"
    fi
    inject "allow hal_graphics_composer_default vendor_file file { read open getattr execute map }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))

    if inject "allow hal_graphics_allocator_default gpu_device chr_file { read write open ioctl getattr }"; then
      RULES_SUCCESS=$((RULES_SUCCESS + 1)); log_boot "  [OK] Graphics allocator -> GPU device"
    else
      RULES_FAILED=$((RULES_FAILED + 1)); CRITICAL_RULES_FAILED=$((CRITICAL_RULES_FAILED + 1))
      log_boot "  [X] CRITICAL: Graphics allocator -> GPU device FAILED"
    fi
    inject "allow hal_graphics_allocator_default same_process_hal_file file { read open getattr execute map }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))

    if inject "allow hal_graphics_mapper_default gpu_device chr_file { read write open ioctl getattr }"; then
      RULES_SUCCESS=$((RULES_SUCCESS + 1))
    else
      inject "allow hal_graphics_mapper gpu_device chr_file { read write open ioctl getattr }" 2>/dev/null && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))
    fi
    if inject "allow hal_graphics_mapper_default same_process_hal_file file { read open getattr execute map }"; then
      RULES_SUCCESS=$((RULES_SUCCESS + 1))
    else
      inject "allow hal_graphics_mapper same_process_hal_file file { read open getattr execute map }" 2>/dev/null && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))
    fi

    if inject "allow surfaceflinger gpu_device chr_file { read write open ioctl getattr }"; then
      RULES_SUCCESS=$((RULES_SUCCESS + 1)); log_boot "  [OK] SurfaceFlinger -> GPU device"
    else
      RULES_FAILED=$((RULES_FAILED + 1)); CRITICAL_RULES_FAILED=$((CRITICAL_RULES_FAILED + 1))
      log_boot "  [X] CRITICAL: SurfaceFlinger -> GPU device FAILED"
    fi
    inject "allow surfaceflinger same_process_hal_file file { read open getattr execute map }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))
    inject "allow surfaceflinger vendor_file file { read open getattr execute map }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))
    inject "allow surfaceflinger vendor_data_file dir { read search getattr }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))
    inject "allow surfaceflinger vendor_data_file file { read open getattr }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))

    inject "allow system_server gpu_device chr_file { read write open ioctl getattr }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))
    inject "allow system_server same_process_hal_file file { read open getattr execute map }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))
    inject "allow system_server vendor_file file { read open getattr execute map }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))
    inject "allow system_server vendor_data_file dir { read search getattr write add_name create setattr }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))
    inject "allow system_server vendor_data_file file { read open getattr create write setattr }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))

    inject "allow zygote gpu_device chr_file { read write open ioctl getattr }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))
    inject "allow zygote same_process_hal_file file { read open getattr execute map }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))
    inject "allow zygote vendor_file file { read open getattr execute map }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))

    inject "allow appdomain gpu_device chr_file { read write open ioctl getattr }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))
    inject "allow untrusted_app gpu_device chr_file { read write open ioctl getattr }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))
    inject "allow platform_app gpu_device chr_file { read write open ioctl getattr }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))
    inject "allow priv_app gpu_device chr_file { read write open ioctl getattr }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))
    inject "allow isolated_app gpu_device chr_file { read write open ioctl getattr }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))

    inject "allow domain system_lib_file file { read open getattr execute map }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))
    inject "allow domain vendor_firmware_file dir { search getattr read }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))
    inject "allow domain vendor_firmware_file file { read open getattr map }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))
    inject "allow domain firmware_file file { read open getattr }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))

    inject "allow init same_process_hal_file file { read open getattr execute map }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))
    inject "allow init vendor_file file { read open getattr execute execute_no_trans }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))
    inject "allow init gpu_device chr_file { read write open ioctl getattr setattr }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))
    inject "allow init vendor_data_file dir { create read write open add_name remove_name search setattr getattr }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))
    inject "allow init vendor_data_file file { create read write open getattr setattr unlink }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))
    # init filesystem mount rules: silent-fail — these trigger audit storms on OEM ROMs
    # (MIUI/HyperOS/OneUI neverallow policies reject filesystem mounts from init domain).
    # Injected opportunistically; failure is expected and non-critical.
    "$SEPOLICY_TOOL" --live "allow init labeledfs filesystem { mount unmount }" >/dev/null 2>&1 && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || true
    "$SEPOLICY_TOOL" --live "allow init tmpfs filesystem mount" >/dev/null 2>&1 && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || true
    "$SEPOLICY_TOOL" --live "allow init rootfs filesystem mount" >/dev/null 2>&1 && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || true
    "$SEPOLICY_TOOL" --live "allow init overlayfs filesystem mount" >/dev/null 2>&1 && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || true

    inject "allow domain gpu_device dir { search read }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))
    inject "allow domain vendor_data_file dir { search read getattr }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))
    inject "allow domain vendor_data_file file { read open getattr }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))
    # dac_read_search: targeted grants only — "allow domain self capability dac_read_search"
    # violates AOSP neverallow ~dac_override_allowed self:capability dac_read_search
    # (domain.te). On OEM ROMs with strict policy validation daemons this causes a
    # policy reload failure at boot → bootloop. Grant only to the GPU-relevant domains
    # that genuinely need it (same set as dac_override_allowed for GPU domains).
    "$SEPOLICY_TOOL" --live "allow hal_graphics_composer_default self capability dac_read_search" >/dev/null 2>&1 && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || true
    "$SEPOLICY_TOOL" --live "allow hal_graphics_allocator_default self capability dac_read_search" >/dev/null 2>&1 && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || true
    "$SEPOLICY_TOOL" --live "allow hal_graphics_mapper_default self capability dac_read_search" >/dev/null 2>&1 && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || true
    "$SEPOLICY_TOOL" --live "allow surfaceflinger self capability dac_read_search" >/dev/null 2>&1 && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || true
    "$SEPOLICY_TOOL" --live "allow system_server self capability dac_read_search" >/dev/null 2>&1 && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || true

    inject "allow vendor_init gpu_device chr_file { read write open ioctl getattr setattr }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))
    inject "allow vendor_init vendor_data_file dir { create read write search add_name setattr }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))
    inject "allow vendor_init vendor_data_file file { create read write setattr }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))
    inject "allow vendor_init vendor_firmware_file dir { search read getattr }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))
    inject "allow vendor_init vendor_firmware_file file { read open getattr }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))
    inject "allow vendor_init self capability { chown fowner }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))

    inject "allow domain logd unix_stream_socket { connectto write }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))
    inject "allow domain kernel file { read open }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))
    # NOTE: type_transition rules intentionally REMOVED.
    # Injecting "type_transition init vendor_data_file:dir/file vendor_data_file" via
    # magiskpolicy --live causes bootloops on OEM ROMs (MIUI/HyperOS, OneUI, ColorOS).
    # Root cause: OEM vendor SELinux policies either (a) have neverallow rules that block
    # these type_transitions, causing the entire batch to fail when batched together, or
    # (b) the successfully-injected rule overrides the OEM's own type_transition rules for
    # vendor_init-created /data/vendor/gpu/ directories, labeling them with the wrong type
    # → vendor HAL services (GPU compositor, allocator) can't access the directory
    # → SurfaceFlinger crashes → bootloop. The allow rules above already provide all
    # necessary GPU access; type_transition rules are not required for driver operation.
  fi
  rm -f "$_RULES_TMP" 2>/dev/null

  # ── OEM-SAFE BROAD DOMAIN RULES — silent-fail individual injection ────────
  # These 6 "allow domain ..." rules were removed from the batch heredoc because
  # they trigger neverallow conflicts on OEM ROMs:
  #
  #   allow domain system_lib_file ... execute     → Samsung OneUI:
  #     neverallow { untrusted_app isolated_app } system_lib_file:file execute
  #     Batch contains both isolated_app and domain (a superset) — conflict.
  #
  #   allow domain gpu_device dir { search read }  → Broad but individually safe;
  #   allow domain vendor_data_file dir/file        removed from batch because a
  #                                                  SINGLE conflicting rule can
  #   allow domain logd unix_stream_socket ...      → ColorOS/RealmeUI:
  #     neverallow domain logd:unix_stream_socket connectto
  #
  #   allow domain kernel file { read open }        → MIUI/HyperOS:
  #     neverallow domain kernel:file { read open }
  #
  # When ANY rule in the --apply batch conflicts with a neverallow, the ENTIRE
  # batch is rejected. By removing these from the batch and injecting them here
  # individually with silent-fail, the 44-rule batch succeeds on all OEM ROMs.
  # These individual injections fail silently on OEM ROMs with strict neverallow
  # policies — which is fine, since the OEM's own policy already covers most of
  # the access paths these rules would grant.
  "$SEPOLICY_TOOL" --live "allow domain system_lib_file file { read open getattr execute map }" >/dev/null 2>&1 && \
    { RULES_SUCCESS=$((RULES_SUCCESS + 1)); log_boot "  [+] domain → system_lib_file execute (optional, OEM-permissive only)"; } || true
  "$SEPOLICY_TOOL" --live "allow domain gpu_device dir { search read }" >/dev/null 2>&1 && \
    RULES_SUCCESS=$((RULES_SUCCESS + 1)) || true
  "$SEPOLICY_TOOL" --live "allow domain vendor_data_file dir { search read getattr }" >/dev/null 2>&1 && \
    RULES_SUCCESS=$((RULES_SUCCESS + 1)) || true
  "$SEPOLICY_TOOL" --live "allow domain vendor_data_file file { read open getattr }" >/dev/null 2>&1 && \
    RULES_SUCCESS=$((RULES_SUCCESS + 1)) || true
  "$SEPOLICY_TOOL" --live "allow domain logd unix_stream_socket { connectto write }" >/dev/null 2>&1 && \
    RULES_SUCCESS=$((RULES_SUCCESS + 1)) || true
  "$SEPOLICY_TOOL" --live "allow domain kernel file { read open }" >/dev/null 2>&1 && \
    RULES_SUCCESS=$((RULES_SUCCESS + 1)) || true

  # ── Rules removed from batch to prevent OEM neverallow cascade failure ────
  # These 4 rules were removed from the 40-rule batch heredoc above because
  # each one triggers a specific OEM neverallow that causes the ENTIRE batch to
  # be rejected (0 rules applied). Injected individually here so each can fail
  # silently without affecting the other rules or the batch.
  #
  # Samsung OneUI: neverallow { untrusted_app isolated_app } vendor_firmware_file:file read
  # → 'domain' superset includes untrusted_app → neverallow hit → batch poison.
  "$SEPOLICY_TOOL" --live "allow domain vendor_firmware_file dir { search getattr read }" >/dev/null 2>&1 && \
    { RULES_SUCCESS=$((RULES_SUCCESS + 1)); log_boot "  [+] domain → vendor_firmware_file dir (optional)"; } || \
    log_boot "  [~] domain → vendor_firmware_file dir: skipped (OEM neverallow — expected on OneUI)"
  "$SEPOLICY_TOOL" --live "allow domain vendor_firmware_file file { read open getattr map }" >/dev/null 2>&1 && \
    { RULES_SUCCESS=$((RULES_SUCCESS + 1)); log_boot "  [+] domain → vendor_firmware_file file (optional)"; } || \
    log_boot "  [~] domain → vendor_firmware_file file: skipped (OEM neverallow — expected on OneUI)"
  #
  # MIUI/HyperOS: neverallow domain firmware_file:file { read open }
  "$SEPOLICY_TOOL" --live "allow domain firmware_file file { read open getattr }" >/dev/null 2>&1 && \
    { RULES_SUCCESS=$((RULES_SUCCESS + 1)); log_boot "  [+] domain → firmware_file read (optional)"; } || \
    log_boot "  [~] domain → firmware_file read: skipped (OEM neverallow — expected on MIUI/HyperOS)"
  #
  # Samsung Knox: neverallow vendor_init self:capability { chown fowner }
  "$SEPOLICY_TOOL" --live "allow vendor_init self capability { chown fowner }" >/dev/null 2>&1 && \
    { RULES_SUCCESS=$((RULES_SUCCESS + 1)); log_boot "  [+] vendor_init capability chown/fowner (optional)"; } || \
    log_boot "  [~] vendor_init capability chown/fowner: skipped (Knox neverallow — expected on OneUI)"

  # ========================================
  # ANDROID 16 QPR2: ALLOWXPERM BATCH INJECTION
  # ========================================
  # Android 16 QPR2 introduces set_xperm_filter which requires explicit
  # allowxperm rules for GPU IOCTL access. Without these, GPU IOCTL calls
  # are denied even when the base "allow ... ioctl" rule exists.
  # Reference: Magisk commit dd3798905f1ec75afa71701ff03a5af3be762c83
  #   (libsepol update to Android 16 QPR2 upstream with new policy capabilities)
  #
  # Range 0x0000-0xffff covers all 16-bit IOCTL command numbers.
  # KGSL Adreno IOCTLs use type 'k' (0x6B), subranges 0x6B00-0x6BFF.
  # The full range is safe: rules are no-ops for commands not actually issued.
  # Silently ignored on kernels/magiskpolicy builds that predate xperm support.
  # ========================================

  log_boot "========================================"
  log_boot "Injecting Android 16 QPR2 IOCTL allowxperm rules"
  log_boot "========================================"

  _XPERM_TMP="/dev/tmp/adreno_xperm_$$"
  mkdir -p /dev/tmp 2>/dev/null || true

  cat > "$_XPERM_TMP" << 'XPERM_RULES_BATCH'
allowxperm hal_graphics_composer_default gpu_device chr_file ioctl { 0x0000-0xffff }
allowxperm hal_graphics_allocator_default gpu_device chr_file ioctl { 0x0000-0xffff }
allowxperm hal_graphics_mapper_default gpu_device chr_file ioctl { 0x0000-0xffff }
allowxperm surfaceflinger gpu_device chr_file ioctl { 0x0000-0xffff }
allowxperm system_server gpu_device chr_file ioctl { 0x0000-0xffff }
allowxperm zygote gpu_device chr_file ioctl { 0x0000-0xffff }
allowxperm appdomain gpu_device chr_file ioctl { 0x0000-0xffff }
allowxperm init gpu_device chr_file ioctl { 0x0000-0xffff }
allowxperm vendor_init gpu_device chr_file ioctl { 0x0000-0xffff }
allowxperm domain gpu_device chr_file ioctl { 0x0000-0xffff }
XPERM_RULES_BATCH

  if [ -f "$_XPERM_TMP" ] && "$SEPOLICY_TOOL" --live --apply "$_XPERM_TMP" >/dev/null 2>&1; then
    RULES_SUCCESS=$((RULES_SUCCESS + 10))
    log_boot "[OK] ANDROID 16 QPR2: allowxperm batch applied (10 IOCTL rules, 1 spawn)"
  else
    log_boot "[!] allowxperm batch failed — injecting individually (silent-fail, expected on older kernels)"
    "$SEPOLICY_TOOL" --live "allowxperm hal_graphics_composer_default gpu_device chr_file ioctl { 0x0000-0xffff }" >/dev/null 2>&1 && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || true
    "$SEPOLICY_TOOL" --live "allowxperm hal_graphics_allocator_default gpu_device chr_file ioctl { 0x0000-0xffff }" >/dev/null 2>&1 && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || true
    "$SEPOLICY_TOOL" --live "allowxperm hal_graphics_mapper_default gpu_device chr_file ioctl { 0x0000-0xffff }" >/dev/null 2>&1 && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || true
    "$SEPOLICY_TOOL" --live "allowxperm surfaceflinger gpu_device chr_file ioctl { 0x0000-0xffff }" >/dev/null 2>&1 && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || true
    "$SEPOLICY_TOOL" --live "allowxperm system_server gpu_device chr_file ioctl { 0x0000-0xffff }" >/dev/null 2>&1 && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || true
    "$SEPOLICY_TOOL" --live "allowxperm zygote gpu_device chr_file ioctl { 0x0000-0xffff }" >/dev/null 2>&1 && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || true
    "$SEPOLICY_TOOL" --live "allowxperm appdomain gpu_device chr_file ioctl { 0x0000-0xffff }" >/dev/null 2>&1 && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || true
    "$SEPOLICY_TOOL" --live "allowxperm init gpu_device chr_file ioctl { 0x0000-0xffff }" >/dev/null 2>&1 && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || true
    "$SEPOLICY_TOOL" --live "allowxperm vendor_init gpu_device chr_file ioctl { 0x0000-0xffff }" >/dev/null 2>&1 && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || true
    "$SEPOLICY_TOOL" --live "allowxperm domain gpu_device chr_file ioctl { 0x0000-0xffff }" >/dev/null 2>&1 && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || true
  fi
  rm -f "$_XPERM_TMP" 2>/dev/null

  log_boot "Injecting optional/versioned rules (individual, silent-fail)..."
  # SDK versions: 25=Android 7.1, 27=Android 8.1, 29=Android 10, 30=Android 11,
  # 32=Android 12L, 33=Android 13, 34=Android 14, 35=Android 15, 36=Android 16
  for _sdk_ver in 25 27 29 30 32 33 34 35 36; do
    "$SEPOLICY_TOOL" --live "allow untrusted_app_${_sdk_ver} gpu_device chr_file { read write open ioctl getattr }" >/dev/null 2>&1 && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || true
    # Android 16 QPR2: allowxperm for each SDK-versioned untrusted_app domain
    "$SEPOLICY_TOOL" --live "allowxperm untrusted_app_${_sdk_ver} gpu_device chr_file ioctl { 0x0000-0xffff }" >/dev/null 2>&1 && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || true
  done
  unset _sdk_ver
  "$SEPOLICY_TOOL" --live "allow isolated_app_all gpu_device chr_file { read write open ioctl getattr }" >/dev/null 2>&1 && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || true
  "$SEPOLICY_TOOL" --live "allowxperm isolated_app_all gpu_device chr_file ioctl { 0x0000-0xffff }" >/dev/null 2>&1 && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || true
  "$SEPOLICY_TOOL" --live "allow isolated_compute_app gpu_device chr_file { read write open ioctl getattr }" >/dev/null 2>&1 && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || true
  "$SEPOLICY_TOOL" --live "allowxperm isolated_compute_app gpu_device chr_file ioctl { 0x0000-0xffff }" >/dev/null 2>&1 && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || true
  "$SEPOLICY_TOOL" --live "allow webview_zygote gpu_device chr_file { read write open ioctl getattr }" >/dev/null 2>&1 && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || true
  "$SEPOLICY_TOOL" --live "allowxperm webview_zygote gpu_device chr_file ioctl { 0x0000-0xffff }" >/dev/null 2>&1 && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || true

  log_boot "Injecting Android 13+ sdk_sandbox rules (silent-fail)..."
  "$SEPOLICY_TOOL" --live "allow sdk_sandbox gpu_device chr_file { read write open ioctl getattr }" >/dev/null 2>&1 && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || true
  "$SEPOLICY_TOOL" --live "allow sdk_sandbox same_process_hal_file file { read open getattr execute map }" >/dev/null 2>&1 && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || true
  "$SEPOLICY_TOOL" --live "allow sdk_sandbox vendor_file file { read open getattr execute map }" >/dev/null 2>&1 && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || true
  "$SEPOLICY_TOOL" --live "allowxperm sdk_sandbox gpu_device chr_file ioctl { 0x0000-0xffff }" >/dev/null 2>&1 && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || true

  log_boot "Injecting Android 13+ isolated_process_all rules (silent-fail)..."
  "$SEPOLICY_TOOL" --live "allow isolated_process_all gpu_device chr_file { read write open ioctl getattr }" >/dev/null 2>&1 && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || true
  "$SEPOLICY_TOOL" --live "allowxperm isolated_process_all gpu_device chr_file ioctl { 0x0000-0xffff }" >/dev/null 2>&1 && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || true

  log_boot "Injecting Android 16 QPR2 gpu_debug rules (silent-fail)..."
  "$SEPOLICY_TOOL" --live "allow gpu_debug gpu_device chr_file { read write open ioctl getattr }" >/dev/null 2>&1 && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || true
  "$SEPOLICY_TOOL" --live "allow gpu_debug same_process_hal_file file { read open getattr execute map }" >/dev/null 2>&1 && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || true
  "$SEPOLICY_TOOL" --live "allow gpu_debug vendor_file file { read open getattr execute map }" >/dev/null 2>&1 && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || true
  "$SEPOLICY_TOOL" --live "allowxperm gpu_debug gpu_device chr_file ioctl { 0x0000-0xffff }" >/dev/null 2>&1 && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || true

  log_boot "Injecting OEM-specific rules (Qualcomm)..."
  # vendor_qti_init_shell: Qualcomm CAF-only type. Undefined on Samsung/MediaTek/AOSP
  # ROMs -> magiskpolicy returns error for unknown type -> silent-fail (|| true). Safe.
  # Allows Qualcomm vendor init shell to read sysfs GPU nodes needed for KGSL init.
  "$SEPOLICY_TOOL" --live "allow vendor_qti_init_shell sysfs file { write open getattr }" >/dev/null 2>&1 && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || true
  "$SEPOLICY_TOOL" --live "allow vendor_qti_init_shell sysfs dir { search read }" >/dev/null 2>&1 && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || true

  # ion_device: /dev/ion replaced by DMA-BUF heaps in Android 12 (GKI 2.0, CONFIG_ION
  # disabled android12-5.10+). ion_device type absent in compiled policy on Android 12+.
  # Only inject on Android 11 (SDK <= 30) where /dev/ion is still present.
  # KGSL GPU allocator on Android 11 uses ion_device for command buffer allocation.
  # Kept individual (not in batch heredoc) -- unknown type crashes --apply on Android 12+.
  _ion_sdk=$(getprop ro.build.version.sdk 2>/dev/null || echo "99")
  if [ "${_ion_sdk:-99}" -le 30 ] 2>/dev/null; then
    "$SEPOLICY_TOOL" --live "allow domain ion_device chr_file { read write open ioctl getattr }" >/dev/null 2>&1 && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || true
    log_boot "  [OK] ion_device: SDK=${_ion_sdk} <= 30 (Android 11), /dev/ion present"
  else
    log_boot "  [SKIP] ion_device: SDK=${_ion_sdk} >= 31, type absent (DMA-BUF heaps era)"
  fi
  unset _ion_sdk
  # hal_camera_default vendor_shell_exec execute rule INTENTIONALLY REMOVED.
  # No GPU relevance. Conflicts with neverallow camera->shell_exec on MIUI/HyperOS
  # and OneUI -> caused --apply batch failure on those ROMs.

  # ── adb_data_file fallback rules ────────────────────────────────────────────
  # ROOT CAUSE: Magisk bind-mounts module .so files from /data/adb/modules/<id>/
  # onto /vendor/. Source files inherit 'adb_data_file' from the /data/adb/ tree.
  # chcon (below, in the SELinux relabeling block) attempts to relabel them to
  # 'same_process_hal_file' before the bind-mount is observed by any process.
  # On OEM ROMs with strict vendor policy (MIUI/HyperOS, OneUI, ColorOS), the
  # chcon operation is DENIED by policy — init lacks permission to relabel
  # adb_data_file → same_process_hal_file. Files then retain adb_data_file context
  # across the bind-mount. GPU processes (SF, HAL, Zygote, apps) attempt to dlopen
  # the driver and hit SELinux denial for adb_data_file → SIGSEGV or silent
  # dlopen failure → SurfaceFlinger crash loop → watchdog reboot.
  #
  # These rules allow all GPU-loading domains to access adb_data_file as a
  # fallback, covering the chcon-failure path. On ROMs where chcon succeeds the
  # file label is same_process_hal_file and these rules are never exercised.
  # Rules are injected silently (|| true) — failure on ROMs without adb_data_file
  # as a defined type is harmless.
  log_boot "Injecting adb_data_file fallback rules (OEM chcon-failure path)..."
  for _adf_domain in hal_graphics_composer_default hal_graphics_allocator_default \
                     hal_graphics_mapper_default hal_graphics_mapper \
                     surfaceflinger system_server zygote \
                     untrusted_app platform_app priv_app; do
    "$SEPOLICY_TOOL" --live \
      "allow ${_adf_domain} adb_data_file file { read open getattr execute map }" \
      >/dev/null 2>&1 && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || true
  done
  unset _adf_domain
  # appdomain covers all app processes (untrusted_app + platform_app + priv_app
  # attributes), providing a single catch-all rule for any future app type not
  # listed above. Silent-fail as above.
  "$SEPOLICY_TOOL" --live \
    "allow appdomain adb_data_file file { read open getattr execute map }" \
    >/dev/null 2>&1 && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || true
  # ── END adb_data_file fallback rules ────────────────────────────────────────

  log_boot "========================================"
  log_boot "SELinux Policy Injection Complete"
  log_boot "========================================"
  log_boot "Total rules successfully injected: $RULES_SUCCESS"
  log_boot "Total rules failed: $RULES_FAILED"
  log_boot "Critical rules failed: $CRITICAL_RULES_FAILED"
  log_boot "Root Manager: $ROOT_TYPE"
  log_boot "Tool used: $SEPOLICY_TOOL"
  log_boot "========================================"

  if [ $CRITICAL_RULES_FAILED -gt 0 ]; then
    log_boot "[!] CRITICAL WARNING: $CRITICAL_RULES_FAILED critical rules failed to inject"
    log_boot "GPU functionality WILL BE SEVERELY IMPAIRED"
  elif [ $RULES_SUCCESS -gt 40 ]; then
    log_boot "[OK] EXCELLENT: Comprehensive SELinux policy successfully applied"
  elif [ $RULES_SUCCESS -gt 20 ]; then
    log_boot "[OK] GOOD: Core SELinux rules successfully applied"
  else
    log_boot "[!] WARNING: Limited SELinux rules applied ($RULES_SUCCESS total)"
    log_boot "  Check for AVC denials: dmesg | grep avc"
  fi
else
  log_boot "========================================"
  log_boot "[!] CRITICAL WARNING: SELinux policy tool not found"
  log_boot "========================================"
  log_boot "Tool not found after ${_retry:-3} retries (max ~3s total wait)"
  log_boot "Root Type: $ROOT_TYPE"
  log_boot "Expected tool: magiskpolicy (Magisk/KernelSU/APatch)"
  log_boot "GPU firmware loading will likely fail due to SELinux denials"
  log_boot "Continuing boot without SELinux injection..."
fi

log_boot "SELinux policy injection: SYNCHRONOUS execution complete"

# ── End of moved SELinux section ────────────────────────────────────────

log_boot "========================================"

# ========================================
# APPLY RENDER MODE SYSTEM PROPERTIES
# ========================================

log_boot "========================================"
log_boot "APPLYING RENDER MODE CONFIGURATION"
log_boot "========================================"
log_boot "Selected render mode: $RENDER_MODE"

# system.prop is loaded by the root manager on every boot automatically.
# Writing here ensures every prop is set on EVERY boot, no resetprop timing needed.
# We also call resetprop below for the CURRENT boot session.
# NOTE: debug.renderengine.backend is NOT written to system.prop — OEM ROMs
# (MIUI/HyperOS, OneUI, ColorOS) register SystemProperties::addChangeCallback for it.
# If init loads it from system.prop and it changes later, SF fires a RenderEngine
# reinit mid-frame → crash. Set exclusively via resetprop BEFORE SF starts (below).

SYSTEM_PROP_FILE="$MODDIR/system.prop"

# Always strip old render + SF + stability props first, then write the correct set
_RENDER_PROPS='debug\.hwui\.renderer=|debug\.renderengine\.backend=|debug\.sf\.latch_unsignaled=|debug\.sf\.auto_latch_unsignaled=|debug\.sf\.disable_backpressure=|debug\.sf\.enable_hwc_vds=|debug\.sf\.enable_transaction_tracing=|debug\.sf\.client_composition_cache_size=|ro\.sf\.disable_triple_buffer=|ro\.surface_flinger\.use_context_priority=|ro\.surface_flinger\.max_frame_buffer_acquired_buffers=|ro\.surface_flinger\.force_hwc_copy_for_virtual_displays=|debug\.hwui\.use_buffer_age=|debug\.hwui\.use_partial_updates=|debug\.hwui\.use_gpu_pixel_buffers=|renderthread\.skia\.reduceopstasksplitting=|debug\.hwui\.skip_empty_damage=|debug\.hwui\.webview_overlays_enabled=|debug\.hwui\.skia_tracing_enabled=|debug\.hwui\.skia_use_perfetto_track_events=|debug\.hwui\.capture_skp_enabled=|debug\.hwui\.skia_atrace_enabled=|debug\.hwui\.use_hint_manager=|debug\.hwui\.target_cpu_time_percent=|com\.qc\.hardware=|persist\.sys\.force_sw_gles=|debug\.vulkan\.layers=|ro\.hwui\.use_vulkan=|debug\.hwui\.recycled_buffer_cache_size=|debug\.hwui\.overdraw=|debug\.hwui\.profile=|debug\.hwui\.show_dirty_regions=|graphics\.gpu\.profiler\.support=|ro\.egl\.blobcache\.multifile=|ro\.egl\.blobcache\.multifile_limit=|debug\.hwui\.fps_divisor=|debug\.hwui\.render_thread=|debug\.hwui\.render_dirty_regions=|debug\.hwui\.show_layers_updates=|debug\.hwui\.filter_test_overhead=|debug\.hwui\.nv_profiling=|debug\.hwui\.clip_surfaceviews=|debug\.hwui\.8bit_hdr_headroom=|debug\.hwui\.skip_eglmanager_telemetry=|debug\.hwui\.initialize_gl_always=|debug\.hwui\.level=|debug\.hwui\.disable_vsync=|hwui\.disable_vsync=|debug\.vulkan\.layers\.enable=|persist\.device_config\.runtime_native\.usap_pool_enabled=|debug\.gralloc\.enable_fb_ubwc=|vendor\.gralloc\.enable_fb_ubwc=|persist\.sys\.perf\.topAppRenderThreadBoost\.enable=|persist\.sys\.gpu\.working_thread_priority=|debug\.sf\.early_phase_offset_ns=|debug\.sf\.early_app_phase_offset_ns=|debug\.sf\.early_gl_phase_offset_ns=|debug\.sf\.early_gl_app_phase_offset_ns=|debug\.hwui\.use_skia_graphite=|ro\.surface_flinger\.supports_background_blur=|persist\.sys\.sf\.disable_blurs=|ro\.sf\.blurs_are_expensive=|ro\.config\.vulkan\.enabled=|persist\.vendor\.vulkan\.enable=|persist\.graphics\.vulkan\.disable_pre_rotation=|debug\.sf\.use_phase_offsets_as_durations=|debug\.hwui\.texture_cache_size=|debug\.hwui\.layer_cache_size=|debug\.hwui\.path_cache_size=|debug\.hwui\.force_dark=|ro\\.config\\.vulkan\\.enabled=|persist\\.vendor\\.vulkan\\.enable=|ro\.hwui\.text_small_cache_width=|ro\.hwui\.text_small_cache_height=|ro\.hwui\.text_large_cache_width=|ro\.hwui\.text_large_cache_height=|ro\.hwui\.drop_shadow_cache_size=|ro\.hwui\.gradient_cache_size=|persist\.sys\.sf\.native_mode=|debug\.sf\.treat_170m_as_sRGB=|debug\.egl\.debug_proc='
if [ -f "$SYSTEM_PROP_FILE" ]; then
  awk -v pat="$_RENDER_PROPS" '{ if ($0 ~ pat) next; print }' \
    "$SYSTEM_PROP_FILE" > "${SYSTEM_PROP_FILE}.tmp" 2>/dev/null && \
    mv "${SYSTEM_PROP_FILE}.tmp" "$SYSTEM_PROP_FILE" 2>/dev/null || \
    rm -f "${SYSTEM_PROP_FILE}.tmp" 2>/dev/null
else
  touch "$SYSTEM_PROP_FILE" 2>/dev/null || true
fi
unset _RENDER_PROPS

# ── FIRST BOOT AFTER INSTALL SAFETY CHECK ────────────────────────────────────
# On the very first boot after a fresh install with skiavk/skiavk_all pre-set,
# the Vulkan driver has not yet been validated by the system (zero shader cache,
# driver freshly placed by overlay). Forcing Vulkan mode on first boot causes
# SurfaceFlinger to fail during Vulkan driver init → BOOTLOOP.
#
# Solution: detect first boot via .first_boot_pending marker, skip skiavk on
# this boot (use normal), remove marker so 2nd boot applies the real mode.
# Marker is created by customize.sh at install time.
# ─────────────────────────────────────────────────────────────────────────────

FIRST_BOOT_PENDING=false
if [ -f "$MODDIR/.first_boot_pending" ]; then
  FIRST_BOOT_PENDING=true
  if rm -f "$MODDIR/.first_boot_pending" 2>/dev/null; then
    log_boot "[OK] First boot pending marker removed"
  fi
  log_boot "========================================"
  log_boot "FIRST BOOT AFTER INSTALL DETECTED"
  log_boot "========================================"
  log_boot "Renderer override ($RENDER_MODE) is DEFERRED to next boot."
  log_boot "Reason: Vulkan/GL driver not yet validated on pristine install."
  log_boot "This boot uses the system-default renderer (no debug.hwui.renderer override)."
  log_boot "All other stability and compatibility props ARE applied this boot."
  log_boot "NOTE: First boot is NOT 'stock/normal mode' — HWUI/EGL/GPU props are active."
  log_boot "      Only the renderer prop (skiavk/skiagl) is withheld until boot 2."
  log_boot "From the NEXT boot onwards, $RENDER_MODE renderer will be fully active."
  log_boot "========================================"

  # Tell service.sh to skip renderer activation this boot too.
  # post-fs-data.sh defers the renderer here, but service.sh runs independently
  # at boot_completed+2s and has no way to know it's first boot (marker already gone).
  # Without this second marker, service.sh would resetprop skiavk at boot_completed+2s
  # → apps opened after that point start with skiavk, Vulkan not yet validated → crash.
  touch "$MODDIR/.service_skip_render" 2>/dev/null && \
    log_boot "[OK] Created service skip marker — service.sh will not set renderer this boot"
fi

# ========================================
# BOOT SUCCESS MARKER: clear stale marker from previous boot
# ========================================
# .boot_success is written by service.sh ONLY after sys.boot_completed fires.
# Deleting it here ensures each boot must re-earn it. A stale marker from a
# previous good boot must NOT carry over: if a ROM/vendor update breaks Vulkan
# compatibility after the marker was written, the stale marker would cause
# skiavkthreaded to be applied again → SF freeze → 3-boot auto-disable cycle.
# Deleting unconditionally here limits worst-case to exactly 1 freeze per
# regression (this boot falls back to skiaglthreaded, boot completes, marker
# is re-written, next boot promotes to skiavkthreaded again).
rm -f "$MODDIR/.boot_success" 2>/dev/null || true
log_boot "[OK] Previous .boot_success cleared — must re-confirm this boot"

# ========================================
# EARLY SKIA PIPELINE CACHE CLEARING
# ========================================
# PRIMARY FIX for "apps crash immediately on open in skiavk/skiagl":
#
# ROOT CAUSE:
#   Each app stores a per-process Skia pipeline cache at:
#     /data/user_de/0/<pkg>/app_skia_pipeline_cache/
#   On a GL → Vulkan (or Vulkan → GL) mode switch, these dirs contain
#   pipeline cache blobs from the OLD backend. On first HWUI init with
#   the new renderer, HWUI passes the old blob as VkPipelineCacheCreateInfo
#   pInitialData. The Vulkan driver sees a wrong cache-header magic value →
#   VK_ERROR_FORMAT_FEATURE_NOT_SUPPORTED or silent corruption → GPU fault
#   → SIGSEGV. The app crashes before any UI is drawn.
#
# WHY HERE (post-fs-data.sh) AND NOT service.sh:
#   service.sh runs at boot_completed+2s. Apps are opened by users within
#   seconds of boot_completed — BEFORE service.sh's cache-clear runs. This
#   race causes the "5-10 minute crash window after boot" symptom.
#   post-fs-data.sh runs in the early boot stage, BEFORE Zygote and
#   SurfaceFlinger start. Clearing here is guaranteed to complete before any
#   app process can ever read or write a pipeline cache file.
#
# MODE-CHANGE DETECTION + skiavk SESSION-KEYED CACHE FIX (critical for OOM safety):
#   Clear when the render mode has changed (GL↔Vulkan or any other switch),
#   OR when the effective mode is skiavk/skiavk_all regardless of mode change.
#
#   WHY skiavk always clears:
#     Custom Adreno drivers embed session-specific memory addresses and internal
#     pointers into their Vulkan pipeline cache blobs (confirmed: VkPipelineCache
#     files contain raw /dev/ashmem/memoryheapbase addresses valid only for the
#     boot session that wrote them). On the NEXT boot, those addresses are invalid.
#     When an app passes the stale blob as VkPipelineCacheCreateInfo::pInitialData,
#     the driver dereferences invalid memory instead of rejecting gracefully →
#     SIGSEGV in vkCreatePipelineCache → app crashes before any UI draws.
#     This is why boot 3 produces a black screen: same skiavk mode (no change
#     detected), caches preserved, all apps crash immediately on open.
#
#   OOM SAFETY: skiavk caches are rebuilt lazily per-app as users open them,
#     not all at once. No OOM spike. The Facebook 2000+ shader OOM risk only
#     applies to skiagl/normal → skiavk transitions where HWUI format changes
#     too, but the session-key issue forces a clear every skiavk boot regardless.
#     skiagl and normal caches remain preserved when mode is unchanged.
#
#   Last mode is written to _LAST_MODE_FILE by service.sh after each
#   successful boot. post-fs-data.sh reads it here to detect a change.
#   On a fresh install, the file is absent → treated as mode changed → clear.
# ========================================

_EARLY_LAST_MODE_FILE="/data/local/tmp/adreno_last_render_mode"
_EARLY_LAST_MODE=""
if [ -f "$_EARLY_LAST_MODE_FILE" ]; then
  { IFS= read -r _EARLY_LAST_MODE; } < "$_EARLY_LAST_MODE_FILE" 2>/dev/null || _EARLY_LAST_MODE=""
fi

# On first boot (FIRST_BOOT_PENDING=true) the renderer is withheld and the
# effective mode is "normal". Compare the effective mode against last recorded.
# This way a previous skiavk install switching to "first-boot normal" also
# triggers a correct cache clear on the first post-install boot.
_EARLY_EFFECTIVE_MODE="$RENDER_MODE"
[ "$FIRST_BOOT_PENDING" = "true" ] && _EARLY_EFFECTIVE_MODE="normal"

# Determine if a clear is needed and record the reason.
_EARLY_CLEAR_REASON=""
if [ "$_EARLY_EFFECTIVE_MODE" != "$_EARLY_LAST_MODE" ]; then
  _EARLY_CLEAR_REASON="mode_change"
elif [ "$_EARLY_EFFECTIVE_MODE" = "skiavk" ] || [ "$_EARLY_EFFECTIVE_MODE" = "skiavk_all" ]; then
  # Same skiavk mode across boots — still clear to purge stale session-keyed
  # Vulkan pipeline cache blobs (custom Adreno driver stores raw heap addresses
  # that are invalidated on every boot → vkCreatePipelineCache SIGSEGV).
  _EARLY_CLEAR_REASON="skiavk_session_keys"
fi

if [ -n "$_EARLY_CLEAR_REASON" ]; then
  log_boot "========================================"
  log_boot "EARLY CACHE CLEAR (pre-Zygote):"
  if [ "$_EARLY_CLEAR_REASON" = "mode_change" ]; then
    log_boot "  Reason: Mode changed '${_EARLY_LAST_MODE:-<none>}' → '$_EARLY_EFFECTIVE_MODE'"
    log_boot "  GL/VK format mismatch in preserved caches → crash on app open."
  else
    log_boot "  Reason: skiavk mode (custom Adreno driver session-keyed caches)"
    log_boot "  Driver embeds /dev/ashmem heap addresses in VkPipelineCache blobs."
    log_boot "  These addresses are invalid on the next boot → vkCreatePipelineCache"
    log_boot "  SIGSEGV → all apps crash before any UI draws → black screen."
    log_boot "  Caches cleared pre-Zygote; apps rebuild lazily — no OOM spike."
  fi
  log_boot "  Clearing stale Skia/HWUI pipeline caches BEFORE Zygote starts."
  log_boot "========================================"
  # Global HWUI pipeline key cache directory
  rm -rf /data/misc/hwui/ 2>/dev/null || true
  # Per-app Skia Vulkan/GL pipeline caches — the primary crash culprit on mode switch
  find /data/user_de/0 -maxdepth 2 -type d -name "app_skia_pipeline_cache" \
      -exec rm -rf {} + 2>/dev/null || true
  # Fallback: legacy /data/data path (pre-Android-7 / direct-boot disabled devices)
  find /data/data -maxdepth 2 -type d -name "app_skia_pipeline_cache" \
      -exec rm -rf {} + 2>/dev/null || true
  # Skia shader journal manifests
  find /data/user_de/0 -maxdepth 2 -name "*.shader_journal" -delete 2>/dev/null || true
  # Skia per-app shader and pipeline cache sub-directories
  find /data/user_de/0 -maxdepth 2 -type d \( -name "skia_shaders" -o -name "shader_cache" \) \
      -exec rm -rf {} + 2>/dev/null || true
  log_boot "[OK] Early Skia pipeline & shader cache clear complete."
  log_boot "     Apps will recompile shaders fresh — no mode-mismatch or session-key crashes."
else
  log_boot "EARLY CACHE CLEAR: mode '${_EARLY_EFFECTIVE_MODE}' unchanged, not skiavk — caches valid, preserved."
  log_boot "  (Skipping clear prevents shader-recompile OOM on Facebook/GMS.)"
fi
unset _EARLY_LAST_MODE _EARLY_LAST_MODE_FILE _EARLY_EFFECTIVE_MODE _EARLY_CLEAR_REASON

log_boot "========================================"
log_boot "APPLYING RENDER MODE PROPS"
log_boot "========================================"

# ==========================================================================
# BLOCK A — Vulkan Compatibility Gate
# Runs probe_vulkan_compat_extended() and auto-degrades RENDER_MODE before
# the renderer case block below, so every code path sees the correct mode.
# ==========================================================================
_VK_SCORE_FILE="/data/local/tmp/adreno_vk_compat_score"
_VK_SCORE_WRITTEN=false

if [ "$RENDER_MODE" = "skiavk" ] || [ "$RENDER_MODE" = "skiavk_all" ]; then

  log_boot "========================================"
  log_boot "VULKAN COMPATIBILITY GATE"
  log_boot "========================================"

  probe_vulkan_compat_extended

  log_boot "VK compat score   : ${VK_COMPAT_SCORE}/100  (${VK_COMPAT_LEVEL})"
  log_boot "Gralloc version   : ${VK_GRALLOC_VERSION}"
  log_boot "ro.hardware.vulkan: '${VK_HWVULKAN_PROP}'"
  log_boot "Vendor API level  : ${VK_VENDOR_API_LEVEL}"
  log_boot "Build date gap    : ~${VK_BUILD_DATE_GAP_DAYS} days"
  log_boot "Driver found      : ${VK_DRIVER_FOUND}"
  if [ -n "$VK_COMPAT_REASONS" ]; then
    log_boot "Deductions        : ${VK_COMPAT_REASONS}"
  else
    log_boot "Deductions        : none"
  fi

  # Persist score for service.sh and WebUI
  {
    printf 'SCORE=%s\n'    "$VK_COMPAT_SCORE"
    printf 'LEVEL=%s\n'    "$VK_COMPAT_LEVEL"
    printf 'GRALLOC=%s\n'  "$VK_GRALLOC_VERSION"
    printf 'HW_VK=%s\n'    "$VK_HWVULKAN_PROP"
    printf 'VAPI=%s\n'     "$VK_VENDOR_API_LEVEL"
    printf 'GAP_DAYS=%s\n' "$VK_BUILD_DATE_GAP_DAYS"
    printf 'DRIVER=%s\n'   "$VK_DRIVER_FOUND"
    printf 'REASONS=%s\n'  "$VK_COMPAT_REASONS"
  } > "$_VK_SCORE_FILE" 2>/dev/null && _VK_SCORE_WRITTEN=true

  _FORCE_OVERRIDE_MARKER="/data/local/tmp/adreno_skiavk_force_override"
  _DEGRADE_REASON=""

  if [ "$VK_COMPAT_LEVEL" = "blocked" ]; then
    # LENIENT: blocked no longer auto-degrades to skiagl.
    # The probe is a conservative heuristic — many real devices hit "blocked"
    # (e.g. old vendor + gralloc mismatch) and run skiavk perfectly fine.
    # Silently overriding the user's explicit choice is worse than a warning.
    # We log clearly and proceed. Only risky+no_driver (driver .so absent)
    # still degrades, because Vulkan is structurally impossible without it.
    log_boot "========================================="
    log_boot "[WARNING] compat=blocked (score=${VK_COMPAT_SCORE}/100) — proceeding with $RENDER_MODE anyway"
    log_boot "  Reasons: ${VK_COMPAT_REASONS:-none recorded}"
    log_boot "  Vulkan may fail silently on this ROM/vendor; if it does HWUI falls back to GL automatically."
    log_boot "  To force skiagl regardless: echo skiagl > /sdcard/Adreno_Driver/Config/adreno_config.txt"
    log_boot "========================================="

  elif [ "$VK_COMPAT_LEVEL" = "risky" ]; then
    if [ -f "$_FORCE_OVERRIDE_MARKER" ]; then
      log_boot "[OVERRIDE] compat=risky but force-override present — keeping $RENDER_MODE"
    elif [ "$VK_DRIVER_FOUND" = "false" ]; then
      # No vulkan.*.so anywhere — Vulkan is structurally impossible.
      # This is the only remaining hard auto-degrade trigger.
      _DEGRADE_REASON="compat_risky_no_driver(score=${VK_COMPAT_SCORE})"
      log_boot "[AUTO-DEGRADE] score=${VK_COMPAT_SCORE} (risky) + no Vulkan driver .so found → skiagl"
      log_boot "  Cannot use skiavk: no vulkan.*.so found in vendor/system paths"
    else
      log_boot "[RISKY] score=${VK_COMPAT_SCORE} — keeping $RENDER_MODE (driver present)"
      log_boot "  Reasons: ${VK_COMPAT_REASONS}"
      log_boot "  If skiavk causes black screen: rm /data/local/tmp/adreno_vk_compat_score && reboot"
      if [ "$RENDER_MODE" = "skiavk_all" ]; then
        RENDER_MODE="skiavk"
        log_boot "  [AUTO] skiavk_all → skiavk (risky: force-stop disabled as precaution)"
      fi
    fi

  elif [ "$VK_COMPAT_LEVEL" = "marginal" ]; then
    log_boot "[MARGINAL] score=${VK_COMPAT_SCORE} — keeping $RENDER_MODE with watchdog"
    if [ "$RENDER_MODE" = "skiavk_all" ]; then
      RENDER_MODE="skiavk"
      log_boot "  [AUTO] skiavk_all → skiavk (marginal: force-stop disabled as precaution)"
    fi

  else
    log_boot "[OK] compat=safe (score=${VK_COMPAT_SCORE}) — proceeding with $RENDER_MODE"
  fi

  if [ -n "$_DEGRADE_REASON" ]; then
    RENDER_MODE="skiagl"
    printf '%s\n' "$_DEGRADE_REASON" \
      > "/data/local/tmp/adreno_skiavk_degraded" 2>/dev/null || true
    log_boot "========================================"
    log_boot "[AUTO-DEGRADE ACTIVE] RENDER_MODE overridden to skiagl this boot"
    log_boot "  Config RENDER_MODE is NOT overwritten — survives to next boot."
    log_boot "  After ROM/vendor upgrade: rm /data/local/tmp/adreno_vk_compat_score"
    log_boot "  And: rm /data/local/tmp/adreno_skiavk_degraded  then reboot"
    log_boot "========================================"
  else
    rm -f "/data/local/tmp/adreno_skiavk_degraded" 2>/dev/null || true
  fi

  unset _DEGRADE_REASON _FORCE_OVERRIDE_MARKER

fi

# ── Fix ro.hardware.vulkan ICD at earliest possible point (pre-Zygote) ────────
if [ "$RENDER_MODE" = "skiavk" ] || [ "$RENDER_MODE" = "skiavk_all" ]; then
  if command -v resetprop >/dev/null 2>&1; then
    _curr_hwvk=$(getprop ro.hardware.vulkan 2>/dev/null || echo "")
    case "$_curr_hwvk" in
      adreno|"") : ;;
      *)
        if [ -f "/vendor/lib64/hw/vulkan.adreno.so" ] || \
           [ -f "/vendor/lib/hw/vulkan.adreno.so" ]; then
          resetprop ro.hardware.vulkan adreno 2>/dev/null && \
            log_boot "[FIX] ro.hardware.vulkan: '${_curr_hwvk}' → 'adreno' (ICD fix)" || \
            log_boot "[!] ro.hardware.vulkan fix FAILED"
        else
          log_boot "[SKIP] ro.hardware.vulkan='${_curr_hwvk}' but vulkan.adreno.so absent"
        fi
        ;;
    esac
    unset _curr_hwvk
  fi
fi

unset _VK_SCORE_FILE _VK_SCORE_WRITTEN

# ==========================================================================
# BLOCK B — apply_gralloc_compat_props()
# Sets gralloc-level WSI compatibility props for old-vendor devices.
# Called after skiavk resetprop block.
# ==========================================================================
apply_gralloc_compat_props() {
  case "$RENDER_MODE" in
    skiavk|skiavk_all) ;;
    *) return 0 ;;
  esac
  command -v resetprop >/dev/null 2>&1 || return 1

  local _gralloc_v="${VK_GRALLOC_VERSION:-unknown}"

  case "$_gralloc_v" in
    2|3)
      # Disable SF backpressure stall on old gralloc (fence interop broken)
      resetprop debug.sf.disable_backpressure 0 2>/dev/null || true
      # Wider gralloc2/3 surface format support
      resetprop ro.surface_flinger.use_context_priority 1 2>/dev/null || true
      # Reduce buffer pool pressure (gralloc2 hard pool limits)
      resetprop ro.sf.disable_triple_buffer 0 2>/dev/null || true
      log_boot "[gralloc-compat] gralloc${_gralloc_v}: applied WSI fallback props"
      ;;
    4|aidl)
      log_boot "[gralloc-compat] gralloc${_gralloc_v}: no fallback needed"
      ;;
    *)
      log_boot "[gralloc-compat] gralloc version unknown: skipping compat props"
      ;;
  esac

  # Cap SF acquire timeout on non-safe compat levels (KGSL fence interop)
  if [ -n "$VK_COMPAT_LEVEL" ] && [ "$VK_COMPAT_LEVEL" != "safe" ]; then
    resetprop debug.sf.max_frame_buffer_acquired_buffers 2 2>/dev/null || true
    log_boot "[kgsl-compat] capped SF buffer acquire: max_frame_buffer_acquired_buffers=2"
  fi

  # Kill validation layers unconditionally (ABI mismatch on old-vendor)
  resetprop debug.vulkan.dev.layers "" 2>/dev/null || true
  resetprop debug.vulkan.layers "" 2>/dev/null || true
  resetprop persist.graphics.vulkan.validation_enable 0 2>/dev/null || true

  return 0
}
# ══ END BLOCK A + BLOCK B ════════════════════════════════════════════════

case "$RENDER_MODE" in
  skiavk|skiavk_all)
    # HWUI props
    # debug.hwui.renderer=skiavk
    #   App render thread uses Skia+Vulkan pipeline instead of Skia+GL.
    #
    # debug.renderengine.backend=skiavkthreaded
    #   SurfaceFlinger compositor uses Skia+Vulkan on a dedicated thread.
    #   SKIA_VK_THREADED = enum 6 in RenderEngine.h; implemented in Android 14
    #   (SkiaVkRenderEngine.cpp); required default in Android 15+. Applied via
    #   resetprop in post-fs-data (pre-SF). "threaded" = SF vsync loop not blocked
    #   waiting for GPU — compositor runs asynchronously on RenderThread.
    #
    # debug.sf.latch_unsignaled=1
    #   Custom Adreno drivers signal GPU fences SLOWER than stock. SF with
    #   skiavkthreaded waits for Vulkan fences before presenting each frame.
    #   Slow fence → SF misses vsync deadline → backpressure cascades to ALL
    #   running apps → system freeze → crash. This forces SF to latch (consume)
    #   buffers even when their fence has not yet signaled, bypassing
    #   the stall entirely. AOSP explicitly documents this for Vulkan compat.
    #
    # debug.sf.auto_latch_unsignaled=true
    #   Android 13+ refinement: only applies latch_unsignaled for single-layer
    #   fullscreen scenarios. Safer variant; complements latch_unsignaled=1.
    #
    # debug.sf.disable_backpressure=1
    #   Prevents SF from propagating vsync-miss signals as backpressure to apps.
    #   Without this, one slow Vulkan fence causes SF to signal ALL apps to slow
    #   their render rate → cascade freeze that looks like a system crash.
    #
    # debug.sf.enable_hwc_vds=1
    #   Routes virtual display compositing (screenshots, screen recording,
    #   PiP, Miracast) through HWC instead of spawning new Vulkan render
    #   contexts in SF. Without this, every screenshot creates a new Vulkan
    #   context → Vulkan memory exhausted within seconds → system crash.
    #   Source: AOSP SurfaceFlinger.cpp, property "debug.sf.enable_hwc_vds".
    #
    # ro.sf.disable_triple_buffer=1
    #   Reduces SF layer buffering from 3 to 2 simultaneous Vulkan framebuffers.
    #   Triple buffering = 3 × (screen resolution × 4 bytes) always allocated
    #   in Vulkan memory. On custom drivers with smaller Vulkan heaps, this
    #   exhausts available memory when combined with app HWUI Vulkan contexts.
    #
    # debug.sf.client_composition_cache_size=1
    #   Android 12+ SF caches client-composition render results. Default cache
    #   size is 3 full Vulkan renderbuffers. Each one = screen-sized Vulkan
    #   allocation. Reducing to 1 cuts this Vulkan memory usage by 66%.
    #
    # debug.sf.enable_transaction_tracing=false
    #   Disables SF's transaction tracing (on by default in Android 12+).
    #   Transaction tracing holds locks shared with the Vulkan render thread;
    #   under sustained load this causes priority inversion → SF stall → crash.
    #
    # com.qc.hardware=true
    #   Qualcomm-specific flag. Enables Qualcomm hardware acceleration paths
    #   in gralloc and vendor libs. Without this, some Qualcomm ION buffer
    #   allocation paths are bypassed → buffer format mismatches with the
    #   Vulkan driver → VK_ERROR_INCOMPATIBLE_DRIVER or SIGSEGV in driver.
    #
    # persist.sys.force_sw_gles=0
    #   Explicitly ensures software GL is not forced system-wide. On some
    #   ROMs a previous tweak or recovery operation may leave this set to 1,
    #   which causes the GL→Vulkan bridge layer to initialize incorrectly.
    #
    # ro.surface_flinger.use_context_priority=true
    #   "Instruct the Render Engine to use EGL_IMG_context_priority hint if
    #   available." (SurfaceFlingerProperties.sysprop, AOSP main)
    #   Gives SurfaceFlinger's GPU context HIGH priority at the hardware
    #   scheduler level, so the Vulkan compositor never starves waiting for
    #   GPU time behind app GL contexts. Prevents SurfaceFlinger GPU starvation.
    #
    # ro.surface_flinger.max_frame_buffer_acquired_buffers=2
    #   "Controls the number of buffers SurfaceFlinger will allocate for use
    #   in FramebufferSurface." (SurfaceFlingerProperties.sysprop, AOSP main)
    #   Caps display surface acquired-buffer count at 2. Some Qualcomm device
    #   trees ship this at 3; keeping it at 2 combined with disable_triple_buffer
    #   further reduces peak Vulkan memory allocation on the display path.
    #
    # ro.surface_flinger.force_hwc_copy_for_virtual_displays=true
    #   "Some hardware can do RGB->YUV conversion more efficiently in hardware
    #   controlled by HWC than in hardware controlled by the video encoder.
    #   This instruct VirtualDisplaySurface to use HWC for such conversion on
    #   GL composition." (SurfaceFlingerProperties.sysprop, AOSP main)
    #   Forces hardware (HWC/display engine) to do the RGB→YUV blit for
    #   screenshots and screen recording instead of spawning a Vulkan GPU
    #   blit pass. Companion to enable_hwc_vds; covers the conversion path.
    #
    # debug.hwui.use_buffer_age=false
    #   Default true: Skia uses EGL_EXT_buffer_age for partial invalidation.
    #   Adreno Vulkan drivers misreport buffer age → Skia reads stale regions
    #   → corrupt frames → crash. False = full redraws every frame (safe).
    #
    # debug.hwui.use_partial_updates=false
    #   Companion to use_buffer_age. Disables BUFFER_PRESERVED partial updates.
    #   Same root cause: Adreno partial buffer age tracking is unreliable.
    #
    # debug.hwui.use_gpu_pixel_buffers=false
    #   Disables PBO (Pixel Buffer Object) GPU readback. PBO readback via
    #   Vulkan has a race condition in custom Adreno firmware → sporadic SIGSEGV
    #   in RenderThread during screenshots and multitasking animations.
    #
    # renderthread.skia.reduceopstasksplitting=true
    #   Prevents Skia from splitting render ops into many tiny tasks. Without
    #   this, task count grows unboundedly with each frame swap → memory for
    #   each unsynchronized task accumulates faster than GC → OOM crash.
    #   Specifically documented for Adreno+Vulkan sustained workloads.
    #
    # debug.hwui.skip_empty_damage=true
    #   Skip submitting Vulkan command buffers for frames with no damage rect.
    #   Reduces GPU idle-wake cycles and Vulkan submission overhead.
    #
    # debug.hwui.webview_overlays_enabled=true
    #   WebView requires the overlay compositing path when HWUI uses Vulkan.
    #   Without it, WebView falls back to software rendering that conflicts
    #   with Vulkan surface management → black frames or crash in browsers.
    #
    # debug.hwui.skia_tracing_enabled=false
    # debug.hwui.skia_use_perfetto_track_events=false
    # debug.hwui.capture_skp_enabled=false
    #   Disable Skia profiling/tracing. When enabled under Vulkan, these
    #   write to shared memory regions the Adreno driver also accesses →
    #   use-after-free crashes on specific Adreno firmware versions.
    #
    # debug.hwui.skia_atrace_enabled=false
    #   Legacy ATrace hook for Skia drawing commands (older than skia_tracing_enabled;
    #   still parsed on Android 10–12 and many OEM ROMs). When active it
    #   instruments every Skia canvas call with an atrace begin/end pair,
    #   adding measurable CPU overhead per draw call under Vulkan.
    #   Disable to eliminate this per-frame systrace cost.
    #
    # debug.hwui.use_hint_manager=true
    #   "Controls whether HWUI will send timing hints to HintManager for
    #   better CPU scheduling." (AOSP Properties.h)
    #   HWUI reports frame-start and frame-end hints to Android's
    #   PerformanceHintManager API, which lets the CPU scheduler ramp
    #   clocks up before the render frame and scale them back down after.
    #   With skiavk, without this the CPU can run throttled during GPU
    #   command submission and cause dropped frames on the first Vulkan path.
    #
    # debug.hwui.target_cpu_time_percent=33
    #   "Percentage of frame time that's used for CPU work. The rest is
    #   reserved for GPU work." (AOSP Properties.h) Used with use_hint_manager.
    #   Default ~66 assumes GL workloads where CPU builds most of the work.
    #   With skiavkthreaded the SF compositor async thread takes ~67% of frame time.
    #   Setting to 33 tells HintManager the CPU only needs 33% of the frame
    #   budget and GPU gets the remaining 67%, preventing CPU over-boosting
    #   at the expense of GPU clock starvation on custom Adreno firmware.
    {
      # ── SF fence/buffer props INTENTIONALLY OMITTED ──────────────────────────
      # debug.sf.latch_unsignaled, debug.sf.auto_latch_unsignaled,
      # debug.sf.disable_backpressure, debug.sf.enable_hwc_vds,
      # ro.sf.disable_triple_buffer, debug.sf.client_composition_cache_size,
      # debug.sf.enable_transaction_tracing, ro.surface_flinger.use_context_priority,
      # ro.surface_flinger.max_frame_buffer_acquired_buffers,
      # ro.surface_flinger.force_hwc_copy_for_virtual_displays
      #
      # ROOT CAUSE ANALYSIS — "shows for a second then whole screen black":
      # latch_unsignaled tells SF to present Vulkan frames BEFORE the GPU fence
      # signals. On custom Adreno drivers with broken/delayed fence FD export,
      # the fence NEVER signals back. SF presents frame 1 (user sees app briefly),
      # then the buffer queue fills with unsignaled fences — no new buffer can be
      # dequeued — HWUI deadlocks — black screen. disable_backpressure amplifies
      # this by removing SF flow control. disable_triple_buffer / max_frame_buffer=2
      # starve the pipeline of render buffers, same outcome.
      # The old working files had NONE of these SF props. Only hwui.renderer and
      # renderengine.backend were needed. Removing all of them restores stability.
      # Renderer props persist to system.prop so SF reads them at init
      
      
      if [ "$FIRST_BOOT_PENDING" = "false" ]; then
        printf 'debug.hwui.renderer=skiavk\n'
        # debug.renderengine.backend intentionally NOT written to system.prop.
        # OEM ROMs (MIUI/HyperOS, Samsung OneUI, ColorOS) register a live
        # SystemProperties::addChangeCallback for this prop. If init loads it from
        # system.prop and its value changes at runtime, SurfaceFlinger fires a
        # RenderEngine reinitialization mid-frame → SF crash → all apps lose surfaces
        # → watchdog reboot. Set exclusively via resetprop BEFORE SF starts (below).
      fi
      printf 'com.qc.hardware=true\n'
      printf 'persist.sys.force_sw_gles=0\n'
      printf 'debug.hwui.use_buffer_age=false\n'
      printf 'debug.hwui.use_partial_updates=false\n'
      printf 'debug.hwui.use_gpu_pixel_buffers=false\n'
      # reduceopstasksplitting=false — AOSP default. Setting true reduces Skia OpsTask
      # splits in the render thread (larger batches), which causes rendering order
      # failures and visual artifacts in apps with complex custom draw operations
      # (e-readers, maps, games with HWUI UI overlay). Leave at safe default false.
      printf 'renderthread.skia.reduceopstasksplitting=false\n'
      printf 'debug.hwui.skip_empty_damage=true\n'
      printf 'debug.hwui.webview_overlays_enabled=true\n'
      printf 'debug.hwui.skia_tracing_enabled=false\n'
      printf 'debug.hwui.skia_use_perfetto_track_events=false\n'
      printf 'debug.hwui.capture_skp_enabled=false\n'
      printf 'debug.hwui.skia_atrace_enabled=false\n'
      printf 'debug.hwui.use_hint_manager=true\n'
      printf 'debug.hwui.target_cpu_time_percent=33\n'  # 33% CPU, 67% GPU — optimal for Vulkan async cmd buffer thread
      # debug.vulkan.layers=  (empty) — clear OEM profiler/debug layers that
      # fail dlopen on custom Adreno driver ABI → every app crashes at Vulkan init
      printf 'debug.vulkan.layers=\n'
      # ro.hwui.use_vulkan=true — MIUI/HyperOS gate for skiavk renderer path
      printf 'ro.hwui.use_vulkan=true\n'
      # recycled_buffer_cache_size=4 — AOSP default. Value of 2 causes constant
      # VkBuffer reallocation in complex UIs → OOM spikes → crash
      printf 'debug.hwui.recycled_buffer_cache_size=4\n'
      # overdraw/profile/show_dirty_regions=false — disable OEM debug Vulkan passes
      printf 'debug.hwui.overdraw=false\n'
      printf 'debug.hwui.profile=false\n'
      printf 'debug.hwui.show_dirty_regions=false\n'
      # profiler.support=false — disable Snapdragon Profiler Vulkan intercept
      # layer (wrong internal ABI on custom drivers → SIGSEGV on vkQueueSubmit)
      printf 'graphics.gpu.profiler.support=false\n'
      # multifile=true — per-process cache files prevent concurrent write
      # corruption that causes EGL init failures on custom Adreno drivers
      printf 'ro.egl.blobcache.multifile=true\n'
      # multifile_limit — 32MB cap prevents unbounded growth → I/O stalls
      printf 'ro.egl.blobcache.multifile_limit=33554432\n'
      # render_thread=true — ensure HWUI runs on async render thread (default,
      # explicit to override any OEM build.prop that disables it)
      printf 'debug.hwui.render_thread=true\n'
      # render_dirty_regions=false — disable HWUI-level partial invalidates;
      # paired with use_partial_updates=false for clean full-frame Vulkan submits
      printf 'debug.hwui.render_dirty_regions=false\n'
      # show_layers_updates=false — disable layer update debug overlay
      printf 'debug.hwui.show_layers_updates=false\n'
      # filter_test_overhead=false — disable test overhead instrumentation hook
      printf 'debug.hwui.filter_test_overhead=false\n'
      # nv_profiling=false — disable NVidia PerfHUD ES hooks (no-op on Adreno
      # but prevents any profiling intercept attempt at VkInstance creation)
      printf 'debug.hwui.nv_profiling=false\n'
      # 8bit_hdr_headroom=false — disable 8-bit HDR headroom expansion pipeline
      printf 'debug.hwui.8bit_hdr_headroom=false\n'
      # skip_eglmanager_telemetry=true — skip EGL telemetry init overhead
      # at RenderThread startup (confirmed AOSP feature flag prop)
      printf 'debug.hwui.skip_eglmanager_telemetry=true\n'
      # initialize_gl_always=false — do NOT pre-load GL at Zygote when Vulkan is active.
      # true loads both drivers → ~20MB extra RAM per app process → OOM on heavy apps.
      printf 'debug.hwui.initialize_gl_always=false\n'
      # level=0 — kDebugDisabled: disable HWUI cache/memory debug logging
      printf 'debug.hwui.level=0\n'
      # disable_vsync=false — explicitly neutralize dangerous OEM/custom ROM
      # props that set hwui.disable_vsync=true, which causes unbounded frame
      # submission → GPU command queue overflow → crash/stall under Vulkan
      printf 'debug.hwui.disable_vsync=false\n'
      # usap_pool_enabled=true — USAP (Unspecialized App Process) pre-fork pool.
      # Zygote maintains warm processes ready to specialize → faster cold-start
      printf 'persist.device_config.runtime_native.usap_pool_enabled=true\n'
      # gralloc.enable_fb_ubwc=1 — UBWC (Unified Buffer/Bandwidth Compression)
      # for the framebuffer surface on Adreno. Reduces GPU↔RAM bandwidth 30-50%
      # for every frame composited by SurfaceFlinger. Confirmed CAF Gralloc prop
      printf 'debug.gralloc.enable_fb_ubwc=1\n'
      # topAppRenderThreadBoost — Qualcomm PerfLock: elevates render thread of
      # the foreground app in kernel scheduler using SCHED_BOOST mechanism
      printf 'persist.sys.perf.topAppRenderThreadBoost.enable=true\n'
      # gpu.working_thread_priority=1 — elevate GPU driver kernel thread to
      # highest priority class; reduces GPU command dispatch latency for Vulkan
      printf 'persist.sys.gpu.working_thread_priority=1\n'
      # Phase offset props omitted — SM8150-specific values (500µs SF,
      # 3ms GL) cause vsync starvation on other Qualcomm SoCs (Adreno 6xx/7xx
      # at 90/120Hz) → systematic frame drops → watchdog → reboot loop.
      # Device tree already contains correct tuned values for each SoC.
      # use_skia_graphite=false — Android 15+ experimental Graphite Skia backend.
      # Conflicts with custom Adreno Vulkan drivers (different extension surface).
      # Must be explicitly disabled; some AOSP-based ROMs enable it by default.
      printf 'debug.hwui.use_skia_graphite=false\n'
      # blur: NOT disabled in SkiaVK. Blanket disable causes Samsung/MIUI UI regression.
      # Only disable if a specific device reports Vulkan blur compute crashes.
      printf 'ro.sf.blurs_are_expensive=1\n'
      # vendor.gralloc.enable_fb_ubwc=1 — CAF gralloc4 uses vendor. namespace
      printf 'vendor.gralloc.enable_fb_ubwc=1\n'
      # ro.config.vulkan.enabled=true — Samsung One UI explicit Vulkan enable gate.
      printf 'ro.config.vulkan.enabled=true\n'
      # persist.vendor.vulkan.enable=1 — MIUI/HyperOS internal vendor Vulkan enable.
      printf 'persist.vendor.vulkan.enable=1\n'
      # disable_pre_rotation: NOT set. UE4/Unity handle pre-rotation in projection matrix.
      # Setting true → VkSurfaceCapabilitiesKHR dimension mismatch → VK_ERROR_OUT_OF_DATE_KHR
      # loop → crash on launch (PUBG Mobile, CoD Mobile, Fortnite).
      # debug.hwui.force_dark=false — belt-and-suspenders override for render-mode.
      printf 'debug.hwui.force_dark=false\n'
      # ── Text atlas: AOSP defaults restored ──
      # Reduction to 512×256/1024×512 caused glyph overflow → font corruption → HWUI crash
      printf 'ro.hwui.text_small_cache_width=1024\n'
      printf 'ro.hwui.text_small_cache_height=512\n'
      printf 'ro.hwui.text_large_cache_width=2048\n'
      printf 'ro.hwui.text_large_cache_height=1024\n'
      # Shadow/gradient cache: reduce peak VRAM budget
      printf 'ro.hwui.drop_shadow_cache_size=3\n'
      printf 'ro.hwui.gradient_cache_size=1\n'
      # native_mode=0: NOT set. Forces sRGB globally, disables HDR/WCG on capable displays.
      # Samsung/Xiaomi WCG: map BT.601/170M → VK_COLOR_SPACE_SRGB_NONLINEAR_KHR
      printf 'debug.sf.treat_170m_as_sRGB=1\n'
      # Clear OEM EGL debug hook (MIUI/HyperOS/ColorOS ABI mismatch → SIGSEGV in libvulkan)
      printf 'debug.egl.debug_proc=\n'
      # ── HWUI render caches — reduce texture/layer/path upload stalls ──────────
      # These props are stripped on every boot but never re-set, causing sub-optimal
      # system defaults (24MB/16MB/4MB). Values below are 2-3× defaults, safe for
      # mid/high-end Adreno devices with 3GB+ RAM.
      printf 'debug.hwui.texture_cache_size=72\n'
      printf 'debug.hwui.layer_cache_size=48\n'
      printf 'debug.hwui.path_cache_size=32\n'
    } >> "$SYSTEM_PROP_FILE" 2>/dev/null
    log_boot "[OK] system.prop: skiavk props written (65 props). disable_pre_rotation and native_mode REMOVED (fixed PUBG/UE4/game crashes). Blur ENABLED. Text cache AOSP defaults restored."
    # Apply live for this boot session via resetprop
    # ── CRITICAL: renderer props set ONLY via resetprop, NEVER system.prop ──
    # This ensures the renderer is only activated AFTER the module's Vulkan
    # driver overlay is mounted, preventing crashes on legacy/OEM devices where
    # system.prop is loaded before module overlays are applied.
    if [ "$FIRST_BOOT_PENDING" = "true" ]; then
      log_boot "[OK] FIRST BOOT: renderer props deferred — NOT applying skiavk this boot (Vulkan not yet validated)"
      log_boot "     All other props (SF/HWUI tweaks) applied via resetprop for system stability"
    fi
    if command -v resetprop >/dev/null 2>&1; then
      # ── Both skiavk and skiavk_all: set SF compositor to skiavkthreaded ────────
      # debug.renderengine.backend controls SurfaceFlinger's compositor engine,
      # entirely separate from HWUI (debug.hwui.renderer controls app rendering).
      # skiavkthreaded = SKIA_VK_THREADED (enum 6, RenderEngine.h) — SF composites
      # using Vulkan via a dedicated RenderThread. Implemented in Android 14
      # (SkiaVkRenderEngine.cpp); required default in Android 15+. Setting it
      # here (pre-SF, post-fs-data) is safe. Setting it after SF starts triggers
      # OEM property watchers → RenderEngine reinit mid-frame → SF crash.
      if [ "$FIRST_BOOT_PENDING" = "false" ]; then
        resetprop debug.hwui.renderer skiavk
        # debug.renderengine.backend: set via resetprop BEFORE SF starts.
        # skiavkthreaded = SkiaVkRenderEngine (Android 14+ / API 34+).
        # skiaglthreaded = fallback threaded GL compositor (all Android versions).
        # DO NOT set this live in service.sh — SF is running, OEM ROM property
        # watchers fire a RenderEngine reinit mid-frame → SF crash → watchdog reboot.
        # DO NOT set in system.prop alone (loaded before module overlays mount →
        # no Vulkan driver present → SF silently falls back, ignoring the prop).
        # Here (post-fs-data, pre-SF) is the only safe window to set it.
        #
        # Gate: API >= 34 OR FORCE_SKIAVKTHREADED_BACKEND=y (user override).
        # On Android < 14: OEM SFs reject unknown backend strings → bootloop.
        # Only bypass if FORCE flag is set AND .boot_success confirmed safe.
        _re_sdk=$(getprop ro.build.version.sdk 2>/dev/null || echo "0")
        _re_threaded_ok=false
        if [ "$_re_sdk" -ge 34 ] 2>/dev/null; then
          _re_threaded_ok=true
        elif [ "$FORCE_SKIAVKTHREADED_BACKEND" = "y" ]; then
          _re_threaded_ok=true
          log_boot "[WARN] FORCE_SKIAVKTHREADED_BACKEND=y: SDK=${_re_sdk} < 34 — skiavkthreaded forced by user (bootloop risk on strict OEM ROMs)"
        fi
        if [ "$_re_threaded_ok" = "true" ]; then
          if [ -f "$MODDIR/.boot_success" ]; then
            # Previous boot reached boot_completed with skiavk active — safe to enable
            resetprop debug.renderengine.backend skiavkthreaded
            log_boot "[OK] renderengine.backend=skiavkthreaded: .boot_success confirmed, SDK=${_re_sdk}$([ "$FORCE_SKIAVKTHREADED_BACKEND" = "y" ] && echo " (FORCED)")"
          else
            # First real boot after install, or previous boot froze before boot_completed.
            # Use skiaglthreaded so SF starts cleanly. Next boot promotes to skiavkthreaded.
            resetprop debug.renderengine.backend skiaglthreaded
            log_boot "[SAFE] renderengine.backend=skiaglthreaded: no .boot_success — safe GL backend this boot"
            log_boot "       skiavkthreaded activates next boot after service.sh writes .boot_success"
          fi
        else
          log_boot "[SKIP] skiavkthreaded backend: SDK=${_re_sdk} < 34, SkiaVkRenderEngine absent — using skiaglthreaded fallback"
          resetprop debug.renderengine.backend skiaglthreaded
        fi
        unset _re_sdk _re_threaded_ok
      fi
      # ── Dangerous SF props INTENTIONALLY NOT SET via resetprop ──────────────
      # (latch_unsignaled, disable_backpressure, disable_triple_buffer, etc.)
      # See system.prop comment above for root cause. These are DELETED below
      # (in case they were set by a previous module version).
      for _bad_sf in debug.sf.latch_unsignaled debug.sf.auto_latch_unsignaled \
                     debug.sf.disable_backpressure debug.sf.enable_hwc_vds \
                     ro.sf.disable_triple_buffer debug.sf.client_composition_cache_size \
                     debug.sf.enable_transaction_tracing \
                     ro.surface_flinger.use_context_priority \
                     ro.surface_flinger.max_frame_buffer_acquired_buffers \
                     ro.surface_flinger.force_hwc_copy_for_virtual_displays \
                     debug.sf.use_phase_offsets_as_durations; do
        resetprop --delete "$_bad_sf" 2>/dev/null || true
      done
      # clip_surfaceviews: delete to restore AOSP default (true).
      # If an OEM ROM set this to false, SurfaceView content (camera preview,
      # video player) bleeds outside its parent window bounds.
      resetprop --delete debug.hwui.clip_surfaceviews 2>/dev/null || true
      resetprop com.qc.hardware true
      resetprop persist.sys.force_sw_gles 0
      resetprop debug.hwui.use_buffer_age false
      resetprop debug.hwui.use_partial_updates false
      resetprop debug.hwui.use_gpu_pixel_buffers false
      # reduceopstasksplitting=false — AOSP default. true causes rendering artifacts
      # in apps with complex Canvas/Skia operations (maps, e-readers, game UI overlays).
      resetprop renderthread.skia.reduceopstasksplitting false
      resetprop debug.hwui.skip_empty_damage true
      resetprop debug.hwui.webview_overlays_enabled true
      resetprop debug.hwui.skia_tracing_enabled false
      resetprop debug.hwui.skia_use_perfetto_track_events false
      resetprop debug.hwui.capture_skp_enabled false
      resetprop debug.hwui.skia_atrace_enabled false
      resetprop debug.hwui.use_hint_manager true
      resetprop debug.hwui.target_cpu_time_percent 33  # 33% CPU, 67% GPU — optimal for skiavk HWUI + skiavkthreaded SF
      resetprop debug.vulkan.layers ""
      resetprop ro.hwui.use_vulkan true
      resetprop debug.hwui.recycled_buffer_cache_size 4
      resetprop debug.hwui.overdraw false
      resetprop debug.hwui.profile false
      resetprop debug.hwui.show_dirty_regions false
      resetprop graphics.gpu.profiler.support false
      resetprop ro.egl.blobcache.multifile true
      resetprop ro.egl.blobcache.multifile_limit 33554432
      resetprop debug.hwui.render_thread true
      resetprop debug.hwui.render_dirty_regions false
      resetprop debug.hwui.show_layers_updates false
      resetprop debug.hwui.filter_test_overhead false
      resetprop debug.hwui.nv_profiling false
      resetprop debug.hwui.8bit_hdr_headroom false
      resetprop debug.hwui.skip_eglmanager_telemetry true
      resetprop debug.hwui.initialize_gl_always false
      resetprop debug.hwui.level 0
      resetprop debug.hwui.disable_vsync false
      resetprop persist.device_config.runtime_native.usap_pool_enabled true
      resetprop debug.gralloc.enable_fb_ubwc 1
      resetprop persist.sys.perf.topAppRenderThreadBoost.enable true
      resetprop persist.sys.gpu.working_thread_priority 1
      # Phase offset resetprops omitted — SM8150-specific values cause vsync starvation on other SoCs (see printf block above)
      resetprop debug.hwui.use_skia_graphite false
      # blur: NOT disabled — blanket disable breaks Samsung/MIUI UI. Clean up if previously set.
      resetprop --delete ro.surface_flinger.supports_background_blur 2>/dev/null || true
      resetprop --delete persist.sys.sf.disable_blurs 2>/dev/null || true
      resetprop ro.sf.blurs_are_expensive 1
      resetprop vendor.gralloc.enable_fb_ubwc 1
      resetprop ro.config.vulkan.enabled true
      resetprop persist.vendor.vulkan.enable 1
      # disable_pre_rotation: NOT set. Causes VK_ERROR_OUT_OF_DATE_KHR crash in UE4/Unity games.
      # Explicitly DELETE it so any value left by a previous module version is cleared.
      resetprop --delete persist.graphics.vulkan.disable_pre_rotation 2>/dev/null || true
      resetprop debug.hwui.force_dark false
      # ── Text atlas: AOSP defaults (glyph overflow → crash fix) ──────────────
      resetprop ro.hwui.text_small_cache_width 1024
      resetprop ro.hwui.text_small_cache_height 512
      resetprop ro.hwui.text_large_cache_width 2048
      resetprop ro.hwui.text_large_cache_height 1024
      resetprop ro.hwui.drop_shadow_cache_size 3
      resetprop ro.hwui.gradient_cache_size 1
      # native_mode: NOT set. Disables HDR/WCG on capable displays.
      resetprop debug.sf.treat_170m_as_sRGB 1
      resetprop debug.egl.debug_proc ""
      # ── OEM-override-resistant props ─────────────────────────────────────
      resetprop debug.sf.hw 1
      resetprop persist.sys.ui.hw 1
      resetprop debug.egl.hw 1
      resetprop debug.egl.profiler 0
      resetprop debug.egl.trace 0
      resetprop debug.vulkan.dev.layers ""
      resetprop persist.graphics.vulkan.validation_enable 0
      resetprop debug.hwui.drawing_enabled true
      resetprop hwui.disable_vsync false
      # ── HWUI render caches — reduce texture/layer/path upload stalls ─────
      resetprop debug.hwui.texture_cache_size 72
      resetprop debug.hwui.layer_cache_size 48
      resetprop debug.hwui.path_cache_size 32
      # ── Strip dangerous OEM props that must never be active ───────────────
      resetprop --delete debug.vulkan.layers.enable 2>/dev/null || true
    fi
    log_boot "[OK] skiavk + SF + stability + OEM compat + EGL + perf + legacy-compat + blur-disable + vendor-gralloc + Samsung/MIUI Vulkan gates + pre-rotation fix + cache sizing + VK crash-fix + phase-offsets props applied live (78+ props)"

    # ══════════════════════════════════════════════════════════════════════════
    # OLD VENDOR DETECTION + PROP WATCHDOG (post-fs-data phase)
    # ══════════════════════════════════════════════════════════════════════════
    #
    # PROBLEM — Why old vendor kills skiavk with no error:
    #
    #   Android property loading order (init source, system/core/init):
    #     1. /system/build.prop        (system partition)
    #     2. /vendor/build.prop        ← loaded AFTER system, HIGHER precedence
    #     3. persist.* props from /data
    #
    #   An old vendor's /vendor/build.prop may contain:
    #     debug.hwui.renderer=skiagl   ← loaded AFTER our system.prop skiavk
    #   Result: skiagl wins the static prop load, despite our system.prop skiavk.
    #
    #   Our resetprop (above) fixes it for THIS process context. But vendor's
    #   init.rc late_start services can call setprop again at any time AFTER
    #   init fires those services (which is after post-fs-data). The prop flips
    #   back to skiagl before Zygote forks any app process → all apps start GL.
    #
    #   Additionally: old Vulkan stacks (API 11 vendor on API 14 system) may
    #   not support VK_KHR_timeline_semaphore, VK_KHR_dynamic_rendering, or
    #   other extensions the custom Adreno driver declares as required. The
    #   Vulkan loader returns VK_ERROR_EXTENSION_NOT_PRESENT on vkCreateDevice
    #   → HWUI silently falls back to GL → "skiavk but all apps crash" symptom.
    #
    # SOLUTION — Two-part approach:
    #   Part 1 (this block): detect old vendor and persist the result.
    #   Part 2 (background subshell): watch for the prop being overridden by
    #          vendor_init late services; re-apply skiavk immediately each time.
    #          Runs for 90s from boot_completed — covers the entire vendor_init
    #          service window on even the slowest custom ROMs.
    # ══════════════════════════════════════════════════════════════════════════

    if [ "$FIRST_BOOT_PENDING" = "false" ] && command -v resetprop >/dev/null 2>&1; then

      detect_old_vendor_extended

      _OLD_VENDOR_FILE="/data/local/tmp/adreno_old_vendor"

      if [ "$OLD_VENDOR" = "true" ]; then
        log_boot "========================================"
        log_boot "OLD VENDOR DETECTED"
        log_boot "========================================"
        log_boot "  Conflicting hwui prop : '${VENDOR_HWUI_PROP:-<not found in any build.prop>}'"
        log_boot "  Offending init.rc     : '${VENDOR_RC_OVERRIDE:-<none found>}'"
        log_boot "  Offending script      : '${VENDOR_SCRIPT_OVERRIDE:-<none found>}'"
        log_boot "  Reason                : $OLD_VENDOR_REASON"
        log_boot "  Impact                : vendor/odm/product build.props load AFTER system.prop;"
        log_boot "                          init.rc on-property triggers fire AFTER our resetprop"
        log_boot "  Mitigation            : post-fs-data watchdog + service.sh persistent re-enforcement"
        log_boot "========================================"

        # Persist detection result for service.sh and the Vulkan probe
        printf '%s\n' "$OLD_VENDOR_REASON" > "$_OLD_VENDOR_FILE" 2>/dev/null || true

        # If any partition build.prop has a conflicting renderer, re-apply skiavk now
        if [ -n "$VENDOR_HWUI_PROP" ] && [ "$VENDOR_HWUI_PROP" != "skiavk" ]; then
          resetprop debug.hwui.renderer skiavk 2>/dev/null || true
          resetprop ro.hwui.use_vulkan true 2>/dev/null || true
          log_boot "[OK] Re-applied skiavk over conflicting build.prop value '${VENDOR_HWUI_PROP}'"
        fi

        # ── Background prop watchdog (post-fs-data phase) ────────────────────
        # This fires early — before Zygote — and keeps re-applying the prop
        # every 3s until boot_completed+30s. Covers the vendor_init service
        # window when old vendor late_start services override our prop.
        # Runs in a detached subshell so it never blocks post-fs-data.
        (
          _w_applied=0
          _w_wait=0
          # Phase 1: pre-boot_completed — check every 3s for up to 90s
          while [ "$_w_wait" -lt 90 ]; do
            sleep 3
            _w_wait=$((_w_wait + 3))
            _cur=$(getprop debug.hwui.renderer 2>/dev/null || echo "")
            if [ "$_cur" != "skiavk" ]; then
              resetprop debug.hwui.renderer skiavk 2>/dev/null || true
              _w_applied=$((_w_applied + 1))
              echo "[ADRENO-OLDVENDOR][pre-boot][${_w_wait}s] vendor_init override detected! Was '${_cur}', re-applied skiavk (override #${_w_applied})" > /dev/kmsg 2>/dev/null || true
            fi
            [ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ] && break
          done
          # Phase 2: post-boot_completed — check every 5s for 60 more seconds
          _w2_wait=0
          while [ "$_w2_wait" -lt 60 ]; do
            sleep 5
            _w2_wait=$((_w2_wait + 5))
            _cur=$(getprop debug.hwui.renderer 2>/dev/null || echo "")
            if [ "$_cur" != "skiavk" ]; then
              resetprop debug.hwui.renderer skiavk 2>/dev/null || true
              _w_applied=$((_w_applied + 1))
              echo "[ADRENO-OLDVENDOR][post-boot][${_w2_wait}s] vendor_init late override! Was '${_cur}', re-applied skiavk (override #${_w_applied})" > /dev/kmsg 2>/dev/null || true
            fi
          done
          # Final summary to kmsg for debugging
          echo "[ADRENO-OLDVENDOR] Watchdog complete. Total re-applications: ${_w_applied}" > /dev/kmsg 2>/dev/null || true
        ) &
        log_boot "[OK] Old-vendor prop watchdog launched (PID=$!) — re-enforces skiavk if vendor_init overrides it"

      else
        log_boot "Old vendor check: CLEAN (SDK_DELTA=${SDK_DELTA}, vendor/build.prop hwui='${VENDOR_HWUI_PROP:-<none>}')"
        # Write clean state — service.sh reads this to skip old-vendor extra work
        printf 'clean\n' > "$_OLD_VENDOR_FILE" 2>/dev/null || true
      fi
      unset _OLD_VENDOR_FILE
    fi
    # ══ END OLD VENDOR DETECTION ═════════════════════════════════════════════

    # ── BACKGROUND RESTART TASK ──────────────────────────────────────────────
    # After boot_completed, re-apply renderer props and crash SystemUI so it
    # cold-restarts with skiavk.
    #
    # Why needed: debug.hwui.renderer is read ONCE per process at first HWUI
    # init, then cached as a static var in Properties.cpp → sRenderPipelineType.
    # Any process that started before the prop was set is stuck on the old renderer
    # FOREVER until it dies and cold-restarts. Force-stopping 3rd-party apps
    # (boot+15s settle) makes them cold-start with skiavk cleanly.
    #
    # skiavk: force-stops 3rd-party apps (below) — RESTORED from old working files.
    # skiavk_all: also gets service.sh's additional system-package force-stop (boot+32s).
    # SystemUI is NOT crashed in any mode — that caused GMS account loss + watchdog reboots.
    if [ "$FIRST_BOOT_PENDING" = "false" ]; then
      (
        # Wait for boot_completed — max 90s.
        # Beyond 90s the user is actively using the device; any action that disrupts
        # running processes (like crashing SystemUI) would appear as an unexpected crash.
        # 90s is sufficient for any normally-booting device.
        _WAIT=0
        while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ] && [ $_WAIT -lt 90 ]; do
          sleep 3
          _WAIT=$((_WAIT + 3))
        done

        # SAFETY: bail out entirely if boot_completed never fired.
        # Never re-apply renderer props or crash SystemUI on a device that failed
        # to reach boot_completed — that state indicates a deeper boot problem.
        [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ] && exit 0

        # Re-apply debug.hwui.renderer (per-process HWUI prop — safe to resetprop live).
        # debug.renderengine.backend intentionally NOT set here: this subshell runs AFTER
        # boot_completed when SurfaceFlinger is already running. OEM ROMs fire a live
        # RenderEngine reinit callback when this prop changes at runtime → SF crash → reboot.
        # It is set safely before SF starts in the main post-fs-data.sh block above.
        if command -v resetprop >/dev/null 2>&1; then
          resetprop debug.hwui.renderer skiavk
        fi

        # ── FORCE-STOP 3RD-PARTY APPS (restored from old working approach) ──────────
        # ROOT CAUSE of "apps crash with skiavk even with prop set":
        # debug.hwui.renderer is read ONCE per process at first HWUI init and cached
        # as a static variable (sRenderPipelineType in RenderThread.cpp). Apps that
        # started during boot before this resetprop fired have the old renderer cached.
        # They also have a driver handle opened against whatever libs were active at
        # their startup — inconsistent with the custom Adreno libs now mounted.
        # Force-stopping makes them exit and cold-start: they read skiavk fresh,
        # initialize the Vulkan driver cleanly from scratch, and work correctly.
        # This is what the original working files did and why they worked.
        #
        # Settle 15s first so GMS AccountManager finishes OAuth token refresh
        # (takes 10-25s on MIUI/HyperOS/OneUI). Killing GMS mid-refresh sends
        # DeadObjectException → all Google accounts removed from Settings.
        #
        # Throttle 150ms: gives KGSL time to fully drain each context teardown
        # before the next SIGKILL — prevents concurrent teardown table corruption.
        #
        # SystemUI: NOT force-stopped. Force-stopping at boot+15s caused black
        # screens, GMS account loss, and Android watchdog reboots on custom ROMs.
        # SystemUI picks up skiavk on the NEXT reboot via system.prop.
        sleep 15
        pm list packages -3 2>/dev/null | while IFS=: read -r _ pkg; do
          pkg="${pkg%$'\r'}"
          # Skip GMS/GSF (OAuth mid-sync → account loss if killed), Meta
          # (ANativeWindow dangling ref), Play Store, core Android namespace.
          #
          # NOTE: UE4/native-Vulkan games (PUBG, CoD Mobile, Fortnite, Genshin)
          # are NO LONGER excluded here. The game-compatibility daemon (service.sh)
          # starts at boot_completed+2s and switches debug.hwui.renderer to skiagl
          # within 1s of any native-Vulkan game being detected in /proc. When the
          # user reopens a game after this force-stop, HWUI initialises with skiagl
          # (GL), not skiavk (Vulkan) — so no dual-VkDevice conflict occurs. The
          # original exclusion assumed HWUI would be skiavk at game launch, but the
          # daemon prevents that. Force-stopping here ensures games cold-start AFTER
          # the daemon is active, closing the race window on boot 2.
          #
          # The game package list is defined in game_exclusion_list.sh (sourced at
          # boot top) and is editable via the Adreno Manager WebUI. The daemon's
          # own /proc scanner (service.sh) still uses the full list independently.
          case "$pkg" in
            android*|com.android.*|com.google.*|\
            com.google.android.gms|com.google.android.gms.*|\
            com.google.android.gsf|com.google.android.gsf.*|\
            com.google.android.gmscore|com.android.vending|\
            com.facebook.katana|com.facebook.orca|com.facebook.lite|\
            com.facebook.mlite|com.instagram.android|com.instagram.lite|\
            com.whatsapp|com.whatsapp.w4b)
              continue ;;
          esac
          am force-stop "$pkg" 2>/dev/null || true
          sleep 0.15
        done

      ) >/dev/null 2>&1 &
      log_boot "[OK] skiavk background task: props re-applied + 3rd-party apps force-stopped to cold-start with skiavk renderer"
    fi

    # ── GAME EXCLUSION DAEMON LAUNCH ──────────────────────────────────────────
    # Launches the native adreno_ged binary if available (zero overhead),
    # falls back to game_excl_daemon.sh (shell, low overhead) if not.
    #
    # Native binary architecture (truly zero overhead):
    #   inotify on /proc: kernel wakes daemon only when a new process spawns.
    #   pidfd per game: kernel delivers death event exactly when game exits.
    #   epoll: single blocking wait covers all events. Zero CPU between events.
    #   No logcat pipe, no polling loop, no shell interpreter overhead.
    #
    # Shell fallback architecture (low overhead):
    #   logcat -b events: blocks in kernel between am_proc_start events.
    #   sleep 1 loop per active game: ~1 µs/sec CPU per game.
    if [ "$GAME_EXCLUSION_DAEMON" = "y" ] && [ "$FIRST_BOOT_PENDING" = "false" ]; then
      (
        # Wait for boot_completed before launching daemon.
        _GED_WAIT=0
        while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ] && [ $_GED_WAIT -lt 90 ]; do
          sleep 3
          _GED_WAIT=$((_GED_WAIT + 3))
        done
        [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ] && exit 0

        # Give ActivityManager 2 extra seconds to fully initialize.
        sleep 2

        # ── Try native binary first ──────────────────────────────────────────
        # Detect CPU ABI to pick the right binary.
        _GED_ABI="$(getprop ro.product.cpu.abi 2>/dev/null || echo '')"
        _GED_BIN=""
        case "$_GED_ABI" in
          arm64*|aarch64*)
            [ -x "${MODDIR}/bin/arm64-v8a/adreno_ged" ]   && _GED_BIN="${MODDIR}/bin/arm64-v8a/adreno_ged"
            ;;
          arm*|armeabi*)
            [ -x "${MODDIR}/bin/armeabi-v7a/adreno_ged" ] && _GED_BIN="${MODDIR}/bin/armeabi-v7a/adreno_ged"
            ;;
        esac

        if [ -n "$_GED_BIN" ]; then
          # Launch native binary: pass restore mode and MODDIR
          # MODDIR passed as $2 so binary can find game_exclusion_list.sh
          "$_GED_BIN" "$RENDER_MODE" "$MODDIR" &
          echo "[ADRENO] Game exclusion daemon (NATIVE) launched PID=$! binary=$_GED_BIN mode=$RENDER_MODE" \
            > /dev/kmsg 2>/dev/null || true
          exit 0
        fi

        # ── Shell fallback ───────────────────────────────────────────────────
        _GED_SCRIPT=""
        for _gp in \
            "/sdcard/Adreno_Driver/Config/game_excl_daemon.sh" \
            "${MODDIR}/game_excl_daemon.sh" \
            "/data/local/tmp/adreno_game_excl_daemon.sh"; do
          [ -f "$_gp" ] && [ -r "$_gp" ] && { _GED_SCRIPT="$_gp"; break; }
        done

        if [ -z "$_GED_SCRIPT" ]; then
          echo "[ADRENO] GAME_EXCLUSION_DAEMON=y but neither binary nor shell script found -- not started" \
            > /dev/kmsg 2>/dev/null || true
          exit 1
        fi

        /system/bin/sh "$_GED_SCRIPT" "$RENDER_MODE" &
        echo "[ADRENO] Game exclusion daemon (SHELL fallback) launched PID=$! script=$_GED_SCRIPT mode=$RENDER_MODE" \
          > /dev/kmsg 2>/dev/null || true
      ) &
      log_boot "[OK] Game exclusion daemon: scheduled for boot_completed+2s (GAME_EXCLUSION_DAEMON=y, mode=$RENDER_MODE)"
    elif [ "$GAME_EXCLUSION_DAEMON" = "n" ]; then
      log_boot "[SKIP] Game exclusion daemon: disabled (GAME_EXCLUSION_DAEMON=n)"
    fi
    ;;

  skiagl)
    {
      # Renderer props: hwui.renderer for per-process HWUI; renderengine.backend
      # for SurfaceFlinger compositor. Both persisted here for next boot.
      # renderengine.backend is also set via resetprop below (pre-SF, this boot).
      printf 'debug.hwui.renderer=skiagl\n'
      printf 'debug.renderengine.backend=skiaglthreaded\n'
      # force_sw_gles=0 — use hardware GLES (not software fallback)
      printf 'persist.sys.force_sw_gles=0\n'
      # Qualcomm hardware acceleration gate — enables Qualcomm ION buffer paths in gralloc
      printf 'com.qc.hardware=true\n'
      # buffer_age=false — EGL_EXT_buffer_age is unreliable on custom Adreno drivers;
      # incorrect buffer age values cause stale pixels (old frame content bleeding through
      # in partial-update regions). Use full-frame rendering for safety.
      printf 'debug.hwui.use_buffer_age=false\n'
      # use_partial_updates=false — EGL_KHR_partial_update similarly unreliable on
      # custom drivers; broken partial-update regions show old frame content to the user.
      printf 'debug.hwui.use_partial_updates=false\n'
      # render_dirty_regions=false — paired with use_partial_updates=false. Dirty region
      # tracking in HWUI depends on correct buffer age from EGL; disabling prevents
      # stale-pixel glitches on OEM EGL implementations with custom Adreno drivers.
      printf 'debug.hwui.render_dirty_regions=false\n'
      # WebView overlay compositing — GL mode supports this safely
      printf 'debug.hwui.webview_overlays_enabled=true\n'
      # reduceopstasksplitting=false — AOSP default. Setting true reduces Skia OpsTask
      # split granularity (larger GPU batches), causing rendering order failures and
      # visual artifacts in apps with complex custom draw operations. Leave at false.
      printf 'renderthread.skia.reduceopstasksplitting=false\n'
      # Disable all Skia tracing/profiling overhead in GL mode too
      printf 'debug.hwui.skia_tracing_enabled=false\n'
      printf 'debug.hwui.skia_use_perfetto_track_events=false\n'
      printf 'debug.hwui.capture_skp_enabled=false\n'
      printf 'debug.hwui.skia_atrace_enabled=false\n'
      # Disable debug overlays that add overhead
      printf 'debug.hwui.overdraw=false\n'
      printf 'debug.hwui.profile=false\n'
      printf 'debug.hwui.show_dirty_regions=false\n'
      printf 'debug.hwui.show_layers_updates=false\n'
      # EGL shader blob cache — prevent concurrent-write corruption on Adreno EGL
      printf 'ro.egl.blobcache.multifile=true\n'
      printf 'ro.egl.blobcache.multifile_limit=33554432\n'
      # render_thread=true — HWUI GL runs on async render thread (explicit for OEM overrides)
      printf 'debug.hwui.render_thread=true\n'
      # use_hint_manager=true — PerformanceHintManager CPU clock hints for GL thread
      printf 'debug.hwui.use_hint_manager=true\n'
      # target_cpu_time_percent=66 — GL workloads are more CPU-bound; 66% CPU / 34% GPU
      printf 'debug.hwui.target_cpu_time_percent=66\n'
      # skip_eglmanager_telemetry — skip EGL telemetry init overhead
      printf 'debug.hwui.skip_eglmanager_telemetry=true\n'
      # initialize_gl_always=false — CRASH FIX: system.prop sets ro.zygote.disable_gl_preload=true
      # to prevent Zygote pre-loading the stock (wrong) driver. If initialize_gl_always=true,
      # HWUI forces EGL init in EVERY process at startup — including NDK/game apps that also
      # initialize their own Vulkan context from a different thread. The custom Adreno driver
      # hits a race between HWUI's EGL context (created by HWUI's RenderThread) and the app's
      # Vulkan context (created by the game engine thread) → SIGSEGV in libEGL/libvulkan.
      # false = lazy EGL init: HWUI initializes GL only when it actually needs to render,
      # at which point the app's own GPU init is already complete. No conflict.
      printf 'debug.hwui.initialize_gl_always=false\n'
      # Disable EGL vsync (do not set hwui.disable_vsync — that's dangerous; use HWUI prop)
      printf 'debug.hwui.disable_vsync=false\n'
      # level=0 — no debug logging overhead
      printf 'debug.hwui.level=0\n'
      # UBWC framebuffer compression — reduces GL↔RAM bandwidth
      printf 'debug.gralloc.enable_fb_ubwc=1\n'
      printf 'vendor.gralloc.enable_fb_ubwc=1\n'
      # USAP pool — faster app cold-start
      printf 'persist.device_config.runtime_native.usap_pool_enabled=true\n'
      # Qualcomm PerfLock render thread boost
      printf 'persist.sys.perf.topAppRenderThreadBoost.enable=true\n'
      # GPU driver thread priority
      printf 'persist.sys.gpu.working_thread_priority=1\n'
      # Disable Android 15+ experimental Graphite backend
      printf 'debug.hwui.use_skia_graphite=false\n'
      # ── CRASH-FIX PROPS — same as skiavk, required in GL mode too ─────────────
      # graphics.gpu.profiler.support=false — CRITICAL: Snapdragon Profiler intercepts
      # BOTH GL and Vulkan calls. Custom Adreno driver has different internal function-pointer
      # table than what Snapdragon Profiler was compiled against. If the profiler attaches
      # (support=true), every intercepted GL call goes through a wrong function pointer →
      # SIGSEGV in libGLESv2. Must be explicitly false, not just deleted (deletion reverts
      # to OEM build.prop default which is often true on Snapdragon devices).
      printf 'graphics.gpu.profiler.support=false\n'
      # use_gpu_pixel_buffers=false — PBO (Pixel Buffer Object) readback race condition exists
      # in custom Adreno firmware for GL path too, not only Vulkan. The race triggers during
      # screenshots and multitasking card animations: PBO fence not yet signaled when CPU
      # tries to read pixel data → use-after-free in RenderThread → SIGSEGV.
      printf 'debug.hwui.use_gpu_pixel_buffers=false\n'
      # recycled_buffer_cache_size=4 — AOSP default. OEM builds sometimes ship value=2,
      # causing constant GL buffer realloc under memory pressure → OOM spike → crash.
      printf 'debug.hwui.recycled_buffer_cache_size=4\n'
      # skip_empty_damage=true — skip GL command submission for undamaged frames
      printf 'debug.hwui.skip_empty_damage=true\n'
      # 8bit_hdr_headroom=false — disable 8-bit HDR pipeline (unnecessary overhead in GL mode)
      printf 'debug.hwui.8bit_hdr_headroom=false\n'
      # nv_profiling=false — disable NVidia PerfHUD ES hooks (no-op on Adreno but prevents
      # any GL interception attempt that could conflict with custom driver)
      printf 'debug.hwui.nv_profiling=false\n'
      # filter_test_overhead=false — disable test overhead instrumentation hook
      printf 'debug.hwui.filter_test_overhead=false\n'
      # blur: ENABLED in SkiaGL — GL blur uses standard EGL paths, no Vulkan compute needed.
      # Disabling breaks WindowBlurBehind on Samsung One UI / MIUI.
      # ── HWUI render caches — reduce texture/layer/path upload stalls in GL mode ──
      printf 'debug.hwui.texture_cache_size=72\n'
      printf 'debug.hwui.layer_cache_size=48\n'
      printf 'debug.hwui.path_cache_size=32\n'
    } >> "$SYSTEM_PROP_FILE" 2>/dev/null
    log_boot "[OK] system.prop: skiagl stability+perf+compat+crash-fix props written (49 props). initialize_gl_always=false (crash fix), profiler.support=false (Snapdragon profiler crash fix), use_gpu_pixel_buffers=false (PBO race fix). Blur ENABLED."
    if command -v resetprop >/dev/null 2>&1; then
      # ── renderer props set ONLY via resetprop (see skiavk section for why) ──
      if [ "$FIRST_BOOT_PENDING" = "false" ]; then
        resetprop debug.hwui.renderer skiagl
        resetprop debug.renderengine.backend skiaglthreaded
      fi
      resetprop persist.sys.force_sw_gles 0
      resetprop com.qc.hardware true
      # use_buffer_age=false — EGL_EXT_buffer_age unreliable on custom Adreno drivers
      resetprop debug.hwui.use_buffer_age false
      # use_partial_updates=false — EGL_KHR_partial_update unreliable on custom drivers
      resetprop debug.hwui.use_partial_updates false
      # render_dirty_regions=false — paired with above to prevent stale-pixel glitches
      resetprop debug.hwui.render_dirty_regions false
      resetprop debug.hwui.webview_overlays_enabled true
      # reduceopstasksplitting=false — AOSP default; true causes rendering artifacts
      resetprop renderthread.skia.reduceopstasksplitting false
      resetprop debug.hwui.skia_tracing_enabled false
      resetprop debug.hwui.skia_use_perfetto_track_events false
      resetprop debug.hwui.capture_skp_enabled false
      resetprop debug.hwui.skia_atrace_enabled false
      resetprop debug.hwui.overdraw false
      resetprop debug.hwui.profile false
      resetprop debug.hwui.show_dirty_regions false
      resetprop debug.hwui.show_layers_updates false
      resetprop ro.egl.blobcache.multifile true
      resetprop ro.egl.blobcache.multifile_limit 33554432
      resetprop debug.hwui.render_thread true
      resetprop debug.hwui.use_hint_manager true
      resetprop debug.hwui.target_cpu_time_percent 66
      resetprop debug.hwui.skip_eglmanager_telemetry true
      # initialize_gl_always=false — CRASH FIX (see system.prop comment above):
      # ro.zygote.disable_gl_preload=true prevents stock driver preloading in Zygote.
      # initialize_gl_always=true would then force EGL init in every process including
      # NDK/game apps, causing double-init race with their own Vulkan context → SIGSEGV.
      resetprop debug.hwui.initialize_gl_always false
      resetprop debug.hwui.disable_vsync false
      resetprop debug.hwui.level 0
      resetprop debug.gralloc.enable_fb_ubwc 1
      resetprop vendor.gralloc.enable_fb_ubwc 1
      resetprop persist.device_config.runtime_native.usap_pool_enabled true
      resetprop persist.sys.perf.topAppRenderThreadBoost.enable true
      resetprop persist.sys.gpu.working_thread_priority 1
      resetprop debug.hwui.use_skia_graphite false
      # blur: ENABLED in SkiaGL — GL blur uses standard EGL paths, works correctly.
      # Clean up any skiavk residue that may have been set previously.
      resetprop --delete ro.surface_flinger.supports_background_blur 2>/dev/null || true
      resetprop --delete persist.sys.sf.disable_blurs 2>/dev/null || true
      # ── Stability + crash-fix props: POSITIVE SET (NOT deleted) ──────────────
      # These were previously in the delete loop below, causing them to be wiped
      # after the positive sets above — a bug where the delete loop undid everything.
      # CRASH FIX: graphics.gpu.profiler.support MUST be explicitly false, not deleted.
      # Deletion reverts to OEM build.prop default (often true on Snapdragon devices),
      # re-enabling Snapdragon Profiler GL intercept with wrong ABI → SIGSEGV.
      resetprop graphics.gpu.profiler.support false
      # CRASH FIX: use_gpu_pixel_buffers MUST be explicitly false, not deleted.
      # Deletion re-enables PBO readback which has a race condition in custom Adreno
      # firmware on the GL path (same as Vulkan path) → SIGSEGV during screenshots.
      resetprop debug.hwui.use_gpu_pixel_buffers false
      # recycled_buffer_cache_size=4: AOSP default; prevents OOM from constant realloc
      resetprop debug.hwui.recycled_buffer_cache_size 4
      # These were being set then immediately deleted by the loop below — fixed:
      resetprop debug.hwui.skip_empty_damage true
      resetprop debug.hwui.filter_test_overhead false
      resetprop debug.hwui.nv_profiling false
      resetprop debug.hwui.8bit_hdr_headroom false
      # ── OEM-override-resistant props (skiagl) ────────────────────────────
      resetprop debug.sf.hw 1
      resetprop persist.sys.ui.hw 1
      resetprop debug.egl.hw 1
      resetprop debug.egl.profiler 0
      resetprop debug.egl.trace 0
      resetprop debug.vulkan.dev.layers ""
      resetprop persist.graphics.vulkan.validation_enable 0
      resetprop debug.hwui.drawing_enabled true
      resetprop hwui.disable_vsync false
      # HWUI render caches — reduce texture/layer/path upload stalls in GL mode
      resetprop debug.hwui.texture_cache_size 72
      resetprop debug.hwui.layer_cache_size 48
      resetprop debug.hwui.path_cache_size 32
      # Only delete props that are EXCLUSIVELY used by skiavk and have no GL equivalent.
      for _p in \
                 ro.hwui.use_vulkan \
                 debug.vulkan.layers \
                 debug.vulkan.layers.enable \
                 debug.hwui.clip_surfaceviews \
                 ro.surface_flinger.use_context_priority \
                 ro.surface_flinger.max_frame_buffer_acquired_buffers \
                 ro.surface_flinger.force_hwc_copy_for_virtual_displays \
                 debug.sf.latch_unsignaled \
                 debug.sf.auto_latch_unsignaled \
                 debug.sf.disable_backpressure \
                 debug.sf.enable_hwc_vds \
                 ro.sf.disable_triple_buffer \
                 debug.sf.client_composition_cache_size \
                 debug.sf.enable_transaction_tracing \
                 debug.sf.early_phase_offset_ns \
                 debug.sf.early_app_phase_offset_ns \
                 debug.sf.early_gl_phase_offset_ns \
                 debug.sf.early_gl_app_phase_offset_ns \
                 debug.sf.use_phase_offsets_as_durations \
                 ro.sf.blurs_are_expensive \
                 hwui.disable_vsync \
                 persist.sys.sf.native_mode \
                 debug.sf.treat_170m_as_sRGB \
                 ro.config.vulkan.enabled \
                 persist.vendor.vulkan.enable \
                 persist.graphics.vulkan.disable_pre_rotation \
                 ro.hwui.text_small_cache_width \
                 ro.hwui.text_small_cache_height \
                 ro.hwui.text_large_cache_width \
                 ro.hwui.text_large_cache_height \
                 ro.hwui.drop_shadow_cache_size \
                 ro.hwui.gradient_cache_size; do
        resetprop --delete "$_p" 2>/dev/null || true
      done
      unset _p
    fi
    log_boot "[OK] Render mode applied: skiagl"

    # ── BACKGROUND RESTART TASK (skiagl) ─────────────────────────────────────
    # After boot_completed, re-apply renderer props and crash SystemUI so it
    # restarts with skiagl. Rationale: debug.hwui.renderer is cached per-process.
    # SystemUI crash ensures the compositor uses skiagl correctly.
    # Third-party apps are NOT force-stopped in skiagl mode — they naturally adopt
    # skiagl on their next cold start and there is no "mixed state" problem in
    # GL mode (GL is always available as a fallback). Force-stopping was the
    # cause of "some apps crash" reports from users in skiagl mode.
    if [ "$FIRST_BOOT_PENDING" = "false" ]; then
      (
        # Max 90s wait. Beyond this the user is actively using the device —
        # any disruptive action (SystemUI crash) would appear as an unexpected crash.
        _WAIT=0
        while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ] && [ $_WAIT -lt 90 ]; do
          sleep 3
          _WAIT=$((_WAIT + 3))
        done

        # SAFETY: bail if boot never completed.
        [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ] && exit 0

        # Re-apply debug.hwui.renderer only — same rationale as skiavk subshell above.
        # debug.renderengine.backend NOT set here (SF is running, OEM watchers fire).
        if command -v resetprop >/dev/null 2>&1; then
          resetprop debug.hwui.renderer skiagl
        fi

        # ── FORCE-STOP 3RD-PARTY APPS (same rationale as skiavk above) ─────────────
        # Apps running with cached GL renderer / old driver state need a cold-start
        # to pick up skiagl cleanly. Same exclusions and throttle as skiavk above.
        sleep 15
        pm list packages -3 2>/dev/null | while IFS=: read -r _ pkg; do
          pkg="${pkg%$'\r'}"
          # Delegate to _game_pkg_excluded() — single source of truth for GMS,
          # Meta, and game exclusions. WebUI updates to game_exclusion_list.sh
          # are reflected here automatically without editing this block.
          if _game_pkg_excluded "$pkg"; then continue; fi
          am force-stop "$pkg" 2>/dev/null || true
          sleep 0.15
        done

      ) >/dev/null 2>&1 &
      log_boot "[OK] skiagl background task: props re-applied + 3rd-party apps force-stopped to cold-start with skiagl renderer"
    fi
    ;;

  skiavkthreaded)
    # ── LEGACY: skiavkthreaded was removed as a separate RENDER_MODE ─────────
    # common.sh normalizes this to 'skiavk' on load. This branch is only reached
    # if the config was written directly without going through common.sh.
    # Redirect to skiavk behaviour by falling through after normalization.
    log_boot "[LEGACY] RENDER_MODE=skiavkthreaded normalized to skiavk (renderengine.backend handled by skiavk block)"
    RENDER_MODE="skiavk"
    # Note: RENDER_MODE change here does NOT re-execute the skiavk case above.
    # The renderengine.backend will be set on next boot. Log for diagnostics.
    log_boot "         Reboot to apply renderengine.backend=skiavkthreaded (or skiaglthreaded fallback)"
    ;;

  skiaglthreaded)
    # ── LEGACY: skiaglthreaded was removed as a separate RENDER_MODE ─────────
    # common.sh normalizes this to 'skiagl' on load. Same as above.
    log_boot "[LEGACY] RENDER_MODE=skiaglthreaded normalized to skiagl (renderengine.backend=skiaglthreaded handled by skiagl block)"
    RENDER_MODE="skiagl"
    log_boot "         Reboot to apply renderengine.backend=skiaglthreaded via skiagl block"
    ;;

  normal|*)
    log_boot "[OK] system.prop: no render prop written (normal mode)"
    if command -v resetprop >/dev/null 2>&1; then
      for _p in debug.hwui.renderer debug.renderengine.backend \
                 debug.sf.latch_unsignaled debug.sf.auto_latch_unsignaled \
                 debug.sf.disable_backpressure debug.sf.enable_hwc_vds \
                 ro.sf.disable_triple_buffer debug.sf.client_composition_cache_size \
                 debug.sf.enable_transaction_tracing \
                 ro.surface_flinger.use_context_priority \
                 ro.surface_flinger.max_frame_buffer_acquired_buffers \
                 ro.surface_flinger.force_hwc_copy_for_virtual_displays \
                 com.qc.hardware persist.sys.force_sw_gles \
                 debug.hwui.use_buffer_age debug.hwui.use_partial_updates \
                 debug.hwui.use_gpu_pixel_buffers \
                 renderthread.skia.reduceopstasksplitting \
                 debug.hwui.skip_empty_damage debug.hwui.webview_overlays_enabled \
                 debug.hwui.skia_tracing_enabled \
                 debug.hwui.skia_use_perfetto_track_events \
                 debug.hwui.capture_skp_enabled \
                 debug.hwui.skia_atrace_enabled \
                 debug.hwui.use_hint_manager \
                 debug.hwui.target_cpu_time_percent \
                 debug.vulkan.layers ro.hwui.use_vulkan \
                 debug.hwui.recycled_buffer_cache_size \
                 debug.hwui.overdraw debug.hwui.profile \
                 debug.hwui.show_dirty_regions \
                 graphics.gpu.profiler.support \
                 ro.egl.blobcache.multifile \
                 ro.egl.blobcache.multifile_limit \
                 debug.hwui.render_dirty_regions debug.hwui.show_layers_updates \
                 debug.hwui.filter_test_overhead debug.hwui.nv_profiling \
                 debug.hwui.clip_surfaceviews debug.hwui.8bit_hdr_headroom \
                 debug.hwui.skip_eglmanager_telemetry \
                 debug.hwui.initialize_gl_always debug.hwui.level \
                 debug.hwui.disable_vsync hwui.disable_vsync \
                 debug.vulkan.layers.enable \
                 persist.device_config.runtime_native.usap_pool_enabled \
                 debug.gralloc.enable_fb_ubwc \
                 persist.sys.perf.topAppRenderThreadBoost.enable \
                 persist.sys.gpu.working_thread_priority \
                 debug.sf.early_phase_offset_ns debug.sf.early_app_phase_offset_ns \
                 debug.sf.early_gl_phase_offset_ns debug.sf.early_gl_app_phase_offset_ns \
                 debug.sf.use_phase_offsets_as_durations \
                 debug.hwui.use_skia_graphite ro.surface_flinger.supports_background_blur \
                 persist.sys.sf.disable_blurs ro.sf.blurs_are_expensive \
                 vendor.gralloc.enable_fb_ubwc \
                 persist.sys.sf.native_mode debug.sf.treat_170m_as_sRGB \
                 ro.config.vulkan.enabled persist.vendor.vulkan.enable \
                 persist.graphics.vulkan.disable_pre_rotation \
                 ro.hwui.text_small_cache_width ro.hwui.text_small_cache_height \
                 ro.hwui.text_large_cache_width ro.hwui.text_large_cache_height \
                 ro.hwui.drop_shadow_cache_size ro.hwui.gradient_cache_size; do
        resetprop --delete "$_p" 2>/dev/null || true
      done
      unset _p
    fi
    log_boot "[OK] Render mode: normal (system default)"
    ;;
esac

# ── BLOCK B CALL: apply gralloc compat props after all renderer resetprop calls ─
apply_gralloc_compat_props

log_boot "========================================"
log_boot "RENDER MODE APPLICATION COMPLETE"
log_boot "========================================"

# ========================================
# QGL CONFIGURATION INSTALLATION
# ========================================

if [ "$QGL" = "y" ]; then
  log_boot "Installing QGL configuration (ATOMIC operation)..."

  if [ -f "$MODDIR/qgl_config.txt" ]; then
    QGL_INSTALL_SUCCESS=false
    MAX_RETRIES=5
    RETRY_COUNT=0

    QGL_TARGET="/data/vendor/gpu/qgl_config.txt"
    QGL_TEMP="/data/vendor/gpu/.qgl_config.txt.tmp.$$"
    QGL_OWNER_MARKER="/data/vendor/gpu/.adreno_qgl_owner"

    if [ -f "$QGL_TARGET" ] && [ ! -f "$QGL_OWNER_MARKER" ]; then
      log_boot "[!] QGL: qgl_config.txt exists but was NOT installed by this module"
      log_boot "    Another manager owns this file — skipping install"
    else

    while [ $RETRY_COUNT -lt $MAX_RETRIES ] && [ "$QGL_INSTALL_SUCCESS" = "false" ]; do

      if touch /data/.adreno_test 2>/dev/null && rm /data/.adreno_test 2>/dev/null; then
        if mkdir -p /data/vendor/gpu 2>/dev/null; then
          if cp -f "$MODDIR/qgl_config.txt" "$QGL_TEMP" 2>/dev/null; then
            if [ -f "$QGL_TEMP" ] && [ -s "$QGL_TEMP" ]; then
              chmod 0644 "$QGL_TEMP" 2>/dev/null
              chown 0:1000 "$QGL_TEMP" 2>/dev/null
              if mv -f "$QGL_TEMP" "$QGL_TARGET" 2>/dev/null; then
                if [ -f "$QGL_TARGET" ] && [ -s "$QGL_TARGET" ]; then
                  chcon u:object_r:same_process_hal_file:s0 "$QGL_TARGET" 2>/dev/null || \
                    chcon u:object_r:vendor_data_file:s0 "$QGL_TARGET" 2>/dev/null || true
                  EXPECTED_SIZE=$(stat -c%s "$MODDIR/qgl_config.txt" 2>/dev/null || echo 0)
                  ACTUAL_SIZE=$(stat -c%s "$QGL_TARGET" 2>/dev/null || echo 0)
                  if [ "$EXPECTED_SIZE" -eq "$ACTUAL_SIZE" ] && [ "$ACTUAL_SIZE" -gt 0 ]; then
                    QGL_INSTALL_SUCCESS=true
                    touch "$QGL_OWNER_MARKER" 2>/dev/null || true
                    log_boot "QGL config installed ATOMICALLY (verified: $ACTUAL_SIZE bytes)"
                    log_boot "[OK] QGL owner marker created: $QGL_OWNER_MARKER"
                    break
                  else
                    log_boot "QGL verification failed (expected: $EXPECTED_SIZE, got: $ACTUAL_SIZE)"
                  fi
                fi
              else
                log_boot "QGL atomic rename failed, retrying..."
                rm -f "$QGL_TEMP" 2>/dev/null
              fi
            else
              log_boot "QGL temp file verification failed"
              rm -f "$QGL_TEMP" 2>/dev/null
            fi
          fi
        fi
      fi

      RETRY_COUNT=$((RETRY_COUNT + 1))
      if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
        log_boot "QGL install attempt $RETRY_COUNT failed, retrying in 1s..."
        sleep 1  # fixed: was sleep $((RETRY_COUNT * 2)) causing up to 20s blocking delay
      fi
    done

    rm -f "$QGL_TEMP" 2>/dev/null

    if [ "$QGL_INSTALL_SUCCESS" = "false" ]; then
      log_boot "ERROR: Failed to install QGL config after $MAX_RETRIES attempts"
      log_boot "GPU functionality may be degraded without QGL config"
    fi

    fi  # end of foreign-file safety check
  else
    log_boot "WARNING: QGL enabled but config file not found in module"
  fi
else
  log_boot "QGL configuration disabled"
fi

# ========================================
# PUBLIC LIBRARIES PATCHING (PLT)
# ========================================

if [ "$PLT" = "y" ]; then
  log_boot "Verifying PLT patches..."

  if [ -d "$MODDIR/system/vendor/etc" ]; then
    PLT_COUNT=0
    for _pf in "$MODDIR/system/vendor/etc"/public.libraries*.txt; do [ -f "$_pf" ] && PLT_COUNT=$((PLT_COUNT+1)); done
    log_boot "PLT files in module vendor/etc: $PLT_COUNT"
    if [ "$PLT_COUNT" -gt 0 ]; then
      log_boot "PLT patches will be mounted at boot (via top-level vendor overlay)"
    else
      log_boot "WARNING: PLT enabled but no patched files found in vendor/etc"
    fi
  else
    log_boot "WARNING: PLT enabled but vendor/etc directory not found in module"
  fi
else
  log_boot "PLT patching disabled"
fi

# ========================================
# OEM ROM SPECIFIC FIXES
# ========================================

# ========================================
# SELINUX CONTEXT RELABELING FOR MODULE VENDOR LIBRARIES
# ========================================
# Magisk bind-mounts module files from /data/adb/modules/<id>/system/vendor/
# onto /vendor/. The source files at the module path retain the 'adb_data_file'
# SELinux label from the /data/adb/ tree. After bind-mount, /vendor/lib64/*.so
# (the custom Adreno driver) is still labeled 'adb_data_file'.
#
# This is a problem on ALL ROMs — not just OEM — because:
#   - hal_graphics_composer_default / hal_graphics_allocator_default / surfaceflinger
#     are allowed to load 'same_process_hal_file' via our injected SELinux rules.
#   - They are NOT necessarily allowed to execute 'adb_data_file' files, especially
#     on OEM ROMs with strict vendor domain policy.
#   - chcon at the module source path changes the label before the bind-mount is seen
#     by any process: after bind-mount, /vendor/lib64/libvulkan.so is labeled
#     same_process_hal_file, which all our allow rules correctly cover.
#
# Split into two find passes: files → same_process_hal_file, dirs → vendor_file.
# DO NOT use chcon -R for both: applying same_process_hal_file to DIRECTORIES
# triggers SELinux denials on OEM ROMs (MIUI, OneUI, ColorOS) because their policy
# does not grant directory permissions for that file type. Directories must be
# vendor_file for traversal to work.
#
# This runs on ALL ROMs (not OEM-only) because the label issue affects all Magisk
# bind-mount environments. chcon failures on already-correctly-labeled systems
# are harmless (command returns non-zero, we ignore it with || true).

log_boot "Applying SELinux contexts to module vendor libraries (all ROMs)..."

if [ -d "$MODDIR/system/vendor/lib" ]; then
  find "$MODDIR/system/vendor/lib" -type f \
    -exec chcon u:object_r:same_process_hal_file:s0 {} + 2>/dev/null || \
    find "$MODDIR/system/vendor/lib" -type f \
      -exec chcon u:object_r:vendor_file:s0 {} + 2>/dev/null || \
    log_boot "WARNING: Failed to set SELinux contexts for system/vendor/lib files"
  find "$MODDIR/system/vendor/lib" -type d \
    -exec chcon u:object_r:vendor_file:s0 {} + 2>/dev/null || true
fi

if [ -d "$MODDIR/system/vendor/lib64" ]; then
  find "$MODDIR/system/vendor/lib64" -type f \
    -exec chcon u:object_r:same_process_hal_file:s0 {} + 2>/dev/null || \
    find "$MODDIR/system/vendor/lib64" -type f \
      -exec chcon u:object_r:vendor_file:s0 {} + 2>/dev/null || \
    log_boot "WARNING: Failed to set SELinux contexts for vendor/lib64 files"
  find "$MODDIR/system/vendor/lib64" -type d \
    -exec chcon u:object_r:vendor_file:s0 {} + 2>/dev/null || true
fi

# ── chcon result verification ────────────────────────────────────────────────
# On OEM ROMs with strict policy (MIUI/HyperOS, OneUI), chcon is denied by
# policy and files retain 'adb_data_file'. The adb_data_file fallback SELinux
# rules injected above cover this path. Log the outcome so it's visible in
# post-fs-data logs when investigating OEM bootloops.
_chcon_label=""
_chcon_sample=$(find "$MODDIR/system/vendor/lib64" -type f -name "*.so" 2>/dev/null | head -1)
if [ -n "$_chcon_sample" ]; then
  _chcon_label=$(ls -Z "$_chcon_sample" 2>/dev/null | awk '{print $1}' || echo "unknown")
  case "$_chcon_label" in
    *same_process_hal_file*)
      log_boot "[OK] chcon: vendor/lib64 .so files labeled same_process_hal_file" ;;
    *vendor_file*)
      log_boot "[OK] chcon: vendor/lib64 .so files labeled vendor_file (fallback label)" ;;
    *adb_data_file*)
      log_boot "[!] chcon FAILED: vendor/lib64 .so files retain adb_data_file label"
      log_boot "    OEM policy denied relabeling. Injecting adb_data_file fallback rules..."
      # ── adb_data_file fallback rule injection ──────────────────────────────
      # chcon failed → bind-mounted driver .so files are still labeled adb_data_file.
      # The batch injected same_process_hal_file allow rules above — those are now
      # the WRONG label. The GPU HAL processes need explicit adb_data_file access.
      # Without these rules: GPU HAL → driver .so → SELinux deny → dlopen fail →
      # SurfaceFlinger crash → watchdog reboot (OEM bootloop root cause).
      #
      # Grant only the 6 GPU-relevant domains that load the custom Adreno driver.
      # 'execute map' = required for dlopen. 'read open getattr' = library loading.
      # NOT granting to 'domain' (broad) — targeted grants only to avoid triggering
      # further OEM neverallow conflicts on the fallback path itself.
      _adf_ok=0
      "$SEPOLICY_TOOL" --live "allow hal_graphics_composer_default adb_data_file file { read open getattr execute map }" >/dev/null 2>&1 && _adf_ok=$((_adf_ok+1)) || true
      "$SEPOLICY_TOOL" --live "allow hal_graphics_allocator_default adb_data_file file { read open getattr execute map }" >/dev/null 2>&1 && _adf_ok=$((_adf_ok+1)) || true
      "$SEPOLICY_TOOL" --live "allow hal_graphics_mapper_default adb_data_file file { read open getattr execute map }" >/dev/null 2>&1 && _adf_ok=$((_adf_ok+1)) || true
      "$SEPOLICY_TOOL" --live "allow surfaceflinger adb_data_file file { read open getattr execute map }" >/dev/null 2>&1 && _adf_ok=$((_adf_ok+1)) || true
      "$SEPOLICY_TOOL" --live "allow system_server adb_data_file file { read open getattr execute map }" >/dev/null 2>&1 && _adf_ok=$((_adf_ok+1)) || true
      "$SEPOLICY_TOOL" --live "allow zygote adb_data_file file { read open getattr execute map }" >/dev/null 2>&1 && _adf_ok=$((_adf_ok+1)) || true
      RULES_SUCCESS=$((RULES_SUCCESS + _adf_ok))
      log_boot "    adb_data_file fallback: ${_adf_ok}/6 GPU HAL rules injected (OEM chcon workaround)"
      log_boot "    GPU processes will use injected adb_data_file allow rules to load the driver."
      unset _adf_ok
      ;;
    *)
      log_boot "[?] chcon: vendor/lib64 label='${_chcon_label}' (unexpected)" ;;
  esac
fi
unset _chcon_label _chcon_sample
# ── END chcon result verification ───────────────────────────────────────────

if [ -d "$MODDIR/system/vendor/firmware" ]; then
  chcon -R u:object_r:vendor_firmware_file:s0 "$MODDIR/system/vendor/firmware" 2>/dev/null || \
    log_boot "WARNING: Failed to set SELinux contexts for firmware"
fi

# ── OEM-specific: QGL data directory fix ─────────────────────────────────────
if [ "$HYPEROS_ROM" = "true" ] && [ "$QGL" = "y" ]; then
  mkdir -p /data/vendor/gpu 2>/dev/null
  # GPU HAL writes shader caches here at runtime. It runs in the 'system'
  # group (GID 1000). 0775 = owner+group write. 0755 would deny group
  # writes → HAL can't create caches → crash → SurfaceFlinger restart loop.
  chown root:system /data/vendor/gpu 2>/dev/null || true
  chmod 0775 /data/vendor/gpu 2>/dev/null || true
  # vendor_data_file is the correct SELinux type for runtime data directories
  # under /data/vendor. same_process_hal_file is for .so library FILES only;
  # applying it to a directory causes SELinux to deny dir-class operations
  # (search, write, add_name) on OEM ROMs that enforce strict type mapping.
  chcon u:object_r:vendor_data_file:s0 /data/vendor/gpu 2>/dev/null || true
  log_boot "QGL directory configured for HyperOS/MIUI (0775 root:system vendor_data_file)"
fi

if [ "$ONEUI_ROM" = "true" ] && [ -d "$MODDIR/system/vendor" ]; then
  find "$MODDIR/system/vendor" -type f -name "*.so" -exec chcon u:object_r:same_process_hal_file:s0 {} + 2>/dev/null || true
fi

log_boot "SELinux context relabeling complete (all ROMs)"

# ========================================
# BOOTLOOP LOGGING
# ========================================

if [ "$IN_BOOTLOOP" = "true" ]; then
  log_boot "========================================"
  log_boot "BOOTLOOP DETECTED - Snapshot Logging Only"
  log_boot "========================================"
  log_boot "NOTE: Continuous logging DISABLED to prevent filesystem deadlock"

  { read _bl2_raw _; } < /proc/uptime 2>/dev/null || _bl2_raw='0'
  BL_TIMESTAMP="${_bl2_raw%%.*}"

  (
    if [ "$ROOT_TYPE" = "KernelSU" ] && [ -f "/data/adb/ksu/log.txt" ]; then
      cp /data/adb/ksu/log.txt "${LOG_BASE_DIR}/Bootloop/ksu_log_${BL_TIMESTAMP}.txt" 2>/dev/null || true
    elif [ "$ROOT_TYPE" = "APatch" ] && [ -f "/data/adb/ap/log.txt" ]; then
      cp /data/adb/ap/log.txt "${LOG_BASE_DIR}/Bootloop/apatch_log_${BL_TIMESTAMP}.txt" 2>/dev/null || true
    elif [ "$ROOT_TYPE" = "Magisk" ] && [ -f "/data/adb/magisk/magisk.log" ]; then
      cp /data/adb/magisk/magisk.log "${LOG_BASE_DIR}/Bootloop/magisk_log_${BL_TIMESTAMP}.txt" 2>/dev/null || true
    fi
    dmesg 2>/dev/null | tail -n 1000 > "${LOG_BASE_DIR}/Bootloop/dmesg_snapshot_${BL_TIMESTAMP}.log" 2>/dev/null || true
    logcat -d -t 5000 > "${LOG_BASE_DIR}/Bootloop/logcat_snapshot_${BL_TIMESTAMP}.txt" 2>/dev/null || true
  ) &
fi

# ========================================
# CLEAN OLD LOGS
# ========================================

log_boot "Cleaning old logs..."

for state_dir in "Booted" "Bootloop"; do
  log_dir="${LOG_BASE_DIR}/${state_dir}"
  if [ -d "$log_dir" ]; then
    _log_count=0
    for _lf in "$log_dir"/boot_*.log "$log_dir"/bootloop_*.log; do
      [ -f "$_lf" ] && _log_count=$((_log_count+1))
    done
    if [ "$_log_count" -gt 2 ]; then
      _n=0
      for _lf in "$log_dir"/boot_*.log "$log_dir"/bootloop_*.log; do
        [ -f "$_lf" ] || continue
        _n=$((_n+1))
        [ $_n -le $((_log_count - 2)) ] && rm -f "$_lf" 2>/dev/null || true
      done
      log_boot "Cleaned old boot logs in $state_dir (kept last 2)"
    fi
    unset _log_count _n _lf

    for log_type in "logcat_" "dmesg_" "last_kmsg_" "ksu_log_" "apatch_log_" "magisk_log_" "snapshot_"; do
      _tcount=0
      for _tf in "$log_dir"/${log_type}*.txt "$log_dir"/${log_type}*.log; do
        [ -f "$_tf" ] && _tcount=$((_tcount+1))
      done
      if [ "$_tcount" -gt 5 ]; then
        _n=0
        for _tf in "$log_dir"/${log_type}*.txt "$log_dir"/${log_type}*.log; do
          [ -f "$_tf" ] || continue
          _n=$((_n+1))
          [ $_n -le $((_tcount - 5)) ] && rm -f "$_tf" 2>/dev/null || true
        done
      fi
      unset _tcount _n _tf
    done
  fi
done

# ========================================
# COMPLETION
# ========================================
# NOTE: The boot-attempt counter is intentionally NOT reset here.
# It is only reset by service.sh AFTER sys.boot_completed fires.
# This ensures the rollback mechanism catches crashes that happen between
# post-fs-data completion and boot_completed (e.g. SurfaceFlinger crash,
# hw-composer crash). If this script resets the counter, those crashes
# silently loop forever with no auto-disable.

log_boot "========================================"
log_boot "post-fs-data.sh completed successfully"
log_boot "Configuration: PLT=$PLT, QGL=$QGL, RENDER=$RENDER_MODE, GAME_EXCLUSION_DAEMON=$GAME_EXCLUSION_DAEMON, FIRST_BOOT_DEFERRED=$FIRST_BOOT_PENDING"
log_boot "Metamodule active: $METAMODULE_ACTIVE"
log_boot "SUSFS (root hiding): $SUSFS_ACTIVE"
log_boot "OEM ROM: $OEM_TYPE"
if [ "$ROOT_TYPE" = "APatch" ]; then
  log_boot "APatch Mode: $APATCH_MODE"
fi
log_boot "SELinux: Synchronous injection complete (${RULES_SUCCESS:-0} rules applied)"
log_boot "========================================"

exit 0
