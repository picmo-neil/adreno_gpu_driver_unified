#!/system/bin/sh
# ============================================================
# ADRENO DRIVER MODULE — SHARED FUNCTIONS
# ============================================================
#
# Developer  : @pica_pica_picachu
# Channel    : @zesty_pic (driver channel)
#
# ⚠️  ANTI-THEFT NOTICE ⚠️
# This module was developed by @pica_pica_picachu.
# If someone claims this as their own work and asks for
# donations — report them immediately to @zesty_pic.
#
# ============================================================
#
# Source with: . "$MODDIR/common.sh"

# Single-pass config loader. Reads file once, extracts and normalises all 5 variables.
load_config() {
  local cfg="$1" _k _v
  [ -f "$cfg" ] || return 1
  while IFS='= ' read -r _k _v; do
    # Skip blank lines and comments
    case "$_k" in '#'*|'') continue ;; esac
    # Strip carriage return from value (Windows line endings)
    _v="${_v%$'\r'}"
    # Normalise boolean keys
    case "$_k" in
      VERBOSE|ARM64_OPT|QGL|PLT|GAME_EXCLUSION_DAEMON|FORCE_SKIAVKTHREADED_BACKEND)
        case "$_v" in
          [Yy]|[Yy][Ee][Ss]|1|[Tt][Rr][Uu][Ee]) _v='y' ;;
          *) _v='n' ;;
        esac ;;
      RENDER_MODE)
        case "$_v" in
          # Canonical values — pass through as-is
          normal|skiavk|skiagl|skiavk_all) ;;
          [Nn][Oo][Rr][Mm][Aa][Ll])            _v='normal' ;;
          [Ss][Kk][Ii][Aa][Vv][Kk])            _v='skiavk' ;;
          [Ss][Kk][Ii][Aa][Gg][Ll])            _v='skiagl' ;;
          [Ss][Kk][Ii][Aa][Vv][Kk]_[Aa][Ll][Ll]) _v='skiavk_all' ;;
          # Legacy: skiavkthreaded/skiaglthreaded were removed as separate modes.
          # renderengine.backend is now folded into skiavk/skiavk_all/skiagl.
          # Use FORCE_SKIAVKTHREADED_BACKEND=y to force skiavkthreaded backend.
          [Ss][Kk][Ii][Aa][Vv][Kk][Tt][Hh][Rr][Ee][Aa][Dd][Ee][Dd]) _v='skiavk' ;;
          [Ss][Kk][Ii][Aa][Gg][Ll][Tt][Hh][Rr][Ee][Aa][Dd][Ee][Dd]) _v='skiagl' ;;
          *) _v='normal' ;;
        esac ;;
    esac
    case "$_k" in
      VERBOSE)     VERBOSE="$_v" ;;
      ARM64_OPT)   ARM64_OPT="$_v" ;;
      QGL)         QGL="$_v" ;;
      PLT)         PLT="$_v" ;;
      RENDER_MODE) RENDER_MODE="$_v" ;;
      GAME_EXCLUSION_DAEMON) GAME_EXCLUSION_DAEMON="$_v" ;;
      FORCE_SKIAVKTHREADED_BACKEND) FORCE_SKIAVKTHREADED_BACKEND="$_v" ;;
    esac
  done < "$cfg"
}

# Canonical metamodule ID list — unified across all scripts.
_METAMODULE_IDS="meta_overlayfs meta-overlayfs meta-magic-mount meta-magicmount MetaMagicMount \
meta-mm metamm meta-mountify metamountify MetaMountify \
magic_mount overlayfs_module \
meta-hybrid meta-hybrid-mount meta_hybrid_mount MetaHybrid \
ksu_overlayfs overlayfs-ksu ksu-mm ksumagic meta-ksu-overlay \
MKSU_Module mksu_module \
meta-apatch meta-ap apatch-overlay apatch-mount meta_apatch_overlay apatch-mm"

# Sets METAMODULE_ACTIVE, METAMODULE_NAME, METAMODULE_ID.
detect_metamodule() {
  METAMODULE_ACTIVE=false
  METAMODULE_NAME=""
  METAMODULE_ID=""

  if [ -L "/data/adb/metamodule" ]; then
    META_LINK=$(readlink -f "/data/adb/metamodule" 2>/dev/null)
    if [ -n "$META_LINK" ] && [ -f "$META_LINK/module.prop" ] && \
       [ ! -f "$META_LINK/disable" ] && [ ! -f "$META_LINK/remove" ]; then
      while IFS='=' read -r _mk _mv; do
        case "$_mk" in
          id)   METAMODULE_ID="${_mv%$'\r'}" ;;
          name) METAMODULE_NAME="${_mv%$'\r'}" ;;
        esac
      done < "$META_LINK/module.prop" 2>/dev/null
      METAMODULE_ACTIVE=true
      return 0
    fi
  fi

  if [ -d "/data/adb/modules" ]; then
    for meta_id in $_METAMODULE_IDS; do
      mod_dir="/data/adb/modules/$meta_id"
      if [ -d "$mod_dir" ] && [ ! -f "$mod_dir/disable" ] && \
         [ ! -f "$mod_dir/remove" ] && [ -f "$mod_dir/module.prop" ]; then
        METAMODULE_ID="$meta_id"
        METAMODULE_NAME="$meta_id"
        while IFS='=' read -r _mk _mv; do
          case "$_mk" in name) METAMODULE_NAME="${_mv%$'\r'}"; break ;; esac
        done < "$mod_dir/module.prop" 2>/dev/null
        METAMODULE_ACTIVE=true
        return 0
      fi
    done
  fi

  if [ -d "/data/adb/modules/.meta" ]; then
    METAMODULE_ACTIVE=true
    METAMODULE_NAME=".meta (legacy)"
    METAMODULE_ID=".meta"
    return 0
  fi

  return 1
}

# ============================================================
# detect_old_vendor_extended()
# ============================================================
# Detects all direct-causation "old vendor" mechanisms that
# silently override debug.hwui.renderer and kill skiavk.
#
# Based on confirmed AOSP property load order (Android 10+):
#   1. /system/build.prop         (our system.prop lives here)
#   2. /system_ext/build.prop
#   3. /vendor/build.prop         ← loads AFTER system, WINS
#   4. /odm/build.prop            ← loads AFTER vendor, WINS over both
#      /odm/etc/build.prop        (modern path since Android 10)
#      /vendor/odm/etc/build.prop (fallback when no physical odm partition)
#   5. /product/build.prop        ← loads last, WINS over everything
#
# RC file loading order (/{system,system_ext,vendor,odm,product}/etc/init/):
#   vendor/etc/init/ fires AFTER system; odm/etc/init/ fires AFTER vendor.
#   on-property triggers (on property:sys.boot_completed=1) run asynchronously
#   AFTER boot_completed, which is AFTER Magisk service.sh boot+2s resetprop.
#
# Only direct-causation criteria are used — no SDK deltas, VNDK, or dates.
# Those are circumstantial. Only criteria where a specific file or value
# directly causes debug.hwui.renderer to be overridden are included.
#
# Sets these variables (all guaranteed to be set on return):
#   OLD_VENDOR          — true/false
#   OLD_VENDOR_REASON   — semicolon-joined human-readable causes (empty if clean)
#   VENDOR_HWUI_PROP    — value found in any build.prop, or "" if none
#   VENDOR_RC_OVERRIDE  — path of first offending init.rc file, or ""
#   VENDOR_SCRIPT_OVERRIDE — path of first offending post-boot shell script, ""
# ============================================================
detect_old_vendor_extended() {
  OLD_VENDOR=false
  OLD_VENDOR_REASON=""
  VENDOR_HWUI_PROP=""
  VENDOR_RC_OVERRIDE=""
  VENDOR_SCRIPT_OVERRIDE=""

  # ── Helper: append a reason ─────────────────────────────────────────────
  _ovd_append() {
    if [ -z "$OLD_VENDOR_REASON" ]; then
      OLD_VENDOR_REASON="$1"
    else
      OLD_VENDOR_REASON="${OLD_VENDOR_REASON}; $1"
    fi
    OLD_VENDOR=true
  }

  # ── Helper: grep a prop file for debug.hwui.renderer ────────────────────
  # Returns the value via stdout; empty if not found or file absent.
  _ovd_grep_prop() {
    [ -f "$1" ] || return 0
    grep -m1 "^debug\.hwui\.renderer=" "$1" 2>/dev/null \
      | cut -d= -f2 | tr -d '\r'
  }

  # ══════════════════════════════════════════════════════════════════════════
  # CAUSE 1 — /vendor/build.prop sets debug.hwui.renderer
  # ══════════════════════════════════════════════════════════════════════════
  _v1=$(_ovd_grep_prop /vendor/build.prop)
  if [ -n "$_v1" ] && [ "$_v1" != "skiavk" ]; then
    VENDOR_HWUI_PROP="$_v1"
    _ovd_append "/vendor/build.prop: debug.hwui.renderer=${_v1}"
  fi
  unset _v1

  # ── Also check /vendor/default.prop (pre-Treble legacy path) ─────────────
  _v1d=$(_ovd_grep_prop /vendor/default.prop)
  if [ -n "$_v1d" ] && [ "$_v1d" != "skiavk" ]; then
    [ -z "$VENDOR_HWUI_PROP" ] && VENDOR_HWUI_PROP="$_v1d"
    _ovd_append "/vendor/default.prop: debug.hwui.renderer=${_v1d}"
  fi
  unset _v1d

  # ══════════════════════════════════════════════════════════════════════════
  # CAUSE 2 — ODM build.prop sets debug.hwui.renderer
  # ══════════════════════════════════════════════════════════════════════════
  for _odmf in /odm/build.prop /odm/etc/build.prop /vendor/odm/etc/build.prop; do
    _v2=$(_ovd_grep_prop "$_odmf")
    if [ -n "$_v2" ] && [ "$_v2" != "skiavk" ]; then
      [ -z "$VENDOR_HWUI_PROP" ] && VENDOR_HWUI_PROP="$_v2"
      _ovd_append "${_odmf}: debug.hwui.renderer=${_v2}"
    fi
    unset _v2
  done
  unset _odmf

  # ══════════════════════════════════════════════════════════════════════════
  # CAUSE 3 — /product/build.prop sets debug.hwui.renderer
  # ══════════════════════════════════════════════════════════════════════════
  _v3=$(_ovd_grep_prop /product/build.prop)
  if [ -n "$_v3" ] && [ "$_v3" != "skiavk" ]; then
    [ -z "$VENDOR_HWUI_PROP" ] && VENDOR_HWUI_PROP="$_v3"
    _ovd_append "/product/build.prop: debug.hwui.renderer=${_v3}"
  fi
  unset _v3

  # ══════════════════════════════════════════════════════════════════════════
  # CAUSE 4 — vendor/odm/product init.rc files have setprop override
  # ══════════════════════════════════════════════════════════════════════════
  for _rc_dir in \
      /vendor/etc/init /vendor/etc/init/hw \
      /odm/etc/init /vendor/odm/etc/init \
      /product/etc/init; do
    [ -d "$_rc_dir" ] || continue
    for _rcf in "${_rc_dir}"/*.rc; do
      [ -f "$_rcf" ] || continue
      if grep -q "setprop debug\.hwui\.renderer" "$_rcf" 2>/dev/null; then
        _rc_val=$(grep "setprop debug\.hwui\.renderer" "$_rcf" 2>/dev/null \
                  | head -1 | awk '{print $NF}' | tr -d '\r')
        if [ -n "$_rc_val" ] && [ "$_rc_val" != "skiavk" ]; then
          [ -z "$VENDOR_RC_OVERRIDE" ] && VENDOR_RC_OVERRIDE="$_rcf"
          _ovd_append "init.rc: ${_rcf##*/} sets debug.hwui.renderer=${_rc_val}"
          break 2
        fi
      fi
    done
  done
  unset _rc_dir _rcf _rc_val

  # ══════════════════════════════════════════════════════════════════════════
  # CAUSE 5 — Vendor post-boot shell script sets debug.hwui.renderer
  # ══════════════════════════════════════════════════════════════════════════
  for _sh in \
      /vendor/bin/init.qcom.post_boot.sh \
      /vendor/bin/init.qti.qcm.sh \
      /vendor/bin/hw/vendor.qti.hardware.perf*.sh \
      /odm/bin/init.post_boot.sh \
      /vendor/bin/init.post_boot.sh; do
    [ -f "$_sh" ] || continue
    if grep -q "setprop debug\.hwui\.renderer" "$_sh" 2>/dev/null; then
      _sh_val=$(grep "setprop debug\.hwui\.renderer" "$_sh" 2>/dev/null \
                | head -1 | awk '{print $NF}' | tr -d '\r')
      if [ -n "$_sh_val" ] && [ "$_sh_val" != "skiavk" ]; then
        [ -z "$VENDOR_SCRIPT_OVERRIDE" ] && VENDOR_SCRIPT_OVERRIDE="$_sh"
        _ovd_append "post-boot script: ${_sh##*/} sets debug.hwui.renderer=${_sh_val}"
        break
      fi
    fi
    unset _sh_val
  done
  unset _sh

  # ── Clean up helper functions ─────────────────────────────────────────────
  unset -f _ovd_append _ovd_grep_prop 2>/dev/null || true

  return 0
}

