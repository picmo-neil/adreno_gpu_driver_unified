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
PLT="n"
RENDER_MODE="normal"
FORCE_SKIAVKTHREADED_BACKEND="n"

CONFIG_FILE="/sdcard/Adreno_Driver/Config/adreno_config.txt"
DATA_CONFIG="/data/local/tmp/adreno_config.txt"
ALT_CONFIG="$MODDIR/adreno_config.txt"

# Priority: /sdcard (mounted by service.sh time) -> /data/local/tmp (mirrored) -> $MODDIR
if ! load_config "$CONFIG_FILE"; then
  if ! load_config "$DATA_CONFIG"; then
    load_config "$ALT_CONFIG" || true
  fi
fi

[ "$VERBOSE" != "y" ]   && VERBOSE="n"
[ "$ARM64_OPT" != "y" ] && ARM64_OPT="n"
[ "$QGL" != "y" ]       && QGL="n"
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

log_service "Configuration: ARM64_OPT=$ARM64_OPT, QGL=$QGL, PLT=$PLT, RENDER_MODE=$RENDER_MODE, FORCE_SKIAVKTHREADED_BACKEND=$FORCE_SKIAVKTHREADED_BACKEND"

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
# 300s kill-$$ timeout fires → service.sh is killed → QGL CASE A, VK canary
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

      # ── STATE-FILE-CONDITIONAL CACHE CLEAR ────────────────────────────────
      # ROOT CAUSE FIX: The previous implementation did a full unconditional cache
      # wipe on EVERY boot whenever mode=0000. This destroyed all compiled shader
      # caches on every boot. Apps would have to compile ALL shaders
      # from scratch with QGL settings active. Custom Adreno drivers crash in
      # vkCreateGraphicsPipelines → QGLCCompileToIRShader during cold full-
      # recompilation under QGL settings. Hence "skiavk + QGL → all
      # apps crash" even though "skiavk + LYB QGL works fine" (LYB never
      # clears caches; apps reuse compiled shaders from previous session → no
      # cold recompile → no crash).
      #
      # FIX: Only clear when settings actually changed (matching the state-file
      # logic in the SECONDARY CACHE CLEAR section).
      # On stable boots: PRESERVE existing compiled shader caches. Apps reuse
      # them → no recompile → no crash.
      # On changed boots (first QGL enable, config change, mode change): clear.
      #
      # The state file is /data/local/tmp/adreno_last_cleared_state (3 lines:
      # RENDER_MODE / QGL / QGL_CONFIG_HASH). Written by the SECONDARY CACHE
      # CLEAR section and at end of service.sh.
      # ──────────────────────────────────────────────────────────────────────
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

      # Compute current QGL source config hash (same locations as state file writer)
      _eq_cur_hash="none"
      for _eq_src in \
          "/sdcard/Adreno_Driver/Config/qgl_config.txt" \
          "/data/local/tmp/qgl_config.txt" \
          "$MODDIR/qgl_config.txt"; do
        if [ -f "$_eq_src" ]; then
          _eq_cur_hash=$(cksum "$_eq_src" 2>/dev/null | awk '{print $1}') || _eq_cur_hash="cksum_fail"
          break
        fi
      done
      unset _eq_src

      _eq_need_clear=false
      _eq_clear_reason=""
      # Only clear on render mode change — QGL changes must NOT trigger a clear.
      # Clearing on QGL change/enable forces cold recompile under QGL settings →
      # QGLCCompileToIRShader SIGSEGV. See SECONDARY CACHE CLEAR comment above.
      # first_boot (no state file → _eq_prev_mode="") is implicitly covered:
      # any configured RENDER_MODE != "" satisfies this condition.
      if [ "$RENDER_MODE" != "$_eq_prev_mode" ]; then
        _eq_need_clear=true
        _eq_clear_reason="render_mode_changed(${_eq_prev_mode:-<none>}→${RENDER_MODE})"
      fi
      unset _eq_state_file _eq_prev_mode _eq_prev_qgl _eq_prev_hash

      if [ "$_eq_need_clear" = "true" ]; then
        log_service "[EARLY QGL] Render mode changed (${_eq_clear_reason}) — clearing post-Zygote app caches"
        printf '[ADRENO-SVC] EARLY QGL: cache clear triggered — %s\n' \
          "$_eq_clear_reason" > /dev/kmsg 2>/dev/null || true

        # FULL SWEEP — not marker-based (directory mtime is NOT updated when apps
        # write new blob files inside existing dirs; -newer marker misses them).
        # These finds complete instantly if dirs are already empty (e.g., because
        # boot-completed.sh ran a clear for skiavk mode).
        find /data/user_de -maxdepth 4 -type d -name "app_skia_pipeline_cache" \
            -exec rm -rf {} + 2>/dev/null || true
        find /data/user_de -maxdepth 4 -name "*.shader_journal" -delete 2>/dev/null || true
        find /data/user_de -maxdepth 4 -type d \( -name "skia_shaders" -o -name "shader_cache" \) \
            -exec rm -rf {} + 2>/dev/null || true
        find /data/user_de -maxdepth 4 -name "com.android.opengl.shaders_cache" \
            -delete 2>/dev/null || true
        find /data/data -maxdepth 3 -name "com.android.opengl.shaders_cache" \
            -delete 2>/dev/null || true
        find /data/user_de -maxdepth 4 -name "com.android.skia.shaders_cache" \
            -delete 2>/dev/null || true
        find /data/data -maxdepth 3 -name "com.android.skia.shaders_cache" \
            -delete 2>/dev/null || true
        rm -rf /data/misc/hwui/ 2>/dev/null || true
        rm -rf /data/misc/gpu/  2>/dev/null || true
        rm -f /data/local/tmp/adreno_post_fs_data_done 2>/dev/null || true
        log_service "[EARLY QGL] All app graphics caches cleared (full sweep — pipeline, EGL blob, Skia shader, GPU vendor)"
        # Write state file so next boot recognises stable state and does not
        # re-trigger a redundant cache clear (perpetual-clear bug fix).
        _eq_state_write="/data/local/tmp/adreno_last_cleared_state"
        printf '%s\n%s\n%s\n' "$RENDER_MODE" "$QGL" "$_eq_cur_hash" \
          > "${_eq_state_write}.tmp" 2>/dev/null && \
          mv "${_eq_state_write}.tmp" "$_eq_state_write" 2>/dev/null || true
        unset _eq_state_write
      else
        log_service "[EARLY QGL] Stable boot — cache clear SKIPPED (mode=$RENDER_MODE qgl=$QGL hash=$_eq_cur_hash). Caches preserved from last session."
        printf '[ADRENO-SVC] EARLY QGL: stable boot — cache clear skipped, caches preserved\n' \
          > /dev/kmsg 2>/dev/null || true
      fi
      unset _eq_need_clear _eq_clear_reason _eq_cur_hash

      # ── TIMING FIX: do NOT activate QGL here (boot+2s) ────────────────────
      # boot-completed.sh sleeps 20s before writing. Activating at boot+2s
      # short-circuits the 20s window → launcher sees QGL during vkCreateDevice
      # init → black screen. Leave file at 0000, defer to boot-completed.sh.
      # CASE A below (~boot+30s, after sdcard wait) has its own timing guard.
      log_service "[EARLY QGL] 0000 detected: deferring activation to boot-completed.sh (+20s)"
      printf '[ADRENO-SVC] EARLY QGL: activation deferred — boot-completed.sh handles at +20s\n' \
        > /dev/kmsg 2>/dev/null || true
      unset _eq _em
      ;;
    "644"|"0644")
      log_service "[EARLY QGL] File already in ACTIVE MODE (${_em}) — no action needed"
      ;;
    "")
      # stat returned "" — two possible causes:
      #   1. File truly absent (most likely if injection succeeded above)
      #   2. getattr still denied (no injection tool available, file exists)
      # Distinguish by checking file existence directly.
      if [ -f "$_eq" ]; then
        # File exists but stat denied — attempt chmod anyway.
        # Static sepolicy.rule grants setattr for su/magisk on most ROMs.
        log_service "[EARLY QGL] stat returned '' but file exists — attempting activation (static sepolicy.rule path)"
        chmod 0644 "$_eq" 2>/dev/null || true
        chown 0:1000 "$_eq" 2>/dev/null || true
        chcon u:object_r:same_process_hal_file:s0 "$_eq" 2>/dev/null || \
          chcon u:object_r:vendor_data_file:s0 "$_eq" 2>/dev/null || true
        chcon u:object_r:same_process_hal_file:s0 /data/vendor/gpu/ 2>/dev/null || true
        _en=$(stat -c '%a' "$_eq" 2>/dev/null || echo "?")
        log_service "[EARLY QGL] Result after fallback attempt: mode=${_em}→${_en}"
        unset _en
      else
        log_service "[EARLY QGL] File absent at boot_completed+2s — CASE B will install it"
      fi
      ;;
  esac
  unset _eq _em
fi
# ── END EARLY QGL FAST-PATH ──────────────────────────────────────────────
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

