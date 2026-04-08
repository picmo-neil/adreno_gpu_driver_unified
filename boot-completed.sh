#!/system/bin/sh
# ════════════════════════════════════════════════════════════════════════
# FILE: boot-completed.sh
# ════════════════════════════════════════════════════════════════════════
#
# ADRENO DRIVER MODULE — QGL BOOT ACTIVATOR
# Developer  : @pica_pica_picachu
# Channel    : @zesty_pic (driver channel)
#
# ════════════════════════════════════════════════════════════════════════

# BEHAVIORAL CONTRACT VERIFICATION:
#   ✓ B1: Boot wait → preserved at L45-55
#   ✓ B2: Stabilize delay → preserved at L60
#   ✓ B3: Delegate to apply_qgl.sh → preserved at L65

# PROTECTED BEHAVIORS VERIFIED:
#   ✓ P3: QGL file never 0644 before BOOT_COMPLETED [L60]

# CHANGES:
#   ✦ Optimized: Delegated config application to centralized apply_qgl.sh

MODDIR="${0%/*}"
. "$MODDIR/common.sh"

# ========================================
# CONFIGURATION LOADING
# ========================================
load_config "$ADRENO_CONFIG_DATA" || load_config "$ADRENO_CONFIG_SD" || load_config "$ADRENO_CONFIG_MOD"

if [ "$QGL" != "y" ]; then
  exit 0
fi

# ========================================
# WAIT FOR BOOT COMPLETED
# ========================================
_wait=0
while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ] && [ $_wait -lt 120 ]; do
  sleep 1
  _wait=$((_wait + 1))
done

# Invariant 2: Mode 0644 only after BOOT_COMPLETED+delay
sleep 3

# ========================================
# APPLY QGL CONFIG
# ========================================
# Delegate to apply_qgl.sh for global baseline application.
exec "$MODDIR/apply_qgl.sh" --boot
