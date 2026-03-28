#!/system/bin/sh
# ============================================================
# ADRENO DRIVER MODULE — UNINSTALL SCRIPT
# ============================================================
#
# Developer  : @pica_pica_picachu
# Channel    : @zesty_pic (driver channel)
#
# ⚠️  ANTI-THEFT NOTICE ⚠️
# This module was developed by @pica_pica_picachu.
# If someone claims this as their own work and asks for
# donations — report them immediately to @zesty_pic.
#
# ============================================================

echo "========================================"
echo "Adreno GPU Driver Uninstaller"
echo "========================================"
echo ""
echo "Cleaning GPU caches..."

# Function to clean caches safely
clean_caches() {
  # User DE caches
  find /data/user_de -type d \( \
    -iname '*shader*' -o \
    -iname '*gpucache*' -o \
    -iname '*graphitecache*' -o \
    -iname '*pipeline*' \
  \) -exec rm -rf {} + 2>/dev/null || true

  find /data/user_de -type f \( \
    -iname '*shader*' -o \
    -iname '*gpu*cache*' \
  \) -exec rm -f {} + 2>/dev/null || true

  # App data caches
  find /data/data -type d \( \
    -iname '*shader*' -o \
    -iname '*gpucache*' -o \
    -iname '*graphitecache*' -o \
    -iname '*pipeline*' -o \
    -iname '*program*cache*' \
  \) -exec rm -rf {} + 2>/dev/null || true

  find /data/data -type f \( \
    -iname '*shader*' -o \
    -iname '*gpu*cache*' \
  \) -exec rm -f {} + 2>/dev/null || true

  # Data mirror caches (data_ce = Credential Encrypted, data_de = Device Encrypted)
  for mirror in /data_mirror/data_ce /data_mirror/data_de; do
    if [ -d "$mirror" ]; then
      find "$mirror" -type d \( \
        -iname '*shader*' -o \
        -iname '*gpucache*' -o \
        -iname '*graphitecache*' -o \
        -iname '*pipeline*' \
      \) -exec rm -rf {} + 2>/dev/null || true

      find "$mirror" -type f \( \
        -iname '*shader*' -o \
        -iname '*gpu*cache*' \
      \) -exec rm -f {} + 2>/dev/null || true
    fi
  done

  # User-specific caches
  find /data/user -type d \( \
    -iname '*shader*' -o \
    -iname '*gpucache*' -o \
    -iname '*code_cache*' \
  \) -exec rm -rf {} + 2>/dev/null || true

  # Camera app caches — match the cache/code_cache subdirectory inside any camera package dir
  # The old -iname + -path combo on the same node never matched anything because a dir
  # named "*camera*" can't also have a path ending in "/cache". Use -path on the full path.
  find /data/data -maxdepth 3 -type d \( \
    -path '*camera*/cache'      -o -path '*camera*/code_cache'   -o \
    -path '*snapcam*/cache'     -o -path '*snapcam*/code_cache'  -o \
    -path '*gcam*/cache'        -o -path '*gcam*/code_cache' \
  \) -exec rm -rf {} + 2>/dev/null || true

  # System caches (GPU-specific only)
  rm -rf /data/system/graphicsstats/* 2>/dev/null || true
  rm -rf /data/system/package_cache/* 2>/dev/null || true
  rm -rf /data/resource-cache/* 2>/dev/null || true
  # NOTE: /data/dalvik-cache and /data/cache are intentionally NOT deleted here.
  # They are unrelated to GPU drivers. Deleting dalvik-cache forces ART to
  # reverify and recompile every app on next boot (minutes of added boot time).

  # OpenGL/Vulkan specific
  find /data -type d -path "*/code_cache/*/OpenGL" -exec rm -rf {} + 2>/dev/null || true
  find /data -type d -path "*/code_cache/*/Vulkan" -exec rm -rf {} + 2>/dev/null || true

  # QGL config
  rm -f /data/vendor/gpu/qgl_config.txt 2>/dev/null || true
  rmdir /data/vendor/gpu 2>/dev/null || true

  # Old GPU caches
  rm -rf /data/vendor/gpu_cache 2>/dev/null || true
}

# Run cache cleaning
clean_caches

echo "✓ Caches cleaned"
echo ""

# ========================================
# REMOVE libgsl.so BACKUP FOLDER
# ========================================
# The Backup folder was created by the GPU Spoofer in the WebUI.
# Remove it on uninstall so a future install starts clean and the
# "Restore Original" button cannot accidentally restore a stale/wrong backup.

echo "Removing libgsl.so backup folder..."
rm -rf /sdcard/Adreno_Driver/Backup 2>/dev/null || true
echo "✓ Backup folder removed"
echo ""

# ========================================
# REMOVE TEMPORARY LOG FILES
# ========================================
# Clean up all /data/local/tmp files written by this module
# (boot attempt counters, boot state, Adreno_Driver log tree).

echo "Removing temporary module files from /data/local/tmp..."
rm -rf /data/local/tmp/Adreno_Driver   2>/dev/null || true
rm -f  /data/local/tmp/adreno_boot_attempts  2>/dev/null || true
rm -f  /data/local/tmp/adreno_boot_state     2>/dev/null || true
rm -f  /data/local/tmp/adreno_no_metamodule.log 2>/dev/null || true
rm -f  /data/local/tmp/adreno_skip_mount.log    2>/dev/null || true
rm -f  /data/local/tmp/adreno_vk_compat_full    2>/dev/null || true
rm -f  /data/local/tmp/adreno_vk_compat_score   2>/dev/null || true
rm -f  /data/local/tmp/adreno_skiavk_degraded   2>/dev/null || true
rm -f  /data/local/tmp/adreno_old_vendor        2>/dev/null || true
# Additional state files not previously removed on uninstall:
rm -f  /data/local/tmp/adreno_last_render_mode      2>/dev/null || true  # stale mode → reinstall skips cache clear
rm -f  /data/local/tmp/adreno_last_cleared_state    2>/dev/null || true  # 3-line state file → reinstall forces correct first-boot clear
rm -f  /data/local/tmp/adreno_skiavk_force_override 2>/dev/null || true  # user-created force-override; previously not removed on uninstall
rm -f  /data/local/tmp/adreno_vk_compat             2>/dev/null || true  # prop_only/incompatible flag — Vulkan compat state
rm -f  /data/local/tmp/adreno_config.txt            2>/dev/null || true  # SD mirror read by next post-fs-data boot
rm -f  /data/local/tmp/adreno_early_log_buffer.*    2>/dev/null || true  # leftover early log buffers
echo "✓ Temp files removed"
echo ""

# ========================================
# REMOVE SDCARD LOG FOLDERS
# ========================================
# Remove the log subdirectories that service.sh copies to sdcard.
# We keep /sdcard/Adreno_Driver/Config/ so the user's config survives
# in case they wish to reinstall, but all log data is removed.

echo "Removing sdcard log folders..."
rm -rf /sdcard/Adreno_Driver/Booted     2>/dev/null || true
rm -rf /sdcard/Adreno_Driver/Bootloop   2>/dev/null || true
rm -rf /sdcard/Adreno_Driver/Install    2>/dev/null || true
rm -rf /sdcard/Adreno_Driver/Statistics 2>/dev/null || true
echo "✓ SDcard log folders removed"
echo ""

# ========================================
# REMOVE QGL OWNER MARKER
# ========================================
# The owner marker tells post-fs-data.sh / service.sh that THIS module
# installed /data/vendor/gpu/qgl_config.txt. Remove it on uninstall so
# the qgl_config.txt deletion logic (which checks the marker) doesn't
# attempt to delete another manager's file on a future reinstall.

echo "Removing QGL owner marker..."
rm -f /data/vendor/gpu/.adreno_qgl_owner 2>/dev/null || true
echo "✓ QGL owner marker removed"
echo ""

echo "========================================"
echo "Uninstall Complete!"
echo "========================================"
echo ""
echo "Stock GPU drivers will be restored"
echo "after reboot."
echo ""
echo "⚠ PLEASE REBOOT YOUR DEVICE"
echo ""

exit 0
