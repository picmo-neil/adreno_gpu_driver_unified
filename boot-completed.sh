#!/system/bin/sh
# Adreno GPU Driver - Boot Completed Script
# Runs at sys.boot_completed via KSU-Next/KernelSU/Magisk/APatch boot-completed stage.
#
# PURPOSE: Write qgl_config.txt FRESH at BOOT_COMPLETED — exactly mirroring LYB
# Kernel Manager's timing and mechanism (Section 7 of RE reference).
#
# WHY FRESH WRITE (not chmod):
#   post-fs-data.sh writes qgl_config.txt at mode=0000 (protected) to prevent
#   SurfaceFlinger's early vkCreateDevice from reading it and hanging.
#   Previously, boot-completed.sh only did chmod 0644. That approach had a fatal
#   flaw: chcon same_process_hal_file on an EXISTING vendor_data_file-labeled file
#   fails silently on OEM ROMs with neverallow for same_process_hal_file on /data.
#   Result: file is at 0644 but wrong SELinux context → Adreno driver validates
#   BOTH file AND directory context (RE reference §7) → context wrong → driver
#   silently ignores the file → QGL never activates despite appearing active.
#
#   LYB's approach (Section 7): rm → touch (new inode) → chcon dir → chcon file →
#   write content. The fresh inode in an already-labeled directory correctly inherits
#   same_process_hal_file via type_transition policy on every ROM. Context is always
#   right because it's set at file CREATION, not applied to an existing file.
#
#   This script replicates LYB's exact mechanism.
#
# Developer: @pica_pica_picachu | Channel: @zesty_pic

MODDIR="${0%/*}"

# ── 1. Load QGL and RENDER_MODE from config ──────────────────────────────
# RENDER_MODE is needed for the state-file-based cache clear (section 4).
QGL="n"
RENDER_MODE=""
for _cfg in \
    "/sdcard/Adreno_Driver/Config/adreno_config.txt" \
    "/data/local/tmp/adreno_config.txt" \
    "$MODDIR/adreno_config.txt"; do
  [ -f "$_cfg" ] || continue
  _has_qgl=false
  while IFS='= ' read -r _k _v; do
    _v="${_v%%$'\r'}"
    case "$_k" in
      '#'*|'') continue ;;
      QGL)
        case "$_v" in
          [Yy]|[Yy][Ee][Ss]|1) QGL="y" ;;
        esac
        _has_qgl=true
        ;;
      RENDER_MODE)
        RENDER_MODE="$_v"
        ;;
    esac
  done < "$_cfg"
  [ "$_has_qgl" = "true" ] && break
done
unset _cfg _k _v _has_qgl

# Skip if QGL is disabled
[ "$QGL" = "y" ] || exit 0

printf '[ADRENO] boot-completed.sh: QGL=y — writing fresh qgl_config.txt (LYB-style)\n' \
  > /dev/kmsg 2>/dev/null || true

# ── DYNAMIC TIMING — detect launcher first-frame instead of fixed sleep ───────
#
# WHY DYNAMIC: LYB's write timing is NOT a fixed sleep — it is the cumulative
# wall-clock time of all blocking operations before r1.b() fires:
#   uname -a + devfreq discovery (multiple cat/ls per device) + lkm_8.txt parse
#   + JSON config reload. This varies per device (3–25s). A fixed 20s is wrong
#   for most devices — too late on fast ones, too early on slow ones.
#
# WHAT WE ACTUALLY NEED: QGL must appear AFTER the launcher and SystemUI have
# already called vkCreateDevice and initialised their Vulkan contexts. Once a
# process has vkCreateDevice open, the presence of qgl_config.txt does NOT
# affect it (the driver reads it only at vkCreateDevice time). So: detect when
# the launcher has rendered its first frames → its vkCreateDevice is done →
# safe to write QGL → all subsequent app opens see QGL from the start.
#
# DETECTION STRATEGY (three layers, most accurate to fallback):
#   Layer 1: Find default launcher package dynamically via PackageManager.
#   Layer 2: Poll dumpsys gfxinfo for the launcher until frames > 0.
#            This is the exact moment vkCreateDevice has been called.
#   Layer 3: Absolute safety ceiling of 30s prevents hanging on edge cases.
#   Layer 4: +2s buffer after frame detection — ensures the launcher's
#            RenderThread has fully settled (HWUI init is async after first
#            frame submission, not before).
#
# NO FORCE-STOPS — EVER. LYB never force-stops any app. Neither do we.
# ─────────────────────────────────────────────────────────────────────────────

