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
# are persisted to system.prop exclusively by post-fs-data.sh (this script).
# service.sh no longer writes system.prop — it only enforces props live via
# resetprop after boot_completed. This avoids a race where service.sh's awk
# strip ran but the rewrite was silently skipped, leaving system.prop empty.
# ========================================

# ========================================
# SHARED FUNCTIONS
# ========================================

MODDIR="${0%/*}"
. "$MODDIR/common.sh"

# ── Boot timing profiler ────────────────────────────────────────────────
# Read /proc/uptime ONCE — avoids repeated cat+awk forks in post-fs-data
# where every ms matters. Subsequent timing entries reuse this value or
# compute deltas from it.
{ read _BOOT_PHASE_START _; } < /proc/uptime 2>/dev/null || _BOOT_PHASE_START="0"
# _log_emit will be wired to log_boot once log_boot() is defined below.
# For now, use a stub that writes to a buffer drained later.
_BOOT_TIMING_ENTRIES=""
_add_boot_timing() { _BOOT_TIMING_ENTRIES="${_BOOT_TIMING_ENTRIES}${1}
"; }
_add_boot_timing "post-fs-data.sh started at ${_BOOT_PHASE_START}s uptime"

# ========================================
# EARLY ROOT DETECTION
# ========================================

_add_boot_timing "root detection started at ${_BOOT_PHASE_START}s"

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
# BOOT COUNTER FILE PATH
# ========================================
BOOT_ATTEMPTS_FILE="/data/local/tmp/adreno_boot_attempts"

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
# between here and the real definition are now logged to the buffer.
# buffer that the real log_boot() drains and re-logs on first call.
_EARLY_LOG_BUFFER="/data/local/tmp/adreno_early_log_buffer.$$"
log_boot() {
  # Write to temp buffer until real log_boot is defined and drains it.
  mkdir -p /data/local/tmp 2>/dev/null
  printf '[EARLY] %s\n' "$1" >> "$_EARLY_LOG_BUFFER" 2>/dev/null || true
}

# ========================================
# NOTE: skip_mount logic REMOVED - KSU auto-handles mount skipping
# and the previous logic caused false auto-disables

# NOTE: Auto-disable mechanism REMOVED - was causing false positives
# Boot counter is still incremented for diagnostics but module won't auto-disable

# ========================================
# CONFIGURATION LOADING
# ========================================

VERBOSE="n"
ARM64_OPT="n"
QGL="n"
QGL_PERAPP="n"
PLT="n"
RENDER_MODE="normal"
FORCE_SKIAVKTHREADED_BACKEND="n"

# Priority: /data/local/tmp (always accessible at post-fs-data) →
#           /sdcard (may not be mounted yet, usually skipped here) →
#           $MODDIR (module bundled defaults)
if ! load_config "$ADRENO_CONFIG_DATA"; then
  if ! load_config "$ADRENO_CONFIG_SD"; then
    load_config "$ADRENO_CONFIG_MOD" || true
  fi
fi

[ "$VERBOSE" != "y" ]   && VERBOSE="n"
[ "$ARM64_OPT" != "y" ] && ARM64_OPT="n"
[ "$QGL" != "y" ]       && QGL="n"
[ "$QGL_PERAPP" != "y" ] && QGL_PERAPP="n"
[ "$PLT" != "y" ]       && PLT="n"
[ -z "$RENDER_MODE" ]   && RENDER_MODE="normal"
[ "$FORCE_SKIAVKTHREADED_BACKEND" != "y" ] && FORCE_SKIAVKTHREADED_BACKEND="n"
# Normalize RENDER_MODE to lowercase so every case statement matches
# regardless of how the user typed it (SkiaVK, SKIAVK, SkiaGL, etc.).
RENDER_MODE=$(printf '%s' "$RENDER_MODE" | tr '[:upper:]' '[:lower:]')
# Legacy: skiavkthreaded/skiaglthreaded were removed as standalone RENDER_MODE values.
# common.sh normalizes them on load, but guard here defensively.
[ "$RENDER_MODE" = "skiavkthreaded" ] && RENDER_MODE="skiavk"
[ "$RENDER_MODE" = "skiaglthreaded" ] && RENDER_MODE="skiagl"

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
    local current_uptime="${_raw%%.*}"
    local boot_count=0
    local last_boot_epoch=0
    local boot_uptime="$current_uptime"

    # Wall-clock timestamp for cross-reboot comparison.
    # Uptime resets to ~20s on every reboot, so storing uptime as LAST_BOOT
    # always gives (current - last) ≈ 0 < 60s → every boot looks like a
    # rapid reboot → false positive bootloop on boot 3+.
    # date +%s gives Unix epoch which is monotonically increasing across reboots.
    local current_epoch
    current_epoch=$(date +%s 2>/dev/null || echo "0")
    # If date is unavailable, use a sentinel that always passes the threshold check
    [ "$current_epoch" = "0" ] && current_epoch=999999999

    if [ -f "$BOOT_STATE_FILE" ]; then
      while IFS='=' read -r _bk _bv; do
        case "$_bk" in
          BOOT_COUNT)       boot_count="${_bv:-0}" ;;
          LAST_BOOT_EPOCH)  last_boot_epoch="${_bv:-0}" ;;
        esac
      done < "$BOOT_STATE_FILE"
    fi

    BOOTLOOP_THRESHOLD=60

    # Compare wall-clock elapsed seconds between reboots.
    if [ $((current_epoch - last_boot_epoch)) -lt $BOOTLOOP_THRESHOLD ]; then
      boot_count=$((boot_count + 1))
    else
      boot_count=1
    fi

    # BUG 8 FIX: Use atomic printf+mv instead of cat > heredoc.
    # cat > file is non-atomic: truncate step clears the file, then write fills it.
    # Power loss between truncate and write leaves an empty file → bootloop guard
    # reads 0 on next boot, silently resetting the safety net.
    # printf > .tmp && mv is atomic on all Linux filesystems (mv = single rename syscall).
    {
      printf 'BOOT_COUNT=%s\n'   "$boot_count"
      printf 'LAST_BOOT_EPOCH=%s\n' "$current_epoch"
      printf 'UPTIME=%s\n'      "$boot_uptime"
      printf 'THRESHOLD=%s\n'   "$BOOTLOOP_THRESHOLD"
    } > "${BOOT_STATE_FILE}.tmp" 2>/dev/null && \
      mv "${BOOT_STATE_FILE}.tmp" "$BOOT_STATE_FILE" 2>/dev/null || {
      # Primary path failed — try /tmp fallback (atomic write there too)
      BOOT_STATE_FILE="/tmp/adreno_boot_state"
      {
        printf 'BOOT_COUNT=%s\n'   "$boot_count"
        printf 'LAST_BOOT_EPOCH=%s\n' "$current_epoch"
        printf 'UPTIME=%s\n'      "$boot_uptime"
        printf 'THRESHOLD=%s\n'   "$BOOTLOOP_THRESHOLD"
      } > "${BOOT_STATE_FILE}.tmp" 2>/dev/null && \
        mv "${BOOT_STATE_FILE}.tmp" "$BOOT_STATE_FILE" 2>/dev/null || true
    }

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
  _log_emit() { log_boot "$1"; }
else
  log_boot() { :; }
  _log_emit() { :; }
fi

# BUG2 FIX: Drain the early log buffer now that the real log_boot() is live.
if [ -f "${_EARLY_LOG_BUFFER:-}" ]; then
  while IFS= read -r _buf_line; do
    log_boot "$_buf_line"
  done < "$_EARLY_LOG_BUFFER" 2>/dev/null
  rm -f "$_EARLY_LOG_BUFFER" 2>/dev/null
fi
unset _EARLY_LOG_BUFFER

# ── Flush boot timing entries ───────────────────────────────────────────
if [ -n "$_BOOT_TIMING_ENTRIES" ]; then
  printf '%s' "$_BOOT_TIMING_ENTRIES" | while IFS= read -r _bt_line; do
    [ -n "$_bt_line" ] && log_boot "[TIMING] $_bt_line"
  done
  unset _BOOT_TIMING_ENTRIES
fi
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

log_boot "Configuration: PLT=$PLT, QGL=$QGL, ARM64_OPT=$ARM64_OPT, RENDER=$RENDER_MODE, FORCE_SKIAVKTHREADED_BACKEND=$FORCE_SKIAVKTHREADED_BACKEND"

# ========================================
# SYNC MODULE STATE TO CURRENT CONFIG
# ========================================

log_boot "========================================"
log_boot "SYNCING MODULE STATE TO CONFIG"
log_boot "========================================"

