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
#   4. Sets SELinux context to same_process_hal_file
#
# ATOMIC WRITE: printf > tmp && mv tmp target
#   The mv syscall is atomic on ext4/f2fs. The GPU driver either sees
#   the complete new file or the old file — never a partial write.
#   This eliminates the "empty file window" that causes app crashes.
#
# LYB COMPAT: Uses same_process_hal_file context, no chmod, no chown.

MODDIR="${0%/*}"
QGL_TARGET="/data/vendor/gpu/qgl_config.txt"
QGL_DIR="/data/vendor/gpu"
PROFILE_PATH="/sdcard/Adreno_Driver/Config/qgl_profiles.json"
LOG_TAG="AdrenoQGL"

# ── Logging ──────────────────────────────────────────────────────────────
log_qgl() {
  printf '[%s] %s\n' "$(date +%H:%M:%S)" "$1" >> /dev/kmsg 2>/dev/null || true
  printf '[%s] %s\n' "$(date +%H:%M:%S)" "$1" >> /sdcard/Adreno_Driver/qgl_trigger.log 2>/dev/null || true
}

# ── Parse arguments ──────────────────────────────────────────────────────
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

[ -z "$PKG" ] && exit 1

# ── Check QGL enabled in adreno_config.txt ───────────────────────────────
_qgl_enabled="n"
for _cfg in \
    "/sdcard/Adreno_Driver/Config/adreno_config.txt" \
    "/data/local/tmp/adreno_config.txt" \
    "$MODDIR/adreno_config.txt"; do
  [ -f "$_cfg" ] || continue
  while IFS='= ' read -r _k _v; do
    case "$_k" in
      QGL) case "$_v" in [Yy]*|1) _qgl_enabled="y" ;; esac ;;
    esac
  done < "$_cfg"
  [ "$_qgl_enabled" = "y" ] && break
done
unset _cfg _k _v

if [ "$_qgl_enabled" != "y" ]; then
  log_qgl "[SKIP] QGL disabled in adreno_config.txt"
  exit 0
fi

# ── Ensure QGL directory exists ──────────────────────────────────────────
mkdir -p "$QGL_DIR" 2>/dev/null

# ══════════════════════════════════════════════════════════════════════════
# BOOT MODE: Use bundled qgl_config.txt (legacy compatibility)
# ══════════════════════════════════════════════════════════════════════════
if [ "$MODE" = "boot" ]; then
  _qsrc=""
  for _q in \
      "/sdcard/Adreno_Driver/Config/qgl_config.txt" \
      "/data/local/tmp/qgl_config.txt" \
      "$MODDIR/qgl_config.txt"; do
    [ -f "$_q" ] && { _qsrc="$_q"; break; }
  done

  if [ -z "$_qsrc" ]; then
    log_qgl "[BOOT] No qgl_config.txt source found, skipping"
    exit 0
  fi

  log_qgl "[BOOT] Applying QGL from $_qsrc"

  _qtmp="${QGL_TARGET}.tmp.$$"
  _qtmp2="${QGL_TARGET}.tmp2.$$"
  if cp -f "$_qsrc" "$_qtmp" 2>/dev/null && mv -f "$_qtmp" "$QGL_TARGET" 2>/dev/null; then
    chcon u:object_r:same_process_hal_file:s0 "$QGL_DIR" 2>/dev/null || true
    chcon u:object_r:same_process_hal_file:s0 "$QGL_TARGET" 2>/dev/null || true
    log_qgl "[BOOT] QGL applied successfully ($(wc -l < "$_qsrc" 2>/dev/null || echo '?') lines)"
  else
    rm -f "$_qtmp" 2>/dev/null || true
    if cp -f "$_qsrc" "$_qtmp2" 2>/dev/null && mv -f "$_qtmp2" "$QGL_TARGET" 2>/dev/null; then
      chcon u:object_r:same_process_hal_file:s0 "$QGL_DIR" 2>/dev/null || true
      chcon u:object_r:same_process_hal_file:s0 "$QGL_TARGET" 2>/dev/null || true
      log_qgl "[BOOT] QGL applied (fallback atomic path)"
    else
      rm -f "$_qtmp2" 2>/dev/null || true
      log_qgl "[BOOT] FAILED to apply QGL"
      exit 1
    fi
  fi
  rm -f "$_qtmp2" 2>/dev/null || true
  exit 0
fi

# ══════════════════════════════════════════════════════════════════════════
# APP MODE: Per-app profile lookup from qgl_profiles.json
# ══════════════════════════════════════════════════════════════════════════

