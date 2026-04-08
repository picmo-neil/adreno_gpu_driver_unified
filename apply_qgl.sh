#!/system/bin/sh
# Adreno GPU Driver — Per-App QGL Config Applier
#
# Called by QGL Trigger APK (AccessibilityService) on every app switch.
# Also called by boot-completed.sh for the initial boot apply.
#
# USAGE:
#   apply_qgl.sh <package_name>          # Per-app mode (from APK)
#   apply_qgl.sh --boot                  # Boot mode (from boot-completed.sh)
#
# BEHAVIOR:
#   1. Reads /sdcard/Adreno_Driver/Config/qgl_profiles.json
#   2. Looks up package-specific profile, falls back to global
#   3. Writes /data/vendor/gpu/qgl_config.txt atomically
#   4. Sets SELinux context to same_process_hal_file on BOTH dir and file
#
# LYB COMPAT: Uses touch + chcon (same_process_hal_file), NO chmod, NO chown.
#   Matches LYB's r1.m6493b() exact sequence:
#     mkdir /data/vendor/gpu
#     rm /data/vendor/gpu/qgl_config.txt
#     touch /data/vendor/gpu/qgl_config.txt
#     chcon u:object_r:same_process_hal_file:s0 /data/vendor/gpu
#     chcon u:object_r:same_process_hal_file:s0 /data/vendor/gpu/qgl_config.txt
#     echo 0x0=0x8675309>> /data/vendor/gpu/qgl_config.txt
#
# LOGGING: All operations logged to /sdcard/Adreno_Driver/qgl_trigger.log
#   and /sdcard/Adreno_Driver/qgl_diagnostics.log for detailed diagnostics.

MODDIR="${0%/*}"
QGL_TARGET="/data/vendor/gpu/qgl_config.txt"
QGL_DIR="/data/vendor/gpu"
PROFILE_PATH="/sdcard/Adreno_Driver/Config/qgl_profiles.json"
LOG_FILE="/sdcard/Adreno_Driver/qgl_trigger.log"
DIAG_FILE="/sdcard/Adreno_Driver/qgl_diagnostics.log"

# ══════════════════════════════════════════════════════════════════════════
# COMPREHENSIVE QGL LOGGING SYSTEM
# ══════════════════════════════════════════════════════════════════════════

_qgl_log() {
  _ts=$(date +%H:%M:%S 2>/dev/null || echo '?')
  printf '[%s] %s\n' "$_ts" "$1" >> "$LOG_FILE" 2>/dev/null || true
  printf '[%s] %s\n' "$_ts" "$1" > /dev/kmsg 2>/dev/null || true
}

_qgl_diag() {
  _ts=$(date +%Y-%m-%d_%H:%M:%S 2>/dev/null || echo '?')
  printf '[%s] [DIAG] %s\n' "$_ts" "$1" >> "$DIAG_FILE" 2>/dev/null || true
}

_qgl_log_sep() {
  printf '%s\n' '═══════════════════════════════════════════════════════════════' >> "$LOG_FILE" 2>/dev/null || true
}

