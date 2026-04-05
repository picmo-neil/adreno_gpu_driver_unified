#!/system/bin/sh
# Adreno GPU Driver — QGL Config Activator (Boot Phase)
#
# TWO-PHASE QGL STRATEGY:
#   Phase 1 (post-fs-data.sh): REMOVE stale QGL before Zygote forks.
#     Prevents GPU driver from reading QGL during init (causes bootloop).
#   Phase 2 (this script): RE-APPLY QGL after system is stable.
#     Delegates to apply_qgl.sh --boot for the actual write.
#
# PER-APP QGL: After boot, the QGL Trigger APK (AccessibilityService)
#   handles per-app QGL application. When any app opens, the APK calls
#   apply_qgl.sh <package_name> which writes the app-specific profile.
#   This matches LYB Kernel Manager's exact behavior.
#
# TIMING FIX (BUG ALPHA): LYB's onboot BroadcastReceiver applies QGL
#   IMMEDIATELY at BOOT_COMPLETED — NO launcher PID wait. The "wait for
#   launcher" step created a 3-60s window where qgl_config.txt was absent,
#   allowing the APK to write a per-app config BEFORE the global baseline.
#   This caused mixed KGSL contexts → cascade crash → bootloop.
#   Fix: removed launcher PID polling. Apply at boot_completed+3s (matches
#   LYB's implicit BroadcastReceiver timing).

MODDIR="${0%/*}"

# ── Logging helper ───────────────────────────────────────────────────────
log_only() {
  printf '[%s] %s\n' "$(date +%H:%M:%S)" "$1" >> /dev/kmsg 2>/dev/null || true
  printf '[%s] %s\n' "$(date +%H:%M:%S)" "$1" >> /sdcard/Adreno_Driver/qgl_trigger.log 2>/dev/null || true
}

# ── Load config ──────────────────────────────────────────────────────────
QGL="n"
QGL_PERAPP="n"
for _cfg in \
    "/sdcard/Adreno_Driver/Config/adreno_config.txt" \
    "/data/local/tmp/adreno_config.txt" \
    "$MODDIR/adreno_config.txt"; do
  [ -f "$_cfg" ] || continue
  while IFS='= ' read -r _k _v; do
    case "$_k" in
      QGL) case "$_v" in [Yy]*|1) QGL="y" ;; esac ;;
      QGL_PERAPP) case "$_v" in [Yy]*|1) QGL_PERAPP="y" ;; esac ;;
    esac
  done < "$_cfg"
  [ "$QGL" = "y" ] && break
done
unset _cfg _k _v
[ "$QGL" = "y" ] || exit 0

# ══════════════════════════════════════════════════════════════════════════
# STEP 1: WAIT FOR BOOT COMPLETED
# ══════════════════════════════════════════════════════════════════════════

_boot_wait=0
while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ] && [ $_boot_wait -lt 120 ]; do
  sleep 1
  _boot_wait=$((_boot_wait + 1))
done
unset _boot_wait
[ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ] && exit 0

# ══════════════════════════════════════════════════════════════════════════
# STEP 2: SAFETY MARGIN (Vulkan pipeline settle)
# ══════════════════════════════════════════════════════════════════════════
# 3s stabilization — matches LYB BroadcastReceiver implicit timing.
# LYB does NOT wait for launcher PID; it applies QGL immediately at
# BOOT_COMPLETED. The BroadcastReceiver system provides enough delay
# (typically 1-2s from broadcast to onReceive execution).
sleep 3

# ══════════════════════════════════════════════════════════════════════════
# STEP 3: WRITE BOOT BASELINE FLAG (for APK coordination)
# ══════════════════════════════════════════════════════════════════════════
# BUG ALPHA FIX: Write a flag file BEFORE applying QGL. The APK checks this
# flag before writing per-app configs. If absent, the APK skips the write
# and lets boot-completed.sh establish the global baseline first.
# This prevents the race where the APK writes a per-app config during the
# window between boot_completed and the global baseline write.
_QGL_BASELINE_FLAG="/data/vendor/gpu/.qgl_boot_baseline_ready"
mkdir -p /data/vendor/gpu 2>/dev/null
touch "$_QGL_BASELINE_FLAG" 2>/dev/null || true

# ══════════════════════════════════════════════════════════════════════════
# STEP 3b: BOOT 2+ FAST EXIT (ADR-005)
# ══════════════════════════════════════════════════════════════════════════
# If qgl_config.txt already exists with correct same_process_hal_file context,
# the global baseline is already in place from a previous boot. LYB never
# rewrites on boot 2+ — skip entirely to avoid races with the APK.
_QGL_TARGET="/data/vendor/gpu/qgl_config.txt"
if [ -f "$_QGL_TARGET" ]; then
  _qgl_ctx=$(ls -Z "$_QGL_TARGET" 2>/dev/null | awk '{print $1}' || echo "")
  case "$_qgl_ctx" in
    *same_process_hal_file*)
      log_only "[OK] QGL boot 2+ fast exit: file exists with correct context ($_qgl_ctx)"
      unset _qgl_ctx _QGL_TARGET _QGL_BASELINE_FLAG
      exit 0
      ;;
  esac
  log_only "[BOOT] QGL file exists but wrong context ($_qgl_ctx) — will re-apply"