if [ "$QGL" = "n" ]; then
  if [ -f "/data/vendor/gpu/qgl_config.txt" ]; then
    rm -f "/data/vendor/gpu/qgl_config.txt" 2>/dev/null && \
      log_boot "[OK] QGL disabled → removed /data/vendor/gpu/qgl_config.txt" || \
      log_boot "[!] QGL disabled → failed to remove qgl_config.txt (may be same_process_hal_file context)"
  else
    log_boot "QGL disabled → qgl_config.txt not present"
  fi
  rm -f "/data/vendor/gpu/.adreno_qgl_owner" 2>/dev/null || true
else
  log_boot "QGL enabled → file will be installed below"
fi

if [ "$QGL" = "y" ]; then
  log_boot "QGL: enabled — directory pre-created, file install deferred to boot-completed.sh"
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

# ── PHASE 1: REMOVE QGL PRE-ZYGOTE ──────────────────────────────────────
# ROOT CAUSE OF BOOTLOOP: If qgl_config.txt exists when the GPU driver loads
# during early boot (pre-zygote), the driver reads it during vkDevice init.
# With a 127-extension QGL config (many unsupported on the target GPU), the
# VkDevice becomes corrupt → SystemUI crashes → black screen → watchdog reboot.
#
# LYB writes QGL at BOOT_COMPLETED broadcast (post-zygote) via its onboot
# BroadcastReceiver. We match this by removing any stale QGL here (pre-zygote)
# and letting boot-completed.sh re-apply it after launcher is ready + 8s delay.
#
# This is a REMOVE-THEN-REAPPLY strategy:
#   Phase 1 (here): Remove QGL → GPU driver loads clean → no bootloop
#   Phase 2 (boot-completed.sh): Re-apply QGL after launcher Vulkan init
if [ "$QGL" = "y" ]; then
  if [ -f "/data/vendor/gpu/qgl_config.txt" ]; then
    # CRITICAL FIX: Retry rm up to 3 times with 0.5s delays.
    # The rm can fail if the file is held open by a dying process from the
    # previous boot, or if SELinux context hasn't propagated yet.
    # If rm fails, the stale QGL config causes VkDevice corruption →
    # SystemUI crash → black screen → watchdog reboot (bootloop).
    _qgl_rm_ok=false
    _qgl_rm_try=0
    while [ $_qgl_rm_try -lt 3 ] && [ "$_qgl_rm_ok" = "false" ]; do
      if rm -f "/data/vendor/gpu/qgl_config.txt" 2>/dev/null; then
        # Verify the file is actually gone
        if [ ! -f "/data/vendor/gpu/qgl_config.txt" ]; then
          _qgl_rm_ok=true
        fi
      fi
      if [ "$_qgl_rm_ok" = "false" ]; then
        _qgl_rm_try=$((_qgl_rm_try + 1))
        if [ $_qgl_rm_try -lt 3 ]; then
          sleep 0.5
        fi
      fi
    done
    if [ "$_qgl_rm_ok" = "true" ]; then
      log_boot "[OK] QGL: removed stale config (will be re-applied at boot-completed)"
    else
      log_boot "[!] CRITICAL: QGL rm failed after 3 attempts — stale config will cause bootloop!"
      log_boot "[!] Attempting forced removal via unlink..."
      # Last resort: try to truncate + unlink
      : > "/data/vendor/gpu/qgl_config.txt" 2>/dev/null || true
      rm -f "/data/vendor/gpu/qgl_config.txt" 2>/dev/null || true
      if [ ! -f "/data/vendor/gpu/qgl_config.txt" ]; then
        log_boot "[OK] QGL: forced removal succeeded"
      else
        log_boot "[!] FATAL: QGL config still present — bootloop is likely imminent"
      fi
    fi
    unset _qgl_rm_ok _qgl_rm_try
  else
    log_boot "QGL: no stale config found (clean boot)"
  fi
  rm -f "/data/vendor/gpu/.adreno_qgl_owner" 2>/dev/null || true
else
  # QGL=n: ensure no QGL file exists
  if [ -f "/data/vendor/gpu/qgl_config.txt" ]; then
    _qgl_rm_ok=false
    _qgl_rm_try=0
    while [ $_qgl_rm_try -lt 3 ] && [ "$_qgl_rm_ok" = "false" ]; do
      if rm -f "/data/vendor/gpu/qgl_config.txt" 2>/dev/null; then
        if [ ! -f "/data/vendor/gpu/qgl_config.txt" ]; then
          _qgl_rm_ok=true
        fi
      fi
      if [ "$_qgl_rm_ok" = "false" ]; then
        _qgl_rm_try=$((_qgl_rm_try + 1))
        if [ $_qgl_rm_try -lt 3 ]; then
          sleep 0.5
        fi
      fi
    done
    if [ "$_qgl_rm_ok" = "true" ]; then
      log_boot "[OK] QGL: disabled → removed existing config"
    else
      log_boot "[!] QGL: disabled → failed to remove config after 3 attempts"
    fi
    unset _qgl_rm_ok _qgl_rm_try
  fi
  rm -f "/data/vendor/gpu/.adreno_qgl_owner" 2>/dev/null || true
fi

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
  # BUG FIX: magiskpolicy --help ALWAYS exits 1 (usage() calls exit(1) in all
  # Magisk/KSU/APatch builds — confirmed in magiskpolicy.c source). Using it as
  # a liveness test means TOOL_FOUND=false on every boot → all SELinux injection
  # silently skipped → su/magisk/ksu domains never get setattr/relabelfrom/relabelto
  # → chmod 0644 and chcon both fail silently → qgl_config.txt stays mode=0000.
  # Correct test: file existence + executable bit only.
  for _mp in \
      "$(command -v magiskpolicy 2>/dev/null)" \
      "/sbin/magiskpolicy" \
      "/data/adb/magisk/magiskpolicy" \
      "/data/adb/ksu/bin/magiskpolicy" \
      "/data/adb/ap/bin/magiskpolicy" \
      "/system/bin/magiskpolicy" \
      "/system/xbin/magiskpolicy"; do
    [ -z "$_mp" ] && continue
    [ -f "$_mp" ] && [ -x "$_mp" ] || continue
    SEPOLICY_TOOL="$_mp"
    TOOL_FOUND=true
    return 0
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

# ── KSU-NEXT: If no magiskpolicy found, create ksud sepolicy patch wrapper ─
# KernelSU-Next (rifsxd) ships no magiskpolicy binary. ksud provides:
#   ksud sepolicy patch "rule"  → live injection
# Create an ephemeral wrapper in /dev/tmp/ so inject() calls work transparently.
if [ "$TOOL_FOUND" = "false" ]; then
  _pfd_ksud_bin=""
  for _kb in "/data/adb/ksud" "/data/adb/ksu/bin/ksud" "$(command -v ksud 2>/dev/null)"; do
    [ -z "$_kb" ] && continue
    [ -f "$_kb" ] && [ -x "$_kb" ] && { _pfd_ksud_bin="$_kb"; break; }
  done
  unset _kb
  if [ -n "$_pfd_ksud_bin" ]; then
    if "$_pfd_ksud_bin" sepolicy patch "allow domain domain process signal" >/dev/null 2>&1; then
      _pfd_ksud_wrapper="/dev/tmp/adreno_pfd_mp_$$"
      mkdir -p /dev/tmp 2>/dev/null || true
      printf '#!/system/bin/sh\nshift\n_k="%s"\nfor _r; do "$_k" sepolicy patch "$_r" 2>/dev/null; done\n' \
        "$_pfd_ksud_bin" > "$_pfd_ksud_wrapper" 2>/dev/null
      if chmod 0755 "$_pfd_ksud_wrapper" 2>/dev/null; then
        SEPOLICY_TOOL="$_pfd_ksud_wrapper"
        TOOL_FOUND=true
        log_boot "[OK] KSU-Next: ksud sepolicy wrapper created (ephemeral): $_pfd_ksud_wrapper"
      else
        rm -f "$_pfd_ksud_wrapper" 2>/dev/null || true
        log_boot "[!] KSU-Next: ksud wrapper chmod failed — injection will be skipped"
      fi
      unset _pfd_ksud_wrapper
    else
      log_boot "[!] KSU-Next: ksud at $_pfd_ksud_bin — 'sepolicy patch' test failed (unexpected)"
    fi
  fi
  unset _pfd_ksud_bin
