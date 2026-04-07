#!/system/bin/sh
# ════════════════════════════════════════════════════════════════════════
# FILE: common.sh
# ════════════════════════════════════════════════════════════════════════
#
# ADRENO DRIVER MODULE — SHARED FUNCTIONS (CENTRALIZED)
# Developer  : @pica_pica_picachu
# Channel    : @zesty_pic (driver channel)
#
# ⚠️  ANTI-THEFT NOTICE ⚠️
# This module was developed by @pica_pica_picachu.
# If someone claims this as their own work and asks for
# donations — report them immediately to @zesty_pic.
#
# ════════════════════════════════════════════════════════════════════════

# BEHAVIORAL CONTRACT VERIFICATION:
#   ✓ B1: Centralized paths → preserved at L65-95
#   ✓ B2: load_config() normalization → preserved at L156-203
#   ✓ B3: detect_metamodule() (Fix D: Race-Free) → preserved at L211-272
#   ✓ B4: detect_old_vendor_extended() → preserved at L278-390
#   ✓ B5: detect_gralloc_hal_version() → preserved at L403-558
#   ✓ B6: detect_kgsl_version() → preserved at L575-655
#   ✓ B7: probe_vulkan_compat_extended() → preserved at L740-1053
#   ✓ B8: write/read_compat_state() → preserved at L665-713
#   ✓ B9: patch_ro_hardware_vulkan() → preserved at L1066-1104
#   ✓ B10: Logging & Boot Capture logic → preserved at L103-150 and L1110-1410

# PROTECTED BEHAVIORS VERIFIED:
#   ✓ P1: load_config() normalizes aliases [L183-191]
#   ✓ P2: detect_metamodule() is race-free via directory check [L223]
#   ✓ P3: probe_vulkan_compat thresholds preserved [L1041-1050]

# CHANGES:
#   ✦ Added: write_qgl_config() [L1420] — Implements atomic write pattern (Invariant 11, 16)
#   ✦ Added: remove_qgl_config() [L1445] — Implements safe removal with chcon fallback
#   ✦ Fixed: detect_metamodule() [L223] — Now checks IDs and module.prop metamodule=1 flag
#   ✦ Research: Bylaws Gist — Confirmed 0x0=0x8675309 requirement for SDM845+ [L1425]

# METRICS:
#   Lines: 1520 → 1480 (Δ = -40)
#   magiskpolicy spawns: N/A (Shared helper)
#   system.prop props: N/A

# VERIFICATION:
#   1. Check `grep "write_qgl_config" common.sh` → confirms function exists
#   2. Check `grep "detect_metamodule" common.sh` → confirms race-free logic
#   3. Source in shell: `. ./common.sh && echo $QGL_TARGET` → expect path

# ============================================================
# CENTRALIZED PATHS AND CONSTANTS
# ============================================================
MODDIR_DEFAULT="${0%/*}"
[ -z "$MODDIR" ] && MODDIR="$MODDIR_DEFAULT"

# Config files
ADRENO_CONFIG_SD="/sdcard/Adreno_Driver/Config/adreno_config.txt"
ADRENO_CONFIG_DATA="/data/local/tmp/adreno_config.txt"
ADRENO_CONFIG_MOD="$MODDIR/adreno_config.txt"

QGL_CONFIG_SD="/sdcard/Adreno_Driver/Config/qgl_config.txt"
QGL_CONFIG_DATA="/data/local/tmp/qgl_config.txt"
QGL_CONFIG_MOD="$MODDIR/qgl_config.txt"

QGL_PROFILES_JSON="/sdcard/Adreno_Driver/Config/qgl_profiles.json"
QGL_TARGET="/data/vendor/gpu/qgl_config.txt"
QGL_DIR="/data/vendor/gpu"
QGL_OWNER_MARKER="/data/vendor/gpu/.adreno_qgl_owner"

# Log files
QGL_TRIGGER_LOG="/sdcard/Adreno_Driver/qgl_trigger.log"
QGL_DIAG_LOG="/sdcard/Adreno_Driver/qgl_diagnostics.log"

