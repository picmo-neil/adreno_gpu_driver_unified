# Adreno GPU Driver - Installation Script
# Compatible with: Magisk, KernelSU, APatch
#
# Runs as BusyBox ash sourced by update-binary (not executed directly).

# ========================================
# UTILITY FUNCTIONS
# ========================================

safe_log() {
  local _t; read _t _ < /proc/uptime 2>/dev/null || _t='?'
  local msg="[${_t}s] $1"
  echo "$msg" 2>/dev/null || true
  [ -n "${LOG_FILE:-}" ] && [ "$LOG_FILE" != "/dev/null" ] && echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

safe_ui_print() {
  local msg="$1"
  echo "$msg"
  [ -n "${LOG_FILE:-}" ] && [ "$LOG_FILE" != "/dev/null" ] && echo "[UI] $msg" >> "$LOG_FILE" 2>/dev/null || true
}

ui_print() { safe_ui_print "$@"; }
log_only() { safe_log "$@"; }

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# Single-pass config loader with inline validation.
# Reads file ONCE, extracts and validates all variables with zero forks.
parse_config() {
  local cfg="$1" _k _v
  [ -f "$cfg" ] || return 1
  while IFS='= ' read -r _k _v; do
    case "$_k" in '#'*|'') continue ;; esac
    _v="${_v%$'\r'}"
    case "$_k" in
      VERBOSE|ARM64_OPT|QGL|PLT|GAME_EXCLUSION_DAEMON)
        case "$_v" in
          [Yy]|[Yy][Ee][Ss]|1|[Tt][Rr][Uu][Ee]) _v='y' ;;
          *) _v='n' ;;
        esac ;;
      RENDER_MODE)
        case "$_v" in
          normal|skiavk|skiagl|skiavk_all) ;;
          [Nn][Oo][Rr][Mm][Aa][Ll])            _v='normal' ;;
          [Ss][Kk][Ii][Aa][Vv][Kk])            _v='skiavk' ;;
          [Ss][Kk][Ii][Aa][Gg][Ll])            _v='skiagl' ;;
          [Ss][Kk][Ii][Aa][Vv][Kk]_[Aa][Ll][Ll]) _v='skiavk_all' ;;
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
    esac
  done < "$cfg"
  return 0
}

# ========================================
# CONFIGURATION LOADING
# ========================================

VERBOSE="n"
ARM64_OPT="n"
QGL="n"
PLT="n"
RENDER_MODE="normal"
GAME_EXCLUSION_DAEMON="n"
CONFIG_FILE=""
CONFIG_FOUND=false

_loaded_cfg=""
for _cfg in \
    "/sdcard/Adreno_Driver/Config/adreno_config.txt" \
    "/storage/emulated/0/Adreno_Driver/Config/adreno_config.txt" \
    "${TMPDIR}/adreno_config.txt"; do
  if parse_config "$_cfg"; then
    CONFIG_FILE="$_cfg"
    _loaded_cfg="$_cfg"
    CONFIG_FOUND=true
    break
  fi
done
unset _cfg

# ========================================
# LOGGING SETUP
# ========================================

LOG_BASE_DIR="/data/local/tmp/Adreno_Driver"
BOOT_STATE="Install"
TIMESTAMP="$(date +%Y%m%d_%H%M%S 2>/dev/null || echo 'unknown')"

if [ "$VERBOSE" = "y" ]; then
  log_dirs_created=false
  for dir in "Booted" "Bootloop" "Config" "Install"; do
    if mkdir -p "${LOG_BASE_DIR}/${dir}" 2>/dev/null; then
      log_dirs_created=true
    else
      LOG_BASE_DIR="/tmp/Adreno_Driver"
      mkdir -p "${LOG_BASE_DIR}/${dir}" 2>/dev/null || true
      break
    fi
  done

  LOG_DIR="${LOG_BASE_DIR}/${BOOT_STATE}"
  LOG_FILE="${LOG_DIR}/install_${TIMESTAMP}.log"

  if ! echo "Installation log started: $(date 2>/dev/null)" > "$LOG_FILE" 2>/dev/null; then
    for fallback in "/cache/adreno_install.log" "/tmp/adreno_install.log" "/dev/null"; do
      if echo "Installation log started: $(date 2>/dev/null)" > "$fallback" 2>/dev/null; then
        LOG_FILE="$fallback"
        break
      fi
    done
  fi
else
  LOG_FILE="/dev/null"
fi

SD_CONFIG_DIR="/sdcard/Adreno_Driver/Config"

