#!/system/bin/sh
# Adreno GPU Driver - Service Script
# Compatible with: Magisk, KernelSU, APatch
# Runs in late_start service mode (NON-BLOCKING)
# Executes after boot_completed, modules mounted, and Zygote started.
#
# Developer  : @pica_pica_picachu
# Channel    : @zesty_pic (driver channel)
#
# ⚠️  ANTI-THEFT NOTICE ⚠️
# This module was developed by @pica_pica_picachu.
# If someone claims this as their own work and asks for
# donations — report them immediately to @zesty_pic.

MODDIR="${0%/*}"

# ========================================
# SHARED FUNCTIONS
# ========================================

. "$MODDIR/common.sh"

cmd_exists() {
  command -v "$1" >/dev/null 2>&1
}

safe_read() {
  local _sr
  { IFS= read -r _sr; } < "$1" 2>/dev/null && printf '%s' "${_sr%$(printf '\r')}"
}

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

CONFIG_FILE="/sdcard/Adreno_Driver/Config/adreno_config.txt"
DATA_CONFIG="/data/local/tmp/adreno_config.txt"
ALT_CONFIG="$MODDIR/adreno_config.txt"

# Priority: /data/local/tmp (authoritative mirror from previous boot) →
#           /sdcard (if mirror not yet created) → $MODDIR (bundled defaults)
# This matches post-fs-data.sh's priority order so both scripts see the same
# config values during the same boot cycle.
if ! load_config "$DATA_CONFIG"; then
  if ! load_config "$CONFIG_FILE"; then
    load_config "$ALT_CONFIG" || true
  fi
fi

[ "$VERBOSE" != "y" ]   && VERBOSE="n"
[ "$ARM64_OPT" != "y" ] && ARM64_OPT="n"
[ "$QGL" != "y" ]       && QGL="n"
[ "$QGL_PERAPP" != "y" ] && QGL_PERAPP="n"
[ "$PLT" != "y" ]       && PLT="n"
[ -z "$RENDER_MODE" ]   && RENDER_MODE="normal"
# BUG7 FIX: Normalize RENDER_MODE to lowercase so case statements match
# regardless of how the user wrote it in the config (SkiaVK, SKIAVK, etc.).
RENDER_MODE=$(printf '%s' "$RENDER_MODE" | tr '[:upper:]' '[:lower:]')
# Legacy: skiavkthreaded/skiaglthreaded were removed as standalone modes.
# common.sh normalizes them on load, but guard here in case of direct writes.
[ "$RENDER_MODE" = "skiavkthreaded" ] && RENDER_MODE="skiavk"
[ "$RENDER_MODE" = "skiaglthreaded" ] && RENDER_MODE="skiagl"
[ "$FORCE_SKIAVKTHREADED_BACKEND" != "y" ] && FORCE_SKIAVKTHREADED_BACKEND="n"

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
  _log_emit() { log_service "$1"; }
else
  log_service() { :; }
  _log_emit() { :; }
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

log_service "Configuration: ARM64_OPT=$ARM64_OPT, QGL=$QGL, QGL_PERAPP=$QGL_PERAPP, PLT=$PLT, RENDER_MODE=$RENDER_MODE, FORCE_SKIAVKTHREADED_BACKEND=$FORCE_SKIAVKTHREADED_BACKEND"

# ── skiavk + QGL_PERAPP=n warning ────────────────────────────────────────
if [ "$QGL" = "y" ] && [ "$QGL_PERAPP" = "n" ] && [ "$RENDER_MODE" = "skiavk" ]; then
  log_service "[WARN] skiavk + QGL_PERAPP=n: apps launched before boot_completed+3s receive NO QGL config at Vulkan init time"
  log_service "[WARN] This directly degrades benchmark scores. Set QGL_PERAPP=y in adreno_config.txt to fix."
fi

# Unconditional kmsg checkpoint: confirms service.sh reached this point and
# is visible in `dmesg | grep ADRENO-SVC` regardless of VERBOSE=n.
# Diagnose silently-killed service.sh by checking for this line in dmesg.
printf '[ADRENO-SVC] init complete (root=%s render=%s qgl=%s)\n' \
  "$ROOT_TYPE" "$RENDER_MODE" "$QGL" > /dev/kmsg 2>/dev/null || true

# ========================================
# WAIT FOR BOOT COMPLETION
# ========================================

log_service "Waiting for boot completion..."

TIMEOUT=300
ELAPSED=0

# ── KernelSU-Next resetprop -w deadlock fix ───────────────────────────────
# service.sh runs in late_start, which Android fires AFTER sys.boot_completed
# is already "1". On KernelSU-Next (rifsxd fork), `resetprop -w NAME VALUE`
# waits for the NEXT CHANGE EVENT rather than returning when the current value
# already matches the target. Since sys.boot_completed is permanently "1"
# after boot, `resetprop -w sys.boot_completed 1` blocks indefinitely → the
# 300s kill-$$ timeout fires → service.sh is killed → VK canary
# write, renderer enforcement, and ALL subsequent work never execute.
#
# Fix: check if already booted BEFORE calling resetprop -w. If the prop is
# already "1" (the normal case for late_start on all root managers), skip the
# wait entirely. resetprop -w is only needed when service.sh starts before
# boot_completed — which should not happen in late_start mode but is handled
# for safety.
# ─────────────────────────────────────────────────────────────────────────────
if [ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ]; then
  log_service "Boot already completed on service.sh entry (sys.boot_completed=1)"
  printf '[ADRENO-SVC] boot_completed=1 on entry — skip wait\n' > /dev/kmsg 2>/dev/null || true