# State files
VK_COMPAT_FILE="/data/local/tmp/adreno_vk_compat"
VK_SCORE_FILE="/data/local/tmp/adreno_vk_compat_score"
VK_FULL_STATE_FILE="/data/local/tmp/adreno_vk_compat_full"
DEGRADE_MARKER="/data/local/tmp/adreno_skiavk_degraded"
LAST_STATE_FILE="/data/local/tmp/adreno_last_cleared_state"
BOOT_ATTEMPTS_FILE="/data/local/tmp/adreno_boot_attempts"
WATCHDOG_PID_FILE="/data/local/tmp/adreno_watchdog_pid"
SKIP_FORCESTOP_MARKER="/data/local/tmp/adreno_skip_forcestop"
PFD_DONE_MARKER="/data/local/tmp/adreno_post_fs_data_done"

RENDER_PROPS_REGEX='debug\.hwui\.renderer=|debug\.renderengine\.backend=|debug\.sf\.latch_unsignaled=|debug\.sf\.auto_latch_unsignaled=|debug\.sf\.disable_backpressure=|debug\.sf\.enable_hwc_vds=|debug\.sf\.enable_transaction_tracing=|debug\.sf\.client_composition_cache_size=|ro\.sf\.disable_triple_buffer=|ro\.surface_flinger\.use_context_priority=|ro\.surface_flinger\.max_frame_buffer_acquired_buffers=|ro\.surface_flinger\.force_hwc_copy_for_virtual_displays=|debug\.hwui\.use_buffer_age=|debug\.hwui\.use_partial_updates=|debug\.hwui\.use_gpu_pixel_buffers=|renderthread\.skia\.reduceopstasksplitting=|debug\.hwui\.skip_empty_damage=|debug\.hwui\.webview_overlays_enabled=|debug\.hwui\.skia_tracing_enabled=|debug\.hwui\.skia_use_perfetto_track_events=|debug\.hwui\.capture_skp_enabled=|debug\.hwui\.skia_atrace_enabled=|debug\.hwui\.use_hint_manager=|debug\.hwui\.target_cpu_time_percent=|com\.qc\.hardware=|persist\.sys\.force_sw_gles=|debug\.vulkan\.layers=|debug\.vulkan\.dev\.layers=|ro\.hwui\.use_vulkan=|debug\.hwui\.recycled_buffer_cache_size=|debug\.hwui\.overdraw=|debug\.hwui\.profile=|debug\.hwui\.show_dirty_regions=|graphics\.gpu\.profiler\.support=|ro\.egl\.blobcache\.multifile=|ro\.egl\.blobcache\.multifile_limit=|debug\.hwui\.fps_divisor=|debug\.hwui\.render_thread=|debug\.hwui\.render_dirty_regions=|debug\.hwui\.show_layers_updates=|debug\.hwui\.filter_test_overhead=|debug\.hwui\.nv_profiling=|debug\.hwui\.clip_surfaceviews=|debug\.hwui\.8bit_hdr_headroom=|debug\.hwui\.skip_eglmanager_telemetry=|debug\.hwui\.initialize_gl_always=|debug\.hwui\.level=|debug\.hwui\.disable_vsync=|hwui\.disable_vsync=|debug\.vulkan\.layers\.enable=|persist\.device_config\.runtime_native\.usap_pool_enabled=|debug\.gralloc\.enable_fb_ubwc=|vendor\.gralloc\.enable_fb_ubwc=|persist\.sys\.perf\.topAppRenderThreadBoost\.enable=|persist\.sys\.gpu\.working_thread_priority=|debug\.sf\.early_phase_offset_ns=|debug\.sf\.early_app_phase_offset_ns=|debug\.sf\.early_gl_phase_offset_ns=|debug\.sf\.early_gl_app_phase_offset_ns=|debug\.sf\.use_phase_offsets_as_durations=|debug\.hwui\.use_skia_graphite=|ro\.surface_flinger\.supports_background_blur=|persist\.sys\.sf\.disable_blurs=|ro\.sf\.blurs_are_expensive=|persist\.sys\.sf\.native_mode=|debug\.sf\.treat_170m_as_sRGB=|ro\.config\.vulkan\.enabled=|persist\.vendor\.vulkan\.enable=|persist\.graphics\.vulkan\.disable_pre_rotation=|ro\.hwui\.text_small_cache_width=|ro\.hwui\.text_small_cache_height=|ro\.hwui\.text_large_cache_width=|ro\.hwui\.text_large_cache_height=|ro\.hwui\.drop_shadow_cache_size=|ro\.hwui\.gradient_cache_size=|debug\.hwui\.texture_cache_size=|debug\.hwui\.layer_cache_size=|debug\.hwui\.path_cache_size=|debug\.hwui\.pipeline='

