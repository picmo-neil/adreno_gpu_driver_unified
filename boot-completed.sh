#!/system/bin/sh
# Adreno GPU Driver — QGL Boot Preparation
#
# TWO-PHASE QGL STRATEGY:
#   Phase 1 (post-fs-data.sh): REMOVE stale QGL before Zygote forks.
#     Prevents GPU driver from reading QGL during init (causes bootloop).
#   Phase 2 (this script): PREPARE directory + remove disabled marker.
#     Does NOT write qgl_config.txt at boot (matches LYB behavior).
#     The Adreno driver reads QGL at vkCreateDevice() time — writing it
#     after SystemUI/launcher already created VkDevices causes black screen.
#
# PER-APP QGL: The QGL Trigger APK (AccessibilityService) applies the
#   correct config on each app switch. SystemUI runs without QGL (fine —
#   not a game). Each app gets QGL when it opens and creates VkDevice fresh.
#
# STATIC QGL (fallback): Writes bundled qgl_config.txt with retry+verify.
#   Only used when QGL_PERAPP=n.
#
# LOGGING: All operations logged to /sdcard/Adreno_Driver/qgl_trigger.log
#   and /sdcard/Adreno_Driver/qgl_diagnostics.log for diagnostics.

MODDIR="${0%/*}"
LOG_FILE="/sdcard/Adreno_Driver/qgl_trigger.log"
DIAG_FILE="/sdcard/Adreno_Driver/qgl_diagnostics.log"
QGL_DIR="/data/vendor/gpu"
QGL_TARGET="/data/vendor/gpu/qgl_config.txt"
BASELINE_FLAG="/data/vendor/gpu/.qgl_boot_baseline_ready"

_qgl_log() {
  _ts=$(date +%H:%M:%S 2>/dev/null || echo '?')
  printf '[%s] %s\n' "$_ts" "$1" >> "$LOG_FILE" 2>/dev/null || true
  printf '[%s] %s\n' "$_ts" "$1" > /dev/kmsg 2>/dev/null || true
}

_qgl_diag() {
  _ts=$(date +%Y-%m-%d_%H:%M:%S 2>/dev/null || echo '?')
  printf '[%s] [BOOT-DIAG] %s\n' "$_ts" "$1" >> "$DIAG_FILE" 2>/dev/null || true
}

_qgl_state_capture() {
  _label="$1"
  _qgl_diag "=== STATE CAPTURE: $_label ==="
  
  if [ -f "$QGL_TARGET" ]; then
    _qgl_diag "QGL_FILE: EXISTS"
    _ls=$(ls -laZ "$QGL_TARGET" 2>/dev/null || echo 'ls_failed')
    _qgl_diag "QGL_FILE_LS: $_ls"
    _ctx=$(ls -Z "$QGL_TARGET" 2>/dev/null | awk '{print $1}' || echo 'unknown')
    _qgl_diag "QGL_FILE_CONTEXT: $_ctx"
    _size=$(wc -c < "$QGL_TARGET" 2>/dev/null || echo '0')
    _qgl_diag "QGL_FILE_SIZE: $_size bytes"
  else
    _qgl_diag "QGL_FILE: ABSENT"
  fi
  
  if [ -d "$QGL_DIR" ]; then
    _qgl_diag "QGL_DIR: EXISTS"
    _dirctx=$(ls -dZ "$QGL_DIR" 2>/dev/null | awk '{print $1}' || echo 'unknown')
    _qgl_diag "QGL_DIR_CONTEXT: $_dirctx"
  else
    _qgl_diag "QGL_DIR: ABSENT"
  fi
  
  _enforce=$(getenforce 2>/dev/null || echo 'unknown')
  _qgl_diag "SELINUX_MODE: $_enforce"
  
  _avc=$(dmesg 2>/dev/null | grep -E 'avc.*qgl|avc.*same_process_hal' | tail -5 | tr '\n' '|' || echo 'none')
  _qgl_diag "QGL_AVC_DENIALS: $_avc"
  
  _qgl_diag "=== END STATE CAPTURE ==="
}

mkdir -p /sdcard/Adreno_Driver 2>/dev/null || true

_qgl_diag "========================================"
_qgl_diag "BOOT-COMPLETED.SH STARTED"
_qgl_diag "PID: $$"
_qgl_diag "TIME: $(date 2>/dev/null || echo 'unknown')"
_qgl_diag "========================================"

QGL="n"
QGL_PERAPP="n"
QGL_SYSTEM_APPS="n"
for _cfg in \
    "/sdcard/Adreno_Driver/Config/adreno_config.txt" \
    "/data/local/tmp/adreno_config.txt" \
    "$MODDIR/adreno_config.txt"; do
  [ -f "$_cfg" ] || continue
  while IFS='= ' read -r _k _v; do
    case "$_k" in
      QGL) case "$_v" in [Yy]*|1) QGL="y" ;; esac ;;
      QGL_PERAPP) case "$_v" in [Yy]*|1) QGL_PERAPP="y" ;; esac ;;
      QGL_SYSTEM_APPS) case "$_v" in [Yy]*|1) QGL_SYSTEM_APPS="y" ;; esac ;;
    esac
  done < "$_cfg"
  [ "$QGL" = "y" ] && break