elif cmd_exists resetprop; then
  log_service "Waiting for boot completion via resetprop -w..."
  (
    sleep $TIMEOUT
    kill $$ 2>/dev/null
  ) &
  TIMEOUT_PID=$!

  # sys.boot_completed goes ""→"1" at boot_completed, never "0".
  # resetprop -w NAME VALUE blocks until NAME==VALUE.
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
# Record boot_completed timestamp for CASE A timing guard below.
_BOOT_COMPLETED_TS=$(cat /proc/uptime 2>/dev/null | awk '{print int($1)}' || echo "0")

# ========================================
# EARLY QGL ACTIVATION FAST-PATH
# ========================================
# ROOT CAUSE FIX: The full QGL CASE A section runs AFTER the 30s sdcard wait
# (line ~1568). On a FORCED_SKIAVKTHREADED_BACKEND=y device, post-fs-data
# writes 0000 on EVERY boot. service.sh must activate it. If the sdcard takes
# ~30s to mount, CASE A fires at boot_completed+32s — far too late.
# Symptom: user checks file, sees 0000, thinks fix "didn't work."
#
# FIX: Activate here — at boot_completed+2s — immediately after the
# stabilization sleep, BEFORE the sdcard wait, BEFORE the VK compat report,
# BEFORE everything else. The full CASE A/B/C verification loop still runs
# later for repair/drift correction.
if [ "$QGL" = "y" ]; then
  # Runs for skiavk and skiagl modes.
  # boot-completed.sh is PRIMARY activation (sleep 20s → cp → chmod 0644).
  # At boot+2s (this fast-path), boot-completed.sh is still sleeping.
  # This fast-path defers to boot-completed.sh for the actual activation.
  # If boot-completed.sh failed entirely (non-standard ROM, no tool), this
  # fast-path is the first and only activation attempt before CASE A/B/C.
  _eq="/data/vendor/gpu/qgl_config.txt"

  # PRE-STAT INJECTION — inject getattr BEFORE calling stat.
  # Without getattr, stat returns "" → case "" → "File absent" branch →
  # chmod never runs → QGL stuck at 0000. This is the stuck-at-0000 fix.
  for _eqb_pre in "/data/adb/ksud" "/data/adb/ksu/bin/ksud"; do
    [ -f "$_eqb_pre" ] && [ -x "$_eqb_pre" ] || continue
    "$_eqb_pre" sepolicy patch "allow su vendor_data_file file { getattr setattr relabelfrom relabelto create write unlink open read }" \
      >/dev/null 2>&1 || true
    "$_eqb_pre" sepolicy patch "allow su vendor_data_file dir { getattr search read open write add_name remove_name }" \
      >/dev/null 2>&1 || true
    "$_eqb_pre" sepolicy patch "allow su same_process_hal_file file { getattr setattr relabelto relabelfrom create write unlink open read }" \
      >/dev/null 2>&1 || true
    "$_eqb_pre" sepolicy patch "allow su same_process_hal_file dir { getattr setattr relabelto relabelfrom search read open write add_name remove_name }" \
      >/dev/null 2>&1 || true
    "$_eqb_pre" sepolicy patch "allow su unlabeled file { getattr setattr relabelfrom relabelto create write unlink open read }" \
      >/dev/null 2>&1 || true
    "$_eqb_pre" sepolicy patch "allow same_process_hal_file labeledfs filesystem associate" \
      >/dev/null 2>&1 || true
    break
  done
  for _eqb_pre in "$(command -v magiskpolicy 2>/dev/null)" \
                  "/data/adb/magisk/magiskpolicy" \
                  "/data/adb/ksu/bin/magiskpolicy" \
                  "/data/adb/ap/bin/magiskpolicy"; do
    [ -z "$_eqb_pre" ] && continue
    [ -f "$_eqb_pre" ] && [ -x "$_eqb_pre" ] || continue
    "$_eqb_pre" --live "allow su vendor_data_file file { getattr setattr relabelfrom relabelto create write unlink open read }" \
      >/dev/null 2>&1 || true
    "$_eqb_pre" --live "allow su vendor_data_file dir { getattr search read open write add_name remove_name }" \
      >/dev/null 2>&1 || true
    "$_eqb_pre" --live "allow su same_process_hal_file file { getattr setattr relabelto relabelfrom create write unlink open read }" \
      >/dev/null 2>&1 || true
    "$_eqb_pre" --live "allow su same_process_hal_file dir { getattr setattr relabelto relabelfrom search read open write add_name remove_name }" \
      >/dev/null 2>&1 || true
    "$_eqb_pre" --live "allow su unlabeled file { getattr setattr relabelfrom relabelto create write unlink open read }" \
      >/dev/null 2>&1 || true
    "$_eqb_pre" --live "allow same_process_hal_file labeledfs filesystem associate" \
      >/dev/null 2>&1 || true
    break
  done
  unset _eqb_pre

  _em=$(stat -c '%a' "$_eq" 2>/dev/null || echo "")
  case "$_em" in
    "0"|"00"|"000"|"0000")
      printf '[ADRENO-SVC] EARLY QGL FAST-PATH: mode=0000, checking if cache clear needed\n' \
        > /dev/kmsg 2>/dev/null || true

      _eq_state_file="/data/local/tmp/adreno_last_cleared_state"
      _eq_prev_mode=""
      _eq_prev_qgl=""
      _eq_prev_hash=""
      if [ -f "$_eq_state_file" ]; then
        {
          IFS= read -r _eq_prev_mode
          IFS= read -r _eq_prev_qgl
          IFS= read -r _eq_prev_hash
        } < "$_eq_state_file" 2>/dev/null || true
      fi
      _eq_cur_hash="none"
      if [ "$QGL" = "y" ]; then
        for _eq_qsrc in \
            "/sdcard/Adreno_Driver/Config/qgl_config.txt" \
            "/data/local/tmp/qgl_config.txt" \
            "$MODDIR/qgl_config.txt"; do
          if [ -f "$_eq_qsrc" ]; then
            _eq_cur_hash=$(cksum "$_eq_qsrc" 2>/dev/null | awk '{print $1}') || _eq_cur_hash="cksum_fail"
            break
          fi
        done
      fi

      _eq_need_clear="false"
      if [ "$_eq_prev_mode" != "$RENDER_MODE" ] || [ "$_eq_prev_qgl" != "$QGL" ] || [ "$_eq_prev_hash" != "$_eq_cur_hash" ]; then
        _eq_need_clear="true"
      fi
      unset _eq_state_file _eq_prev_mode _eq_prev_qgl _eq_prev_hash _eq_cur_hash

      if [ "$_eq_need_clear" = "true" ]; then
        printf '[ADRENO-SVC] EARLY QGL: state changed, clearing caches\n' > /dev/kmsg 2>/dev/null || true
        rm -rf /data/misc/hwui/ 2>/dev/null || true
        rm -rf /data/misc/gpu/ 2>/dev/null || true
      else
        printf '[ADRENO-SVC] EARLY QGL: state unchanged, PRESERVING caches\n' > /dev/kmsg 2>/dev/null || true
      fi
      unset _eq_need_clear

      # Try to chmod 0644 to activate
      chmod 0644 "$_eq" 2>/dev/null && \
        printf '[ADRENO-SVC] EARLY QGL: mode=0000 → 0644 success\n' > /dev/kmsg 2>/dev/null || \
        printf '[ADRENO-SVC] EARLY QGL: mode=0000 → chmod failed (selinux?)\n' > /dev/kmsg 2>/dev/null || true
      ;;
    "644")
      printf '[ADRENO-SVC] EARLY QGL: mode=0644 already, deferring to boot-completed.sh\n' \
        > /dev/kmsg 2>/dev/null || true
      ;;
    *)
      printf '[ADRENO-SVC] EARLY QGL: mode=%s, checking status\n' "$_em" > /dev/kmsg 2>/dev/null || true
      if [ -f "$_eq" ]; then
        chmod 0644 "$_eq" 2>/dev/null || true
      fi
      ;;
  esac
  unset _eq _em