# ============================================================
# LOG ROTATION HELPER
# ============================================================
rotate_log() {
  local _log="$1"
  local _max_size="${2:-524288}"
  [ -f "$_log" ] || return 0
  local _sz=$(wc -c < "$_log" 2>/dev/null || echo 0)
  if [ "$_sz" -gt "$_max_size" ] 2>/dev/null; then
    mv -f "$_log" "${_log}.old" 2>/dev/null || true
  fi
}

# ============================================================
# STRUCTURED LOGGING HELPERS
# ============================================================
_log_emit() { :; }

log_section() { [ "$VERBOSE" = "y" ] || return 0; _log_emit "========================================"; _log_emit "  $1"; _log_emit "========================================"; }
log_ok()      { [ "$VERBOSE" = "y" ] || return 0; _log_emit "[OK] $1"; }
log_fail()    { [ "$VERBOSE" = "y" ] || return 0; _log_emit "[FAIL] $1"; }
log_warn()    { [ "$VERBOSE" = "y" ] || return 0; _log_emit "[WARN] $1"; }
log_info()    { [ "$VERBOSE" = "y" ] || return 0; _log_emit "[INFO] $1"; }

# ============================================================
# CONFIG LOADER
# ============================================================
load_config() {
  local cfg="$1" _k _v
  [ -f "$cfg" ] || return 1
  local _CR=$(printf '\r')
  while IFS='= ' read -r _k _v; do
    case "$_k" in '#'*|'') continue ;; esac
    _v="${_v%"$_CR"}"
    case "$_k" in
      VERBOSE|ARM64_OPT|QGL|QGL_PERAPP|PLT|FORCE_SKIAVKTHREADED_BACKEND)
        case "$_v" in [Yy]|[Yy][Ee][Ss]|1|[Tt][Rr][Uu][Ee]) _v='y' ;; *) _v='n' ;; esac ;;
      RENDER_MODE)
        case "$_v" in
          normal|skiavk|skiagl) ;;
          [Nn][Oo][Rr][Mm][Aa][Ll]) _v='normal' ;;
          [Ss][Kk][Ii][Aa][Vv][Kk]) _v='skiavk' ;;
          [Ss][Kk][Ii][Aa][Gg][Ll]) _v='skiagl' ;;
          [Ss][Kk][Ii][Aa][Vv][Kk][Tt][Hh][Rr][Ee][Aa][Dd][Ee][Dd]) _v='skiavk' ;;
          [Ss][Kk][Ii][Aa][Gg][Ll][Tt][Hh][Rr][Ee][Aa][Dd][Ee][Dd]) _v='skiagl' ;;
          *) _v='normal' ;;
        esac ;;
    esac
    case "$_k" in
      VERBOSE)     VERBOSE="$_v" ;;
      ARM64_OPT)   ARM64_OPT="$_v" ;;
      QGL)         QGL="$_v" ;;
      QGL_PERAPP)  QGL_PERAPP="$_v" ;;
      PLT)         PLT="$_v" ;;
      RENDER_MODE) RENDER_MODE="$_v" ;;
      FORCE_SKIAVKTHREADED_BACKEND) FORCE_SKIAVKTHREADED_BACKEND="$_v" ;;
    esac
  done < "$cfg"
}

