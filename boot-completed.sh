#!/system/bin/sh
# Adreno GPU Driver — QGL Config Activator (Boot Phase)
#
# TWO-PHASE QGL STRATEGY:
#   Phase 1 (post-fs-data.sh): REMOVE stale QGL before Zygote forks.
#     Prevents GPU driver from reading QGL during init (causes bootloop).
#   Phase 2 (this script): RE-APPLY QGL after system is stable.
#     Delegates to apply_qgl.sh --boot for the actual write.
#
# PER-APP QGL: After boot, the QGL Trigger APK (AccessibilityService)
#   handles per-app QGL application. When any app opens, the APK calls
#   apply_qgl.sh <package_name> which writes the app-specific profile.
#   This matches LYB Kernel Manager's exact behavior.
#
# TIMING: Wait for boot_completed + launcher PID + 3s safety → apply global.
#   The APK then overrides with per-app configs as apps are opened.

MODDIR="${0%/*}"

# ── Load config ──────────────────────────────────────────────────────────
QGL="n"
for _cfg in \
    "/sdcard/Adreno_Driver/Config/adreno_config.txt" \
    "/data/local/tmp/adreno_config.txt" \
    "$MODDIR/adreno_config.txt"; do
  [ -f "$_cfg" ] || continue
  while IFS='= ' read -r _k _v; do
    case "$_k" in
      QGL) case "$_v" in [Yy]*|1) QGL="y" ;; esac ;;
    esac
  done < "$_cfg"
  [ "$QGL" = "y" ] && break
done
unset _cfg _k _v
[ "$QGL" = "y" ] || exit 0

# ══════════════════════════════════════════════════════════════════════════
# STEP 1: WAIT FOR BOOT COMPLETED
# ══════════════════════════════════════════════════════════════════════════

_boot_wait=0
while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ] && [ $_boot_wait -lt 120 ]; do
  sleep 1
  _boot_wait=$((_boot_wait + 1))
done
unset _boot_wait
[ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ] && exit 0

# ══════════════════════════════════════════════════════════════════════════
# STEP 2: WAIT FOR LAUNCHER PID
# ══════════════════════════════════════════════════════════════════════════

_lp=0
while [ $_lp -lt 60 ]; do
  for _pkg in $_LAUNCHER_PKGS; do
    if pidof "$_pkg" >/dev/null 2>&1; then
      _lp=999
      break 2
    fi
  done
  sleep 1
  _lp=$((_lp + 1))
done
unset _lp _pkg

# ══════════════════════════════════════════════════════════════════════════
# STEP 3: SAFETY MARGIN (Vulkan pipeline settle)
# ══════════════════════════════════════════════════════════════════════════
sleep 3

# ══════════════════════════════════════════════════════════════════════════
# STEP 4: APPLY QGL (delegated to apply_qgl.sh)
# ══════════════════════════════════════════════════════════════════════════
# apply_qgl.sh --boot reads the bundled qgl_config.txt and writes it
# atomically with correct SELinux context.
#
# After boot, the QGL Trigger APK handles per-app overrides via:
#   apply_qgl.sh <package_name>
#   → reads qgl_profiles.json → writes app-specific config atomically

exec "$MODDIR/apply_qgl.sh" --boot