fi

# QGL activation is handled EXCLUSIVELY by boot-completed.sh (display-stable timing).
# Per-app QGL is handled by the QGL Trigger APK (AccessibilityService).
# Cache clearing is handled EXCLUSIVELY by post-fs-data.sh (before Zygote starts).
# service.sh does NOT touch QGL — no chmod, no chcon, no cp, no cache clearing.

# ── Install QGL Trigger APK if bundled and QGL_PERAPP=y ──────────────────
# The APK provides the AccessibilityService that detects app switches and
# applies per-app QGL configs via apply_qgl.sh <package_name>.
# Only installs when QGL=y AND QGL_PERAPP=y. Uses pm install -g to grant
# all declared permissions (including BIND_ACCESSIBILITY_SERVICE).
# Root/superuser is granted by the user via their root manager UI on first use.
# This matches LYB Kernel Manager's exact behavior.
if [ "$QGL" = "y" ] && [ "$QGL_PERAPP" = "y" ] && [ -f "$MODDIR/QGLTrigger.apk" ]; then
  _qgl_apk_pkg="io.github.adreno.qgl.trigger"
  _qgl_apk_version=$(dumpsys package "$_qgl_apk_pkg" 2>/dev/null | grep versionName | head -1 | sed 's/.*versionName=//;s/ .*//' | tr -d ' \r\n')
  if [ -n "$_qgl_apk_version" ]; then
    log_service "[QGL] QGLTrigger APK already installed (v$_qgl_apk_version)"
  else
    log_service "[QGL] Installing QGLTrigger APK..."
    pm install -g --user 0 "$MODDIR/QGLTrigger.apk" 2>/dev/null && \
      log_service "[QGL] QGLTrigger APK installed — enabling accessibility service..." || \
      log_service "[QGL] QGLTrigger APK install FAILED — user must install manually"
  fi

  # Enable Accessibility Service from root shell
  _acc_comp="io.github.adreno.qgl.trigger/.QGLAccessibilityService"
  _current=$(settings get secure enabled_accessibility_services 2>/dev/null || true)
  case "$_current" in
    *"$_acc_comp"*)
      log_service "[QGL] Accessibility service already enabled"
      ;;
    ""|null)
      settings put secure enabled_accessibility_services "$_acc_comp" 2>/dev/null && \
        log_service "[QGL] Accessibility service enabled (first service)" || \
        log_service "[QGL] Could not enable accessibility — user must enable manually in Settings > Accessibility"
      ;;
    *)
      settings put secure enabled_accessibility_services "${_current}:${_acc_comp}" 2>/dev/null && \
        log_service "[QGL] Accessibility service appended to enabled list" || \
        log_service "[QGL] Could not append accessibility service"
      ;;
  esac
  settings put secure accessibility_enabled 1 2>/dev/null || true
  unset _qgl_apk_pkg _qgl_apk_version _acc_comp _current
