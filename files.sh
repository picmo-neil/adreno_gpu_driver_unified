#!/system/bin/sh
# ========================================
# Permissions Script - Recovery Mode
# Called from update-binary after file copy
# ========================================

# Firmware
chmod 644 /vendor/firmware/*.fw 2>/dev/null
chmod 644 /vendor/firmware/*.bin 2>/dev/null
chmod 644 /vendor/firmware/*.mbn 2>/dev/null

# Configs
chmod 644 /vendor/etc/*.txt 2>/dev/null
chmod 644 /vendor/etc/*.xml 2>/dev/null
chmod 644 /vendor/etc/permissions/*.xml 2>/dev/null

# Libraries 32-bit
chmod 644 /vendor/lib/*.so 2>/dev/null
chmod 644 /vendor/lib/egl/*.so 2>/dev/null
chmod 644 /vendor/lib/hw/*.so 2>/dev/null

# Libraries 64-bit
chmod 644 /vendor/lib64/*.so 2>/dev/null
chmod 644 /vendor/lib64/egl/*.so 2>/dev/null
chmod 644 /vendor/lib64/hw/*.so 2>/dev/null

# System libs (if present)
chmod 644 /system/lib/*.so 2>/dev/null
chmod 644 /system/lib64/*.so 2>/dev/null
chmod 644 /system_root/system/lib/*.so 2>/dev/null
chmod 644 /system_root/system/lib64/*.so 2>/dev/null

# SELinux contexts for driver libraries
# (recovery restores automatically on next boot via restorecon,
#  but setting them now avoids first-boot denial errors)
if command -v chcon >/dev/null 2>&1; then
  chcon -R u:object_r:same_process_hal_file:s0 /vendor/lib/egl   2>/dev/null || true
  chcon -R u:object_r:same_process_hal_file:s0 /vendor/lib64/egl 2>/dev/null || true
  chcon -R u:object_r:same_process_hal_file:s0 /vendor/lib/hw    2>/dev/null || true
  chcon -R u:object_r:same_process_hal_file:s0 /vendor/lib64/hw  2>/dev/null || true
  chcon -R u:object_r:vendor_firmware_file:s0   /vendor/firmware  2>/dev/null || true
fi

exit 0
