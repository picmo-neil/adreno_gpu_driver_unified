# Adreno GPU Driver — Recovery Mode Analysis

## Background
The module manages `qgl_config.txt` in `/data/vendor/gpu/`. This directory persists across reboots. Recovery environments (TWRP, OrangeFox, SHRP) mount the `/data` partition to perform backups, installs, and file management.

## Risk Assessment

### Scenario 1: GPU Driver Loading in Recovery
Most modern recoveries use the Linux Framebuffer (`fbdev`) or a minimal GLES implementation. They do NOT typically mount the `/vendor` partition in the standard Android location at boot, nor do they load the full Vulkan stack.

### Scenario 2: Persistent QGL Config
If a normal boot was completed, `qgl_config.txt` remains at mode `0644`. If a recovery *were* to load the Qualcomm Vulkan driver and read this file:
- **Result**: It would apply the extensions/settings.
- **Risk**: Low. Recoveries are not high-performance GPU consumers. An incompatible extension might cause a drawing glitch but is unlikely to "brick" the recovery UI which has multiple fallbacks.

### Scenario 3: Protected State (Mode 0000)
If the device crashed or was rebooted before `BOOT_COMPLETED`, the config is at mode `0000`.
- **Result**: The recovery GPU driver (if any) would receive `EACCES` when attempting to read the file.
- **Risk**: Zero. The driver falls back to default internal settings.

## Research Finding
A search of TWRP and OrangeFox source code confirms they do not intentionally parse `qgl_config.txt` from `/data/vendor/gpu/`. They rely on standard AOSP `minui` or basic GLES.

## Implementation Decision
**No fix required.** The "Remove-Then-Reapply" strategy implemented in `post-fs-data.sh` and `boot-completed.sh` ensures that even if a "bad" config was left behind, it is removed at the very start of the next *normal* boot. Recovery remains unaffected.
