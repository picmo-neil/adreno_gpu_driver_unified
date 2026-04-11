#!/system/bin/sh
# Adreno GPU Driver — Per-App QGL Config Applier
#
# Called by boot-completed.sh for the initial boot apply.
# The QGL Trigger APK (AccessibilityService) handles runtime app switches
# directly via cp — it does NOT call this script.
#
# USAGE:
#   apply_qgl.sh --boot                  # Boot mode (from boot-completed.sh)
#
# BEHAVIOR:
#   1. Finds qgl_config.txt in /sdcard/Adreno_Driver/Config/ (or /data/local/tmp/)
#   2. Copies to /data/vendor/gpu/qgl_config.txt atomically (tmp + chcon + mv)
#   3. Sets SELinux context to same_process_hal_file on BOTH dir and file
#
# FILE-BASED PER-APP QGL:
#   Per-app configs are stored as qgl_config.txt.<package_name> in the Config dir.
#   The QGLTrigger APK detects app switches and copies the matching file to
#   /data/vendor/gpu/qgl_config.txt. If no per-app file exists, it falls back
#   to the default qgl_config.txt.
#
# ATOMIC WRITE: tmp + chcon + mv (same_process_hal_file), NO chmod, NO chown.
#   No rm before mv — avoids SF crash window where file is missing.

MODDIR="${0%/*}"
QGL_TARGET="/data/vendor/gpu/qgl_config.txt"
QGL_DIR="/data/vendor/gpu"
CONFIG_DIR_SD="/sdcard/Adreno_Driver/Config"
CONFIG_DIR_DATA="/data/local/tmp"
LOG_FILE="/sdcard/Adreno_Driver/qgl_trigger.log"
DIAG_FILE="/sdcard/Adreno_Driver/qgl_diagnostics.log"

_qgl_log() {
  _ts=$(date +%H:%M:%S 2>/dev/null || echo '?')
  printf '[%s] %s\n' "$_ts" "$1" >> "$LOG_FILE" 2>/dev/null || true
  printf '[%s] %s\n' "$_ts" "$1" > /dev/kmsg 2>/dev/null || true
}

_qgl_diag() {
  _ts=$(date +%Y-%m-%d_%H:%M:%S 2>/dev/null || echo '?')
  printf '[%s] [DIAG] %s\n' "$_ts" "$1" >> "$DIAG_FILE" 2>/dev/null || true
}

_qgl_state_capture() {
  _label="$1"
  _qgl_diag "=== STATE CAPTURE: $_label ==="
  if [ -f "$QGL_TARGET" ]; then
    _qgl_diag "QGL_FILE: EXISTS"
    _ctx=$(ls -Z "$QGL_TARGET" 2>/dev/null | awk '{print $1}' || echo 'unknown')
    _qgl_diag "QGL_FILE_CONTEXT: $_ctx"
    _size=$(wc -c < "$QGL_TARGET" 2>/dev/null || echo '0')
    _qgl_diag "QGL_FILE_SIZE: $_size bytes"
  else
    _qgl_diag "QGL_FILE: ABSENT"
  fi
  if [ -d "$QGL_DIR" ]; then
    _dirctx=$(ls -dZ "$QGL_DIR" 2>/dev/null | awk '{print $1}' || echo 'unknown')
    _qgl_diag "QGL_DIR_CONTEXT: $_dirctx"
  else
    _qgl_diag "QGL_DIR: ABSENT"
  fi
  _enforce=$(getenforce 2>/dev/null || echo 'unknown')
  _qgl_diag "SELINUX_MODE: $_enforce"
  _qgl_diag "=== END STATE CAPTURE ==="
}

mkdir -p /sdcard/Adreno_Driver 2>/dev/null || true

for _lf in "$LOG_FILE" "$DIAG_FILE"; do
  if [ -f "$_lf" ]; then
    _sz=$(wc -c < "$_lf" 2>/dev/null || echo '0')
    if [ "$_sz" -gt 512000 ] 2>/dev/null; then
      mv "$_lf" "${_lf}.old" 2>/dev/null || true
    fi
  fi
done