fi

# CRITICAL FIX: Reset the boot_attempts counter HERE — immediately after
# boot_completed — NOT at the end of the script (line ~2649).
#
# ROOT CAUSE OF AUTO-DISABLE CYCLE:
#   - post-fs-data.sh increments boot_attempts on every boot
#   - service.sh was only resetting it at script END (line ~2649)
#   - If service.sh crashes/is killed anywhere BEFORE that reset
#     (during watchdog daemon, QGL handling, etc.),
#     the counter is NEVER reset
#   - After 4 consecutive incomplete runs: boot_attempts > 3 →
#     post-fs-data.sh creates 'disable' → module permanently broken
#
# FIX: Reset the counter as soon as service.sh has confirmed:
#   (a) system booted successfully (sys.boot_completed=1)
#   (b) stabilization delay passed (sleep 2)
# This is the earliest safe point. Even if service.sh crashes later
# (during QGL activation, OEM watchdog, etc.), the counter is already
# 0 for the next boot — no false-positive auto-disable.
_EARLY_BOOT_ATT_FILE="/data/local/tmp/adreno_boot_attempts"
if printf '0\n' > "${_EARLY_BOOT_ATT_FILE}.tmp" 2>/dev/null && \
   mv "${_EARLY_BOOT_ATT_FILE}.tmp" "$_EARLY_BOOT_ATT_FILE" 2>/dev/null; then
  log_service "[OK] EARLY boot attempt counter reset (auto-disable protection)"
  printf '[ADRENO-SVC] boot_attempts reset=0 (early, post-boot-completed)\n' > /dev/kmsg 2>/dev/null || true
else
  rm -f "${_EARLY_BOOT_ATT_FILE}.tmp" 2>/dev/null || true
  log_service "[!] WARNING: Early boot attempt counter reset failed (non-fatal)"
fi
unset _EARLY_BOOT_ATT_FILE
# ── END EARLY BOOT COUNTER RESET ─────────────────────────────────────────

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
# FIRST BOOT DEFERRAL: REMOVED
# ========================================
# Q7 decision: always apply renderer from first boot.
# The 2-boot delay caused stale system.prop state and user confusion.
# Vulkan safety is handled by the VK compat gate in post-fs-data.sh which
# auto-degrades to skiagl if no Vulkan driver .so is found.
# Clean up any stale markers left from a previous module version.
rm -f "$MODDIR/.service_skip_render" 2>/dev/null || true
rm -f "$MODDIR/.first_boot_pending" 2>/dev/null || true

# ========================================
# EARLY RENDERER ENFORCEMENT
# ========================================
# Fires at boot_completed + stabilization delay — before OEM late_start init.d scripts can
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
# skiavk mode: props-only enforcement. No force-stops ever.
#   SystemUI is NOT crashed in any mode (stability fix — KGSL corruption prevention).
# ========================================
# Early enforcement: set debug.hwui.renderer + Vulkan gate props via resetprop
# at boot+2s — immediately after the stabilization sleep.
#
# WHY ro.hwui.use_vulkan IS SET HERE (user request + correctness):
#   MIUI/HyperOS checks ro.hwui.use_vulkan as a gate BEFORE reading
#   debug.hwui.renderer. If a vendor_init late_start service reset it between
#   post-fs-data.sh and now, any app opened at boot+2s ignores skiavk entirely.
#   Re-enforcing it here (and in the live resetprop block at ~boot+35s) ensures
#   the gate is open for ALL new processes from the first user interaction onward.
#
# Props set here:
#   debug.hwui.renderer     — per-process HWUI pipeline (skiavk/skiagl)
#   ro.hwui.use_vulkan      — MIUI/HyperOS/Samsung gate for HWUI Vulkan path
#   ro.config.vulkan.enabled — Samsung One UI explicit Vulkan enable flag
#   persist.vendor.vulkan.enable — MIUI/HyperOS vendor Vulkan enable
#   persist.sys.force_sw_gles — ensure HW GLES is used, not software fallback
#
# NOTE: debug.renderengine.backend is NOT set here — SF is already running and
# OEM addChangeCallback handlers would crash it. Backend is set exclusively in
# post-fs-data.sh before SF starts, via resetprop, and persists via system.prop.
if cmd_exists resetprop; then
  case "$RENDER_MODE" in
    skiavk)
      resetprop debug.hwui.renderer skiavk 2>/dev/null || true
      # Vulkan enable gates — set at boot+2s so all apps opened from home screen
      # benefit immediately, not just at the later live resetprop run (~boot+35s).
      resetprop ro.hwui.use_vulkan true 2>/dev/null || true
      resetprop ro.config.vulkan.enabled true 2>/dev/null || true
      resetprop persist.vendor.vulkan.enable 1 2>/dev/null || true
      resetprop persist.sys.force_sw_gles 0 2>/dev/null || true
      # Graphite must be off — custom Adreno lacks VK_KHR_dynamic_rendering
      resetprop debug.hwui.use_skia_graphite false 2>/dev/null || true
      log_service "[OK] Early enforcement (boot+2s): skiavk hwui.renderer + ro.hwui.use_vulkan + Vulkan gates set"
      ;;
    skiagl)
      resetprop debug.hwui.renderer skiagl 2>/dev/null || true
      resetprop persist.sys.force_sw_gles 0 2>/dev/null || true
      resetprop debug.hwui.use_skia_graphite false 2>/dev/null || true
      log_service "[OK] Early enforcement (boot+2s): skiagl hwui.renderer set"
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
# FIX: Remove the crash entirely for ALL modes.
# props-only enforcement for all modes. No force-stops in service.sh.
# SystemUI is NOT crashed in any mode. Next reboot: all procs get renderer from init.
case "$RENDER_MODE" in
  skiavk|skiagl)
    log_service "[OK] $RENDER_MODE: renderer prop enforced via resetprop at boot+2s; SystemUI NOT crashed (GMS/accounts protected)"
    ;;
