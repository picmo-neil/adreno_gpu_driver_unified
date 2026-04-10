package io.github.adreno.qgl.trigger

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.provider.Settings
import android.util.Log

private const val TAG = "QGLTrigger"

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_LOCKED_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED -> {
                Log.d(TAG, "Boot event received: ${intent.action}, starting QGL service")

                try {
                    val keepAliveIntent = Intent(context, ForegroundKeepAliveService::class.java)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        context.startForegroundService(keepAliveIntent)
                    } else {
                        context.startService(keepAliveIntent)
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "Failed to start keep-alive service on boot", e)
                }

                try {
                    val accComp = "io.github.adreno.qgl.trigger/.QGLAccessibilityService"
                    val enabled = Settings.Secure.getString(
                        context.contentResolver,
                        Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
                    ) ?: ""
                    if (!enabled.contains(accComp)) {
                        Log.d(TAG, "Accessibility service not enabled, cannot auto-start")
                    }
                } catch (_: Exception) {
                }
            }
        }
    }
}
