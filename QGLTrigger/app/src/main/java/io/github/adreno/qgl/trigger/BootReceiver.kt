package io.github.adreno.qgl.trigger

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log

private const val TAG = "QGLTrigger"

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_LOCKED_BOOT_COMPLETED -> {
                Log.d(TAG, "Boot event received: ${intent.action}, starting QGL service")
                startKeepAliveService(context)
            }
            Intent.ACTION_MY_PACKAGE_REPLACED -> {
                Log.d(TAG, "Package update detected, restarting QGL service")
                startKeepAliveService(context)
            }
        }
    }

    private fun startKeepAliveService(context: Context) {
        try {
            val keepAliveIntent = Intent(context, ForegroundKeepAliveService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(keepAliveIntent)
            } else {
                context.startService(keepAliveIntent)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start keep-alive service", e)
        }
    }
}