if [ "$VERBOSE" = "y" ]; then
  cleanup_old_logs() {
    local state_dir log_dir _fcount _n _f
    for state_dir in "Booted" "Bootloop" "Install"; do
      log_dir="${LOG_BASE_DIR}/${state_dir}"
      if [ -d "$log_dir" ]; then
        _fcount=0
        for _f in "$log_dir"/*.log; do [ -f "$_f" ] && _fcount=$((_fcount+1)); done
        if [ "$_fcount" -gt 10 ]; then
          _n=0
          for _f in "$log_dir"/*.log; do
            [ -f "$_f" ] || continue
            _n=$((_n+1))
            [ $_n -le $((_fcount - 10)) ] && rm -f "$_f" 2>/dev/null || true
          done
        fi
        unset _fcount _n _f
      fi
    done
  }
  cleanup_old_logs
fi

# ========================================
# BANNER
# ========================================

ui_print " "
ui_print "       _                         "
ui_print "       \`*-.                      "
ui_print "        )  _\`-.                   "
ui_print "       .  : \`. .                  "
ui_print "       : _   '  \\                 "
ui_print "       ; *\` _.   \`*-._            "
ui_print "       \`-.-'          \`-.         "
ui_print "         ;       \`       \`.       "
ui_print "         :.       .        \\      "
ui_print "         . \\  .   :   .-'   .     "
ui_print "         '  \`+.;  ;  '      :     "
ui_print "         :  '  |    ;       ;-.   "
ui_print "         ; '   : :\`-:     _.\`* ;  "
ui_print " [bug] .*' /  .*' ; .*\`- +'  \`*' "
ui_print "      \`*-*   \`*-*  \`*-*'         "
ui_print " "
ui_print "    ASCII art by Blazej Kozlowski"
ui_print " "
ui_print "    Adreno GPU Driver Module"
ui_print " "

# ========================================
# START INSTALLATION LOG
# ========================================

log_only "========================================"
log_only "Adreno GPU Driver Installation Started"
log_only "Timestamp: $TIMESTAMP"
log_only "Log: $LOG_FILE"
log_only "========================================"

ui_print "========================================"

# ========================================
# ENVIRONMENT VALIDATION
# ========================================

log_only "Validating environment..."

if [ -z "${MODPATH:-}" ]; then
  ui_print "! CRITICAL: MODPATH not set!"
  log_only "FATAL: MODPATH is empty - not running in proper installer context"
  return 1 2>/dev/null || exit 1
fi

if [ -z "${TMPDIR:-}" ]; then
  TMPDIR="${MODPATH%/*}/tmp"
  if [ ! -d "$TMPDIR" ]; then
    ui_print "! CRITICAL: TMPDIR not set!"
    log_only "FATAL: TMPDIR is empty"
    return 1 2>/dev/null || exit 1
  fi
fi

if [ ! -d "$TMPDIR" ]; then
  ui_print "! CRITICAL: TMPDIR does not exist!"
  log_only "FATAL: TMPDIR=$TMPDIR not found"
  return 1 2>/dev/null || exit 1
fi

if ! touch "$TMPDIR/.adreno_test" 2>/dev/null || ! rm "$TMPDIR/.adreno_test" 2>/dev/null; then
  ui_print "! CRITICAL: TMPDIR not writable!"
  log_only "FATAL: TMPDIR=$TMPDIR is not writable"
  return 1 2>/dev/null || exit 1
fi

log_only "Environment validated"
log_only "MODPATH: $MODPATH"
log_only "TMPDIR: $TMPDIR"

# ========================================
# ROOT DETECTION
# ========================================

ui_print "Detecting environment..."
log_only "Starting root environment detection..."

ROOT_TYPE="Unknown"
ROOT_VER="unknown"
USES_OVERLAY=false
USES_METAMODULE=false
SUSFS_PRESENT=false
METAMODULE_ACTIVE=false
METAMODULE_INSTALLED=false
METAMODULE_NAME=""
METAMODULE_ID=""
MAGIC_MOUNT_KSU=false

# Note: KernelSU sets MAGISK_VER_CODE=25200 for compat — check KSU first.
if [ "${KSU:-false}" = "true" ] || [ "${KSU_KERNEL_VER_CODE:-0}" -gt 0 ]; then
  ROOT_TYPE="KernelSU"
  ROOT_VER="${KSU_VER:-${KSU_VER_CODE:-${KSU_KERNEL_VER_CODE:-unknown}}}"
  USES_OVERLAY=true
  USES_METAMODULE=true
  ui_print "[OK] KernelSU: ${ROOT_VER}"
  log_only "KernelSU detected via env: $ROOT_VER"
elif [ "${APATCH:-false}" = "true" ] || [ "${APATCH_VER_CODE:-0}" -gt 0 ]; then
  ROOT_TYPE="APatch"
  ROOT_VER="${APATCH_VER:-${APATCH_VER_CODE:-unknown}}"
  USES_OVERLAY=true
  ui_print "[OK] APatch: ${ROOT_VER}"
  log_only "APatch detected via env: $ROOT_VER"
elif [ -n "${MAGISK_VER:-}" ] || [ "${MAGISK_VER_CODE:-0}" -gt 0 ]; then
  ROOT_TYPE="Magisk"
  ROOT_VER="${MAGISK_VER:-${MAGISK_VER_CODE:-unknown}}"
  ui_print "[OK] Magisk: ${ROOT_VER}"
  log_only "Magisk detected via env: $ROOT_VER"
fi

if [ "$ROOT_TYPE" = "Unknown" ]; then
  if [ -f "/data/adb/ksu/bin/ksud" ] && [ -x "/data/adb/ksu/bin/ksud" ]; then
    ROOT_TYPE="KernelSU"
    USES_OVERLAY=true
    USES_METAMODULE=true
    ROOT_VER="$(/data/adb/ksu/bin/ksud -V 2>/dev/null | head -n1 || echo 'unknown')"
    ui_print "[OK] KernelSU (detected via ksud)"
    log_only "KernelSU detected via binary: $ROOT_VER"
  elif [ -f "/data/adb/apd" ] && [ -x "/data/adb/apd" ]; then
    ROOT_TYPE="APatch"
    USES_OVERLAY=true
    ROOT_VER="$(/data/adb/apd -v 2>/dev/null | head -n1 || echo 'unknown')"
    ui_print "[OK] APatch (detected via apd)"
    log_only "APatch detected via binary: $ROOT_VER"
  elif [ -f "/data/adb/magisk/magisk" ]; then
    ROOT_TYPE="Magisk"
    ROOT_VER="$(/data/adb/magisk/magisk -v 2>/dev/null | head -n1 || echo 'unknown')"
    ui_print "[OK] Magisk (detected via binary)"
    log_only "Magisk detected via binary: $ROOT_VER"
  fi
fi

if [ "$ROOT_TYPE" = "Unknown" ]; then
  if [ -d "/data/adb/ksu" ]; then
    ROOT_TYPE="KernelSU"
    USES_OVERLAY=true
    USES_METAMODULE=true
    ui_print "[OK] KernelSU (detected via directory)"
    log_only "KernelSU detected via directory"
  elif [ -d "/data/adb/modules" ]; then
    ROOT_TYPE="Magisk"
    ui_print "[OK] Magisk (detected via directory)"
    log_only "Magisk detected via module directory"
  fi
fi

if [ "$ROOT_TYPE" = "Unknown" ]; then
  _km=false
  while IFS= read -r _kl; do
    case "$_kl" in *kernelsu*) _km=true; break;; esac
  done < /proc/modules 2>/dev/null
  if [ "$_km" = "true" ] || [ -e "/dev/ksu" ]; then
    unset _km _kl
    ROOT_TYPE="KernelSU"
    USES_OVERLAY=true
    USES_METAMODULE=true
    ui_print "[OK] KernelSU (detected via kernel module)"
    log_only "KernelSU detected via kernel module/device"
  else
    unset _km _kl
    IFS= read -r _pv < /proc/version 2>/dev/null
    case "${_pv:-}" in
      *APatch*)
        ROOT_TYPE="APatch"
        USES_OVERLAY=true
        ui_print "[OK] APatch (detected via kernel signature)"
        log_only "APatch detected via kernel version string"
        ;;
    esac
    unset _pv
  fi
fi

if [ "$ROOT_TYPE" = "Unknown" ]; then
  ui_print "[!] Unknown Root Manager"
  log_only "WARNING: Root type unknown - installation may not work correctly"
fi

log_only "Root type: $ROOT_TYPE, Uses overlay: $USES_OVERLAY"

# ========================================
# SUSFS DETECTION
# ========================================

ui_print " "
ui_print "Checking for SUSFS (root hiding)..."
log_only "Checking for SUSFS root hiding patches..."

SUSFS_INDICATORS=0

if [ -f "/sys/kernel/susfs/version" ]; then
  SUSFS_VER="unknown"
  { IFS= read -r SUSFS_VER; } < /sys/kernel/susfs/version 2>/dev/null
  ui_print "[OK] SUSFS detected (sysfs): v${SUSFS_VER}"
  log_only "SUSFS: sysfs found - version $SUSFS_VER"
  SUSFS_INDICATORS=$((SUSFS_INDICATORS + 3))
  SUSFS_PRESENT=true
fi

if [ -d "/data/adb/modules/susfs4ksu" ] && [ ! -f "/data/adb/modules/susfs4ksu/disable" ]; then
  ui_print "[OK] SUSFS module detected"
  log_only "SUSFS: module found and enabled"
  SUSFS_INDICATORS=$((SUSFS_INDICATORS + 2))
  SUSFS_PRESENT=true
fi

if [ -f "/data/adb/ksu/bin/ksu_susfs" ]; then
  ui_print "[OK] SUSFS KernelSU binary detected"
  log_only "SUSFS: ksu_susfs binary found"
  SUSFS_INDICATORS=$((SUSFS_INDICATORS + 1))
  SUSFS_PRESENT=true
fi

if [ "$SUSFS_INDICATORS" -eq 0 ]; then
  ui_print "[o] SUSFS not detected"
  log_only "SUSFS: No indicators found"
else
  log_only "SUSFS: Total indicators = $SUSFS_INDICATORS"
fi

# ========================================
# METAMODULE DETECTION
# ========================================

ui_print " "
ui_print "Detecting mounting solution..."
log_only "Starting metamodule detection..."

detect_metamodule() {
  METAMODULE_INSTALLED=false
  METAMODULE_ACTIVE=false
  METAMODULE_NAME=""
  METAMODULE_ID=""

  if [ -L "/data/adb/metamodule" ]; then
    META_LINK=$(readlink -f "/data/adb/metamodule" 2>/dev/null)
    if [ -n "$META_LINK" ] && [ -f "$META_LINK/module.prop" ]; then
      while IFS='=' read -r _mk _mv; do
        case "$_mk" in
          id)   METAMODULE_ID="${_mv%$'\r'}" ;;
          name) METAMODULE_NAME="${_mv%$'\r'}" ;;
        esac
      done < "$META_LINK/module.prop" 2>/dev/null
      if [ ! -f "$META_LINK/disable" ] && [ ! -f "$META_LINK/remove" ]; then
        METAMODULE_INSTALLED=true
        METAMODULE_ACTIVE=true
        ui_print "[OK] Metamodule: $METAMODULE_NAME"
        log_only "Metamodule detected via symlink: $METAMODULE_NAME (ID: $METAMODULE_ID)"
        return 0
      fi
    fi
  fi

  if [ -d "/data/adb/modules" ]; then
    for meta_id in \
        "meta_overlayfs" "meta-overlayfs" \
        "meta-magic-mount" "meta-magicmount" "MetaMagicMount" \
        "meta-mm" "metamm" \
        "meta-mountify" "metamountify" "MetaMountify" \
        "meta-hybrid" "meta-hybrid-mount" "meta_hybrid_mount" "MetaHybrid" \
        "magic_mount" "overlayfs_module" \
        "ksu_overlayfs" "overlayfs-ksu" "ksu-mm" "ksumagic" "meta-ksu-overlay" \
        "MKSU_Module" "mksu_module" \
        "meta-apatch" "meta-ap" "apatch-overlay" "apatch-mount" "meta_apatch_overlay" "apatch-mm"; do
      mod_dir="/data/adb/modules/$meta_id"
      if [ -d "$mod_dir" ] && [ ! -f "$mod_dir/disable" ] && [ ! -f "$mod_dir/remove" ] && \
         [ -f "$mod_dir/module.prop" ]; then
        METAMODULE_ID="$meta_id"
        METAMODULE_NAME="$meta_id"
        while IFS='=' read -r _mk _mv; do
          case "$_mk" in name) METAMODULE_NAME="${_mv%$'\r'}"; break ;; esac
        done < "$mod_dir/module.prop" 2>/dev/null
        METAMODULE_INSTALLED=true
        METAMODULE_ACTIVE=true
        ui_print "[OK] Metamodule: $METAMODULE_NAME"
        log_only "Metamodule detected by known ID: $METAMODULE_NAME"
        return 0
      fi
    done
  fi

  if [ -d "/data/adb/modules/.meta" ]; then
    METAMODULE_INSTALLED=true
    METAMODULE_ACTIVE=true
    METAMODULE_NAME=".meta (legacy)"
    METAMODULE_ID=".meta"
    ui_print "[OK] Metamodule: .meta (legacy)"
    log_only "Metamodule: Legacy .meta directory found"
    return 0
  fi

  log_only "No metamodule detected"
  return 1
}

if [ "$ROOT_TYPE" = "KernelSU" ]; then
  detect_metamodule
  if [ "$METAMODULE_INSTALLED" = "false" ]; then
    ui_print "[!] No metamodule detected"
    ui_print "  Module mounting may fail without a metamodule"
    log_only "WARNING: KernelSU detected but no metamodule found"
    MAGIC_MOUNT_KSU=true
  fi
elif [ "$ROOT_TYPE" = "APatch" ]; then
  METAMODULE_INSTALLED=true
  METAMODULE_ACTIVE=true
  METAMODULE_NAME="APatch Native"
  log_only "APatch: Using built-in OverlayFS"
else
  log_only "Not KernelSU/APatch, skipping metamodule detection"
fi

# ========================================
# DEVICE INFORMATION
# ========================================

ui_print " "
ui_print "Collecting device information..."
log_only "Gathering device information..."

MANUFACTURER="$(getprop ro.product.manufacturer 2>/dev/null || echo 'unknown')"
MODEL="$(getprop ro.product.model 2>/dev/null || echo 'unknown')"
DEVICE="$(getprop ro.product.device 2>/dev/null || echo 'unknown')"
ANDROID_VER="$(getprop ro.build.version.release 2>/dev/null || echo 'unknown')"
API="${API:-$(getprop ro.build.version.sdk 2>/dev/null || echo '0')}"
BUILD_ID="$(getprop ro.build.id 2>/dev/null || echo 'unknown')"
BUILD_DISPLAY="$(getprop ro.build.display.id 2>/dev/null || echo 'unknown')"
FINGERPRINT="$(getprop ro.build.fingerprint 2>/dev/null || echo 'unknown')"

ui_print "[OK] Device: $MANUFACTURER $MODEL"
ui_print "[OK] Android: $ANDROID_VER (API $API)"
log_only "Device: $MANUFACTURER $MODEL ($DEVICE)"
log_only "Android: $ANDROID_VER (API $API)"
log_only "Build: $BUILD_ID"
log_only "Fingerprint: $FINGERPRINT"

# ========================================
# OEM ROM DETECTION
# ========================================

ui_print " "
ui_print "Detecting ROM type..."
log_only "Starting OEM ROM detection..."

HYPEROS_ROM=false
ONEUI_ROM=false
COLOROS_ROM=false
REALME_ROM=false
FUNTOUCH_ROM=false
OXYGENOS_ROM=false
OEM_DETECTED=""

MIUI_VERSION="$(getprop ro.miui.ui.version.name 2>/dev/null)"
MIUI_CODE="$(getprop ro.miui.ui.version.code 2>/dev/null)"
HYPEROS_VERSION="$(getprop ro.mi.os.version.incremental 2>/dev/null)"

if [ -n "$HYPEROS_VERSION" ] || [ "$MIUI_VERSION" = "V140" ] || [ "${MIUI_CODE:-0}" -ge 14 ] 2>/dev/null; then
  HYPEROS_ROM=true
  OEM_DETECTED="HyperOS"
  ui_print "[OK] HyperOS detected"
  log_only "ROM: HyperOS (version: ${HYPEROS_VERSION:-${MIUI_VERSION:-unknown}})"
elif [ -n "$MIUI_VERSION" ] || [ -f "/system/etc/miui.apklist" ] || [ -d "/system/priv-app/MiuiSystemUI" ]; then
  HYPEROS_ROM=true
  OEM_DETECTED="MIUI"
  ui_print "[OK] MIUI detected"
  log_only "ROM: MIUI (version: ${MIUI_VERSION:-unknown})"
fi

ONEUI_VERSION="$(getprop ro.build.version.oneui 2>/dev/null)"
_mfr_is_samsung=false
case "$MANUFACTURER" in [Ss][Aa][Mm][Ss][Uu][Nn][Gg]) _mfr_is_samsung=true ;; esac
if [ -n "$ONEUI_VERSION" ] || [ "$_mfr_is_samsung" = "true" ] || [ -f "/system/etc/floating_feature.xml" ]; then
  ONEUI_ROM=true
  [ -z "$OEM_DETECTED" ] && OEM_DETECTED="OneUI"
  ui_print "[OK] Samsung OneUI detected"
  log_only "ROM: Samsung OneUI (version: ${ONEUI_VERSION:-unknown})"
fi

COLOROS_VERSION="$(getprop ro.build.version.opporom 2>/dev/null)"
_mfr_is_oppo=false
case "$MANUFACTURER" in [Oo][Pp][Pp][Oo]) _mfr_is_oppo=true ;; esac
if [ -n "$COLOROS_VERSION" ] || [ "$_mfr_is_oppo" = "true" ] || [ -d "/system/priv-app/OPPOColorOS" ]; then
  COLOROS_ROM=true
  [ -z "$OEM_DETECTED" ] && OEM_DETECTED="ColorOS"
  ui_print "[OK] ColorOS detected"
  log_only "ROM: ColorOS (version: ${COLOROS_VERSION:-unknown})"
fi

REALME_VERSION="$(getprop ro.build.version.realmeui 2>/dev/null)"
_mfr_is_realme=false
case "$MANUFACTURER" in [Rr][Ee][Aa][Ll][Mm][Ee]) _mfr_is_realme=true ;; esac
if [ -n "$REALME_VERSION" ] || [ "$_mfr_is_realme" = "true" ] || [ -d "/system/priv-app/RealmeSystemUI" ]; then
  REALME_ROM=true
  [ -z "$OEM_DETECTED" ] && OEM_DETECTED="RealmeUI"
  ui_print "[OK] RealmeUI detected"
  log_only "ROM: RealmeUI (version: ${REALME_VERSION:-unknown})"
fi

FUNTOUCH_VERSION="$(getprop ro.vivo.os.version 2>/dev/null)"
_mfr_is_vivo=false
case "$MANUFACTURER" in [Vv][Ii][Vv][Oo]|[Ii][Qq][Oo][Oo]) _mfr_is_vivo=true ;; esac
if [ -n "$FUNTOUCH_VERSION" ] || [ "$_mfr_is_vivo" = "true" ] || [ -d "/system/priv-app/VivoSystemUI" ]; then
  FUNTOUCH_ROM=true
  [ -z "$OEM_DETECTED" ] && OEM_DETECTED="FuntouchOS"
  ui_print "[OK] FuntouchOS detected"
  log_only "ROM: FuntouchOS (version: ${FUNTOUCH_VERSION:-unknown})"
fi

OXYGEN_VERSION="$(getprop ro.oxygen.version 2>/dev/null)"
_mfr_is_oneplus=false
case "$MANUFACTURER" in [Oo][Nn][Ee][Pp][Ll][Uu][Ss]) _mfr_is_oneplus=true ;; esac
if [ -n "$OXYGEN_VERSION" ] || [ "$_mfr_is_oneplus" = "true" ]; then
  OXYGENOS_ROM=true
  [ -z "$OEM_DETECTED" ] && OEM_DETECTED="OxygenOS"
  ui_print "[OK] OxygenOS detected"
  log_only "ROM: OxygenOS (version: ${OXYGEN_VERSION:-unknown})"
fi
unset _mfr_is_samsung _mfr_is_oppo _mfr_is_realme _mfr_is_vivo _mfr_is_oneplus

if [ -z "$OEM_DETECTED" ]; then
  ROM_BRAND="$(getprop ro.product.brand 2>/dev/null)"
  ROM_NAME="$(getprop ro.build.flavor 2>/dev/null || getprop ro.product.name 2>/dev/null)"
  _is_custom_rom=false
  case "$BUILD_DISPLAY" in
    *[Ll]ineage*|*[Cc][Rr][Dd]roid*|*[Pp]ixel*[Ee]xperience*|*[Ee]volution*[Xx]*|\
*[Aa]rrow*[Oo][Ss]*|*[Dd]erpfest*|*[Hh]avoc*|*[Rr]esurrection*|*[Mm]o[Kk]ee*|\
*[Aa][Oo][Ss][Ii][Pp]*|*[Dd]ot*[Oo][Ss]*)
      _is_custom_rom=true ;;
  esac
  if [ "$_is_custom_rom" = "true" ]; then
    OEM_DETECTED="Custom ROM"
    ui_print "[OK] Custom ROM detected: $BUILD_DISPLAY"
    log_only "ROM: Custom/AOSP-based ($BUILD_DISPLAY)"
  else
    OEM_DETECTED="Stock/AOSP"
    ui_print "[OK] Stock/AOSP ROM detected"
    log_only "ROM: Stock/AOSP (brand: $ROM_BRAND)"
  fi
else
  ROM_BRAND="$OEM_DETECTED"
  ROM_NAME="$OEM_DETECTED"
fi

log_only "Final ROM detection: $OEM_DETECTED"

# ========================================
# ARCHITECTURE DETECTION
# ========================================

CPU_ABI="${ARCH:-$(getprop ro.product.cpu.abi 2>/dev/null || echo 'unknown')}"
IS_ARM64="${IS64BIT:-false}"

case "$CPU_ABI" in
  arm64*|aarch64*|arm64-v8a)
    IS_ARM64=true
    ui_print "[OK] Architecture: ARM64"
    log_only "Architecture: ARM64 ($CPU_ABI)"
    ;;
  arm*|armeabi*)
    IS_ARM64=false
    ui_print "[OK] Architecture: ARM (32-bit)"
    log_only "Architecture: ARM 32-bit ($CPU_ABI)"
    ;;
  x64|x86_64)
    # BUG6 FIX: Original code set IS_ARM64=true for x86_64, which is incorrect.
    # x86_64 is a 64-bit Intel/AMD architecture, NOT ARM. Setting IS_ARM64=true
    # caused ARM64-specific driver paths and optimizations to activate on x86_64
    # Android-on-x86 environments (e.g., BlissOS, PrimeOS, WSA), which are
    # incompatible with ARM Adreno driver binaries. These environments use a
    # software Vulkan ICD (llvmpipe/SwiftShader) — not Adreno hardware.
    IS_ARM64=false
    ui_print "[OK] Architecture: x86_64 (non-ARM, IS_ARM64=false)"
    log_only "Architecture: x86_64 ($CPU_ABI) — IS_ARM64=false (corrected from original true)"
    ;;
  x86)
    IS_ARM64=false
    ui_print "[OK] Architecture: x86"
    log_only "Architecture: x86 ($CPU_ABI)"
    ;;
  *)
    ui_print "[!] Unknown architecture: $CPU_ABI"
    log_only "Architecture: Unknown ($CPU_ABI)"
    ;;
esac

# ========================================
# GPU DETECTION
# ========================================

ui_print " "
ui_print "Detecting GPU..."
log_only "Starting GPU detection..."

GPU_NAME="Unknown"
GPU_SUPPORTED=false

if [ -r /sys/class/kgsl/kgsl-3d0/gpu_model ]; then
  { IFS= read -r GPU_NAME; } < /sys/class/kgsl/kgsl-3d0/gpu_model 2>/dev/null
  GPU_NAME="${GPU_NAME:-Unknown}"
  ui_print "[OK] GPU: $GPU_NAME"
  log_only "GPU detected: $GPU_NAME (via kgsl sysfs)"
elif [ -r /sys/devices/soc0/gpu ]; then
  { IFS= read -r GPU_NAME; } < /sys/devices/soc0/gpu 2>/dev/null
  GPU_NAME="${GPU_NAME:-Unknown}"
  ui_print "[OK] GPU: $GPU_NAME"
  log_only "GPU detected via soc0: $GPU_NAME"
else
  GPU_NAME="$(getprop ro.hardware.vulkan 2>/dev/null || echo '')"
  if [ -n "$GPU_NAME" ] && [ "$GPU_NAME" != "Unknown" ]; then
    ui_print "[OK] GPU: $GPU_NAME (via Vulkan)"
    log_only "GPU detected via Vulkan property: $GPU_NAME"
  else
    GPU_NAME="$(getprop ro.hardware.egl 2>/dev/null || echo 'Unknown')"
    if [ -n "$GPU_NAME" ] && [ "$GPU_NAME" != "Unknown" ]; then
      ui_print "[OK] GPU: $GPU_NAME (via EGL)"
      log_only "GPU detected via EGL property: $GPU_NAME"
    else
      ui_print "[!] GPU: Detection failed"
      log_only "WARNING: GPU detection failed"
    fi
  fi
fi

case "$GPU_NAME" in
  *[Aa]dreno*)
    GPU_SUPPORTED=true
    ui_print "[OK] Supported Adreno GPU detected"
    log_only "GPU is supported Adreno"
    ;;
  *)
    ui_print "[!] GPU may not be Adreno"
    log_only "WARNING: Non-Adreno GPU detected or unknown"
    ;;
esac

# ========================================
# MODULE REQUIREMENTS CHECK
# ========================================
# Reads Android=, Adreno=, Kernel=, Oem= from module.prop.
# Empty fields are skipped.  Android/Adreno/Kernel failures BLOCK the flash.
# Oem= is a WARNING-ONLY list — the user is informed but the flash proceeds.

ui_print " "
ui_print "Checking module requirements..."
log_only "Checking module requirements from module.prop..."

# Locate module.prop — it is extracted to TMPDIR by the installer framework.
_req_modprop=""
for _mp in "$TMPDIR/module.prop" "$MODPATH/module.prop"; do
  [ -f "$_mp" ] && { _req_modprop="$_mp"; break; }
done

REQ_ANDROID=""
REQ_ADRENO=""
REQ_KERNEL=""
REQ_OEM=""
REQS_FAILED=false

if [ -n "$_req_modprop" ]; then
  while IFS='=' read -r _rk _rv; do
    # Skip blank lines, comments, and lines starting with '#'
    case "$_rk" in '#'*|'') continue ;; esac
    _rv="${_rv%$'\r'}"
    case "$_rk" in
      Android) REQ_ANDROID="$_rv" ;;
      Adreno)  REQ_ADRENO="$_rv"  ;;
      Kernel)  REQ_KERNEL="$_rv"  ;;
      Oem)     REQ_OEM="$_rv"     ;;
    esac
  done < "$_req_modprop"
  log_only "Requirement fields: Android='$REQ_ANDROID' Adreno='$REQ_ADRENO' Kernel='$REQ_KERNEL' Oem='$REQ_OEM'"
else
  log_only "INFO: module.prop not found in TMPDIR or MODPATH — skipping requirements check"
fi
unset _req_modprop

# ── Android version check ─────────────────────────────────────────────────────
# Compares the device's Android major version against Android= in module.prop.
# Android 12 → major "12", Android 13 → major "13", etc.
# The API variable is also compared for extra precision when the Android= value
# maps to a known SDK level (12→31, 13→33, 14→34, etc.), but the primary check
# is always major version to keep the logic simple and user-readable.
if [ -n "$REQ_ANDROID" ]; then
  _dev_maj="${ANDROID_VER%%.*}"
  _req_maj_a="${REQ_ANDROID%%.*}"
  if [ "$_dev_maj" -ge "$_req_maj_a" ] 2>/dev/null; then
    ui_print "[OK] Android $ANDROID_VER meets requirement (>= $REQ_ANDROID)"
    log_only "Android check PASSED: device=$ANDROID_VER required>=$REQ_ANDROID"
  else
    ui_print " "
    ui_print "! INCOMPATIBLE: Android version check FAILED"
    ui_print "  Device:   Android $ANDROID_VER (API $API)"
    ui_print "  Required: Android $REQ_ANDROID or newer"
    ui_print " "
    log_only "ERROR: Android check FAILED — device=$ANDROID_VER required>=$REQ_ANDROID"
    REQS_FAILED=true
  fi
  unset _dev_maj _req_maj_a
else
  log_only "Android= not set — skipping Android version check"
fi

# ── Adreno GPU model check ────────────────────────────────────────────────────
# Extracts the trailing numeric model from GPU_NAME.
# Examples: "Adreno (TM) 640" → 640, "Adreno 618" → 618, "Adreno730" → 730.
# Takes the LAST numeric sequence in the string (the model number) to handle
# strings like "Adreno (TM) 640" where "(TM)" also contains no digits but
# intermediate strings might on some OEM sysfs implementations.
if [ -n "$REQ_ADRENO" ]; then
  # Extract all digit groups, keep last one (the actual model number)
  # Extract the GPU model number — the FIRST sequence of 3+ digits in the name.
  # e.g. "Adreno610v1" → 610, "Adreno (TM) 640" → 640, "Adreno 6xx" → skipped
  # Using [0-9]{3,} avoids picking up revision suffixes like "v1", "v2" etc.
  _gpu_num=$(echo "$GPU_NAME" | grep -oE '[0-9]{3,}' | head -n1 2>/dev/null)
  if [ -n "$_gpu_num" ] && [ "$_gpu_num" -ge "$REQ_ADRENO" ] 2>/dev/null; then
    ui_print "[OK] Adreno ${_gpu_num} meets requirement (>= Adreno $REQ_ADRENO)"
    log_only "Adreno check PASSED: detected=${_gpu_num} required>=$REQ_ADRENO (from '$GPU_NAME')"
  else
    ui_print " "
    ui_print "! INCOMPATIBLE: Adreno GPU check FAILED"
    ui_print "  Device GPU: $GPU_NAME (model #${_gpu_num:-unknown})"
    ui_print "  Required:   Adreno $REQ_ADRENO or higher"
    ui_print " "
    log_only "ERROR: Adreno check FAILED — detected=${_gpu_num:-unknown} required>=$REQ_ADRENO (GPU_NAME='$GPU_NAME')"
    REQS_FAILED=true
  fi
  unset _gpu_num
else
  log_only "Adreno= not set — skipping Adreno GPU check"
fi

# ── Kernel version check ──────────────────────────────────────────────────────
# Compares kernel version (from uname -r) against Kernel= in module.prop.
# Format: major.minor  (e.g. 4.14, 5.4, 5.15, 6.1).
# Comparison is: device_major > req_major  OR
#                device_major == req_major AND device_minor >= req_minor
if [ -n "$REQ_KERNEL" ]; then
  _kraw=$(uname -r 2>/dev/null || echo "0.0")
  _kraw_clean="${_kraw%%[-+ ]*}"   # strip vendor suffix: "5.10.168-perf-g..." → "5.10.168"
  _kmaj="${_kraw_clean%%.*}"
  _krest="${_kraw_clean#*.}"
  _kmin="${_krest%%.*}"            # stop at next dot for minor (e.g. "10" from "10.168")
  _kmin="${_kmin%%[^0-9]*}"        # strip any non-digit suffix just in case

  _req_maj_k="${REQ_KERNEL%%.*}"
  _req_rest_k="${REQ_KERNEL#*.}"
  _req_min_k="${_req_rest_k%%[^0-9]*}"

  _kernel_ok=false
  if [ "$_kmaj" -gt "$_req_maj_k" ] 2>/dev/null; then
    _kernel_ok=true
  elif [ "$_kmaj" -eq "$_req_maj_k" ] && [ "$_kmin" -ge "$_req_min_k" ] 2>/dev/null; then
    _kernel_ok=true
  fi

  if [ "$_kernel_ok" = "true" ]; then
    ui_print "[OK] Kernel ${_kmaj}.${_kmin} meets requirement (>= $REQ_KERNEL)"
    log_only "Kernel check PASSED: detected=${_kmaj}.${_kmin} required>=$REQ_KERNEL (uname -r: $_kraw)"
  else
    ui_print " "
    ui_print "! INCOMPATIBLE: Kernel version check FAILED"
    ui_print "  Device kernel: ${_kmaj}.${_kmin} (full: $_kraw)"
    ui_print "  Required:      $REQ_KERNEL or newer"
    ui_print " "
    log_only "ERROR: Kernel check FAILED — detected=${_kmaj}.${_kmin} required>=$REQ_KERNEL (full: $_kraw)"
    REQS_FAILED=true
  fi
  unset _kraw _kraw_clean _kmaj _krest _kmin _req_maj_k _req_rest_k _req_min_k _kernel_ok
else
  log_only "Kernel= not set — skipping kernel version check"
fi

# ── OEM ROM warning (NON-BLOCKING) ───────────────────────────────────────────
# If the detected ROM matches any entry in the Oem= comma-separated list, print
# a compatibility warning. Installation continues regardless — the user's choice.
if [ -n "$REQ_OEM" ]; then
  # Normalise detected OEM to lowercase for case-insensitive matching.
  _oem_detected_lc=$(echo "${OEM_DETECTED:-stock}" | tr '[:upper:]' '[:lower:]')
  _oem_warned=false
  _oem_matched_entry=""

  # Split on comma (replace commas with spaces for shell word-splitting)
  _oem_entries=$(echo "$REQ_OEM" | tr ',' ' ')
  for _oem_e in $_oem_entries; do
    _oem_e_lc=$(echo "$_oem_e" | tr '[:upper:]' '[:lower:]' | tr -d ' ')
    # Match if the detected ROM name contains this entry as a substring.
    # e.g. "hyperos" matches OEM_DETECTED="HyperOS"; "miui" matches "MIUI".
    case "$_oem_detected_lc" in
      *"$_oem_e_lc"*)
        _oem_warned=true
        _oem_matched_entry="$_oem_e"
        break
        ;;
    esac
  done
  unset _oem_entries _oem_e _oem_e_lc

  if [ "$_oem_warned" = "true" ]; then
    ui_print " "
    ui_print "========================================"
    ui_print "! OEM ROM COMPATIBILITY WARNING"
    ui_print "========================================"
    ui_print " "
    ui_print "  Detected ROM : $OEM_DETECTED"
    ui_print "  Warning ROMs : $REQ_OEM"
    ui_print " "
    ui_print "  This driver may have compatibility issues on $OEM_DETECTED."
    ui_print "  Known OEM-specific problems:"
    ui_print "    - GOS (Game Optimisation Service) can block Vulkan layers"
    ui_print "    - OEM prop watchers may override debug.hwui.renderer"
    ui_print "    - Vendor init scripts can reset render mode after boot"
    ui_print "    - Custom SELinux policies may deny GPU device access"
    ui_print " "
    ui_print "  Installation will continue — use with caution."
    ui_print "  If issues occur, try RENDER_MODE=normal or skiagl."
    ui_print " "
    ui_print "========================================"
    log_only "WARNING: OEM compatibility warning — detected=$OEM_DETECTED matched entry='$_oem_matched_entry' in list='$REQ_OEM'"
  else
    ui_print "[OK] ROM not in OEM warning list"
    log_only "OEM check: ROM '$OEM_DETECTED' not in warning list '$REQ_OEM'"
  fi
  unset _oem_detected_lc _oem_warned _oem_matched_entry
else
  log_only "Oem= not set — skipping OEM ROM warning check"
fi

# ── Block installation on hard requirement failure ────────────────────────────
if [ "$REQS_FAILED" = "true" ]; then
  ui_print " "
  ui_print "========================================"
  ui_print "  INSTALLATION BLOCKED"
  ui_print "========================================"
  ui_print " "
  ui_print "  Your device does not meet the minimum"
  ui_print "  requirements for this GPU driver."
  ui_print " "
  ui_print "  Check the messages above for details."
  ui_print "  Using an incompatible driver can cause"
  ui_print "  bootloops, GPU crashes, or black screens."
  ui_print " "
  ui_print "========================================"
  log_only "FATAL: Installation blocked — one or more device requirements not met"
  log_only "Device: $MANUFACTURER $MODEL | Android $ANDROID_VER (API $API) | GPU: $GPU_NAME | Kernel: $(uname -r 2>/dev/null)"
  # abort() is provided by Magisk / KernelSU / APatch installer environment.
  # It prints the message, runs cleanup, and calls exit 1 — the only reliable
  # way to halt installation from within a sourced customize.sh.
  abort "FATAL: Device does not meet minimum requirements. See above for details."
fi

log_only "All module requirements passed"

# ========================================
# CONFIGURATION LOADING
# ========================================

ui_print " "
ui_print "Loading configuration..."
log_only "Searching for configuration files..."

CONFIG_FOUND=false
CONFIG_FILE=""
RESTORED_CONFIGS=false

for config_path in \
    "/sdcard/Adreno_Driver/Config/adreno_config.txt" \
    "/storage/emulated/0/Adreno_Driver/Config/adreno_config.txt" \
    "$MODPATH/adreno_config.txt" \
    "$TMPDIR/adreno_config.txt"; do
  if [ -f "$config_path" ] && [ -r "$config_path" ]; then
    CONFIG_FILE="$config_path"
    CONFIG_FOUND=true
    ui_print "[OK] Config found: ${config_path##*/}"
    log_only "Configuration loaded from: $config_path"
    break
  fi