fi
unset _qgl_ctx _QGL_TARGET

# ══════════════════════════════════════════════════════════════════════════
# STEP 3b: BOOT 2+ FAST EXIT (ADR-005)
# ══════════════════════════════════════════════════════════════════════════
# If qgl_config.txt already exists with correct same_process_hal_file context,
# the global baseline is already in place from a previous boot. LYB never
# rewrites on boot 2+ — skip entirely to avoid races with the APK.
_QGL_TARGET="/data/vendor/gpu/qgl_config.txt"
if [ -f "$_QGL_TARGET" ]; then
  _qgl_ctx=$(ls -Z "$_QGL_TARGET" 2>/dev/null | awk '{print $1}' || echo "")
  case "$_qgl_ctx" in
    *same_process_hal_file*)
      log_only "[OK] QGL boot 2+ fast exit: file exists with correct context ($_qgl_ctx)"
      unset _qgl_ctx _QGL_TARGET _QGL_BASELINE_FLAG
      exit 0
      ;;
  esac
  log_only "[BOOT] QGL file exists but wrong context ($_qgl_ctx) — will re-apply"
fi
unset _qgl_ctx _QGL_TARGET

# ══════════════════════════════════════════════════════════════════════════
# STEP 3b: BOOT 2+ FAST EXIT (ADR-005)
# ══════════════════════════════════════════════════════════════════════════
# If qgl_config.txt already exists with correct same_process_hal_file context,
# the global baseline is already in place from a previous boot. LYB never
# rewrites on boot 2+ — skip entirely to avoid races with the APK.
_QGL_TARGET="/data/vendor/gpu/qgl_config.txt"
if [ -f "$_QGL_TARGET" ]; then
  _qgl_ctx=$(ls -Z "$_QGL_TARGET" 2>/dev/null | awk '{print $1}' || echo "")
  case "$_qgl_ctx" in
    *same_process_hal_file*)
      log_only "[OK] QGL boot 2+ fast exit: file exists with correct context ($_qgl_ctx)"
      unset _qgl_ctx _QGL_TARGET _QGL_BASELINE_FLAG
      exit 0
      ;;
  esac
  log_only "[BOOT] QGL file exists but wrong context ($_qgl_ctx) — will re-apply"
fi
unset _qgl_ctx _QGL_TARGET

# ══════════════════════════════════════════════════════════════════════════
# STEP 3b: BOOT 2+ FAST EXIT (ADR-005)
# ══════════════════════════════════════════════════════════════════════════
# If qgl_config.txt already exists with correct same_process_hal_file context,
# the global baseline is already in place from a previous boot. LYB never
# rewrites on boot 2+ — skip entirely to avoid races with the APK.
_QGL_TARGET="/data/vendor/gpu/qgl_config.txt"
if [ -f "$_QGL_TARGET" ]; then
  _qgl_ctx=$(ls -Z "$_QGL_TARGET" 2>/dev/null | awk '{print $1}' || echo "")
  case "$_qgl_ctx" in
    *same_process_hal_file*)
      log_only "[OK] QGL boot 2+ fast exit: file exists with correct context ($_qgl_ctx)"
      unset _qgl_ctx _QGL_TARGET _QGL_BASELINE_FLAG
      exit 0
      ;;
  esac
  log_only "[BOOT] QGL file exists but wrong context ($_qgl_ctx) — will re-apply"
fi
unset _qgl_ctx _QGL_TARGET

# ══════════════════════════════════════════════════════════════════════════
# STEP 3b: BOOT 2+ FAST EXIT (ADR-005)
# ══════════════════════════════════════════════════════════════════════════
# If qgl_config.txt already exists with correct same_process_hal_file context,
# the global baseline is already in place from a previous boot. LYB never
# rewrites on boot 2+ — skip entirely to avoid races with the APK.
_QGL_TARGET="/data/vendor/gpu/qgl_config.txt"
if [ -f "$_QGL_TARGET" ]; then
  _qgl_ctx=$(ls -Z "$_QGL_TARGET" 2>/dev/null | awk '{print $1}' || echo "")
  case "$_qgl_ctx" in
    *same_process_hal_file*)
      log_only "[OK] QGL boot 2+ fast exit: file exists with correct context ($_qgl_ctx)"
      unset _qgl_ctx _QGL_TARGET _QGL_BASELINE_FLAG
      exit 0
      ;;
  esac
  log_only "[BOOT] QGL file exists but wrong context ($_qgl_ctx) — will re-apply"
fi
unset _qgl_ctx _QGL_TARGET

# ══════════════════════════════════════════════════════════════════════════
# STEP 4: APPLY QGL (branch on QGL_PERAPP)
# ══════════════════════════════════════════════════════════════════════════

