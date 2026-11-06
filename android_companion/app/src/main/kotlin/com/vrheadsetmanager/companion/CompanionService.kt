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

    @Volatile private var httpServer: HttpApiServer? = null
    @Volatile private var stopping = false
    private var discoveryServer: DiscoveryServer? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var watchdog: AdbWatchdog? = null
    private var telemetry: TelemetryReporter? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        startForeground(NOTIFICATION_ID, buildNotification())

        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "VRHM:CompanionService")
        wakeLock?.acquire()

        startHttpWithRetry()

        discoveryServer = DiscoveryServer(applicationContext, UDP_PORT)
        discoveryServer?.start()

        // The approver (accessibility service) can be left off by an app update or a reset; put it
        // back before the watchdog turns wireless debugging on, so the prompt that follows is handled.
        CmdReceiver.ensureApproverEnabled(applicationContext)

        watchdog = AdbWatchdog(applicationContext)
        watchdog?.start()

        // Telemetry push (ADR-0042): starts only when a report_url has been provisioned.
        telemetry = TelemetryReporter(applicationContext)
        TelemetryReporter.active = telemetry
        telemetry?.start()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_ENABLE_ADB -> {
                val enable = intent.getBooleanExtra(EXTRA_ENABLE, true)
                if (!AdbBootManager.isPico()) try {
                    Settings.Global.putInt(contentResolver, "adb_wifi_enabled", if (enable) 1 else 0)
                } catch (_: SecurityException) {}
            }
            ACTION_STOP -> stopSelf()
        }
        return START_STICKY
    }

    /** Starts the HTTP API; a failure (port in use) is logged and retried 5 s / 30 s / 60 s, never crashes the service. */
    private fun startHttpWithRetry() {
        stopping = false
        Thread({
            val delays = longArrayOf(5_000, 30_000, 60_000)
            var i = 0
            while (!stopping) {
                try {
                    val s = HttpApiServer(HTTP_PORT, applicationContext)
                    s.start()
                    httpServer = s
                    AdbBootManager.reportError(null)
                    return@Thread
                } catch (e: Throwable) {
                    val msg = "http server start failed: ${e.message}"
                    android.util.Log.w("VrhmService", msg)
                    AdbBootManager.reportError(msg)
                }
                try { Thread.sleep(delays[minOf(i, delays.size - 1)]) } catch (_: InterruptedException) { return@Thread }
                i++
            }
        }, "VRHM-HttpStart").also { it.isDaemon = true; it.start() }
    }

    override fun onDestroy() {
        stopping = true
        telemetry?.stop()
        TelemetryReporter.active = null
        watchdog?.stop()
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