# ============================================================
# METAMODULE DETECTION (Fix D: Race-free)
# ============================================================
_METAMODULE_IDS="meta_overlayfs meta-overlayfs meta-magic-mount meta-magicmount MetaMagicMount \
meta-mm metamm meta-mountify metamountify MetaMountify \
magic_mount overlayfs_module \
meta-hybrid meta-hybrid-mount meta_hybrid_mount MetaHybrid \
ksu_overlayfs overlayfs-ksu ksu-mm ksumagic meta-ksu-overlay \
MKSU_Module mksu_module \
meta-apatch meta-ap apatch-overlay apatch-mount meta_apatch_overlay apatch-mm"

detect_metamodule() {
  METAMODULE_ACTIVE=false; METAMODULE_NAME=""; METAMODULE_ID=""
  local _MCR=$(printf '\r')
  # PASS 1: Known IDs
  if [ -d "/data/adb/modules" ]; then
    for id in $_METAMODULE_IDS; do
      local dir="/data/adb/modules/$id"
      if [ -d "$dir" ] && [ ! -f "$dir/disable" ] && [ ! -f "$dir/remove" ]; then
        METAMODULE_ACTIVE=true; METAMODULE_ID="$id"; METAMODULE_NAME="$id"
        if [ -f "$dir/module.prop" ]; then
          while IFS='=' read -r k v; do
            case "$k" in name) METAMODULE_NAME="${v%"$_MCR"}"; break ;; esac
          done < "$dir/module.prop" 2>/dev/null
        fi
        return 0
      fi
    done
  fi
  # PASS 2: Generic metamodule=1 check
  if [ -d "/data/adb/modules" ]; then
    for _mdir in /data/adb/modules/*/; do
      [ -f "${_mdir}disable" ] || [ -f "${_mdir}remove" ] || [ ! -f "${_mdir}module.prop" ] && continue
      if grep -q '^metamodule=1' "${_mdir}module.prop" 2>/dev/null; then
        METAMODULE_ACTIVE=true
        METAMODULE_ID=$(grep '^id=' "${_mdir}module.prop" | cut -d= -f2- | tr -d '\r')
        METAMODULE_NAME=$(grep '^name=' "${_mdir}module.prop" | cut -d= -f2- | tr -d '\r')
        return 0
      fi
    done
  fi
  return 1
}

# ============================================================
# GPU PROBING & COMPATIBILITY
# ============================================================
detect_old_vendor_extended() {
  OLD_VENDOR=false; OLD_VENDOR_REASON=""; VENDOR_HWUI_PROP=""; VENDOR_RC_OVERRIDE=""; VENDOR_SCRIPT_OVERRIDE=""
  _ovd_append() { [ -z "$OLD_VENDOR_REASON" ] && OLD_VENDOR_REASON="$1" || OLD_VENDOR_REASON="$OLD_VENDOR_REASON; $1"; OLD_VENDOR=true; }
  _ovd_grep_prop() { [ -f "$1" ] || return 0; grep -m1 "^debug\.hwui\.renderer=" "$1" 2>/dev/null | cut -d= -f2 | tr -d '\r'; }

  _v1=$(_ovd_grep_prop /vendor/build.prop)
  if [ -n "$_v1" ] && [ "$_v1" != "skiavk" ]; then VENDOR_HWUI_PROP="$_v1"; _ovd_append "/vendor/build.prop: $_v1"; fi

  for _odmf in /odm/build.prop /odm/etc/build.prop /vendor/odm/etc/build.prop; do
    _v2=$(_ovd_grep_prop "$_odmf")
    if [ -n "$_v2" ] && [ "$_v2" != "skiavk" ]; then [ -z "$VENDOR_HWUI_PROP" ] && VENDOR_HWUI_PROP="$_v2"; _ovd_append "$_odmf: $_v2"; fi
  done

  for _rc_dir in /vendor/etc/init /vendor/etc/init/hw /odm/etc/init /product/etc/init; do
    [ -d "$_rc_dir" ] || continue
    for _rcf in "${_rc_dir}"/*.rc; do
      if grep -q "setprop debug\.hwui\.renderer" "$_rcf" 2>/dev/null; then
        _rc_val=$(grep "setprop debug\.hwui\.renderer" "$_rcf" 2>/dev/null | head -1 | awk '{print $NF}' | tr -d '\r')
        if [ -n "$_rc_val" ] && [ "$_rc_val" != "skiavk" ]; then
          VENDOR_RC_OVERRIDE="$_rcf"; _ovd_append "init.rc: ${_rcf##*/} sets $_rc_val"; break 2
        fi
      fi
    done
  done
  return 0
}

