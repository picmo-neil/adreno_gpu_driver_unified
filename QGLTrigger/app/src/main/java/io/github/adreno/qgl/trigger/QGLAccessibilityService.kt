package io.github.adreno.qgl.trigger

import android.accessibilityservice.AccessibilityService
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import java.io.DataOutputStream
import java.io.IOException
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

private const val TAG = "QGLTrigger"
private const val DEBOUNCE_MS = 2000L
private const val NOTIFICATION_CHANNEL_ID = "qgl_trigger_channel"
private const val NOTIFICATION_ID = 1001
private const val QGL_TARGET = "/data/vendor/gpu/qgl_config.txt"
private const val QGL_DIR = "/data/vendor/gpu"
private const val SELINUX_CONTEXT = "u:object_r:same_process_hal_file:s0"

private val SYSTEM_UI_PACKAGES = setOf(
    "com.android.systemui",
    "com.android.launcher",
    "com.android.launcher2",
    "com.android.launcher3",
    "com.miui.home",
    "com.sec.android.app.launcher",
    "com.oppo.launcher",
    "com.vivo.launcher",
    "com.huawei.android.launcher",
    "com.google.android.googlequicksearchbox",
    "com.google.android.apps.nexuslauncher",
    "android",
    "com.android.settings"
)

class QGLAccessibilityService : AccessibilityService() {

    private var lastAppPackage: String? = null
    private var lastSwitchTime: Long = 0L
    private var currentForegroundPackage: String? = null
    private val scriptExecutor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "QGL-ScriptExecutor").apply { isDaemon = true }
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        Log.d(TAG, "AccessibilityService connected")
        startForegroundNotification()
        Log.d(TAG, "QGL Accessibility Service started and ready to monitor app switches")
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null) return

        if (event.eventType != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) {
            return
        }

        val packageName = event.packageName?.toString()
        if (packageName.isNullOrEmpty()) return

        if (packageName == applicationContext.packageName) return

        if (SYSTEM_UI_PACKAGES.any { pkg ->
                packageName == pkg || packageName.startsWith("$pkg.")
            }) {
            return
        }

        val now = System.currentTimeMillis()
        if (packageName == lastAppPackage && (now - lastSwitchTime) < DEBOUNCE_MS) {
            return
        }

        if (packageName == currentForegroundPackage) {
            return
        }

        Log.d(TAG, "App switch detected: $packageName")
        lastAppPackage = packageName
        lastSwitchTime = now
        currentForegroundPackage = packageName

        handleAppSwitch(packageName)
    }

    private fun handleAppSwitch(packageName: String) {
        val keys = ProfileManager.getKeysForPackage(packageName)
        if (keys.isNullOrEmpty()) {
            Log.d(TAG, "No QGL profile configured for $packageName, skipping")
            return
        }

        Log.d(TAG, "Applying QGL config for $packageName with ${keys.size} keys")
        executeQGLScript(packageName, keys)
    }

    private fun executeQGLScript(packageName: String, keys: List<String>) {
        scriptExecutor.execute {
            var process: Process? = null
            var os: DataOutputStream? = null
            try {
                process = Runtime.getRuntime().exec("su")
                os = DataOutputStream(process.outputStream)

                val magicHeader = "0x0=0x8675309"

                // Atomic write: printf content to temp file, then mv to target.
                // printf > tmp && mv tmp target is atomic on ext4/f2fs (rename syscall).
                // The heredoc approach (cat > tmp <<'EOF') is NOT atomic — cat truncates
                // the file first, then writes. If the su process is killed between
                // truncate and write completion (OOM killer, timeout), the temp file
                // is left empty/partial and mv moves corrupted data to the target.
                //
                // Keys are written via a heredoc to the temp file, but the heredoc
                // feeds into printf which writes to the temp file in a single shell
                // operation. The subsequent mv is the atomic boundary.
                os.writeBytes("mkdir -p $QGL_DIR 2>/dev/null\n")
                os.writeBytes("{\n")
                os.writeBytes("printf '%s\\n' '$magicHeader'\n")
                for (key in keys) {
                    val escaped = key.replace("'", "'\\''")
                    os.writeBytes("printf '%s\\n' '$escaped'\n")
                }
                os.writeBytes("} > ${QGL_TARGET}.tmp 2>/dev/null && ")
                os.writeBytes("mv -f ${QGL_TARGET}.tmp $QGL_TARGET 2>/dev/null\n")
                os.writeBytes("chcon $SELINUX_CONTEXT $QGL_DIR 2>/dev/null || true\n")
                os.writeBytes("chcon $SELINUX_CONTEXT $QGL_TARGET 2>/dev/null || true\n")
                os.writeBytes("exit\n")
                os.flush()
                // Do NOT close os before waitFor — let the shell exit naturally
                // after reading "exit". Closing stdin prematurely can cause SIGPIPE
                // if the shell is mid-read from its input stream.

                val finished = process.waitFor(5, TimeUnit.SECONDS)
                if (!finished) {
                    process.destroyForcibly()
                    process.waitFor(2, TimeUnit.SECONDS)
                    Log.w(TAG, "su process timed out and was force-destroyed for $packageName")
                }

                val exitCode = process.exitValue()
                if (exitCode != 0) {
                    Log.e(TAG, "su process exited with code $exitCode for $packageName")
                } else {
                    Log.d(TAG, "QGL config written directly for $packageName (${keys.size} keys)")
                }
            } catch (e: IOException) {
                Log.e(TAG, "Failed to execute su for $packageName", e)
            } catch (e: SecurityException) {
                Log.e(TAG, "Root access denied for $packageName", e)
            } finally {
                try {
                    os?.close()
                } catch (_: IOException) {
                }
                try {
                    process?.destroy()
                } catch (_: Exception) {
                }
            }
        }
    }

    override fun onInterrupt() {
        Log.w(TAG, "AccessibilityService interrupted")
    }

    override fun onDestroy() {
        Log.w(TAG, "AccessibilityService destroyed — Android will restart it")
        scriptExecutor.shutdown()
        try {
            if (!scriptExecutor.awaitTermination(3, TimeUnit.SECONDS)) {
                scriptExecutor.shutdownNow()
            }
        } catch (_: InterruptedException) {
            scriptExecutor.shutdownNow()
        }
        super.onDestroy()
    }

    private fun startForegroundNotification() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                NOTIFICATION_CHANNEL_ID,
                "QGL Trigger Service",
                NotificationManager.IMPORTANCE_MIN
            ).apply {
                setShowBadge(false)
                setSound(null, null)
            }
            val nm = getSystemService(NotificationManager::class.java)
            nm.createNotificationChannel(channel)
        }

        val notification = Notification.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setContentTitle("QGL Trigger Active")
            .setContentText("Monitoring app switches for GPU config")
            .setSmallIcon(android.R.drawable.ic_menu_compass)
            .setOngoing(true)
            .setPriority(Notification.PRIORITY_MIN)
            .build()

        try {
            startForeground(NOTIFICATION_ID, notification)
            Log.d(TAG, "Foreground notification started")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start foreground service", e)
        }
    }
}