# ========================================
# SECONDARY GRAPHICS CACHE CLEARING
# ========================================
# post-fs-data.sh:
#   - Always clears /data/misc/hwui/ (stale HWUI cache → SF hang → ROM logo freeze)
#   - Clears /data/misc/gpu/ and per-app caches only on mode change
# This is a belt-and-suspenders secondary pass for /data/misc/gpu/ + per-app:
#   1. Catches any caches created/modified between post-fs-data and here
#   2. Covers the skip_mount code path (post-fs-data exits early, no clear)
#   3. Runs before the sdcard wait so it still fires early in service.sh
# /data/misc/hwui/ is intentionally NOT re-cleared here (post-fs-data handles it).
# ========================================

_SVC_STATE_FILE="/data/local/tmp/adreno_last_cleared_state"
_SVC_PREV_MODE=""
_SVC_PREV_QGL=""
_SVC_PREV_HASH=""
if [ -f "$_SVC_STATE_FILE" ]; then
  {
    IFS= read -r _SVC_PREV_MODE
    IFS= read -r _SVC_PREV_QGL
    IFS= read -r _SVC_PREV_HASH
  } < "$_SVC_STATE_FILE" 2>/dev/null || true
fi

# Compute current QGL config hash (same method as post-fs-data.sh)
_SVC_CUR_HASH="none"
if [ "$QGL" = "y" ]; then
  for _svc_qsrc in \
      "/sdcard/Adreno_Driver/Config/qgl_config.txt" \
      "/data/local/tmp/qgl_config.txt" \
      "$MODDIR/qgl_config.txt"; do
    if [ -f "$_svc_qsrc" ]; then
      _SVC_CUR_HASH=$(cksum "$_svc_qsrc" 2>/dev/null | awk '{print $1}') || _SVC_CUR_HASH="cksum_fail"
      break
    fi
  done
  unset _svc_qsrc
fi

_SVC_EARLY_CLEAR_REASON=""
# Only clear on render mode change — QGL changes must NOT trigger a clear.
# Clearing on QGL change forces cold shader recompile under QGL settings →
# QGLCCompileToIRShader SIGSEGV (confirmed bug in custom Adreno drivers).
# LYB never clears on QGL change and works fine: apps reuse existing cached
# pipeline blobs which remain format-valid regardless of QGL state.
# first_boot (no state file → _SVC_PREV_MODE="") is implicitly covered:
# any configured RENDER_MODE != "" satisfies this condition.
if [ "$RENDER_MODE" != "$_SVC_PREV_MODE" ]; then
  _SVC_EARLY_CLEAR_REASON="mode_change(${_SVC_PREV_MODE:-<none>}→${RENDER_MODE})"
fi

if [ -n "$_SVC_EARLY_CLEAR_REASON" ]; then
  log_service "========================================"
  log_service "SECONDARY CACHE CLEAR (service.sh early pass):"
  log_service "  Reason : $_SVC_EARLY_CLEAR_REASON"
  log_service "  Prev state: mode=${_SVC_PREV_MODE:-<none>} qgl=${_SVC_PREV_QGL:-<none>} hash=${_SVC_PREV_HASH:-<none>}"
  log_service "  Curr state: mode=${RENDER_MODE} qgl=${QGL} hash=${_SVC_CUR_HASH}"
  log_service "  Removing any caches not caught by post-fs-data.sh early clear."
  log_service "========================================"
  rm -rf /data/misc/hwui/ 2>/dev/null || true
  rm -rf /data/misc/gpu/ 2>/dev/null || true
  find /data/user_de -maxdepth 4 -type d -name "app_skia_pipeline_cache" \
      -exec rm -rf {} + 2>/dev/null || true
  find /data/data -maxdepth 3 -type d -name "app_skia_pipeline_cache" \
      -exec rm -rf {} + 2>/dev/null || true
  find /data/user_de -maxdepth 4 -name "*.shader_journal" -delete 2>/dev/null || true
  find /data/user_de -maxdepth 4 -type d \( -name "skia_shaders" -o -name "shader_cache" \) \
      -exec rm -rf {} + 2>/dev/null || true
  find /data/user_de -maxdepth 4 -name "com.android.opengl.shaders_cache" \
      -delete 2>/dev/null || true
  find /data/data -maxdepth 3 -name "com.android.opengl.shaders_cache" \
      -delete 2>/dev/null || true
  find /data/user_de -maxdepth 4 -name "com.android.skia.shaders_cache" \
      -delete 2>/dev/null || true
  find /data/data -maxdepth 3 -name "com.android.skia.shaders_cache" \
      -delete 2>/dev/null || true
  log_service "[OK] Secondary full graphics cache clear complete."
  # Update state file to reflect this secondary clear
  printf '%s\n%s\n%s\n' "$RENDER_MODE" "$QGL" "$_SVC_CUR_HASH" \
    > "$_SVC_STATE_FILE" 2>/dev/null || true
else
  log_service "SECONDARY CACHE CLEAR: state matches (mode=$RENDER_MODE qgl=$QGL) — caches valid, preserved."
  log_service "  (Skipping prevents shader-recompile OOM on Facebook/GMS.)"
fi
unset _SVC_PREV_MODE _SVC_PREV_QGL _SVC_PREV_HASH _SVC_CUR_HASH _SVC_EARLY_CLEAR_REASON _SVC_STATE_FILE


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

# ========================================
# ========================================
# QGL CONFIGURATION: ACTIVATE / REPAIR
# ========================================
# post-fs-data.sh (init domain) always installs qgl_config.txt.
# This section handles three cases based on what state that install left:
#
#  CASE A — PROTECTED MODE (skiavkthreaded boot, file is mode=0000):
#    post-fs-data.sh wrote qgl_config.txt as root:root mode=0000 so that
#    SurfaceFlinger (uid=1000, no CAP_DAC_OVERRIDE) gets EACCES on open()
#    during its renderengine skiavkthreaded vkCreateDevice call at SF init()
#    — BEFORE boot_completed. EACCES → driver uses defaults → no Vulkan init hang.
#    SF is now already running with its existing VkDevice context.
#    We ACTIVATE the file: chmod 0644 + chown 0:1000 + chcon same_process_hal_file.
#    After activation, two consumer paths benefit:
#      (1) debug.hwui.renderer=skiavk: every app that calls vkCreateDevice after
#          boot_completed reads the QGL tuning. HWUI apps, games, any Vulkan user.
#      (2) debug.renderengine.backend=skiavkthreaded: SF reads qgl_config.txt on
#          any VkDevice recreation event (display hotplug, protected content mode,
#          etc.) after boot_completed. sepolicy.rule grants SF same_process_hal_file
#          read statically; CASE A re-injects the rule dynamically as belt-and-suspenders.
#    Primary path: chmod 0644 requires "setattr" on vendor_data_file.
#    Fallback path: if setattr is blocked, rm + recreate the file fresh via cat
#    (uses "unlink" + "create" — NOT "setattr"). Both paths are covered.
#    After activation, all new app processes (HWUI skiavk, games, any Vulkan app)
#    read the QGL config when they do their own vkCreateDevice / KGSL open.
#    SF's running compositor context is unaffected (already past init).
#    This is identical in effect to LYB Kernel Manager's post-boot install.
#
#  CASE B — FILE MISSING (post-fs-data.sh failed — rare /data timing issue):
#    Emergency full write attempted here with SELinux injection as last resort.
#
#  CASE C — FILE HEALTHY (active mode, normal non-skiavk boot):
#    Verify permissions and size. Correct any drift.

# ── QGL: SELinux policy tool discovery ────────────────────────────────────
# service.sh runs in late_start service context. On Magisk, magiskpolicy is
# symlinked into the Magisk tmpfs PATH. On KernelSU and APatch, the binary
# is in a root-manager-specific directory that is NOT in the late_start PATH.
# ROOT_TYPE is already detected above — use it to prioritise the correct path.
#
# Discovery order:
#   1. PATH lookup (covers Magisk — magiskpolicy is always in PATH via sbin/tmpfs)
#   2. /data/adb/magisk/magiskpolicy  — Magisk persistent path
#   3. /data/adb/ksu/bin/magiskpolicy — KernelSU
#   4. /data/adb/ap/bin/magiskpolicy  — APatch (uses Magisk's magiskpolicy binary)
#   5. /sbin/magiskpolicy             — legacy Magisk on older Android ≤9 devices
#   6. system paths                   — vendor-shipped fallback (very rare)
_SVC_SEPOLICY_TOOL=""
# BUG FIX: magiskpolicy --help ALWAYS calls exit(1) in every Magisk/KSU/APatch
# build (confirmed: usage() ends with exit(1) in magiskpolicy.c, all forks).
# Using --help as a liveness test means _SVC_SEPOLICY_TOOL is always empty →
# all injection skipped → chmod 0644 fails silently on KSU-Next (u:r:ksu:s0
# lacks setattr on vendor_data_file without explicit injection) → mode stays 0000.
# Correct test: file existence + executable bit. Verify function separately.
_svc_mp_try() {
  [ -z "$1" ] && return 1
  [ -f "$1" ] && [ -x "$1" ] || return 1
  _SVC_SEPOLICY_TOOL="$1"; return 0
}
_svc_mp_try "$(command -v magiskpolicy 2>/dev/null)" || \
_svc_mp_try "/data/adb/magisk/magiskpolicy" || \
_svc_mp_try "/data/adb/ksu/bin/magiskpolicy" || \
_svc_mp_try "/data/adb/ap/bin/magiskpolicy" || \
_svc_mp_try "/sbin/magiskpolicy" || \
_svc_mp_try "/system/bin/magiskpolicy" || \
_svc_mp_try "/system/xbin/magiskpolicy" || true
unset -f _svc_mp_try 2>/dev/null || true