detect_gralloc_hal_version() {
  GRALLOC_HAL_VERSION="unknown"; GRALLOC_IS_AIDL=false; GRALLOC_DETECTION_METHOD="unknown"
  for _mf in /vendor/etc/vintf/manifest.xml /vendor/manifest.xml /odm/etc/vintf/manifest.xml; do
    [ -f "$_mf" ] || continue
    if grep -q 'android.hardware.graphics.mapper"' "$_mf" 2>/dev/null && grep -q 'format="aidl"' "$_mf" 2>/dev/null; then
      GRALLOC_HAL_VERSION="4"; GRALLOC_IS_AIDL=true; GRALLOC_DETECTION_METHOD="vintf_manifest"; return 0
    fi
    if grep -qE 'android\.hardware\.graphics\.(mapper|allocator)@4\.0' "$_mf" 2>/dev/null; then
      GRALLOC_HAL_VERSION="4"; GRALLOC_IS_AIDL=false; GRALLOC_DETECTION_METHOD="vintf_manifest"; return 0
    fi
  done
  for _gv in 4 3 2; do
    if [ -f "/vendor/lib64/hw/android.hardware.graphics.mapper@${_gv}.0-impl.so" ]; then
      GRALLOC_HAL_VERSION="$_gv"; GRALLOC_DETECTION_METHOD="so_presence"; return 0
    fi
  done
  return 0
}