# Layer 1: Resolve default home/launcher package
_bc_home=""
_bc_home_raw=$(cmd package resolve-activity --brief \
  -a android.intent.action.MAIN \
  -c android.intent.category.HOME 2>/dev/null | head -1)
# Strip "/Activity" class suffix — keep only the package name
_bc_home="${_bc_home_raw%%/*}"
# Sanitise: must look like a dotted package name
case "$_bc_home" in
  *.*)  : ;;           # valid (e.g. com.android.launcher3)
  *)    _bc_home="" ;; # garbage — discard
esac
unset _bc_home_raw

printf '[ADRENO] boot-completed.sh: dynamic QGL timing — launcher=%s\n' \
  "${_bc_home:-unknown}" > /dev/kmsg 2>/dev/null || true

# Layer 2: Poll gfxinfo until launcher has rendered at least 1 frame.
# dumpsys gfxinfo <pkg> returns "Total frames rendered: N" in its header block.
# N > 0 means the HWUI RenderThread has submitted at least one frame → vkCreateDevice
# has already been called → safe to write QGL.
_bc_waited=0
_bc_max=28   # hard ceiling: 28s poll + 2s buffer = 30s absolute max
_bc_frames_done=false

if [ -n "$_bc_home" ]; then
  while [ $_bc_waited -lt $_bc_max ]; do
    # Extract "Total frames rendered: N" from gfxinfo header
    _bc_frames=$(dumpsys gfxinfo "$_bc_home" 2>/dev/null \
      | awk '/Total frames rendered/{print $NF; exit}' 2>/dev/null || echo "0")
    _bc_frames="${_bc_frames:-0}"
    # Strip non-digits (e.g. trailing comma on some ROM variants)
    _bc_frames="${_bc_frames%%[!0-9]*}"
    if [ "${_bc_frames:-0}" -gt 0 ] 2>/dev/null; then
      _bc_frames_done=true
      break
    fi
    sleep 1
    _bc_waited=$((_bc_waited + 1))
  done
else
  # No launcher detected — cannot poll; wait a fixed 6s (safe for most devices)
  printf '[ADRENO] boot-completed.sh: no launcher detected — using fixed 6s fallback\n' \
    > /dev/kmsg 2>/dev/null || true
  sleep 6
  _bc_frames_done=true
fi

# Layer 3: Fallback log if we hit the ceiling without detecting frames
if [ "$_bc_frames_done" = "false" ]; then
  printf '[ADRENO] boot-completed.sh: frame detection timed out after %ds — proceeding anyway\n' \
    "$_bc_waited" > /dev/kmsg 2>/dev/null || true
fi

# Layer 4: +2s buffer after frame detection to let HWUI RenderThread fully settle.
# The first frame submission != HWUI fully initialised; the async init continues
# for ~1–2s after the first frame. This buffer closes that window.
sleep 2

printf '[ADRENO] boot-completed.sh: launcher frames detected after %ds + 2s buffer — writing QGL\n' \
  "$_bc_waited" > /dev/kmsg 2>/dev/null || true
unset _bc_home _bc_waited _bc_max _bc_frames _bc_frames_done

QGL_TARGET="/data/vendor/gpu/qgl_config.txt"
QGL_OWNER_MARKER="/data/vendor/gpu/.adreno_qgl_owner"

# ── 2. Locate the QGL source file ────────────────────────────────────────────
# Priority: /sdcard (mounted by boot_completed) → /data/local/tmp → $MODDIR
# Same priority order as post-fs-data.sh and service.sh use.
_bc_qsrc=""
for _qs in \
    "/sdcard/Adreno_Driver/Config/qgl_config.txt" \
    "/data/local/tmp/qgl_config.txt" \
    "$MODDIR/qgl_config.txt"; do
  [ -f "$_qs" ] && { _bc_qsrc="$_qs"; break; }
done
unset _qs

if [ -z "$_bc_qsrc" ]; then
  printf '[ADRENO] boot-completed.sh: no qgl_config.txt source found — exiting\n' \
    > /dev/kmsg 2>/dev/null || true
  exit 0
fi