_qgl_state_capture() {
  _label="$1"
  _qgl_diag "=== STATE CAPTURE: $_label ==="
  
  # File existence and permissions
  if [ -f "$QGL_TARGET" ]; then
    _qgl_diag "QGL_FILE: EXISTS"
    _stat=$(stat "$QGL_TARGET" 2>/dev/null || echo 'stat_failed')
    _qgl_diag "QGL_FILE_STAT: $_stat"
    _ls=$(ls -laZ "$QGL_TARGET" 2>/dev/null || echo 'ls_failed')
    _qgl_diag "QGL_FILE_LS: $_ls"
    _mode=$(stat -c '%a' "$QGL_TARGET" 2>/dev/null || echo 'unknown')
    _qgl_diag "QGL_FILE_MODE: $_mode"
    _owner=$(stat -c '%U:%G' "$QGL_TARGET" 2>/dev/null || echo 'unknown')
    _qgl_diag "QGL_FILE_OWNER: $_owner"
    _ctx=$(ls -Z "$QGL_TARGET" 2>/dev/null | awk '{print $1}' || echo 'unknown')
    _qgl_diag "QGL_FILE_CONTEXT: $_ctx"
    _size=$(wc -c < "$QGL_TARGET" 2>/dev/null || echo '0')
    _qgl_diag "QGL_FILE_SIZE: $_size bytes"
    _lines=$(wc -l < "$QGL_TARGET" 2>/dev/null || echo '0')
    _qgl_diag "QGL_FILE_LINES: $_lines"
    # First 5 lines for verification
    _head=$(head -5 "$QGL_TARGET" 2>/dev/null | tr '\n' '|' || echo 'empty')
    _qgl_diag "QGL_FILE_HEAD: $_head"
  else
    _qgl_diag "QGL_FILE: ABSENT"
  fi
  
  # Directory state
  if [ -d "$QGL_DIR" ]; then
    _qgl_diag "QGL_DIR: EXISTS"
    _dirls=$(ls -laZ "$QGL_DIR" 2>/dev/null || echo 'ls_failed')
    _qgl_diag "QGL_DIR_LS: $_dirls"
    _dirctx=$(ls -dZ "$QGL_DIR" 2>/dev/null | awk '{print $1}' || echo 'unknown')
    _qgl_diag "QGL_DIR_CONTEXT: $_dirctx"
  else
    _qgl_diag "QGL_DIR: ABSENT"
  fi
  
  # SELinux enforcement status
  _enforce=$(getenforce 2>/dev/null || echo 'unknown')
  _qgl_diag "SELINUX_MODE: $_enforce"
  
  # AVC denials related to QGL (last 10)
  _avc=$(dmesg 2>/dev/null | grep -E 'avc.*qgl|avc.*same_process_hal' | tail -10 | tr '\n' '|' || echo 'none')
  _qgl_diag "QGL_AVC_DENIALS: $_avc"
  
  # Config state
  _qgl_diag "QGL_ENABLED: $_qgl_enabled"
  _qgl_diag "QGL_PERAPP: $_qgl_perapp"
  _qgl_diag "MODE: $MODE"
  _qgl_diag "PACKAGE: $PKG"
  
  _qgl_diag "=== END STATE CAPTURE ==="
}

_qgl_verify_success() {
  _qgl_diag "--- VERIFYING QGL FILE STATE ---"
  
  if [ ! -f "$QGL_TARGET" ]; then
    _qgl_diag "VERIFY: FAIL - File does not exist"
    return 1
  fi
  
  _ctx=$(ls -Z "$QGL_TARGET" 2>/dev/null | awk '{print $1}' || echo '')
  case "$_ctx" in
    *same_process_hal_file*)
      _qgl_diag "VERIFY: OK - SELinux context correct: $_ctx"
      ;;
    *)
      _qgl_diag "VERIFY: WARN - SELinux context unexpected: $_ctx"
      ;;
  esac
  
  _mode=$(stat -c '%a' "$QGL_TARGET" 2>/dev/null || echo 'unknown')
  case "$_mode" in
    644|640|600)
      _qgl_diag "VERIFY: OK - File mode: $_mode"
      ;;
    000|*)
      _qgl_diag "VERIFY: WARN - File mode unusual: $_mode"
      ;;
  esac
  
  _size=$(wc -c < "$QGL_TARGET" 2>/dev/null || echo '0')
  if [ "$_size" -gt 100 ] 2>/dev/null; then
    _qgl_diag "VERIFY: OK - File size reasonable: $_size bytes"
  else
    _qgl_diag "VERIFY: WARN - File size small: $_size bytes"
  fi
  
  return 0
}

# ══════════════════════════════════════════════════════════════════════════
# INITIALIZATION AND LOGGING
# ══════════════════════════════════════════════════════════════════════════

# Ensure log directory exists
mkdir -p /sdcard/Adreno_Driver 2>/dev/null || true