# Backwards-compat alias — callers that used detect_old_vendor() still work
detect_old_vendor() { detect_old_vendor_extended; }

# ============================================================
# detect_gralloc_hal_version()
# ============================================================
# Detects the vendor gralloc HAL version by probing VINTF manifest,
# .so presence, and live service checks (in priority order).
#
# WHY THIS MATTERS FOR SKIAVK:
#   Android 12+ system libvulkan.so (loader) calls ANativeWindow_lock()
#   which routes through the system gralloc mapper client. The client was
#   compiled against gralloc4 HIDL or AIDL interface ABI. If the vendor
#   ships only gralloc2 or gralloc3 HIDL, the Binder IPC for
#   IMapper::importBuffer() or IAllocator::allocate() fails with
#   DEAD_OBJECT or returns incorrect usage-flag capabilities. The Vulkan
#   loader cannot allocate swapchain images → vkCreateSwapchainKHR returns
#   VK_ERROR_INITIALIZATION_FAILED → HWUI aborts the Vulkan pipeline →
#   app draws nothing (black screen) or SIGSEGV.
#
# Sets:
#   GRALLOC_HAL_VERSION  — "4" / "3" / "2" / "1" / "unknown"
#   GRALLOC_IS_AIDL      — true (Android 13+ AIDL interface) / false (HIDL)
#   GRALLOC_DETECTION_METHOD — "vintf_manifest" / "aidl_so" / "so_presence" / "service_check" / "unknown"
# ============================================================
detect_gralloc_hal_version() {
  GRALLOC_HAL_VERSION="unknown"
  GRALLOC_IS_AIDL=false
  GRALLOC_DETECTION_METHOD="unknown"

  # ── Strategy 1: VINTF manifest (most authoritative) ──────────────────────
  # /vendor/etc/vintf/manifest.xml lists every HAL interface the vendor
  # implements. gralloc4 HIDL appears as "android.hardware.graphics.mapper@4.0",
  # AIDL appears as "android.hardware.graphics.mapper" with no version attribute
  # or with an explicit HAL format="aidl" marker.
  for _mf in /vendor/etc/vintf/manifest.xml /vendor/manifest.xml \
              /odm/etc/vintf/manifest.xml /odm/manifest.xml; do
    [ -f "$_mf" ] || continue

    # AIDL gralloc (Android 13+) — no @version suffix in the interface name
    if grep -q 'android.hardware.graphics.mapper"' "$_mf" 2>/dev/null && \
       grep -q 'format="aidl"' "$_mf" 2>/dev/null; then
      GRALLOC_HAL_VERSION="4"
      GRALLOC_IS_AIDL=true
      GRALLOC_DETECTION_METHOD="vintf_manifest"
      return 0
    fi

    # HIDL gralloc4
    if grep -qE 'android\.hardware\.graphics\.(mapper|allocator)@4\.0' \
        "$_mf" 2>/dev/null; then
      GRALLOC_HAL_VERSION="4"
      GRALLOC_IS_AIDL=false
      GRALLOC_DETECTION_METHOD="vintf_manifest"
      return 0
    fi

    # HIDL gralloc3
    if grep -qE 'android\.hardware\.graphics\.(mapper|allocator)@3\.0' \
        "$_mf" 2>/dev/null; then
      GRALLOC_HAL_VERSION="3"
      GRALLOC_IS_AIDL=false
      GRALLOC_DETECTION_METHOD="vintf_manifest"
      return 0
    fi

    # HIDL gralloc2
    if grep -qE 'android\.hardware\.graphics\.(mapper|allocator)@2\.' \
        "$_mf" 2>/dev/null; then
      GRALLOC_HAL_VERSION="2"
      GRALLOC_IS_AIDL=false
      GRALLOC_DETECTION_METHOD="vintf_manifest"
      return 0
    fi
  done
  unset _mf

  # ── Strategy 2: AIDL .so file patterns (Android 13+) ─────────────────────
  # AIDL gralloc ships as libgralloc.*.so or android.hardware.graphics.mapper-VX.so
  # where X is the AIDL minor version. No @4.0 suffix — pure AIDL naming.
  for _ap in \
    /vendor/lib64/hw/android.hardware.graphics.mapper-V*.so \
    /vendor/lib64/android.hardware.graphics.allocator-V*.so \
    /vendor/lib64/libgralloc.so \
    /vendor/lib/hw/android.hardware.graphics.mapper-V*.so; do
    # Use ls to expand glob — if glob expands to nothing ls fails silently
    ls "$_ap" >/dev/null 2>&1 && {
      GRALLOC_HAL_VERSION="4"
      GRALLOC_IS_AIDL=true
      GRALLOC_DETECTION_METHOD="aidl_so"
      return 0
    }
  done
  unset _ap

  # ── Strategy 3: HIDL .so file presence by version (4 → 3 → 2) ───────────
  # gralloc HIDL .so naming: android.hardware.graphics.mapper@X.0-impl.so
  # Present in /vendor/lib64/hw/ on Qualcomm devices using HIDL gralloc.
  for _gv in 4 3 2; do
    _found_so=false
    for _p in \
      "/vendor/lib64/hw/android.hardware.graphics.mapper@${_gv}.0-impl.so" \
      "/vendor/lib64/hw/android.hardware.graphics.mapper@${_gv}.0.so" \
      "/vendor/lib/hw/android.hardware.graphics.mapper@${_gv}.0-impl.so" \
      "/system/lib64/android.hardware.graphics.mapper@${_gv}.0.so" \
      "/vendor/lib64/android.hardware.graphics.allocator@${_gv}.0-service.so"; do
      [ -f "$_p" ] && { _found_so=true; break; }
    done
    if [ "$_found_so" = "true" ]; then
      GRALLOC_HAL_VERSION="$_gv"
      GRALLOC_IS_AIDL=false
      GRALLOC_DETECTION_METHOD="so_presence"
      unset _gv _found_so _p
      return 0
    fi
  done
  unset _gv _found_so _p

  # ── Strategy 4: Live service check (slowest but most accurate at runtime) ─
  # service check tests if the Binder service is registered in servicemanager.
  # Only works after servicemanager is up — safe in service.sh, risky in post-fs.
  if command -v service >/dev/null 2>&1; then
    # AIDL gralloc (Android 13+): service name has no @ version
    if service check "android.hardware.graphics.allocator.IAllocator/default" \
        >/dev/null 2>&1; then
      GRALLOC_HAL_VERSION="4"
      GRALLOC_IS_AIDL=true
      GRALLOC_DETECTION_METHOD="service_check"
      return 0
    fi
    # HIDL gralloc4
    if service check "android.hardware.graphics.allocator@4.0::IAllocator/default" \
        >/dev/null 2>&1; then
      GRALLOC_HAL_VERSION="4"
      GRALLOC_IS_AIDL=false
      GRALLOC_DETECTION_METHOD="service_check"
      return 0
    fi
    # HIDL gralloc3
    if service check "android.hardware.graphics.allocator@3.0::IAllocator/default" \
        >/dev/null 2>&1; then
      GRALLOC_HAL_VERSION="3"
      GRALLOC_IS_AIDL=false
      GRALLOC_DETECTION_METHOD="service_check"
      return 0
    fi
    # HIDL gralloc2
    if service check "android.hardware.graphics.allocator@2.0::IAllocator/default" \
        >/dev/null 2>&1; then
      GRALLOC_HAL_VERSION="2"
      GRALLOC_IS_AIDL=false
      GRALLOC_DETECTION_METHOD="service_check"
      return 0
    fi
  fi

  # Unknown — proceed with caution
  GRALLOC_HAL_VERSION="unknown"
  GRALLOC_DETECTION_METHOD="unknown"
  return 0
}