# ── KSU-NEXT KSUD WRAPPER: Auto-create if magiskpolicy not found ──────────
# KernelSU-Next (rifsxd) ships no magiskpolicy. Instead, ksud provides:
#   ksud sepolicy patch "rule"  →  live injection (equivalent to magiskpolicy --live)
# If no magiskpolicy wrapper is pre-installed, auto-create an ephemeral one
# in /dev/tmp/ so injection code (which calls "$_SVC_SEPOLICY_TOOL" --live "rule")
# works transparently. On Magisk/tiann-KSU/APatch, magiskpolicy was already
# found above — this block is a no-op.
_SVC_KSUD_BIN=""  # Direct ksud binary path — used as fallback when wrapper is unavailable.
if [ -z "$_SVC_SEPOLICY_TOOL" ]; then
  _ksud_bin=""
  for _kb in "/data/adb/ksud" "/data/adb/ksu/bin/ksud" "$(command -v ksud 2>/dev/null)"; do
    [ -z "$_kb" ] && continue
    [ -f "$_kb" ] && [ -x "$_kb" ] && { _ksud_bin="$_kb"; break; }
  done
  unset _kb
  if [ -n "$_ksud_bin" ]; then
    # Verify ksud sepolicy patch works on this build
    if "$_ksud_bin" sepolicy patch "allow domain domain process signal" >/dev/null 2>&1; then
      _svc_ksud_wrapper="/dev/tmp/adreno_mp_wrap_$$"
      mkdir -p /dev/tmp 2>/dev/null || true
      # Write wrapper: translates --live "rule" [...] to ksud sepolicy patch "rule" [...]
      printf '#!/system/bin/sh\n# KSU-Next magiskpolicy wrapper (auto)\nshift\n_k="%s"\nfor _r; do "$_k" sepolicy patch "$_r" 2>/dev/null; done\n' \
        "$_ksud_bin" > "$_svc_ksud_wrapper" 2>/dev/null
      if chmod 0755 "$_svc_ksud_wrapper" 2>/dev/null; then
        _SVC_SEPOLICY_TOOL="$_svc_ksud_wrapper"
        _SVC_KSUD_BIN="$_ksud_bin"  # also keep direct path
        log_service "[OK] QGL: KSU-Next ksud wrapper created at $_svc_ksud_wrapper"
      else
        # Wrapper chmod failed — ksud is verified working but we cannot make the
        # script executable. Keep the direct ksud binary path so CASE A can call
        # ksud sepolicy patch directly without the wrapper intermediary.
        _SVC_KSUD_BIN="$_ksud_bin"
        log_service "[!] QGL: ksud wrapper chmod failed — will use direct ksud calls in CASE A"
        log_service "    ksud binary: $_ksud_bin (direct sepolicy patch calls will be used)"
        rm -f "$_svc_ksud_wrapper" 2>/dev/null || true
        printf '[ADRENO-SVC] ksud wrapper chmod failed — direct ksud mode\n' > /dev/kmsg 2>/dev/null || true
      fi
      unset _svc_ksud_wrapper
    else
      log_service "[!] QGL: ksud at $_ksud_bin found but 'sepolicy patch' test failed"
    fi
  fi
  unset _ksud_bin
fi
# ── END KSU-NEXT KSUD WRAPPER ─────────────────────────────────────────────

if [ -n "$_SVC_SEPOLICY_TOOL" ]; then
  # Functional verification: inject a harmless no-op rule to confirm --live works.
  # This is separate from the discovery test (which is existence+execute only).
  if "$_SVC_SEPOLICY_TOOL" --live "allow domain domain process signal" >/dev/null 2>&1; then
    log_service "[OK] QGL: SELinux tool found + verified: $_SVC_SEPOLICY_TOOL"
  else
    log_service "[!] QGL: SELinux tool found but --live test failed: $_SVC_SEPOLICY_TOOL"
    log_service "    Will still attempt injection (may be policy-redundant on this ROM)"
  fi
else
  log_service "[!] QGL: No magiskpolicy or ksud wrapper — inline injection skipped"
  log_service "    chmod 0644 relies on static sepolicy.rule grants (allow su vendor_data_file file { setattr })"
  printf '[ADRENO-SVC] QGL: no sepolicy tool — static sepolicy.rule only\n' > /dev/kmsg 2>/dev/null || true
fi
# ── END QGL SELinux tool discovery ────────────────────────────────────────

