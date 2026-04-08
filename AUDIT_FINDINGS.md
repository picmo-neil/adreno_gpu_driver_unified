# Adreno GPU Driver — Audit Findings

## Finding 1: Property Area Overflow
- **Severity**: CRITICAL
- **Root Cause**: The module was writing over 60 dynamic tuning properties to `system.prop`. Combined with OEM properties, this exceeded the contiguous space in the 128KB property area, causing "Found hole in prop area" errors and silent property failures.
- **Fix**: Trimmed `system.prop` to 10 critical boot-time properties. Moved all other tuning to `resetprop` in `post-fs-data.sh`.
- **Verification**: `dmesg | grep -i "hole in prop"` is empty after boot.

## Finding 2: Metamodule Detection Race Condition
- **Severity**: HIGH
- **Root Cause**: The module relied on a runtime marker written by metamodules during `post-fs-data`. Since execution order is not guaranteed, the module often failed to detect the metamodule, incorrectly creating a `skip_mount` file and breaking functionality.
- **Fix**: Implemented race-free detection by checking `/data/adb/modules/` for known metamodule IDs and the `metamodule=1` flag in `module.prop` before execution.
- **Verification**: `skip_mount` is no longer created when a metamodule is present.

## Finding 3: QGL Configuration Key Format
- **Severity**: MEDIUM
- **Root Cause**: Bylaws Gist research confirmed that SDM845+ (Adreno 630+) drivers use hashed keys. Human-readable names are ignored unless the `0x0=0x8675309` magic line is present.
- **Fix**: Added the mandatory backward-compatibility line to all QGL config writes.
- **Verification**: QGL extensions are confirmed active in Vulkan caps on SDM845+ devices.

## Finding 4: Insecure Boot Counter Reset
- **Severity**: HIGH
- **Root Cause**: `BOOT_ATTEMPTS` was only reset at the very end of `service.sh`. If the script was killed early by a watchdog, the counter persisted, eventually causing a false-positive auto-disable.
- **Fix**: Implemented an early reset in `service.sh` as soon as `sys.boot_completed=1` is confirmed.
- **Verification**: Module remains enabled across multiple successful boots with forced service interruptions.

## Finding 5: Non-Atomic QGL Writes
- **Severity**: LOW
- **Root Cause**: `apply_qgl.sh` was writing directly to the target file. A crash during write could leave the driver with a partial or empty config.
- **Fix**: Implemented `tmp file -> mv` atomic write pattern.
- **Verification**: `ls -l` shows the file is always complete or original.
