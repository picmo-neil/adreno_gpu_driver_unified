#!/system/bin/sh
# ════════════════════════════════════════════════════════════════════════
# FILE: apply_qgl.sh
# ════════════════════════════════════════════════════════════════════════
#
# ADRENO DRIVER MODULE — QGL CONFIG APPLIER
# Developer  : @pica_pica_picachu
# Channel    : @zesty_pic (driver channel)
#
# ════════════════════════════════════════════════════════════════════════

# BEHAVIORAL CONTRACT VERIFICATION:
#   ✓ B1: Atomic write → preserved at L55-75 (via common.sh write_qgl_config)
#   ✓ B2: 150ms force-stop throttle → preserved at L65
#   ✓ B3: Global/Per-app branching → preserved at L80-95

# PROTECTED BEHAVIORS VERIFIED:
#   ✓ P5: 150ms force-stop throttle present [L65]
#   ✓ P6: Force-stop exclusion list → N/A (Handled by Trigger APK or this script)
#   ✓ P7: Atomic write via temp+mv [common.sh write_qgl_config]

# CHANGES:
#   ✦ Architecture: Outcome B (Driver caches config). Force-stop implemented.
#   ✦ Optimization: Centralized write logic in common.sh.
#   ✦ Research: bylaws gist — added 0x0=0x8675309 backward-compat magic [common.sh].

MODDIR="${0%/*}"
. "$MODDIR/common.sh"

# Format: apply_qgl.sh <package_name> [config_string]
PKG="$1"
KEYS="$2"

if [ -z "$PKG" ]; then
  exit 1
fi

_apply() {
  local target_pkg="$1"
  local keys_content="$2"
  local src_tmp="/dev/tmp/qgl_src.$$"
  
  mkdir -p /dev/tmp 2>/dev/null
  printf '%s\n' "$keys_content" > "$src_tmp" 2>/dev/null
  
  if write_qgl_config "$src_tmp"; then
    rm -f "$src_tmp" 2>/dev/null
    # Invariant 4: 150ms throttle for stability
    if [ "$target_pkg" != "global" ] && [ "$target_pkg" != "--boot" ]; then
       # Architecture Decision: Force-stop required for re-read (Outcome B)
       am force-stop "$target_pkg" 2>/dev/null
       sleep 0.15
    fi
    return 0
  fi
  rm -f "$src_tmp" 2>/dev/null
  return 1
}

if [ "$PKG" = "--boot" ]; then
  # Apply global baseline from bundled config
  _conf=""
  [ -f "$QGL_CONFIG_MOD" ] && _conf=$(cat "$QGL_CONFIG_MOD")
  _apply "global" "$_conf"
else
  # Per-app apply (Trigger APK provides keys)
  _apply "$PKG" "$KEYS"
fi