# Rotate logs if too large (>500KB)
for _lf in "$LOG_FILE" "$DIAG_FILE"; do
  if [ -f "$_lf" ]; then
    _sz=$(wc -c < "$_lf" 2>/dev/null || echo '0')
    if [ "$_sz" -gt 512000 ] 2>/dev/null; then
      mv "$_lf" "${_lf}.old" 2>/dev/null || true
    fi
  fi
done

# Parse arguments
MODE="app"
PKG=""
case "$1" in
  --boot)
    MODE="boot"
    PKG="__boot__"
    ;;
  *)
    PKG="$1"
    ;;
esac

[ -z "$PKG" ] && { _qgl_log "[FATAL] No package argument — exiting"; exit 1; }

_qgl_log_sep
_qgl_log "[START] apply_qgl.sh MODE=$MODE PKG=$PKG"
_qgl_diag "========================================"
_qgl_diag "APPLY_QGL.SH STARTED"
_qgl_diag "MODE: $MODE"
_qgl_diag "PACKAGE: $PKG"
_qgl_diag "TIME: $(date 2>/dev/null || echo 'unknown')"
_qgl_diag "PID: $$"
_qgl_diag "========================================"

# ══════════════════════════════════════════════════════════════════════════
# CHECK QGL ENABLED IN adreno_config.txt
# ══════════════════════════════════════════════════════════════════════════

_qgl_enabled="n"
_qgl_perapp="n"
for _cfg in \
    "/sdcard/Adreno_Driver/Config/adreno_config.txt" \
    "/data/local/tmp/adreno_config.txt" \
    "$MODDIR/adreno_config.txt"; do
  [ -f "$_cfg" ] || continue
  _qgl_log "[CFG] Checking $_cfg"
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
_qgl_diag "CONFIG_QGL: $_qgl_enabled"
_qgl_diag "CONFIG_QGL_PERAPP: $_qgl_perapp"

if [ "$_qgl_enabled" != "y" ]; then
  _qgl_log "[SKIP] QGL disabled in adreno_config.txt"
  _qgl_diag "EXIT: QGL disabled in config"
  exit 0
fi

# Capture initial state before any operations
_qgl_state_capture "BEFORE_OPERATIONS"

# ══════════════════════════════════════════════════════════════════════════
# ENSURE QGL DIRECTORY EXISTS WITH CORRECT SELINUX CONTEXT
# LYB: mkdir /data/vendor/gpu
# ══════════════════════════════════════════════════════════════════════════

_qgl_log "[DIR] Ensuring $QGL_DIR exists"
_qgl_diag "DIR_OP: Creating directory $QGL_DIR"

if ! mkdir -p "$QGL_DIR" 2>/dev/null; then
  _qgl_log "[FATAL] mkdir -p $QGL_DIR failed"
  _qgl_diag "DIR_OP: FAIL - mkdir failed"
  exit 1
fi
_qgl_log "[DIR] Directory created/exists"
_qgl_diag "DIR_OP: OK - mkdir succeeded"

# ══════════════════════════════════════════════════════════════════════════
# APPLY SELINUX CONTEXT TO DIRECTORY (LYB: chcon dir)
# CRITICAL: Adreno driver validates BOTH dir and file context
# ══════════════════════════════════════════════════════════════════════════

_qgl_log "[CHCON] Setting context on directory $QGL_DIR"
_qgl_diag "SELINUX_OP: chcon u:object_r:same_process_hal_file:s0 $QGL_DIR"

_chcon_out=$(chcon u:object_r:same_process_hal_file:s0 "$QGL_DIR" 2>&1)
_chcon_rc=$?

if [ $_chcon_rc -eq 0 ]; then
  _qgl_log "[CHCON] Directory context set successfully"
  _qgl_diag "SELINUX_OP: OK - chcon dir succeeded"
else
  _qgl_log "[WARN] chcon on directory failed (rc=$_chcon_rc): $_chcon_out"
  _qgl_diag "SELINUX_OP: WARN - chcon dir failed: $_chcon_out"