done

if [ "$CONFIG_FOUND" = "false" ]; then
  ui_print "[!] No config file found, using defaults"
  log_only "No configuration file found, using defaults"
fi

if [ "$CONFIG_FOUND" = "true" ] && [ "$CONFIG_FILE" != "${_loaded_cfg:-}" ]; then
  parse_config "$CONFIG_FILE" || true
fi
RESTORED_CONFIGS="$CONFIG_FOUND"

[ "$ARM64_OPT" = "y" ] || ARM64_OPT="n"
[ "$QGL" = "y" ]       || QGL="n"
[ "$PLT" = "y" ]       || PLT="n"
[ "$VERBOSE" = "y" ]   || VERBOSE="n"
[ "$GAME_EXCLUSION_DAEMON" = "y" ] || GAME_EXCLUSION_DAEMON="n"
[ -n "$RENDER_MODE" ]  || RENDER_MODE="normal"

ui_print "Configuration:"
ui_print "  - PLT: $PLT"
ui_print "  - QGL: $QGL"
if [ "$IS_ARM64" = "true" ]; then
  ui_print "  - ARM64 Opt: $ARM64_OPT"
fi
ui_print "  - Render: $RENDER_MODE"
ui_print "  - Game Exclusion Daemon: $GAME_EXCLUSION_DAEMON"