fi
# ── END KSU-NEXT WRAPPER ──────────────────────────────────────────────────

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
allow hal_graphics_composer_default same_process_hal_file dir { search read open getattr }
allow hal_graphics_composer_default vendor_file file { read open getattr execute map }
allow hal_graphics_allocator_default gpu_device chr_file { read write open ioctl getattr }
allow hal_graphics_allocator_default same_process_hal_file file { read open getattr execute map }
allow hal_graphics_allocator_default same_process_hal_file dir { search read open getattr }
allow hal_graphics_mapper_default gpu_device chr_file { read write open ioctl getattr }
allow hal_graphics_mapper_default same_process_hal_file file { read open getattr execute map }
allow hal_graphics_mapper_default same_process_hal_file dir { search read open getattr }
allow surfaceflinger gpu_device chr_file { read write open ioctl getattr }
allow surfaceflinger same_process_hal_file file { read open getattr execute map }
allow surfaceflinger same_process_hal_file dir { search read open getattr }
allow surfaceflinger vendor_file file { read open getattr execute map }
allow system_server gpu_device chr_file { read write open ioctl getattr }
allow system_server same_process_hal_file file { read open getattr execute map }
allow system_server same_process_hal_file dir { search read open getattr }
allow system_server vendor_file file { read open getattr execute map }
allow zygote gpu_device chr_file { read write open ioctl getattr }
allow zygote same_process_hal_file file { read open getattr execute map }
allow zygote same_process_hal_file dir { search read open getattr }
allow zygote vendor_file file { read open getattr execute map }
allow appdomain gpu_device chr_file { read write open ioctl getattr }
allow appdomain same_process_hal_file dir { search read open getattr }
allow appdomain same_process_hal_file file { read open getattr map }
allow untrusted_app gpu_device chr_file { read write open ioctl getattr }
allow platform_app gpu_device chr_file { read write open ioctl getattr }
allow priv_app gpu_device chr_file { read write open ioctl getattr }
allow isolated_app gpu_device chr_file { read write open ioctl getattr }
allow init same_process_hal_file file { read open getattr execute map relabelto relabelfrom unlink rename }
allow init same_process_hal_file dir { getattr setattr relabelto relabelfrom search read open write add_name remove_name }
allow init vendor_file file { read open getattr execute execute_no_trans }
allow init gpu_device chr_file { read write open ioctl getattr setattr }
allow hal_graphics_mapper same_process_hal_file dir { search read open getattr }
allow hal_graphics_mapper same_process_hal_file file { read open getattr execute map }
allow hal_graphics_composer_default self capability dac_read_search
allow hal_graphics_allocator_default self capability dac_read_search
allow hal_graphics_mapper_default self capability dac_read_search
allow surfaceflinger self capability dac_read_search
allow system_server self capability dac_read_search
allow vendor_init gpu_device chr_file { read write open ioctl getattr setattr }
allow vendor_init vendor_firmware_file dir { search read getattr }
allow vendor_init vendor_firmware_file file { read open getattr }
allow su same_process_hal_file dir { getattr setattr relabelto relabelfrom search read open write add_name remove_name }
allow su same_process_hal_file file { getattr setattr relabelto relabelfrom create write open read unlink rename }
allow magisk same_process_hal_file dir { getattr setattr relabelto relabelfrom search read open write add_name remove_name }
allow magisk same_process_hal_file file { getattr setattr relabelto relabelfrom create write open read unlink rename }
allow init unlabeled file { getattr setattr relabelfrom unlink rename }
allow init unlabeled dir { getattr setattr relabelfrom write add_name remove_name }
allow same_process_hal_file labeledfs filesystem associate
allow same_process_hal_file unlabeled filesystem associate
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

  # NOTE: The ksud wrapper does not support --apply FILE (it only handles individual
  # rule strings via 'ksud sepolicy patch "rule"'). Skip batch attempt for ksud wrapper
  # and fall through directly to individual injection — this avoids a confusing log
  # message about batch failure when the wrapper is functioning correctly.
  _batch_ok=false
  _is_ksud_wrapper=false
  case "$SEPOLICY_TOOL" in
    */adreno_pfd_mp_*) _is_ksud_wrapper=true ;;
  esac

  if [ "$_is_ksud_wrapper" = "false" ] && [ -f "$_RULES_TMP" ] && \
     "$SEPOLICY_TOOL" --live --apply "$_RULES_TMP" >/dev/null 2>&1; then
    _batch_ok=true
    RULES_SUCCESS=52
    log_boot "[OK] BATCH injection: 52 core rules applied in 1 magiskpolicy spawn"
  fi

  # FIX-C-2: Individual fallback is rare (batch succeeds on >95% of devices).
  # Individual injection is the most granular fallback — each rule fails
  # independently. Splitting into smaller batches was rejected because it
  # requires per-OEM neverallow knowledge that is not discoverable at runtime.
  # Worst case: 69 spawns on strict OEM ROMs (~28s). Batch path: 1 spawn.
  if [ "$_batch_ok" = "false" ]; then
    [ "$_is_ksud_wrapper" = "true" ] && \
      log_boot "[OK] ksud wrapper detected — using individual injection (batch --apply unsupported by ksud)"
    [ "$_is_ksud_wrapper" = "false" ] && \
      log_boot "[!] Batch --apply failed — falling back to individual injection (28s worst case on strict OEM ROMs)"
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
    inject "allow hal_graphics_composer_default same_process_hal_file dir { search read open getattr }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))
    inject "allow hal_graphics_composer_default vendor_file file { read open getattr execute map }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))

    if inject "allow hal_graphics_allocator_default gpu_device chr_file { read write open ioctl getattr }"; then
      RULES_SUCCESS=$((RULES_SUCCESS + 1)); log_boot "  [OK] Graphics allocator -> GPU device"
    else
      RULES_FAILED=$((RULES_FAILED + 1)); CRITICAL_RULES_FAILED=$((CRITICAL_RULES_FAILED + 1))
      log_boot "  [X] CRITICAL: Graphics allocator -> GPU device FAILED"
    fi
    inject "allow hal_graphics_allocator_default same_process_hal_file file { read open getattr execute map }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))
    inject "allow hal_graphics_allocator_default same_process_hal_file dir { search read open getattr }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))

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
    inject "allow hal_graphics_mapper_default same_process_hal_file dir { search read open getattr }" 2>/dev/null && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || true
    inject "allow hal_graphics_mapper same_process_hal_file dir { search read open getattr }" 2>/dev/null && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || true

    if inject "allow surfaceflinger gpu_device chr_file { read write open ioctl getattr }"; then
      RULES_SUCCESS=$((RULES_SUCCESS + 1)); log_boot "  [OK] SurfaceFlinger -> GPU device"
    else
      RULES_FAILED=$((RULES_FAILED + 1)); CRITICAL_RULES_FAILED=$((CRITICAL_RULES_FAILED + 1))
      log_boot "  [X] CRITICAL: SurfaceFlinger -> GPU device FAILED"
    fi
    inject "allow surfaceflinger same_process_hal_file file { read open getattr execute map }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))
    inject "allow surfaceflinger same_process_hal_file dir { search read open getattr }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))
    inject "allow surfaceflinger vendor_file file { read open getattr execute map }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))

    inject "allow system_server gpu_device chr_file { read write open ioctl getattr }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))
    inject "allow system_server same_process_hal_file file { read open getattr execute map }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))
    inject "allow system_server same_process_hal_file dir { search read open getattr }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))
    inject "allow system_server vendor_file file { read open getattr execute map }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))

    inject "allow zygote gpu_device chr_file { read write open ioctl getattr }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))
    inject "allow zygote same_process_hal_file file { read open getattr execute map }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))
    inject "allow zygote same_process_hal_file dir { search read open getattr }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))
    inject "allow zygote vendor_file file { read open getattr execute map }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))

    inject "allow appdomain gpu_device chr_file { read write open ioctl getattr }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))
    # DIRECTORY CHCON FIX: appdomain needs dir search on same_process_hal_file to traverse
    # /data/vendor/gpu/ when the directory has same_process_hal_file context (set by CASE A).
    # Without this, kernel denies directory traversal before the file open() is attempted.
    inject "allow appdomain same_process_hal_file dir { search read open getattr }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))
    inject "allow appdomain same_process_hal_file file { read open getattr map }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))
    inject "allow untrusted_app gpu_device chr_file { read write open ioctl getattr }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))
    inject "allow platform_app gpu_device chr_file { read write open ioctl getattr }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))
    inject "allow priv_app gpu_device chr_file { read write open ioctl getattr }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))
    inject "allow isolated_app gpu_device chr_file { read write open ioctl getattr }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))

    inject "allow domain system_lib_file file { read open getattr execute map }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))
    inject "allow domain vendor_firmware_file dir { search getattr read }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))
    inject "allow domain vendor_firmware_file file { read open getattr map }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))
    inject "allow domain firmware_file file { read open getattr }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))

    # BUG FIX: add relabelfrom+unlink so init can delete/relabel the file after
    # service.sh CASE A chcon'd it to same_process_hal_file. Without these:
    # - mv -f $QGL_TEMP $QGL_TARGET silently fails when target is same_process_hal_file
    # - rm -f in QGL=n disable path silently fails for the same reason
    inject "allow init same_process_hal_file file { read open getattr execute map relabelto relabelfrom unlink rename }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))
    # DIRECTORY CHCON FIX: init chcon's /data/vendor/gpu/ to same_process_hal_file.
    # The Adreno driver checks BOTH dir and file context — dir must be same_process_hal_file
    # or driver ignores qgl_config.txt entirely (validated via LYB reverse engineering).
    # write+add_name+remove_name: needed for creating/removing files in same_process_hal_file dirs
    # (QGL_TEMP creation, owner marker touch, mv rename within the dir).
    inject "allow init same_process_hal_file dir { getattr setattr relabelto relabelfrom search read open write add_name remove_name }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))
    inject "allow init gpu_device chr_file { read write open ioctl getattr setattr }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))
    # UNLABELED FIX for init domain:
    # OEM ROMs without type_transition → init-created files in /data/vendor/gpu/
    # get 'unlabeled' label. The chcon in boot-completed.sh
    # needs relabelfrom unlabeled. Without these,
    # chcon silently fails → file stays unlabeled.
    # rename: needed for mv QGL_TEMP→QGL_TARGET when QGL_TEMP has unlabeled context.
    # write+add_name+remove_name on dir: needed for file creation in same_process_hal_file/unlabeled dirs.
    "$SEPOLICY_TOOL" --live "allow init unlabeled file { getattr setattr relabelfrom unlink rename }" \
      >/dev/null 2>&1 && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || true
    "$SEPOLICY_TOOL" --live "allow init unlabeled dir { getattr setattr relabelfrom write add_name remove_name }" \
      >/dev/null 2>&1 && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || true
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
    inject "allow vendor_init vendor_firmware_file dir { search read getattr }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))
    inject "allow vendor_init vendor_firmware_file file { read open getattr }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))
    inject "allow vendor_init self capability { chown fowner }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))

    inject "allow domain logd unix_stream_socket { connectto write }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))
    inject "allow domain kernel file { read open }" && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || RULES_FAILED=$((RULES_FAILED + 1))
  fi
  rm -f "$_RULES_TMP" 2>/dev/null

  # ── CRITICAL: init relabeling rules — injected UNCONDITIONALLY after batch ─
  # BUG FIX: These were previously only in the batch-failure fallback path.
  # If the batch succeeded, these rules were never injected, so init's
  # chcon in PROTECTED MODE silently failed → file stays unlabeled →
  # service.sh CASE A chmod 0644 denied → mode stays 0000 forever.
  # Now injected here regardless of whether the batch succeeded or failed.
  # They are also present in the batch (added above) as belt-and-suspenders.
  # Silent-fail: each rule succeeds or fails independently of the others.
  # allow init unlabeled: OEM ROMs without type_transition label init-created files
  # in /data/vendor/gpu/ as 'unlabeled'. init needs relabelfrom unlabeled to chcon.
  "$SEPOLICY_TOOL" --live "allow init unlabeled file { getattr setattr relabelfrom unlink rename }" \
    >/dev/null 2>&1 && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || true
  # allow init vendor_data_file relabelfrom+relabelto: REMOVED (no vendor_data_file slop)
  # same_process_hal_file associate: kernel security_sid_mls_copy() checks this
  # BEFORE evaluating relabelfrom/relabelto. If denied, chcon returns EACCES
  # even when relabelfrom+relabelto are present. Must be unconditionally present.
  "$SEPOLICY_TOOL" --live "allow same_process_hal_file labeledfs filesystem associate" \
    >/dev/null 2>&1 && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || true
  "$SEPOLICY_TOOL" --live "allow same_process_hal_file unlabeled filesystem associate" \
    >/dev/null 2>&1 && RULES_SUCCESS=$((RULES_SUCCESS + 1)) || true

  # ── OEM-SAFE BROAD DOMAIN RULES — silent-fail individual injection ────────
  # These 6 "allow domain ..." rules were removed from the batch heredoc because
  # they trigger neverallow conflicts on OEM ROMs:
  #
  #   allow domain system_lib_file ... execute     → Samsung OneUI:
  #     neverallow { untrusted_app isolated_app } system_lib_file:file execute
  #     Batch contains both isolated_app and domain (a superset) — conflict.
  #
  #   allow domain gpu_device dir { search read }  → Broad but individually safe;
  #                                                  removed from batch because a
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

  # ── QGL: su/magisk access for boot-completed.sh install path ──────────────
  # service.sh (late_start) runs as su/magisk domain and needs access to
  # atomically install qgl_config.txt after boot_completed.
  # These rules are injected individually (silent-fail) so su/magisk type
  # absence on non-Magisk roots doesn't poison the batch.
  # On KernelSU/APatch the 'su' type is the correct service.sh context;
  # 'magisk' covers Magisk proper. Both are always attempted.
  if [ "$QGL" = "y" ] && [ -n "$SEPOLICY_TOOL" ]; then
    log_boot "  [QGL] Injecting same_process_hal_file access for su/magisk/ksu"
    # su   = KernelSU (standard, tiann) and APatch service.sh domain
    # magisk = Magisk service.sh domain (already has allow magisk * * *, but belt+suspenders)
    # ksu  = KernelSU-Next (rifsxd) service.sh domain (uses u:r:ksu:s0, NOT su)
    for _qgl_ctx in su magisk ksu; do
      "$SEPOLICY_TOOL" --live \
        "allow ${_qgl_ctx} same_process_hal_file dir { getattr setattr relabelto relabelfrom search read open write add_name remove_name }" \
        >/dev/null 2>&1 && \
        { RULES_SUCCESS=$((RULES_SUCCESS + 1)); log_boot "  [+] ${_qgl_ctx} → same_process_hal_file dir full"; } || true
      "$SEPOLICY_TOOL" --live \
        "allow ${_qgl_ctx} same_process_hal_file file { getattr setattr relabelto relabelfrom create write open read unlink rename }" \
        >/dev/null 2>&1 && \
        { RULES_SUCCESS=$((RULES_SUCCESS + 1)); log_boot "  [+] ${_qgl_ctx} → same_process_hal_file file full"; } || true
      # UNLABELED FIX: new files cp'd into same_process_hal_file dir get unlabeled
      # context on OEM ROMs without type_transition. create/write/open needed for cp.
      "$SEPOLICY_TOOL" --live \
        "allow ${_qgl_ctx} unlabeled file { create read write open getattr setattr relabelfrom unlink rename }" \
        >/dev/null 2>&1 && \
        { RULES_SUCCESS=$((RULES_SUCCESS + 1)); log_boot "  [+] ${_qgl_ctx} → unlabeled file full (OEM type_transition fix)"; } || true
    done
    unset _qgl_ctx
    # filesystem associate: required for chcon same_process_hal_file on /data.
    # Injected here so it is present regardless of whether batch or fallback ran.
    # labeledfs = ext4/f2fs with xattr (/data); NOT '*' — Knox neverallow risk.
    "$SEPOLICY_TOOL" --live "allow same_process_hal_file labeledfs filesystem associate" \
      >/dev/null 2>&1 && { RULES_SUCCESS=$((RULES_SUCCESS + 1)); log_boot "  [+] same_process_hal_file labeledfs associate (QGL)"; } || true
    "$SEPOLICY_TOOL" --live "allow same_process_hal_file unlabeled filesystem associate" \
      >/dev/null 2>&1 && { RULES_SUCCESS=$((RULES_SUCCESS + 1)); log_boot "  [+] same_process_hal_file unlabeled associate (QGL)"; } || true
  fi

  # ── ksu (KernelSU-Next u:r:ksu:s0) standalone rules ─────────────────────────
  # KernelSU-Next (rifsxd fork) runs service.sh under u:r:ksu:s0, distinct from
  # u:r:su:s0 used by KernelSU (tiann) and APatch.
  # The 49-rule batch includes su and magisk rules but NOT ksu — adding ksu to the
  # batch would cause magiskpolicy to reject the entire batch on Magisk-only ROMs
  # where 'ksu' is an unknown type (unknown-type rule in --apply → batch abort).
  # These 3 rules are injected individually here so each succeeds or fails on its own.
  # The QGL=y block above also injects these for ksu; the duplication is harmless
  # (magiskpolicy handles duplicate allow rules idempotently) and this block ensures
  # coverage when QGL=n or when the tool is absent during the QGL block.
  if [ -n "$SEPOLICY_TOOL" ]; then
    "$SEPOLICY_TOOL" --live \
      "allow ksu same_process_hal_file file { getattr setattr relabelto relabelfrom create write open read unlink rename }" \
      >/dev/null 2>&1 && \
      { RULES_SUCCESS=$((RULES_SUCCESS + 1)); log_boot "  [+] ksu -> same_process_hal_file file full (KSU-Next standalone)"; } || true
    # BUG FIX: was missing entirely. write+add_name+remove_name required to create/delete files
    # inside the same_process_hal_file-labeled /data/vendor/gpu/ directory.
    "$SEPOLICY_TOOL" --live \
      "allow ksu same_process_hal_file dir { getattr setattr relabelto relabelfrom search read open write add_name remove_name }" \
      >/dev/null 2>&1 && \
      { RULES_SUCCESS=$((RULES_SUCCESS + 1)); log_boot "  [+] ksu -> same_process_hal_file dir (KSU-Next standalone)"; } || true
    # BUG FIX: unlabeled rules — new files created in same_process_hal_file dir get unlabeled
    # context (no type_transition on OEM ROMs); unlink+rename needed to rm/mv them.
    "$SEPOLICY_TOOL" --live \
      "allow ksu unlabeled file { getattr setattr relabelfrom unlink rename }" \
      >/dev/null 2>&1 && \
      { RULES_SUCCESS=$((RULES_SUCCESS + 1)); log_boot "  [+] ksu -> unlabeled file (KSU-Next standalone)"; } || true
    "$SEPOLICY_TOOL" --live \
      "allow ksu unlabeled dir { getattr setattr relabelfrom write add_name remove_name }" \
      >/dev/null 2>&1 && \
      { RULES_SUCCESS=$((RULES_SUCCESS + 1)); log_boot "  [+] ksu -> unlabeled dir (KSU-Next standalone)"; } || true
  fi

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
  unset _batch_ok _is_ksud_wrapper

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
if [ -f "$SYSTEM_PROP_FILE" ]; then
  awk -v pat="$RENDER_PROPS_REGEX" '{ if ($0 ~ pat) next; print }' \
    "$SYSTEM_PROP_FILE" > "${SYSTEM_PROP_FILE}.tmp" 2>/dev/null && \
    mv "${SYSTEM_PROP_FILE}.tmp" "$SYSTEM_PROP_FILE" 2>/dev/null || \
    rm -f "${SYSTEM_PROP_FILE}.tmp" 2>/dev/null