# ============================================================
# detect_kgsl_version()
# ============================================================
# Detects the KGSL kernel driver version and GPU model from sysfs.
#
# WHY THIS MATTERS FOR SKIAVK:
#   Custom Adreno drivers (Xtreme Star, Banch++, etc.) are compiled
#   against a specific KGSL IOCTL ABI version. The critical IOCTLs are:
#
#   IOCTL_KGSL_GPU_COMMAND / IOCTL_KGSL_GPU_COMMAND_V2 (kernel 4.14+):
#     Used by vkQueueSubmit to submit command streams to the GPU.
#     If the kernel KGSL doesn't implement this IOCTL, it returns ENOTTY.
#     Custom drivers don't always validate the return value → they
#     dereference the (null/garbage) output struct → SIGSEGV in vkCreateDevice.
#
#   IOCTL_KGSL_GPUOBJ_SYNC (kernel 4.14+):
#     Used by vkMapMemory / vkUnmapMemory for GPU memory coherency.
#     Missing → custom driver writes to an already-freed pointer → SIGBUS.
#
#   sync_file / EGL_ANDROID_native_fence_sync (kernel 4.9+):
#     Used by HWUI swapchain present/acquire to synchronize GPU and CPU.
#     Missing → fence FD is created but never signals → display deadlock.
#
# Sets:
#   KGSL_VERSION_MAJOR     — integer (e.g. 3), 0 if unknown
#   KGSL_VERSION_MINOR     — integer (e.g. 15), 0 if unknown
#   KGSL_VERSION_RAW       — raw string from sysfs ("3.15" or "inferred:X.Y")
#   KGSL_GPU_MODEL         — GPU model string (e.g. "Adreno 650")
#   KERNEL_VERSION_MAJOR   — kernel major version integer
#   KERNEL_VERSION_MINOR   — kernel minor version integer
#   KERNEL_VERSION_PATCH   — kernel patch level integer
#   KERNEL_VERSION_RAW     — raw uname -r output
# ============================================================
detect_kgsl_version() {
  KGSL_VERSION_MAJOR=0
  KGSL_VERSION_MINOR=0
  KGSL_VERSION_RAW="unknown"
  KGSL_GPU_MODEL="unknown"
  KERNEL_VERSION_MAJOR=0
  KERNEL_VERSION_MINOR=0
  KERNEL_VERSION_PATCH=0
  KERNEL_VERSION_RAW="unknown"

  # ── Kernel version (baseline for KGSL IOCTL availability) ─────────────────
  KERNEL_VERSION_RAW=$(uname -r 2>/dev/null || echo "0.0.0")
  # Parse: "4.19.157-perf-g1234abc" → major=4, minor=19, patch=157
  _kv_tmp="$KERNEL_VERSION_RAW"
  KERNEL_VERSION_MAJOR="${_kv_tmp%%.*}"
  _kv_tmp="${_kv_tmp#*.}"
  KERNEL_VERSION_MINOR="${_kv_tmp%%.*}"
  _kv_tmp="${_kv_tmp#*.}"
  # Extract numeric prefix only (before any -, +, or letter)
  KERNEL_VERSION_PATCH="${_kv_tmp%%[^0-9]*}"
  # Sanitise: ensure we have integers
  KERNEL_VERSION_MAJOR="${KERNEL_VERSION_MAJOR:-0}"
  KERNEL_VERSION_MINOR="${KERNEL_VERSION_MINOR:-0}"
  KERNEL_VERSION_PATCH="${KERNEL_VERSION_PATCH:-0}"
  unset _kv_tmp

  # ── GPU model from sysfs ──────────────────────────────────────────────────
  for _gm_path in \
    /sys/class/kgsl/kgsl-3d0/gpu_model \
    /sys/devices/platform/soc/3d00000.qcom,kgsl-3d0/kgsl/kgsl-3d0/gpu_model \
    /sys/devices/platform/soc/*.qcom,kgsl-3d0/kgsl/kgsl-3d0/gpu_model \
    /sys/kernel/debug/kgsl/kgsl-3d0/gpuinfo; do
    [ -f "$_gm_path" ] || continue
    { IFS= read -r KGSL_GPU_MODEL; } < "$_gm_path" 2>/dev/null
    KGSL_GPU_MODEL="${KGSL_GPU_MODEL:-unknown}"
    break
  done
  unset _gm_path

  # ── KGSL driver version from sysfs ───────────────────────────────────────
  # Format varies by kernel: "3.15" or "kgsl 3.15" or "3.15.0"
  for _kv_path in \
    /sys/class/kgsl/kgsl-3d0/kgsl_version \
    /sys/kernel/debug/kgsl/version \
    /sys/devices/platform/soc/3d00000.qcom,kgsl-3d0/kgsl/kgsl-3d0/kgsl_version; do
    [ -f "$_kv_path" ] || continue
    { IFS= read -r KGSL_VERSION_RAW; } < "$_kv_path" 2>/dev/null || continue
    # Strip "kgsl " prefix if present
    _kv_clean="${KGSL_VERSION_RAW#*kgsl }"
    _kv_clean="${_kv_clean#kgsl-}"
    # Extract major.minor
    KGSL_VERSION_MAJOR="${_kv_clean%%.*}"
    _kv_rest="${_kv_clean#*.}"
    KGSL_VERSION_MINOR="${_kv_rest%%[^0-9]*}"
    # Sanitise
    KGSL_VERSION_MAJOR="${KGSL_VERSION_MAJOR:-0}"
    KGSL_VERSION_MINOR="${KGSL_VERSION_MINOR:-0}"
    unset _kv_clean _kv_rest
    break
  done
  unset _kv_path

  # ── Fallback: infer KGSL version from kernel version ─────────────────────
  # Qualcomm KGSL version approximately tracks the kernel version it ships with.
  # This is an approximation — used only when sysfs is unavailable.
  if [ "$KGSL_VERSION_MAJOR" -eq 0 ] 2>/dev/null; then
    KGSL_VERSION_MAJOR="$KERNEL_VERSION_MAJOR"
    KGSL_VERSION_MINOR="$KERNEL_VERSION_MINOR"
    KGSL_VERSION_RAW="inferred:${KERNEL_VERSION_MAJOR}.${KERNEL_VERSION_MINOR}"
  fi

  return 0
}

# ============================================================
# probe_vulkan_stack_compatibility()
# ============================================================
# Comprehensive multi-layer hardware compatibility analysis for skiavk.
# Probes: Vulkan driver existence, KGSL/kernel version, gralloc HAL
# version, EGL fence sync support, UBWC/HWC compatibility, vendor
# prop wars, and VNDK API delta.
#
# CALL ORDER REQUIREMENTS:
#   Must be called AFTER detect_old_vendor_extended() (needs OLD_VENDOR,
#   VENDOR_RC_OVERRIDE, VENDOR_SCRIPT_OVERRIDE), and AFTER
#   detect_kgsl_version() (needs KERNEL_VERSION_MAJOR/MINOR).
#   detect_gralloc_hal_version() is called internally.
#
# SCORING SYSTEM (0–100):
#   Each detected incompatibility deducts points based on crash severity.
#
#   100        = Perfect — every check passes, no issues found
#   80 – 99    = EXCELLENT  → skiavk + skiavk_all both safe
#   60 – 79    = GOOD       → skiavk safe, avoid skiavk_all
#   40 – 59    = DEGRADED   → skiavk may work with visible glitches/OOM risk
#   0  – 39    = CRITICAL   → guaranteed crash/black screen → auto-downgrade to skiagl
#
# DEDUCTION TABLE (matches root causes from root cause analysis):
#   -60  NO_VULKAN_DRIVER           (no vulkan.*.so anywhere)
#   -50  KERNEL_TOO_OLD             (kernel < 4.9, no sync_file)
#   -45  GRALLOC2_MISMATCH          (gralloc2 with Android 12+ system)
#   -40  KGSL_IOCTL_MISSING         (kernel 4.9–4.13, GPU CMD V2 absent)
#   -35  GRALLOC3_ON_A12_PLUS       (gralloc3 with SDK >= 31)
#   -30  EGL_FENCE_SYNC_MISSING     (sync_file absent in kernel)
#   -25  KGSL_CMD_V2_ABSENT         (kernel 4.14+ but sysfs KGSL < expected)
#   -20  HWC_UBWC_MISMATCH          (HWC 2.0 can't composite UBWC buffers)
#   -20  SDK_DELTA_SEVERE           (system vs vendor VNDK delta > 4 levels)
#   -15  GRALLOC_UNKNOWN            (couldn't probe gralloc version)
#   -10  SDK_DELTA_MODERATE         (VNDK delta 3–4 levels)
#   -10  VENDOR_RC_PROP_WAR         (vendor init.rc will override prop)
#   -8   VENDOR_SCRIPT_PROP_WAR     (vendor post-boot script will override)
#   -5   UBWC_EXPLICITLY_DISABLED   (vendor disabled UBWC, minor compat note)
#   -5   HWC_VERSION_UNKNOWN        (couldn't probe HWC version)
#
# Sets:
#   VK_COMPAT_SCORE         — 0–100 integer
#   VK_COMPAT_LEVEL         — "critical" / "degraded" / "good" / "excellent"
#   VK_COMPAT_ISSUES        — semicolon-separated list of issue codes + detail
#   VK_RECOMMENDED_MODE     — "skiagl" / "skiavk" / "skiavk_all"
#   VK_GRALLOC_OK           — true/false
#   VK_KGSL_OK              — true/false
#   VK_EGL_FENCE_OK         — true/false
#   VK_UBWC_OK              — true/false
#   VK_DRIVER_OK            — true/false
#   VK_COMPAT_REPORT        — multi-line human-readable diagnosis string
# ============================================================
probe_vulkan_stack_compatibility() {
  VK_COMPAT_SCORE=100
  VK_COMPAT_LEVEL="excellent"
  VK_COMPAT_ISSUES=""
  VK_RECOMMENDED_MODE="skiavk"
  VK_GRALLOC_OK=true
  VK_KGSL_OK=true
  VK_EGL_FENCE_OK=true
  VK_UBWC_OK=true
  VK_DRIVER_OK=true
  VK_COMPAT_REPORT=""

  # ── Internal helpers ──────────────────────────────────────────────────────
  _vk_deduct() {
    # $1 = points to deduct, $2 = issue code:detail string
    VK_COMPAT_SCORE=$((VK_COMPAT_SCORE - $1))
    [ "$VK_COMPAT_SCORE" -lt 0 ] && VK_COMPAT_SCORE=0
    if [ -z "$VK_COMPAT_ISSUES" ]; then
      VK_COMPAT_ISSUES="$2"
    else
      VK_COMPAT_ISSUES="${VK_COMPAT_ISSUES}; $2"
    fi
  }

  _vk_report() {
    if [ -z "$VK_COMPAT_REPORT" ]; then
      VK_COMPAT_REPORT="$1"
    else
      VK_COMPAT_REPORT="${VK_COMPAT_REPORT}
$1"
    fi
  }

  # ════════════════════════════════════════════════════════════════════════
  # CHECK 1: Vulkan driver .so existence
  # ════════════════════════════════════════════════════════════════════════
  # Without a Vulkan ICD, libvulkan's loader cannot find any physical device.
  # vkCreateInstance returns VK_ERROR_INCOMPATIBLE_DRIVER immediately.
  # HWUI silently falls back to skiagl — the prop stays "skiavk" but no
  # Vulkan ever runs. skiavk_all then clears GL caches, force-stops apps,
  # apps restart, all try Vulkan, all fail, all fall back to GL without cache
  # → mass shader recompile OOM → every app crashes for 10 minutes.
  _vk_drv_found=false
  _vk_drv_path=""
  for _vl in \
    /vendor/lib64/hw/vulkan.*.so \
    /vendor/lib/hw/vulkan.*.so \
    /system/lib64/hw/vulkan.*.so \
    /system/lib/hw/vulkan.*.so \
    /vendor/lib64/libvulkan.so \
    /system/lib64/libvulkan.so; do
    ls "$_vl" >/dev/null 2>&1 && { _vk_drv_found=true; _vk_drv_path="$_vl"; break; }
  done
  if [ "$_vk_drv_found" = "true" ]; then
    _vk_report "  [OK] Vulkan driver found: ${_vk_drv_path}"
  else
    VK_DRIVER_OK=false
    _vk_deduct 60 "NO_VULKAN_DRIVER: No vulkan.*.so or libvulkan.so in vendor/system"
    _vk_report "  [CRIT] NO VULKAN DRIVER — skiavk prop is set but no Vulkan ICD exists."
    _vk_report "         vkCreateInstance → VK_ERROR_INCOMPATIBLE_DRIVER immediately."
    _vk_report "         HWUI silently falls to skiagl. skiavk_all then clears GL caches"
    _vk_report "         → apps restart without shaders → mass OOM → ALL apps crash."
  fi
  unset _vk_drv_found _vk_drv_path _vl

  # ════════════════════════════════════════════════════════════════════════
  # CHECK 2: Kernel version — KGSL IOCTL baseline requirements
  # ════════════════════════════════════════════════════════════════════════
  # The minimum kernel version requirements for Vulkan on Qualcomm:
  #
  # < 4.9:   No CONFIG_SYNC_FILE in-kernel → no sync FD for GPU/display sync.
  #          EGL_ANDROID_native_fence_sync cannot be implemented.
  #          HWUI swapchain acquire/present fence never signals → deadlock.
  #          Also: no VK_KHR_timeline_semaphore host support → ICD crashes.
  #
  # 4.9–4.13: sync_file exists but KGSL command submission API is V1.
  #           Custom Adreno drivers call IOCTL_KGSL_GPU_COMMAND_V2 (4.14+).
  #           Kernel returns ENOTTY. Driver dereferences un-initialized struct
  #           → SIGSEGV in vkCreateDevice. Every app crashes on open.
  #
  # >= 4.14:  IOCTL_KGSL_GPU_COMMAND_V2 available. Also IOCTL_KGSL_GPUOBJ_SYNC
  #           (needed for vkMapMemory coherency). This is the baseline for
  #           custom Adreno drivers from Xtreme Star / Banch++.
  _kv_maj="${KERNEL_VERSION_MAJOR:-0}"
  _kv_min="${KERNEL_VERSION_MINOR:-0}"

  if [ "$_kv_maj" -lt 4 ] 2>/dev/null; then
    VK_KGSL_OK=false
    _vk_deduct 50 "KERNEL_TOO_OLD: Kernel ${_kv_maj}.${_kv_min} — Vulkan requires >= 4.9 minimum"
    _vk_report "  [CRIT] KERNEL TOO OLD (${_kv_maj}.${_kv_min})."
    _vk_report "         No CONFIG_SYNC_FILE, no KGSL IOCTL_KGSL_GPU_COMMAND."
    _vk_report "         vkCreateDevice → SIGSEGV. Every app crashes immediately."

  elif [ "$_kv_maj" -eq 4 ] && [ "$_kv_min" -lt 9 ] 2>/dev/null; then
    VK_KGSL_OK=false
    _vk_deduct 50 "KGSL_NO_SYNC_FILE: Kernel ${_kv_maj}.${_kv_min} — no CONFIG_SYNC_FILE"
    _vk_report "  [CRIT] KERNEL ${_kv_maj}.${_kv_min}: No sync_file (CONFIG_SYNC_FILE added in 4.9)."
    _vk_report "         EGL_ANDROID_native_fence_sync impossible → HWUI swapchain deadlock."
    _vk_report "         Screen: first frame then permanent black. App: eventually ANR."

  elif [ "$_kv_maj" -eq 4 ] && [ "$_kv_min" -lt 14 ] 2>/dev/null; then
    VK_KGSL_OK=false
    _vk_deduct 40 "KGSL_IOCTL_MISSING: Kernel ${_kv_maj}.${_kv_min} — IOCTL_KGSL_GPU_COMMAND_V2 absent"
    _vk_report "  [HIGH] KERNEL ${_kv_maj}.${_kv_min}: KGSL GPU_COMMAND_V2 IOCTL missing (needs 4.14+)."
    _vk_report "         Custom Adreno drivers call this IOCTL in vkQueueSubmit."
    _vk_report "         Kernel returns ENOTTY → driver SIGSEGV → app crashes on open."
    _vk_report "         Stock Qualcomm drivers handle this gracefully; custom do NOT."

  else
    _vk_report "  [OK] Kernel ${_kv_maj}.${_kv_min} — KGSL IOCTL baseline met (>= 4.14)"
  fi
  unset _kv_maj _kv_min

  # ════════════════════════════════════════════════════════════════════════
  # CHECK 3: Gralloc HAL version vs system libvulkan requirement
  # ════════════════════════════════════════════════════════════════════════
  # Android system libvulkan is compiled against the gralloc version the
  # system SDK targets. It calls ANativeWindow_lock() → IMapper::importBuffer().
  #
  # Android 12+ (SDK 31+): libvulkan compiled for gralloc4 HIDL/AIDL.
  #   Calling gralloc4 mapper API on a gralloc3 implementation:
  #     → Binder finds @3.0 service, not @4.0 → SERVICE_NOT_FOUND
  #     → IMapper::importBuffer() throws RemoteException
  #     → Vulkan loader: NULL native buffer handle
  #     → vkCreateSwapchainKHR: VK_ERROR_INITIALIZATION_FAILED
  #     → HWUI falls back to skiagl (prop still says skiavk)
  #
  # Android 10–11 (SDK 29–30): libvulkan compatible with gralloc3.
  #   Custom ROM on Android 12 SYSTEM + Android 10 VENDOR:
  #   system SDK is 31+ but vendor provides only gralloc3 → guaranteed crash.
  #
  # gralloc2: even older, no HIDL buffer import at all. Catastrophic mismatch.
  detect_gralloc_hal_version
  _sys_sdk=$(getprop ro.build.version.sdk 2>/dev/null || echo "0")
  # Sanitise: strip non-numeric suffix (some ROMs append letters)
  _sys_sdk="${_sys_sdk%%[^0-9]*}"
  _sys_sdk="${_sys_sdk:-0}"

  case "$GRALLOC_HAL_VERSION" in
    "unknown")
      _vk_deduct 15 "GRALLOC_UNKNOWN: Cannot determine gralloc HAL version (method: ${GRALLOC_DETECTION_METHOD})"
      _vk_report "  [WARN] Gralloc HAL version undetermined. Proceeding cautiously."
      _vk_report "         If swapchain fails (black screen), gralloc version mismatch is the cause."
      ;;
    "2")
      VK_GRALLOC_OK=false
      _vk_deduct 45 "GRALLOC2_MISMATCH: Vendor has gralloc2 HIDL — system libvulkan cannot allocate swapchain buffers"
      _vk_report "  [CRIT] GRALLOC2 DETECTED (vendor). System libvulkan compiled for gralloc3+."
      _vk_report "         IMapper::importBuffer() call fails → null ANativeWindow buffer."
      _vk_report "         vkCreateSwapchainKHR → VK_ERROR_INITIALIZATION_FAILED → black screen."
      _vk_report "         Fix: skiavk requires gralloc3 minimum (gralloc4 preferred)."
      ;;
    "3")
      if [ "$_sys_sdk" -ge 31 ] 2>/dev/null; then
        # Android 12+ system on gralloc3 vendor: confirmed mismatch
        VK_GRALLOC_OK=false
        _vk_deduct 35 "GRALLOC3_ON_SDK${_sys_sdk}: gralloc3 vendor with Android 12+ system (SDK=${_sys_sdk})"
        _vk_report "  [HIGH] GRALLOC3 + SDK${_sys_sdk}: Android 12+ libvulkan uses gralloc4 ABI."
        _vk_report "         Vendor ships gralloc3 HIDL — the @4.0::IMapper service doesn't exist."
        _vk_report "         Swapchain buffer allocation partially fails → some buffers corrupt."
        _vk_report "         Symptom: app draws first frame (flicker) then black screen."
      else
        _vk_report "  [OK] Gralloc3 — compatible with this system SDK (${_sys_sdk})"
      fi
      ;;
    "4")
      if [ "$GRALLOC_IS_AIDL" = "true" ]; then
        _vk_report "  [OK] Gralloc4 AIDL (Android 13+ optimal) — full Vulkan swapchain support"
      else
        _vk_report "  [OK] Gralloc4 HIDL — Vulkan swapchain buffer allocation fully supported"
      fi
      ;;
    *)
      _vk_report "  [INFO] Gralloc version: ${GRALLOC_HAL_VERSION} (unhandled case, treating as OK)"
      ;;
  esac
  unset _sys_sdk

  # ════════════════════════════════════════════════════════════════════════
  # CHECK 4: EGL_ANDROID_native_fence_sync proxy check
  # ════════════════════════════════════════════════════════════════════════
  # HWUI skiavkthreaded uses this extension to create exportable sync FDs
  # for the Vulkan acquire/present semaphore handshake with SurfaceFlinger.
  #
  # The extension requires in-kernel sync_file (CONFIG_SYNC_FILE, 4.9+)
  # AND the vendor EGL driver must expose the extension.
  #
  # Shell proxy: check kernel version (definitive) + /sys/kernel/debug/sync
  # (CONFIG_SYNC_FILE marker) + /dev/sw_sync (alternative sync path).
  #
  # What happens when it's missing:
  #   HWUI's VulkanSurface::dequeueBuffer() calls eglCreateSyncKHR() for the
  #   native fence. Returns EGL_NO_SYNC_KHR. HWUI proceeds without a fence.
  #   SurfaceFlinger's buffer queue now has no synchronization signal for when
  #   the GPU finishes writing each frame. SF acquires the next buffer before
  #   GPU finishes writing → tearing → black frame → SF flips back to previous
  #   buffer → deadlock. Screen: flicker once then freeze. System not crashed.
  _egl_fence_ok=true
  _egl_fence_reason=""

  if [ "${KERNEL_VERSION_MAJOR:-0}" -lt 4 ] 2>/dev/null; then
    _egl_fence_ok=false
    _egl_fence_reason="Kernel ${KERNEL_VERSION_MAJOR}.${KERNEL_VERSION_MINOR} < 4.9"
  elif [ "${KERNEL_VERSION_MAJOR:-0}" -eq 4 ] && \
       [ "${KERNEL_VERSION_MINOR:-0}" -lt 9 ] 2>/dev/null; then
    _egl_fence_ok=false
    _egl_fence_reason="Kernel ${KERNEL_VERSION_MAJOR}.${KERNEL_VERSION_MINOR} < 4.9 (CONFIG_SYNC_FILE not available)"
  else
    # Kernel >= 4.9: sync_file is present. Now check if the kernel config
    # actually compiled it in (some custom kernels explicitly disable it).
    if [ ! -d "/sys/kernel/debug/sync" ] && \
       [ ! -d "/sys/kernel/debug/dma_buf" ] && \
       [ ! -e "/dev/sync" ] && \
       [ ! -e "/dev/sw_sync" ]; then
      # All markers absent — likely CONFIG_SYNC_FILE=n
      # Only flag as failed if kernel is old-ish (>= 4.14 usually has it enabled)
      if [ "${KERNEL_VERSION_MAJOR:-0}" -eq 4 ] && \
         [ "${KERNEL_VERSION_MINOR:-0}" -lt 14 ] 2>/dev/null; then
        _egl_fence_ok=false
        _egl_fence_reason="Kernel ${KERNEL_VERSION_MAJOR}.${KERNEL_VERSION_MINOR}: sync_file markers absent (CONFIG_SYNC_FILE=n?)"
      fi
    fi
  fi

  if [ "$_egl_fence_ok" = "false" ]; then
    VK_EGL_FENCE_OK=false
    _vk_deduct 30 "EGL_FENCE_SYNC_MISSING: ${_egl_fence_reason}"
    _vk_report "  [HIGH] EGL_ANDROID_native_fence_sync UNAVAILABLE: ${_egl_fence_reason}"
    _vk_report "         HWUI swapchain acquire/present has no GPU completion signal."
    _vk_report "         SF consumes buffers before GPU finishes → frame corruption → freeze."
    _vk_report "         Symptom: app opens (brief flicker), then permanent black screen."
  else
    _vk_report "  [OK] EGL_ANDROID_native_fence_sync proxy check passed (sync_file available)"
  fi
  unset _egl_fence_ok _egl_fence_reason

  # ════════════════════════════════════════════════════════════════════════
  # CHECK 5: UBWC / HWC compatibility gap
  # ════════════════════════════════════════════════════════════════════════
  # Custom Adreno drivers (Xtreme Star etc.) allocate all GPU render targets
  # with UBWC (Unified Buffer Write Compression) enabled. UBWC is a
  # Qualcomm-proprietary tile compression format that increases effective
  # memory bandwidth for the GPU.
  #
  # Problem: The Hardware Composer (HWC) must also understand UBWC to
  # composite these buffers onto the display. Old vendor HWC (2.0 era)
  # doesn't handle UBWC buffers — when the Vulkan driver marks a swapchain
  # image as UBWC and hands it to SurfaceFlinger, SF passes it to HWC,
  # which reads it as uncompressed → garbage output on display → black screen.
  #
  # Alternatively: old vendor gralloc allocates the buffer as UBWC in
  # response to the UBWC usage flag, but the new system libvulkan doesn't
  # set the vendor-specific UBWC usage flag (changed between gralloc3 and
  # gralloc4) → gralloc allocates non-UBWC, driver tries to write UBWC
  # tile data → hardware memory protection fault → GPU fault → device reset.
  #
  # Proxy: HWC HAL version from VINTF manifest. HWC 2.1+ added UBWC support
  # for Qualcomm platforms. HWC 2.0 does NOT support UBWC compositing.
  _hwc_ver="unknown"
  _hwc_ok=true
  for _hwcmf in /vendor/etc/vintf/manifest.xml /vendor/manifest.xml \
                /odm/etc/vintf/manifest.xml /odm/manifest.xml; do
    [ -f "$_hwcmf" ] || continue
    grep -q "android.hardware.graphics.composer" "$_hwcmf" 2>/dev/null || continue

    # Check for AIDL composer (Android 14+ / HWC3+)
    if grep -q 'android.hardware.graphics.composer3' "$_hwcmf" 2>/dev/null || \
       (grep -q 'android.hardware.graphics.composer' "$_hwcmf" 2>/dev/null && \
        grep -q 'format="aidl"' "$_hwcmf" 2>/dev/null); then
      _hwc_ver="3_aidl"
      _hwc_ok=true
      break
    fi
    # HIDL HWC version check
    for _hv in "4.0" "3.0" "2.4" "2.3" "2.2" "2.1" "2.0"; do
      if grep -q "android.hardware.graphics.composer@${_hv}" "$_hwcmf" 2>/dev/null; then
        _hwc_ver="$_hv"
        # HWC 2.0 lacks UBWC support for compositing
        [ "$_hv" = "2.0" ] && _hwc_ok=false
        break 2
      fi
    done
    unset _hv
  done
  unset _hwcmf

  # Also check: vendor gralloc.disable_ubwc prop
  _ubwc_disabled=$(getprop vendor.gralloc.disable_ubwc 2>/dev/null || echo "")
  if [ "$_ubwc_disabled" = "1" ] || [ "$_ubwc_disabled" = "true" ]; then
    # Vendor explicitly disabled UBWC — this actually helps old vendor compat
    # (driver won't produce UBWC-compressed buffers HWC can't read)
    _vk_deduct 5 "UBWC_DISABLED: vendor.gralloc.disable_ubwc=1 (UBWC off, minor perf loss)"
    _vk_report "  [NOTE] vendor.gralloc.disable_ubwc=1: UBWC compression disabled by vendor."
    _vk_report "         Good for old HWC compatibility, minor GPU throughput reduction."
  elif [ "$_hwc_ok" = "false" ]; then
    VK_UBWC_OK=false
    _vk_deduct 20 "HWC_UBWC_MISMATCH: HWC ${_hwc_ver} cannot composite UBWC buffers from custom Adreno driver"
    _vk_report "  [HIGH] HWC ${_hwc_ver} CANNOT COMPOSITE UBWC BUFFERS."
    _vk_report "         Custom Adreno driver enables UBWC on swapchain images."
    _vk_report "         HWC 2.0 reads UBWC buffers as uncompressed → scrambled / black display."
    _vk_report "         Symptom: display shows garbage or stays black after first frame."
    _vk_report "         Fix: vendor.gralloc.disable_ubwc=1 in system.prop disables UBWC."
  elif [ "$_hwc_ver" = "unknown" ]; then
    _vk_deduct 5 "HWC_VERSION_UNKNOWN: Cannot determine HWC HAL version from VINTF manifest"
    _vk_report "  [WARN] HWC version undetermined. Cannot verify UBWC compatibility."
  else
    _vk_report "  [OK] HWC ${_hwc_ver} — UBWC compositing supported"
  fi
  unset _hwc_ver _hwc_ok _ubwc_disabled

  # ════════════════════════════════════════════════════════════════════════
  # CHECK 6: VNDK / SDK version delta (system vs vendor ABI gap)
  # ════════════════════════════════════════════════════════════════════════
  # ro.vndk.version = API level the vendor image was built for.
  # ro.build.version.sdk = API level of the current system image.
  # Delta > 3 API levels means the Vulkan ICD dispatch table ABI (function
  # pointer offsets in VkLayerDispatchTable) diverged significantly.
  # System libvulkan calls GetDeviceProcAddr for extension functions the old
  # ICD doesn't know about → NULL pointers in dispatch table → SIGSEGV on
  # first Vulkan API call that uses a newer extension (e.g., VK_KHR_timeline_semaphore).
  _sys_sdk2=$(getprop ro.build.version.sdk 2>/dev/null || echo "0")
  _sys_sdk2="${_sys_sdk2%%[^0-9]*}"
  _vndk_ver=$(getprop ro.vndk.version 2>/dev/null || echo "")
  _vndk_ver="${_vndk_ver%%[^0-9]*}"

  if [ -n "$_vndk_ver" ] && [ -n "$_sys_sdk2" ] && \
     [ "$_vndk_ver" -gt 0 ] 2>/dev/null && [ "$_sys_sdk2" -gt 0 ] 2>/dev/null; then
    _sdk_delta=$((_sys_sdk2 - _vndk_ver)) 2>/dev/null || _sdk_delta=0
    if [ "$_sdk_delta" -gt 4 ] 2>/dev/null; then
      _vk_deduct 20 "SDK_DELTA_SEVERE: System SDK=${_sys_sdk2}, Vendor VNDK=${_vndk_ver}, delta=${_sdk_delta} API levels"
      _vk_report "  [HIGH] SEVERE VNDK DELTA: System SDK=${_sys_sdk2} vs Vendor VNDK=${_vndk_ver} (Δ${_sdk_delta})."
      _vk_report "         Vulkan ICD dispatch table ABI diverged — new function pointers missing."
      _vk_report "         libvulkan calls GetDeviceProcAddr for newer extensions → NULL ptr."
      _vk_report "         First call to missing function → SIGSEGV in libvulkan.so."
    elif [ "$_sdk_delta" -gt 2 ] 2>/dev/null; then
      _vk_deduct 10 "SDK_DELTA_MODERATE: System SDK=${_sys_sdk2}, Vendor VNDK=${_vndk_ver}, delta=${_sdk_delta}"
      _vk_report "  [WARN] MODERATE VNDK DELTA: System SDK=${_sys_sdk2} vs Vendor VNDK=${_vndk_ver} (Δ${_sdk_delta})."
      _vk_report "         Some newer Vulkan extensions may be unsupported → VK_ERROR_EXTENSION_NOT_PRESENT."
    else
      _vk_report "  [OK] VNDK delta acceptable: System SDK=${_sys_sdk2}, Vendor VNDK=${_vndk_ver} (Δ${_sdk_delta})"
    fi
  else
    _vk_report "  [INFO] VNDK delta check skipped (ro.vndk.version not set or not parseable)"
  fi
  unset _sys_sdk2 _vndk_ver _sdk_delta

  # ════════════════════════════════════════════════════════════════════════
  # CHECK 7: Vendor RC prop override war
  # ════════════════════════════════════════════════════════════════════════
  # If detect_old_vendor_extended() found an RC file with a setprop override,
  # that file will fire after boot_completed and reset our skiavk → skiagl.
  # This is a "prop war" — not a crash risk per se, but means skiavk won't
  # actually stick without the watchdog. Deduct points to flag it.
  if [ "${OLD_VENDOR:-false}" = "true" ] && [ -n "${VENDOR_RC_OVERRIDE:-}" ]; then
    _vk_deduct 10 "VENDOR_RC_PROP_WAR: ${VENDOR_RC_OVERRIDE##*/} overrides debug.hwui.renderer after boot_completed"
    _vk_report "  [WARN] VENDOR RC PROP WAR: ${VENDOR_RC_OVERRIDE##*/}"
    _vk_report "         This init.rc fires after boot_completed and resets debug.hwui.renderer."
    _vk_report "         The service.sh watchdog will re-enforce skiavk — but there is a race window."
    _vk_report "         Apps opened in that window start with the wrong renderer."
  fi

  if [ "${OLD_VENDOR:-false}" = "true" ] && [ -n "${VENDOR_SCRIPT_OVERRIDE:-}" ]; then
    _vk_deduct 8 "VENDOR_SCRIPT_PROP_WAR: ${VENDOR_SCRIPT_OVERRIDE##*/} post-boot script resets debug.hwui.renderer"
    _vk_report "  [WARN] VENDOR SCRIPT PROP WAR: ${VENDOR_SCRIPT_OVERRIDE##*/}"
    _vk_report "         Qualcomm post_boot.sh resets the renderer prop during perf tuning."
  fi

  # ════════════════════════════════════════════════════════════════════════
  # FINAL: Determine level and recommended mode
  # ════════════════════════════════════════════════════════════════════════
  if [ "$VK_COMPAT_SCORE" -le 39 ]; then
    VK_COMPAT_LEVEL="critical"
    VK_RECOMMENDED_MODE="skiagl"
    _vk_report ""
    _vk_report "  VERDICT: CRITICAL (score ${VK_COMPAT_SCORE}/100)"
    _vk_report "  skiavk WILL cause black screen and/or app crashes on this device."
    _vk_report "  AUTO-DOWNGRADE to skiagl recommended."

  elif [ "$VK_COMPAT_SCORE" -le 59 ]; then
    VK_COMPAT_LEVEL="degraded"
    VK_RECOMMENDED_MODE="skiavk"
    _vk_report ""
    _vk_report "  VERDICT: DEGRADED (score ${VK_COMPAT_SCORE}/100)"
    _vk_report "  skiavk may work but with glitches or occasional crashes."
    _vk_report "  skiavk_all (force-stop) NOT safe on this device."

  elif [ "$VK_COMPAT_SCORE" -le 79 ]; then
    VK_COMPAT_LEVEL="good"
    VK_RECOMMENDED_MODE="skiavk"
    _vk_report ""
    _vk_report "  VERDICT: GOOD (score ${VK_COMPAT_SCORE}/100)"
    _vk_report "  skiavk should work. Skip skiavk_all to avoid edge-case OOM."

  else
    VK_COMPAT_LEVEL="excellent"
    VK_RECOMMENDED_MODE="skiavk_all"
    _vk_report ""
    _vk_report "  VERDICT: EXCELLENT (score ${VK_COMPAT_SCORE}/100)"
    _vk_report "  Full skiavk + skiavk_all safe on this device."
  fi

  # ── Clean up internal helpers ─────────────────────────────────────────────
  unset -f _vk_deduct _vk_report 2>/dev/null || true

  return 0
}

