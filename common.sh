# ============================================================
# ADRENO DRIVER MODULE — SHARED FUNCTIONS
# ============================================================
MODDIR="${0%/*}"

# Canonical metamodule ID list for detection
_METAMODULE_IDS="meta_overlayfs meta-magic-mount MetaMagicMount magic_mount meta-hybrid MetaHybrid MKSU_Module"

# Simple metamodule detector
detect_metamodule() {
    METAMODULE_ACTIVE=false
    [ -L "/data/adb/metamodule" ] && METAMODULE_ACTIVE=true && return 0
    if [ -d "/data/adb/modules" ]; then
        for meta_id in $_METAMODULE_IDS; do
            if [ -d "/data/adb/modules/$meta_id" ] && [ ! -f "/data/adb/modules/$meta_id/disable" ]; then
                METAMODULE_ACTIVE=true
                return 0
            fi
        done
    fi
    return 1
}

# Dummy config loader for script compatibility
load_config() {
    [ -f "$1" ] && . "$1"
}
