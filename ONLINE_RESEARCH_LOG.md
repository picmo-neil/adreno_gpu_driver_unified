# Adreno GPU Driver — Online Research Log

## RESEARCH ENTRY [1]:
- **Query**: "Found hole in prop area" Android source
- **Sources consulted**: `https://android.googlesource.com/platform/system/core/+/refs/heads/main/init/property_service.cpp`
- **Finding**: "Found hole in prop area" is logged by `PropertyService` when `prop_area::add` fails to find contiguous space or the area is full. This indicates fragmentation or exhaustion of the 128KB `PA_SIZE`.
- **Applied to**: Fix B, `system.prop`. Decision to reduce static props to <15.

## RESEARCH ENTRY [2]:
- **Query**: "ro.zygote.disable_gl_preload" Adreno driver
- **Sources consulted**: AOSP `frameworks/base/core/java/com/android/internal/os/ZygoteInit.java`
- **Finding**: Zygote checks this property to skip early driver preloading. In a module context, preloading happens BEFORE the bind-mount is active, leading to the stock driver being loaded.
- **Applied to**: Architecture Invariant 8. Prop MUST be preserved in `system.prop`.

## RESEARCH ENTRY [3]:
- **Query**: "magiskpolicy --apply" batch failure OEM
- **Sources consulted**: GitHub issues for Magisk/KernelSU regarding OneUI/MIUI neverallows.
- **Finding**: If a batch contains a rule that violates a `neverallow`, the entire batch is rejected. OneUI has strict neverallows on `vendor_firmware_file` read for app domains.
- **Applied to**: Fix C, `post-fs-data.sh`. Moved firmware and Knox rules to individual silent-fail.

## RESEARCH ENTRY [4]:
- **Query**: "qgl_config.txt" format Qualcomm
- **Sources consulted**: `https://gist.github.com/bylaws/04130932e2634d1c6a2a9729e3940d60`
- **Finding**: SDM845+ drivers require hashed keys unless `0x0=0x8675309` is present.
- **Applied to**: Fix F, `apply_qgl.sh` and `boot-completed.sh`.