log_only "Final config: PLT=$PLT, QGL=$QGL, ARM64_OPT=$ARM64_OPT, VERBOSE=$VERBOSE, RENDER_MODE=$RENDER_MODE, GAME_EXCLUSION_DAEMON=$GAME_EXCLUSION_DAEMON"

ui_print " "
ui_print "========================================"
ui_print "32-BIT ARCHITECTURE ANALYSIS"
ui_print "========================================"
ui_print " "

LINKER="/system/bin/linker"
TANGO="/dev/tango32"
SYSLIB="/system/lib"
VENDORLIB="/vendor/lib"

LINKER_PRESENT=false
LINKER_PATH=""

for linker_check in \
    "/system/bin/linker" \
    "/system_root/system/bin/linker" \
    "/system/apex/com.android.runtime/bin/linker"; do
  if [ -e "$linker_check" ]; then
    LINKER_PATH="$linker_check"
    if [ -L "$linker_check" ]; then
      LINK_TARGET=$(readlink "$linker_check" 2>/dev/null || echo "")
      case "$LINK_TARGET" in *linker64*)
        LINKER_STATUS="⚠️  SYMLINK to linker64 (no native 32-bit)"
        LINKER_PRESENT=false
        log_only "Linker is symlink to linker64 at $linker_check -> $LINK_TARGET"
        break
      ;; *)
        LINKER_STATUS="✅ FOUND (at $linker_check)"
        LINKER_PRESENT=true
        log_only "Linker found at $linker_check"
        break
      ;; esac
    else
      LINKER_STATUS="✅ FOUND (at $linker_check)"
      LINKER_PRESENT=true
      log_only "Linker found at $linker_check"
      break
    fi
  fi
done

if [ "$LINKER_PRESENT" = "false" ] && [ -z "$LINKER_PATH" ]; then
  LINKER_STATUS="❌ MISSING"
  log_only "Linker not found in any checked location"
fi

if [ -c "$TANGO" ]; then
  TANGO_STATUS="✅ ACTIVE"
  TANGO_PRESENT=true
else
  TANGO_STATUS="❌ NOT FOUND"
  TANGO_PRESENT=false
fi

