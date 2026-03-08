#!/system/bin/sh
# ============================================================
# ADRENO DRIVER MODULE — GAME EXCLUSION LIST
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
# ============================================================
# This file is sourced by BOTH post-fs-data.sh AND service.sh.
# It defines which app packages are excluded from the
# throttled force-stop sequence when activating skiavk/skiavk_all.
#
# ===================== READ THIS FIRST =======================
#
# This list covers TWO distinct rendering problems under skiavk.
# Add a package here ONLY if it matches one of these two groups:
#
# GROUP 1 — Add if ALL of these apply (dual-VkDevice crash):
#   - The app CRASHES immediately in skiavk or skiavk_all mode
#     (black screen, instant force-close, logcat shows GPU fault:
#     "concurrent vkCreateDevice" or SIGSEGV in libgsl.so)
#   - The crash does NOT happen in skiagl or normal mode
#
# GROUP 2 — Add if ALL of these apply (UBWC green-line artifact):
#   - The app shows a persistent green horizontal line on screen
#     in skiavk mode (specific scan lines, not a full-screen tint)
#   - The artifact disappears when switched to skiagl mode
#   - Currently: Meta apps (Facebook, Instagram, WhatsApp) due to
#     HWUI Vulkan UBWC tile layout mismatch with their native layers
#
# WHEN NOT TO ADD / WHEN TO REMOVE:
#   - App runs FINE in skiavk or skiavk_all mode              -> do NOT add it
#   - App crashes for unrelated reasons (anti-cheat, root
#     detection, network issues)                              -> do NOT add it
#   - A previously-added app no longer shows symptoms         -> REMOVE it
#
#   Adding unnecessarily disables daemon protection for that app
#   AND keeps it on GL longer than needed after each boot.
#
# ===================== WHY APPS ARE EXCLUDED =================
#
# GROUP 1 — Dual-VkDevice crash (UE4/native-Vulkan games):
#   Native-Vulkan games (UE4 engine: PUBG/Fortnite/CoD,
#   custom Vulkan engines: Genshin/HSR/ZZZ) create their own
#   VkDevice from a native thread. If HWUI also holds skiavk
#   (a second VkDevice in the same process), the custom Adreno
#   driver cannot handle concurrent vkCreateDevice -> SIGSEGV.
#   The game-compatibility daemon (service.sh) switches
#   debug.hwui.renderer to skiagl within ~1s of detecting any
#   listed game in /proc, so HWUI uses GL and the game uses
#   Vulkan -- no conflict. Force-stopping at boot+35s ensures
#   games cold-start AFTER the daemon is running.
#
# GROUP 2 — Green line artifact (Meta apps: Facebook/Instagram/WhatsApp):
#   HWUI Vulkan swapchain allocates buffers in UBWC compressed format.
#   Meta apps' native render layers (React Native canvas, libvpx media)
#   use gralloc buffers with a DIFFERENT UBWC tile layout expectation.
#   When SurfaceFlinger composites both surfaces, the UBWC metadata
#   mismatch causes color channel corruption on specific scan lines ->
#   green line. Fix: switch HWUI to skiagl -> GL buffers -> no mismatch.
#
# EDIT VIA WEBUI:
#   The Adreno Manager WebUI (Config -> Game Exclusion List)
#   writes to this file. You can also edit manually -- one
#   package name per line inside GAME_EXCLUSION_PKGS.
#   Glob wildcards (e.g. com.epicgames.*) are supported.
#
# FORMAT:
#   GAME_EXCLUSION_PKGS is a whitespace-separated list.
#   Lines inside the heredoc are trimmed of comments.
#   The _game_pkg_excluded() function uses a case statement
#   with an O(n) linear scan — acceptable for lists of <50 entries.
# ============================================================

GAME_EXCLUSION_PKGS="
com.tencent.ig
com.pubg.krmobile
com.pubg.imobile
com.pubg.newstate
com.vng.pubgmobile
com.rekoo.pubgm
com.tencent.tmgp.pubgmhd
com.epicgames.*
com.activision.callofduty.shooter
com.garena.game.codm
com.tencent.tmgp.cod
com.vng.codmvn
com.miHoYo.GenshinImpact
com.cognosphere.GenshinImpact
com.miHoYo.enterprise.HSRPrism
com.HoYoverse.hkrpgoversea
com.levelinfinite.hotta
com.proximabeta.mfh
com.HoYoverse.Nap
com.miHoYo.ZZZ
com.facebook.katana
com.facebook.orca
com.facebook.lite
com.facebook.mlite
com.instagram.android
com.instagram.lite
com.instagram.barcelona
com.whatsapp
com.whatsapp.w4b
"

# -- _game_pkg_excluded PKG ------------------------------------------
# Returns 0 (true) if $1 matches any entry in the list.
# The case pattern expands globs (e.g. com.epicgames.*)
# correctly because they appear as unquoted case patterns.
# --------------------------------------------------------------------
_game_pkg_excluded() {
  local _p="$1"
  local _entry
  for _entry in $GAME_EXCLUSION_PKGS; do
    # shellcheck disable=SC2254
    case "$_p" in
      $_entry) return 0 ;;
    esac
  done
  return 1
}
