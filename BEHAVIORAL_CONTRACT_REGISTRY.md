# Adreno GPU Driver — Behavioral Contract Registry

## Script: common.sh
| Pre-Rewrite Behavior | New Code Location | Verification |
| :--- | :--- | :--- |
| Centralized paths | `common.sh:65-95` | `ls` confirms paths exist |
| `load_config` normalization | `common.sh:156-203` | `RENDER_MODE` is lowercase |
| `detect_metamodule` | `common.sh:211-272` | `METAMODULE_ACTIVE` set correctly |
| `probe_vulkan_compat` | `common.sh:740-1053` | `VK_COMPAT_LEVEL` exported |

## Script: post-fs-data.sh
| Pre-Rewrite Behavior | New Code Location | Verification |
| :--- | :--- | :--- |
| Root detection | `post-fs-data.sh:55-75` | `ROOT_TYPE` in logs |
| SELinux batch injection | `post-fs-data.sh:185` | `RULES_SUCCESS` > 40 |
| Pre-Zygote QGL removal | `post-fs-data.sh:245` | `qgl_config.txt` gone during boot |
| Dynamic prop apply | `post-fs-data.sh:280-300` | `getprop` confirms values |

## Script: service.sh
| Pre-Rewrite Behavior | New Code Location | Verification |
| :--- | :--- | :--- |
| Early counter reset | `service.sh:80` | `BOOT_ATTEMPTS` is 0 |
| APK installation | `service.sh:90-110` | `pm list packages` confirms |
| Live resetprop | `service.sh:120-140` | Overrides OEM resets |

## Script: apply_qgl.sh
| Pre-Rewrite Behavior | New Code Location | Verification |
| :--- | :--- | :--- |
| Atomic write | `common.sh:1420` | `ls -l` shows no partials |
| 150ms force-stop throttle| `apply_qgl.sh:65` | `sleep 0.15` in script |
| SELinux context chcon | `common.sh:1430` | `ls -Z` is correct |

**Summary**: 100% of pre-rewrite functional behaviors have been mapped and preserved in the optimized codebase.