# ============================================================
# write_compat_state()
# ============================================================
# Writes VK compatibility probe results to a persistent state file
# so other scripts and the WebUI can read them without re-probing.
#
# File: /data/local/tmp/adreno_vk_compat_full
# Format: KEY=VALUE (one per line, sourced by shell)
# ============================================================
write_compat_state() {
  local _state_file="/data/local/tmp/adreno_vk_compat_full"
  {
    echo "VK_COMPAT_SCORE=${VK_COMPAT_SCORE:-0}"
    echo "VK_COMPAT_LEVEL=${VK_COMPAT_LEVEL:-unknown}"
    echo "VK_RECOMMENDED_MODE=${VK_RECOMMENDED_MODE:-skiagl}"
    echo "VK_GRALLOC_OK=${VK_GRALLOC_OK:-false}"
    echo "VK_KGSL_OK=${VK_KGSL_OK:-false}"
    echo "VK_EGL_FENCE_OK=${VK_EGL_FENCE_OK:-false}"
    echo "VK_UBWC_OK=${VK_UBWC_OK:-false}"
    echo "VK_DRIVER_OK=${VK_DRIVER_OK:-false}"
    echo "GRALLOC_HAL_VERSION=${GRALLOC_HAL_VERSION:-unknown}"
    echo "GRALLOC_IS_AIDL=${GRALLOC_IS_AIDL:-false}"
    echo "KGSL_GPU_MODEL=${KGSL_GPU_MODEL:-unknown}"
    echo "KERNEL_VERSION_RAW=${KERNEL_VERSION_RAW:-unknown}"
    echo "KGSL_VERSION_RAW=${KGSL_VERSION_RAW:-unknown}"
    # Issues: replace semicolons with |||  for safe single-line storage
    printf 'VK_COMPAT_ISSUES=%s\n' "${VK_COMPAT_ISSUES//;/|||}"
  } > "$_state_file" 2>/dev/null || true
  chmod 644 "$_state_file" 2>/dev/null || true
}