esac

# Cache clearing handled by post-fs-data.sh (before Zygote). No duplicate clear here.

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

# ── Mirror SD config to /data/local/tmp for post-fs-data.sh ─────────────────
# post-fs-data.sh runs before FUSE/sdcardfs is mounted, so it cannot read
# /sdcard/Adreno_Driver/Config/adreno_config.txt directly. We mirror the SD
# config here (service.sh, after sdcard is confirmed mounted) to
# /data/local/tmp/adreno_config.txt — which IS accessible at post-fs-data time.
# On the NEXT boot, post-fs-data.sh will read this cached copy first.
_sd_cfg="/sdcard/Adreno_Driver/Config/adreno_config.txt"
_dt_cfg="/data/local/tmp/adreno_config.txt"
if [ -f "$_sd_cfg" ]; then
  if cp -f "$_sd_cfg" "$_dt_cfg" 2>/dev/null; then
    log_service "[OK] SD config mirrored to $_dt_cfg (available to post-fs-data next boot)"
  else
    log_service "[!] Failed to mirror SD config to $_dt_cfg"
  fi
fi
unset _sd_cfg _dt_cfg

# Mirror per-app QGL config files (qgl_config.txt.*) to /data/local/tmp so the
# QGLTrigger APK can read them before /sdcard is mounted (AccessibilityService
# starts at BOOT_COMPLETED but FUSE/sdcardfs may not be ready yet).
if [ "$QGL" = "y" ] && [ "$QGL_PERAPP" = "y" ]; then
  _sd_qgl_dir="/sdcard/Adreno_Driver/Config"
  _dt_qgl_dir="/data/local/tmp"
  if [ -d "$_sd_qgl_dir" ]; then
    _count=0
    for _f in "$_sd_qgl_dir"/qgl_config.txt*; do
      [ -f "$_f" ] || continue
      _base="${_f##*/}"
      if cp -f "$_f" "$_dt_qgl_dir/$_base" 2>/dev/null; then
        chmod 0644 "$_dt_qgl_dir/$_base" 2>/dev/null || true
        _count=$((_count + 1))
      fi
    done
    if [ "$_count" -gt 0 ]; then
      log_service "[OK] QGL config files mirrored to $_dt_qgl_dir ($_count files)"
    else
      log_service "[!] No QGL config files found to mirror"
    fi
  fi
  unset _sd_qgl_dir _dt_qgl_dir _count _f _base
fi
# ── END config mirror ────────────────────────────────────────────────────────

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

# QGL activation: boot-completed.sh (display-stable timing).
# No QGL status report or activation logic here.

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
    GPU_MODEL="${GPU_MODEL%$(printf '\r')}"
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
  _plt_found=false
  for _plt_f in /vendor/etc/public.libraries*.txt; do
    [ -f "$_plt_f" ] || continue
    if grep -q "gpu++.so" "$_plt_f" 2>/dev/null; then
      _plt_found=true
      log_service "[OK] gpu++.so found in ${_plt_f##*/}"
      break
    fi
  done
  [ "$_plt_found" = "false" ] && \
    log_service "[!] WARNING: gpu++.so not found in any public.libraries*.txt"
  unset _plt_found _plt_f
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

