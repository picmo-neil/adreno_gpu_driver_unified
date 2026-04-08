package io.github.adreno.qgl.trigger

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.util.Log

private const val TAG = "QGLTrigger"
private const val KEEPALIVE_CHANNEL_ID = "qgl_keepalive_channel"
private const val KEEPALIVE_NOTIFICATION_ID = 1002

class ForegroundKeepAliveService : Service() {

    override fun onCreate() {
        super.onCreate()
        Log.d(TAG, "ForegroundKeepAliveService created")
        ensureNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.d(TAG, "ForegroundKeepAliveService onStartCommand")

        val notification = buildNotification()
        try {
            startForeground(KEEPALIVE_NOTIFICATION_ID, notification)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start foreground in keepalive service", e)
        }

        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        Log.w(TAG, "ForegroundKeepAliveService destroyed — requesting restart")
        super.onDestroy()
        val restartIntent = Intent(applicationContext, ForegroundKeepAliveService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            try {
                startForegroundService(restartIntent)
            } catch (e: Exception) {
                Log.e(TAG, "Failed to restart keepalive service", e)
            }
        } else {
            try {
                startService(restartIntent)
            } catch (e: Exception) {
                Log.e(TAG, "Failed to restart keepalive service", e)
            }
        }
    }

    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                KEEPALIVE_CHANNEL_ID,
                "QGL Keepalive",
                NotificationManager.IMPORTANCE_MIN
            ).apply {
                setShowBadge(false)
                setSound(null, null)
            }
            val nm = getSystemService(NotificationManager::class.java)
            nm.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(): Notification {
        return Notification.Builder(this, KEEPALIVE_CHANNEL_ID)
            .setContentTitle("QGL Service Running")
            .setContentText("GPU layer configuration active")
            .setSmallIcon(android.R.drawable.ic_menu_compass)
            .setOngoing(true)
            .setPriority(Notification.PRIORITY_MIN)
            .build()
    }
}