# ============================================================
# read_compat_state()
# ============================================================
# Reads previously-written VK compat state. Call when you want
# to skip re-probing (e.g., service.sh reading post-fs-data.sh results).
# Returns 1 if state file doesn't exist.
# ============================================================
read_compat_state() {
  local _state_file="/data/local/tmp/adreno_vk_compat_full"
  [ -f "$_state_file" ] || return 1
  # Source the state file — sets all VK_COMPAT_* variables
  # shellcheck disable=SC1090
  . "$_state_file" 2>/dev/null || return 1
  # Restore issues semicolon separator
  VK_COMPAT_ISSUES="${VK_COMPAT_ISSUES//|||/;}"
  return 0
}
probe_vulkan_compat_extended() {
  VK_COMPAT_SCORE=100
  VK_COMPAT_LEVEL="safe"
  VK_COMPAT_REASONS=""
  VK_GRALLOC_VERSION="unknown"
  VK_HWVULKAN_PROP=""
  VK_BUILD_DATE_GAP_DAYS=0
  VK_VENDOR_API_LEVEL=0
  VK_DRIVER_FOUND=false

  # ── Helper: subtract points and record reason ──────────────────────────────
  _pvk_deduct() {
    # $1 = points to deduct  $2 = reason string
    VK_COMPAT_SCORE=$(( VK_COMPAT_SCORE - $1 ))
    [ $VK_COMPAT_SCORE -lt 0 ] && VK_COMPAT_SCORE=0
    if [ -z "$VK_COMPAT_REASONS" ]; then
      VK_COMPAT_REASONS="$2"
    else
      VK_COMPAT_REASONS="${VK_COMPAT_REASONS}; $2"
    fi
  }

  # ── Helper: safely read integer prop ──────────────────────────────────────
  _pvk_int_prop() {
    local _v
    _v=$(getprop "$1" 2>/dev/null || echo "0")
    # strip anything non-numeric
    _v="${_v%%[!0-9]*}"
    echo "${_v:-0}"
  }

  # ══════════════════════════════════════════════════════════════════════════
  # RC6 — Vulkan driver .so existence check (CRITICAL, -50)
  # Must be the first check: if there's no driver at all, every other check
  # is moot and we should never waste time on further probes.
  # ══════════════════════════════════════════════════════════════════════════
  for _vl in \
      /vendor/lib64/hw/vulkan.adreno.so \
      /vendor/lib64/hw/vulkan.msm*.so \
      /vendor/lib64/hw/vulkan.*.so \
      /vendor/lib/hw/vulkan.*.so \
      /system/lib64/hw/vulkan.*.so \
      /system/lib/hw/vulkan.*.so \
      /vendor/lib64/libvulkan.so \
      /system/lib64/libvulkan.so; do
    if [ -f "$_vl" ]; then
      VK_DRIVER_FOUND=true
      break
    fi
  done
  unset _vl

  if [ "$VK_DRIVER_FOUND" = "false" ]; then
    _pvk_deduct 50 "RC6: no vulkan.*.so or libvulkan.so found in vendor/system"
  fi

  # ══════════════════════════════════════════════════════════════════════════
  # RC5 — ro.hwui.use_vulkan explicitly disabled (-25)
  # Some OEM device trees set this to false. HWUI checks it before
  # vkCreateInstance — if false, skiavk silently becomes skiagl regardless
  # of debug.hwui.renderer. Deduct hard.
  # ══════════════════════════════════════════════════════════════════════════
  _ro_use_vk=$(getprop ro.hwui.use_vulkan 2>/dev/null || echo "")
  if [ "$_ro_use_vk" = "false" ] || [ "$_ro_use_vk" = "0" ]; then
    _pvk_deduct 25 "RC5: ro.hwui.use_vulkan=${_ro_use_vk} (vendor device tree disables HWUI Vulkan)"
  fi
  unset _ro_use_vk

  # ══════════════════════════════════════════════════════════════════════════
  # RC3+RC9 — ro.hardware.vulkan ICD discovery failure (-35)
  # Android's Vulkan loader (libvulkan.so) discovers ICDs via:
  #   /vendor/etc/vulkan/icd.d/     (preferred, Android 9+)
  #   OR ro.hardware.vulkan property → opens vulkan.${value}.so
  # OEM ROMs set ro.hardware.vulkan to the SoC codename (sm6115, kona, lahaina,
  # sm8450) instead of "adreno". The custom driver ships as vulkan.adreno.so.
  # When the prop says "sm6115", the loader tries vulkan.sm6115.so → ENOENT →
  # vkCreateInstance returns VK_ERROR_INCOMPATIBLE_DRIVER → HWUI falls back.
  # ══════════════════════════════════════════════════════════════════════════
  VK_HWVULKAN_PROP=$(getprop ro.hardware.vulkan 2>/dev/null || echo "")
  if [ -n "$VK_HWVULKAN_PROP" ]; then
    case "$VK_HWVULKAN_PROP" in
      adreno)
        : # correct — no deduction
        ;;
      "")
        # not set at all; libvulkan falls back to icd.d/ discovery which works
        : # no deduction
        ;;
      *)
        # Set to SoC codename or something else — ICD discovery will fail
        # unless vendor also ships a symlink/copy. Check for the named file.
        _named_so="/vendor/lib64/hw/vulkan.${VK_HWVULKAN_PROP}.so"
        if [ ! -f "$_named_so" ]; then
          _pvk_deduct 35 \
            "RC3/RC9: ro.hardware.vulkan='${VK_HWVULKAN_PROP}' but vulkan.${VK_HWVULKAN_PROP}.so absent (ICD discovery fails)"
        fi
        unset _named_so
        ;;
    esac
  fi

  # ══════════════════════════════════════════════════════════════════════════
  # RC1 — Gralloc HAL version detection (-0 to -30)
  # Detection strategy (in priority order):
  #   a) Check for AIDL gralloc service registration (Android 13+)
  #   b) Check for HIDL gralloc4 service (gralloc@4.0)
  #   c) Check for HIDL gralloc3 service (gralloc@3.0)
  #   d) Check for legacy gralloc2 HAL binary
  #   e) Infer from vendor SDK level
  #
  # Penalty logic:
  #   System SDK 31+ (Android 12+) with gralloc ≤ 2: -30 (gralloc2 lacks
  #     USAGE_CPU_READ_OFTEN semantics for UBWC; Vulkan swapchain alloc fails)
  #   System SDK 33+ (Android 13+) with gralloc ≤ 3: -20 (AIDL allocator
  #     interface not present; libvulkan's ANW gralloc path breaks)
  # ══════════════════════════════════════════════════════════════════════════
  _sys_sdk=$(_pvk_int_prop ro.build.version.sdk)

  # Detect gralloc version via service manifest or binary presence
  # AIDL allocator (Android 13+)
  if [ -f /vendor/etc/vintf/manifest.xml ] && \
     grep -q "android.hardware.graphics.allocator" /vendor/etc/vintf/manifest.xml 2>/dev/null && \
     grep -q "IAllocator" /vendor/etc/vintf/manifest.xml 2>/dev/null; then
    VK_GRALLOC_VERSION="aidl"
  # HIDL gralloc 4.0
  elif [ -f /vendor/etc/vintf/manifest.xml ] && \
       grep -q "android.hardware.graphics.mapper@4" /vendor/etc/vintf/manifest.xml 2>/dev/null; then
    VK_GRALLOC_VERSION="4"
  # HIDL gralloc 3.0
  elif [ -f /vendor/etc/vintf/manifest.xml ] && \
       grep -q "android.hardware.graphics.mapper@3" /vendor/etc/vintf/manifest.xml 2>/dev/null; then
    VK_GRALLOC_VERSION="3"
  # HIDL gralloc 2.0 (check for HAL binary presence as fallback)
  elif [ -f /vendor/lib64/hw/gralloc.msm*.so ] || \
       [ -f /vendor/lib64/hw/gralloc.default.so ]; then
    # Check if it's an old gralloc2 module (pre-Treble gralloc2 ships as
    # gralloc.<board>.so; gralloc3/4 ships as a mapper HAL service)
    if ! grep -q "android.hardware.graphics.mapper@3" \
         /vendor/etc/vintf/manifest.xml 2>/dev/null && \
       ! grep -q "android.hardware.graphics.mapper@4" \
         /vendor/etc/vintf/manifest.xml 2>/dev/null; then
      VK_GRALLOC_VERSION="2"
    else
      VK_GRALLOC_VERSION="3"
    fi
  else
    # Fallback: infer from vendor API level
    _vapi=$(_pvk_int_prop ro.vendor.api_level)
    if [ "$_vapi" -ge 33 ] 2>/dev/null; then
      VK_GRALLOC_VERSION="aidl"
    elif [ "$_vapi" -ge 30 ] 2>/dev/null; then
      VK_GRALLOC_VERSION="4"
    elif [ "$_vapi" -ge 28 ] 2>/dev/null; then
      VK_GRALLOC_VERSION="3"
    elif [ "$_vapi" -gt 0 ] 2>/dev/null; then
      VK_GRALLOC_VERSION="2"
    fi
    unset _vapi
  fi

  # Apply gralloc mismatch penalties
  case "$VK_GRALLOC_VERSION" in
    2)
      if [ "$_sys_sdk" -ge 31 ] 2>/dev/null; then
        _pvk_deduct 30 \
          "RC1: gralloc2 (legacy HIDL) on system SDK ${_sys_sdk} — vkCreateSwapchainKHR USAGE flags incompatible"
      elif [ "$_sys_sdk" -ge 29 ] 2>/dev/null; then
        _pvk_deduct 15 \
          "RC1: gralloc2 on system SDK ${_sys_sdk} — marginal; UBWC alloc may fail on Vulkan swapchain"
      fi
      ;;
    3)
      if [ "$_sys_sdk" -ge 33 ] 2>/dev/null; then
        _pvk_deduct 20 \
          "RC1: gralloc3 HIDL on system SDK ${_sys_sdk} — AIDL allocator interface absent; libvulkan ANW path broken"
      fi
      ;;
    4|aidl|unknown)
      : # gralloc4/AIDL on any SDK or unknown — no deduction
      ;;
  esac
  unset _sys_sdk

  # ══════════════════════════════════════════════════════════════════════════
  # RC4 — Build date / API level gap (-0 to -25)
  # A large gap between vendor build date and system build date indicates the
  # vendor image is from a completely different Android generation. This
  # correlates with KGSL IOCTL table mismatches, VNDK ABI changes, and
  # EGL/Vulkan extension set differences.
  # ══════════════════════════════════════════════════════════════════════════
  _vendor_api=$(_pvk_int_prop ro.vendor.api_level)
  # Fallback: some devices use ro.product.first_api_level or ro.board.api_level
  if [ "$_vendor_api" -eq 0 ] 2>/dev/null; then
    _vendor_api=$(_pvk_int_prop ro.product.first_api_level)
  fi
  if [ "$_vendor_api" -eq 0 ] 2>/dev/null; then
    _vendor_api=$(_pvk_int_prop ro.board.api_level)
  fi
  VK_VENDOR_API_LEVEL="$_vendor_api"

  _sys_api=$(_pvk_int_prop ro.build.version.sdk)

  if [ "$_vendor_api" -gt 0 ] && [ "$_sys_api" -gt 0 ] 2>/dev/null; then
    _api_gap=$(( _sys_api - _vendor_api ))
    if [ "$_api_gap" -ge 6 ] 2>/dev/null; then
      # ≥6 SDK levels behind (≥3 Android major versions)
      _pvk_deduct 25 \
        "RC4: vendor API level ${_vendor_api} vs system SDK ${_sys_api} (gap=${_api_gap}) — VNDK ABI mismatch probable"
    elif [ "$_api_gap" -ge 4 ] 2>/dev/null; then
      _pvk_deduct 15 \
        "RC4: vendor API level ${_vendor_api} vs system SDK ${_sys_api} (gap=${_api_gap}) — VNDK drift, marginal compatibility"
    elif [ "$_api_gap" -ge 2 ] 2>/dev/null; then
      _pvk_deduct 5 \
        "RC4: vendor API level ${_vendor_api} vs system SDK ${_sys_api} (gap=${_api_gap}) — minor drift"
    fi
    unset _api_gap
  fi
  unset _vendor_api _sys_api

  # ══════════════════════════════════════════════════════════════════════════
  # RC2 — KGSL kernel version probe (-0 to -20)
  # The custom Adreno driver embeds its expected KGSL IOCTL version in the
  # driver binary. On old kernels, newer IOCTL codes return ENOTTY, causing
  # the driver to segfault. The KGSL version is readable from sysfs.
  # ══════════════════════════════════════════════════════════════════════════
  _kgsl_ver=""
  # Try sysfs (available on most Qualcomm kernels)
  for _kp in \
      /sys/class/kgsl/kgsl-3d0/kgsl_version \
      /sys/class/kgsl/kgsl/kgsl_version \
      /proc/gpu/kgsl_version; do
    if [ -f "$_kp" ]; then
      { IFS= read -r _kgsl_ver; } < "$_kp" 2>/dev/null || _kgsl_ver=""
      _kgsl_ver="${_kgsl_ver%%$'\r'}"
      break
    fi
  done
  unset _kp

  if [ -n "$_kgsl_ver" ]; then
    # Parse major.minor — KGSL 3.14 and below is pre-Android-10 era kernels
    # that lack IOCTL_KGSL_GPU_COMMAND_V2 and timeline fence support.
    _kgsl_major="${_kgsl_ver%%.*}"
    _kgsl_minor="${_kgsl_ver#*.}"
    _kgsl_minor="${_kgsl_minor%%.*}"
    if [ "$_kgsl_major" -lt 3 ] 2>/dev/null; then
      _pvk_deduct 20 \
        "RC2: KGSL version ${_kgsl_ver} < 3.x — IOCTL table predates Android 9; custom driver IOCTLs return ENOTTY"
    elif [ "$_kgsl_major" -eq 3 ] && [ "$_kgsl_minor" -le 14 ] 2>/dev/null; then
      _pvk_deduct 15 \
        "RC2: KGSL version ${_kgsl_ver} ≤ 3.14 — timeline fence sync absent; Vulkan swapchain deadlock risk"
    elif [ "$_kgsl_major" -eq 3 ] && [ "$_kgsl_minor" -le 18 ] 2>/dev/null; then
      _pvk_deduct 8 \
        "RC2: KGSL version ${_kgsl_ver} ≤ 3.18 — GPU_COMMAND_V3 absent; minor compat risk with custom driver"
    fi
    unset _kgsl_major _kgsl_minor
  fi
  unset _kgsl_ver

  # ══════════════════════════════════════════════════════════════════════════
  # RC7 — VNDK version gap (-0 to -15)
  # The system's libvulkan.so and libhwui.so are compiled against a specific
  # VNDK snapshot. If the vendor partition ships a significantly older VNDK,
  # the Vulkan loader may load the wrong libEGL/libGLESv2 symbols, causing
  # vkCreateInstance to fail or produce a corrupt VkDevice.
  # ══════════════════════════════════════════════════════════════════════════
  _vendor_vndk=$(_pvk_int_prop ro.vndk.version)
  _sys_vndk=$(_pvk_int_prop ro.build.version.sdk)
  if [ "$_vendor_vndk" -gt 0 ] && [ "$_sys_vndk" -gt 0 ] 2>/dev/null; then
    _vndk_gap=$(( _sys_vndk - _vendor_vndk ))
    if [ "$_vndk_gap" -ge 4 ] 2>/dev/null; then
      _pvk_deduct 15 \
        "RC7: VNDK version ${_vendor_vndk} vs system SDK ${_sys_vndk} (gap=${_vndk_gap}) — ABI symbols may mismatch in libvulkan dispatch table"
    elif [ "$_vndk_gap" -ge 2 ] 2>/dev/null; then
      _pvk_deduct 5 \
        "RC7: VNDK version ${_vendor_vndk} vs system SDK ${_sys_vndk} (gap=${_vndk_gap}) — minor ABI drift"
    fi
    unset _vndk_gap
  fi
  unset _vendor_vndk _sys_vndk

  # ══════════════════════════════════════════════════════════════════════════
  # RC8 — EGL_ANDROID_native_fence_sync inference (-0 to -15)
  # HWUI's skiavkthreaded requires EGL_ANDROID_native_fence_sync to export
  # VkSemaphore as a sync_file_fence FD for SurfaceFlinger compositing.
  # This extension was mandated in CDD starting Android 9 (API 28). Vendor
  # images older than API 27 almost certainly lack it; API 28-29 are marginal.
  # We can't check EGL directly from shell, so we infer from vendor API level.
  # ══════════════════════════════════════════════════════════════════════════
  _inf_vapi=$(_pvk_int_prop ro.vendor.api_level)
  if [ "$_inf_vapi" -eq 0 ] 2>/dev/null; then
    _inf_vapi=$(_pvk_int_prop ro.product.first_api_level)
  fi
  if [ "$_inf_vapi" -gt 0 ] 2>/dev/null; then
    if [ "$_inf_vapi" -lt 28 ] 2>/dev/null; then
      _pvk_deduct 15 \
        "RC8: vendor API ${_inf_vapi} < 28 — EGL_ANDROID_native_fence_sync likely absent; skiavkthreaded fence export fails"
    elif [ "$_inf_vapi" -lt 30 ] 2>/dev/null; then
      _pvk_deduct 7 \
        "RC8: vendor API ${_inf_vapi} < 30 — EGL_ANDROID_native_fence_sync marginal; timeline fence interop may deadlock"
    fi
  fi
  unset _inf_vapi

  # ══════════════════════════════════════════════════════════════════════════
  # Build date gap estimation
  # Read ro.vendor.build.date.utc and ro.build.date.utc (seconds since epoch).
  # These are written by OEM build systems and present on virtually every device.
  # Gap > 18 months (approx 548 days) = high-risk old-vendor scenario.
  # ══════════════════════════════════════════════════════════════════════════
  _vbuild_utc=$(_pvk_int_prop ro.vendor.build.date.utc)
  _sbuild_utc=$(_pvk_int_prop ro.build.date.utc)
  if [ "$_vbuild_utc" -gt 0 ] && [ "$_sbuild_utc" -gt 0 ] 2>/dev/null; then
    if [ "$_sbuild_utc" -gt "$_vbuild_utc" ] 2>/dev/null; then
      _gap_secs=$(( _sbuild_utc - _vbuild_utc ))
      VK_BUILD_DATE_GAP_DAYS=$(( _gap_secs / 86400 ))
    else
      VK_BUILD_DATE_GAP_DAYS=0
    fi
    unset _gap_secs
  fi
  unset _vbuild_utc _sbuild_utc

  # Penalise large build date gaps if API level gap wasn't already penalised
  # (e.g., vendor is same API level but very old security patch — KGSL drift)
  if [ "$VK_BUILD_DATE_GAP_DAYS" -gt 730 ] 2>/dev/null; then
    _pvk_deduct 10 \
      "RC4: build date gap ~${VK_BUILD_DATE_GAP_DAYS} days (>24 months) — KGSL/HAL drift beyond API level gap"
  elif [ "$VK_BUILD_DATE_GAP_DAYS" -gt 365 ] 2>/dev/null; then
    _pvk_deduct 5 \
      "RC4: build date gap ~${VK_BUILD_DATE_GAP_DAYS} days (>12 months) — minor KGSL drift possible"
  fi

  # ══════════════════════════════════════════════════════════════════════════
  # Floor and classify
  # ══════════════════════════════════════════════════════════════════════════
  [ "$VK_COMPAT_SCORE" -lt 0 ] && VK_COMPAT_SCORE=0

  if   [ "$VK_COMPAT_SCORE" -ge 70 ] 2>/dev/null; then
    VK_COMPAT_LEVEL="safe"
  elif [ "$VK_COMPAT_SCORE" -ge 50 ] 2>/dev/null; then
    VK_COMPAT_LEVEL="marginal"
  elif [ "$VK_COMPAT_SCORE" -ge 30 ] 2>/dev/null; then
    VK_COMPAT_LEVEL="risky"
  else
    VK_COMPAT_LEVEL="blocked"
  fi

  # Clean up helpers
  unset -f _pvk_deduct _pvk_int_prop 2>/dev/null || true

  return 0
}