done
unset _cfg _k _v

_qgl_log "[BOOT] Config loaded: QGL=$QGL QGL_PERAPP=$QGL_PERAPP QGL_SYSTEM_APPS=$QGL_SYSTEM_APPS"
_qgl_diag "CONFIG_QGL: $QGL"
_qgl_diag "CONFIG_QGL_PERAPP: $QGL_PERAPP"
_qgl_diag "CONFIG_QGL_SYSTEM_APPS: $QGL_SYSTEM_APPS"

if [ "$QGL" != "y" ]; then
  _qgl_log "[BOOT] QGL=n in config — skipping QGL activation"
  _qgl_diag "EXIT: QGL disabled in config"
  exit 0
fi

rm -f "/data/local/tmp/.qgl_disabled" 2>/dev/null || true
_qgl_log "[BOOT] Removed .qgl_disabled marker (QGL enabled)"

_qgl_state_capture "BEFORE_BOOT_QGL"

_qgl_log "[BOOT] Waiting for sys.boot_completed=1..."
_qgl_diag "WAIT: For sys.boot_completed=1"

_boot_wait=0
while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ] && [ $_boot_wait -lt 120 ]; do
  sleep 1
  _boot_wait=$((_boot_wait + 1))
done
unset _boot_wait

if [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ]; then
  _qgl_log "[BOOT] sys.boot_completed never reached — exiting"
  _qgl_diag "EXIT: boot_completed never reached"
  exit 0
fi

_qgl_log "[BOOT] sys.boot_completed=1 confirmed"
_qgl_diag "WAIT: OK - boot_completed=1"

_qgl_log "[BOOT] Preparing $QGL_DIR"
_qgl_diag "DIR_OP: Creating $QGL_DIR"

mkdir -p "$QGL_DIR" 2>/dev/null || true
_qgl_diag "DIR_OP: mkdir done"

_qgl_log "[BOOT] Setting context on directory"
_qgl_diag "SELINUX_OP: chcon u:object_r:same_process_hal_file:s0 $QGL_DIR"

_chcon_out=$(chcon u:object_r:same_process_hal_file:s0 "$QGL_DIR" 2>&1)
_chcon_rc=$?

if [ $_chcon_rc -eq 0 ]; then
  _qgl_log "[BOOT] Directory context set"
  _qgl_diag "SELINUX_OP: chcon dir succeeded"
else
  _qgl_log "[WARN] chcon directory failed: $_chcon_out"
  _qgl_diag "SELINUX_OP: chcon dir failed: $_chcon_out"
fi

_dir_ctx=$(ls -dZ "$QGL_DIR" 2>/dev/null | awk '{print $1}' || echo 'unknown')
_qgl_log "[BOOT] Directory context: $_dir_ctx"
_qgl_diag "SELINUX_VERIFY: Dir context: $_dir_ctx"

case "$_dir_ctx" in
  *same_process_hal_file*)
    _qgl_log "[BOOT] Directory context VERIFIED"
    _qgl_diag "SELINUX_VERIFY: OK - Dir context correct"
    ;;
  *)
    _qgl_log "[WARN] Directory context NOT same_process_hal_file"
    _qgl_diag "SELINUX_VERIFY: WARN - Dir context unexpected: $_dir_ctx"
    ;;
esac

touch "$BASELINE_FLAG" 2>/dev/null || true

if [ -f "$BASELINE_FLAG" ]; then
  _qgl_log "[BOOT] Baseline flag written"
  _qgl_diag "FLAG_OP: OK - Baseline flag created"
else
  _qgl_log "[WARN] Failed to write baseline flag"
  _qgl_diag "FLAG_OP: WARN - Baseline flag creation failed"
fi

if [ "$QGL_PERAPP" = "y" ]; then
  _qgl_log "[BOOT] Per-app mode: APK will apply QGL on first app switch (matches LYB)"
  _qgl_diag "MODE: PER-APP - No boot QGL write, APK handles runtime"
  _qgl_state_capture "PERAPP_BOOT_DONE"
  _qgl_log "[END] boot-completed.sh finished (per-app mode, no QGL written at boot)"
  _qgl_diag "========================================"
  _qgl_diag "BOOT-COMPLETED.SH FINISHED (PER-APP)"
  _qgl_diag "========================================"
  exit 0
fi

# ══════════════════════════════════════════════════════════════════════════
# STATIC MODE (QGL_PERAPP=n): Apply bundled qgl_config.txt
# ══════════════════════════════════════════════════════════════════════════

_qgl_log "[BOOT] Static mode: installing from bundled qgl_config.txt"
_qgl_diag "MODE: STATIC - Installing bundled config"

QGL_OWNER_MARKER="/data/vendor/gpu/.adreno_qgl_owner"