# ── 2b. SELinux injection — needed for write/unlink on vendor_data_file ──────
#
# We need: unlink (rm), create (cp), setattr (chmod/chown/chcon) on
# vendor_data_file and same_process_hal_file. Inject before any file ops.
#
_bc_injected=false
for _spbin in "/data/adb/ksud" "/data/adb/ksu/bin/ksud"; do
  [ -f "$_spbin" ] && [ -x "$_spbin" ] || continue
  "$_spbin" sepolicy patch \
    "allow su vendor_data_file file { getattr setattr relabelfrom relabelto create write unlink open read }" \
    >/dev/null 2>&1 && _bc_injected=true
  "$_spbin" sepolicy patch \
    "allow su same_process_hal_file file { getattr setattr relabelto relabelfrom create write unlink open read }" \
    >/dev/null 2>&1 || true
  "$_spbin" sepolicy patch \
    "allow su same_process_hal_file dir { getattr setattr relabelto relabelfrom search read open write add_name remove_name }" \
    >/dev/null 2>&1 || true
  "$_spbin" sepolicy patch \
    "allow su vendor_data_file dir { getattr search read open write add_name remove_name }" \
    >/dev/null 2>&1 || true
  "$_spbin" sepolicy patch \
    "allow same_process_hal_file labeledfs filesystem associate" \
    >/dev/null 2>&1 || true
  "$_spbin" sepolicy patch \
    "allow su unlabeled file { getattr setattr relabelfrom relabelto create write unlink open read }" \
    >/dev/null 2>&1 || true
  break
done
if [ "$_bc_injected" = "false" ]; then
  for _spbin in \
      "$(command -v magiskpolicy 2>/dev/null)" \
      "/data/adb/magisk/magiskpolicy" \
      "/data/adb/ksu/bin/magiskpolicy" \
      "/data/adb/ap/bin/magiskpolicy"; do
    [ -z "$_spbin" ] && continue
    [ -f "$_spbin" ] && [ -x "$_spbin" ] || continue
    "$_spbin" --live \
      "allow su vendor_data_file file { getattr setattr relabelfrom relabelto create write unlink open read }" \
      >/dev/null 2>&1 && _bc_injected=true
    "$_spbin" --live \
      "allow su same_process_hal_file file { getattr setattr relabelto relabelfrom create write unlink open read }" \
      >/dev/null 2>&1 || true
    "$_spbin" --live \
      "allow su same_process_hal_file dir { getattr setattr relabelto relabelfrom search read open write add_name remove_name }" \
      >/dev/null 2>&1 || true
    "$_spbin" --live \
      "allow su vendor_data_file dir { getattr search read open write add_name remove_name }" \
      >/dev/null 2>&1 || true
    "$_spbin" --live \
      "allow same_process_hal_file labeledfs filesystem associate" \
      >/dev/null 2>&1 || true
    "$_spbin" --live \
      "allow su unlabeled file { getattr setattr relabelfrom relabelto create write unlink open read }" \
      >/dev/null 2>&1 || true
    break
  done
fi
unset _spbin _bc_injected
# ── END PRE-STAT INJECTION ────────────────────────────────────────────────

# ── 3. No cache clearing at boot_completed — apps are already running ──────
#
# At boot_completed, SurfaceFlinger, SystemUI, the launcher, and Zygote have
# already initialised. Clearing pipeline caches HERE forces the first user-
# opened app to cold-recompile ALL shaders with QGL already active. The custom
# Adreno driver crashes in QGLCCompileToIRShader during cold compilation under
# QGL settings → device reboots on first app open.
#
# LYB Kernel Manager NEVER clears any cache on any boot. It writes
# qgl_config.txt and lets all apps reuse their existing pipeline blobs.
# Existing blobs remain valid: QGL changes driver-internal execution
# parameters, not the SPIR-V bytecode Skia submits. Reusing them is safe.
#
# All necessary cache clearing (render mode change GL↔Vulkan = incompatible
# binary blob format, first install) is handled exclusively by post-fs-data.sh
# BEFORE Zygote starts — the only window where clearing is safe.
#
printf '[ADRENO] boot-completed.sh: writing qgl_config.txt — LYB-style, no force-stops, no cache clear\n' \
  > /dev/kmsg 2>/dev/null || true

rm -f /data/local/tmp/adreno_post_fs_data_done 2>/dev/null || true

