# Adreno GPU Driver — Verification Checklist

## TEST 1: Property Area Stability
- **Device state**: Normal boot.
- **Command**: `adb shell dmesg | grep -i "hole in prop"`
- **Expected output**: Empty.
- **If failing**: Bucket overflow. Move more props from `system.prop` to `resetprop` in `post-fs-data.sh`.

## TEST 2: SELinux Injection
- **Device state**: Normal boot.
- **Command**: `adb shell getenforce` (Check mode), then `adb shell dmesg | grep avc | grep -i gpu`
- **Expected output**: Minimal to zero GPU-related denials.
- **If failing**: Check `SEPOLICY_AUDIT.md` for batch success/failure.

## TEST 3: QGL Activation Timing
- **Device state**: Booting.
- **Command**: `adb shell ls -l /data/vendor/gpu/qgl_config.txt`
- **Expected output**: File should NOT exist or be mode 0000 during boot animation. Should be mode 0644 AFTER `sys.boot_completed=1` + 3s.
- **If failing**: Check `boot-completed.sh` logs in `/sdcard/Adreno_Driver/qgl_trigger.log`.

## TEST 4: Per-App Switching
- **Device state**: Open a game with an app-specific profile.
- **Command**: `adb shell cat /data/vendor/gpu/qgl_config.txt`
- **Expected output**: Config content matches the app-specific profile.
- **If failing**: Check QGL Trigger APK accessibility service status.

## TEST 5: Metamodule Compatibility
- **Device state**: KernelSU/APatch with a meta module installed.
- **Command**: `adb shell [ -f /data/adb/modules/adreno_gpu_driver_unified/skip_mount ] && echo "Broken" || echo "OK"`
- **Expected output**: `OK`.
- **If failing**: Metamodule detection failed. Check `common.sh` ID list.
