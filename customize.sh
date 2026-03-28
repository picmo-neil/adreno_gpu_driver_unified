# ============================================================
# ADRENO DRIVER MODULE — MINIMAL INSTALLER
# ============================================================
MODPATH="$MODPATH"
TMPDIR="$TMPDIR"

ui_print "========================================"
ui_print "    Adreno GPU Driver Refactored"
ui_print "========================================"

# 1. Architecture Check
if [ "$ARCH" != "arm64" ]; then
    ui_print "! ONLY ARM64 SUPPORTED"
    abort "! Incompatible architecture: $ARCH"
fi

# 2. Extract Files
ui_print "- Installing files..."
cp -af "$TMPDIR/system" "$MODPATH/"
for f in post-fs-data.sh service.sh boot-completed.sh common.sh adreno_config.txt qgl_config.txt sepolicy.rule; do
    [ -f "$TMPDIR/$f" ] && cp -f "$TMPDIR/$f" "$MODPATH/"
done

# 3. Permissions
ui_print "- Setting permissions..."
set_perm_recursive "$MODPATH" 0 0 0755 0644
chmod 0755 "$MODPATH"/*.sh

# 4. Contexts
if command -v chcon >/dev/null 2>&1; then
    chcon -R u:object_r:same_process_hal_file:s0 "$MODPATH/system/vendor/lib64" 2>/dev/null
    chcon -R u:object_r:vendor_firmware_file:s0 "$MODPATH/system/vendor/firmware" 2>/dev/null
fi

ui_print "- Done. Reboot to activate."
ui_print "========================================"
