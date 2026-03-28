#!/system/bin/sh
# Adreno GPU Driver - Simplified post-fs-data.sh
# Core purpose: Ensure /data/vendor/gpu exists and set early props.

MODDIR="${0%/*}"
. "$MODDIR/common.sh"

# 1. Basic Directory Setup for QGL
QGL="n"
[ -f "$MODDIR/adreno_config.txt" ] && . "$MODDIR/adreno_config.txt"
[ -f "/data/local/tmp/adreno_config.txt" ] && . "/data/local/tmp/adreno_config.txt"

if [ "$QGL" = "y" ]; then
    mkdir -p /data/vendor/gpu 2>/dev/null
    chown root:system /data/vendor/gpu 2>/dev/null
    chmod 0775 /data/vendor/gpu 2>/dev/null
    # Pre-label so SurfaceFlinger doesn't hit a wall if it checks too early
    chcon u:object_r:same_process_hal_file:s0 /data/vendor/gpu 2>/dev/null || true
fi

# 2. Render Mode Props (Handled here before SF starts)
# Load RENDER_MODE
RENDER_MODE="normal"
[ -f "$MODDIR/adreno_config.txt" ] && . "$MODDIR/adreno_config.txt"

if [ "$RENDER_MODE" = "skiavk" ]; then
    resetprop debug.hwui.renderer skiavk
    resetprop debug.renderengine.backend skiavkthreaded
    resetprop ro.hwui.use_vulkan true
elif [ "$RENDER_MODE" = "skiagl" ]; then
    resetprop debug.hwui.renderer skiagl
    resetprop debug.renderengine.backend skiaglthreaded
fi

# 3. Cache Management (Only on mode change)
# Simplified mode change detection
LAST_MODE_FILE="/data/local/tmp/adreno_last_mode"
LAST_MODE=$(cat "$LAST_MODE_FILE" 2>/dev/null || echo "none")

if [ "$RENDER_MODE" != "$LAST_MODE" ]; then
    printf '[ADRENO] Render mode change detected: %s -> %s. Clearing cache.\n' "$LAST_MODE" "$RENDER_MODE" > /dev/kmsg
    rm -rf /data/misc/hwui/* 2>/dev/null
    rm -rf /data/misc/gpu/* 2>/dev/null
    find /data/user_de -type d -name "app_skia_pipeline_cache" -exec rm -rf {} + 2>/dev/null
    echo "$RENDER_MODE" > "$LAST_MODE_FILE"
fi

exit 0
