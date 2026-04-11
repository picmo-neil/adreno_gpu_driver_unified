package io.github.adreno.qgl.trigger

import android.accessibilityservice.AccessibilityService
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import java.io.BufferedReader
import java.io.DataOutputStream
import java.io.IOException
import java.io.InputStreamReader
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

private const val TAG = "QGLTrigger"
private const val DEBOUNCE_MS = 2000L
private const val NOTIFICATION_CHANNEL_ID = "qgl_trigger_channel"
private const val NOTIFICATION_ID = 1001
private const val QGL_TARGET = "/data/vendor/gpu/qgl_config.txt"
private const val QGL_DIR = "/data/vendor/gpu"
private const val QGL_DISABLED_MARKER = "/data/local/tmp/.qgl_disabled"
private const val SELINUX_CONTEXT = "u:object_r:same_process_hal_file:s0"
private const val CONFIG_DIR_SD = "/sdcard/Adreno_Driver/Config"
private const val CONFIG_DIR_DATA = "/data/local/tmp"

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
    private var lastAppliedConfig: String? = null

    @Volatile private var persistentShell: Process? = null
    @Volatile private var shellStdin: DataOutputStream? = null
    @Volatile private var shellStdout: BufferedReader? = null
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

        val componentName = event.componentName
        if (componentName != null) {
            try {
                packageManager.getActivityInfo(componentName, 0)
            } catch (_: PackageManager.NameNotFoundException) {
                return
            }
        }

        val now = System.currentTimeMillis()
        if (packageName == lastAppPackage && (now - lastSwitchTime) < DEBOUNCE_MS) {
            return
        }

        Log.d(TAG, "App switch detected: $packageName")
        lastAppPackage = packageName
        lastSwitchTime = now

        scriptExecutor.execute {
            handleAppSwitch(packageName)
        }
    }

    private fun queryQGLState(packageName: String): Triple<String, String?, String> {
        val script = """
            if [ -f $QGL_DISABLED_MARKER ]; then
                echo "DISABLED"
            else
                pkg='$packageName'
                _r="NONE"
                _m="0"
                for dir in $CONFIG_DIR_DATA $CONFIG_DIR_SD; do
                    f="${'$'}dir/qgl_config.txt.${'$'}pkg"
                    [ -f "${'$'}f" ] || continue
                    if [ -s "${'$'}f" ]; then _r="PATH:${'$'}f"; _m=${'$'}(stat -c '%Y' "${'$'}f" 2>/dev/null || echo '0'); else _r="NOQGL"; fi
                    break
                done
                if [ "${'$'}_r" = "NONE" ]; then
                    for dir in $CONFIG_DIR_DATA $CONFIG_DIR_SD; do
                        f="${'$'}dir/qgl_config.txt"
                        [ -f "${'$'}f" ] && [ -s "${'$'}f" ] && { _r="PATH:${'$'}f"; _m=${'$'}(stat -c '%Y' "${'$'}f" 2>/dev/null || echo '0'); break; }
                    done
                fi
                echo "${'$'}_r"
                echo "${'$'}_m"
            fi
        """.trimIndent()

        val output = runShellScript(script)
        val lines = output.lines().filter { it.isNotBlank() }

        return when {
            lines.isEmpty() -> Triple("NONE", null, "0")
            lines[0] == "DISABLED" -> Triple("DISABLED", null, "0")
            lines[0] == "NOQGL" -> Triple("NOQGL", null, "0")
            lines[0].startsWith("PATH:") -> {
                val path = lines[0].substring(5)
                val mtime = lines.getOrElse(1) { "0" }
                Triple("PATH", path, mtime)
            }
            else -> Triple("NONE", null, "0")
        }
    }

    private fun runShellScript(script: String): String {
        val stdin: DataOutputStream
        val stdout: BufferedReader
        synchronized(shellLock) {
            stdin = shellStdin ?: return "NONE"
            stdout = shellStdout ?: return "NONE"
        }

        return try {
            val marker = "QGL_RESULT_${android.os.Process.myPid()}_${System.nanoTime()}"
            stdin.writeBytes("{ $script; } 2>/dev/null\n")
            stdin.writeBytes("echo $marker\n")
            stdin.flush()

            val buf = CharArray(4096)
            val sb = StringBuilder()
            val deadline = System.currentTimeMillis() + 5000
            while (System.currentTimeMillis() < deadline) {
                if (stdout.ready()) {
                    val n = stdout.read(buf)
                    if (n > 0) sb.append(buf, 0, n)
                    if (sb.contains(marker)) {
                        val output = sb.toString()
                        val markerIdx = output.lastIndexOf(marker)
                        return output.substring(0, markerIdx).trimEnd()
                    }
                } else {
                    Thread.sleep(50)
                }
            }
            Log.w(TAG, "runShellScript timed out")
            "NONE"
        } catch (e: IOException) {
            Log.w(TAG, "runShellScript failed", e)
            synchronized(shellLock) {
                persistentShell?.destroyForcibly()
                persistentShell = null
                shellStdin = null
                shellStdout = null
            }
            "NONE"
        }
    }

    private fun handleAppSwitch(packageName: String) {
        val (state, srcPath, mtime) = queryQGLState(packageName)

        when (state) {
            "DISABLED" -> {
                if (lastAppliedConfig == "NO_QGL") {
                    Log.d(TAG, "QGL disabled marker present, already in no-QGL state, skipping")
                    return
                }
                Log.d(TAG, "QGL disabled marker present — removing QGL config")
                executeQGLRemove()
                lastAppliedConfig = "NO_QGL"
            }
            "NOQGL" -> {
                if (lastAppliedConfig == "NO_QGL") {
                    Log.d(TAG, "Already in no-QGL state for $packageName, skipping")
                    return
                }
                Log.d(TAG, "Removing QGL config for no-QGL app: $packageName")
                executeQGLRemove()
                lastAppliedConfig = "NO_QGL"
            }
            "PATH" -> {
                val contentHash = "$srcPath:$mtime"
                if (contentHash == lastAppliedConfig) {
                    Log.d(TAG, "Same config already applied for $packageName, skipping")
                    return
                }
                Log.d(TAG, "Applying QGL config for $packageName from $srcPath")
                executeQGLCopy(srcPath)
                lastAppliedConfig = contentHash
            }
            else -> {
                Log.d(TAG, "No QGL config found for $packageName, skipping")
            }
        }
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
                shellStdout = BufferedReader(InputStreamReader(p.inputStream))
                Log.d(TAG, "Persistent root shell created")
                stdin
            } catch (e: Exception) {
                Log.e(TAG, "Failed to create persistent root shell", e)
                persistentShell = null
                shellStdin = null
                shellStdout = null
                null
            }
        }
    }

    private fun writeToShell(cmds: List<String>): Boolean {
        val stdin: DataOutputStream
        val stdout: BufferedReader
        synchronized(shellLock) {
            stdin = shellStdin ?: return false
            stdout = shellStdout ?: return false
        }

        return try {
            val marker = "QGL_DONE_${android.os.Process.myPid()}_${System.nanoTime()}"
            for (cmd in cmds) {
                stdin.writeBytes("$cmd\n")
            }
            stdin.writeBytes("echo $marker\n")
            stdin.flush()

            val buf = CharArray(4096)
            val sb = StringBuilder()
            val deadline = System.currentTimeMillis() + 5000
            while (System.currentTimeMillis() < deadline) {
                if (stdout.ready()) {
                    val n = stdout.read(buf)
                    if (n > 0) sb.append(buf, 0, n)
                    if (sb.contains(marker)) {
                        val output = sb.toString()
                        if (output.contains("QGL_WRITE_FAIL")) {
                            Log.w(TAG, "Shell command reported failure")
                            return false
                        }
                        return true
                    }
                } else {
                    Thread.sleep(50)
                }
            }
            Log.w(TAG, "Shell command timed out waiting for marker")
            true
        } catch (e: IOException) {
            Log.w(TAG, "Shell write failed, will respawn on next switch", e)
            synchronized(shellLock) {
                persistentShell?.destroyForcibly()
                persistentShell = null
                shellStdin = null
                shellStdout = null
            }
            false
        }
    }

    private fun executeQGLCopy(srcPath: String) {
        getOrCreateShell() ?: run {
            Log.e(TAG, "No root shell available")
            return
        }

        val tmpFile = "${QGL_TARGET}.tmp.${android.os.Process.myPid()}"
        val cmds = mutableListOf<String>()

        cmds.add("mkdir -p $QGL_DIR 2>/dev/null")
        cmds.add("chcon $SELINUX_CONTEXT $QGL_DIR 2>/dev/null || true")
        cmds.add("cp -f '$srcPath' $tmpFile 2>/dev/null || echo QGL_WRITE_FAIL")
        cmds.add("chcon $SELINUX_CONTEXT $tmpFile 2>/dev/null || true")
        cmds.add("chmod 0644 $tmpFile 2>/dev/null || true")
        cmds.add("if mv -f $tmpFile $QGL_TARGET 2>/dev/null; then")
        cmds.add("  touch $QGL_TARGET 2>/dev/null || true")
        cmds.add("  chcon $SELINUX_CONTEXT $QGL_TARGET 2>/dev/null || true")
        cmds.add("  chmod 0644 $QGL_TARGET 2>/dev/null || true")
        cmds.add("else")
        cmds.add("  rm -f $tmpFile 2>/dev/null || true")
        cmds.add("  echo QGL_WRITE_FAIL")
        cmds.add("fi")

        if (writeToShell(cmds)) {
            Log.d(TAG, "QGL config applied from $srcPath")
        } else {
            Log.w(TAG, "Failed to write QGL config from $srcPath, shell will respawn")
            lastAppliedConfig = null
        }
    }

    private fun executeQGLRemove() {
        getOrCreateShell() ?: run {
            Log.e(TAG, "No root shell available")
            return
        }

        val cmds = mutableListOf<String>()
        cmds.add("rm -f $QGL_TARGET 2>/dev/null || true")

        if (writeToShell(cmds)) {
            Log.d(TAG, "QGL config removed (no-QGL mode)")
        } else {
            Log.w(TAG, "Failed to remove QGL config, shell will respawn")
            lastAppliedConfig = null
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
            shellStdout = null
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