else
  touch "$SYSTEM_PROP_FILE" 2>/dev/null || true
fi


# ── FIRST BOOT SAFETY CHECK: REMOVED (Q7 decision) ───────────────────────────
# First-boot deferral removed. Renderer is now always applied on first boot.
# Vulkan safety is provided by the VK compat gate above (auto-degrades to
# skiagl when VK_DRIVER_FOUND=false), which is a real structural check rather
# than a blanket 2-boot delay. Clean up any stale markers from previous installs.
FIRST_BOOT_PENDING=false  # kept as variable for remaining code compatibility; always false now
rm -f "$MODDIR/.first_boot_pending" 2>/dev/null || true
rm -f "$MODDIR/.service_skip_render" 2>/dev/null || true
log_boot "[OK] First-boot deferral disabled — renderer applied immediately"

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
# Check if previous boot completed successfully (service.sh wrote this marker).
# This gates the skiavkthreaded backend: on first install (no marker) or after
# an SF freeze (service.sh never ran → no marker), fall back to skiaglthreaded.
# Deleting it here forces service.sh to re-earn it this boot.
# Worst-case: 1 skiaglthreaded boot after any regression; next boot re-promotes.
_PREV_BOOT_SUCCESS=false
[ -f "$MODDIR/.boot_success" ] && _PREV_BOOT_SUCCESS=true
rm -f "$MODDIR/.boot_success" 2>/dev/null || true
log_boot "[OK] Previous .boot_success cleared — must re-confirm this boot (prev_success=$_PREV_BOOT_SUCCESS)"

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
#   OR when the effective mode is skiavk regardless of mode change.
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

