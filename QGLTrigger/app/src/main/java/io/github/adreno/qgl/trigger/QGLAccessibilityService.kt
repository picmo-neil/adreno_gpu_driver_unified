package io.github.adreno.qgl.trigger

import android.accessibilityservice.AccessibilityService
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.ComponentName
import android.content.pm.ApplicationInfo
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
private const val CONFIG_PATH_SD = "/sdcard/Adreno_Driver/Config/adreno_config.txt"
private const val CONFIG_PATH_DATA = "/data/local/tmp/adreno_config.txt"
private const val SYSTEM_APPS_CACHE_MS = 30000L

class QGLAccessibilityService : AccessibilityService() {

    private var lastAppPackage: String? = null
    private var lastSwitchTime: Long = 0L
    private var lastAppliedConfig: String? = null
    private var qglSystemAppsEnabled = false
    private var qglSystemAppsCacheTime: Long = 0L

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
        qglSystemAppsEnabled = readQGLSystemApps()
        Log.d(TAG, "QGL Accessibility Service ready — QGL_SYSTEM_APPS=$qglSystemAppsEnabled")
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null) return

        if (event.eventType != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) {
            return
        }

        val packageName = event.packageName?.toString()
        if (packageName.isNullOrEmpty()) return

        if (packageName == applicationContext.packageName) return

        val className = event.className?.toString()
        if (!className.isNullOrEmpty()) {
            try {
                packageManager.getActivityInfo(ComponentName(packageName, className), 0)
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
            val isSystemPkg = isSystemApp(packageName) && !isQGLSystemAppsEnabled()
            handleAppSwitch(packageName, isSystemPkg)
        }
    }

    private fun isSystemApp(packageName: String): Boolean {
        return try {
            val appInfo = packageManager.getApplicationInfo(packageName, 0)
            (appInfo.flags and ApplicationInfo.FLAG_SYSTEM) != 0
        } catch (_: PackageManager.NameNotFoundException) {
            true
        }
    }

    private fun isQGLSystemAppsEnabled(): Boolean {
        val now = System.currentTimeMillis()
        if (now - qglSystemAppsCacheTime < SYSTEM_APPS_CACHE_MS && qglSystemAppsCacheTime > 0) {
            return qglSystemAppsEnabled
        }
        qglSystemAppsEnabled = readQGLSystemApps()
        qglSystemAppsCacheTime = now
        return qglSystemAppsEnabled
    }

    private fun readQGLSystemApps(): Boolean {
        val result = runShellScript("for f in $CONFIG_PATH_SD $CONFIG_PATH_DATA; do [ -f \"\$f\" ] && { grep -q '^QGL_SYSTEM_APPS=y' \"\$f\" && echo y || echo n; break; } 2>/dev/null; done").trim()
        return result == "y"
    }

    private fun handleAppSwitch(packageName: String, isSystemPkg: Boolean) {
        val last = lastAppliedConfig ?: ""
        val sysFlag = if (isSystemPkg) "1" else "0"
        val S = "$"

        val script = """
            _last='$last'
            _sys=$sysFlag
            if [ -f $QGL_DISABLED_MARKER ]; then
                if [ "$S{_last}" = "NO_QGL" ]; then
                    echo "SAME"
                else
                    if rm -f $QGL_TARGET; then
                        echo "REMOVED:DISABLED"
                    elif truncate -s 0 $QGL_TARGET 2>/dev/null; then
                        echo "REMOVED:DISABLED:TRUNCATED"
                    else
                        echo "FAIL:rm_disabled"
                    fi
                fi
            else
                pkg='$packageName'
                _src=""
                _mt=""
                _type=""
                _is_noqgl=0
                for dir in $CONFIG_DIR_SD $CONFIG_DIR_DATA; do
                    f="$S{dir}/no_qgl_packages.txt"
                    if [ -f "$S{f}" ] && grep -qxF "$S{pkg}" "$S{f}" 2>/dev/null; then
                        _is_noqgl=1
                        break
                    fi
                done
                if [ "$S{_is_noqgl}" = "1" ]; then
                    if [ "$S{_last}" = "NO_QGL" ]; then
                        echo "SAME"
                    else
                        if rm -f $QGL_TARGET; then
                            echo "REMOVED:NOQGL"
                        elif truncate -s 0 $QGL_TARGET 2>/dev/null; then
                            echo "REMOVED:NOQGL:TRUNCATED"
                        else
                            echo "FAIL:rm_noqgl"
                        fi
                    fi
                else
                    for dir in $CONFIG_DIR_SD $CONFIG_DIR_DATA; do
                        f="$S{dir}/qgl_config.txt.$S{pkg}"
                        if [ -f "$S{f}" ] && [ -s "$S{f}" ]; then
                            _src="$S{f}"
                            _mt=$S(stat -c '%Y' "$S{f}" 2>/dev/null || echo '0')
                            _type="PERAPP"
                            break
                        fi
                    done
                    if [ -z "$S{_src}" ]; then
                        for dir in $CONFIG_DIR_SD $CONFIG_DIR_DATA; do
                            f="$S{dir}/qgl_config.txt"
                            if [ -f "$S{f}" ] && [ -s "$S{f}" ]; then
                                _src="$S{f}"
                                _mt=$S(stat -c '%Y' "$S{f}" 2>/dev/null || echo '0')
                                _type="DEFAULT"
                                break
                            fi
                        done
                    fi
                    if [ -n "$S{_src}" ]; then
                        if [ "$S{_sys}" = "1" ] && [ "$S{_type}" = "DEFAULT" ]; then
                            if [ "$S{_last}" = "NO_QGL" ]; then
                                echo "SAME"
                            else
                                if rm -f $QGL_TARGET; then
                                    echo "REMOVED:SYS_DEFAULT"
                                elif truncate -s 0 $QGL_TARGET 2>/dev/null; then
                                    echo "REMOVED:SYS_DEFAULT:TRUNCATED"
                                else
                                    echo "FAIL:rm_sys_default"
                                fi
                            fi
                        else
                            _hash="$S{_src}:$S{_mt}"
                            if [ "$S{_hash}" = "$S{_last}" ]; then
                                echo "SAME:$S{_hash}"
                            else
                                _tmp="${QGL_TARGET}.tmp.$S$S"
                                mkdir -p $QGL_DIR 2>/dev/null
                                chcon $SELINUX_CONTEXT $QGL_DIR || echo "DIAG:chcon_dir_failed:$S?"
                                if cp -f "$S{_src}" "$S{_tmp}"; then
                                    if chcon $SELINUX_CONTEXT "$S{_tmp}"; then
                                        if chmod 0644 "$S{_tmp}"; then
                                            if mv -f "$S{_tmp}" $QGL_TARGET; then
                                                touch $QGL_TARGET 2>/dev/null || true
                                                chcon $SELINUX_CONTEXT $QGL_TARGET || echo "DIAG:chcon_target_failed"
                                                chmod 0644 $QGL_TARGET 2>/dev/null || echo "DIAG:chmod_target_failed"
                                                echo "APPLIED:$S{_hash}"
                                            else
                                                rm -f "$S{_tmp}" 2>/dev/null || true
                                                echo "FAIL:mv"
                                            fi
                                        else
                                            rm -f "$S{_tmp}" 2>/dev/null || true
                                            echo "FAIL:chmod_tmp"
                                        fi
                                    else
                                        rm -f "$S{_tmp}" 2>/dev/null || true
                                        echo "FAIL:chcon_tmp"
                                    fi
                                else
                                    rm -f "$S{_tmp}" 2>/dev/null || true
                                    echo "FAIL:cp"
                                fi
                            fi
                        fi
                    else
                        if [ "$S{_last}" != "NO_QGL" ]; then
                            if rm -f $QGL_TARGET; then
                                echo "REMOVED:NO_CONFIG"
                            elif truncate -s 0 $QGL_TARGET 2>/dev/null; then
                                echo "REMOVED:NO_CONFIG:TRUNCATED"
                            else
                                echo "FAIL:rm_no_config"
                            fi
                        else
                            echo "SAME"
                        fi
                    fi
                fi
            fi
        """.trimIndent()

        val output = runShellScript(script).trim()
        Log.d(TAG, "QGL switch for $packageName (sys=$isSystemPkg): $output")

        when {
            output.startsWith("APPLIED:") -> {
                lastAppliedConfig = output.substring(8)
            }
            output.startsWith("REMOVED:") -> {
                lastAppliedConfig = "NO_QGL"
            }
            output.startsWith("SAME") -> {
            }
            output.startsWith("FAIL:") -> {
                Log.w(TAG, "QGL apply failed: $output")
                lastAppliedConfig = null
            }
            else -> {
                Log.w(TAG, "Unexpected QGL output: $output")
                lastAppliedConfig = null
            }
        }
    }

    private fun runShellScript(script: String): String {
        synchronized(shellLock) {
            if (shellStdin == null || shellStdout == null || persistentShell?.isAlive != true) {
                if (!createShellInternal()) return "NONE"
            }
        }

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
                    Thread.sleep(10)
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
                createShellInternal()
            }
            "NONE"
        }
    }

    private fun drainStderr(process: Process) {
        Thread({
            try {
                val reader = BufferedReader(InputStreamReader(process.errorStream))
                val buf = CharArray(1024)
                while (reader.read(buf) != -1) {
                    // drain only — discard
                }
            } catch (_: IOException) {
            }
        }, "QGL-StderrDrain").apply { isDaemon = true }.start()
    }

    private data class VerifiedShell(
        val process: Process,
        val stdin: DataOutputStream,
        val stdout: BufferedReader
    )

    private fun tryCreateShell(command: String): VerifiedShell? {
        return try {
            val p = Runtime.getRuntime().exec(command)
            drainStderr(p)
            val stdin = DataOutputStream(p.outputStream)
            val stdout = BufferedReader(InputStreamReader(p.inputStream))
            stdin.writeBytes("id\n")
            stdin.writeBytes("echo QGL_SHELL_READY\n")
            stdin.flush()
            val deadline = System.currentTimeMillis() + 3000
            val sb = StringBuilder()
            val buf = CharArray(256)
            while (System.currentTimeMillis() < deadline) {
                if (stdout.ready()) {
                    val n = stdout.read(buf)
                    if (n > 0) sb.append(buf, 0, n)
                    if (sb.contains("QGL_SHELL_READY")) {
                        val idLine = sb.toString().lines().firstOrNull { it.contains("uid=") } ?: ""
                        if (idLine.contains("uid=0")) {
                            Log.d(TAG, "Root shell verified via '$command': $idLine")
                            return VerifiedShell(p, stdin, stdout)
                        } else {
                            Log.w(TAG, "Shell '$command' is NOT root: $idLine")
                            p.destroyForcibly()
                            return null
                        }
                    }
                } else {
                    Thread.sleep(10)
                }
            }
            Log.w(TAG, "Shell '$command' verification timed out")
            p.destroyForcibly()
            null
        } catch (e: Exception) {
            Log.w(TAG, "Shell '$command' creation failed: ${e.message}")
            null
        }
    }

    private fun createShellInternal(): Boolean {
        synchronized(shellLock) {
            for (cmd in arrayOf("su", "/system/xbin/su", "/system/bin/su", "/sbin/su")) {
                val vs = tryCreateShell(cmd)
                if (vs != null) {
                    persistentShell = vs.process
                    shellStdin = vs.stdin
                    shellStdout = vs.stdout
                    return true
                }
            }
            Log.e(TAG, "All su paths failed — no root access available. Grant root to QGLTrigger via Magisk/KSU/APatch manager.")
            persistentShell = null
            shellStdin = null
            shellStdout = null
            return false
        }
    }

    private fun getOrCreateShell(): DataOutputStream? {
        synchronized(shellLock) {
            val shell = persistentShell
            if (shell != null && shell.isAlive) {
                return shellStdin
            }
            return if (createShellInternal()) shellStdin else null
        }
    }

    override fun onInterrupt() {
        Log.w(TAG, "AccessibilityService interrupted")
    }

    override fun onDestroy() {
        Log.d(TAG, "AccessibilityService destroyed — closing persistent shell")
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
