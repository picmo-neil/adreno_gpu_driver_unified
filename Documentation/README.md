# 🎯 ADRENO GPU DRIVER GUIDE
## Complete Installation & Configuration Manual

**Module Name:** Adreno GPU Driver Unified  
**Module ID:** `adreno_gpu_driver_unified`  
**Developer:** @pica_pica_picachu  
**Contact:** Telegram @zesty_pic  
**Version:** Universal (Works with Magisk • KernelSU • APatch • Recovery)

> **⚡ ONE ZIP FILE FOR ALL INSTALLATION METHODS**

> **⚠️ BOOTLOOP DISCLAIMER:** This module includes optional library replacements (`libdmabufheap.so`, `libgpu_tonemapper.so`) that interact with your device's specific Adreno GPU generation, ROM version, and vendor partition. These libraries may cause bootloops on unsupported devices. If you experience 3+ consecutive bootloops, remove these libraries via Quick Fixes or reflash without the library overlay.

---

# 📋 TABLE OF CONTENTS

## PART 1: QUICK START GUIDE (BEGINNERS)
1. [What Is This & What Does It Do?](#what-is-this)
2. [Quick Prerequisites Checklist](#quick-prerequisites)
3. [Installation Methods - Choose One](#installation-methods-comparison)
4. [Magisk Installation (Recommended)](#magisk-quick-install)
5. [KernelSU Installation](#kernelsu-quick-install)
6. [APatch Installation](#apatch-quick-install)
7. [Quick Troubleshooting](#quick-troubleshooting)

## PART 2: ADVANCED COMPLETE GUIDE
8. [Deep Dive: How The Module Works](#how-module-works)
9. [File Structure & Components](#file-structure-detailed)
10. [Boot Process Detailed](#boot-process-detailed)
11. [Property Management System](#property-management)
12. [Configuration System](#configuration-system)
13. [WebUI Manager Complete Guide](#webui-complete-guide)
14. [SELinux Policy Injection](#selinux-policy)
15. [Cache Management System](#cache-management)
16. [Bootloop Detection & Recovery](#bootloop-detection-system)
17. [OEM ROM Compatibility](#oem-rom-compatibility)

## PART 3: TECHNICAL REFERENCE
18. [Configuration File Reference](#config-file-reference)
19. [System Properties Reference](#system-properties)
20. [Log Files Complete Reference](#log-files-reference)
21. [GPU Compatibility Matrix](#gpu-compatibility-matrix)
22. [Driver Version Selection](#driver-version-selection)
23. [ROM-Specific Considerations](#rom-specific)
24. [RENDER_MODE Technical Details](#render-mode-technical)

## PART 4: TROUBLESHOOTING & RECOVERY
25. [Complete Troubleshooting Guide](#complete-troubleshooting)
26. [Bootloop Recovery (All Methods)](#bootloop-recovery-all)
27. [Camera Not Working](#fix-camera)
28. [Screen Recorder Broken](#fix-screen-recorder)
29. [Night Mode Issues](#fix-night-mode)
30. [Performance Problems](#fix-performance)
31. [Graphics Glitches](#fix-graphics-glitches)
32. [Module Not Loading](#fix-module-not-loading)

## PART 5: RECOVERY MODE INSTALLATION
33. [Recovery Mode Complete Guide](#recovery-mode-guide)
34. [Understanding the Risks](#recovery-risks)
35. [Mandatory Backups](#recovery-backups)
36. [Step-by-Step Recovery Installation](#recovery-installation-steps)

## PART 6: WEBUI MANAGER GUIDE
37. [Home Tab](#webui-home)
38. [Config Tab](#webui-config)
39. [Utils Tab](#webui-utils)
40. [Data Tab](#webui-data)
41. [Custom Driver Tools](#webui-custom-tools)
42. [Language & Theme](#webui-language-theme)
43. [Terminal Log](#webui-terminal)

## PART 7: APPENDIX
44. [FAQ - Frequently Asked Questions](#faq)
45. [Glossary of Terms](#glossary)
46. [Credits & Acknowledgments](#credits)
47. [License & Disclaimer](#license)

---

# PART 1: QUICK START GUIDE

<a name="what-is-this"></a>
## 1. What Is This & What Does It Do?

### Simple Explanation (For Beginners)

Your phone has a GPU (Graphics Processing Unit) - the chip that handles all graphics, games, and visual effects. Just like a PC graphics card, your GPU needs software called "drivers" to work.

**This module replaces your phone's GPU drivers with different versions.**

**What you can get:**
- ✅ Better gaming performance (higher FPS, smoother gameplay)
- ✅ Improved graphics rendering
- ✅ Better app performance
- 😐 No noticeable difference
- ❌ Worse performance
- ❌ Broken features (camera, screen recorder, etc.)

**The Truth:** Results are **100% device-dependent**. What works amazing on one phone might completely break another.

### What Does "GPU Driver" Mean?

Think of it like updating your computer's graphics card drivers:
- **Windows PC:** You download NVIDIA/AMD drivers
- **Android Phone:** You install this module with Adreno drivers

### Key Features of This Module

**🎯 Universal Installation**
- ONE ZIP works with: Magisk, KernelSU, APatch, and Custom Recovery
- Auto-detects your environment
- Installs correctly on all platforms

**🛡️ Safety Features**
- Bootloop detection (detects if phone keeps rebooting)
- Automatic crash log collection
- Configuration backup (survives updates)
- Easy removal (for Magisk/KernelSU/APatch)

**🎨 Web Interface (Magisk/KernelSU/APatch only)**
- Change settings without editing files
- One-click fixes for common problems
- View logs and system information
- Multi-language support

**⚡ Smart Cache Management**
- Automatically cleans GPU shader caches
- Prevents compatibility issues
- Optimizes for new drivers

<a name="quick-prerequisites"></a>
## 2. Quick Prerequisites Checklist

### ✅ MUST HAVE (All Required)

**Device Requirements:**
- [ ] Qualcomm Adreno GPU (check in DevCheck app)
  - ❌ Mali GPU (Samsung/MediaTek) - Won't work
  - ❌ PowerVR GPU - Won't work
  - ❌ Adreno 5xx or older - Not recommended

- [ ] Android 11 or newer (Android 10 may work but unsupported)
- [ ] ARM64 architecture (64-bit device)
- [ ] 500MB+ free storage space
- [ ] Unlocked bootloader

**Root/Recovery Requirements (Choose ONE):**
- [ ] Magisk 20.4+ installed, OR
- [ ] KernelSU 0.5.0+ installed, OR
- [ ] APatch 0.10.7+ installed, OR
- [ ] Custom Recovery (TWRP 3.5.0+, OrangeFox R11+)

**Knowledge Requirements:**
- [ ] Know how to install Magisk/KernelSU/APatch modules
- [ ] Know how to boot into recovery mode
- [ ] Know how to recover from bootloops
- [ ] Have made BACKUPS (especially for Recovery method)

### ⚠️ CRITICAL WARNINGS

**BEFORE YOU INSTALL - READ THIS:**

1. **❌ NO GUARANTEED IMPROVEMENTS**
   - Drivers may improve, worsen, or have no effect
   - Performance depends on driver compatibility
   - This is EXPERIMENTAL

2. **❌ MAY BREAK FEATURES**
   - Camera might stop working
   - Screen recorder might break
   - Night mode/blue light filter might fail
   - Some apps might crash

3. **❌ BOOTLOOP RISK**
   - Incompatible drivers = bootloop
   - Must know how to recover
   - ALWAYS backup before installing

4. **❌ ONE DRIVER AT A TIME**
   - Uninstall any existing GPU driver modules first
   - Don't mix multiple GPU modules

5. **✅ ALWAYS BACKUP**
   - Magisk/KernelSU/APatch: Easy to remove
   - Recovery mode: MUST backup vendor partition!

<a name="installation-methods-comparison"></a>
## 3. Installation Methods - Choose One

| Method | Reversible? | System Changes | WebUI? | Difficulty | Risk |
|--------|-------------|----------------|--------|------------|------|
| **Magisk** | ✅ Yes (easy) | ❌ None | ✅ Yes | 🟢 Easy | 🟢 Low |
| **KernelSU** | ✅ Yes (easy) | ❌ None | ✅ Yes | 🟢 Easy | 🟢 Low |
| **APatch** | ✅ Yes (easy) | ❌ None | ✅ Yes | 🟢 Easy | 🟢 Low |
| **Recovery** | ❌ NO (permanent) | ✅ Direct | ❌ No | 🔴 Hard | 🔴 High |

### Which Method Should You Use?

**If you have Magisk installed:**
→ Use **Method A: Magisk** (Recommended)
- Easiest to remove if issues
- Includes WebUI (you do have to use kernelsu webui apk to see webui)
- Survives system updates
- No permanent changes

**If you have KernelSU installed:**
→ Use **Method B: KernelSU**
- Same benefits as Magisk
- Includes WebUI
- Easy removal
- **IMPORTANT:** Needs metamodule installed!

**If you have APatch installed:**
→ Use **Method C: APatch**
- Same benefits as Magisk/KernelSU
- Multiple mounting modes supported
- Includes WebUI

**If you DON'T have root but have custom recovery:**
→ Use **Method D: Recovery** (Advanced Only)
- ⚠️ Makes PERMANENT changes
- ⚠️ MUST backup vendor first
- ⚠️ NO WebUI
- ⚠️ Can't easily change settings
- ⚠️ Only for advanced users

**First time trying GPU drivers?**
→ **Install Magisk first**, then use Method A
- Safest way to test
- Easy to remove if it doesn't work
- Can try different drivers easily

<a name="magisk-quick-install"></a>
## 4. Magisk Installation (Recommended)

### Prerequisites
- ✅ Magisk 20.4 or newer installed
- ✅ Magisk Manager app
- ✅ Module ZIP downloaded

### Installation Steps

**1. Open Magisk Manager**
   - Launch the Magisk app on your phone

**2. Go to Modules Tab**
   - Tap "Modules" in bottom navigation bar

**3. Install Module**
   - Tap "Install from storage" button
   - (Older Magisk: Tap the + icon)

**4. Select ZIP File**
   - Navigate to Downloads folder
   - Select the `adreno_gpu_driver_unified_vX.X.X.zip` file

**5. Wait for Installation**
   - Installation takes 30-60 seconds
   - You'll see GPU detection, config loading, file installation, and cache cleaning

**6. Check Installation Summary**
   - Look for:
     - ✅ "GPU detected: Adreno XXX"
     - ✅ "Configuration loaded"
     - ✅ "XX files installed"
     - ✅ "Caches cleaned"

**7. Reboot Device**
   - Tap "Reboot" button
   - First boot takes 1-3 minutes (normal)
   - GPU caches are being rebuilt

**8. Verify Installation**
   - After boot, open Magisk Manager
   - Modules tab → Check module is enabled

### What Happens During Installation?

During installation, `customize.sh` runs and performs environment detection (Magisk version, device model, Android version, GPU model from `/sys/class/kgsl/kgsl-3d0/gpu_model`), loads your saved config from `/sdcard/Adreno_Driver/Config/` if it exists, copies all driver files to the module directory, and cleans shader caches. After the first successful boot, the module's configuration is also backed up to your SD card so it survives module updates and reinstalls.

### If Phone Doesn't Boot (Bootloop)

**Option 1: Volume Down Method** (Easiest - if you have anti-bootloop module)

```
1. Power off device completely
2. Turn on device
3. When logo appears → Press and HOLD Volume Down button
4. Keep holding until system boots
5. This disables ALL Magisk modules
6. Open Magisk Manager
7. Modules → Disable "Adreno GPU Driver"
8. Reboot normally
```

**Option 2: Recovery Method** (Universal)

```
1. Boot into recovery (Power + Volume Up)
2. Mount → Enable "Data"
3. File Manager → Navigate to:
   /data/adb/modules/
4. Delete folder: adreno_gpu_driver_unified
5. Go back → Reboot → System
6. Module removed
```

**Option 3: ADB Method**

```bash
adb shell
su
rm -rf /data/adb/modules/adreno_gpu_driver_unified
reboot
```

<a name="kernelsu-quick-install"></a>
## 5. KernelSU Installation

### Prerequisites
- ✅ KernelSU 0.5.0 or newer
- ✅ KernelSU Manager app
- ✅ Module ZIP downloaded
- ✅ **CRITICAL: Metamodule installed** (MetaMagicMount recommended)

### Important: Metamodule Requirement

**⚠️ KernelSU REQUIRES A METAMODULE FOR MODULE MOUNTING**

KernelSU by itself cannot mount module files. You MUST install one of these metamodules first:

**Recommended Metamodules:**
1. **MetaMagicMount** (Most recommended) — Best compatibility, mimics Magisk's Magic Mount
2. **Meta-Mountify** (Second recommendation if MetaMagicMount breaks something)
3. **Meta-OverlayFS** — Uses OverlayFS mounting, good alternative
4. **Meta-Hybrid** — Combines multiple approaches, latest solution

**How to Install Metamodule:**
```
1. Download metamodule ZIP (get from KernelSU community)
2. Install it through KernelSU Manager
3. Reboot
4. Verify it's active (no disable marker)
5. THEN install this GPU driver module
```

**Without Metamodule:**
- ❌ Module will install but NOT work
- ❌ Files won't be mounted to system
- ❌ Stock drivers will still be active
- ❌ You'll see "skip_mount" file created

### KernelSU Settings (CRITICAL)

Before installing, open KernelSU Manager → Settings → find "Unmount modules by default" → turn this **OFF**. This ensures modules mount correctly.

### Installation Steps

1. Verify Metamodule is installed and enabled in KernelSU Manager
2. Open KernelSU Manager → Modules Tab → Install (+ button)
3. Select the module ZIP file
4. Wait for installation (same process as Magisk)
5. Check for warnings — if you see "No metamodule detected" → STOP and install a metamodule first
6. Reboot device

**Verify after boot:**
```bash
su
ls /data/adb/modules/adreno_gpu_driver_unified/
```
If you see a `skip_mount` file, the module is not working — install a metamodule first.

### Accessing WebUI on Magisk
- Install the KernelSU WebUI APK, grant it root access, and you will be able to see WebUI for all modules.

### Accessing WebUI on KernelSU
- KernelSU Manager → Modules → Tap "Adreno GPU Driver" → Open WebUI button

### If Phone Doesn't Boot
Same recovery methods as Magisk: Volume Down method, Recovery deletion, or ADB removal.

<a name="apatch-quick-install"></a>
## 6. APatch Installation

### Prerequisites
- ✅ APatch 0.10.7 or newer installed
- ✅ APatch Manager app
- ✅ Module ZIP downloaded

### APatch Mounting Modes

APatch supports three mounting modes. The module auto-detects and adapts to whichever is active:

- **Magic Mount** (Default on v0.10.8+) — Similar to Magisk, most compatible
- **OverlayFS** (Opt-in) — Uses Linux OverlayFS, enable via `.overlay_enable` marker
- **Lite Mode** — Minimal mounting, compatibility mode

### Installation Steps

1. Open APatch Manager → Modules Tab → Install
2. Select ZIP from storage
3. Wait for installation (APatch mode auto-detected)
4. Reboot device
5. Verify in APatch Manager → Modules — check module is enabled

Recovery methods are identical to Magisk/KernelSU (Volume Down, Recovery file deletion, or ADB).

<a name="quick-troubleshooting"></a>
## 7. Quick Troubleshooting

### Issue: Module Not Working (Files Not Mounted)

**Symptoms:** Stock GPU still active, no performance change, module shows enabled but ineffective

- **Magisk:** Ensure Magic Mount is enabled in settings. Check module has no disable marker.
- **KernelSU:** Install MetaMagicMount or other metamodule FIRST. If `skip_mount` exists in the module folder → no metamodule was detected. Install metamodule, reboot, reinstall this module.
- **APatch:** Check mounting mode and verify APatch version (0.10.8+ for Magic Mount).

### Issue: Phone Boots Then Crashes/Reboots

**Symptoms:** Phone boots to home screen, apps start crashing (especially keyboard), eventually reboots

**Cause:** Module mounted but drivers incompatible with your hardware. The easiest fix is flashing via recovery.

**Solution:** Remove module (recovery or ADB), try a different driver version, or confirm driver compatibility before reflashing.

### Issue: Camera Not Working

Open WebUI → Utils Tab → tap "Fix Camera" → Reboot. This removes OpenCL/compute libraries that can conflict with the camera HAL.

### Issue: Screen Recorder Broken

Open WebUI → Utils Tab → tap "Fix Screen Recorder" → Reboot. This removes C2D color conversion libraries that can break screen recording.

### Issue: Night Mode/Blue Light Filter Not Working

Open WebUI → Utils Tab → tap "Fix Night Mode" → Reboot. This removes the Snapdragon Color Manager library that can interfere with the display night mode.

### Issue: Can't Access WebUI

Check that the module is enabled, wait 5 minutes after boot, try a different browser. Check that `webui_running` marker exists at `/data/local/tmp/Adreno_Driver/webui_running`. Check the service.sh log for errors.

---

# PART 2: ADVANCED COMPLETE GUIDE

<a name="how-module-works"></a>
## 8. Deep Dive: How The Module Works

At its core, the module does two things:

1. **Replaces the GPU driver** — injects custom Adreno `.so` libraries into the file system via magic-mount before any process has loaded the system driver, so every app and the Android compositor (SurfaceFlinger) use the custom driver from the very first frame.
2. **Configures the renderer** — sets Android system properties that tell the HWUI rendering engine and SurfaceFlinger which rendering pipeline (Vulkan or OpenGL) to use, and applies stability, performance, and compatibility tuning flags for the custom driver.

### Module Mode (Magisk/KernelSU/APatch)

The module directory at `/data/adb/modules/adreno_gpu_driver_unified/system/vendor/` mirrors the real `/vendor/` partition. The root manager's mounting system (Magic Mount or OverlayFS) overlays these files on top of the stock vendor partition — the system sees the custom driver, while the stock files are untouched underneath. Disabling or removing the module instantly reverts everything.

### Recovery Mode (Direct Installation)

Files are copied directly into `/vendor/lib64/`, `/vendor/firmware/`, etc. This is permanent — stock drivers are overwritten. No WebUI, no easy removal. Only for advanced users on devices where module mode is not possible.

<a name="file-structure-detailed"></a>
## 9. File Structure & Components

```
adreno_gpu_driver_unified/
├── META-INF/com/google/android/
│   ├── update-binary              # Universal installer (handles Magisk/KSU/APatch/Recovery)
│   └── updater-script
│
├── module.prop                    # Module metadata (id, name, version, author)
├── customize.sh                   # Runs during Magisk/KSU/APatch installation
├── post-fs-data.sh                # Early boot script (SELinux, PLT, QGL, boot counter)
├── service.sh                     # Late boot script (renderer props, WebUI, boot success)
├── uninstall.sh                   # Runs on module removal (cleanup)
├── adreno_config.txt              # Main configuration (PLT, QGL, ARM64_OPT, RENDER_MODE)
├── qgl_config.txt                 # QGL JSON config (Vulkan extensions, GPU tuning)
├── system.prop                    # System property overrides (applied on boot)
│
├── webroot/                       # Web interface
│   ├── index.html
│   ├── index.js                   # Backend logic + API handlers
│   └── style.css / theme.css
│
└── system/vendor/
    ├── lib/                       # 32-bit libraries (installed if ARM64_OPT=n)
    │   └── egl/, hw/
    ├── lib64/                     # 64-bit libraries (always installed)
    │   ├── libvulkan_adreno.so    # Vulkan driver
    │   ├── libGLESv2_adreno.so   # OpenGL ES 2.0/3.x driver
    │   ├── libGLESv1_CM_adreno.so
    │   ├── libEGL_adreno.so
    │   ├── libgsl.so              # Graphics System Layer (kernel communication)
    │   ├── libllvm-qcom.so        # LLVM shader compiler
    │   ├── libOpenCL.so / libOpenCL_adreno.so   # ⚠️ Optional — can break camera
    │   ├── libC2D2.so / libc2d30_bltlib.so      # ⚠️ Optional — can break screen recorder
    │   ├── libsnapdragon_color_manager.so        # ⚠️ Optional — can break night mode
    │   ├── gpu++.so               # Enhanced features (needs PLT=y, only in Zura's drivers)
    │   ├── libdmabufheap.so       # ⚠️ Needs higher kernel version
    │   ├── libgputonemap.so       # ⚠️ May cause bootloop on unsupported GPUs
    │   └── libgpukbc.so           # ⚠️ GPU-specific, may cause bootloop
    └── firmware/
        ├── a6xx_sqe.fw / a6xx_gmu.bin    # Adreno 6xx series
        ├── a7xx_sqe.fw / a7xx_gmu.bin    # Adreno 7xx series
        └── GPU-specific variants (a630, a640, a650, a702, a730...)
```

### Library Quick Reference

| Library Group | Purpose | Risk if Incompatible |
|---|---|---|
| `libGLESv2_adreno.so`, `libvulkan_adreno.so`, `libgsl.so` | Core graphics driver | Bootloop |
| `libOpenCL.so`, `libCB.so`, `libkcl.so`, etc. | GPU compute / OpenCL | Camera breakage |
| `libC2D2.so`, `libc2dcolorconvert.so` | 2D composition | Screen recorder breakage |
| `libsnapdragon_color_manager.so` | Display color management | Night mode breakage |
| `libgputonemap.so`, `libgpukbc.so`, `libdmabufheap.so` | Advanced GPU features | Bootloop |

<a name="boot-process-detailed"></a>
## 10. Boot Process Detailed

Android boots in distinct phases. The module hooks into two of them.

### Phase 1 — `post-fs-data.sh` (Very Early Boot, Before Zygote)

Runs after the file system is mounted but before any app or service process has started. This is the only safe window to:

- Apply renderer system properties via `resetprop` — SurfaceFlinger hasn't started yet so no property-change callbacks can fire.
- Write the module's `system.prop` file so the root manager pre-loads persistent properties on subsequent boots.
- Inject SELinux policy rules required for the custom driver's device nodes and shared library contexts.
- Configure the QGL (Qualcomm GPU Library) JSON config atomically.
- Increment the boot-attempt counter (for automatic rollback).

### Phase 2 — `service.sh` (Late Boot, After `boot_completed`)

Runs a few seconds after the device has fully booted and is interactive. This phase:

- Resets the boot-attempt counter (proving the boot succeeded).
- Re-enforces `debug.hwui.renderer` (per-process HWUI property — safe to set live because it is read per-process at first HWUI init, not monitored by SurfaceFlinger).
- Writes the persistent `system.prop` entries for the next boot.
- Optionally force-stops third-party apps so they cold-start with the new renderer (relevant for `skiavk_all` mode and when switching modes).

### Vulkan Compatibility Safety Gate

The renderer is applied immediately on all boots (including first boot after install). Rather than a blanket two-boot delay, safety is provided by a structural Vulkan compatibility gate in `post-fs-data.sh`:

1. `post-fs-data.sh` checks for a valid Vulkan ICD (Installable Client Driver) on the device.
2. If no Vulkan ICD is found, the render mode is **auto-degraded** from `skiavk` to `skiagl` — a real structural fallback rather than a timing workaround.
3. Pipeline caches are cleared pre-Zygote when the render mode changes, preventing stale cache crashes.
4. `service.sh` confirms boot success and writes a `.boot_success` marker, which gates `skiavkthreaded` backend promotion on subsequent boots.

This approach provides real Vulkan capability detection rather than deferring the renderer to an arbitrary second boot.

<a name="property-management"></a>
## 11. Property Management System

Android has two distinct ways to set system properties, and the module uses them deliberately.

### `resetprop` (Live Property Injection)

Sets a property in the running system immediately. Safe to use in `post-fs-data.sh` before SurfaceFlinger starts. Unsafe for certain properties after SurfaceFlinger is running because OEM ROMs register live property-change callbacks in SF.

### `system.prop` (Boot-Time Persistence)

The module maintains a `system.prop` file in its module directory. The root manager loads this file very early in boot — after magic-mount (so the custom driver is already in place) but before any app process starts.

### The `renderengine.backend` Bootloop Problem (Fixed)

`debug.renderengine.backend` controls which rendering engine SurfaceFlinger uses. On OEM ROMs (MIUI/HyperOS, Samsung OneUI, ColorOS), SurfaceFlinger registers a live `SystemProperties::addChangeCallback` for this property. If its value changes while SF is running, SF attempts to reinitialize its RenderEngine mid-frame — this crashes SF, all apps lose their window surfaces, and the device's watchdog reboots it.

**Why this caused a bootloop on the second boot specifically:** The first boot deferred everything. On the second boot, `post-fs-data.sh` set the property safely before SF started, but then `service.sh`, running after `boot_completed` while SF was actively rendering, also called `resetprop debug.renderengine.backend skiavkthreaded`. On OEM ROMs, this change notification fired the SF watcher → SF crash → reboot. On the third boot, the property already had the correct value, so the `resetprop` call was a no-op and didn't trigger the watcher.

**The fix:** `debug.renderengine.backend` is set **exclusively** in `post-fs-data.sh` before SF starts. It is never live-resetprop'd in `service.sh` and is not written to `system.prop`. `debug.hwui.renderer` is unaffected — it's a per-process HWUI property with no SF-level callbacks and is safe to set live.

<a name="configuration-system"></a>
## 12. Configuration System

### Configuration File: `adreno_config.txt`

The main config file lives in the module root. All settings are `KEY=value` pairs. The WebUI and manual edits both modify this same file. It is automatically backed up to `/sdcard/Adreno_Driver/Config/` and restored on reinstall.

| Setting | Values | Default | Purpose |
|---|---|---|---|
| `PLT` | `y` / `n` | `n` | Patches `/vendor/etc/public.libraries*.txt` to register `gpu++.so` — required for Zura's Bench++ drivers |
| `QGL` | `y` / `n` | `n` | Deploys a tuned `qgl_config.txt` to `/data/vendor/gpu/` for Vulkan extension and GPU memory tuning |
| `ARM64_OPT` | `y` / `n` | `n` | Removes 32-bit driver libraries to save ~100–200MB. **Only safe if you have zero 32-bit apps.** |
| `VERBOSE` | `y` / `n` | `n` | Enables detailed per-operation logging for debugging |
| `RENDER_MODE` | `normal` / `skiavk` / `skiagl` / `skiavk_all` | `normal` | Sets the HWUI and SurfaceFlinger rendering backend |

**Recommended for most users:** Leave all settings at defaults (`n` / `normal`) and only change what you specifically need.

### Common Configuration Profiles

**Maximum compatibility (all users):** `PLT=n  QGL=n  ARM64_OPT=n  VERBOSE=n  RENDER_MODE=normal`

**Vulkan rendering enabled:** Same as above but `RENDER_MODE=skiavk`

**Zura Bench++ testing:** `PLT=y  RENDER_MODE=normal` (all others default)

**ARM64-only storage saving:** `ARM64_OPT=y` — only if you are absolutely certain no 32-bit apps exist on your device. Free Fire, PUBG Mobile, and COD Mobile all require 32-bit libraries.

**Debugging a problem:** `VERBOSE=y` (all others unchanged)

### Changing Configuration

- **WebUI (recommended):** Open WebUI → Config tab → change settings → Apply Now or Save & Reboot
- **Manual (on-device):** Edit `/data/adb/modules/adreno_gpu_driver_unified/adreno_config.txt` with any text editor and reboot
- **Recovery mode:** Edit `adreno_config.txt` inside the ZIP before flashing — settings cannot be changed after a recovery flash without reflashing

### Configuration Persistence

Config is backed up to `/sdcard/Adreno_Driver/Config/adreno_config.txt`. This file survives module updates, reinstalls, and reboots. To fully reset: delete that file and reinstall the module.

<a name="webui-complete-guide"></a>
## 13. WebUI Manager Complete Guide

See **Part 6** for the complete WebUI user guide with all tabs, features, and options explained in detail.

**Quick access:**
- Magisk: Install KernelSU WebUI APK, grant root, open it
- KernelSU: KernelSU Manager → Modules → Adreno GPU Driver → Open WebUI
- APatch: APatch Manager → Modules → Open WebUI

<a name="selinux-policy"></a>
## 14. SELinux Policy Injection

### Why It's Necessary

The custom Adreno driver libraries need access to GPU device nodes (`/dev/kgsl-3d0`, etc.) and need to load as `same_process_hal` (in-process HAL). Stock SELinux policy denies these accesses for custom/untrusted library paths. Without policy injection, the GPU fails to initialize, apps crash, or SurfaceFlinger refuses to load the custom driver.

### What Gets Injected

`post-fs-data.sh` injects over 100 SELinux policy rules synchronously before the renderer is activated. The categories are:

- **GPU device access** — allows `gpu_device` ioctls and reads for various process contexts (SurfaceFlinger, system_server, app domains)
- **Same-process HAL** — allows the custom driver to be loaded as an in-process HAL library by all relevant process types
- **Vendor file contexts** — allows access to Adreno-specific vendor library paths for library execution and mapping
- **Android 16 QPR2** — includes updated `allowxperm` IOCTL range rules (0x0000–0xffff) required by newer kernel SELinux enforcement
- **SDK-versioned app domains** — covers `untrusted_app` domains for SDK 25 through 36 to handle per-SDK type enforcement
- **HAL binder IPC** — allows SurfaceFlinger, allocator HAL, and composer HAL to communicate via binder
- **Vendor data access** — allows SurfaceFlinger and apps to read the QGL config from `/data/vendor/gpu/`
- **OEM-specific rules** — fixes for Samsung's custom library path scheme, OPPO/Realme vendor path layouts, etc.

### Why Synchronous Injection Matters

All rules are injected synchronously (blocking, not backgrounded) before `post-fs-data.sh` exits. If injection runs in the background, SurfaceFlinger can start before the rules are active, hit a permission denial on the first GPU access, and trigger a bootloop. The script waits for every rule to be confirmed before returning.

### Diagnosing SELinux Denials

If GPU issues occur after installation, check for AVC denials in the kernel log:

```bash
adb shell dmesg | grep "avc:" | grep -iE "gpu|adreno|kgsl|vendor_file"
```

Common patterns: denials on `gpu_device` access for `surfaceflinger`, or `vendor_file` execute denials for `untrusted_app`. These indicate either the injection didn't run (check post-fs-data log) or an OEM-specific rule is missing.

<a name="cache-management"></a>
## 15. Cache Management System

### Why Cache Cleaning Is Necessary

When you replace GPU drivers, existing shader pipeline caches become invalid — they were compiled for the previous pipeline and will cause crashes or rendering corruption if reused. The module tracks the last active render mode in `/data/local/tmp/adreno_last_render_mode`. On each boot, if the current mode differs from the stored mode, the module selectively clears:

- `/data/misc/hwui/` — system-wide HWUI cache
- Per-app `app_skia_pipeline_cache` directories for all installed packages

This is done **only on mode changes** to avoid the severe performance impact of clearing caches unnecessarily. Some apps (notably Facebook) have thousands of shaders; clearing their cache forces a full recompile causing sluggishness and OOM conditions lasting several minutes.

### After Cache Cleaning: First Boot Behavior

After a cache clear, the first boot will be 1–3 minutes instead of the usual 30 seconds. Dalvik/ART recompiles all installed apps, and each game/app rebuilds its shader cache from scratch. The first launch of games will have noticeable stuttering or compilation pauses. This is temporary — once shaders are rebuilt for the new driver, performance normalizes.

### Manual Cache Clearing

Use the WebUI "Clear GPU Cache" button (Utils tab) to clear caches on demand while booted. Useful after changing driver version or configuration, or when experiencing graphics glitches from stale shaders.

| Cache Type | Path | Typical Size |
|---|---|---|
| Shader caches | `/data/user_de/*/cache/*shader*` | 50–500MB |
| GPU compute | `/data/data/*/cache/*gpucache*` | 10–100MB |
| OpenGL bytecode | `*/code_cache/*/OpenGL` | 5–50MB |
| Vulkan pipelines | `*/code_cache/*/Vulkan` | 5–100MB |
| Dalvik cache | `/data/dalvik-cache/*` | 100–300MB |

<a name="bootloop-detection-system"></a>
## 16. Bootloop Detection & Recovery

### How Detection Works

A boot counter at `/data/local/tmp/adreno_boot_attempts` tracks how many times `post-fs-data.sh` has run without a corresponding successful `service.sh` completion.

- `post-fs-data.sh` **increments** the counter at the start of each run.
- `service.sh` **resets** it to 0 after `boot_completed`.
- If the counter reaches **3** (three consecutive failed boots with uptime under 60 seconds), `post-fs-data.sh` disables the module by touching the Magisk/KSU `disable` flag, then exits without applying any driver or property changes.

This ensures a bad driver or broken configuration cannot brick a device — after three failed attempts the module disengages and the device boots normally with the stock driver.

**Why 60 seconds:** This threshold reliably separates bootloops (which always crash before 30 seconds) from slow-but-successful boots with heavy GPU cache rebuilding. Three consecutive failures before this threshold signals a real bootloop, not a transient issue.

### What Happens When Bootloop Is Detected

The module collects diagnostic logs before disengaging: `last_kmsg`, `pstore` contents, `dmesg`, and a human-readable `boot_state.txt` with your active configuration and device info. All logs are saved to `/sdcard/Adreno_Driver/Bootloop/bootloop_TIMESTAMP/`. After recovering, connect via ADB and read these logs to understand the root cause before trying a different driver.

### Manual Recovery Methods

See **Section 26** (Part 4) for all bootloop recovery methods.

<a name="oem-rom-compatibility"></a>
## 17. OEM ROM Compatibility

Different OEM Android builds add proprietary graphics-stack hooks that can interfere with custom drivers. The module detects and handles:

- **MIUI/HyperOS** — clears `debug.vulkan.dev.layers` (MIUI injects its own Vulkan validation layers which crash custom drivers), enforces its Vulkan gate property, disables Snapdragon profiler hooks.
- **Samsung OneUI** — fixes `same_process_hal_file` SELinux context for Samsung's custom library path scheme, handles the Samsung Vulkan gate (`ro.config.vulkan.enabled`).
- **ColorOS / RealmeUI** — adjusts SELinux contexts for OPPO's vendor path layout, clears OEM debug layer overrides.
- **FuntouchOS** — similar vendor path and layer cleanup.

For all OEM ROMs, the module also disables graphics profiler support flags (`graphics.gpu.profiler.support=false`) that cause crashes when the profiler attaches to a process using a custom driver it doesn't recognize.

---

# PART 3: TECHNICAL REFERENCE

<a name="config-file-reference"></a>
## 18. Configuration File Reference

### `adreno_config.txt` — All Options

**PLT (Public Libraries Text) Patching**
- `PLT=n` (default) — No modification to public.libraries.txt
- `PLT=y` — Adds `gpu++.so 64` to `/vendor/etc/public.libraries*.txt`, enabling apps to load the extended GPU feature library. Required for Zura's Bench++ drivers. Risks: DRM apps and banking apps may detect the system modification. Applied atomically during `post-fs-data.sh`.

**QGL (Qualcomm Graphics Library) Configuration**
- `QGL=n` (default) — No custom QGL config
- `QGL=y` — Writes a tuned `qgl_config.txt` to `/data/vendor/gpu/`. The write is atomic (temp file → rename) and retried up to 5 times. Config controls memory allocation strategies, command buffer sizes, and pipeline compilation settings. Also editable via WebUI QGL Editor. Backup saved to SD card automatically.

**ARM64 Optimization**
- `ARM64_OPT=n` (default) — Installs both 32-bit and 64-bit libraries
- `ARM64_OPT=y` — Removes `system/vendor/lib/` (32-bit libraries). Saves 100–200MB. Will break any 32-bit app or game. Cannot be changed after installation without reinstalling. Check 32-bit apps: `ls -d /data/app/*/lib/arm` — if any results exist, you need 32-bit support.

**Verbose Logging**
- `VERBOSE=n` (default) — Normal logging
- `VERBOSE=y` — Logs every individual operation, variable values, and timing. Logs written to `/sdcard/Adreno_Driver/Booted/` and `/data/local/tmp/Adreno_Driver/service.log`. Use only for debugging.

**RENDER_MODE**
See Section 24 for full technical details. Valid values: `normal`, `skiavk`, `skiagl`, `skiavk_all`.

<a name="system-properties"></a>
## 19. System Properties Reference

The module sets these properties through `system.prop` and/or `resetprop` in `post-fs-data.sh`:

| Property | Where Set | Purpose |
|---|---|---|
| `debug.hwui.renderer` | `post-fs-data.sh` + `service.sh` | Per-process HWUI backend (`skiavk`, `skiagl`) |
| `debug.renderengine.backend` | `post-fs-data.sh` only | SurfaceFlinger compositor backend — **never set live after boot** |
| `ro.hwui.use_vulkan` | `post-fs-data.sh` | System-level Vulkan enable flag |
| `debug.sf.hw` | `system.prop` | Hardware composition for SurfaceFlinger |
| `graphics.gpu.profiler.support` | `post-fs-data.sh` | Disabled to prevent profiler crashes with custom drivers |
| `debug.vulkan.dev.layers` | `post-fs-data.sh` (MIUI) | Cleared to prevent OEM Vulkan layer injection |

**Check current renderer:**
```bash
adb shell getprop debug.hwui.renderer
adb shell getprop debug.renderengine.backend
```

<a name="log-files-reference"></a>
## 20. Log Files Complete Reference

All logs are written to `/sdcard/Adreno_Driver/`:

| Path | Contents | Kept |
|---|---|---|
| `Booted/postfs_*.log` | Full post-fs-data sequence: property applications, SELinux injections, QGL writes | Last 5 |
| `Booted/service_*.log` | Service.sh completion: renderer, WebUI, driver verification | Last 5 |
| `Bootloop/bootloop_TIMESTAMP/` | `last_kmsg`, `dmesg`, `pstore`, `boot_state.txt` | Last 3 |
| `Config/adreno_config.txt` | Current config backup | Always |

Each log entry has a timestamp and `[OK]`/`[!]` prefix for easy scanning. View from WebUI Data tab, or via ADB:

```bash
adb shell ls /sdcard/Adreno_Driver/Booted/
adb shell cat /sdcard/Adreno_Driver/Booted/postfs_LATEST.log
```

<a name="gpu-compatibility-matrix"></a>
## 21. GPU Compatibility Matrix

> **Note from developer:** Any Adreno with kernel 4.14+ can use driver 819. Any Adreno with kernel 5.4+ can use driver 837/840+. The list shows drivers that CAN boot — booting does not mean better performance. Test and benchmark yourself.

### Adreno 4xx Series

**Adreno 418:** Compatible: 223, 601, 646 — Recommended: 601
**Adreno 420:** Compatible: 24 — Recommended: 24 (only option)
**Adreno 430:** Compatible: 24, 436, 601, 646 — Recommended: 436

### Adreno 5xx Series

**Adreno 504:** Compatible: 415, 502 — Recommended: 502
**Adreno 505 / 506 / 508 / 509:** Compatible: 313, 331, 415, 454, 472, 490, 502 — Recommended: 490 or 502
**Adreno 510 / 512:** Compatible: 331 — Recommended: 331 (only confirmed)
**Adreno 530:** Compatible: 384, 393, 415, 454, 490, 502 — Recommended: 490
**Adreno 540:** Compatible: 331, 415, 454, 490, 502, 555 — Recommended: 502 or 555

### Adreno 6xx Series

**Adreno 610 v1:** Use up to v819. Recommended: 757 or 819
**Adreno 610 v2:** Maximum v777. Recommended: 757 or 777. ⚠️ v819 causes bootloop on v2 — try v777 first; if OK, try v819; bootloop with v819 = you have v2.

**Adreno 612:** Compatible: 334, 415, 490, 502 — Recommended: 502
**Adreno 615:** Compatible: 331, 490, 502 — Recommended: 502
**Adreno 616:** Compatible: 415, 502, 744, 786 — Recommended: 744
**Adreno 618:** Compatible: 366, 415, 464, 502, 611, 615, 655, 687, 777, 786, 819 — Recommended: 777 or 819 (very compatible, wide support, popular in Poco/Redmi)
**Adreno 619:** Compatible: 444, 502, 530 — Recommended: 530
**Adreno 619L:** Compatible: 615, 762, 819 — Recommended: 762 or 819
**Adreno 613:** Compatible: 615 — Recommended: 615 (only confirmed)
**Adreno 620:** Compatible: 444, 490, 502, 655, 728 — Recommended: 655 or 728
**Adreno 630:** Compatible: 331, 415, 464, 502, 615, 797 — Recommended: 615 or 797 (SD845 devices)
**Adreno 640:** Compatible: 359, 365, 408, 415, 490, 502, 530, 615, 655, 676, 728, 786, 819 — Recommended: 786 or 819 (SD855/SD860, excellent compatibility)
**Adreno 642:** Compatible: 530, 611 — Recommended: 611
**Adreno 642L:** Compatible: 530, 615, 744.8, 757 — Recommended: 744.8 or 757
**Adreno 650:** Compatible: 443–819 (very wide range) — Recommended: 777, 786, or 819 (SD865/SD870, extensively tested, Poco F3 and similar)
**Adreno 660:** Compatible: 522, 525, 530, 615, 687, 744, 762.10, 767, 777, 819, 837 — Recommended: 819 or 837 (SD888)
**Adreno 680/685:** Limited community data — test with 7xx series drivers
**Adreno 690:** Compatible: 649 — Recommended: 649

### Adreno 7xx Series

**Adreno 702:** Start with v762
**Adreno 710 v1:** Use up to v762 — Recommended: v762
**Adreno 710 v2:** Has own v800.xx driver — Recommended: v800 specifically
**Adreno 720:** Compatible: 676 — Recommended: 676
**Adreno 722:** Compatible: 800 — Recommended: 800
**Adreno 725:** Compatible: 615–840 wide range — Recommended: v819 or v840
**Adreno 730:** Compatible: 614, 615, 676, 687, 744, 762, 772, 814, 819, 837 — Recommended: 819 or 837 (SD8 Gen 1, widely tested)
**Adreno 732 / 735:** Compatible: 762 — Recommended: 762
**Adreno 740:** Compatible: 614, 676, 690, 725, 819, 821, 837 — Recommended: 837 or 821 (SD8 Gen 2)
**Adreno 750:** Compatible: 744, 762, 786, 819, 837 — Recommended: 837 (SD8 Gen 3)

### Adreno 8xx Series

**Adreno 802:** Very new architecture, limited driver availability, experimental support only. Use latest 8xx driver available. Stock drivers may be the best choice currently.

<a name="driver-version-selection"></a>
## 22. Driver Version Selection

**How to systematically find the best driver:**

1. **Find your GPU:** `adb shell cat /sys/class/kgsl/kgsl-3d0/gpu_model` or use the DevCheck app
2. **Check the compatibility matrix** above for your GPU's recommended driver
3. **Establish a baseline:** Run 3DMark Sling Shot Extreme 3 times and average the score; note FPS in your main game
4. **Test the recommended version first** — install, reboot, benchmark
5. **Step up or down one version at a time** — test each systematically
6. **Document results** and share with community

Compatibility ≠ better performance. Just because a driver boots does not mean it's an improvement. Always benchmark and compare.

<a name="rom-specific"></a>
## 23. ROM-Specific Considerations

### MIUI / HyperOS
Most recent builds use EROFS (read-only filesystem) for `/vendor` — **recovery mode installation is impossible on EROFS, use module mode only.** Check: `adb shell cat /proc/mounts | grep vendor` — if output contains "erofs", use module mode. Recommended: `RENDER_MODE=normal`, `PLT=n` to avoid Play Integrity issues. Use "Fix Camera" preemptively as camera breakage is more common on MIUI.

### Samsung OneUI
Affects Game Launcher (may conflict) and Bixby Vision (may break). Test camera features thoroughly. The module auto-handles the Samsung Vulkan gate property and `same_process_hal_file` SELinux context for Samsung's library paths.

### ColorOS / RealmeUI
Has custom GPU profiles and aggressive memory management. May need `ARM64_OPT=n` even on pure 64-bit devices. Recommended: `RENDER_MODE=normal` for vsync_enhancer compatibility.

### FuntouchOS / OriginOS (Vivo)
OriginOS uses a proprietary UI rendering layer. If experiencing mounting issues on KernelSU: use `META_OVERLAYFS` metamodule. Recommended `RENDER_MODE=skiagl` for better compatibility with their rendering layer.

### OxygenOS (OnePlus)
Pure OxygenOS (pre-merger, AOSP-based) has no special issues. ColorOS-based OxygenOS — follow ColorOS recommendations above.

### Custom ROMs (LineageOS, Pixel Experience, etc.)
Best compatibility. Clean AOSP base with minimal modifications means the highest success rate and fewest broken features. Recommended platform for testing drivers.

<a name="render-mode-technical"></a>
## 24. RENDER_MODE Technical Details

### Render Mode Table

| Mode | HWUI renderer | SurfaceFlinger backend | Behavior |
|---|---|---|---|
| `normal` | System default | System default | No renderer override; module only replaces the driver binary. Safest. |
| `skiavk` | Skia + Vulkan | `skiavkthreaded` | Full Vulkan rendering pipeline. Best GPU utilization with the custom driver. |
| `skiagl` | Skia + OpenGL | `skiaglthreaded` | OpenGL rendering pipeline. Fallback for devices where Vulkan has issues. |
| `skiavk_all` | Skia + Vulkan | `skiavkthreaded` | Same as `skiavk` plus throttled force-stop of background apps at boot so every process cold-starts with the Vulkan renderer. |

### Why `skiavk_all` Force-Stops Apps

The HWUI renderer choice (`skiavk`/`skiagl`) is read once per process at first HWUI initialization and cached. Any app that started during early boot before the renderer property settled has the old renderer cached internally. Force-stopping such apps makes them restart cleanly with the correct renderer and driver. A 150ms throttle between kills prevents concurrent KGSL context teardown corruption.

### When to Use Each Mode

- **normal** — Use if you don't have a specific reason to change it. Maximum compatibility. Recommended for most users.
- **skiavk** — Try this on modern devices (2020+) with Adreno 6xx/7xx/8xx if you want Vulkan-accelerated UI rendering. Low risk. May improve FPS in apps/games.
- **skiagl** — Use only if you have rendering glitches, UI artifacts, or Vulkan compatibility issues. Forces OpenGL path.
- **skiavk_all** — Experimental. Only for benchmarking or when some apps still render incorrectly after a regular `skiavk` boot. Expect a slower first boot while all apps cold-start.

### Troubleshooting RENDER_MODE

- **skiavk causes graphics glitches:** Switch to `skiagl` or `normal`. Vulkan driver bug or incompatibility.
- **skiavk doesn't improve performance:** Revert to `normal`. Not all devices benefit.
- **Setting doesn't take effect:** Clear caches (WebUI → Utils → Clear GPU Cache), verify config was saved, reboot, and check `adb shell getprop debug.hwui.renderer`.

---

# PART 4: TROUBLESHOOTING & RECOVERY

<a name="complete-troubleshooting"></a>
## 25. Complete Troubleshooting Guide

### General Diagnostic Procedure

Before applying any fix:

```bash
# 1. Check module status
adb shell su -c "ls /data/adb/modules/adreno_gpu_driver_unified/"
# Look for: module.prop (required), disable (bad!), skip_mount (bad!)

# 2. Verify driver is actually mounted
adb shell ls -la /vendor/lib64/libGLESv2_adreno.so

# 3. Check for SELinux denials
adb shell dmesg | grep "avc:" | grep -iE "gpu|adreno|vendor" | head -20

# 4. Check boot logs
adb shell ls /sdcard/Adreno_Driver/Booted/
adb shell cat /sdcard/Adreno_Driver/Booted/postfs_*.log | tail -50

# 5. Check GPU is recognized
adb shell cat /sys/class/kgsl/kgsl-3d0/gpu_model
```

### Issue: Apps Crashing (Especially Keyboard/Gboard)

**Most likely cause on KernelSU:** No metamodule installed. Check:
```bash
adb shell ls /data/adb/modules/adreno_gpu_driver_unified/skip_mount
# If file exists → metamodule is missing
```
**Solution:** Install MetaMagicMount and reinstall this module.

### Issue: Hot Device / Battery Drain

Some driver versions enable more aggressive GPU frequency scaling. Try `RENDER_MODE=normal` if using skiavk/skiavk_all, try an older driver version, or disable QGL if enabled.

### Issue: WebUI Not Accessible

```bash
# Check if service.sh ran
adb shell ls /data/local/tmp/Adreno_Driver/webui_running

# Check port is listening
adb shell netstat -tlnp | grep 33641

# Manual WebUI restart
adb shell su -c "cd /data/adb/modules/adreno_gpu_driver_unified/webroot && busybox httpd -f -p 33641 -h . &"
```

### Issue: DRM Content Not Working (Netflix, Widevine L3)

**Cause:** `PLT=y` modifies `public.libraries.txt`, which Play Integrity detects as system tampering.
**Solution:** Open WebUI → Config → PLT Patching: OFF → Save → Reboot.

If still broken after disabling PLT:
```bash
adb shell su -c "rm /data/adb/modules/adreno_gpu_driver_unified/system/vendor/etc/public.libraries*.txt"
# Reboot
```

<a name="bootloop-recovery-all"></a>
## 26. Bootloop Recovery (All Methods)

### Method 1: Volume Button Recovery (Magisk — Easiest)

```
Requirement: Magisk anti-bootloop protection must be active

1. Power off device completely
2. Hold Power button to turn on
3. When boot logo appears → HOLD Volume Down
4. Keep holding until home screen loads
   (This disables ALL Magisk modules for this boot)
5. Open Magisk Manager
6. Modules tab → Find "Adreno GPU Driver"
7. Tap Disable toggle → Reboot
```

### Method 2: Recovery File Manager (Universal)

```
Works on: TWRP, OrangeFox, any recovery with file manager

1. Boot to custom recovery:
   Power off → Hold Power + Volume Up simultaneously
2. Recovery menu → Mount → Enable "Data" partition
3. File Manager → Navigate to: /data/adb/modules/
4. Locate folder: adreno_gpu_driver_unified
5. Long press → Delete
6. If using OverlayFS/KernelSU overlayfs, ALSO delete:
   /data/adb/modules.img (or modules_overlay.img)
7. Go back → Reboot → System
```

### Method 3: ADB Shell

```bash
# Must have enabled USB debugging BEFORE bootloop

# Option A: Delete module folder
adb shell su -c "rm -rf /data/adb/modules/adreno_gpu_driver_unified && reboot"

# Option B: Disable module (keeps files, disables loading)
adb shell su -c "touch /data/adb/modules/adreno_gpu_driver_unified/disable && reboot"
```

### Method 4: Safe Mode (Android Built-in)

```
1. Attempt to boot normally
2. When logo appears, hold Volume Down
3. If "Safe Mode" text appears in corner: modules disabled!
4. Remove module via Magisk Manager
5. Reboot normally
Note: Only works if Android can boot to safe mode
```

### Method 5: Fastboot Recovery (No Custom Recovery Required)

```bash
# If you can reach fastboot (Power + Volume Down during boot):
fastboot boot /path/to/your/stock_boot.img
# Boot from stock image → remove module via ADB
```

### Method 6: EDL/Deep Flash (Last Resort)

```
1. Enter EDL mode (Emergency Download Mode):
   Most Qualcomm devices: Power + Volume Up + Down simultaneously
2. Use QPST/QFIL or MiFlash to restore stock firmware
3. Guaranteed to work — requires OEM tools and firmware
```

### Post-Recovery Checklist

```
□ Clear shader caches: adb shell su -c "rm -rf /data/dalvik-cache/*"
□ If using KernelSU, verify MetaMagicMount is active before re-installing
□ Check bootloop diagnostic logs in /sdcard/Adreno_Driver/Bootloop/
□ Try a different driver version if driver incompatibility was the cause
□ Check kernel version compatibility (libdmabufheap.so etc.)
```

<a name="fix-camera"></a>
## 27. Camera Not Working

### Symptoms

| Symptom | Likely Cause |
|---------|-------------|
| Camera app crashes immediately | OpenCL library conflict |
| Camera opens but hangs/freezes | GPU data producer conflict |
| Camera works but no preview | LLVM compiler conflict |
| Camera works but photos are corrupted | Kernel compute layer conflict |

### Quick Fix (WebUI)

1. Open WebUI → Utils tab → **Fix Camera**
2. Confirm removal
3. Reboot device

### What Gets Removed

`libCB.so`, `libgpudataproducer.so`, `libkcl.so`, `libkernelmanager.so`, `libllvm-qcom.so`, `libOpenCL.so`, `libOpenCL_adreno.so`, `libVkLayer_ADRENO_qprofiler.so`

> **Note:** `libVkLayer_ADRENO_qprofiler.so` is the Adreno Vulkan profiler layer. On some OEM ROMs it is loaded by the camera HAL and causes camera failure with a custom driver active.

To restore these libraries, reflash the module ZIP.

### Manual Fix (ADB)

```bash
adb shell su -c "
MODLIB=/data/adb/modules/adreno_gpu_driver_unified/system/vendor/lib64
rm -f \$MODLIB/libOpenCL.so \$MODLIB/libOpenCL_adreno.so \$MODLIB/libCB.so
rm -f \$MODLIB/libkcl.so \$MODLIB/libkernelmanager.so
rm -f \$MODLIB/libgpudataproducer.so \$MODLIB/libllvm-qcom.so
rm -f \$MODLIB/libVkLayer_ADRENO_qprofiler.so
"
# Reboot
```

**Note:** If the camera was broken before installing the module, this fix will not help — it only addresses breakage caused by the module's own libraries.

### Android 16 QPR2 and Above — Storage Corruption Notice

On Android 16 QPR2 and above, some users have reported that removing OpenCL libraries can also resolve storage corruption issues. There are two ways to do this:

**Option A — Manual OpenCL removal** (removes only the OpenCL-specific compute libs):

Delete these files from the module overlay at `/data/adb/modules/adreno_gpu_driver_unified/system/vendor/lib64/`:

```
libOpenCL.so
libOpenCL_adreno.so
libCB.so
libkcl.so
libkernelmanager.so
libllvm-qcom.so
libgpudataproducer.so
```

**Option B — Quick Fix Camera** (WebUI → Utils → Fix Camera):

Removes a broader set of OpenCL and compute libraries:

```
libCB.so
libgpudataproducer.so
libkcl.so
libkernelmanager.so
libllvm-qcom.so
libOpenCL.so
libOpenCL_adreno.so
libVkLayer_ADRENO_qprofiler.so
```

> **Note on `libVkLayer_ADRENO_qprofiler.so`:** This is the Adreno Vulkan profiler layer. On some OEM ROMs (particularly MIUI/HyperOS, ColorOS, and similar) this library is loaded by the camera HAL and causes camera failure when a custom driver is active. Quick Fix Camera removes it to resolve those cases.

Both options can resolve storage corruption on affected devices. Option A is more conservative. Option B removes more and is the recommended one-tap solution. Reboot after either.

> ⚠️ **Disclaimer:** This applies only to a **small number of specific devices** on Android 16 QPR2 and above. It is **not a universal fix**. Do not remove these libraries expecting storage corruption to be resolved unless you have confirmed this issue on your specific device.

### Vendor GPU Files — Storage Corruption Prevention

Some devices may need to copy `vendor/gpu/` files from their own stock vendor partition into the driver flashing folder before flashing a custom driver. Skipping this step can cause storage corruption on affected devices.

> ⚠️ **Device-specific:** This is not required for all devices. Only do this if you encounter storage corruption after flashing, or if your device is known to require it. Pull the `vendor/gpu/` directory from your device's stock vendor image and place it in the driver flashing folder before flashing.

<a name="fix-screen-recorder"></a>
## 28. Screen Recorder Broken

### Symptoms

Screen recorder won't start, recording shows black screen, screenshots are corrupted, "Encoding failed" error after module installation.

### Quick Fix (WebUI)

Open WebUI → Utils tab → **Fix Screen Recorder** → Reboot.

### What Gets Removed

`libC2D2.so`, `libc2d30_bltlib.so`, `libc2dcolorconvert.so`

These C2D (Qualcomm 2D composition) libraries can break the system screen recorder on some devices/ROMs. To restore, reflash the module ZIP.

<a name="fix-night-mode"></a>
## 29. Night Mode Issues

### Symptom

Night mode / blue light filter / reading mode stopped working after installing the module.

### Quick Fix (WebUI)

Open WebUI → Utils tab → **Fix Night Mode** → Reboot.

### What Gets Removed

`libsnapdragon_color_manager.so` — this Snapdragon Color Manager library can prevent the display night mode from working. To restore, reflash the module ZIP.

<a name="fix-performance"></a>
## 30. Performance Problems

### Performance Worse Than Before

- Check `RENDER_MODE` — if `skiavk` was enabled, the Vulkan driver may not be well-tuned for your device. Try `normal`.
- Clear GPU caches (WebUI → Utils → Clear GPU Cache)
- Try an older or newer driver version — the "recommended" driver in the matrix is a starting point, not guaranteed best
- Check GPU thermals: `adb shell cat /sys/class/kgsl/kgsl-3d0/gpu_busy_percentage`

### Testing Driver Versions Systematically

1. Start with the compatibility matrix recommended version
2. Establish a benchmark baseline (3DMark Sling Shot Extreme, 3 runs averaged)
3. Test recommended version → benchmark
4. Step to next newer → benchmark
5. If worse, step to older → benchmark
6. Document all results — don't test randomly, systematic testing finds the best driver faster

<a name="fix-graphics-glitches"></a>
## 31. Graphics Glitches

### Visual Artifacts, UI Flickering, Corrupted Graphics

- If using `skiavk` or `skiavk_all`: switch to `skiagl` or `normal` — Vulkan driver bug on your device
- Clear GPU caches (WebUI → Utils → Clear GPU Cache)
- Try a different driver version
- Check for SELinux denials: `adb shell dmesg | grep "avc:" | grep -iE "gpu|adreno"`

### Screenshots or Screen Recordings Corrupted (Android 13+)

This is a known issue on newer Android versions. Try in order:
1. Fix Screen Recorder (WebUI)
2. Fix Camera (WebUI) — removes OpenCL libraries
3. Clear GPU caches
4. Try a different driver version
5. If nothing works → ROM incompatibility, use stock drivers

<a name="fix-module-not-loading"></a>
## 32. Module Not Loading

### Module Shows Enabled But Nothing Changed

**KernelSU:** Install MetaMagicMount or another metamodule first. Check for `skip_mount` file:
```bash
adb shell ls /data/adb/modules/adreno_gpu_driver_unified/skip_mount
```
If it exists, no metamodule was detected during installation.

**Magisk:** Ensure Magic Mount is enabled in Magisk settings. Check the module has no `disable` marker. Reboot.

**APatch:** Verify APatch version (0.10.8+ for built-in Magic Mount). Check mounting mode detection.

**For all:** If mounting verification passes but stock driver is still active, consider flashing via recovery mode to bypass overlay mounting entirely.

---

# PART 5: RECOVERY MODE INSTALLATION

<a name="recovery-mode-guide"></a>
## 33. Recovery Mode Complete Guide

Recovery mode installation copies driver files **directly into the vendor partition**. The changes are **permanent and cannot be easily reversed**. Only use this if you cannot use Magisk, KernelSU, or APatch.

<a name="recovery-risks"></a>
## 34. Understanding the Risks

| Risk | Module Mode | Recovery Mode |
|------|-------------|---------------|
| Reversible | ✅ Instantly | ❌ Requires vendor restore |
| Survives OTA | ✅ (mostly) | ❌ OTA wipes it |
| WebUI available | ✅ Yes | ❌ No |
| Can change settings | ✅ Yes | ❌ Must reflash |
| EROFS vendor | ✅ Works | ❌ Impossible |

**⚠️ Do NOT use recovery mode on devices with EROFS vendor partition.** Check: `adb shell cat /proc/mounts | grep vendor`. If it says "erofs" → use module mode only.

<a name="recovery-backups"></a>
## 35. Mandatory Backups

Before flashing in recovery mode, you MUST backup your vendor partition:

```bash
# Via TWRP
TWRP → Backup → Select "Vendor" → Swipe to backup

# Via ADB (if possible)
adb shell su -c "dd if=/dev/block/by-name/vendor of=/sdcard/vendor_backup.img"
```

Store this backup in a safe location (cloud/PC). Without it, you cannot reverse a recovery installation.

<a name="recovery-installation-steps"></a>
## 36. Step-by-Step Recovery Installation

1. **Edit config before flashing** — extract the ZIP on your PC, open `adreno_config.txt`, set your desired PLT/QGL/ARM64_OPT/RENDER_MODE values, save (UTF-8, no BOM), repack the ZIP
2. **Boot to custom recovery** (Power + Volume Up)
3. **Install the ZIP** — Advanced Wipe is NOT needed; just flash the ZIP
4. The installer auto-detects recovery mode, mounts `/vendor` read-write, copies all driver files directly, sets permissions, and applies config
5. **Reboot** — no WebUI will be available; settings cannot be changed without reflashing
6. **To uninstall**: restore your vendor backup, or dirty-flash your ROM

---

# PART 6: WEBUI MANAGER GUIDE

Open the WebUI from your root manager (Magisk / KernelSU / APatch) by tapping the module's web icon or using the KernelSU WebUI APK. The interface has four tabs: **Home**, **Config**, **Utils**, and **Data**.

---

<a name="webui-home"></a>
## 37. Home Tab

The landing screen. Shows your device at a glance.

**System Info panel** — displays device model, Android version, kernel, CPU/GPU identifiers, and the currently active Adreno driver version the module has mounted.

**Render Status panel** — shows the live values of the three renderer properties:
- `debug.hwui.renderer` — which rendering pipeline each app uses (e.g. `skiavk`, `skiagl`, or system default)
- `debug.renderengine.backend` — SurfaceFlinger's compositor backend (`skiavkthreaded`, `skiaglthreaded`, or default)
- `ro.hwui.use_vulkan` — whether Vulkan is enabled at the system level

The status panel refreshes on load and reflects the real running state, not just what the config says.

---

<a name="webui-config"></a>
## 38. Config Tab

Where you choose how the module configures the graphics stack.

### Render Mode

Four options:

| Mode | What it does |
|---|---|
| **Normal** | No renderer override. Module only swaps the driver binary. Safest fallback. |
| **skiavk** | Sets HWUI to Skia+Vulkan and SurfaceFlinger to `skiavkthreaded`. Best GPU performance with the custom driver. |
| **skiagl** | Sets HWUI to Skia+OpenGL and SurfaceFlinger to `skiaglthreaded`. Use if Vulkan causes issues on your device. |
| **skiavk_all** | Same as skiavk but also force-stops all third-party background apps at boot so they cold-start fresh with the Vulkan renderer. More thorough — use if some apps still render incorrectly after a skiavk boot. |

### Applying Changes

**Apply Now** — injects props immediately via `resetprop` without rebooting. Apps that are already running have the renderer cached internally, so kill and reopen them to pick up the change. Safe props are applied live; `debug.renderengine.backend` is excluded from live apply (it is handled pre-boot by the module to avoid OEM ROM crash callbacks).

**Save & Reboot** — writes props to the module's persistent `system.prop` and reboots. On next boot every process, including SystemUI, initialises with the correct renderer from the very first frame. Use this for a clean, fully consistent state.

> **Tip:** Use *Apply Now* to test a mode first. If everything looks good, use *Save & Reboot* to make it permanent.

### QGL Config

Opens the **QGL Editor** — a text editor for the Qualcomm Graphics Library JSON config file (`qgl_config.txt`). This file controls low-level GPU memory allocation, command buffer sizes, and pipeline compilation behaviour.

- **Format** — auto-indents the JSON for readability.
- **Reset** — reverts to the backed-up default (created automatically on first save).
- **Save** — writes your changes to both the module directory and `/sdcard/Adreno_Driver/qgl_config.txt`. Takes effect on next reboot.

> Only edit this if you know what specific QGL keys do. Wrong values can cause GPU hangs or crashes. The Reset button always brings back the original default.

---

<a name="webui-utils"></a>
## 39. Utils Tab

Troubleshooting and driver manipulation tools.

### GPU Spoofer

Makes the GPU driver report a different Adreno model number to apps and games. Useful when a game has a whitelist tied to specific GPU model IDs and your device's model is not on it, or when you want to test compatibility under a different reported GPU.

**How to use:**
1. Tap **Scan** — reads all `libgsl.so` files inside the module and lists every Adreno model ID found
2. **Select Source** — pick the model currently in the binary (what your GPU actually is)
3. **Enter Target** — type the model ID you want the driver to report instead
4. Tap **Apply Spoof**

**Safety rules the tool enforces automatically:**
- Source and target must have the **same digit count** (3-digit or 4-digit). Mismatched lengths would corrupt the ELF file and cause a bootloop. The tool blocks this.
- A backup of the original `libgsl.so` is saved to `/sdcard/Adreno_Driver/Backup/lib/` and `/Backup/lib64/` the first time you spoof. Subsequent spoofs never overwrite that backup.
- Backups are stored on `/sdcard/`, never inside the module's system directory.

> ⚠️ Reboot required after spoofing for the change to take effect.

### Restore Original

Restores the factory `libgsl.so` from the backup created by the spoofer. Only available after at least one spoof has been applied. Requires a reboot after restoring.

### Camera Fix

Removes specific OpenCL and compute libraries from the module overlay that are known to break camera on some devices/ROMs: `libCB.so`, `libgpudataproducer.so`, `libkcl.so`, `libkernelmanager.so`, `libllvm-qcom.so`, `libOpenCL.so`, `libOpenCL_adreno.so`, `libVkLayer_ADRENO_qprofiler.so`.

`libVkLayer_ADRENO_qprofiler.so` is the Adreno Vulkan profiler layer — on some OEM ROMs this library is loaded by the camera HAL and causes camera failure when a custom driver is active.

Use this if your camera app crashes or fails to open after installing the module. If the camera was broken before installing the module, this won't help. Reflash the module to restore these libraries.

### Screen Recorder Fix

Removes C2D libraries that can break the system screen recorder: `libC2D2.so`, `libc2d30_bltlib.so`, `libc2dcolorconvert.so`. Use if the stock screen recorder crashes or produces corrupt output. Reflash to restore.

### Night Mode Fix

Removes `libsnapdragon_color_manager.so` that can prevent Night Mode from working. Use if Night Mode / Reading Mode stopped working after installing the module. Reflash to restore.

### Clear GPU Cache

Deletes the system HWUI shader cache (`/data/misc/hwui/`) and per-app Skia pipeline caches. Useful after switching render modes manually or if you're seeing rendering glitches from stale cached shaders.

The module clears these automatically when it detects a mode change at boot, so you normally don't need to do this manually.

---

<a name="webui-data"></a>
## 40. Data Tab

Logs and statistics.

### Statistics

Shows three counters tracked across all sessions:
- **Configs** — number of times you've saved a configuration change
- **Fixes** — number of times a fix tool (Camera / Recorder / Night Mode) has been applied
- **Spoofs** — number of GPU spoofs applied

### Boot Logs

Lists log files from `/sdcard/Adreno_Driver/Booted/` and `/Bootloop/`. Each file corresponds to one boot cycle.

- **Booted/** — logs from boots that reached `boot_completed` successfully. File names include the timestamp and active render mode.
- **Bootloop/** — logs from boots that did not complete. Useful for diagnosing driver compatibility issues.

Tap a log entry to view its full contents. Use **Export** to copy or share the selected log file.

### Auto-Backup Info

All settings are automatically saved to `/sdcard/Adreno_Driver/Config/adreno_config.txt`. This file survives module updates, reinstalls, and reboots.

To fully reset your configuration: navigate to `/sdcard/Adreno_Driver/Config/`, delete `adreno_config.txt`, and reinstall the module.

---

<a name="webui-custom-tools"></a>
## 41. Custom Driver Tools (Advanced)

Accessible from the Config tab's advanced section. These tools operate on driver files you provide — not the module's active driver.

### Custom GPU Spoof

Spoofs model IDs inside **any `libgsl.so` file you provide** — not just the one currently in the module. Point it at a driver file on your `/sdcard/` to modify it before flashing.

> ⚠️ **Never point this at `/vendor/` or `/system/` directly.** Modifying a live system library while Android is running will cause a bootloop. Always copy the driver file to `/sdcard/` first, then spoof it there.
>
> ⚠️ **Never mix a spoofed `libgsl.so` with a different driver.** `libgsl.so` is tightly coupled to the rest of the driver package it came from. Using it with any other driver will bootloop.

After spoofing, flash the modified file via your root manager — do not simply reboot without flashing.

---

<a name="webui-language-theme"></a>
## 42. Language & Theme

The UI supports English, Simplified Chinese, and Traditional Chinese as built-in options. You can also auto-translate the entire interface into any other language via the language selector — the tool uses the Claude API to generate a translation and saves it locally for future sessions. Documentation (README) can be translated separately with the **Translate Docs** option.

A theme picker (🎨) lets you change the UI accent colour. Selection is saved automatically to your configuration and persists across sessions.

---

<a name="webui-terminal"></a>
## 43. Terminal Log

A scrollable terminal panel (visible on every tab) streams real-time output from all operations — prop applications, cache clears, spoof results, QGL saves, and errors. Colour-coded: green = success, yellow = warning, red = error, white = info. Useful for verifying what the module actually did and for diagnosing failures.

---

# PART 7: APPENDIX

<a name="faq"></a>
## 44. Frequently Asked Questions (FAQ)

**Q: Will this work on my device?**

The module works on any Android device with a Qualcomm Adreno GPU (the sysfs path `/sys/class/kgsl/kgsl-3d0/` must exist), Android 11+, ARM64 architecture, and root via Magisk/KernelSU/APatch (or custom recovery for permanent install). Devices with Exynos, MediaTek, or other non-Adreno GPUs are **not supported**.

---

**Q: How do I know which GPU model my device has?**

```bash
adb shell cat /sys/class/kgsl/kgsl-3d0/gpu_model
```

Alternatively, use the DevCheck app from the Play Store (free), or check your Snapdragon chipset specs — every Snapdragon has a known Adreno GPU model.

---

**Q: Which driver version should I use?**

Start with the recommended version in the compatibility matrix (Section 21) for your GPU. If it causes issues, step down one version at a time. There is no universal "best" version — it depends on your specific device, ROM, and kernel version.

---

**Q: Can I use this on a stock (non-rooted) ROM?**

Not with the module method. However, recovery mode installation (Section 33) works if you have custom recovery (TWRP/OrangeFox), even without Magisk/KernelSU. Recovery mode is permanent and harder to reverse.

---

**Q: Will this survive a ROM update (OTA)?**

Module mode: Yes, mostly — module files persist in `/data/adb/modules/` which most OTAs don't touch. However, if the OTA updates GPU libraries that conflict with the module's files, you may need to reinstall after the OTA.

Recovery mode: No — OTA updates restore the stock vendor partition, wiping your installed custom drivers. You must reflash after every OTA.

---

**Q: Does this work with MIUI/HyperOS?**

Yes, with caveats. Most recent HyperOS builds use EROFS — use module mode only, not recovery mode. Disable PLT patching to avoid Play Integrity issues. See Section 23.

---

**Q: KernelSU says module is active but GPU driver didn't change — why?**

KernelSU requires a **metamodule** (mounting helper module) to work. Install **MetaMagicMount** (recommended), Meta-Mountify, or Meta-OverlayFS FIRST, then reinstall this GPU driver module. See Section 32.

---

**Q: Can I use this on a Samsung phone with both Snapdragon and Exynos variants?**

Only on the **Snapdragon variant**. US and some international Samsung models use Snapdragon with Adreno GPUs and are fully compatible. International variants (Korean, European) use Exynos with ARM Mali GPUs — completely different GPU architecture, this module does not apply.

---

**Q: What's the actual benefit of updating GPU drivers on a phone?**

Benefits can include: newer Vulkan extensions for better graphics quality in some games, bug fixes for rendering issues in older drivers, performance improvements in specific workloads, and compatibility with newer games requiring more recent GPU feature sets. Results are **device-dependent and unpredictable**. Testing is always required.

---

**Q: Will this improve my gaming performance?**

Possibly, but not guaranteed. Benchmark before and after using identical conditions. For many users the improvement is marginal (0–5% FPS). Some users with older drivers on mid-range GPUs see more substantial gains in Vulkan titles.

---

**Q: What does RENDER_MODE do? Which should I use?**

- **normal** — Use this if you don't have a specific reason to change it. Maximum compatibility.
- **skiavk** — Try this if you want Vulkan-accelerated UI rendering and your ROM supports it. Low risk.
- **skiagl** — Use only if you have rendering glitches with the default mode.
- **skiavk_all** — Experimental. Only for benchmarking or if apps still render incorrectly after a regular `skiavk` boot.

For gaming specifically, RENDER_MODE affects the **system UI renderer**, not in-game rendering. Games use their own Vulkan/OpenGL paths directly.

---

**Q: Is PLT patching required for Bench++/Zuras benchmark?**

Yes. The Bench++ benchmark requires `gpu++.so` to be listed in `public.libraries.txt`. Without `PLT=y`, the benchmark may run but will report lower scores. Enable `PLT=y` for benchmarking, then consider disabling if you don't want the system modification permanently.

---

**Q: My camera still works after installing. Is that normal?**

Yes, completely normal. Camera issues are **not universal** — they depend on your specific driver version and device. Many driver versions don't install the conflicting OpenCL/camera libraries. If your camera works, leave it alone.

---

**Q: Can two different GPU driver versions be installed simultaneously?**

No. Only one driver version can be active at a time. Uninstall the current module and install a new one to switch versions.

---

**Q: What happens to existing data when I install/uninstall this module?**

Installing the module does not touch any user data or apps. Uninstalling removes only the driver overlay — all app data, cache, and settings are preserved. Configuration is backed up to `/sdcard/Adreno_Driver/Config/` automatically.

---

**Q: Community Wisdom — what do experienced users recommend?**

1. Start conservative: module mode, default settings, recommended driver version
2. Test one change at a time — don't enable PLT, QGL, ARM64_OPT all at once
3. Keep detailed notes: which drivers you tried, what worked, benchmark scores
4. Know when to quit: if 3+ drivers don't work → ROM incompatibility, accept stock drivers might be best
5. Share your findings on XDA or Telegram to help others with the same device

<a name="glossary"></a>
## 45. Glossary of Terms

| Term | Definition |
|---|---|
| **Adreno** | Qualcomm's brand name for their GPU lineup |
| **GPU Driver** | Software that controls how the GPU processes graphics commands |
| **HWUI** | Hardware UI — Android's hardware-accelerated user interface rendering system |
| **SurfaceFlinger** | Android's display compositor — assembles all window surfaces into the final screen image |
| **SELinux** | Security-Enhanced Linux — Android's mandatory access control system |
| **Magic Mount** | Magisk's system for overlaying files onto the file system without modifying partitions |
| **OverlayFS** | Linux filesystem overlaying mechanism, alternative to Magic Mount |
| **Metamodule** | A KernelSU helper module that provides the file mounting capability that KernelSU lacks natively |
| **PLT** | Public Libraries Text — `public.libraries.txt` files that list libraries apps are allowed to load |
| **QGL** | Qualcomm Graphics Library — internal Qualcomm system for GPU configuration tuning |
| **Vulkan** | Low-overhead, explicit 3D graphics API — more efficient than OpenGL on modern GPUs |
| **Skia** | Android's 2D graphics library — used by HWUI to render UI elements |
| **skiavk** | Skia rendering with Vulkan backend |
| **skiagl** | Skia rendering with OpenGL ES backend |
| **Shader Cache** | Pre-compiled GPU programs that apps store for faster rendering on subsequent launches |
| **KGSL** | Kernel Graphics Support Layer — the Linux kernel driver for Adreno GPUs |
| **EROFS** | Extents Read-Only File System — compressed read-only filesystem used in newer ROMs |
| **bootloop** | A state where the device restarts continuously before fully booting |
| **resetprop** | Magisk tool for modifying read-only system properties at runtime |

<a name="credits"></a>
## 46. Credits & Acknowledgments

- **Module Developer:** @pica_pica_picachu
- **Contact:** Telegram @zesty_pic
- **Documentation:** Generated and maintained with assistance from Claude AI

Special thanks to the Adreno driver modding community for driver compatibility testing data, the Magisk/KernelSU/APatch teams for their excellent root frameworks, and all users who contributed bootloop reports and compatibility findings.

<a name="license"></a>
## 47. License & Disclaimer

**USE AT YOUR OWN RISK.**

- This module modifies critical system GPU driver files
- No warranty is provided, express or implied
- The developer is not responsible for bricked devices, lost data, broken features, or any other damage
- Always backup before installing
- Test on a secondary device if possible before trusting on a daily driver
- Driver files included are property of Qualcomm Technologies, Inc.

*Documentation may contain inaccuracies. Verify critical information independently.*

---

*END OF DOCUMENTATION*