if [ -d "$SYSLIB" ]; then
  _syslib_has=false
  for _f in "$SYSLIB"/*; do [ -e "$_f" ] && { _syslib_has=true; break; }; done
  if [ "$_syslib_has" = "true" ]; then
    _syslib_n=0
    for _f in "$SYSLIB"/*; do [ -e "$_f" ] && _syslib_n=$((_syslib_n+1)); done
    SYSLIB_STATUS="✅ EXISTS ($_syslib_n files)"
    SYSLIB_PRESENT=true
  else
    SYSLIB_STATUS="❌ MISSING/EMPTY"
    SYSLIB_PRESENT=false
  fi
else
  SYSLIB_STATUS="❌ MISSING/EMPTY"
  SYSLIB_PRESENT=false
fi

if [ -d "$VENDORLIB" ]; then
  _vlib_has=false
  for _f in "$VENDORLIB"/*; do [ -e "$_f" ] && { _vlib_has=true; break; }; done
  if [ "$_vlib_has" = "true" ]; then
    _vlib_n=0
    for _f in "$VENDORLIB"/*; do [ -e "$_f" ] && _vlib_n=$((_vlib_n+1)); done
    VENDORLIB_STATUS="✅ EXISTS ($_vlib_n files)"
    VENDORLIB_PRESENT=true
  else
    VENDORLIB_STATUS="❌ MISSING/EMPTY"
    VENDORLIB_PRESENT=false
  fi
else
  VENDORLIB_STATUS="❌ MISSING/EMPTY"
  VENDORLIB_PRESENT=false
fi

ui_print "Analysis Results:"
ui_print "─────────────────────────────────────"
ui_print "1. Native 32-bit Linker:  $LINKER_STATUS"
if [ -n "$LINKER_PATH" ]; then
  ui_print "   Location: $LINKER_PATH"
else
  ui_print "   Location: /system/bin/linker (not found)"
fi
ui_print " "
ui_print "2. Tango Translator:      $TANGO_STATUS"
ui_print "   Location: $TANGO"
ui_print " "
ui_print "3. System 32-bit Libs:    $SYSLIB_STATUS"
ui_print "   Location: $SYSLIB"
ui_print " "
ui_print "4. Vendor 32-bit Libs:    $VENDORLIB_STATUS"
ui_print "   Location: $VENDORLIB"
ui_print "─────────────────────────────────────"
ui_print " "

AUTO_ARM64_OPT="n"
DETECTION_REASON=""

if [ "$LINKER_PRESENT" = "true" ]; then
  AUTO_ARM64_OPT="n"
  DETECTION_REASON="Native 32-bit linker found"
  RECOMMENDATION="KEEP 32-bit libs (native support detected)"
  SAFETY_LEVEL="✅ SAFE"
  ui_print "🔍 RESULT: NATIVE 32-BIT SUPPORT DETECTED"
  ui_print " "
  ui_print "Your device has native 32-bit support."
  ui_print "You can safely install both 32-bit and 64-bit driver modules."
  ui_print " "
elif [ "$TANGO_PRESENT" = "true" ]; then
  AUTO_ARM64_OPT="y"
  DETECTION_REASON="Tango translator detected (translation layer only)"
  RECOMMENDATION="REMOVE 32-bit libs (driver modules need 64-bit only)"
  SAFETY_LEVEL="⚠️  CRITICAL"
  ui_print "🔍 RESULT: TRANSLATION-ONLY SYSTEM (64-bit + Tango)"
  ui_print " "
  ui_print "Your device uses Tango translator for 32-bit apps."
  ui_print "32-bit apps work via translation, but DRIVER MODULES"
  ui_print "must be 64-bit only to prevent BOOTLOOP!"
  ui_print " "
  ui_print "⚠️  Installing 32-bit driver libs will cause BOOTLOOP!"
  ui_print " "
elif [ "$SYSLIB_PRESENT" = "true" ] || [ "$VENDORLIB_PRESENT" = "true" ]; then
  AUTO_ARM64_OPT="y"
  DETECTION_REASON="32-bit lib directories found but NO LINKER"
  RECOMMENDATION="REMOVE 32-bit libs (linker required to load them)"
  SAFETY_LEVEL="✅ SAFE"
  ui_print "🔍 RESULT: NO 32-BIT LINKER (Cannot Load 32-bit Libs)"
  ui_print " "
  ui_print "32-bit library directories exist, but native linker not found."
  ui_print "Without native linker, 32-bit libs cannot be loaded."
  ui_print "Skipping 32-bit driver installation to prevent issues."
  ui_print " "
  ui_print "✓ Only 64-bit drivers will be installed"
  ui_print " "
else
  AUTO_ARM64_OPT="y"
  DETECTION_REASON="Pure 64-bit system (no 32-bit support)"
  RECOMMENDATION="REMOVE 32-bit libs (pure 64-bit system)"
  SAFETY_LEVEL="✅ SAFE"
  ui_print "🔍 RESULT: PURE 64-BIT SYSTEM"
  ui_print " "
  ui_print "No 32-bit support detected at all."
  ui_print "32-bit driver libs will be automatically excluded."
  ui_print " "
fi

ui_print "Decision Logic:"
ui_print "─────────────────────────────────────"
ui_print "Reason: $DETECTION_REASON"
ui_print "Action: $RECOMMENDATION"
ui_print "Safety: $SAFETY_LEVEL"
ui_print "─────────────────────────────────────"
ui_print " "

if [ "$AUTO_ARM64_OPT" = "y" ] && [ "${ARM64_OPT}" = "n" ]; then
  ui_print "🔧 AUTO-CONFIGURATION APPLIED"
  ui_print " "
  ui_print "Original ARM64_OPT setting: n (from config)"
  ui_print "Detected ARM64_OPT setting: y (auto-detected)"
  ui_print " "
  ui_print "⚙️  Overriding config → ARM64_OPT=y"
  ui_print " "
  ui_print "Reason: Prevents bootloop on 64-bit-only/Tango systems"
  ui_print " "
  ARM64_OPT="y"
  if [ -n "${CONFIG_FILE:-}" ] && [ -f "${CONFIG_FILE}" ]; then
    awk 'BEGIN{found=0} /^ARM64_OPT=/{print "ARM64_OPT=y"; found=1; next} {print} END{if(!found) print "ARM64_OPT=y"}' \
      "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" 2>/dev/null && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE" 2>/dev/null || true
    ui_print "✓ Configuration file updated: ARM64_OPT=y"
    ui_print " "
  fi
  log_only "AUTO-CONFIGURATION: ARM64_OPT overridden from 'n' to 'y'"
  log_only "Detection reason: $DETECTION_REASON"
  log_only "Linker present: $LINKER_PRESENT"
  log_only "Tango present: $TANGO_PRESENT"
  log_only "System lib present: $SYSLIB_PRESENT"
elif [ "$AUTO_ARM64_OPT" = "n" ] && [ "${ARM64_OPT}" = "y" ]; then
  ui_print "⚠️  CONFIGURATION OVERRIDE NOTICE"
  ui_print " "
  ui_print "Your config says: ARM64_OPT=y (64-bit only)"
  ui_print "Detection result: ARM64_OPT=n (32-bit support found)"
  ui_print " "
  ui_print "⚙️  Keeping your manual configuration: ARM64_OPT=y"
  ui_print " "
  ui_print "This may cause issues if you run 32-bit apps!"
  ui_print "To use auto-detection, set ARM64_OPT=n in config"
  ui_print " "
  log_only "User manual override: ARM64_OPT=y (despite 32-bit support detected)"
else
  ui_print "✓ Configuration validated: ARM64_OPT=$ARM64_OPT"
  ui_print "  (matches auto-detection result)"
  ui_print " "
fi

ui_print "Final ARM64_OPT Setting: $ARM64_OPT"
ui_print " "

if [ "$ARM64_OPT" = "y" ]; then
  ui_print "📦 32-bit libraries will be EXCLUDED from installation"
  ui_print "📦 Only 64-bit libraries will be installed"
else
  ui_print "📦 Both 32-bit and 64-bit libraries will be installed"
fi

ui_print " "
ui_print "========================================"
ui_print "32-BIT ANALYSIS COMPLETE"
ui_print "========================================"
ui_print " "

export ARM64_OPT
export AUTO_ARM64_OPT
export DETECTION_REASON

# ========================================
# CLEANUP STALE BACKUP ON REINSTALL
# ========================================

BACKUP_DIR="/sdcard/Adreno_Driver/Backup"
if [ -d "$BACKUP_DIR" ]; then
  ui_print " "
  ui_print "Removing stale libgsl.so backup from previous install..."
  ui_print "(Prevents bootloop from wrong-version restore)"
  if rm -rf "$BACKUP_DIR" 2>/dev/null; then
    ui_print "[OK] Stale backup removed: $BACKUP_DIR"
    log_only "Stale libgsl.so backup removed: $BACKUP_DIR"
  else
    ui_print "[!] WARNING: Could not remove stale backup!"
    ui_print "    Please delete manually: $BACKUP_DIR"
    log_only "WARNING: Failed to remove stale backup at $BACKUP_DIR"
  fi
fi

STATS_DIR="/sdcard/Adreno_Driver/Statistics"
if [ -d "$STATS_DIR" ]; then
  ui_print " "
  ui_print "Removing stale Statistics folder from previous install..."
  if rm -rf "$STATS_DIR" 2>/dev/null; then
    ui_print "[OK] Stale Statistics folder removed"
    log_only "Stale Statistics folder removed: $STATS_DIR"
  else
    ui_print "[!] WARNING: Could not remove stale Statistics folder"
    log_only "WARNING: Failed to remove stale Statistics folder: $STATS_DIR"
  fi
fi

if [ -f "/data/vendor/gpu/qgl_config.txt" ]; then
  rm -f "/data/vendor/gpu/qgl_config.txt" 2>/dev/null || true
  log_only "Stale QGL owner marker removed (will be re-created if QGL=y)"
fi

# ========================================
# COPY MODULE FILES
# ========================================

ui_print " "
ui_print "Installing module files..."
log_only "Starting file installation..."

FILES_COPIED=0
FILES_FAILED=0

if [ -d "$TMPDIR/system" ]; then
  if cp -af "$TMPDIR/system" "$MODPATH/" 2>/dev/null; then
    FILES_COPIED=$((FILES_COPIED + 1))
    log_only "System directory copied successfully"
  else
    if mkdir -p "$MODPATH/system" 2>/dev/null; then
      for item in "$TMPDIR/system"/*; do
        [ -e "$item" ] || continue
        if cp -af "$item" "$MODPATH/system/" 2>/dev/null; then
          FILES_COPIED=$((FILES_COPIED + 1))
        else
          FILES_FAILED=$((FILES_FAILED + 1))
          log_only "WARNING: Failed to copy ${item##*/}"
        fi
      done
    else
      FILES_FAILED=$((FILES_FAILED + 1))
      log_only "ERROR: Failed to create system directory"
    fi
  fi
else
  log_only "WARNING: No system directory found in module package"
fi

for file in module.prop post-fs-data.sh service.sh uninstall.sh system.prop sepolicy.rule adreno_config.txt qgl_config.txt common.sh game_excl_daemon.sh game_exclusion_list.sh; do
  if [ -f "$TMPDIR/$file" ]; then
    if cp -f "$TMPDIR/$file" "$MODPATH/" 2>/dev/null; then
      FILES_COPIED=$((FILES_COPIED + 1))
      log_only "Copied: $file"
    else
      FILES_FAILED=$((FILES_FAILED + 1))
      log_only "ERROR: Failed to copy $file"
    fi
  fi
done

