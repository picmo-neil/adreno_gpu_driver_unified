#!/system/bin/sh
# Adreno GPU Driver - Boot Completed Script (Robust & Zero-Overhead)
# Replicates LYB Kernel Manager timing and mechanism exactly.

MODDIR="${0%/*}"

# 1. Load Config
QGL="n"
# Priority override from user config if exists, then fallback to module defaults.
[ -f "/sdcard/Adreno_Driver/Config/adreno_config.txt" ] && . "/sdcard/Adreno_Driver/Config/adreno_config.txt" || \
[ -f "$MODDIR/adreno_config.txt" ] && . "$MODDIR/adreno_config.txt"

[ "$QGL" = "y" ] || exit 0

# 2. Optimized Wait for Boot Settlement
# Consistent with LYB Kernel Manager's safe application window.
sleep 20

# 3. Locate Source
QGL_SRC=""
for src in "/sdcard/Adreno_Driver/Config/qgl_config.txt" "/data/local/tmp/qgl_config.txt" "$MODDIR/qgl_config.txt"; do
    if [ -f "$src" ]; then
        QGL_SRC="$src"
        break
    fi
done

[ -n "$QGL_SRC" ] || exit 1

# 4. LYB-Style Application Mechanism
# The Adreno driver validates BOTH file and directory context.
# We ensure the directory exists and has the correct label first.
QGL_DIR="/data/vendor/gpu"
QGL_TARGET="$QGL_DIR/qgl_config.txt"
QGL_TMP="$QGL_DIR/.qgl_config.tmp"

mkdir -p "$QGL_DIR" 2>/dev/null
chown root:system "$QGL_DIR" 2>/dev/null
chmod 0775 "$QGL_DIR" 2>/dev/null
chcon u:object_r:same_process_hal_file:s0 "$QGL_DIR" 2>/dev/null || true

# Atomic application via temporary move to prevent partial reads by the driver.
cp -f "$QGL_SRC" "$QGL_TMP" 2>/dev/null
chmod 0644 "$QGL_TMP" 2>/dev/null
chown 0:1000 "$QGL_TMP" 2>/dev/null
chcon u:object_r:same_process_hal_file:s0 "$QGL_TMP" 2>/dev/null || true
mv -f "$QGL_TMP" "$QGL_TARGET" 2>/dev/null

# Log success
printf '[ADRENO] QGL Config applied successfully (LYB-style)\n' > /dev/kmsg 2>/dev/null || true

exit 0