# ========================================
# SKIAVK (non-_all): VK COMPAT CANARY WRITE
# ========================================
# BUG FIX: For RENDER_MODE=skiavk, adreno_vk_compat was NEVER written by
# service.sh. All writes of "confirmed" live exclusively inside the
# All writes of "confirmed" must now happen in service.sh directly.
#
# IMPACT: post-fs-data.sh QGL freeze gate requires adreno_vk_compat=confirmed
# before it allows renderengine.backend=skiavkthreaded. With skiavk+QGL=y,
# that "confirmed" value never arrives → skiaglthreaded is used on every boot
# forever, regardless of how healthy the device is.
#
# FIX: After boot_completed + service.sh settle time (~35s total), run the
# same Loophole 4 SystemUI dumpsys canary. If Vulkan is
# confirmed working, write "confirmed" so the QGL gate clears on next boot.
# If it fails, write "prop_only" so the gate stays safely locked.
# Do NOT overwrite existing "incompatible" — that was written for good reason.
# ========================================
if [ "$RENDER_MODE" = "skiavk" ]; then
  _skvk_compat_file="/data/local/tmp/adreno_vk_compat"
  _skvk_cur=""
  [ -f "$_skvk_compat_file" ] && \
    { IFS= read -r _skvk_cur; } < "$_skvk_compat_file" 2>/dev/null || _skvk_cur=""

  if [ "$_skvk_cur" = "incompatible" ]; then
    log_service "[SKIP] skiavk VK canary: adreno_vk_compat=incompatible — not overwriting (boot_success will also be suppressed)"
  elif [ "$_skvk_cur" = "confirmed" ]; then
    log_service "[OK] skiavk VK canary: adreno_vk_compat already confirmed — no write needed"
  else
    # Run the canary: check Vulkan driver .so exists (structural guard)
    _skvk_drv_ok=false
    for _skvk_vd in /vendor/lib64/hw/vulkan.*.so /vendor/lib/hw/vulkan.*.so \
                    /system/lib64/hw/vulkan.*.so /system/lib/hw/vulkan.*.so \
                    /vendor/lib64/libvulkan.so /system/lib64/libvulkan.so; do
      [ -f "$_skvk_vd" ] && { _skvk_drv_ok=true; break; }
    done
    unset _skvk_vd

    if [ "$_skvk_drv_ok" = "false" ]; then
      log_service "[!] skiavk VK canary: no vulkan.*.so/libvulkan.so found — writing incompatible"
      printf 'incompatible\n' > "${_skvk_compat_file}.tmp" 2>/dev/null && \
        mv "${_skvk_compat_file}.tmp" "$_skvk_compat_file" 2>/dev/null || true
    else
      # Runtime canary: check SystemUI is actually on Vulkan pipeline
      # BUG FIX: dumpsys gfxinfo can hang if SystemUI is unresponsive.
      # Wrap with timeout: run in background, kill after 10s.
      # Use background+kill fallback for devices without 'timeout' (toybox).
      if command -v timeout >/dev/null 2>&1; then
        _skvk_sysui_dump=$(timeout 10 dumpsys gfxinfo com.android.systemui 2>/dev/null || true)
      else
        dumpsys gfxinfo com.android.systemui > /dev/tmp/adreno_gfxinfo_$$ 2>&1 &
        _gfxinfo_pid=$!
        _gfxinfo_wait=0
        while kill -0 "$_gfxinfo_pid" 2>/dev/null && [ $_gfxinfo_wait -lt 10 ]; do
          sleep 1
          _gfxinfo_wait=$((_gfxinfo_wait + 1))
        done
        kill "$_gfxinfo_pid" 2>/dev/null || true
        wait "$_gfxinfo_pid" 2>/dev/null || true
        _skvk_sysui_dump=$(cat /dev/tmp/adreno_gfxinfo_$$ 2>/dev/null || true)
        rm -f /dev/tmp/adreno_gfxinfo_$$ 2>/dev/null || true
      fi
      _skvk_sysui_count=$(printf '%s' "$_skvk_sysui_dump" | grep -c "Skia (Vulkan)" 2>/dev/null || echo "0")
      _skvk_sysui_count="${_skvk_sysui_count:-0}"

      if [ "$_skvk_sysui_count" -gt 0 ] 2>/dev/null; then
        printf 'confirmed\n' > "${_skvk_compat_file}.tmp" 2>/dev/null && \
          mv "${_skvk_compat_file}.tmp" "$_skvk_compat_file" 2>/dev/null || true
        log_service "[OK] skiavk VK canary: SystemUI on Vulkan (${_skvk_sysui_count} Skia(Vulkan) surface(s)) — writing confirmed, QGL gate cleared for next boot"
      else
        _skvk_pipe=$(printf '%s' "$_skvk_sysui_dump" | grep -i "Pipeline" | head -1 || echo "")
        _skvk_live=$(getprop debug.hwui.renderer 2>/dev/null || echo "")
        printf 'prop_only\n' > "${_skvk_compat_file}.tmp" 2>/dev/null && \
          mv "${_skvk_compat_file}.tmp" "$_skvk_compat_file" 2>/dev/null || true
        log_service "[!] skiavk VK canary: SystemUI NOT on Vulkan — writing prop_only (QGL gate stays locked)"
        log_service "    SystemUI pipeline : '${_skvk_pipe:-unknown}'"
        log_service "    Live renderer prop: '${_skvk_live}'"
        log_service "    Skia(Vulkan) count: 0"
      fi
      unset _skvk_sysui_count _skvk_pipe _skvk_live _skvk_sysui_dump
    fi
    unset _skvk_drv_ok
  fi
  unset _skvk_cur _skvk_compat_file