if [ "$QGL" = "y" ]; then
  log_service "========================================"
  log_service "QGL CONFIGURATION: ACTIVATE / REPAIR"
  log_service "========================================"

  QGL_TARGET="/data/vendor/gpu/qgl_config.txt"
  QGL_TEMP="/data/vendor/gpu/.qgl_config.txt.tmp.$$"
  QGL_OWNER_MARKER="/data/vendor/gpu/.adreno_qgl_owner"

  # ── PRE-STAT SELINUX INJECTION (stuck-at-0000 root cause fix) ─────────────
  #
  # stat -c '%a' requires the SELinux 'getattr' permission on the file's type.
  # On many custom ROMs (HyperOS, MIUI, ColorOS, OneUI) the static sepolicy.rule
  # has not been loaded by the time service.sh runs at boot_completed+5s.
  # If getattr is denied:
  #   foreign-file guard stat → "?" → case "*" → _fg_skip=true → CASE A/B skipped
  #   main dispatch stat      → ""  → CASE B instead of CASE A (wrong path)
  # BOTH stat calls happen before the CASE A injection block — so the thorough
  # injection inside CASE A is unreachable when it's needed most.
  # FIX: Run a minimum getattr+setattr injection HERE, before any stat call,
  # so every subsequent stat in this block succeeds and routes correctly.
  # These calls are no-ops if the rules are already live (idempotent).
  if [ -n "$_SVC_SEPOLICY_TOOL" ]; then
    for _pre_ctx in su ksu magisk; do
      "$_SVC_SEPOLICY_TOOL" --live \
        "allow ${_pre_ctx} vendor_data_file file { getattr setattr relabelfrom relabelto }" \
        >/dev/null 2>&1 || true
      "$_SVC_SEPOLICY_TOOL" --live \
        "allow ${_pre_ctx} same_process_hal_file file { getattr setattr relabelto relabelfrom }" \
        >/dev/null 2>&1 || true
      "$_SVC_SEPOLICY_TOOL" --live \
        "allow ${_pre_ctx} unlabeled file { getattr setattr relabelfrom relabelto }" \
        >/dev/null 2>&1 || true
    done
    unset _pre_ctx
    log_service "[OK] QGL: pre-stat SELinux getattr+setattr injected (su, ksu, magisk)"
  fi
  # ── END PRE-STAT INJECTION ─────────────────────────────────────────────────

  # ── OWNERSHIP RECLAIM + FOREIGN-FILE GUARD ───────────────────────────────
  # Merged into one check so that mode 0000 (our exclusive PROTECTED MODE) is
  # NEVER blocked by the foreign-file guard, even when the owner marker is missing.
  #
  # ROOT CAUSE FIX: Previously, when touch "$QGL_OWNER_MARKER" failed (because
  # su/ksu/magisk lacked write+add_name on the same_process_hal_file directory),
  # the reclaim block logged a failure and fell through — and then the foreign-file
  # guard immediately fired: "file exists without marker → third-party → skip."
  # CASE A never ran and the file stayed at 0000 permanently.
  #
  # FIX LOGIC:
  #   • mode 0000   → ALWAYS ours (no external manager creates 0000-mode QGL config).
  #                   Attempt marker recreation; proceed to CASE A regardless.
  #   • mode non-0 + no marker → genuinely third-party (LYB, etc.) → skip.
  _fg_skip=false
  if [ -f "$QGL_TARGET" ] && [ ! -f "$QGL_OWNER_MARKER" ]; then
    # Fallback is "0" not "?" — if getattr fails despite pre-stat injection
    # (e.g., ksud/magiskpolicy unavailable), treat as mode 0000.
    # Only our module ever creates a mode-000 qgl_config.txt; no third-party
    # manager uses that mode, so treating a failed stat as 0000 is always correct.
    _svc_fgmode=$(stat -c '%a' "$QGL_TARGET" 2>/dev/null || echo "0")
    case "$_svc_fgmode" in
      "0"|"00"|"000"|"0000")
        # Mode 0000 = exclusively our PROTECTED MODE. Reclaim unconditionally.
        # If touch fails (same_process_hal_file dir perms gap on older policy builds),
        # we still proceed — mode 0000 cannot be a third-party file.
        log_service "[OK] QGL: 0000-mode file without owner marker — reclaiming (PROTECTED MODE is exclusively ours)"
        if touch "$QGL_OWNER_MARKER" 2>/dev/null && chmod 0600 "$QGL_OWNER_MARKER" 2>/dev/null; then
          log_service "    Owner marker re-created — proceeding to CASE A"
        else
          log_service "    [!] Owner marker re-create failed (dir write/add_name denied?) — forcing CASE A anyway"
          log_service "    mode 0000 is definitive proof this is our protected-mode file"
          printf '[ADRENO] QGL: 0000-mode without marker, marker touch failed — forcing CASE A\n' \
            > /dev/kmsg 2>/dev/null || true
        fi
        ;;
      *)
        # Non-zero mode + no marker = third-party manager's file
        _fg_skip=true
        log_service "[!] QGL: qgl_config.txt exists without owner marker (mode=${_svc_fgmode}) — third-party controls it"
        log_service "    Skipping to avoid overwriting (e.g. LYB Kernel Manager)"
        ;;
    esac
    unset _svc_fgmode
  fi
  # ── END ownership reclaim + guard ──────────────────────────────────────────

  if [ "$_fg_skip" = "true" ]; then
    : # foreign-file — nothing to do
  else
    # Fallback is "0000" not "missing" — if stat still fails despite pre-stat
    # injection, the file exists (we checked _fg_skip) and must be ours at mode 0000.
    # Routing to CASE A (chmod) is correct; routing to CASE B (cp) is wrong since
    # the file already exists and CASE B would try to overwrite it unnecessarily.
    _qgl_mode=$(stat -c '%a' "$QGL_TARGET" 2>/dev/null || echo "0000")

    case "$_qgl_mode" in

      "missing"|"")
        # ── CASE B: File absent — emergency full install ───────────────────────
        log_service "[!] CASE B: qgl_config.txt not present — post-fs-data.sh install failed"
        log_service "    Attempting emergency install (requires SELinux write for su/magisk domain)"

        if [ -n "$_SVC_SEPOLICY_TOOL" ]; then
          # Inject for all three root manager domains individually (NOT batched).
          # Batch risk: Knox neverallow on associate rolls back the ENTIRE batch atomically,
          # leaving even the critical setattr un-injected. Individual calls: each
          # rule succeeds or fails independently; setattr lands even when associate is blocked.
          # su    = KernelSU (tiann) + APatch service domain
          # ksu   = KernelSU-Next (rifsxd) service domain — NOT in KSU standard
          # magisk = Magisk service domain (already has allow magisk * * *, belt-and-suspenders)
          for _ctx in su ksu magisk; do
            "$_SVC_SEPOLICY_TOOL" --live \
              "allow ${_ctx} vendor_data_file dir { create read write open search add_name remove_name setattr getattr relabelfrom }" \
              >/dev/null 2>&1 || true
            "$_SVC_SEPOLICY_TOOL" --live \
              "allow ${_ctx} vendor_data_file file { create read write open getattr setattr unlink rename relabelfrom relabelto }" \
              >/dev/null 2>&1 || true
            # BUG FIX: was relabelto-only. Added relabelfrom+unlink for copy-fallback rm -f
            # and for future relabeling FROM same_process_hal_file back to vendor_data_file.
            "$_SVC_SEPOLICY_TOOL" --live \
              "allow ${_ctx} same_process_hal_file file { create read write open getattr setattr relabelto relabelfrom unlink rename }" \
              >/dev/null 2>&1 || true
            # DIRECTORY CHCON FIX: dir-level relabelto/relabelfrom for same_process_hal_file.
            # Required to chcon /data/vendor/gpu/ to same_process_hal_file in CASE B.
            # write+add_name+remove_name: needed for creating files in same_process_hal_file dirs.
            "$_SVC_SEPOLICY_TOOL" --live \
              "allow ${_ctx} same_process_hal_file dir { getattr setattr relabelto relabelfrom search read open write add_name remove_name }" \
              >/dev/null 2>&1 || true
          done
          # labeledfs = ext4/f2fs with xattr (/data partition type in Android).
          # unlabeled = fallback for any file missing a security label.
          # NOT using '*' — Knox neverallow covers tmpfs/proc/devpts and '*' hits all.
          "$_SVC_SEPOLICY_TOOL" --live \
            "allow same_process_hal_file labeledfs filesystem associate" \
            >/dev/null 2>&1 || true
          "$_SVC_SEPOLICY_TOOL" --live \
            "allow same_process_hal_file unlabeled filesystem associate" \
            >/dev/null 2>&1 || true
          log_service "    CASE B: SELinux write+relabel injected for su, ksu, magisk"
          unset _ctx
        fi

        if [ -f "$MODDIR/qgl_config.txt" ]; then
          _qgl_ok=false; _qgl_r=0
          mkdir -p /data/vendor/gpu 2>/dev/null || true
          while [ $_qgl_r -lt 5 ] && [ "$_qgl_ok" = "false" ]; do
            if cp -f "$MODDIR/qgl_config.txt" "$QGL_TEMP" 2>/dev/null && \
               [ -s "$QGL_TEMP" ]; then
              chmod 0644 "$QGL_TEMP" 2>/dev/null
              chown 0:1000 "$QGL_TEMP" 2>/dev/null
              if mv -f "$QGL_TEMP" "$QGL_TARGET" 2>/dev/null && [ -s "$QGL_TARGET" ]; then
                if chcon u:object_r:same_process_hal_file:s0 "$QGL_TARGET" 2>/dev/null; then
                  # Also chcon the directory — both required by the Adreno driver.
                  chcon u:object_r:same_process_hal_file:s0 /data/vendor/gpu/ 2>/dev/null || true
                  _qgl_ctx_actual=$(ls -Z "$QGL_TARGET" 2>/dev/null | awk '{print $1}' || echo "unknown")
                else
                  chcon u:object_r:vendor_data_file:s0 "$QGL_TARGET" 2>/dev/null || true
                  _qgl_ctx_actual=$(ls -Z "$QGL_TARGET" 2>/dev/null | awk '{print $1}' || echo "unknown")
                fi
                touch "$QGL_OWNER_MARKER" 2>/dev/null || true
                _qgl_sz=$(stat -c%s "$QGL_TARGET" 2>/dev/null || echo "?")
                log_service "[OK] CASE B: Emergency install succeeded (${_qgl_sz}B, ctx=${_qgl_ctx_actual})"
                unset _qgl_ctx_actual
                _qgl_ok=true; break
              fi
            fi
            rm -f "$QGL_TEMP" 2>/dev/null
            _qgl_r=$((_qgl_r + 1))
            [ "$_qgl_ok" = "false" ] && sleep 1
          done
          if [ "$_qgl_ok" = "false" ]; then
            log_service "[X] CASE B: Emergency install FAILED — SELinux write denied for su/magisk"
            log_service "    QGL tuning unavailable this boot"
            log_service "    Diagnostic: dmesg | grep -i 'avc.*vendor_data'"
          fi
          unset _qgl_ok _qgl_r _qgl_sz
        else
          log_service "[X] CASE B: $MODDIR/qgl_config.txt missing — module may be corrupt"
        fi
        ;;

      "0"|"00"|"000"|"0000")
        # ── CASE A: Protected mode — ACTIVATE ─────────────────────────────────
        # ── TIMING GUARD: wait for boot-completed.sh +20s window ─────────────
        # CASE A runs after sdcard wait (~boot+7-10s), before boot-completed.sh
        # finishes its 20s sleep. Without this guard CASE A activates at boot+10s,
        # short-circuiting the 20s delay that fixed the black screen.
        # boot-completed.sh: sleep 20s → cp → chmod 0644 → done. That sequence
        # needs ~2s of CPU time after the 20s sleep, so wait 25s to be safe.
        # If boot-completed.sh already wrote the file (0644), we skip immediately.
        _caseA_now=$(cat /proc/uptime 2>/dev/null | awk '{print int($1)}' || echo "999")
        _caseA_elapsed=$(( _caseA_now - ${_BOOT_COMPLETED_TS:-0} ))
        _caseA_skip=false
        if [ "$_caseA_elapsed" -lt 25 ] 2>/dev/null; then
          _caseA_wait=$(( 25 - _caseA_elapsed ))
          log_service "[CASE A] Timing guard: ${_caseA_elapsed}s elapsed — waiting ${_caseA_wait}s (boot-completed.sh writes at +20s)"
          sleep "$_caseA_wait"
          # Re-check: boot-completed.sh may have already activated
          _caseA_recheck=$(stat -c '%a' "$QGL_TARGET" 2>/dev/null || echo "0000")
          if [ "$_caseA_recheck" = "644" ] || [ "$_caseA_recheck" = "0644" ]; then
            log_service "[CASE A] boot-completed.sh already activated (0644) — CASE A skip"
            _caseA_skip=true
          fi
          unset _caseA_recheck
        fi
        unset _caseA_now _caseA_elapsed _caseA_wait
        # ── END TIMING GUARD ──────────────────────────────────────────────────
        if [ "$_caseA_skip" = "true" ]; then
          unset _caseA_skip
        else
        unset _caseA_skip
        _qgl_ctx_pre=$(ls -Z "$QGL_TARGET" 2>/dev/null | awk '{print $1}' || echo "unknown")
        printf '[ADRENO] QGL CASE A: activating protected file (mode=0000→0644, ctx=%s)\n' \
          "$_qgl_ctx_pre" > /dev/kmsg 2>/dev/null || true
        log_service "[OK] CASE A: qgl_config.txt is in PROTECTED MODE (mode=0000)"
        log_service "    SELinux context before activation: ${_qgl_ctx_pre}"
        log_service "    SurfaceFlinger (uid=1000) was blocked from reading → no Vulkan init hang"
        log_service "    Activating now: chmod 0644 — requires only 'setattr', NOT 'write'"
        log_service "    Effect: all new Vulkan contexts after activation use QGL tuning"
        unset _qgl_ctx_pre

        # ── Pre-inject setattr + relabelfrom + relabelto + hwui consumer rules ──
        #
        # (1) setattr on vendor_data_file: required for chmod 0644 to succeed.
        #     Magisk domain has 'allow magisk * * *' so it's covered. KernelSU
        #     (u:r:su:s0) and APatch have su domain; KernelSU-Next has ksu domain —
        #     neither has setattr on vendor_data_file without explicit injection.
        #     Without this: chmod silently returns EACCES → mode stays 0000 forever.
        #
        # (2) relabelfrom vendor_data_file + relabelto same_process_hal_file: required
        #     for chcon to relabel the file. Without these, chcon silently fails →
        #     file retains vendor_data_file context → HAL processes (which only have
        #     same_process_hal_file read rules) cannot open qgl_config.txt → QGL config
        #     is silently ignored even though the file is chmod 0644.
        #
        # (3) Consumer rules for both rendering paths: once QGL becomes readable
        #     (chmod 0644 + chcon same_process_hal_file):
        #     (a) debug.hwui.renderer=skiavk: appdomain processes read qgl_config.txt
        #         on every vkCreateDevice call. HWUI apps, games, Vulkan renderers.
        #     (b) debug.renderengine.backend=skiavkthreaded: SurfaceFlinger reads
        #         qgl_config.txt on VkDevice recreation events (display hotplug,
        #         protected content mode, etc.) after boot_completed. The static
        #         sepolicy.rule already grants SF same_process_hal_file read, but
        #         re-injection here ensures the rule is live at the exact moment
        #         of file activation, even on ROMs where policy reload ordering varies.
        #     Both paths require same_process_hal_file read rules. These rules are
        #     also in post-fs-data.sh batch, but re-injecting here is belt-and-suspenders
        #     batch, but re-injecting here is belt-and-suspenders for cases where the
        #     batch failed, and ensures they are present at the exact moment of activation.
        #
        # NOT batched: a Knox OEM neverallow on 'filesystem associate' (or any other
        # rule) would roll back the ENTIRE batch atomically — setattr would never land.
        # Individual calls: each succeeds or fails independently.
        if [ -n "$_SVC_SEPOLICY_TOOL" ]; then
          for _ctx in su ksu magisk; do
            "$_SVC_SEPOLICY_TOOL" --live \
              "allow ${_ctx} vendor_data_file file { getattr setattr relabelfrom relabelto }" \
              >/dev/null 2>&1 || true
            "$_SVC_SEPOLICY_TOOL" --live \
              "allow ${_ctx} vendor_data_file dir { getattr search read open relabelfrom }" \
              >/dev/null 2>&1 || true
            # BUG FIX: added create/write/open/read so the fresh-write cp (boot-completed.sh
            # and service.sh fallback) can create a new file inside the same_process_hal_file
            # directory without needing relabelfrom/relabelto permissions.
            "$_SVC_SEPOLICY_TOOL" --live \
              "allow ${_ctx} same_process_hal_file file { getattr setattr relabelto relabelfrom create write open read unlink rename }" \
              >/dev/null 2>&1 || true
            # DIRECTORY CHCON FIX: dir-level rules for chconing /data/vendor/gpu/ to
            # same_process_hal_file. Without these, the directory chcon silently fails
            # and the Adreno driver ignores qgl_config.txt (it checks both contexts).
            # write+add_name+remove_name: needed for creating/removing files in the dir
            # (owner marker touch, temp file creation in copy-fallback, rm of old file).
            "$_SVC_SEPOLICY_TOOL" --live \
              "allow ${_ctx} same_process_hal_file dir { getattr setattr relabelto relabelfrom search read open write add_name remove_name }" \
              >/dev/null 2>&1 || true
            # UNLABELED FIX: OEM ROMs (HyperOS/MIUI/ColorOS) lack type_transition
            # init vendor_data_file:dir vendor_data_file -> files created in
            # /data/vendor/gpu/ receive 'unlabeled' label instead of vendor_data_file.
            # setattr: needed for chmod 0644 on unlabeled file (primary CASE A path).
            # relabelfrom: needed for chcon FROM unlabeled to vendor_data_file/sph.
            # unlink: needed for rm -f on unlabeled file (CASE A copy fallback).
            # rename: needed for mv of unlabeled temp file → target.
            # write+add_name+remove_name on dir: needed for file creation in unlabeled dirs.
            "$_SVC_SEPOLICY_TOOL" --live \
              "allow ${_ctx} unlabeled file { create read write open getattr setattr relabelfrom unlink rename }" \
              >/dev/null 2>&1 || true
            "$_SVC_SEPOLICY_TOOL" --live \
              "allow ${_ctx} unlabeled dir { getattr setattr relabelfrom write add_name remove_name }" \
              >/dev/null 2>&1 || true
          done
          "$_SVC_SEPOLICY_TOOL" --live \
            "allow same_process_hal_file labeledfs filesystem associate" \
            >/dev/null 2>&1 || true
          "$_SVC_SEPOLICY_TOOL" --live \
            "allow same_process_hal_file unlabeled filesystem associate" \
            >/dev/null 2>&1 || true
          # Consumer rules re-injected for BOTH rendering paths:
          #   (a) debug.hwui.renderer=skiavk → appdomain processes call vkCreateDevice
          #       after boot_completed and read qgl_config.txt via same_process_hal_file.
          #   (b) debug.renderengine.backend=skiavkthreaded → SurfaceFlinger's VkDevice
          #       recreation events (display hotplug, protected content mode transitions)
          #       after boot_completed read qgl_config.txt. Static sepolicy.rule already
          #       grants SF same_process_hal_file read; re-injection here is belt-and-
          #       suspenders ensuring the rule is present at the exact moment of activation.
          # DIR rules: required because /data/vendor/gpu/ has same_process_hal_file
          # context — processes need dir search to traverse it to the config file.
          for _ctx in appdomain surfaceflinger hal_graphics_composer_default hal_graphics_allocator_default hal_graphics_mapper_default system_server zygote; do
            "$_SVC_SEPOLICY_TOOL" --live \
              "allow ${_ctx} same_process_hal_file file { read open getattr }" \
              >/dev/null 2>&1 || true
            "$_SVC_SEPOLICY_TOOL" --live \
              "allow ${_ctx} same_process_hal_file dir { search read open getattr }" \
              >/dev/null 2>&1 || true
            "$_SVC_SEPOLICY_TOOL" --live \
              "allow ${_ctx} vendor_data_file file { read open getattr }" \
              >/dev/null 2>&1 || true
          done
          log_service "    CASE A: SELinux setattr+relabelfrom+relabelto injected (su, ksu, magisk)"
          log_service "    CASE A: consumer rules re-injected (HWUI skiavk appdomain + renderengine SF + HALs)"
          unset _ctx
        fi

        # ── DIRECT KSUD INJECTION: belt-and-suspenders regardless of wrapper state ──
        # Runs unconditionally: even when _SVC_SEPOLICY_TOOL is set (wrapper works),
        # direct ksud calls here ensure the CRITICAL setattr+unlink+create rules land.
        # This covers: (a) wrapper-less KSU-Next (chmod failed), (b) any wrapper
        # failure mid-injection, (c) ROMs where sepolicy.rule was silently rejected.
        # _SVC_KSUD_BIN is set when ksud was found and tested but wrapper couldn't
        # be made executable. Also do a final discovery scan in case ksud appeared
        # after the initial wrapper-creation attempt (rare but possible on some ROMs).
        _caseA_ksud=""
        if [ -n "$_SVC_KSUD_BIN" ]; then
          _caseA_ksud="$_SVC_KSUD_BIN"
        else
          for _kb in "/data/adb/ksud" "/data/adb/ksu/bin/ksud" "$(command -v ksud 2>/dev/null)"; do
            [ -z "$_kb" ] && continue
            [ -f "$_kb" ] && [ -x "$_kb" ] && { _caseA_ksud="$_kb"; break; }
          done
          unset _kb
        fi
        if [ -n "$_caseA_ksud" ]; then
          _caseA_inj=0
          for _ctx in su ksu magisk; do
            "$_caseA_ksud" sepolicy patch \
              "allow ${_ctx} vendor_data_file file { getattr setattr unlink create write open rename relabelfrom relabelto }" \
              >/dev/null 2>&1 && _caseA_inj=$((_caseA_inj+1)) || true
            "$_caseA_ksud" sepolicy patch \
              "allow ${_ctx} vendor_data_file dir { getattr search read open relabelfrom }" \
              >/dev/null 2>&1 || true
            "$_caseA_ksud" sepolicy patch \
              "allow ${_ctx} same_process_hal_file file { getattr setattr relabelto relabelfrom create write open read unlink rename }" \
              >/dev/null 2>&1 || true
            "$_caseA_ksud" sepolicy patch \
              "allow ${_ctx} same_process_hal_file dir { getattr setattr relabelto relabelfrom search read open write add_name remove_name }" \
              >/dev/null 2>&1 || true
            "$_caseA_ksud" sepolicy patch \
              "allow ${_ctx} unlabeled file { getattr setattr relabelfrom unlink rename create write open }" \
              >/dev/null 2>&1 || true
            "$_caseA_ksud" sepolicy patch \
              "allow ${_ctx} unlabeled dir { getattr setattr relabelfrom write add_name remove_name }" \
              >/dev/null 2>&1 || true
          done
          "$_caseA_ksud" sepolicy patch "allow same_process_hal_file labeledfs filesystem associate" >/dev/null 2>&1 || true
          "$_caseA_ksud" sepolicy patch "allow same_process_hal_file unlabeled filesystem associate" >/dev/null 2>&1 || true
          log_service "    CASE A: direct ksud belt-and-suspenders injection done (${_caseA_inj}/3 su/ksu/magisk setattr rules)"
          unset _caseA_inj _ctx
        fi
        unset _caseA_ksud
        # ── END DIRECT KSUD INJECTION ─────────────────────────────────────────
        # ── END pre-injection ─────────────────────────────────────────────────

        # UNLABELED FIX: On OEM ROMs without type_transition, qgl_config.txt may
        # be labeled 'unlabeled' instead of 'vendor_data_file'. chmod needs setattr
        # on the file's actual type. If the file is unlabeled, try to relabel it to
        # vendor_data_file first (using the rules injected above), so that the existing
        # setattr grant on vendor_data_file then applies to the chmod call.
        # This is a no-op on correctly-labeled files (already vendor_data_file).
        _qgl_pre_label=$(ls -Z "$QGL_TARGET" 2>/dev/null | awk '{print $1}' || echo "")
        case "$_qgl_pre_label" in
          *unlabeled*)
            log_service "    CASE A: file labeled 'unlabeled' (OEM ROM missing type_transition)"
            log_service "    CASE A: pre-relabeling unlabeled → vendor_data_file before chmod"
            chcon u:object_r:vendor_data_file:s0 "$QGL_TARGET" 2>/dev/null && \
              log_service "    CASE A: pre-relabel OK (file now vendor_data_file — chmod will use setattr rule)" || \
              log_service "    [!] CASE A: pre-relabel failed (unlabeled relabelfrom may not be in policy yet)"
            printf '[ADRENO] QGL CASE A: unlabeled→vendor_data_file pre-relabel attempted\n' > /dev/kmsg 2>/dev/null || true
            ;;
        esac
        unset _qgl_pre_label

        if chmod 0644 "$QGL_TARGET" 2>/dev/null; then
          printf '[ADRENO] QGL CASE A: chmod 0644 succeeded\n' > /dev/kmsg 2>/dev/null || true
          chown 0:1000 "$QGL_TARGET" 2>/dev/null || chown 0:0 "$QGL_TARGET" 2>/dev/null || true
          # relabelfrom vendor_data_file + relabelto same_process_hal_file + associate now injected above.
          # CRITICAL: chcon BOTH the file AND the directory to same_process_hal_file.
          # The Adreno driver validates both contexts before reading qgl_config.txt.
          # If the directory does not have same_process_hal_file, the driver silently
          # ignores the file even if the file itself has the correct context.
          if chcon u:object_r:same_process_hal_file:s0 "$QGL_TARGET" 2>/dev/null; then
            _qgl_ctx_actual=$(ls -Z "$QGL_TARGET" 2>/dev/null | awk '{print $1}' || echo "unknown")
            log_service "    chcon file → same_process_hal_file OK (ctx=${_qgl_ctx_actual})"
            # Now chcon the directory — MANDATORY for driver to read the file.
            if chcon u:object_r:same_process_hal_file:s0 /data/vendor/gpu/ 2>/dev/null; then
              _qgl_dir_ctx=$(ls -dZ /data/vendor/gpu/ 2>/dev/null | awk '{print $1}' || echo "unknown")
              log_service "    chcon dir → same_process_hal_file OK (ctx=${_qgl_dir_ctx})"
            else
              log_service "    [!] chcon dir same_process_hal_file denied — driver may ignore config"
              printf '[ADRENO] QGL CASE A: dir chcon denied — driver may ignore config\n' > /dev/kmsg 2>/dev/null || true
            fi
            unset _qgl_dir_ctx
          else
            chcon u:object_r:vendor_data_file:s0 "$QGL_TARGET" 2>/dev/null || true
            _qgl_ctx_actual=$(ls -Z "$QGL_TARGET" 2>/dev/null | awk '{print $1}' || echo "unknown")
            log_service "    [!] chcon same_process_hal_file denied — filesystem associate OEM-blocked"
            log_service "    Fallback: ctx=${_qgl_ctx_actual} — HAL fallback via domain→vendor_data_file rule"
          fi
          unset _qgl_ctx_actual

          _qgl_new_mode=$(stat -c '%a' "$QGL_TARGET" 2>/dev/null || echo "?")
          _qgl_sz=$(stat -c%s "$QGL_TARGET" 2>/dev/null || echo "?")
          if [ "$_qgl_new_mode" = "644" ] || [ "$_qgl_new_mode" = "0644" ]; then
            printf '[ADRENO] QGL CASE A: ACTIVATED OK (mode=0644, %sB)\n' "$_qgl_sz" > /dev/kmsg 2>/dev/null || true
            log_service "[OK] CASE A: QGL ACTIVATED (mode=${_qgl_new_mode}, ${_qgl_sz}B)"
            log_service "    QGL tuning now active for all new KGSL/Vulkan contexts (HWUI skiavk apps + SF renderengine skiavkthreaded recreation events)"
          else
            printf '[ADRENO] QGL CASE A: chmod ran but mode=%s — check dmesg for avc\n' "$_qgl_new_mode" > /dev/kmsg 2>/dev/null || true
            log_service "[!] CASE A: chmod ran but mode=${_qgl_new_mode} — checking readability"
            if cat "$QGL_TARGET" >/dev/null 2>&1; then
              log_service "[OK] File readable — treating as activated"
            else
              log_service "[X] File still unreadable — activation may have failed"
            fi
          fi
          unset _qgl_new_mode _qgl_sz
        else
          # chmod denied even after pre-injection — Knox ultra-strict SELinux edge case.
          # chmod 0644 failed even after SELinux injection. This means 'setattr' on
          # vendor_data_file is blocked (e.g. file labeled 'unlabeled' instead of
          # vendor_data_file, or OEM neverallow blocks setattr on that type).
          # Copy-based fallback: remove the 0000-mode file and recreate it fresh.
          # A newly created file's mode is set at open(O_CREAT) time, which uses
          # 'create' in SELinux policy — NOT 'setattr'. This sidesteps the block.
          # 'unlink' + 'create' on vendor_data_file are granted in sepolicy.rule and
          # in the individual injection loop above — available even when setattr fails.
          printf '[ADRENO] QGL CASE A: chmod 0644 DENIED — trying copy-based fallback\n' > /dev/kmsg 2>/dev/null || true
          log_service "[X] CASE A: chmod 0644 denied after setattr injection — attempting copy-based fallback"
          log_service "    Strategy: rm the 0000-mode file + recreate fresh (uses 'create', not 'setattr')"
          if [ -f "$MODDIR/qgl_config.txt" ]; then
            if rm -f "$QGL_TARGET" 2>/dev/null; then
              if cat "$MODDIR/qgl_config.txt" > "$QGL_TARGET" 2>/dev/null && [ -s "$QGL_TARGET" ]; then
                _qgl_new_mode=$(stat -c '%a' "$QGL_TARGET" 2>/dev/null || echo "?")
                _qgl_sz=$(stat -c%s "$QGL_TARGET" 2>/dev/null || echo "?")
                log_service "    Copy fallback: file recreated (mode=${_qgl_new_mode}, ${_qgl_sz}B)"
                if chcon u:object_r:same_process_hal_file:s0 "$QGL_TARGET" 2>/dev/null; then
                  # Also chcon the directory — both are required by the Adreno driver.
                  chcon u:object_r:same_process_hal_file:s0 /data/vendor/gpu/ 2>/dev/null || true
                  _qgl_ctx_actual=$(ls -Z "$QGL_TARGET" 2>/dev/null | awk '{print $1}' || echo "unknown")
                  log_service "[OK] CASE A (copy-fallback): ACTIVATED (mode=${_qgl_new_mode}, ctx=${_qgl_ctx_actual})"
                  printf '[ADRENO] QGL CASE A: ACTIVATED via copy-fallback (mode=%s)\n' \
                    "$_qgl_new_mode" > /dev/kmsg 2>/dev/null || true
                else
                  chcon u:object_r:vendor_data_file:s0 "$QGL_TARGET" 2>/dev/null || true
                  _qgl_ctx_actual=$(ls -Z "$QGL_TARGET" 2>/dev/null | awk '{print $1}' || echo "unknown")
                  log_service "[~] CASE A (copy-fallback): file recreated as ${_qgl_new_mode}, chcon OEM-blocked"
                  log_service "    ctx=${_qgl_ctx_actual} — QGL accessible via vendor_data_file consumer rules"
                  printf '[ADRENO] QGL CASE A: copy-fallback partial (mode=%s, chcon blocked)\n' \
                    "$_qgl_new_mode" > /dev/kmsg 2>/dev/null || true
                fi
              else
                log_service "[X] CASE A (copy-fallback): cat/create blocked — both setattr and create denied"
                log_service "    Attempting direct ksud injection as last-resort fallback..."
                # LAST-RESORT: directly call ksud sepolicy patch without the wrapper.
                # This covers the edge case where the wrapper creation failed or was
                # not available at discovery time but ksud itself is accessible.
                _la_ksud_bin=""
                for _kb2 in "/data/adb/ksud" "/data/adb/ksu/bin/ksud" "$(command -v ksud 2>/dev/null)"; do
                  [ -z "$_kb2" ] && continue
                  [ -f "$_kb2" ] && [ -x "$_kb2" ] && { _la_ksud_bin="$_kb2"; break; }
                done
                unset _kb2
                if [ -n "$_la_ksud_bin" ]; then
                  for _la_ctx in su ksu magisk; do
                    "$_la_ksud_bin" sepolicy patch "allow ${_la_ctx} vendor_data_file file { create write open unlink rename }" 2>/dev/null || true
                    "$_la_ksud_bin" sepolicy patch "allow ${_la_ctx} unlabeled file { create write open setattr relabelfrom unlink rename }" 2>/dev/null || true
                  done
                  unset _la_ctx
                  log_service "    Direct ksud injection done — retrying cat/create once more"
                  if cat "$MODDIR/qgl_config.txt" > "$QGL_TARGET" 2>/dev/null && [ -s "$QGL_TARGET" ]; then
                    log_service "[OK] CASE A (ksud last-resort): file created after direct injection"
                    chcon u:object_r:same_process_hal_file:s0 "$QGL_TARGET" 2>/dev/null || \
                      chcon u:object_r:vendor_data_file:s0 "$QGL_TARGET" 2>/dev/null || true
                    printf '[ADRENO] QGL CASE A: ACTIVATED via ksud last-resort\n' > /dev/kmsg 2>/dev/null || true
                  else
                    log_service "[X] CASE A: ksud last-resort also failed — all paths exhausted"
                    log_service "    Will self-heal next boot. Check: dmesg | grep 'avc.*vendor_data'"
                    printf '[ADRENO] QGL CASE A: ALL paths DENIED — check dmesg avc\n' > /dev/kmsg 2>/dev/null || true
                  fi
                else
                  log_service "    ksud not found — no last-resort available"
                  log_service "    Will self-heal next boot. Check: dmesg | grep 'avc.*vendor_data'"
                  printf '[ADRENO] QGL CASE A: BOTH chmod and copy-fallback DENIED\n' > /dev/kmsg 2>/dev/null || true
                fi
                unset _la_ksud_bin
              fi
            else
              # rm -f failed — unlink is denied. This is unusual since we injected
              # 'unlink' above. Try direct ksud injection specifically for unlink,
              # retry rm once, and if still blocked, overwrite the existing 0000-mode
              # file in-place (requires 'write' on vendor_data_file, NOT 'unlink').
              # After overwrite, attempt chmod 0644 again with refreshed rules.
              log_service "[X] CASE A (copy-fallback): rm -f blocked — attempting ksud direct unlink injection + retry"
              printf '[ADRENO] QGL CASE A: unlink DENIED — injecting direct ksud rules\n' > /dev/kmsg 2>/dev/null || true
              _rmretry_ksud=""
              for _kb in "/data/adb/ksud" "/data/adb/ksu/bin/ksud" "$(command -v ksud 2>/dev/null)"; do
                [ -z "$_kb" ] && continue
                [ -f "$_kb" ] && [ -x "$_kb" ] && { _rmretry_ksud="$_kb"; break; }
              done
              unset _kb
              if [ -n "$_rmretry_ksud" ]; then
                for _rmctx in su ksu magisk; do
                  "$_rmretry_ksud" sepolicy patch "allow ${_rmctx} vendor_data_file file { unlink create write open setattr getattr }" 2>/dev/null || true
                  "$_rmretry_ksud" sepolicy patch "allow ${_rmctx} unlabeled file { unlink create write open setattr getattr relabelfrom }" 2>/dev/null || true
                done
                unset _rmctx
                log_service "    Retrying rm -f after direct ksud unlink injection..."
                if rm -f "$QGL_TARGET" 2>/dev/null; then
                  # rm succeeded after injection — create fresh file (mode 0644 from umask)
                  if cat "$MODDIR/qgl_config.txt" > "$QGL_TARGET" 2>/dev/null && [ -s "$QGL_TARGET" ]; then
                    chmod 0644 "$QGL_TARGET" 2>/dev/null || true
                    if chcon u:object_r:same_process_hal_file:s0 "$QGL_TARGET" 2>/dev/null; then
                      chcon u:object_r:same_process_hal_file:s0 /data/vendor/gpu/ 2>/dev/null || true
                      _qgl_ctx_actual=$(ls -Z "$QGL_TARGET" 2>/dev/null | awk '{print $1}' || echo "unknown")
                      log_service "[OK] CASE A (rm-retry): ACTIVATED after ksud injection (ctx=${_qgl_ctx_actual})"
                      printf '[ADRENO] QGL CASE A: ACTIVATED via rm-retry path\n' > /dev/kmsg 2>/dev/null || true
                    else
                      chcon u:object_r:vendor_data_file:s0 "$QGL_TARGET" 2>/dev/null || true
                      log_service "[~] CASE A (rm-retry): file recreated, chcon OEM-blocked"
                    fi
                    unset _qgl_ctx_actual
                  else
                    log_service "[X] CASE A (rm-retry): create still denied after direct injection"
                    printf '[ADRENO] QGL CASE A: create DENIED even after ksud injection\n' > /dev/kmsg 2>/dev/null || true
                  fi
                else
                  # rm still fails — overwrite in-place (avoids unlink, uses write instead)
                  log_service "    rm still denied — trying in-place overwrite (write without unlink)"
                  if cat "$MODDIR/qgl_config.txt" > "$QGL_TARGET" 2>/dev/null && [ -s "$QGL_TARGET" ]; then
                    # File exists with 0000 mode but new content — attempt chmod now
                    if chmod 0644 "$QGL_TARGET" 2>/dev/null; then
                      if chcon u:object_r:same_process_hal_file:s0 "$QGL_TARGET" 2>/dev/null; then
                        chcon u:object_r:same_process_hal_file:s0 /data/vendor/gpu/ 2>/dev/null || true
                        _qgl_ctx_actual=$(ls -Z "$QGL_TARGET" 2>/dev/null | awk '{print $1}' || echo "unknown")
                        log_service "[OK] CASE A (in-place): ACTIVATED (overwrite+chmod, ctx=${_qgl_ctx_actual})"
                        printf '[ADRENO] QGL CASE A: ACTIVATED via in-place overwrite\n' > /dev/kmsg 2>/dev/null || true
                        unset _qgl_ctx_actual
                      else
                        log_service "[~] CASE A (in-place): chmod OK but chcon blocked — mode 0644, vendor_data_file ctx"
                      fi
                    else
                      log_service "[X] CASE A (in-place): content written but chmod still denied (mode stays 0000)"
                      log_service "    Content is there. Check dmesg for AVC denials on setattr+vendor_data_file"
                      printf '[ADRENO] QGL CASE A: in-place write OK but chmod DENIED — mode=0000\n' > /dev/kmsg 2>/dev/null || true
                    fi
                  else
                    log_service "[X] CASE A: all paths exhausted — SELinux fully blocking this domain"
                    log_service "    Check: dmesg | grep 'avc.*vendor_data_file'"
                    printf '[ADRENO] QGL CASE A: ALL paths DENIED — check dmesg avc\n' > /dev/kmsg 2>/dev/null || true
                  fi
                fi
              else
                log_service "[X] CASE A (copy-fallback): rm -f blocked and no ksud available"
                log_service "    Will self-heal next boot. Check: dmesg | grep 'avc.*vendor_data'"
                printf '[ADRENO] QGL CASE A: unlink DENIED — no ksud fallback available\n' > /dev/kmsg 2>/dev/null || true
              fi
              unset _rmretry_ksud
            fi
          else
            log_service "[X] CASE A (copy-fallback): $MODDIR/qgl_config.txt missing — module may be corrupt"
            log_service "    Will self-heal next boot."
          fi
        fi
        fi # end timing guard
        ;;

      *)
        # ── CASE C: File healthy — verify and correct drift ───────────────────
        _qgl_sz=$(stat -c%s "$QGL_TARGET" 2>/dev/null || echo "0")
        _qgl_ctx=$(ls -Z "$QGL_TARGET" 2>/dev/null | awk '{print $1}' || echo "unknown")
        log_service "[OK] CASE C: QGL config active and healthy"
        log_service "    Mode: ${_qgl_mode}  Size: ${_qgl_sz}B  Context: ${_qgl_ctx}"

        # BUG FIX (644): Pre-inject setattr+relabelfrom+relabelto BEFORE any chmod/chcon.
        # Without this, the mode-drift chmod below can fail silently on KernelSU-Next
        # (u:r:ksu:s0 lacks setattr on vendor_data_file without explicit injection).
        # Injected here once — both mode-drift and context-drift handlers rely on it.
        # Individual calls (not batched) — same Knox neverallow reasoning as CASE A.
        if [ -n "$_SVC_SEPOLICY_TOOL" ]; then
          for _ctx in su ksu magisk; do
            "$_SVC_SEPOLICY_TOOL" --live \
              "allow ${_ctx} vendor_data_file file { getattr setattr relabelfrom relabelto }" \
              >/dev/null 2>&1 || true
            "$_SVC_SEPOLICY_TOOL" --live \
              "allow ${_ctx} vendor_data_file dir { getattr search read open }" \
              >/dev/null 2>&1 || true
            # BUG FIX: was relabelto-only. Added relabelfrom+unlink — same rationale as CASE A.
            "$_SVC_SEPOLICY_TOOL" --live \
              "allow ${_ctx} same_process_hal_file file { getattr setattr relabelto relabelfrom unlink }" \
              >/dev/null 2>&1 || true
            # DIRECTORY CHCON FIX: same rationale as CASE A.
            "$_SVC_SEPOLICY_TOOL" --live \
              "allow ${_ctx} same_process_hal_file dir { getattr setattr relabelto relabelfrom search read open }" \
              >/dev/null 2>&1 || true
            "$_SVC_SEPOLICY_TOOL" --live \
              "allow ${_ctx} vendor_data_file dir { relabelfrom }" \
              >/dev/null 2>&1 || true
            # UNLABELED FIX: same rationale as CASE A injection above.
            "$_SVC_SEPOLICY_TOOL" --live \
              "allow ${_ctx} unlabeled file { getattr setattr relabelfrom unlink }" \
              >/dev/null 2>&1 || true
            "$_SVC_SEPOLICY_TOOL" --live \
              "allow ${_ctx} unlabeled dir { getattr setattr relabelfrom }" \
              >/dev/null 2>&1 || true
          done
          "$_SVC_SEPOLICY_TOOL" --live \
            "allow same_process_hal_file labeledfs filesystem associate" \
            >/dev/null 2>&1 || true
          "$_SVC_SEPOLICY_TOOL" --live \
            "allow same_process_hal_file unlabeled filesystem associate" \
            >/dev/null 2>&1 || true
          unset _ctx
          log_service "    CASE C: SELinux setattr+relabelfrom+associate pre-injected (su, ksu, magisk)"
        fi

        if [ "$_qgl_mode" != "644" ] && [ "$_qgl_mode" != "0644" ]; then
          chmod 0644 "$QGL_TARGET" 2>/dev/null && \
            log_service "    Corrected mode drift → 0644" || \
            log_service "    [!] mode-drift chmod failed (SELinux EACCES even after injection?)"
        fi

        # Context-drift check: if chcon failed on a prior boot, file keeps vendor_data_file
        # context → hal_graphics_* HAL domains (same_process_hal_file-only read rules)
        # silently cannot open qgl_config.txt → QGL tuning never loaded.
        # Injection was already done above — just attempt the chcon here.
        case "$_qgl_ctx" in
          *same_process_hal_file*)
            log_service "    Context: same_process_hal_file — correct, no relabeling needed"
            # Ensure directory also has same_process_hal_file (belt-and-suspenders).
            _qgl_dir_ctx=$(ls -dZ /data/vendor/gpu/ 2>/dev/null | awk '{print $1}' || echo "unknown")
            if [ "$_qgl_dir_ctx" != "u:object_r:same_process_hal_file:s0" ]; then
              chcon u:object_r:same_process_hal_file:s0 /data/vendor/gpu/ 2>/dev/null && \
                log_service "    [OK] CASE C: dir context corrected → same_process_hal_file" || \
                log_service "    [!] CASE C: dir chcon denied (dir ctx=${_qgl_dir_ctx})"
            fi
            unset _qgl_dir_ctx
            ;;
          *)
            log_service "    Context drift detected ('${_qgl_ctx}') — attempting relabel"
            # Rules (setattr, relabelfrom, relabelto, associate) injected above
            if chcon u:object_r:same_process_hal_file:s0 "$QGL_TARGET" 2>/dev/null; then
              # Also correct the directory context.
              chcon u:object_r:same_process_hal_file:s0 /data/vendor/gpu/ 2>/dev/null || true
              _qgl_ctx_new=$(ls -Z "$QGL_TARGET" 2>/dev/null | awk '{print $1}' || echo "unknown")
              log_service "    [OK] Context corrected → ${_qgl_ctx_new}"
              unset _qgl_ctx_new
            else
              _qgl_ctx_new=$(ls -Z "$QGL_TARGET" 2>/dev/null | awk '{print $1}' || echo "unknown")
              log_service "    [!] chcon same_process_hal_file denied (OEM-blocked associate on /data fs)"
              log_service "    Current ctx: ${_qgl_ctx_new} — HAL fallback via domain→vendor_data_file rule"
              unset _qgl_ctx_new
            fi
            ;;
        esac

        if [ "$_qgl_sz" = "0" ]; then
          log_service "[X] CASE C: File is empty — removing so next boot reinstalls"
          rm -f "$QGL_TARGET" "$QGL_OWNER_MARKER" 2>/dev/null || true
        fi
        unset _qgl_sz _qgl_ctx
        ;;
    esac

    unset _qgl_mode
  fi
  unset _fg_skip

  unset QGL_TARGET QGL_TEMP QGL_OWNER_MARKER
