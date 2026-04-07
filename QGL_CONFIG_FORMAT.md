# QGL Config Format Authorization Document

## Authoritative Source
- **Bylaws Gist**: `https://gist.github.com/bylaws/04130932e2634d1c6a2a9729e3940d60`

## File Locations
The Adreno Vulkan driver probes these locations in order:
1. `/data/vendor/gpu/qgl_config.txt`
2. `/data/misc/gpu/qgl_config.txt`

The module primary target is `/data/vendor/gpu/qgl_config.txt`.

## Syntax
- **Comments**: Start with `;`.
- **Assignment**: `key=value`, `key\nvalue`, or `key\rvalue` are all valid and equivalent.

## Key Format & Hashing (SDM845+ / Adreno 630+)
On SDM845 and newer SoCs, the driver internally uses hashed keys.

### Backward Compatibility
To use human-readable strings on SDM845+ devices, the following magic line **MUST** be at the top of the file:
```
0x0=0x8675309
```
Without this line, human-readable keys are silently ignored by the driver on modern GPUs.

### Hash Functions
- **SDM845+ (Current)**:
  ```cpp
  uint32_t state{0x425534b3};
  for (char c : string) {
    uint32_t c_uint = c;
    uint32_t c_lower = c_int | 0x20;
    if (0x19 < (c_uint - 0x41)) lower = c_int;
    state = c_lower ^ (state >> 0x1b | state << 0x5);
  }
  return state;
  ```
- **MSM8998**: Simple rolling XOR with `tolower`.
- **MSM8996**: XOR rolling with shift.

## Critical Settings
- `enableshaderlog=True`: **DANGER**. Dumps IR/optimization info. Creates massive files. Disable in production.
- `enablebinlog=True`: **DANGER**. Dumps binary timelines. Disable in production.
- `shadersubstitution`: Enables shader replacement.
- `debugTracingGroupsEnabled`: atrace category mask.
- `debugPrintGroupsEnabled`: debug print category mask.

## Valid Settings (Bruteforced List)
Common valid keys identified:
- `cpucount`
- `forcepunt`
- `depthclamp`
- `depthbounds`
- `shaderint64`
- `shaderint16`
- `shadersubstitution`
- `subgroupsize`
- `maxsamples`
- `multiviewmode`
- `tessellationshader`
- `preemptionstyle`
- `sparsebinding`
- `gputype`

## Module Application
1. **Always include `0x0=0x8675309`** in `qgl_config.txt` and generated per-app profiles to ensure compatibility across all Adreno 6xx/7xx/8xx devices.
2. Ensure **SELinux context** is `u:object_r:same_process_hal_file:s0` for both the file and the directory `/data/vendor/gpu`.
3. Use **atomic writes** (temp file -> rename) to prevent driver reads of partial files.
