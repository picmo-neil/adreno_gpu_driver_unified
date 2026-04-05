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
# TIMING: Wait for boot_completed + launcher PID + 3s safety → apply global.
#   The APK then overrides with per-app configs as apps are opened.

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
# STEP 2: WAIT FOR LAUNCHER PID
# ══════════════════════════════════════════════════════════════════════════

# Common launcher packages across OEM ROMs
_LAUNCHER_PKGS="com.android.launcher3 com.google.android.apps.nexuslauncher com.sec.android.app.launcher com.miui.home com.oppo.launcher com.vivo.launcher com.huawei.android.launcher com.lge.launcher3 com.htc.launcher com.oneplus.launcher com.samsung.android.app.homelauncher"

_lp=0
while [ $_lp -lt 60 ]; do
  for _pkg in $_LAUNCHER_PKGS; do
    if pidof "$_pkg" >/dev/null 2>&1; then
      _lp=999
      break 2
    fi
  done
  sleep 1
  _lp=$((_lp + 1))
done
unset _lp _pkg _LAUNCHER_PKGS

# ══════════════════════════════════════════════════════════════════════════
# STEP 3: SAFETY MARGIN (Vulkan pipeline settle)
# ══════════════════════════════════════════════════════════════════════════
sleep 3

# ══════════════════════════════════════════════════════════════════════════
# STEP 4: APPLY QGL (branch on QGL_PERAPP)
# ══════════════════════════════════════════════════════════════════════════

if [ "$QGL_PERAPP" = "y" ]; then
  # ── Per-app mode: apply global profile as baseline ─────────────────────
  # The QGL Trigger APK (AccessibilityService) handles per-app overrides
  # as apps are opened. This boot apply provides the global baseline.
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