# ── Native GED binary install ──────────────────────────────────────────────
# Install the pre-compiled adreno_ged binary for the device's ABI.
# Layout in the zip:   bin/arm64-v8a/adreno_ged
#                      bin/armeabi-v7a/adreno_ged
# Installed to:        $MODPATH/bin/<abi>/adreno_ged  (executable 0755)
#
# If no binary is found for this ABI, the shell fallback (game_excl_daemon.sh)
# is used automatically by post-fs-data.sh — no user action needed.
_GED_ABI="${CPU_ABI:-$(getprop ro.product.cpu.abi 2>/dev/null || echo '')}"
_GED_ARCH=""
case "$_GED_ABI" in
  arm64*|aarch64*) _GED_ARCH="arm64-v8a"   ;;
  arm*|armeabi*)   _GED_ARCH="armeabi-v7a" ;;
  *) log_only "INFO: native GED binary: unsupported ABI=$_GED_ABI, will use shell fallback" ;;
esac

if [ -n "$_GED_ARCH" ]; then
  _GED_SRC="$TMPDIR/bin/${_GED_ARCH}/adreno_ged"
  _GED_DST_DIR="$MODPATH/bin/${_GED_ARCH}"
  _GED_DST="$_GED_DST_DIR/adreno_ged"

  # Some Magisk forks/versions pre-copy all zip contents to MODPATH before
  # sourcing customize.sh. If the binary is already in MODPATH, skip the copy
  # and just ensure it's executable.
  if [ ! -f "$_GED_SRC" ] && [ -f "$_GED_DST" ]; then
    log_only "Native GED binary already in MODPATH (pre-copied by installer), skipping cp"
    if chmod 0755 "$_GED_DST" 2>/dev/null; then
      FILES_COPIED=$((FILES_COPIED + 1))
      ui_print "[OK] Native GED binary already installed (${_GED_ARCH})"
      log_only "Native GED binary permissions confirmed: $_GED_DST"
    fi
  elif [ -f "$_GED_SRC" ]; then
    if mkdir -p "$_GED_DST_DIR" 2>/dev/null && \
       cp -f "$_GED_SRC" "$_GED_DST" 2>/dev/null && \
       chmod 0755 "$_GED_DST" 2>/dev/null; then
      FILES_COPIED=$((FILES_COPIED + 1))
      ui_print "[OK] Native GED binary installed (${_GED_ARCH})"
      log_only "Native GED binary installed: $_GED_DST"
    else
      FILES_FAILED=$((FILES_FAILED + 1))
      ui_print "[!] Native GED binary copy failed — shell fallback will be used"
      log_only "ERROR: Failed to install native GED binary to $_GED_DST"
    fi
  else
    ui_print "[!] Native GED binary not found in package for ABI=${_GED_ARCH}"
    ui_print "    Shell fallback (game_excl_daemon.sh) will be used instead."
    log_only "INFO: $_GED_SRC not in package — shell fallback active"
  fi
fi
unset _GED_ABI _GED_ARCH _GED_SRC _GED_DST_DIR _GED_DST

if [ $FILES_FAILED -gt 0 ]; then
  ui_print "[!] Module files installed with $FILES_FAILED errors"
  log_only "WARNING: $FILES_FAILED files failed to copy"
else
  ui_print "[OK] Module files installed ($FILES_COPIED files)"
fi

# ========================================
# VENDOR DIRECTORY PATH NOTE
# ========================================
# Per Magisk official documentation, vendor files MUST be placed under
# system/vendor/ inside the module — NOT at a top-level vendor/ directory.
# Magisk magic mount handles the system/vendor → /vendor mapping
# transparently, regardless of whether /vendor is a separate partition.
# KernelSU's ksud converts system/vendor/ to top-level vendor/ internally
# when building the ext4 module image. APatch follows Magisk conventions.
# Reference: https://topjohnwu.github.io/Magisk/guides.html
# "If you want to replace files in /vendor... please place them under
#  system/vendor... Magisk will transparently handle both cases."
# Files are already at system/vendor/ — NO restructure needed.

log_only "Vendor files remain at system/vendor/ (correct path for all root managers)"

# ========================================
# SET PERMISSIONS
# ========================================

ui_print "Setting permissions..."
log_only "Setting file and directory permissions..."

PERMS_SET=0
PERMS_FAILED=0

if type set_perm_recursive >/dev/null 2>&1; then
  set_perm_recursive "$MODPATH" 0 0 0755 0644 2>/dev/null && PERMS_SET=$((PERMS_SET + 1)) || PERMS_FAILED=$((PERMS_FAILED + 1))
else
  find "$MODPATH" -type d -exec chmod 0755 {} + 2>/dev/null || PERMS_FAILED=$((PERMS_FAILED + 1))
  find "$MODPATH" -type f -exec chmod 0644 {} + 2>/dev/null || PERMS_FAILED=$((PERMS_FAILED + 1))
fi

for script in post-fs-data.sh service.sh uninstall.sh common.sh; do
  if [ -f "$MODPATH/$script" ]; then
    if chmod 0755 "$MODPATH/$script" 2>/dev/null; then
      PERMS_SET=$((PERMS_SET + 1))
      log_only "Executable: $script"
    else
      PERMS_FAILED=$((PERMS_FAILED + 1))
      log_only "ERROR: Failed to set executable permission on $script"
    fi
  fi
done

# Ensure native GED binaries are executable
for _abi_dir in "$MODPATH/bin/arm64-v8a" "$MODPATH/bin/armeabi-v7a"; do
  if [ -f "$_abi_dir/adreno_ged" ]; then
    chmod 0755 "$_abi_dir/adreno_ged" 2>/dev/null && \
      PERMS_SET=$((PERMS_SET + 1)) || PERMS_FAILED=$((PERMS_FAILED + 1))
    log_only "Executable: $_abi_dir/adreno_ged"
  fi
done
unset _abi_dir

if [ -d "$MODPATH/system/vendor" ]; then
  find "$MODPATH/system/vendor" -type f -name "*.so" -exec chmod 0644 {} + 2>/dev/null && \
    PERMS_SET=$((PERMS_SET + 1)) || PERMS_FAILED=$((PERMS_FAILED + 1))
  log_only "Vendor library permissions set"
fi

for libdir in "$MODPATH/system/lib" "$MODPATH/system/lib64"; do
  if [ -d "$libdir" ]; then
    find "$libdir" -type f -name "*.so" -exec chmod 0644 {} + 2>/dev/null
  fi
done

if [ $PERMS_FAILED -gt 0 ]; then
  ui_print "[!] Permissions configured with warnings"
else
  ui_print "[OK] Permissions configured"
fi

# ========================================
# ARM64 OPTIMIZATION
# ========================================

if [ "$IS_ARM64" = "true" ] && [ "$ARM64_OPT" = "y" ]; then
  ui_print " "
  ui_print "Applying ARM64 optimization..."
  log_only "ARM64 optimization enabled - removing 32-bit libraries"

  LIB32_REMOVED=0

  if [ -d "$MODPATH/system/vendor/lib" ]; then
    if rm -rf "$MODPATH/system/vendor/lib" 2>/dev/null; then
      LIB32_REMOVED=$((LIB32_REMOVED + 1))
      log_only "Removed: system/vendor/lib (32-bit)"
    fi
  fi

  if [ -d "$MODPATH/system/lib" ]; then
    if rm -rf "$MODPATH/system/lib" 2>/dev/null; then
      LIB32_REMOVED=$((LIB32_REMOVED + 1))
      log_only "Removed: system/lib (32-bit)"
    fi
  fi

  if [ $LIB32_REMOVED -gt 0 ]; then
    ui_print "[OK] ARM64 optimized ($LIB32_REMOVED 32-bit directories removed)"
  else
    ui_print "[OK] ARM64 optimization complete (no 32-bit libs found)"
  fi
fi

# ========================================
# SELINUX CONTEXT SETUP
# ========================================

ui_print " "
ui_print "Configuring SELinux contexts..."
log_only "Setting SELinux contexts for module files..."

SELINUX_SET=0

if command_exists chcon; then
  for libdir in "$MODPATH/system/vendor/lib/egl" "$MODPATH/system/vendor/lib64/egl" \
                "$MODPATH/system/vendor/lib" "$MODPATH/system/vendor/lib64"; do
    if [ -d "$libdir" ]; then
      if chcon -R u:object_r:same_process_hal_file:s0 "$libdir" 2>/dev/null; then
        SELINUX_SET=$((SELINUX_SET + 1))
      else
        chcon -R u:object_r:vendor_file:s0 "$libdir" 2>/dev/null || \
          log_only "WARNING: Failed to set SELinux context for $libdir"
      fi
    fi
  done

  if [ -d "$MODPATH/system/vendor/firmware" ]; then
    if chcon -R u:object_r:vendor_firmware_file:s0 "$MODPATH/system/vendor/firmware" 2>/dev/null; then
      SELINUX_SET=$((SELINUX_SET + 1))
    else
      log_only "WARNING: Failed to set SELinux context for firmware"
    fi
  fi

  for hwdir in "$MODPATH/system/vendor/lib/hw" "$MODPATH/system/vendor/lib64/hw"; do
    if [ -d "$hwdir" ]; then
      if chcon -R u:object_r:same_process_hal_file:s0 "$hwdir" 2>/dev/null; then
        SELINUX_SET=$((SELINUX_SET + 1))
      else
        chcon -R u:object_r:vendor_hal_file:s0 "$hwdir" 2>/dev/null || true
      fi
    fi
  done

  if [ -d "$MODPATH/system/vendor/etc" ]; then
    chcon -R u:object_r:vendor_configs_file:s0 "$MODPATH/system/vendor/etc" 2>/dev/null || true
  fi

  if [ $SELINUX_SET -gt 0 ]; then
    ui_print "[OK] SELinux contexts configured ($SELINUX_SET paths)"
  else
    ui_print "[!] SELinux context setting had issues"
  fi
  log_only "SELinux contexts set: $SELINUX_SET paths"
else
  ui_print "[!] chcon not available, contexts will be set at boot"
  log_only "WARNING: chcon command not found"
fi

# ========================================
# PUBLIC LIBRARIES PATCHING (PLT)
# ========================================

if [ "$PLT" = "y" ]; then
  ui_print " "
  ui_print "Applying PLT patches..."
  log_only "Starting PLT (Public Libraries) patching..."

  PLT_DIR="$MODPATH/system/vendor/etc"
  mkdir -p "$PLT_DIR" 2>/dev/null

  PATCH_COUNT=0
  LINE_TO_ADD="gpu++.so"

  for vendor_etc in "/vendor/etc" "/system/vendor/etc"; do
    [ -d "$vendor_etc" ] || continue
    for plt_file in "$vendor_etc"/public.libraries*.txt; do
      [ -f "$plt_file" ] || continue
      DEST_FILE="$PLT_DIR/${plt_file##*/}"
      if [ ! -f "$DEST_FILE" ]; then
        if cp -f "$plt_file" "$DEST_FILE" 2>/dev/null; then
          log_only "Copied PLT file: ${plt_file##*/}"
        else
          log_only "WARNING: Failed to copy ${plt_file##*/}"
          continue
        fi
      fi
      if [ -s "$DEST_FILE" ]; then
        [ -n "$(tail -c1 "$DEST_FILE" 2>/dev/null)" ] && echo >> "$DEST_FILE"
        if ! grep -qF "$LINE_TO_ADD" "$DEST_FILE" 2>/dev/null; then
          if echo "$LINE_TO_ADD" >> "$DEST_FILE" 2>/dev/null; then
            PATCH_COUNT=$((PATCH_COUNT + 1))
            log_only "Patched: ${plt_file##*/} with '$LINE_TO_ADD'"
          else
            log_only "WARNING: Failed to patch ${plt_file##*/}"
          fi
        else
          log_only "Already patched: ${plt_file##*/}"
        fi
      fi
    done
  done

  if [ $PATCH_COUNT -gt 0 ]; then
    ui_print "[OK] PLT patched ($PATCH_COUNT file(s))"
  else
    ui_print "[OK] PLT verified (already patched)"
  fi