MODE=""
PKG=""
case "$1" in
  --boot)
    MODE="boot"
    ;;
  *)
    _qgl_log "[FATAL] Unknown argument: $1 (only --boot is supported)"
    exit 1
    ;;
esac

_qgl_log "[START] apply_qgl.sh MODE=$MODE"
_qgl_diag "APPLY_QGL.SH STARTED MODE=$MODE PID=$$"

_qgl_enabled="n"
_qgl_perapp="n"
for _cfg in \
    "/sdcard/Adreno_Driver/Config/adreno_config.txt" \
    "/data/local/tmp/adreno_config.txt" \
    "$MODDIR/adreno_config.txt"; do
  [ -f "$_cfg" ] || continue
  while IFS='= ' read -r _k _v; do
    case "$_k" in
      QGL) case "$_v" in [Yy]*|1) _qgl_enabled="y" ;; esac ;;
      QGL_PERAPP) case "$_v" in [Yy]*|1) _qgl_perapp="y" ;; esac ;;
    esac
  done < "$_cfg"
  [ "$_qgl_enabled" = "y" ] && break
done
unset _cfg _k _v

_qgl_log "[CFG] QGL=$_qgl_enabled QGL_PERAPP=$_qgl_perapp"

if [ "$_qgl_enabled" != "y" ]; then
  _qgl_log "[SKIP] QGL disabled in adreno_config.txt"
  exit 0
fi

_qgl_state_capture "BEFORE_OPERATIONS"

if ! mkdir -p "$QGL_DIR" 2>/dev/null; then
  _qgl_log "[FATAL] mkdir -p $QGL_DIR failed"
  exit 1
fi

chcon u:object_r:same_process_hal_file:s0 "$QGL_DIR" 2>/dev/null || true

_qsrc=""
for _dir in "$CONFIG_DIR_SD" "$CONFIG_DIR_DATA"; do
  _f="$_dir/qgl_config.txt"
  if [ -f "$_f" ] && [ -r "$_f" ]; then
    _qsrc="$_f"
    break
  fi
done

if [ -z "$_qsrc" ]; then
  for _dir in "$CONFIG_DIR_SD" "$CONFIG_DIR_DATA"; do
    _f="$_dir/qgl_config.txt"
    [ -f "$_f" ] && { _qsrc="$_f"; break; }
  done

  if [ -z "$_qsrc" ]; then
    _qgl_log "[BOOT] ERROR: No QGL config source found"
    _qgl_diag "BOOT_RESULT: FAIL - No config source"
    exit 1
  fi
fi

_qgl_log "[BOOT] Applying QGL from $_qsrc"
_qgl_diag "BOOT_SOURCE: $_qsrc"

_qtmp="${QGL_TARGET}.tmp.$$"

if ! cp -f "$_qsrc" "$_qtmp" 2>/dev/null; then
  _qgl_log "[BOOT] FAILED: cp to temp file"
  rm -f "$_qtmp" 2>/dev/null || true
  exit 1
fi

touch "$_qtmp" 2>/dev/null || true
chcon u:object_r:same_process_hal_file:s0 "$_qtmp" 2>/dev/null || true

if mv -f "$_qtmp" "$QGL_TARGET" 2>/dev/null; then
  touch "$QGL_TARGET" 2>/dev/null || true
  chcon u:object_r:same_process_hal_file:s0 "$QGL_TARGET" 2>/dev/null || true

  _lines=$(wc -l < "$QGL_TARGET" 2>/dev/null || echo '?')
  _qgl_log "[BOOT] QGL applied successfully ($_lines lines)"
  _qgl_diag "BOOT_RESULT: SUCCESS - $_lines lines from $_qsrc"
  _qgl_state_capture "AFTER_BOOT_APPLY"
else
  rm -f "$_qtmp" 2>/dev/null || true
  _qgl_log "[BOOT] FAILED to apply QGL (mv failed)"
  _qgl_diag "BOOT_RESULT: FAIL - mv failed"
  _qgl_state_capture "AFTER_BOOT_APPLY_FAILED"
  exit 1
fi

_qgl_log "[END] apply_qgl.sh completed"
exit 0
