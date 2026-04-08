# Adreno GPU Driver — Meta Module Compatibility Registry

## Known Meta Modules

| Module Name | ID | Detection Method |
|-------------|----|------------------|
| MetaMagicMount | `MetaMagicMount` | Directory presence |
| Meta-OverlayFS | `meta-overlayfs` | Directory presence |
| Meta-Hybrid | `meta-hybrid` | Directory presence |
| Mountify | `Mountify` | Directory presence |
| Magic Mount Companion | `magic_mount` | Directory presence |

## Detection Strategy

### Race-Free Detection (Fix D)
The module identifies meta modules by checking the `/data/adb/modules/` directory for the presence of known IDs and the `metamodule=1` flag in `module.prop`. This check occurs before `post-fs-data` execution, ensuring that `skip_mount` is only created when truly necessary.

### Compatibility Pass
- **Magisk**: Works with standard Magic Mount.
- **KernelSU**: Works in both Magic Mount and OverlayFS modes (with metamodule).
- **APatch**: Works in both modes.

## Verification Protocol
1. Install a supported meta module.
2. Boot the device.
3. Check `/data/local/tmp/Adreno_Driver/Booted/boot_*.log` for "Metamodule Active: true".
4. Verify that `$MODDIR/skip_mount` does NOT exist.