fi

# Verify directory context actually applied
_dir_ctx=$(ls -dZ "$QGL_DIR" 2>/dev/null | awk '{print $1}' || echo 'unknown')
_qgl_log "[CHCON] Directory context: $_dir_ctx"
_qgl_diag "SELINUX_VERIFY: Dir context is: $_dir_ctx"

case "$_dir_ctx" in
  *same_process_hal_file*)
    _qgl_log "[CHCON] Directory context VERIFIED"
    _qgl_diag "SELINUX_VERIFY: OK - Dir context correct"
    ;;
  *)
    _qgl_log "[WARN] Directory context NOT same_process_hal_file: $_dir_ctx"
    _qgl_diag "SELINUX_VERIFY: WARN - Dir context unexpected"
    ;;
esac

# ══════════════════════════════════════════════════════════════════════════
# LIGHTWEIGHT JSON KEY EXTRACTOR FOR POSIX SH
# Must be defined before boot mode block (called at boot mode line ~294)
# ══════════════════════════════════════════════════════════════════════════

_extract_section_keys() {
  _section="$1"
  _data="$2"
  
  printf '%s\n' "$_data" | awk -v section="\"$_section\"" '
    BEGIN { in_section=0; in_keys=0; brace_depth=0; enabled=1 }
    {
      line = $0
      
      if (!in_section && index(line, section ":") > 0) {
        in_section = 1
        brace_depth = 0
        enabled = 1
      }
      
      if (in_section) {
        for (i = 1; i <= length(line); i++) {
          c = substr(line, i, 1)
          if (c == "{") brace_depth++
          if (c == "}") {
            brace_depth--
            if (brace_depth == 0) {
              in_section = 0
              break
            }
          }
        }
        
        if (index(line, "\"enabled\"") > 0 && index(line, "false") > 0) {
          enabled = 0
        }
        
        if (in_keys == 0 && index(line, "\"keys\"") > 0 && index(line, "[") > 0) {
          in_keys = 1
          sub(/.*\[/, "", line)
        }
        
        if (in_keys) {
          while (1) {
            q1 = index(line, "\"")
            if (q1 == 0) break
            rest = substr(line, q1 + 1)
            q2 = 0
            for (ci = 1; ci <= length(rest); ci++) {
              ch = substr(rest, ci, 1)
              if (ch == "\\") { ci++; continue }
              if (ch == "\"") { q2 = ci; break }
            }
            if (q2 == 0) break
            val = substr(rest, 1, q2 - 1)
            gsub(/\\"/, "\"", val)
            if (index(val, "=") > 0) {
              print val
            }
            line = substr(rest, q2 + 1)
          }
          if (index(line, "]") > 0) {
            in_keys = 0
          }
        }
      }
    }
    END {
      if (enabled == 0) exit 1
    }
  '
}

# ══════════════════════════════════════════════════════════════════════════
# BOOT MODE: Use qgl_profiles.json first, fallback to legacy qgl_config.txt
# ══════════════════════════════════════════════════════════════════════════

if [ "$MODE" = "boot" ]; then
  _qgl_log "[BOOT] Starting boot mode QGL apply"
  _qgl_diag "BOOT_MODE: Starting"
  
  _qsrc=""
  _qtmp="${QGL_TARGET}.tmp.$$"
  _qtmp2="${QGL_TARGET}.tmp2.$$"
  
  # Priority 1: qgl_profiles.json (unified single source)
  if [ -f "$PROFILE_PATH" ]; then
    _qgl_log "[BOOT] Found qgl_profiles.json"
    _json=$(cat "$PROFILE_PATH" 2>/dev/null)
    if [ -n "$_json" ]; then
      _keys=$(_extract_section_keys "global" "$_json" 2>/dev/null)
      if [ -n "$_keys" ]; then
        _qgl_log "[BOOT] Using qgl_profiles.json as unified config source"
        _qgl_diag "BOOT_SOURCE: qgl_profiles.json"
        _qgl_diag "BOOT_KEYS_COUNT: $(printf '%s\n' "$_keys" | wc -l 2>/dev/null || echo '?')"
        
        # Build qgl_config.txt content from JSON keys
        _has_magic="n"
        _first_line=$(printf '%s\n' "$_keys" | head -1)
        case "$_first_line" in "0x0=0x8675309") _has_magic="y" ;; esac
        
        {
          if [ "$_has_magic" != "y" ]; then
            printf '0x0=0x8675309\n'
          fi
          printf '%s\n' "$_keys"
        } > "$_qtmp" 2>/dev/null
        
        if [ -s "$_qtmp" ]; then
          _qgl_log "[BOOT] Temp file written, committing..."
          _qgl_diag "FILE_OP: Temp file size: $(wc -c < "$_qtmp" 2>/dev/null || echo '?') bytes"
          
          # REMOVE old file first (LYB: rm /data/vendor/gpu/qgl_config.txt)
          _qgl_log "[BOOT] Removing old QGL file"
          rm -f "$QGL_TARGET" 2>/dev/null || true
          
          # Atomic rename (touch then mv - matches LYB approach)
          if mv -f "$_qtmp" "$QGL_TARGET" 2>/dev/null; then
            _qgl_log "[BOOT] File renamed successfully"
            _qgl_diag "FILE_OP: mv succeeded"
            
            # Touch to ensure file has proper timestamp (LYB: touch)
            touch "$QGL_TARGET" 2>/dev/null || true
            
            # Set SELinux context (LYB: chcon file)
            _qgl_log "[BOOT] Setting SELinux context on file"
            _chcon_file_out=$(chcon u:object_r:same_process_hal_file:s0 "$QGL_TARGET" 2>&1)
            _chcon_file_rc=$?
            
            if [ $_chcon_file_rc -eq 0 ]; then
              _qgl_log "[BOOT] File SELinux context set"
              _qgl_diag "SELINUX_OP: chcon file succeeded"
            else
              _qgl_log "[WARN] chcon file failed: $_chcon_file_out"
              _qgl_diag "SELINUX_OP: chcon file failed: $_chcon_file_out"
            fi
            
            _lines=$(wc -l < "$QGL_TARGET" 2>/dev/null || echo '?')
            _qgl_log "[BOOT] QGL applied from qgl_profiles.json ($_lines lines)"
            _qgl_diag "BOOT_RESULT: SUCCESS - $_lines lines written"
            
            # Verify final state
            _qgl_verify_success
            _qgl_state_capture "AFTER_BOOT_APPLY_JSON"
            exit 0
          else
            _qgl_log "[BOOT] mv failed"
            _qgl_diag "FILE_OP: mv failed"
          fi
          rm -f "$_qtmp" 2>/dev/null || true
        fi
      fi
    fi
  fi
  
  # Priority 2: Legacy qgl_config.txt sources
  for _q in \
      "/sdcard/Adreno_Driver/Config/qgl_config.txt" \
      "/sdcard/Adreno_Driver/qgl_config.txt" \
      "/data/local/tmp/qgl_config.txt" \
      "$MODDIR/qgl_config.txt"; do
    [ -f "$_q" ] && { _qsrc="$_q"; break; }
  done

  if [ -z "$_qsrc" ]; then
    _qgl_log "[BOOT] ERROR: No QGL config source found"
    _qgl_log "[BOOT] Tried: qgl_profiles.json, then qgl_config.txt sources"
    _qgl_diag "BOOT_RESULT: FAIL - No config source"
    exit 1
  fi

  _qgl_log "[BOOT] Applying QGL from $_qsrc"
  _qgl_diag "BOOT_SOURCE: $_qsrc (legacy)"
  _qgl_diag "BOOT_SOURCE_SIZE: $(wc -c < "$_qsrc" 2>/dev/null || echo '?') bytes"
  
  # REMOVE old file (LYB: rm)
  _qgl_log "[BOOT] Removing old QGL file"
  rm -f "$QGL_TARGET" 2>/dev/null || true
  
  # Copy to temp (prepare for atomic commit)
  _qgl_log "[BOOT] Copying to temp file"
  if ! cp -f "$_qsrc" "$_qtmp" 2>/dev/null; then
    _qgl_log "[BOOT] FAILED: cp to temp file"
    _qgl_diag "FILE_OP: cp failed"
    rm -f "$_qtmp" 2>/dev/null || true
    exit 1
  fi
  _qgl_diag "FILE_OP: cp succeeded, temp size: $(wc -c < "$_qtmp" 2>/dev/null || echo '?') bytes"
  
  # Touch (LYB: touch) - ensures file timestamp
  touch "$_qtmp" 2>/dev/null || true
  
  # Atomic commit (mv)
  if mv -f "$_qtmp" "$QGL_TARGET" 2>/dev/null; then
    _qgl_log "[BOOT] Atomic rename succeeded"
    _qgl_diag "FILE_OP: mv succeeded"
    
    # Touch again on final location (matches LYB)
    touch "$QGL_TARGET" 2>/dev/null || true
    
    # Set SELinux context (LYB: chcon file)
    _qgl_log "[BOOT] Setting SELinux context on file (legacy path)"
    _chcon_leg_out=$(chcon u:object_r:same_process_hal_file:s0 "$QGL_TARGET" 2>&1)
    _chcon_leg_rc=$?
    if [ $_chcon_leg_rc -eq 0 ]; then
      _qgl_log "[BOOT] File SELinux context set (legacy path)"
      _qgl_diag "SELINUX_OP: chcon file succeeded (legacy)"
    else
      _qgl_log "[WARN] chcon file failed (legacy path, rc=$_chcon_leg_rc): $_chcon_leg_out"
      _qgl_diag "SELINUX_OP: chcon file failed (legacy): $_chcon_leg_out"
    fi
    unset _chcon_leg_out _chcon_leg_rc
    
    _lines=$(wc -l < "$QGL_TARGET" 2>/dev/null || echo '?')
    _qgl_log "[BOOT] QGL applied successfully ($_lines lines)"
    _qgl_diag "BOOT_RESULT: SUCCESS - $_lines lines from $_qsrc"
    
    _qgl_verify_success
    _qgl_state_capture "AFTER_BOOT_APPLY_LEGACY"
  else
    rm -f "$_qtmp" 2>/dev/null || true
    _qgl_log "[BOOT] FAILED to apply QGL (mv failed)"
    _qgl_diag "BOOT_RESULT: FAIL - mv failed"
    _qgl_state_capture "AFTER_BOOT_APPLY_FAILED"
    exit 1
  fi
  
  rm -f "$_qtmp2" 2>/dev/null || true
  exit 0