# ========================================
# GRAPHICS CACHE CLEARING — REVISED STRATEGY
# ========================================
#
# CACHE CLEAR POLICY — mode-change detection only (mirrors LYB Kernel Manager):
#
#   ALL caches (/data/misc/gpu/, /data/misc/hwui/, per-app Skia/EGL) are
#   cleared ONLY when RENDER_MODE changes (GL↔Vulkan blob format incompatibility)
#   or on first boot (no state file). On stable boots, ALL caches are preserved.
#
#   This is identical to LYB Kernel Manager, which never clears any cache on
#   QGL enable/disable or on stable boots. LYB has zero cache-related crash
#   reports. Preserving caches means apps and SF load programs compiled in the
#   same configuration as the current session → consistent → no crash.
#
# WHY CLEARING /data/misc/gpu/ EVERY BOOT CAUSED THE CRASH:
#   See detailed explanation in the TIER 1 comment block below.
# ========================================

# ========================================
# TWO-TIER CACHE CLEAR APPROACH
# ========================================
# TIER 1 — SYSTEM CACHES: always clear every boot
# TIER 2 — PER-APP CACHES: clear only on mode-change or first QGL enable
# ========================================

# ── TIER 1: System caches — ALWAYS clear every boot ──────────────────────
# /data/misc/gpu/  — SurfaceFlinger + gralloc EGL blob cache
# /data/misc/hwui/ — HWUI pipeline key cache
#
# WHY ALWAYS: qgl_config.txt is at mode=0000 during early boot (protected).
# SF and SystemUI load these caches during boot animation BEFORE the lock
# screen, BEFORE boot_completed fires. If the previous boot wrote QGL-compiled
# shader binaries here, this boot's SF reads them WITHOUT QGL (file is 0000)
# → driver state mismatch → SF watchdog crash → hang at ROM logo. Always
# clearing prevents this. These dirs are tiny; SF rebuilds in milliseconds.
log_boot "========================================"
log_boot "SYSTEM GPU CACHE CLEAR (every boot — prevents ROM logo bootloop):"
log_boot "  /data/misc/gpu/  — SurfaceFlinger EGL blob cache (keyed on QGL settings)"
log_boot "  /data/misc/hwui/ — HWUI pipeline key cache"
log_boot "  SF loads these BEFORE lock screen; stale QGL blobs → SF crash → ROM logo hang."
log_boot "========================================"
rm -rf /data/misc/hwui/ 2>/dev/null || true
rm -rf /data/misc/gpu/  2>/dev/null || true
log_boot "[OK] System GPU/HWUI caches cleared."

# ── TIER 2: Per-app caches — settings-change detection ───────────────────
_CS_STATE_FILE="/data/local/tmp/adreno_last_cleared_state"
_CS_PREV_MODE=""
_CS_PREV_QGL=""
_CS_PREV_HASH=""
if [ -f "$_CS_STATE_FILE" ]; then
  {
    IFS= read -r _CS_PREV_MODE
    IFS= read -r _CS_PREV_QGL
    IFS= read -r _CS_PREV_HASH
  } < "$_CS_STATE_FILE" 2>/dev/null || true
fi

# Compute a lightweight hash of the active qgl_config source file.
# cksum is POSIX (busybox + toybox both provide it on Android 7–17+).
# Hash is "none" when QGL is disabled so a QGL-off→QGL-on transition is caught
# by the QGL-toggle check rather than requiring a real hash comparison.
_CS_CUR_HASH="none"
if [ "$QGL" = "y" ]; then
  for _cs_qsrc in \
      "/sdcard/Adreno_Driver/Config/qgl_config.txt" \
      "/data/local/tmp/qgl_config.txt" \
      "$MODDIR/qgl_config.txt"; do
    if [ -f "$_cs_qsrc" ]; then
      _CS_CUR_HASH=$(cksum "$_cs_qsrc" 2>/dev/null | awk '{print $1}') || _CS_CUR_HASH="cksum_fail"
      break
    fi
  done
  unset _cs_qsrc
fi

# Rotate QGL logs if they exist
rotate_log "$QGL_TRIGGER_LOG"
rotate_log "$QGL_DIAG_LOG"

# Build reason string — empty means no clear needed.
_CS_REASON=""

# Reason 1: render mode changed (GL↔Vulkan pipeline blob format is incompatible)
#
# WHY QGL CHANGES NO LONGER TRIGGER A CLEAR (Reasons 2 & 3 removed):
#   Custom Adreno drivers have a bug in qglinternal::vkCreateGraphicsPipelines →
#   QGLCCompileToIRShader that crashes during COLD (fresh) shader compilation when
#   QGL settings are active. Clearing caches forces a full cold recompile on the
#   next session → crash. LYB Kernel Manager NEVER clears caches and works fine
#   because apps always reuse existing compiled pipeline blobs — QGLCCompileToIRShader
#   is never called. QGL settings affect new compilations only; existing cached
#   blobs remain valid regardless of QGL state change.
#   FIX: Only clear when RENDER_MODE changes (GL↔Vulkan binary format incompatibility
#   is the ONLY case where cached blobs cannot be safely reused).
#
# WHY first_boot IS COVERED HERE (Reason 4 removed):
#   When no state file exists, _CS_PREV_MODE="". Any configured RENDER_MODE != ""
#   makes this condition true — mode_change fires and covers the first-boot case.
# Reason 1: render mode changed (GL↔Vulkan pipeline blob format is incompatible)
if [ "$RENDER_MODE" != "$_CS_PREV_MODE" ]; then
  _CS_REASON="mode_change(${_CS_PREV_MODE:-<none>}→${RENDER_MODE})"
