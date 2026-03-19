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
  # Pre-compute CR once — avoids spawning a subshell on every config line.
  # $'\r' is a bash/ksh extension; printf is portable across mksh/ash/toybox sh.
  local _CR
  _CR=$(printf '\r')
  while IFS='= ' read -r _k _v; do
    # Skip blank lines and comments
    case "$_k" in '#'*|'') continue ;; esac
    # Strip carriage return from value (Windows line endings)
    _v="${_v%"$_CR"}"
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
          normal|skiavk|skiagl) ;;
          [Nn][Oo][Rr][Mm][Aa][Ll])            _v='normal' ;;
          [Ss][Kk][Ii][Aa][Vv][Kk])            _v='skiavk' ;;
          [Ss][Kk][Ii][Aa][Gg][Ll])            _v='skiagl' ;;
          # Legacy: skiavkthreaded/skiaglthreaded were removed as separate modes.
          # renderengine.backend is now folded into skiavk/skiagl.
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

  # Pre-compute CR once — same rationale as load_config.
  local _MCR
  _MCR=$(printf '\r')

  if [ -L "/data/adb/metamodule" ]; then
    META_LINK=$(readlink -f "/data/adb/metamodule" 2>/dev/null)
    if [ -n "$META_LINK" ] && [ -f "$META_LINK/module.prop" ] && \
       [ ! -f "$META_LINK/disable" ] && [ ! -f "$META_LINK/remove" ]; then
      while IFS='=' read -r _mk _mv; do
        case "$_mk" in
          id)   METAMODULE_ID="${_mv%"$_MCR"}" ;;
          name) METAMODULE_NAME="${_mv%"$_MCR"}" ;;
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
          case "$_mk" in name) METAMODULE_NAME="${_mv%"$_MCR"}"; break ;; esac
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
# write_compat_state()
# ============================================================
# Writes VK compatibility probe results to a persistent state file
# so other scripts and the WebUI can read them without re-probing.
# Must be called immediately after probe_vulkan_compat_extended(),
# which is responsible for setting all VK_*_OK and VK_COMPAT_ISSUES
# variables that this function writes.
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
    echo "FORCE_SKIAVKTHREADED_BACKEND=${FORCE_SKIAVKTHREADED_BACKEND:-n}"
    # Issues: replace semicolons with ||| for safe single-line storage.
    # NOTE: ${var//pat/rep} is bash-only; use sed for POSIX sh (mksh/sh on Android).
    printf 'VK_COMPAT_ISSUES=%s\n' \
      "$(printf '%s' "${VK_COMPAT_ISSUES:-}" | sed 's/;/|||/g' 2>/dev/null)"
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
  # NOTE: ${var//pat/rep} is bash-only; use sed for POSIX sh (mksh/sh on Android).
  VK_COMPAT_ISSUES="$(printf '%s' "${VK_COMPAT_ISSUES:-}" | sed 's/|||/;/g' 2>/dev/null)"
  return 0
}
probe_vulkan_compat_extended() {
  VK_COMPAT_SCORE=100
  VK_COMPAT_LEVEL="safe"
  VK_COMPAT_REASONS=""
  VK_COMPAT_ISSUES=""
  VK_GRALLOC_VERSION="unknown"
  VK_HWVULKAN_PROP=""
  VK_BUILD_DATE_GAP_DAYS=0
  VK_VENDOR_API_LEVEL=0
  VK_DRIVER_FOUND=false
  # Per-subsystem pass/fail flags populated during checks below;
  # written to the compat state file by write_compat_state().
  VK_DRIVER_OK=false
  VK_GRALLOC_OK=false
  VK_KGSL_OK=true       # assume OK until RC2 fires
  VK_EGL_FENCE_OK=true  # assume OK until RC8 fires
  VK_UBWC_OK=true       # not directly testable from shell; assumed OK

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
  else
    VK_DRIVER_OK=true
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

  # Detect gralloc version via service manifest or binary presence.
  # BUG-5 FIX: On Android 12+ devices, VINTF manifests may be split across
  # /vendor/etc/vintf/manifest/*.xml fragments. A grep on only the top-level
  # manifest.xml can miss the gralloc mapper entry entirely — returning a false
  # "not found" and letting the code fall through to incorrect binary-presence
  # heuristics. We now scan all manifest files (top-level + all fragments), and
  # only commit to a VINTF result when we find a known gralloc interface string.
  # If no fragment matches, we fall through to the .so / vendor API level path.
  _vk_gralloc_from_vintf=""
  for _vmf in \
      /vendor/etc/vintf/manifest.xml \
      /vendor/manifest.xml \
      /odm/etc/vintf/manifest.xml \
      /odm/manifest.xml \
      /vendor/etc/vintf/manifest/*.xml \
      /odm/etc/vintf/manifest/*.xml; do
    [ -f "$_vmf" ] || continue
    if grep -q "android.hardware.graphics.allocator" "$_vmf" 2>/dev/null && \
       grep -q "IAllocator" "$_vmf" 2>/dev/null; then
      _vk_gralloc_from_vintf="aidl"; break
    fi
    if grep -q "android.hardware.graphics.mapper@4" "$_vmf" 2>/dev/null; then
      _vk_gralloc_from_vintf="4"; break
    fi
    if grep -q "android.hardware.graphics.mapper@3" "$_vmf" 2>/dev/null; then
      _vk_gralloc_from_vintf="3"; break
    fi
    if grep -q "android.hardware.graphics.mapper@2" "$_vmf" 2>/dev/null; then
      _vk_gralloc_from_vintf="2"; break
    fi
  done
  unset _vmf

  if [ -n "$_vk_gralloc_from_vintf" ]; then
    # VINTF manifest (full scan including fragments) gave a definitive answer.
    VK_GRALLOC_VERSION="$_vk_gralloc_from_vintf"
    unset _vk_gralloc_from_vintf
  # HIDL gralloc 2.0 (check for HAL binary presence as fallback when VINTF
  # has no mapper entry — covers pre-Treble gralloc2 devices and split manifests
  # where all fragment scans found nothing)
  elif [ -n "$(ls /vendor/lib64/hw/gralloc.msm*.so 2>/dev/null | head -1)" ] || \
       [ -f /vendor/lib64/hw/gralloc.default.so ]; then
    unset _vk_gralloc_from_vintf
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
    unset _vk_gralloc_from_vintf
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
  # VK_GRALLOC_OK: true when gralloc is adequate for the current system SDK.
  # If the case above deducted points, gralloc is not compatible enough.
  # Track this by inspecting whether any RC1 reason was recorded.
  case "$VK_COMPAT_REASONS" in
    *RC1:*) VK_GRALLOC_OK=false ;;
    *)      VK_GRALLOC_OK=true  ;;
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
      _kgsl_ver=$(printf '%s' "$_kgsl_ver" | tr -d '\r')
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
      VK_KGSL_OK=false
      _pvk_deduct 20 \
        "RC2: KGSL version ${_kgsl_ver} < 3.x — IOCTL table predates Android 9; custom driver IOCTLs return ENOTTY"
    elif [ "$_kgsl_major" -eq 3 ] && [ "$_kgsl_minor" -le 14 ] 2>/dev/null; then
      VK_KGSL_OK=false
      _pvk_deduct 15 \
        "RC2: KGSL version ${_kgsl_ver} ≤ 3.14 — timeline fence sync absent; Vulkan swapchain deadlock risk"
    elif [ "$_kgsl_major" -eq 3 ] && [ "$_kgsl_minor" -le 18 ] 2>/dev/null; then
      VK_KGSL_OK=false
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
      VK_EGL_FENCE_OK=false
      _pvk_deduct 15 \
        "RC8: vendor API ${_inf_vapi} < 28 — EGL_ANDROID_native_fence_sync likely absent; skiavkthreaded fence export fails"
    elif [ "$_inf_vapi" -lt 30 ] 2>/dev/null; then
      VK_EGL_FENCE_OK=false
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

  # Expose the accumulated deduction reasons under the name that write_compat_state
  # writes to the state file and the WebUI reads.  VK_COMPAT_REASONS is the
  # internal accumulator; VK_COMPAT_ISSUES is the public output variable.
  VK_COMPAT_ISSUES="$VK_COMPAT_REASONS"

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

# Backwards-compat aliases — probe function availability check
# probe_vulkan_compat_extended and patch_ro_hardware_vulkan are defined above
# probe_vulkan_stack_compatibility was the old name for probe_vulkan_compat_extended
probe_vulkan_stack_compatibility() { probe_vulkan_compat_extended "$@"; }