fi
# ── END SKIAVK VK COMPAT CANARY WRITE ────────────────────────────────────────

log_service "========================================"
log_service "MARKING SUCCESSFUL BOOT"
log_service "========================================"

# NOTE: Boot attempt counter was ALREADY reset at boot_completed+2s (line ~303).
# That early reset is the primary protection — if service.sh crashes after that
# point, the counter is still 0 for the next boot. No second reset needed.
# This avoids a redundant write and keeps the logic clean.

# Skip the marker if this boot confirmed Vulkan is incompatible with this device.
# When adreno_vk_compat="incompatible", the next boot's post-fs-data.sh would see
# _PREV_BOOT_SUCCESS=true and promote to skiavkthreaded — but Vulkan is broken, so
# SF would freeze. Suppressing the marker forces post-fs-data.sh to stay on
# skiaglthreaded until a future boot re-evaluates compat.
# "prop_only" is NOT suppressed: that means the ICD runs but VK compat is uncertain;
# SF's own Vulkan compositor path is independent and may still work.
# NOTE: Boot attempt counter was already reset early (line ~303) — no redundant write here.
_bs_vk_compat=""
[ -f "/data/local/tmp/adreno_vk_compat" ] && \
  { IFS= read -r _bs_vk_compat; } < "/data/local/tmp/adreno_vk_compat" 2>/dev/null || true
if [ "$_bs_vk_compat" = "incompatible" ]; then
  log_service "[!] Skipping .boot_success — adreno_vk_compat=incompatible; skiavkthreaded suppressed next boot"
elif touch "$MODDIR/.boot_success" 2>/dev/null; then
  log_service "Boot success marker created"
else
  log_service "WARNING: Failed to create boot success marker"
fi
unset _bs_vk_compat