fi

# Reason 2: REMOVED (qgl_first_enable).
# Clearing caches when QGL is first enabled forces cold pipeline compilation
# WITH QGL active → QGLCCompileToIRShader crash on custom Adreno 610 v0762.41.
# The 0000 protection + 20s boot-completed.sh delay ensure QGL activates AFTER
# the launcher has initialised, so no cold compile ever happens with QGL active.
# LYB never clears caches on first enable either.

if [ -n "$_CS_REASON" ]; then
  log_boot "========================================"
  log_boot "FULL GRAPHICS CACHE CLEAR (settings changed):"
  log_boot "  Reason : $_CS_REASON"
  log_boot "  Previous state : mode=${_CS_PREV_MODE:-<none>} qgl=${_CS_PREV_QGL:-<none>} hash=${_CS_PREV_HASH:-<none>}"
  log_boot "  Current  state : mode=${RENDER_MODE} qgl=${QGL} hash=${_CS_CUR_HASH}"
  log_boot "  Clearing ALL caches (system + per-app) BEFORE Zygote starts."
  log_boot "========================================"

  # ── Tier-1: System caches ─────────────────────────────────────────────────
  # Only on mode change — ShaderCache self-validates via pipelineCacheUUID.
  rm -rf /data/misc/hwui/ 2>/dev/null || true
  rm -rf /data/misc/gpu/  2>/dev/null || true
  log_boot "[OK] Tier-1: /data/misc/hwui/ and /data/misc/gpu/ cleared (mode changed)."

  # ── Tier-2: Per-app Skia/EGL caches ────────────────────────────────────
  # Per-app Skia Vulkan/GL pipeline caches — primary crash culprit on mode switch.
  # DEPTH: /data/user_de/<uid>/<pkg>/code_cache/app_skia_pipeline_cache/ = 4 levels deep.
  # All UIDs (primary + work-profile) covered by omitting the uid filter.
  find /data/user_de -maxdepth 4 -type d -name "app_skia_pipeline_cache" \
      -exec rm -rf {} + 2>/dev/null || true
  # Legacy /data/data path (pre-Android 7 / direct-boot disabled devices)
  find /data/data -maxdepth 3 -type d -name "app_skia_pipeline_cache" \
      -exec rm -rf {} + 2>/dev/null || true

  # Skia shader journal manifests
  find /data/user_de -maxdepth 4 -name "*.shader_journal" -delete 2>/dev/null || true

  # Skia shader + pipeline cache sub-directories
  find /data/user_de -maxdepth 4 -type d \( -name "skia_shaders" -o -name "shader_cache" \) \
      -exec rm -rf {} + 2>/dev/null || true

  # EGL blob cache — per-app compiled OpenGL shader binaries, keyed on driver+QGL settings.
  find /data/user_de -maxdepth 4 -name "com.android.opengl.shaders_cache" \
      -delete 2>/dev/null || true
  find /data/data -maxdepth 3 -name "com.android.opengl.shaders_cache" \
      -delete 2>/dev/null || true

  # Skia shader cache — SPIR-V/GLSL programs compiled by Skia; separate from pipeline cache.
  find /data/user_de -maxdepth 4 -name "com.android.skia.shaders_cache" \
      -delete 2>/dev/null || true
  find /data/data -maxdepth 3 -name "com.android.skia.shaders_cache" \
      -delete 2>/dev/null || true

  log_boot "[OK] Full graphics cache clear complete (Tier-1 + Tier-2)."
  log_boot "     Cleared: /data/misc/gpu/, /data/misc/hwui/, Skia pipeline, EGL blob, Skia shader caches."
  log_boot "     Shaders/programs will recompile lazily on first use — no batch OOM spike."

  # Persist the new cleared state so next boot can skip the clear if settings are unchanged.
  printf '%s\n%s\n%s\n' "$RENDER_MODE" "$QGL" "$_CS_CUR_HASH" \
    > "$_CS_STATE_FILE" 2>/dev/null || true
  log_boot "[OK] Cleared state persisted: mode=$RENDER_MODE qgl=$QGL hash=$_CS_CUR_HASH"

  # Write skip-forcestop marker — cache was cleared; signal next phase.
  # active simultaneously → QGLCCompileToIRShader crash → black screen / crash loop.
  # Marker is removed by service.sh after reading, and cleared on next stable boot.
  touch /data/local/tmp/adreno_skip_forcestop 2>/dev/null || true
  log_boot "[OK] skip-forcestop marker written (caches cleared this boot)"

else
  log_boot "CACHE CLEAR: settings unchanged — ALL caches PRESERVED (Tier-1 + Tier-2)."
  log_boot "  mode=$RENDER_MODE qgl=$QGL hash=${_CS_CUR_HASH} (matches last cleared state)"
  log_boot "  Preserving /data/misc/gpu/ prevents SF/app GPU program mismatch on QGL boots."
  log_boot "  Preserving per-app caches prevents shader-recompile OOM (Facebook 2000+ shaders)."
fi

unset _CS_PREV_MODE _CS_PREV_QGL _CS_PREV_HASH _CS_CUR_HASH _CS_REASON _CS_STATE_FILE

# Backward compat: remove old single-line mode file if present from a previous install.
rm -f /data/local/tmp/adreno_last_render_mode 2>/dev/null || true

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

