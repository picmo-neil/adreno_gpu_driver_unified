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

private const val TAG = "QGLTrigger"
private const val APPLY_SCRIPT_PATH = "/data/adb/modules/adreno_gpu_driver_unified/apply_qgl.sh"
private const val DEBOUNCE_MS = 2000L
private const val NOTIFICATION_CHANNEL_ID = "qgl_trigger_channel"
private const val NOTIFICATION_ID = 1001

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

        if (SYSTEM_UI_PACKAGES.any { packageName.startsWith(it) }) {
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
        Thread {
            var process: Process? = null
            try {
                process = Runtime.getRuntime().exec("su")
                val os = DataOutputStream(process.outputStream)

                os.writeBytes("export QGL_KEYS=\"${keys.joinToString(",")}\"\n")
                os.writeBytes("export QGL_PACKAGE=\"$packageName\"\n")
                os.writeBytes("$APPLY_SCRIPT_PATH \"$packageName\" &\n")
                os.writeBytes("exit\n")
                os.flush()

                Log.d(TAG, "QGL script dispatched for $packageName (fire-and-forget)")
            } catch (e: IOException) {
                Log.e(TAG, "Failed to execute su for $packageName", e)
            } catch (e: SecurityException) {
                Log.e(TAG, "Root access denied for $packageName", e)
            } finally {
                try {
                    process?.outputStream?.close()
                } catch (_: IOException) {
                }
                process?.destroy()
            }
        }.start()
    }

    override fun onInterrupt() {
        Log.w(TAG, "AccessibilityService interrupted")
    }

    override fun onDestroy() {
        Log.w(TAG, "AccessibilityService destroyed — Android will restart it")
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