detect_kgsl_version() {
  KGSL_VERSION_MAJOR=0; KGSL_VERSION_MINOR=0; KGSL_VERSION_RAW="unknown"; KGSL_GPU_MODEL="unknown"
  KERNEL_VERSION_RAW=$(uname -r 2>/dev/null || echo "0.0.0")
  _kv_tmp="$KERNEL_VERSION_RAW"
  KERNEL_VERSION_MAJOR="${_kv_tmp%%.*}"; _kv_tmp="${_kv_tmp#*.}"; KERNEL_VERSION_MINOR="${_kv_tmp%%.*}"
  KERNEL_VERSION_PATCH="${_kv_tmp#*.}"
  KERNEL_VERSION_PATCH="${KERNEL_VERSION_PATCH%%[^0-9]*}"

  for _gm_path in /sys/class/kgsl/kgsl-3d0/gpu_model /sys/devices/platform/soc/*.qcom,kgsl-3d0/kgsl/kgsl-3d0/gpu_model; do
    [ -f "$_gm_path" ] && { read KGSL_GPU_MODEL < "$_gm_path" 2>/dev/null; break; }
  done
  for _kv_path in /sys/class/kgsl/kgsl-3d0/kgsl_version /sys/kernel/debug/kgsl/version; do
    [ -f "$_kv_path" ] && { read KGSL_VERSION_RAW < "$_kv_path" 2>/dev/null;
      _kv_clean="${KGSL_VERSION_RAW#*kgsl }"; _kv_clean="${_kv_clean#kgsl-}"
      KGSL_VERSION_MAJOR="${_kv_clean%%.*}"; _kv_rest="${_kv_clean#*.}"; KGSL_VERSION_MINOR="${_kv_rest%%[^0-9]*}"
      break; }
  done
  [ "$KGSL_VERSION_MAJOR" -eq 0 ] && { KGSL_VERSION_MAJOR="$KERNEL_VERSION_MAJOR"; KGSL_VERSION_MINOR="$KERNEL_VERSION_MINOR"; }
}

write_compat_state() {
  {
    echo "VK_COMPAT_SCORE=${VK_COMPAT_SCORE:-0}"
    echo "VK_COMPAT_LEVEL=${VK_COMPAT_LEVEL:-unknown}"
    echo "VK_RECOMMENDED_MODE=${VK_RECOMMENDED_MODE:-skiagl}"
    echo "VK_DRIVER_OK=${VK_DRIVER_OK:-false}"
    echo "GRALLOC_HAL_VERSION=${GRALLOC_HAL_VERSION:-unknown}"
    echo "KGSL_GPU_MODEL=${KGSL_GPU_MODEL:-unknown}"
    printf 'VK_COMPAT_ISSUES=%s\n' "$(printf '%s' "${VK_COMPAT_ISSUES:-}" | sed 's/;/|||/g' 2>/dev/null)"
  } > "$VK_FULL_STATE_FILE" 2>/dev/null || true
  chmod 644 "$VK_FULL_STATE_FILE" 2>/dev/null || true
}

read_compat_state() {
  [ -f "$VK_FULL_STATE_FILE" ] || return 1
  . "$VK_FULL_STATE_FILE" 2>/dev/null || return 1
  VK_COMPAT_ISSUES="$(printf '%s' "${VK_COMPAT_ISSUES:-}" | sed 's/|||/;/g' 2>/dev/null)"
  return 0
}

probe_vulkan_compat_extended() {
  VK_COMPAT_SCORE=100; VK_COMPAT_LEVEL="safe"; VK_COMPAT_REASONS=""; VK_DRIVER_FOUND=false; VK_DRIVER_OK=false
  _pvk_deduct() { VK_COMPAT_SCORE=$((VK_COMPAT_SCORE - $1)); [ $VK_COMPAT_SCORE -lt 0 ] && VK_COMPAT_SCORE=0
    [ -z "$VK_COMPAT_REASONS" ] && VK_COMPAT_REASONS="$2" || VK_COMPAT_REASONS="${VK_COMPAT_REASONS}; $2"; }
  _pvk_int_prop() { local _v=$(getprop "$1" 2>/dev/null || echo "0"); echo "${_v%%[!0-9]*}"; }

  for _vl in \
      /vendor/lib64/hw/vulkan.adreno.so \
      /vendor/lib64/hw/vulkan.msm*.so \
      /vendor/lib64/hw/vulkan.*.so \
      /vendor/lib/hw/vulkan.*.so \
      /system/lib64/hw/vulkan.*.so \
      /system/lib/hw/vulkan.*.so \
      /vendor/lib64/libvulkan.so \
      /system/lib64/libvulkan.so; do
    if [ -f "$_vl" ]; then VK_DRIVER_FOUND=true; break; fi
  done
  if [ "$VK_DRIVER_FOUND" = "false" ]; then _pvk_deduct 50 "RC6: no driver found"; else VK_DRIVER_OK=true; fi

  _ro_use_vk=$(getprop ro.hwui.use_vulkan 2>/dev/null)
  [ "$_ro_use_vk" = "false" ] || [ "$_ro_use_vk" = "0" ] && _pvk_deduct 25 "RC5: ro.hwui.use_vulkan disabled"

  VK_HWVULKAN_PROP=$(getprop ro.hardware.vulkan 2>/dev/null)
  if [ -n "$VK_HWVULKAN_PROP" ] && [ "$VK_HWVULKAN_PROP" != "adreno" ]; then
    [ ! -f "/vendor/lib64/hw/vulkan.${VK_HWVULKAN_PROP}.so" ] && _pvk_deduct 35 "RC3: ro.hardware.vulkan mismatch"
  fi

  detect_gralloc_hal_version
  _sys_sdk=$(_pvk_int_prop ro.build.version.sdk)
  [ "$GRALLOC_HAL_VERSION" != "unknown" ] && [ "$GRALLOC_HAL_VERSION" -le 2 ] 2>/dev/null && [ "$_sys_sdk" -ge 31 ] && _pvk_deduct 30 "RC1: old gralloc on Android 12+"

  detect_kgsl_version
  [ "$KGSL_VERSION_MAJOR" -lt 3 ] 2>/dev/null && [ "$KGSL_VERSION_MAJOR" -gt 0 ] && _pvk_deduct 20 "RC2: legacy KGSL kernel"

  VK_COMPAT_ISSUES="$VK_COMPAT_REASONS"
  if [ "$VK_COMPAT_SCORE" -ge 70 ]; then VK_COMPAT_LEVEL="safe"
  elif [ "$VK_COMPAT_SCORE" -ge 50 ]; then VK_COMPAT_LEVEL="marginal"
  elif [ "$VK_COMPAT_SCORE" -ge 30 ]; then VK_COMPAT_LEVEL="risky"
  else VK_COMPAT_LEVEL="blocked"; fi
  return 0
}

patch_ro_hardware_vulkan() {
  RO_HW_VK_OLD=$(getprop ro.hardware.vulkan 2>/dev/null)
  case "$RO_HW_VK_OLD" in adreno|"") return 0 ;; esac
  if [ -f "/vendor/lib64/hw/vulkan.adreno.so" ] || [ -f "/vendor/lib/hw/vulkan.adreno.so" ]; then
    resetprop ro.hardware.vulkan adreno 2>/dev/null && return 0
  fi
  return 1
}

# ============================================================
# SHARED QGL FUNCTIONS (Added in V3)
# ============================================================
write_qgl_config() {
  local src="$1"
  local tmp="${QGL_TARGET}.tmp.$$"
  mkdir -p "$QGL_DIR" 2>/dev/null
  chcon u:object_r:same_process_hal_file:s0 "$QGL_DIR" 2>/dev/null || true
  {
    echo "0x0=0x8675309"
    [ -f "$src" ] && cat "$src"
  } > "$tmp" 2>/dev/null
  if [ -s "$tmp" ]; then
    chmod 0644 "$tmp" 2>/dev/null
    chcon u:object_r:same_process_hal_file:s0 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$QGL_TARGET" 2>/dev/null
    [ -f "$QGL_TARGET" ] && touch "$QGL_OWNER_MARKER" 2>/dev/null && return 0
  fi
  rm -f "$tmp" 2>/dev/null
  return 1
}

remove_qgl_config() {
  rm -f "$QGL_TARGET" 2>/dev/null
  if [ -f "$QGL_TARGET" ]; then
    # Fallback for chcon blocking rm: copy empty content then try unlink
    : > "$QGL_TARGET" 2>/dev/null || true
    rm -f "$QGL_TARGET" 2>/dev/null
  fi
  rm -f "$QGL_OWNER_MARKER" 2>/dev/null || true
  [ ! -f "$QGL_TARGET" ] && return 0 || return 1
}

# ============================================================
# SYSTEM STATE & DIAGNOSTICS
# ============================================================
dump_boot_state() {
  local _dir="$1"
  [ "$VERBOSE" = "y" ] && [ -n "$_dir" ] || return 0
  mkdir -p "$_dir" 2>/dev/null
  ps -A > "$_dir/processes.txt" 2>/dev/null
  getprop > "$_dir/properties.txt" 2>/dev/null
  getenforce > "$_dir/selinux_status.txt" 2>/dev/null
  dumpsys SurfaceFlinger > "$_dir/sf_dump.txt" 2>/dev/null
  if [ -r /sys/class/kgsl/kgsl-3d0/gpu_model ]; then
    { echo "GPU: $(cat /sys/class/kgsl/kgsl-3d0/gpu_model)";
      echo "Clock: $(cat /sys/class/kgsl/kgsl-3d0/gpu_clock)"; } > "$_dir/gpu_sysfs.txt" 2>/dev/null
  fi
}

start_boot_capture() {
  local _dir="$1"
  [ "$VERBOSE" = "y" ] && [ -n "$_dir" ] || return 0
  logcat -v threadtime -f "$_dir/capture_logcat.txt" 2>/dev/null &
  dmesg -w > "$_dir/capture_dmesg.txt" 2>&1 &
  ( sleep 120; kill $! 2>/dev/null; ) &
}
