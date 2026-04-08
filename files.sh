#!/system/bin/sh
# ========================================
# Permissions Script - Recovery Mode
# Called from update-binary after file copy
# ========================================
# NOTE: This script runs in recovery context where /system and /vendor
# are the recovery-mounted partitions, NOT the live system. Operations
# here only affect the module files being installed, not the running OS.

# ── Module paths (recovery-mounted) ──────────────────────────────────
# In recovery, $MODPATH points to the staged module directory.
# All chmod/chcon operations target module files only.

_module_lib="$MODPATH/system/vendor/lib"
_module_lib64="$MODPATH/system/vendor/lib64"
_module_fw="$MODPATH/system/vendor/firmware"
_module_etc="$MODPATH/system/vendor/etc"

# ── Library permissions (module files only) ─────────────────────────
# Recovery already sets reasonable defaults; these are explicit guards.
if [ -d "$_module_lib64" ]; then
  find "$_module_lib64" -name '*.so' -exec chmod 644 {} + 2>/dev/null || true
fi
if [ -d "$_module_lib" ]; then
  find "$_module_lib" -name '*.so' -exec chmod 644 {} + 2>/dev/null || true
fi

# ── Firmware permissions (module files only) ────────────────────────
if [ -d "$_module_fw" ]; then
  find "$_module_fw" \( -name '*.fw' -o -name '*.bin' -o -name '*.mbn' \) \
    -exec chmod 644 {} + 2>/dev/null || true
fi

# ── Config permissions (module files only) ──────────────────────────
if [ -d "$_module_etc" ]; then
  find "$_module_etc" \( -name '*.txt' -o -name '*.xml' \) \
    -exec chmod 644 {} + 2>/dev/null || true
fi

# ── SELinux contexts for driver libraries ───────────────────────────
# (recovery restores automatically on next boot via restorecon,
#  but setting them now avoids first-boot denial errors)
if command -v chcon >/dev/null 2>&1; then
  if [ -d "$_module_lib64/egl" ]; then
    chcon -R u:object_r:same_process_hal_file:s0 "$_module_lib64/egl" 2>/dev/null || true
  fi
  if [ -d "$_module_lib/egl" ]; then
    chcon -R u:object_r:same_process_hal_file:s0 "$_module_lib/egl" 2>/dev/null || true
  fi
  if [ -d "$_module_lib64/hw" ]; then
    chcon -R u:object_r:same_process_hal_file:s0 "$_module_lib64/hw" 2>/dev/null || true
  fi
  if [ -d "$_module_lib/hw" ]; then
    chcon -R u:object_r:same_process_hal_file:s0 "$_module_lib/hw" 2>/dev/null || true
  fi
  if [ -d "$_module_fw" ]; then
    chcon -R u:object_r:vendor_firmware_file:s0 "$_module_fw" 2>/dev/null || true
  fi
fi

# ── Cleanup ─────────────────────────────────────────────────────────
unset _module_lib _module_lib64 _module_fw _module_etc

exit 0