# ========================================
# SYSTEM.PROP OWNERSHIP: post-fs-data.sh
# ========================================
# Renderer props (debug.hwui.renderer and all HWUI/EGL/SF/perf props) are
# written to system.prop exclusively by post-fs-data.sh on every boot,
# before SurfaceFlinger starts. service.sh no longer writes system.prop.
#
# Rationale: post-fs-data.sh runs before SF, so it can safely set
# debug.renderengine.backend via resetprop with no OEM watcher risk.
# It writes system.prop for next-boot persistence in the same pass.
# service.sh performs live resetprop enforcement below (belt-and-suspenders)
# but does NOT strip or rewrite system.prop — that caused a race where the
# awk strip ran but the rewrite was silently skipped on certain code paths,
# leaving system.prop empty of render props.
# ========================================

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
  # BUG FIX: adreno_skiavk_degraded stores the REASON string written by
  # post-fs-data.sh (e.g. "compat_risky_no_driver(score=45)"), not the mode.
  # The old code set RENDER_MODE directly to that string → matched "normal|*"
  # in the case statement → system.prop was silently emptied every boot after
  # a degrade. Fix: presence of the file means "degraded to skiagl", regardless
  # of content. Set RENDER_MODE="skiagl" unconditionally when the file exists.
  _degrade_marker="/data/local/tmp/adreno_skiavk_degraded"
  if [ -f "$_degrade_marker" ]; then
    { IFS= read -r _degraded_reason; } < "$_degrade_marker" 2>/dev/null || _degraded_reason=""
    log_service "[BUG3-FIX] degrade marker present (reason: ${_degraded_reason:-unknown}) — overriding RENDER_MODE to skiagl"
    RENDER_MODE="skiagl"
    unset _degraded_reason
  fi
  unset _degrade_marker

  log_service "========================================"
  log_service "LIVE RESETPROP: Enforcing OEM-override-resistant props"
  log_service "========================================"

  # Legacy EGL/SF props: parsed only on Android 8 and earlier; ignored by Android 9+.
  # Kept for belt-and-suspenders compatibility with ancient vendor partitions that
  # still ship these in their init.rc. Setting them is a no-op on modern devices.
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
    skiavk)
      # Reinforce critical skiavk-specific props
      resetprop debug.hwui.renderer skiavk 2>/dev/null || true
      # debug.renderengine.backend intentionally NOT live-resetprop'd here.
      # SF is active; OEM ROM property watchers fire a RenderEngine reinit on change
      # -> SF crash -> all apps lose window surfaces -> watchdog reboot.
      # Set safely BEFORE SF starts via resetprop in post-fs-data.sh.
      # Log current effective value (set at post-fs-data time) for diagnostics:
      _svc_re_be=$(getprop debug.renderengine.backend 2>/dev/null || echo "default")
      log_service "[INFO] renderengine.backend=${_svc_re_be} (FORCE_SKIAVKTHREADED_BACKEND=${FORCE_SKIAVKTHREADED_BACKEND}, set pre-SF in post-fs-data.sh)"
      unset _svc_re_be
      resetprop ro.hwui.use_vulkan true 2>/dev/null || true
      resetprop persist.vendor.vulkan.enable 1 2>/dev/null || true
      resetprop ro.config.vulkan.enabled true 2>/dev/null || true
      resetprop persist.sys.force_sw_gles 0 2>/dev/null || true
      # disable_pre_rotation: NOT enforced. Causes VK_ERROR_OUT_OF_DATE_KHR crash in UE4/Unity.
      # Explicitly DELETE it to clear any value set by a previous module version.
      resetprop --delete persist.graphics.vulkan.disable_pre_rotation 2>/dev/null || true
      resetprop debug.vulkan.layers "" 2>/dev/null || true
      # treat_170m_as_sRGB: safe only on non-WCG (sRGB-only) displays.
      # Skip on WCG/HDR devices (ro.surface_flinger.use_color_management=1).
      _wcg_svc=$(getprop ro.surface_flinger.use_color_management 2>/dev/null || echo "")
      if [ "$_wcg_svc" != "1" ] && [ "$_wcg_svc" != "true" ]; then
        resetprop debug.sf.treat_170m_as_sRGB 1 2>/dev/null || true
      fi
      unset _wcg_svc
      # blur: NOT disabled in SkiaVK — blanket disable causes Samsung/MIUI UI regression.
      resetprop --delete ro.surface_flinger.supports_background_blur 2>/dev/null || true
      resetprop --delete persist.sys.sf.disable_blurs 2>/dev/null || true
      resetprop ro.sf.blurs_are_expensive 1 2>/dev/null || true
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
      resetprop debug.hwui.render_dirty_regions false 2>/dev/null || true
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
  # Persist cleared state for next boot comparison.
  # 3-line format: RENDER_MODE / QGL / QGL_CONFIG_HASH
  # post-fs-data.sh writes this when it clears. We update it here at end-of-boot
  # to ensure it reflects the FINAL settings (in case something changed mid-boot).
  # This is safe to write even when we DID NOT clear above — the state file records
  # what mode is currently ACTIVE, so next boot's comparison is accurate.
  _LAST_STATE_FILE="/data/local/tmp/adreno_last_cleared_state"
  _LS_PREV_MODE=""
  _LS_PREV_QGL=""
  if [ -f "$_LAST_STATE_FILE" ]; then
    {
      IFS= read -r _LS_PREV_MODE
      IFS= read -r _LS_PREV_QGL
    } < "$_LAST_STATE_FILE" 2>/dev/null || true
  fi
  if [ "$RENDER_MODE" != "$_LS_PREV_MODE" ] || [ "$QGL" != "$_LS_PREV_QGL" ]; then
    # Settings differ from what's in the state file — rewrite with current values.
    _LS_HASH="none"
    if [ "$QGL" = "y" ]; then
      for _ls_qsrc in \
          "/sdcard/Adreno_Driver/Config/qgl_config.txt" \
          "/data/local/tmp/qgl_config.txt" \
          "$MODDIR/qgl_config.txt"; do
        if [ -f "$_ls_qsrc" ]; then
          _LS_HASH=$(cksum "$_ls_qsrc" 2>/dev/null | awk '{print $1}') || _LS_HASH="cksum_fail"
          break
        fi
      done
      unset _ls_qsrc
    fi
    printf '%s\n%s\n%s\n' "$RENDER_MODE" "$QGL" "$_LS_HASH" \
      > "$_LAST_STATE_FILE" 2>/dev/null || true
    log_service "[OK] Cleared state file updated: mode=$RENDER_MODE qgl=$QGL hash=$_LS_HASH"
    unset _LS_HASH
  else
    log_service "[OK] Cleared state file current: mode=$RENDER_MODE qgl=$QGL — no update needed."
  fi
  unset _LAST_STATE_FILE _LS_PREV_MODE _LS_PREV_QGL

  # Backward compat: remove old single-line mode file from previous installs.
  rm -f /data/local/tmp/adreno_last_render_mode 2>/dev/null || true

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

# ── QGL VERIFICATION (verbose=y) ────────────────────────────────────────
if [ "$VERBOSE" = "y" ] && [ "$QGL" = "y" ]; then
  log_service "========================================"
  log_service "QGL VERIFICATION"
  log_service "========================================"
  if [ -f /data/vendor/gpu/qgl_config.txt ]; then
    _qgl_sz=$(stat -c '%s' /data/vendor/gpu/qgl_config.txt 2>/dev/null || echo '?')
    _qgl_ctx=$(ls -Z /data/vendor/gpu/qgl_config.txt 2>/dev/null | awk '{print $1}' || echo '?')
    log_service "[OK] QGL file present (${_qgl_sz} bytes)"
    log_service "  Context: ${_qgl_ctx}"
    case "$_qgl_ctx" in
      *same_process_hal_file*) log_service "  Status: CORRECT" ;;
      *) log_service "  Status: UNEXPECTED — expected same_process_hal_file" ;;
    esac
  else
    log_service "[INFO] QGL file NOT present — boot-completed.sh will apply it after launcher is ready"
  fi
fi

log_service "========================================"
log_service "service.sh completed successfully"
log_service "Total elapsed time: approx ${ELAPSED:-0}s + processing"
log_service "========================================"

# ── SYSTEM STATE DUMP + 120s BOOT CAPTURE (verbose=y) ─────────────────────
if [ "$VERBOSE" = "y" ]; then
  _state_dir="${LOG_BASE}/Booted/system_state_$(date +%Y%m%d_%H%M%S 2>/dev/null || echo 'unknown')"
  dump_boot_state "$_state_dir"
  start_boot_capture "${LOG_BASE}/Booted"
fi

exit 0