if [ "$RENDER_MODE" = "skiavk" ]; then

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
  # Write full per-subsystem detail to adreno_vk_compat_full for tools that need
  # more than the summary score (e.g. advanced diagnostic scripts).
  # write_compat_state() is defined in common.sh — sourced above.
  write_compat_state

  _FORCE_OVERRIDE_MARKER="/data/local/tmp/adreno_skiavk_force_override"
  _DEGRADE_REASON=""

  if [ "$VK_COMPAT_LEVEL" = "blocked" ]; then
    # Q3 decision: auto-degrade ONLY when no Vulkan driver .so is found (structurally
    # impossible to run Vulkan). If the driver .so exists, warn and stay — the probe
    # is a conservative heuristic; many real devices score "blocked" due to gralloc
    # mismatch or old vendor strings but run skiavk perfectly fine.
    if [ -f "$_FORCE_OVERRIDE_MARKER" ]; then
      log_boot "[OVERRIDE] compat=blocked but force-override present — keeping $RENDER_MODE"
    elif [ "$VK_DRIVER_FOUND" = "false" ]; then
      # No vulkan.*.so anywhere — Vulkan is structurally impossible.
      _DEGRADE_REASON="compat_blocked_no_driver(score=${VK_COMPAT_SCORE})"
      log_boot "[AUTO-DEGRADE] compat=blocked + no Vulkan driver .so found → skiagl"
      log_boot "  Cannot use skiavk: no vulkan.*.so found in vendor/system paths"
    else
      log_boot "========================================="
      log_boot "[WARNING] compat=blocked (score=${VK_COMPAT_SCORE}/100) but driver present — proceeding with $RENDER_MODE"
      log_boot "  Reasons: ${VK_COMPAT_REASONS:-none recorded}"
      log_boot "  Vulkan may exhibit glitches on this ROM/vendor; HWUI falls back to GL automatically if it fails."
      log_boot "  To force skiagl: echo skiagl > /sdcard/Adreno_Driver/Config/adreno_config.txt"
      log_boot "========================================="
    fi

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
      # DEGRADE-MARKER FIX: delete stale degraded marker so service.sh BUG3-fix
      # does not override RENDER_MODE to skiagl in the live resetprop block.
      # risky+driver = module proceeds with skiavk; marker is not applicable.
      rm -f "/data/local/tmp/adreno_skiavk_degraded" 2>/dev/null || true
    fi

  elif [ "$VK_COMPAT_LEVEL" = "marginal" ]; then
    log_boot "[MARGINAL] score=${VK_COMPAT_SCORE} — keeping $RENDER_MODE with watchdog"
    # DEGRADE-MARKER FIX: delete stale degraded marker — marginal means proceed
    # with skiavk (watchdog active). Keeping the marker would cause service.sh
    # to override RENDER_MODE to skiagl in the live resetprop block every boot.
    rm -f "/data/local/tmp/adreno_skiavk_degraded" 2>/dev/null || true

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
if [ "$RENDER_MODE" = "skiavk" ]; then
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
    skiavk) ;;
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
  skiavk)
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
      # ── FIX-C-1: system.prop reduced to ≤10 ESSENTIAL PERSISTENCE-ONLY props ────
      # Previous version wrote 56+ props to system.prop, causing "Found hole in
      # prop area" on devices with small prop context buckets. Only props that
      # MUST survive reboot via system.prop are written here. ALL other tuning
      # props are set exclusively via resetprop (below) for the live session.
      #
      # Why these 10:
      #   debug.hwui.renderer — persistence across reboot (live resetprop below)
      #   com.qc.hardware — Qualcomm ION buffer path gate (no resetprop equiv)
      #   persist.sys.force_sw_gles — ensure HW GLES (persist.* must be in prop file)
      #   debug.vulkan.layers= — clear OEM debug layers (must survive reboot)
      #   debug.vulkan.dev.layers= — clear OEM dev layers (must survive reboot)
      #   persist.graphics.vulkan.validation_enable=0 — kill validation (persist.*)
      #   graphics.gpu.profiler.support=false — kill profiler (no resetprop equiv)
      #   debug.egl.debug_proc= — clear OEM EGL hook (must survive reboot)
      #   ro.zygote.disable_gl_preload=true — prevent GL preload in skiavk (invariant I-1)
      #   ro.surface_flinger.protected_contents=true — existing static prop
      #
      # debug.renderengine.backend is INTENTIONALLY NOT in system.prop.
      # OEM ROMs (MIUI/OneUI/ColorOS) register addChangeCallback for this prop.
      # If init loads it from system.prop and value changes at runtime via resetprop,
      # SF fires RenderEngine reinit mid-frame → crash → watchdog reboot.
      # Set exclusively via resetprop BEFORE SF starts (below).

      printf 'debug.hwui.renderer=skiavk\n'
      printf 'com.qc.hardware=true\n'
      printf 'persist.sys.force_sw_gles=0\n'
      printf 'debug.vulkan.layers=\n'
      printf 'debug.vulkan.dev.layers=\n'
      printf 'persist.graphics.vulkan.validation_enable=0\n'
      printf 'graphics.gpu.profiler.support=false\n'
      printf 'debug.egl.debug_proc=\n'
      printf 'ro.zygote.disable_gl_preload=true\n'
      printf 'ro.surface_flinger.protected_contents=true\n'
    } >> "$SYSTEM_PROP_FILE" 2>/dev/null
    log_boot "[OK] system.prop: skiavk props written (10 props). FIX-C-1: reduced from 56+ to prevent prop area overflow. All tuning props via resetprop only."
    # Apply live for this boot session via resetprop
    # ── CRITICAL: renderer props set ONLY via resetprop, NEVER system.prop ──
    # This ensures the renderer is only activated AFTER the module's Vulkan
    # driver overlay is mounted, preventing crashes on legacy/OEM devices where
    # system.prop is loaded before module overlays are applied.
    # First-boot deferral removed (Q7) — renderer always applied.
    if command -v resetprop >/dev/null 2>&1; then
      # ── skiavk: set HWUI renderer + SF compositor ────────
      # debug.hwui.renderer   — per-app HWUI rendering (Vulkan via skiavk)
      # debug.renderengine.backend — SurfaceFlinger compositor engine
      #   skiavkthreaded = SkiaVkRenderEngine (Android 14+ / API 34+)
      #   skiaglthreaded = threaded GL compositor (all Android versions, safe fallback)
      # Must be set here (post-fs-data, pre-SF). Setting after SF starts triggers OEM
      # addChangeCallback → RenderEngine reinit mid-frame → SF crash.
      resetprop debug.hwui.renderer skiavk
      # debug.renderengine.backend — SurfaceFlinger compositor engine.
      #   skiavkthreaded = SkiaVkRenderEngine (fully implemented Android 14+ / API 34+).
      #   skiaglthreaded = threaded GL compositor (safe fallback for API < 34).
      #
      # Decision logic:
      #   FORCE_SKIAVKTHREADED_BACKEND=y  -> always skiavkthreaded regardless of API.
      #   _PREV_BOOT_SUCCESS=false        -> skiaglthreaded (first boot after install
      #                                      or after an SF freeze; safe landing).
      #   _PREV_BOOT_SUCCESS=true
      #     + SDK >= 34                   -> skiavkthreaded (promoted after confirmed good boot)
      #     + SDK < 34                    -> skiaglthreaded (API too old for SkiaVkRenderEngine)
      #
      # WHY _PREV_BOOT_SUCCESS gate:
      #   skiavkthreaded causes SF to freeze on some ROMs on the FIRST boot after
      #   install (Vulkan ICD not yet warmed up, shader cache empty → SF watchdog fires
      #   → watchdog reboot before service.sh can reset BOOT_ATTEMPTS → counter climbs
      #   → module auto-disabled → black screen). Using skiaglthreaded on first boot
      #   avoids the freeze; service.sh writes .boot_success → next boot promotes to
      #   skiavkthreaded cleanly. Worst-case regression cost: 1 extra skiaglthreaded boot.
      _re_sdk=$(getprop ro.build.version.sdk 2>/dev/null || echo "0")
      if [ "$FORCE_SKIAVKTHREADED_BACKEND" = "y" ]; then
        resetprop debug.renderengine.backend skiavkthreaded
        if [ "$_re_sdk" -lt 34 ] 2>/dev/null; then
          log_boot "[OK] renderengine.backend=skiavkthreaded (FORCE_SKIAVKTHREADED_BACKEND=y, SDK=${_re_sdk} < 34 — forced)"
        else
          log_boot "[OK] renderengine.backend=skiavkthreaded (FORCE_SKIAVKTHREADED_BACKEND=y, SDK=${_re_sdk})"
        fi
      elif [ "$_PREV_BOOT_SUCCESS" = "true" ] && [ "$_re_sdk" -ge 34 ] 2>/dev/null; then
        # QGL-specific adreno_vk_compat gate REMOVED — the "warm stack" assumption was
        # factually incorrect. HWUI Vulkan (per-process, app layer) and SF's own
        # vkCreateInstance (compositor process) are completely independent contexts;
        # warming one does NOT warm the other.
        #
        # The gate caused a 3-boot auto-disable cascade:
        #   boot 1: _PREV_BOOT_SUCCESS=false → skiaglthreaded (safe) → service.sh runs
        #           → writes .boot_success + adreno_vk_compat=confirmed
        #   boot 2: _PREV_BOOT_SUCCESS=true, vk_compat=confirmed → gate passes
        #           → skiavkthreaded + QGL → SF freeze → watchdog reboot
        #           → service.sh NEVER runs → BOOT_ATTEMPTS not reset → counter = 2
        #   boot 3-4: same freeze → BOOT_ATTEMPTS exceeds MAX → module auto-disabled
        #
        # Alternatively if the canary never wrote "confirmed" (strict OEM gfxinfo format,
        # SystemUI not fully drawn when dumpsys ran), every boot used skiaglthreaded
        # with QGL permanently broken — no bootloop but feature never activated.
        #
        # The old codebase applied skiavkthreaded unconditionally (no QGL gate) and
        # worked correctly on this device. The _PREV_BOOT_SUCCESS gate is the correct
        # and sufficient first-boot safety. QGL does not require an additional gate.
        resetprop debug.renderengine.backend skiavkthreaded
        log_boot "[OK] renderengine.backend=skiavkthreaded (prev boot confirmed, SDK=${_re_sdk})"
      else
        resetprop debug.renderengine.backend skiaglthreaded
        if [ "$_PREV_BOOT_SUCCESS" = "false" ]; then
          log_boot "[OK] renderengine.backend=skiaglthreaded (first boot or prev boot failed — promoting to skiavkthreaded next boot after success)"
        else
          log_boot "[OK] renderengine.backend=skiaglthreaded (SDK=${_re_sdk} < 34; set FORCE_SKIAVKTHREADED_BACKEND=y to override)"
        fi
      fi
      unset _re_sdk
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
       # NOTE: Removed use_buffer_age, use_partial_updates, use_gpu_pixel_buffers, reduceopstasksplitting
       # These hurt performance on stock drivers - now using AOSP defaults (true)
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
      # treat_170m_as_sRGB: only safe on sRGB-only (non-WCG) displays.
      # Skip on WCG/HDR devices (ro.surface_flinger.use_color_management=1).
      _wcg=$(getprop ro.surface_flinger.use_color_management 2>/dev/null || echo "")
      if [ "$_wcg" != "1" ] && [ "$_wcg" != "true" ]; then
        resetprop debug.sf.treat_170m_as_sRGB 1
      fi
      unset _wcg
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

    # FIRST_BOOT_PENDING guard removed (Q7); resetprop check kept.
    if command -v resetprop >/dev/null 2>&1; then

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

        # ── FIX-C-4: Old-vendor prop re-application (replacing watchdog) ──────
        # Previous code launched a 150-second background watchdog that polled
        # every 3-5 seconds. This consumed CPU, spawned >30 getprop processes,
        # and prevented deep sleep.
        #
        # Replacement: A single delayed re-application at post-fs-data + 15s.
        # This covers the vendor_init late_start service window (typically
        # fires within 10-15s of post-fs-data). service.sh adds a second
        # re-application at boot_completed + 10s as a belt-and-suspenders.
        (
          sleep 15
          _cur=$(getprop debug.hwui.renderer 2>/dev/null || echo "")
          if [ "$_cur" != "skiavk" ]; then
            resetprop debug.hwui.renderer skiavk 2>/dev/null || true
            echo "[ADRENO-OLDVENDOR][15s] vendor_init override detected! Was '${_cur}', re-applied skiavk" > /dev/kmsg 2>/dev/null || true
          else
            echo "[ADRENO-OLDVENDOR][15s] renderer stable (${_cur})" > /dev/kmsg 2>/dev/null || true
          fi
          rm -f /data/local/tmp/adreno_watchdog_pid 2>/dev/null || true
        ) &
        _wd_pid=$!
        printf '%d\n' "$_wd_pid" > /data/local/tmp/adreno_watchdog_pid 2>/dev/null || true
        log_boot "[OK] Old-vendor one-shot re-apply armed (PID=$_wd_pid, +15s delay) — replaces 150s watchdog"
        unset _wd_pid

      else
        log_boot "Old vendor check: CLEAN (vendor/build.prop hwui='${VENDOR_HWUI_PROP:-<none>}')"
        # Write clean state — service.sh reads this to skip old-vendor extra work
        printf 'clean\n' > "$_OLD_VENDOR_FILE" 2>/dev/null || true
      fi
      unset _OLD_VENDOR_FILE
    fi
    # ══ END OLD VENDOR DETECTION ═════════════════════════════════════════════

    # NOTE: The old redundant renderer re-enforcement subshell (previously at
    # lines 2507-2518) was removed. The watchdog launched above already covers
    # the same ground: it re-enforces debug.hwui.renderer=skiavk every 3-5s
    # from post-fs-data through boot_completed+60s. No duplicate needed.
    ;;

  skiagl)
    {
      # ── FIX-C-1: system.prop reduced to ≤10 ESSENTIAL PERSISTENCE-ONLY props ────
      # Same rationale as skiavk block: prevent prop area overflow on devices
      # with small prop context buckets. Only persistence-required props here.
      # All tuning props are set exclusively via resetprop (below).
      printf 'debug.hwui.renderer=skiagl\n'
      printf 'com.qc.hardware=true\n'
      printf 'persist.sys.force_sw_gles=0\n'
       printf 'debug.vulkan.layers=\n'
       printf 'debug.vulkan.dev.layers=\n'
       printf 'persist.graphics.vulkan.validation_enable=0\n'
       printf 'graphics.gpu.profiler.support=false\n'
       printf 'debug.egl.debug_proc=\n'
       # Removed use_buffer_age, use_partial_updates - using AOSP defaults for max perf
     } >> "$SYSTEM_PROP_FILE" 2>/dev/null
    log_boot "[OK] system.prop: skiagl props written (10 props). FIX-C-1: reduced from 58+ to prevent prop area overflow. All tuning props via resetprop only."
    if command -v resetprop >/dev/null 2>&1; then
      # ── renderer props set ONLY via resetprop (see skiavk section for why) ──
      # FIRST_BOOT_PENDING guard removed (Q7) — always applies now.
      resetprop debug.hwui.renderer skiagl
      resetprop debug.renderengine.backend skiaglthreaded
      resetprop persist.sys.force_sw_gles 0
       resetprop com.qc.hardware true
       # NOTE: Removed use_buffer_age, use_partial_updates, reduceopstasksplitting
       # Using AOSP defaults for max performance
       resetprop debug.hwui.render_dirty_regions false
       resetprop debug.hwui.webview_overlays_enabled true
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
       # Removed use_gpu_pixel_buffers - using AOSP default (true) for max performance
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

    # Re-enforce skiagl renderer prop after boot_completed (no force-stops)
    (
        _WAIT=0
        while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ] && [ $_WAIT -lt 90 ]; do
          sleep 3; _WAIT=$((_WAIT + 3))
        done
        [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ] && exit 0
        if command -v resetprop >/dev/null 2>&1; then
          resetprop debug.hwui.renderer skiagl 2>/dev/null || true
        fi
    ) >/dev/null 2>&1 &
    log_boot "[OK] skiagl: renderer re-enforced after boot_completed (no force-stops)"
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
                  # Removed from delete: use_buffer_age, use_partial_updates, use_gpu_pixel_buffers, reduceopstasksplitting
                  # Letting OEM defaults persist for max performance
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
# QGL CONFIGURATION — DEFERRED TO boot-completed.sh
# ========================================
# LYB Kernel Manager NEVER writes qgl_config.txt pre-zygote. It writes
# exclusively at BOOT_COMPLETED broadcast time (via onboot BroadcastReceiver).
# Writing it here (post-fs-data) causes:
#   - Pre-zygote: SF reads QGL during boot → caches compiled with QGL
#   - If file is 0000 (protected): SF gets EACCES → no-QGL caches
#   - When boot-completed.sh activates (0644): mixed QGL/no-QGL contexts
#     on same KGSL device → cascade crash → black screen → bootloop
#
# FIX: do NOT install qgl_config.txt here at all. boot-completed.sh handles
# it exclusively at the correct timing (boot_completed + 3s stabilization).
# The /data/vendor/gpu directory is pre-created below for SELinux readiness.