fi

# ══════════════════════════════════════════════════════════════════════════
# APP MODE: Per-app profile lookup from qgl_profiles.json
# ══════════════════════════════════════════════════════════════════════════

_qgl_log "[APP] Starting per-app mode for $PKG"
_qgl_diag "APP_MODE: Starting for $PKG"

if [ ! -f "$PROFILE_PATH" ]; then
  _qgl_log "[APP] No qgl_profiles.json at $PROFILE_PATH"
  _qgl_diag "APP_RESULT: SKIP - No profiles file"
  exit 0
fi
      

extract_keys() {
  _pkg="$1"
  _json="$2"
  
  _keys=$(_extract_section_keys "$_pkg" "$_json" 2>/dev/null)
  if [ -n "$_keys" ]; then
    printf '%s\n' "$_keys"
    return 0
  fi
  
  _keys=$(_extract_section_keys "global" "$_json" 2>/dev/null)
  if [ -n "$_keys" ]; then
    printf '%s\n' "$_keys"
    return 0
  fi
  
  return 1
}

# Read profile JSON
_json=""
if [ -f "$PROFILE_PATH" ]; then
  _json=$(cat "$PROFILE_PATH" 2>/dev/null) || true
fi

if [ -z "$_json" ]; then
  _qgl_log "[APP] Failed to read qgl_profiles.json"
  _qgl_diag "APP_RESULT: FAIL - Cannot read profiles"
  exit 0
