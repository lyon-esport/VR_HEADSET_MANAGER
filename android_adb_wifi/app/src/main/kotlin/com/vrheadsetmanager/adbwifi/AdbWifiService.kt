package com.vrheadsetmanager.adbwifi

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder
import android.util.Log

/**
 * Short-lived foreground service used at headset startup: waits for Wi-Fi, enables
 * ADB over Wi-Fi (with a few retries), shows the result and stops.
 */
class AdbWifiService : Service() {

    @Volatile private var running = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        createChannel()
        startForeground(NOTIFICATION_ID_PROGRESS, buildNotification(getString(R.string.notif_enabling), ongoing = true),
            ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        if (!running) {
            running = true
            Thread(::work, "AdbWifiBoot").start()
        }
        return START_NOT_STICKY
    }

    private fun work() {
        val port = Prefs(this).port
        var result = AdbWifiController.Result(false, "The headset did not connect to Wi-Fi.")
        try {
            // Wi-Fi usually comes up a little after BOOT_COMPLETED
            val wifiDeadline = System.currentTimeMillis() + WIFI_WAIT_MS
            while (NetUtils.wifiIpv4() == null && System.currentTimeMillis() < wifiDeadline) Thread.sleep(2000)

            if (NetUtils.wifiIpv4() != null) {
                for (attempt in 1..ATTEMPTS) {
                    result = AdbWifiController.enable(this, port) { Log.i(TAG, it) }
                    if (result.success) break
                    Log.w(TAG, "Attempt $attempt failed: ${result.message}")
                    if (attempt < ATTEMPTS) Thread.sleep(RETRY_DELAY_MS)
                }
            }
        } catch (e: Exception) {
            result = AdbWifiController.Result(false, e.message ?: e.toString())
        }

        val ip = NetUtils.wifiIpv4()?.hostAddress
        val text = if (result.success && ip != null) getString(R.string.notif_enabled, ip, port) else result.message
        getSystemService(NotificationManager::class.java)
            .notify(NOTIFICATION_ID_RESULT, buildNotification(text, ongoing = false))
        running = false
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun createChannel() {
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(CHANNEL_ID, getString(R.string.notif_channel), NotificationManager.IMPORTANCE_LOW)
        )
    }

    private fun buildNotification(text: String, ongoing: Boolean): Notification {
        val pi = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        return Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(getString(R.string.app_name))
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setContentIntent(pi)
            .setOngoing(ongoing)
            .setAutoCancel(!ongoing)
            .build()
    }

    companion object {
        private const val TAG = "VRHM-AdbWifi"
        private const val CHANNEL_ID = "adb_wifi"
        private const val NOTIFICATION_ID_PROGRESS = 1
        private const val NOTIFICATION_ID_RESULT = 2
        private const val WIFI_WAIT_MS = 120_000L
        private const val ATTEMPTS = 3
        private const val RETRY_DELAY_MS = 10_000L

        fun start(context: Context) {
            context.startForegroundService(Intent(context, AdbWifiService::class.java))
        }
    }
}