fi
unset _SVC_SEPOLICY_TOOL _SVC_KSUD_BIN

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
      _skvk_sysui_count=$(dumpsys gfxinfo com.android.systemui 2>/dev/null \
                          | grep -c "Skia (Vulkan)" 2>/dev/null || echo "0")
      _skvk_sysui_count="${_skvk_sysui_count:-0}"

      if [ "$_skvk_sysui_count" -gt 0 ] 2>/dev/null; then
        printf 'confirmed\n' > "${_skvk_compat_file}.tmp" 2>/dev/null && \
          mv "${_skvk_compat_file}.tmp" "$_skvk_compat_file" 2>/dev/null || true
        log_service "[OK] skiavk VK canary: SystemUI on Vulkan (${_skvk_sysui_count} Skia(Vulkan) surface(s)) — writing confirmed, QGL gate cleared for next boot"
      else
        _skvk_pipe=$(dumpsys gfxinfo com.android.systemui 2>/dev/null \
                     | grep -i "Pipeline" | head -1 || echo "")
        _skvk_live=$(getprop debug.hwui.renderer 2>/dev/null || echo "")
        printf 'prop_only\n' > "${_skvk_compat_file}.tmp" 2>/dev/null && \
          mv "${_skvk_compat_file}.tmp" "$_skvk_compat_file" 2>/dev/null || true
        log_service "[!] skiavk VK canary: SystemUI NOT on Vulkan — writing prop_only (QGL gate stays locked)"
        log_service "    SystemUI pipeline : '${_skvk_pipe:-unknown}'"
        log_service "    Live renderer prop: '${_skvk_live}'"
        log_service "    Skia(Vulkan) count: 0"
      fi
      unset _skvk_sysui_count _skvk_pipe _skvk_live
    fi
    unset _skvk_drv_ok
  fi
  unset _skvk_cur _skvk_compat_file