fi

_qgl_log "[APP] qgl_profiles.json loaded ($(printf '%s' "$_json" | wc -c | tr -d ' ') bytes)"
_qgl_diag "APP_PROFILES_LOADED: OK"

# Extract keys for this package
_keys=$(extract_keys "$PKG" "$_json")
if [ -z "$_keys" ]; then
  _qgl_log "[APP] No profile for $PKG (no app-specific or global keys found)"
  _qgl_diag "APP_RESULT: SKIP - No profile for $PKG"
  exit 0
fi

_key_count=$(printf '%s\n' "$_keys" | wc -l 2>/dev/null || echo '?')
_qgl_log "[APP] Found $_key_count keys for $PKG"
_qgl_diag "APP_KEYS_FOUND: $_key_count"

# Build qgl_config.txt content
_has_magic="n"
_first_line=$(printf '%s\n' "$_keys" | head -1)
case "$_first_line" in
  "0x0=0x8675309") _has_magic="y" ;;
esac

_qtmp="${QGL_TARGET}.tmp.$$"

{
  if [ "$_has_magic" != "y" ]; then
    printf '0x0=0x8675309\n'
  fi
  printf '%s\n' "$_keys"
} > "$_qtmp" 2>/dev/null

if [ ! -s "$_qtmp" ]; then
  _qgl_log "[APP] Failed to write temp file for $PKG"
  _qgl_diag "APP_RESULT: FAIL - Cannot write temp"
  rm -f "$_qtmp" 2>/dev/null
  exit 1