else
  ui_print " "
  ui_print "[-] PLT patching disabled"
  log_only "PLT patching skipped (disabled in config)"
fi

# ========================================
# QGL CONFIGURATION
# ========================================

if [ "$QGL" = "y" ]; then
  ui_print " "
  ui_print "Installing QGL configuration..."
  log_only "Setting up QGL (Qualcomm GPU Library) configuration..."

  QGL_TMP="$TMPDIR/qgl_config.txt"
  QGL_MOD="$MODPATH/qgl_config.txt"

  mkdir -p "$MODPATH" 2>/dev/null || true

  if [ -f "$QGL_TMP" ]; then
    if cp -af "$QGL_TMP" "$QGL_MOD" 2>/dev/null; then
      log_only "QGL config copied from TMPDIR to module"
      ui_print "[OK] QGL configuration ready"
      log_only "QGL config will be installed at boot by post-fs-data.sh"
    else
      if [ -f "$QGL_MOD" ]; then
        log_only "Failed to copy from TMPDIR, but module already contains qgl_config.txt"
        ui_print "[OK] QGL configuration ready (using existing file in module)"
      else
        ui_print "[!] Failed to copy QGL config to module"
        log_only "WARNING: Failed to copy QGL config to module"
      fi
    fi
  elif [ -f "$QGL_MOD" ]; then
    ui_print "[OK] QGL configuration ready"
    log_only "QGL config already present in module; will be installed at boot by post-fs-data.sh"
  else
    ui_print "[!] QGL config file not found"
    log_only "WARNING: QGL enabled but qgl_config.txt not found in TMPDIR or module"
  fi
else
  ui_print " "
  ui_print "[-] QGL configuration disabled"
  log_only "QGL configuration skipped (disabled in config)"
fi

# ========================================
# RENDER MODE PROPERTY
# ========================================
# IMPORTANT: Render mode props (debug.hwui.renderer, debug.renderengine.backend)
# are deliberately NOT written to system.prop here.
#
# Reason: system.prop is loaded by the root manager via resetprop BEFORE
# post-fs-data.sh executes and BEFORE the first-boot safety check runs.
# Writing skiavk/skiagl to system.prop at install time causes bootloop on the
# FIRST boot after a fresh flash because:
#   1. Vulkan driver validation on a pristine install (zero shader cache) can
#      time out, crashing SurfaceFlinger.
#   2. The background force-stop task fires mid-boot on the first boot.
#
# Instead, render mode is applied dynamically via resetprop in post-fs-data.sh
# AFTER the first-boot safety check. post-fs-data.sh runs before Zygote and
# SurfaceFlinger, so the timing is correct for all non-first-boot cases.
#
# On the FIRST boot after install, post-fs-data.sh detects .first_boot_pending
# and uses normal mode — preventing the bootloop. From the second boot onwards,
# the configured render mode is applied normally.

if [ -n "$RENDER_MODE" ] && [ "$RENDER_MODE" != "normal" ]; then
  ui_print " "
  ui_print "Render mode configured: $RENDER_MODE"
  ui_print "[!] NOTE: Renderer override activates from 2nd boot onwards."
  ui_print "    First boot: system-default renderer (no debug.hwui.renderer set)."
  ui_print "    All stability/compatibility props ARE active on first boot."
  ui_print "    Skia pipeline caches cleared pre-Zygote on mode change."
  log_only "Render mode ($RENDER_MODE): renderer prop deferred to 2nd boot"
  log_only "First boot: system-default renderer only. Stability props active."
else
  ui_print " "
  ui_print "Render mode: normal (default)"
  log_only "Render mode: normal (no special props needed)"
fi

# Ensure any stale render mode props from a previous install are stripped
# from system.prop at install time. Render props are managed EXCLUSIVELY
# via resetprop in post-fs-data.sh and NEVER written to system.prop.
# This strip ensures a clean state regardless of what a prior install left.
SYSTEM_PROP="$MODPATH/system.prop"
if [ -f "$SYSTEM_PROP" ]; then
  awk '!/^debug\.hwui\.renderer=/ &&
       !/^debug\.renderengine\.backend=/ &&
       !/^debug\.sf\.latch_unsignaled=/ &&
       !/^debug\.sf\.auto_latch_unsignaled=/ &&
       !/^debug\.sf\.disable_backpressure=/ &&
       !/^debug\.sf\.enable_hwc_vds=/ &&
       !/^debug\.sf\.enable_transaction_tracing=/ &&
       !/^debug\.sf\.client_composition_cache_size=/ &&
       !/^ro\.sf\.disable_triple_buffer=/ &&
       !/^ro\.surface_flinger\.use_context_priority=/ &&
       !/^ro\.surface_flinger\.max_frame_buffer_acquired_buffers=/ &&
       !/^ro\.surface_flinger\.force_hwc_copy_for_virtual_displays=/ &&
       !/^ro\.surface_flinger\.supports_background_blur=/ &&
       !/^debug\.hwui\.use_buffer_age=/ &&
       !/^debug\.hwui\.use_partial_updates=/ &&
       !/^debug\.hwui\.use_gpu_pixel_buffers=/ &&
       !/^renderthread\.skia\.reduceopstasksplitting=/ &&
       !/^debug\.hwui\.skip_empty_damage=/ &&
       !/^debug\.hwui\.webview_overlays_enabled=/ &&
       !/^debug\.hwui\.skia_tracing_enabled=/ &&
       !/^debug\.hwui\.skia_use_perfetto_track_events=/ &&
       !/^debug\.hwui\.capture_skp_enabled=/ &&
       !/^debug\.hwui\.skia_atrace_enabled=/ &&
       !/^debug\.hwui\.use_hint_manager=/ &&
       !/^debug\.hwui\.target_cpu_time_percent=/ &&
       !/^com\.qc\.hardware=/ &&
       !/^persist\.sys\.force_sw_gles=/ &&
       !/^debug\.vulkan\.layers=/ &&
       !/^debug\.vulkan\.layers\.enable=/ &&
       !/^ro\.hwui\.use_vulkan=/ &&
       !/^debug\.hwui\.recycled_buffer_cache_size=/ &&
       !/^debug\.hwui\.overdraw=/ &&
       !/^debug\.hwui\.profile=/ &&
       !/^debug\.hwui\.show_dirty_regions=/ &&
       !/^graphics\.gpu\.profiler\.support=/ &&
       !/^ro\.egl\.blobcache\.multifile=/ &&
       !/^ro\.egl\.blobcache\.multifile_limit=/ &&
       !/^debug\.hwui\.fps_divisor=/ &&
       !/^debug\.hwui\.render_thread=/ &&
       !/^debug\.hwui\.render_dirty_regions=/ &&
       !/^debug\.hwui\.show_layers_updates=/ &&
       !/^debug\.hwui\.filter_test_overhead=/ &&
       !/^debug\.hwui\.nv_profiling=/ &&
       !/^debug\.hwui\.clip_surfaceviews=/ &&
       !/^debug\.hwui\.8bit_hdr_headroom=/ &&
       !/^debug\.hwui\.skip_eglmanager_telemetry=/ &&
       !/^debug\.hwui\.initialize_gl_always=/ &&
       !/^debug\.hwui\.level=/ &&
       !/^debug\.hwui\.disable_vsync=/ &&
       !/^hwui\.disable_vsync=/ &&
       !/^debug\.hwui\.use_skia_graphite=/ &&
       !/^persist\.device_config\.runtime_native\.usap_pool_enabled=/ &&
       !/^debug\.gralloc\.enable_fb_ubwc=/ &&
       !/^persist\.sys\.perf\.topAppRenderThreadBoost\.enable=/ &&
       !/^persist\.sys\.gpu\.working_thread_priority=/ &&
       !/^debug\.sf\.early_phase_offset_ns=/ &&
       !/^debug\.sf\.early_app_phase_offset_ns=/ &&
       !/^debug\.sf\.early_gl_phase_offset_ns=/ &&
       !/^debug\.sf\.early_gl_app_phase_offset_ns=/' \
    "$SYSTEM_PROP" > "${SYSTEM_PROP}.tmp" 2>/dev/null && \
    mv "${SYSTEM_PROP}.tmp" "$SYSTEM_PROP" 2>/dev/null || \
    rm -f "${SYSTEM_PROP}.tmp" 2>/dev/null
  log_only "system.prop cleaned of all render/SF/HWUI/OEM/EGL/perf props (57+ patterns)"
fi

# ========================================
# GPU CACHE CLEANING
# ========================================

ui_print " "
ui_print "========================================"
ui_print "Cleaning GPU caches..."
ui_print "========================================"
ui_print " "

IN_RECOVERY=false
if [ -e /sbin/recovery ] || [ -n "${RECOVERY_MODE:-}" ] || \
   [ "$(getprop ro.bootmode 2>/dev/null)" = "recovery" ] || \
   [ "$(getprop ro.boot.mode 2>/dev/null)" = "recovery" ] || \
   [ ! -e /proc/1/cmdline ]; then
  IN_RECOVERY=true
  ui_print "[OK] Recovery mode - aggressive cleaning"
  log_only "Cache cleaning: Recovery mode detected"
else
  ui_print "[OK] Live system - conservative cleaning"
  log_only "Cache cleaning: Live system mode"
fi

if command_exists ionice; then
  ionice -c2 -n7 -p $$ 2>/dev/null || true
fi
if command_exists renice; then
  renice -n 19 -p $$ 2>/dev/null || true
fi

CACHE_CLEANED=0

if [ "$IN_RECOVERY" = "true" ]; then
  ui_print "Cleaning GPU shader caches..."
  find /data/user_de -type d \( -iname '*shader*' -o -iname '*gpucache*' -o -iname '*graphitecache*' \) -exec rm -rf {} + 2>/dev/null && CACHE_CLEANED=$((CACHE_CLEANED + 1)) || true
  sleep 1
  find /data/data -type d \( -iname '*shader*' -o -iname '*gpucache*' -o -iname '*graphitecache*' -o -iname '*program*cache*' \) -exec rm -rf {} + 2>/dev/null && CACHE_CLEANED=$((CACHE_CLEANED + 1)) || true
  sleep 1
  find /data/user -type d \( -iname '*shader*' -o -iname '*gpucache*' \) -exec rm -rf {} + 2>/dev/null && CACHE_CLEANED=$((CACHE_CLEANED + 1)) || true
else
  ui_print "Conservative cleaning (live system)..."
  log_only "Using conservative cache cleaning to prevent app crashes"
  find /data/user_de -type d -iname '*shader*' -empty -exec rm -rf {} + 2>/dev/null || true
  find /data/data -type d -iname '*shader*' -empty -exec rm -rf {} + 2>/dev/null || true
  CACHE_CLEANED=$((CACHE_CLEANED + 1))
fi