if [ "$QGL" = "y" ]; then
  log_boot "QGL: enabled — installation deferred to boot-completed.sh (LYB timing)"
  # Pre-create directory with correct context so boot-completed.sh has a
  # ready target. This is safe — no file exists yet, just the directory.
  mkdir -p /data/vendor/gpu 2>/dev/null || true
  chcon u:object_r:same_process_hal_file:s0 /data/vendor/gpu 2>/dev/null || true
  # Remove any stale file from a crashed previous boot to ensure clean state
  rm -f /data/vendor/gpu/qgl_config.txt 2>/dev/null || true
  log_boot "[OK] QGL: /data/vendor/gpu pre-created, stale file cleared"
else
  log_boot "QGL configuration disabled"
  # If QGL is disabled, clean up any existing file
  rm -f /data/vendor/gpu/qgl_config.txt 2>/dev/null || true
  rm -f /data/vendor/gpu/.adreno_qgl_owner 2>/dev/null || true
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

# ── QGL data directory setup (ALL OEMs) ─────────────────────────────────────
# GPU HAL writes shader caches here at runtime. It runs in the 'system'
# group (GID 1000). 0775 = owner+group write. 0755 would deny group
# writes → HAL can't create caches → crash → SurfaceFlinger restart loop.
# same_process_hal_file is required for BOTH the directory and qgl_config.txt.
# The Adreno driver validates both contexts before reading the config file.
if [ "$QGL" = "y" ]; then
  mkdir -p /data/vendor/gpu 2>/dev/null || true
  chcon u:object_r:same_process_hal_file:s0 /data/vendor/gpu 2>/dev/null || true
  log_boot "QGL directory context set to same_process_hal_file (dir+file both required by driver)"
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
log_boot "Configuration: PLT=$PLT, QGL=$QGL, RENDER=$RENDER_MODE, FIRST_BOOT_DEFERRAL=disabled"
log_boot "Metamodule active: $METAMODULE_ACTIVE"
log_boot "SUSFS (root hiding): $SUSFS_ACTIVE"
log_boot "OEM ROM: $OEM_TYPE"
if [ "$ROOT_TYPE" = "APatch" ]; then
  log_boot "APatch Mode: $APATCH_MODE"
fi
log_boot "SELinux: Synchronous injection complete (${RULES_SUCCESS:-0} rules applied)"
log_boot "========================================"

# ── BOOT MARKER ──────────────────────────────────────────────────────────────
# Written at the very end of post-fs-data.sh so boot-completed.sh can identify
# caches that were written AFTER this point (i.e., by apps forked from Zygote
# during early boot, before QGL activated). Only those NEW caches need clearing
# at boot_completed time — not the full per-app sweep we may have done above.
# This keeps the boot_completed cache clear targeted and minimal, preventing
# unnecessary shader recompilation while still fixing the black home screen.
touch /data/local/tmp/adreno_post_fs_data_done 2>/dev/null || true

exit 0