fi

_qgl_diag "FILE_OP: Temp file written: $(wc -c < "$_qtmp" 2>/dev/null || echo '?') bytes"

# REMOVE old file (LYB: rm)
_qgl_log "[APP] Removing old QGL file"
rm -f "$QGL_TARGET" 2>/dev/null || true

# Atomic commit (LYB: mv via touch + chcon approach)
_qgl_log "[APP] Committing $_qtmp → $QGL_TARGET"
if mv -f "$_qtmp" "$QGL_TARGET" 2>/dev/null; then
  # Touch (LYB: touch)
  touch "$QGL_TARGET" 2>/dev/null || true
  
  # Set SELinux context (LYB: chcon file)
  _qgl_log "[APP] Setting SELinux context"
  _chcon_app_out=$(chcon u:object_r:same_process_hal_file:s0 "$QGL_TARGET" 2>&1)
  _chcon_app_rc=$?
  if [ $_chcon_app_rc -eq 0 ]; then
    _qgl_log "[APP] File SELinux context set"
    _qgl_diag "SELINUX_OP: chcon file succeeded (app mode)"
  else
    _qgl_log "[WARN] chcon file failed for $PKG (rc=$_chcon_app_rc): $_chcon_app_out"
    _qgl_diag "SELINUX_OP: chcon file failed (app mode): $_chcon_app_out"
  fi
  unset _chcon_app_out _chcon_app_rc
  
  _line_count=$(wc -l < "$QGL_TARGET" 2>/dev/null || echo '?')
  _qgl_log "[APP] QGL applied for $PKG ($_line_count keys)"
  _qgl_diag "APP_RESULT: SUCCESS - $_line_count keys for $PKG"
  
  _qgl_verify_success
  _qgl_state_capture "AFTER_APP_APPLY"
else
  rm -f "$_qtmp" 2>/dev/null || true
  _qgl_log "[APP] FAILED to commit QGL for $PKG (mv failed)"
  _qgl_diag "APP_RESULT: FAIL - mv failed"
  _qgl_state_capture "AFTER_APP_APPLY_FAILED"
  exit 1
fi

_qgl_log "[END] apply_qgl.sh completed"
_qgl_diag "========================================"
_qgl_diag "APPLY_QGL.SH COMPLETED"
_qgl_diag "========================================"
exit 0