log_only "Cleaning system-level caches..."
rm -rf /data/system/graphicsstats/* 2>/dev/null || true
rm -rf /data/dalvik-cache/* 2>/dev/null || true
rm -rf /data/cache/* 2>/dev/null || true
rm -rf /data/system/package_cache/* 2>/dev/null || true
rm -rf /data/resource-cache/* 2>/dev/null || true
CACHE_CLEANED=$((CACHE_CLEANED + 1))

find /data -type d -path "*/code_cache/*/OpenGL" -exec rm -rf {} + 2>/dev/null || true
find /data -type d -path "*/code_cache/*/Vulkan" -exec rm -rf {} + 2>/dev/null || true
find /data -type d -name "com.android.gl.*" -path "*/code_cache/*" -exec rm -rf {} + 2>/dev/null || true
CACHE_CLEANED=$((CACHE_CLEANED + 1))

ui_print "[OK] GPU caches cleaned ($CACHE_CLEANED categories)"
log_only "Cache cleaning completed: $CACHE_CLEANED categories processed"

# ========================================
# SAVE CONFIGURATION FOR PERSISTENCE
# ========================================

ui_print " "
ui_print "Saving configuration..."

if [ "$CONFIG_FOUND" = "true" ] && [ -n "$CONFIG_FILE" ]; then
  cp -f "$CONFIG_FILE" "$MODPATH/adreno_config.txt" 2>/dev/null && \
    log_only "Configuration saved to module" || \
    log_only "WARNING: Failed to save configuration to module"
elif [ -f "$TMPDIR/adreno_config.txt" ]; then
  cp -f "$TMPDIR/adreno_config.txt" "$MODPATH/adreno_config.txt" 2>/dev/null && \
    log_only "Default configuration saved to module" || \
    log_only "WARNING: Failed to save default configuration"
fi

if [ -f "$MODPATH/adreno_config.txt" ]; then
  if mkdir -p "$SD_CONFIG_DIR" 2>/dev/null; then
    cp -f "$MODPATH/adreno_config.txt" "$SD_CONFIG_DIR/adreno_config.txt" 2>/dev/null && \
      log_only "Configuration backed up to SD Card" || \
      log_only "WARNING: Failed to backup configuration to SD Card"
  fi
fi

# ── game_exclusion_list.sh backup / restore ───────────────────────────────────
# The user's custom game exclusion list must survive reinstalls exactly like
# adreno_config.txt does.  Without this, every fresh install resets the list
# to the module's bundled default, losing any games the user added via WebUI.
#
# Priority (mirrors the source priority in service.sh):
#   1. SD card backup  → restore to MODPATH (user's saved list wins)
#   2. No SD backup    → copy the bundled default TO SD (first-run seed)
#
# The live WebUI-edited copy lives at:
#   /data/local/tmp/adreno_game_exclusion_list.sh (written by WebUI Save)
#   /sdcard/Adreno_Driver/Config/game_exclusion_list.sh (SD backup, written by service.sh)
#   $MODPATH/game_exclusion_list.sh (module-bundled default / last restored)
#
# We prefer the SD backup because it always has the user's latest edits
# (service.sh syncs it from /data/local/tmp at each successful boot).
_GE_SD="$SD_CONFIG_DIR/game_exclusion_list.sh"
_GE_DATA="/data/local/tmp/adreno_game_exclusion_list.sh"
_GE_MOD="$MODPATH/game_exclusion_list.sh"

if [ -f "$_GE_SD" ]; then
  # User has a previously saved list on SD — restore it into the module so
  # service.sh and post-fs-data.sh find it at $MODPATH/game_exclusion_list.sh.
  cp -f "$_GE_SD" "$_GE_MOD" 2>/dev/null && \
    log_only "[OK] game_exclusion_list.sh: restored from SD card backup" || \
    log_only "WARNING: Failed to restore game_exclusion_list.sh from SD"
  ui_print "[OK] Game exclusion list restored from SD backup"
elif [ -f "$_GE_DATA" ]; then
  # Live /data copy exists but no SD backup yet — copy it to both locations.
  cp -f "$_GE_DATA" "$_GE_MOD" 2>/dev/null && \
    log_only "[OK] game_exclusion_list.sh: restored from /data live copy" || true
  if mkdir -p "$SD_CONFIG_DIR" 2>/dev/null; then
    cp -f "$_GE_DATA" "$_GE_SD" 2>/dev/null && \
      log_only "[OK] game_exclusion_list.sh: backed up live copy to SD" || true
  fi
  ui_print "[OK] Game exclusion list restored from live data copy"
elif [ -f "$_GE_MOD" ]; then
  # Only the module-bundled default exists — seed SD backup for future installs.
  if mkdir -p "$SD_CONFIG_DIR" 2>/dev/null; then
    cp -f "$_GE_MOD" "$_GE_SD" 2>/dev/null && \
      log_only "[OK] game_exclusion_list.sh: default seeded to SD card" || \
      log_only "WARNING: Failed to seed game_exclusion_list.sh to SD"
  fi
  ui_print "[OK] Game exclusion list: default seeded to SD"
else
  log_only "INFO: No game_exclusion_list.sh found (WebUI will use built-in default on first run)"
fi
unset _GE_SD _GE_DATA _GE_MOD
# ─────────────────────────────────────────────────────────────────────────────

# ========================================
# SAVE INSTALLATION INFO
# ========================================

cat > "$MODPATH/.install_info" 2>/dev/null <<INSTALL_INFO
========================================
Adreno GPU Driver - Installation Info
========================================
Install Date: $(date 2>/dev/null || echo 'unknown')
Timestamp: $TIMESTAMP
Log File: $LOG_FILE

Root Environment:
-----------------
Root Type: $ROOT_TYPE
Root Version: $ROOT_VER
Uses Overlay: $USES_OVERLAY
Metamodule Installed: $METAMODULE_INSTALLED
Metamodule Active: $METAMODULE_ACTIVE
Metamodule Name: ${METAMODULE_NAME:-none}
SUSFS Present: $SUSFS_PRESENT

Device Information:
-------------------
Manufacturer: $MANUFACTURER
Model: $MODEL
Device: $DEVICE
Android Version: $ANDROID_VER
API Level: $API
Build ID: $BUILD_ID
ROM Type: $OEM_DETECTED
Architecture: $CPU_ABI
ARM64 Device: $IS_ARM64

GPU Information:
----------------
GPU Name: $GPU_NAME
GPU Supported: $GPU_SUPPORTED

Configuration:
--------------
PLT Enabled: $PLT
QGL Enabled: $QGL
ARM64 Optimization: $ARM64_OPT
Render Mode: $RENDER_MODE

ROM Compatibility:
------------------
HyperOS/MIUI: $HYPEROS_ROM
Samsung OneUI: $ONEUI_ROM
ColorOS: $COLOROS_ROM
RealmeUI: $REALME_ROM
FuntouchOS: $FUNTOUCH_ROM
OxygenOS: ${OXYGENOS_ROM:-false}

Installation Statistics:
------------------------
Files Copied: $FILES_COPIED
Files Failed: $FILES_FAILED
Permissions Set: $PERMS_SET
Permissions Failed: $PERMS_FAILED
SELinux Contexts: $SELINUX_SET
Cache Categories Cleaned: $CACHE_CLEANED
========================================
INSTALL_INFO

log_only "Installation info saved to $MODPATH/.install_info"

# ========================================
# FIRST BOOT PENDING MARKER
# ========================================
# Tells post-fs-data.sh this is the first boot after a fresh install.
# On first boot, post-fs-data.sh will:
#   1. Defer the renderer prop (system-default renderer used this boot)
#   2. Remove this marker so the 2nd boot sets the configured renderer normally
#   3. Create .service_skip_render so service.sh also skips the renderer prop
#
# All HWUI/EGL/GPU stability props ARE applied on first boot — only
# debug.hwui.renderer / debug.renderengine.backend are withheld until boot 2.
# This is intentional: deferring Vulkan on the first boot prevents a bootloop
# that occurs when skiavk/skiagl is forced on a pristine (empty) GPU shader cache.

if touch "$MODPATH/.first_boot_pending" 2>/dev/null; then
  log_only "First boot pending marker created: $MODPATH/.first_boot_pending"
  log_only "(SkiaVK/SkiaGL render mode deferred to 2nd boot for stability)"
else
  log_only "WARNING: Could not create first boot pending marker (non-fatal)"
fi

# ========================================
# RESET BOOTLOOP COUNTER
# ========================================

rm -f "/data/local/tmp/adreno_boot_attempts" 2>/dev/null
rm -f "/data/local/tmp/adreno_boot_state" 2>/dev/null
log_only "Boot counters reset for fresh install"

# ========================================
# INSTALLATION SUMMARY
# ========================================

ui_print " "
ui_print "========================================"
ui_print "  INSTALLATION COMPLETE"
ui_print "========================================"
ui_print " "
ui_print "[OK] Driver files installed"
ui_print "[OK] Permissions configured"
ui_print "[OK] GPU caches cleaned"
ui_print "[OK] Configuration saved"
ui_print " "
ui_print "Module Information:"
ui_print "-------------------"
ui_print "  - Root: $ROOT_TYPE ${ROOT_VER:+v}$ROOT_VER"
ui_print "  - Device: $MANUFACTURER $MODEL"
ui_print "  - Android: $ANDROID_VER (API $API)"
ui_print "  - GPU: $GPU_NAME"
ui_print "  - ROM: $OEM_DETECTED"
ui_print " "

if [ "$SUSFS_PRESENT" = "true" ]; then
  ui_print "Root Hiding:"
  ui_print "------------"
  ui_print "[OK] SUSFS detected - kernel-level hiding active"
  ui_print " "
fi

if [ "$ROOT_TYPE" = "Magisk" ]; then
  ui_print "Mount Status:"
  ui_print "-------------"
  ui_print "[OK] Magisk Magic Mount active"
  ui_print " "
elif [ "$ROOT_TYPE" = "KernelSU" ]; then
  if [ "$METAMODULE_INSTALLED" = "true" ]; then
    ui_print "Mount Status:"
    ui_print "-------------"
    ui_print "[OK] Metamodule: ${METAMODULE_NAME:-Active}"
    ui_print " "
  else
    ui_print "Mount Status:"
    ui_print "-------------"
    ui_print "[!] No metamodule detected!"
    ui_print " "
    ui_print "! IMPORTANT: Install a mounting solution:"
    ui_print "  - MetaMagicMount (RECOMMENDED)"
    ui_print "  - Meta-OverlayFS / Meta-Mountify"
    ui_print " "
    ui_print "Without a metamodule, the driver will NOT work!"
    ui_print " "
  fi
elif [ "$ROOT_TYPE" = "APatch" ]; then
  ui_print "Mount Status:"
  ui_print "-------------"
  ui_print "[OK] APatch native OverlayFS"
  ui_print " "
fi

if [ $FILES_FAILED -gt 0 ] || [ $PERMS_FAILED -gt 0 ]; then
  ui_print "Installation Warnings:"
  ui_print "----------------------"
  [ $FILES_FAILED -gt 0 ] && ui_print "  [!] $FILES_FAILED file copy errors"
  [ $PERMS_FAILED -gt 0 ] && ui_print "  [!] $PERMS_FAILED permission errors"
  ui_print " "
  ui_print "Check log: $LOG_FILE"
  ui_print " "
fi

ui_print "========================================"
ui_print "  Installation Successful!"
ui_print "========================================"
ui_print " "
ui_print "[!] REBOOT REQUIRED to activate drivers"
ui_print " "
ui_print "Config: /sdcard/Adreno_Driver/Config/"
ui_print "Log: $LOG_FILE"
ui_print " "

log_only "========================================"
log_only "Installation Completed Successfully"
log_only "========================================"
log_only "Completion time: $(date 2>/dev/null || echo 'unknown')"
log_only "Root Type: $ROOT_TYPE ${ROOT_VER:+v}$ROOT_VER"
log_only "Device: $MANUFACTURER $MODEL ($DEVICE)"
log_only "Android: $ANDROID_VER (API $API)"
log_only "GPU: $GPU_NAME"
log_only "========================================"

# DO NOT use 'exit' — per Magisk docs, customize.sh must not call exit.