if [ -f "$QGL_TARGET" ] && [ ! -f "$QGL_OWNER_MARKER" ]; then
  _qgl_log "[!] QGL static: qgl_config.txt exists but NOT owned by this module — skipping"
  _qgl_diag "STATIC: SKIP - File exists but not owned by module"
  exit 0
fi

if [ ! -f "$MODDIR/qgl_config.txt" ]; then
  _qgl_log "[!] QGL static: qgl_config.txt not found in module"
  _qgl_diag "STATIC: SKIP - No bundled qgl_config.txt"
  exit 0
fi

_qgl_log "[BOOT] Proceeding with static install"
_qgl_diag "STATIC: Starting install"

QGL_INSTALL_SUCCESS="false"
MAX_RETRIES=5
RETRY_COUNT=0
QGL_TEMP=""

while [ $RETRY_COUNT -lt $MAX_RETRIES ] && [ "$QGL_INSTALL_SUCCESS" = "false" ]; do
  sleep 1
  _qgl_diag "STATIC_RETRY: Attempt $((RETRY_COUNT + 1))/$MAX_RETRIES"
  
  if touch /data/.adreno_test 2>/dev/null && rm /data/.adreno_test 2>/dev/null; then
    QGL_TEMP="${QGL_TARGET}.tmp.$$"
    _qgl_diag "FILE_OP: Temp file: $QGL_TEMP"
    
    if cp -f "$MODDIR/qgl_config.txt" "$QGL_TEMP" 2>/dev/null; then
      if [ -f "$QGL_TEMP" ] && [ -s "$QGL_TEMP" ]; then
        _qgl_diag "FILE_OP: cp succeeded, size: $(wc -c < "$QGL_TEMP" 2>/dev/null || echo '?') bytes"
        
        touch "$QGL_TEMP" 2>/dev/null || true
        chcon u:object_r:same_process_hal_file:s0 "$QGL_TEMP" 2>/dev/null || true
        chmod 0644 "$QGL_TEMP" 2>/dev/null || true
        
        if mv -f "$QGL_TEMP" "$QGL_TARGET" 2>/dev/null; then
          if [ -f "$QGL_TARGET" ] && [ -s "$QGL_TARGET" ]; then
            _qgl_log "[BOOT] File renamed successfully"
            _qgl_diag "FILE_OP: mv succeeded"
            
            touch "$QGL_TARGET" 2>/dev/null || true
            chcon u:object_r:same_process_hal_file:s0 "$QGL_TARGET" 2>/dev/null || true
            chmod 0644 "$QGL_TARGET" 2>/dev/null || true
            
            EXPECTED_SIZE=$(stat -c%s "$MODDIR/qgl_config.txt" 2>/dev/null || echo 0)
            ACTUAL_SIZE=$(stat -c%s "$QGL_TARGET" 2>/dev/null || echo 0)
            
            if [ "$EXPECTED_SIZE" -eq "$ACTUAL_SIZE" ] 2>/dev/null && [ "$ACTUAL_SIZE" -gt 0 ] 2>/dev/null; then
              QGL_INSTALL_SUCCESS="true"
              touch "$QGL_OWNER_MARKER" 2>/dev/null || true
              _qgl_log "[OK] QGL static install verified: $ACTUAL_SIZE bytes"
              _qgl_diag "STATIC_RESULT: SUCCESS - $ACTUAL_SIZE bytes"
              break
            else
              _qgl_log "[!] QGL static size mismatch: expected=$EXPECTED_SIZE actual=$ACTUAL_SIZE"
              _qgl_diag "STATIC: WARN - Size mismatch"
            fi
          fi
        else
          _qgl_log "[!] QGL static atomic rename failed"
          _qgl_diag "FILE_OP: mv failed"
          rm -f "$QGL_TEMP" 2>/dev/null || true
        fi
      else
        _qgl_log "[!] QGL static temp file empty"
        _qgl_diag "FILE_OP: Temp file empty"
        rm -f "$QGL_TEMP" 2>/dev/null || true
      fi
    fi
  fi
  
  RETRY_COUNT=$((RETRY_COUNT + 1))
  if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
    _delay=$((RETRY_COUNT * 2))
    _qgl_log "[BOOT] Retry $RETRY_COUNT in ${_delay}s..."
    sleep $_delay
  fi
done

rm -f "$QGL_TEMP" 2>/dev/null || true

if [ "$QGL_INSTALL_SUCCESS" = "false" ]; then
  _qgl_log "[FAIL] QGL static install failed after $MAX_RETRIES attempts"
  _qgl_diag "STATIC_RESULT: FAIL - Max retries exceeded"
fi

_qgl_state_capture "AFTER_STATIC_INSTALL"
unset QGL_TARGET QGL_OWNER_MARKER QGL_TEMP QGL_INSTALL_SUCCESS MAX_RETRIES RETRY_COUNT EXPECTED_SIZE ACTUAL_SIZE

_qgl_log "[END] boot-completed.sh finished"
_qgl_diag "========================================"
_qgl_diag "BOOT-COMPLETED.SH FINISHED"
_qgl_diag "========================================"