# ============================================================
# patch_ro_hardware_vulkan()
# ============================================================
# Attempts to fix the ICD discovery failure caused by ro.hardware.vulkan
# being set to an OEM SoC codename instead of "adreno".
#
# Call ONLY after boot_completed + resetprop is confirmed available.
# Rewrites the property in-session so vkCreateInstance in freshly-forked
# Zygote children uses the correct ICD path.
#
# Sets:
#   RO_HW_VK_PATCHED — true | false
#   RO_HW_VK_OLD     — original value (empty if not set)
# ============================================================
patch_ro_hardware_vulkan() {
  RO_HW_VK_PATCHED=false
  RO_HW_VK_OLD=""

  if ! command -v resetprop >/dev/null 2>&1; then
    return 1
  fi

  RO_HW_VK_OLD=$(getprop ro.hardware.vulkan 2>/dev/null || echo "")

  # If already "adreno" or not set, nothing to do
  case "$RO_HW_VK_OLD" in
    adreno|"") return 0 ;;
  esac

  # Verify that vulkan.adreno.so actually exists before patching.
  # If it doesn't, patching to "adreno" won't help — let existing value stand.
  local _adreno_so=false
  for _s in \
      /vendor/lib64/hw/vulkan.adreno.so \
      /vendor/lib/hw/vulkan.adreno.so; do
    [ -f "$_s" ] && { _adreno_so=true; break; }
  done
  unset _s

  if [ "$_adreno_so" = "true" ]; then
    resetprop ro.hardware.vulkan adreno 2>/dev/null && RO_HW_VK_PATCHED=true
  fi
  unset _adreno_so

  return 0
}

# Backwards-compat alias — probe function availability check
# probe_vulkan_compat_extended and patch_ro_hardware_vulkan are defined above
