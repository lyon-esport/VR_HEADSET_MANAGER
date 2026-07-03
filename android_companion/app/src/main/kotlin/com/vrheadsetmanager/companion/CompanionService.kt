package com.vrheadsetmanager.companion

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.IBinder
import android.os.PowerManager
import android.provider.Settings

class CompanionService : Service() {

    private var httpServer: HttpApiServer? = null
    private var discoveryServer: DiscoveryServer? = null
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        startForeground(NOTIFICATION_ID, buildNotification())

        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "VRHM:CompanionService")
        wakeLock?.acquire()

        httpServer = HttpApiServer(HTTP_PORT, applicationContext)
        httpServer?.start()

        discoveryServer = DiscoveryServer(applicationContext, UDP_PORT)
        discoveryServer?.start()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_ENABLE_ADB -> {
                val enable = intent.getBooleanExtra(EXTRA_ENABLE, true)
                try {
                    Settings.Secure.putInt(contentResolver, "adb_wifi_enabled", if (enable) 1 else 0)
                } catch (_: SecurityException) {}
            }
            ACTION_STOP -> stopSelf()
        }
        return START_STICKY
    }

    override fun onDestroy() {
        httpServer?.stop()
        discoveryServer?.stop()
        if (wakeLock?.isHeld == true) wakeLock?.release()
        super.onDestroy()
    }

    private fun createNotificationChannel() {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "VR Headset Manager Companion", NotificationManager.IMPORTANCE_LOW)
                .apply { description = "Background service for ADB WiFi and HTTP API" }
        )
    }

    private fun buildNotification(): Notification {
        val pi = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        return Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle("VRHM Companion Active")
            .setContentText("HTTP :$HTTP_PORT | UDP discovery :$UDP_PORT")
            .setContentIntent(pi)
            .setOngoing(true)
            .build()
    }

    companion object {
        const val CHANNEL_ID = "vrhm_companion"
        const val NOTIFICATION_ID = 1
        const val HTTP_PORT = 8765
        const val UDP_PORT = 5556
        const val ACTION_ENABLE_ADB = "com.vrheadsetmanager.companion.ENABLE_ADB"
        const val ACTION_STOP = "com.vrheadsetmanager.companion.STOP"
        const val EXTRA_ENABLE = "enable"
    }
}
