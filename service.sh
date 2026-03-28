#!/system/bin/sh
# Adreno GPU Driver - Simplified service.sh
# Core purpose: Reinforce props and handle boot-time verification.

MODDIR="${0%/*}"
. "$MODDIR/common.sh"

# 1. Configuration Loading
[ -f "$MODDIR/adreno_config.txt" ] && . "$MODDIR/adreno_config.txt"
[ -f "/sdcard/Adreno_Driver/Config/adreno_config.txt" ] && . "/sdcard/Adreno_Driver/Config/adreno_config.txt"

# 2. Wait for Boot Completion
# We use a simple loop as it is most reliable across ROMs.
while [ "$(getprop sys.boot_completed)" != "1" ]; do
    sleep 1
done

# 3. Prop Reinforcement
# Ensure our props won't be overridden by OEM late-start scripts.
if [ "$RENDER_MODE" = "skiavk" ]; then
    resetprop debug.hwui.renderer skiavk
    resetprop ro.hwui.use_vulkan true
elif [ "$RENDER_MODE" = "skiagl" ]; then
    resetprop debug.hwui.renderer skiagl
fi

# Stability Props (Set regardless of mode)
resetprop debug.egl.hw 1
resetprop debug.sf.hw 1
resetprop persist.sys.ui.hw 1

# 4. Success Marker
touch "$MODDIR/.boot_success" 2>/dev/null

# Log success
printf '[ADRENO] service.sh completed successfully\n' > /dev/kmsg 2>/dev/null || true

exit 0