fi
# ── END SKIAVK VK COMPAT CANARY WRITE ────────────────────────────────────────

log_service "========================================"
log_service "MARKING SUCCESSFUL BOOT"
log_service "========================================"

BOOT_ATTEMPTS_FILE="/data/local/tmp/adreno_boot_attempts"

# BUG-A FIX: Use atomic printf+mv pattern (same as post-fs-data.sh BUG-1/2 fix).
# echo > file truncates then writes in two non-atomic steps; a crash between
# truncation and the write leaves an empty file.  An empty file is read back as
# "0" (the :-0 default) on the next boot, so the functional impact is tiny, but
# the pattern must be consistent with every other counter write in this module.
if printf '0\n' > "${BOOT_ATTEMPTS_FILE}.tmp" 2>/dev/null && \
   mv "${BOOT_ATTEMPTS_FILE}.tmp" "$BOOT_ATTEMPTS_FILE" 2>/dev/null; then
  log_service "[OK] Boot attempt counter reset to 0"
else
  rm -f "${BOOT_ATTEMPTS_FILE}.tmp" 2>/dev/null || true
  log_service "[!] WARNING: Failed to reset boot attempt counter"
fi

# Skip the marker if this boot confirmed Vulkan is incompatible with this device.
# When adreno_vk_compat="incompatible", the next boot's post-fs-data.sh would see
# _PREV_BOOT_SUCCESS=true and promote to skiavkthreaded — but Vulkan is broken, so
# SF would freeze. Suppressing the marker forces post-fs-data.sh to stay on
# skiaglthreaded until a future boot re-evaluates compat.
# "prop_only" is NOT suppressed: that means the ICD runs but VK compat is uncertain;
# SF's own Vulkan compositor path is independent and may still work.
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

log_service "========================================"
log_service "service.sh completed successfully"
log_service "Total elapsed time: approx ${ELAPSED:-0}s + processing"
log_service "========================================"

exit 0
