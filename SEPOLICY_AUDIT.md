# Adreno GPU Driver — SELinux Policy Audit

## Rule Audit & Categorization

| Rule | Purpose | OEM Risk | Decision | Citation |
| :--- | :--- | :--- | :--- | :--- |
| `allow hal_graphics_composer_default gpu_device chr_file ...` | Core GPU access | Low | Batch | AOSP `hal_graphics_composer` |
| `allow appdomain same_process_hal_file file ...` | Load custom driver | Low | Batch | AOSP `same_process_hal` |
| `allow domain vendor_firmware_file dir search` | Firmware access | **High (OneUI)** | Individual | Samsung OneUI neverallow |
| `allow domain firmware_file file read` | Firmware access | **High (MIUI)** | Individual | MIUI neverallow |
| `allow vendor_init self capability { chown fowner }` | Directory setup | **High (Knox)** | Individual | Samsung Knox neverallow |
| `allow domain logd unix_stream_socket connectto` | Logging | **High (ColorOS)** | Individual | ColorOS neverallow |
| `allow ksu same_process_hal_file ...` | KSU-Next access | Low | Batch | KSU-Next domain |

## Injection Strategy

### Batch 1 (Core & OEM-Safe)
Contains 40+ rules for GPU HALs, surfaceflinger, and standard app domains. Confirmed safe on AOSP and most OEM ROMs.

### Batch 2 (Android 16 QPR2 allowxperm)
Consolidates `allowxperm` rules for IOCTL ranges. Silently ignored on pre-Android 16 kernels.

### Individual (Silent-Fail)
Contains the High Risk rules identified above. These are injected one-by-one with `|| true` to prevent a single neverallow conflict from poisoning the entire core batch.

## Metrics
- Target `magiskpolicy` spawns: 1 (Primary Batch) + 1 (allowxperm) + 6 (Individual) = 8 total.
- Current spawns: 8 (Meets target ≤ 10).