# ── Check profile file exists ────────────────────────────────────────────
if [ ! -f "$PROFILE_PATH" ]; then
  log_qgl "[APP] No qgl_profiles.json at $PROFILE_PATH"
  exit 0
fi

# ── Lightweight JSON key extractor for POSIX sh ──────────────────────────
# Extracts "keys" array for a given package or "global" section.
# Uses awk — single fork, no jq dependency, no gawk features.
#
# Output: one key per line, or empty if not found.
#
# JSON format expected:
# {
#   "global": { "keys": ["0x0=0x8675309", "0x1=0x2"], "enabled": true },
#   "apps": {
#     "com.example.game": { "keys": ["0x0=0x8675309"], "enabled": true }
#   }
# }

_extract_section_keys() {
  _section="$1"
  _data="$2"

  # Find the section, check enabled, extract keys.
  # Pure POSIX awk — no gawk extensions (no 3-arg match, no gensub).
  printf '%s\n' "$_data" | awk -v section="\"$_section\"" '
    BEGIN { in_section=0; in_keys=0; brace_depth=0; enabled=1 }
    {
      line = $0

      # Look for section start: "section_name": {
      if (!in_section && index(line, section ":") > 0) {
        in_section = 1
        brace_depth = 0
        enabled = 1
      }

      if (in_section) {
        # Count braces to track nesting
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

        # Check enabled field — POSIX-compatible (no 3-arg match)
        if (index(line, "\"enabled\"") > 0 && index(line, "false") > 0) {
          enabled = 0
        }

        # Extract keys array
        if (in_keys == 0 && index(line, "\"keys\"") > 0 && index(line, "[") > 0) {
          in_keys = 1
          # Remove everything up to and including the first [
          sub(/.*\[/, "", line)
        }

        if (in_keys) {
          # Extract quoted strings one at a time
          while (1) {
            # Find first quote
            q1 = index(line, "\"")
            if (q1 == 0) break
            rest = substr(line, q1 + 1)
            # Find closing quote, skipping escaped quotes (\" → literal quote in value)
            q2 = 0
            for (ci = 1; ci <= length(rest); ci++) {
              ch = substr(rest, ci, 1)
              if (ch == "\\") { ci++; continue }
              if (ch == "\"") { q2 = ci; break }
            }
            if (q2 == 0) break
            val = substr(rest, 1, q2 - 1)
            # Unescape any \" sequences in the value
            gsub(/\\"/, "\"", val)
            # Skip "keys" and "enabled" — only output actual key=value pairs
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

extract_keys() {
  _pkg="$1"
  _json="$2"

  # Try app-specific first
  _keys=$(_extract_section_keys "$_pkg" "$_json" 2>/dev/null)
  if [ -n "$_keys" ]; then
    printf '%s\n' "$_keys"
    return 0
  fi

  # Fall back to global
  _keys=$(_extract_section_keys "global" "$_json" 2>/dev/null)
  if [ -n "$_keys" ]; then
    printf '%s\n' "$_keys"
    return 0
  fi

  return 1
}

# ── Read profile JSON ────────────────────────────────────────────────────
_json=""
if [ -f "$PROFILE_PATH" ]; then
  _json=$(cat "$PROFILE_PATH" 2>/dev/null) || true
fi
if [ -z "$_json" ]; then
  log_qgl "[APP] Failed to read qgl_profiles.json"
  exit 0
fi

# ── Extract keys for this package ────────────────────────────────────────
_keys=$(extract_keys "$PKG" "$_json")
if [ -z "$_keys" ]; then
  log_qgl "[APP] No profile for $PKG (no app-specific or global keys)"
  exit 0
fi

# ── Build qgl_config.txt content ─────────────────────────────────────────
# The first line MUST be 0x0=0x8675309 (magic header for SDM845+ hash support).
# If the user's profile already includes it, don't duplicate.

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
  log_qgl "[APP] Failed to write temp file for $PKG"
  rm -f "$_qtmp" 2>/dev/null
  exit 1
fi

# ── Atomic commit: mv is atomic on ext4/f2fs ─────────────────────────────
if mv -f "$_qtmp" "$QGL_TARGET" 2>/dev/null; then
  chcon u:object_r:same_process_hal_file:s0 "$QGL_DIR" 2>/dev/null || true
  chcon u:object_r:same_process_hal_file:s0 "$QGL_TARGET" 2>/dev/null || true
  _line_count=$(wc -l < "$QGL_TARGET" 2>/dev/null || echo '?')
  log_qgl "[APP] QGL applied for $PKG ($_line_count keys)"
else
  rm -f "$_qtmp" 2>/dev/null || true
  log_qgl "[APP] FAILED to commit QGL for $PKG (mv failed)"
  exit 1
fi

exit 0
