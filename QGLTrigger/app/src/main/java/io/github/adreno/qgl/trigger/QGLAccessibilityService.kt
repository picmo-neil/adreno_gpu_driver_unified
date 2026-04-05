package io.github.adreno.qgl.trigger

import android.accessibilityservice.AccessibilityService
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
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

    @Volatile private var persistentShell: Process? = null
    @Volatile private var shellStdin: DataOutputStream? = null
    private val shellLock = Any()

    private val scriptExecutor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "QGL-ScriptExecutor").apply { isDaemon = true }
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        Log.d(TAG, "AccessibilityService connected")
        startForegroundNotification()
        getOrCreateShell()
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

        Log.d(TAG, "App switch detected: $packageName")
        lastAppPackage = packageName
        lastSwitchTime = now

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

    private fun getOrCreateShell(): DataOutputStream? {
        synchronized(shellLock) {
            val shell = persistentShell
            if (shell != null && shell.isAlive) {
                return shellStdin
            }
            return try {
                val p = Runtime.getRuntime().exec("su")
                persistentShell = p
                val stdin = DataOutputStream(p.outputStream)
                shellStdin = stdin
                Log.d(TAG, "Persistent root shell created")
                stdin
            } catch (e: Exception) {
                Log.e(TAG, "Failed to create persistent root shell", e)
                persistentShell = null
                shellStdin = null
                null
            }
        }
    }

    private fun writeToShell(stdin: DataOutputStream, cmds: List<String>): Boolean {
        return try {
            for (cmd in cmds) {
                stdin.writeBytes("$cmd\n")
            }
            stdin.flush()
            true
        } catch (e: IOException) {
            Log.w(TAG, "Shell write failed, will respawn on next switch", e)
            synchronized(shellLock) {
                persistentShell?.destroyForcibly()
                persistentShell = null
                shellStdin = null
            }
            false
        }
    }

    private fun executeQGLScript(packageName: String, keys: List<String>) {
        scriptExecutor.execute {
            val stdin = getOrCreateShell() ?: run {
                Log.e(TAG, "No root shell available for $packageName")
                return@execute
            }

            val magicHeader = "0x0=0x8675309"
            val cmds = mutableListOf<String>()

            cmds.add("mkdir -p $QGL_DIR 2>/dev/null")
            cmds.add("chcon $SELINUX_CONTEXT $QGL_DIR 2>/dev/null || true")

            val tmpFile = "${QGL_TARGET}.tmp"
            cmds.add("{")
            cmds.add("printf '%s\\n' '$magicHeader'")
            for (key in keys) {
                val escaped = key.replace("'", "'\\''")
                cmds.add("printf '%s\\n' '$escaped'")
            }
            cmds.add("} > $tmpFile 2>/dev/null && mv -f $tmpFile $QGL_TARGET 2>/dev/null")
            cmds.add("chcon $SELINUX_CONTEXT $QGL_TARGET 2>/dev/null || true")

            if (writeToShell(stdin, cmds)) {
                Log.d(TAG, "QGL config queued for $packageName (${keys.size} keys)")
            } else {
                Log.w(TAG, "Failed to write QGL config for $packageName, shell will respawn")
            }
        }
    }

    override fun onInterrupt() {
        Log.w(TAG, "AccessibilityService interrupted")
    }

    override fun onDestroy() {
        Log.w(TAG, "AccessibilityService destroyed — closing persistent shell")
        synchronized(shellLock) {
            try {
                shellStdin?.writeBytes("exit\n")
                shellStdin?.flush()
            } catch (_: IOException) {
            }
            persistentShell?.destroyForcibly()
            persistentShell = null
            shellStdin = null
        }
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