if [ "$QGL_PERAPP" = "y" ]; then
  # ── Per-app mode: apply global profile as baseline ─────────────────────
  # The QGL Trigger APK (AccessibilityService) handles per-app overrides
  # as apps are opened. This boot apply provides the global baseline.
  log_only "[BOOT] Applying QGL global baseline (per-app mode)"
  exec "$MODDIR/apply_qgl.sh" --boot
else
  # ── Static mode: old code retry+verify install from bundled qgl_config.txt
  # No APK. No per-app switching. One config for everything.

  QGL_TARGET="/data/vendor/gpu/qgl_config.txt"
  QGL_OWNER_MARKER="/data/vendor/gpu/.adreno_qgl_owner"

  # Safety check: if qgl_config.txt exists but has no owner marker,
  # it belongs to another manager (e.g. LYB). Respect that and skip.
  if [ -f "$QGL_TARGET" ] && [ ! -f "$QGL_OWNER_MARKER" ]; then
    log_only "[!] QGL static: qgl_config.txt exists but NOT owned by this module — skipping"
    exit 0
  fi

  if [ ! -f "$MODDIR/qgl_config.txt" ]; then
    log_only "[!] QGL static: qgl_config.txt not found in module — skipping"
    exit 0
  fi

  QGL_INSTALL_SUCCESS="false"
  MAX_RETRIES=5
  RETRY_COUNT=0
  QGL_TEMP=""

  while [ $RETRY_COUNT -lt $MAX_RETRIES ] && [ "$QGL_INSTALL_SUCCESS" = "false" ]; do
    sleep 1

    # Verify /data is writable
    if touch /data/.adreno_test 2>/dev/null && rm /data/.adreno_test 2>/dev/null; then
      # Create directory with correct SELinux context FIRST
      if mkdir -p /data/vendor/gpu 2>/dev/null; then
        chcon u:object_r:same_process_hal_file:s0 /data/vendor/gpu 2>/dev/null || \
          chcon u:object_r:vendor_data_file:s0 /data/vendor/gpu 2>/dev/null || true

        QGL_TEMP="/data/vendor/gpu/.qgl_config.txt.tmp.$$"

        # Write to temp file
        if cp -f "$MODDIR/qgl_config.txt" "$QGL_TEMP" 2>/dev/null; then
          if [ -f "$QGL_TEMP" ] && [ -s "$QGL_TEMP" ]; then
            chmod 0644 "$QGL_TEMP" 2>/dev/null
            chown 0:1000 "$QGL_TEMP" 2>/dev/null

            # Atomic rename
            if mv -f "$QGL_TEMP" "$QGL_TARGET" 2>/dev/null; then
              if [ -f "$QGL_TARGET" ] && [ -s "$QGL_TARGET" ]; then
                chcon u:object_r:same_process_hal_file:s0 "$QGL_TARGET" 2>/dev/null || \
                  chcon u:object_r:vendor_data_file:s0 "$QGL_TARGET" 2>/dev/null || true

                EXPECTED_SIZE=$(stat -c%s "$MODDIR/qgl_config.txt" 2>/dev/null || echo 0)
                ACTUAL_SIZE=$(stat -c%s "$QGL_TARGET" 2>/dev/null || echo 0)

                if [ "$EXPECTED_SIZE" -eq "$ACTUAL_SIZE" ] 2>/dev/null && [ "$ACTUAL_SIZE" -gt 0 ] 2>/dev/null; then
                  QGL_INSTALL_SUCCESS="true"
                  touch "$QGL_OWNER_MARKER" 2>/dev/null || true
                  log_only "[OK] QGL static install verified: $ACTUAL_SIZE bytes"
                  break
                else
                  log_only "[!] QGL static size mismatch: expected=$EXPECTED_SIZE actual=$ACTUAL_SIZE"
                fi
              fi
            else
              log_only "[!] QGL static atomic rename failed, retrying..."
              rm -f "$QGL_TEMP" 2>/dev/null || true
            fi
          else
            log_only "[!] QGL static temp file empty or missing"
            rm -f "$QGL_TEMP" 2>/dev/null || true
          fi
        fi
      fi
    fi

    RETRY_COUNT=$((RETRY_COUNT + 1))
    if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
      log_only "QGL static install attempt $RETRY_COUNT failed, retrying in $((RETRY_COUNT * 2))s..."
      sleep $((RETRY_COUNT * 2))
    fi
  done

  rm -f "$QGL_TEMP" 2>/dev/null || true

  if [ "$QGL_INSTALL_SUCCESS" = "false" ]; then
    log_only "[FAIL] QGL static install failed after $MAX_RETRIES attempts"
  fi

  unset QGL_TARGET QGL_OWNER_MARKER QGL_TEMP QGL_INSTALL_SUCCESS MAX_RETRIES RETRY_COUNT EXPECTED_SIZE ACTUAL_SIZE
fi