# ── 4. Write qgl_config.txt FRESH — LYB-style mechanism with atomic cp ────
#
# LYB Section 7 (RE reference) sequence:
#   mkdir /data/vendor/gpu
#   rm /data/vendor/gpu/qgl_config.txt
#   touch /data/vendor/gpu/qgl_config.txt
#   chcon u:object_r:same_process_hal_file:s0 /data/vendor/gpu
#   chcon u:object_r:same_process_hal_file:s0 /data/vendor/gpu/qgl_config.txt
#   echo KEY=VAL >> ...  (each setting)
#
# WHY THIS WORKS WHEN CHMOD-ONLY DID NOT:
#   The Adreno driver validates BOTH the file AND directory SELinux context
#   before reading qgl_config.txt (RE reference §7). chcon on an EXISTING
#   vendor_data_file-labeled file fails silently on OEM ROMs that have
#   neverallow blocking same_process_hal_file relabeling on /data fs.
#   A FRESH file created in an already-labeled same_process_hal_file directory
#   inherits the correct label via kernel type_transition policy — this works
#   on every ROM without needing relabelfrom/relabelto permissions at all.
#
# WHY cp INSTEAD OF LINE-BY-LINE echo:
#   LYB's line-by-line echo submits all commands simultaneously as fire-and-forget
#   async shells — they execute in rapid succession with no artificial delay.
#   A while loop with sleep 0.1 between 177 lines = 17+ seconds of partial file
#   exposure: force-stopped apps that restart during this window call vkCreateDevice
#   against an incomplete config → non-deterministic driver state → crash.
#   cp is atomic: the file goes from absent to complete in a single operation.
#   No partial-write window → no race → force-stopped apps always see either
#   no file (defaults) or the complete config. Clean and correct.
#
mkdir -p /data/vendor/gpu 2>/dev/null || true

# Step 1: Label directory FIRST (LYB §4.3: chcon dir before file creation)
chcon u:object_r:same_process_hal_file:s0 /data/vendor/gpu 2>/dev/null || true

# Step 2: Remove previous file — fresh inode (LYB: rm)
rm -f "$QGL_TARGET" 2>/dev/null || true

# Step 3: Copy complete file atomically (replaces LYB's touch → echo × N sequence)
# cp is a single syscall sequence: open → write full content → close.
# File inherits same_process_hal_file context from the directory via type_transition.
if ! cp -f "$_bc_qsrc" "$QGL_TARGET" 2>/dev/null; then
  printf '[ADRENO] boot-completed.sh: cp FAILED — QGL not activated\n' \
    > /dev/kmsg 2>/dev/null || true
  exit 1
fi
unset _bc_qsrc

if [ ! -f "$QGL_TARGET" ]; then
  printf '[ADRENO] boot-completed.sh: QGL_TARGET missing after cp — QGL not activated\n' \
    > /dev/kmsg 2>/dev/null || true
  exit 1
fi

# Step 4: Set ownership, permissions, and SELinux context
chmod 0644 "$QGL_TARGET" 2>/dev/null || true
chown 0:1000 "$QGL_TARGET" 2>/dev/null || true
chcon u:object_r:same_process_hal_file:s0 "$QGL_TARGET" 2>/dev/null || \
  chcon u:object_r:vendor_data_file:s0 "$QGL_TARGET" 2>/dev/null || true

# Write owner marker so service.sh CASE A/B/C recognises this as our file
touch "$QGL_OWNER_MARKER" 2>/dev/null || true
chmod 0600 "$QGL_OWNER_MARKER" 2>/dev/null || true

# ── 5. Verify and log ─────────────────────────────────────────────────────
_bc_mode=$(stat -c '%a' "$QGL_TARGET" 2>/dev/null || echo "?")
_bc_ctx=$(ls -Z "$QGL_TARGET" 2>/dev/null | awk '{print $1}' || echo "?")
_bc_dir_ctx=$(ls -Zd /data/vendor/gpu 2>/dev/null | awk '{print $1}' || echo "?")
_bc_size=$(stat -c '%s' "$QGL_TARGET" 2>/dev/null || echo "?")

if [ "$_bc_mode" = "644" ] || [ "$_bc_mode" = "0644" ]; then
  printf '[ADRENO] boot-completed.sh: QGL WRITTEN OK mode=%s size=%s file_ctx=%s dir_ctx=%s\n' \
    "$_bc_mode" "$_bc_size" "$_bc_ctx" "$_bc_dir_ctx" > /dev/kmsg 2>/dev/null || true
else
  printf '[ADRENO] boot-completed.sh: QGL WRITE PARTIAL mode=%s ctx=%s — check avc\n' \
    "$_bc_mode" "$_bc_ctx" > /dev/kmsg 2>/dev/null || true
fi
unset _bc_mode _bc_ctx _bc_dir_ctx _bc_size

exit 0
