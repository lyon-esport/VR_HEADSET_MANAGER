package com.vrheadsetmanager.companion

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings

class CompanionService : Service() {

    @Volatile private var httpServer: HttpApiServer? = null
    @Volatile private var stopping = false
    private var discoveryServer: DiscoveryServer? = null
    private var watchdog: AdbWatchdog? = null
    private var telemetry: TelemetryReporter? = null
    @Volatile private var httpStarting = false
    private val supHandler = Handler(Looper.getMainLooper())

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        startForeground(NOTIFICATION_ID, buildNotification())

        // No permanent partial wake lock any more: the keep-awake switch (default ON) decides.
        KeepAwake.onServiceStart(applicationContext)

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

        registerComponents()
        supHandler.postDelayed(superviseTick, SUP_FIRST_MS)
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
        httpStarting = true
        Thread({
        try {
            val delays = longArrayOf(5_000, 30_000, 60_000)
            var i = 0
            while (!stopping) {
                try {
                    val s = HttpApiServer(HTTP_PORT, applicationContext)
                    s.start()
                    httpServer = s
                    AdbBootManager.reportError(null)
                    Comp.http.lastError = null
                    return@Thread
                } catch (e: Throwable) {
                    val msg = "http server start failed: ${e.message}"
                    android.util.Log.w("VrhmService", msg)
                    AdbBootManager.reportError(msg)
                    Comp.http.lastError = msg
                }
                try { Thread.sleep(delays[minOf(i, delays.size - 1)]) } catch (_: InterruptedException) { return@Thread }
                i++
            }
        } finally { httpStarting = false }
        }, "VRHM-HttpStart").also { it.isDaemon = true; it.start() }
    }

    // ---- Supervision (T2.1-lite): a 30 s tick on the main looper, no extra thread. ----

    private val superviseTick = object : Runnable {
        override fun run() {
            try { supervise() } catch (e: Throwable) { android.util.Log.w("VrhmService", "supervise: ${e.message}") }
            supHandler.postDelayed(this, SUP_PERIOD_MS)
        }
    }

    private fun registerComponents() {
        Comp.http.probe = { httpServer?.isAlive == true }
        Comp.discovery.probe = { threadAlive("VRHM-Discovery") }
        // The reporter owns a HandlerThread only while a valid report_url is provisioned.
        Comp.reporter.probe = { !reporterExpected() || threadAlive("vrhm-telemetry") }
        Comp.watchdog.probe = {
            val t = watchdog?.lastPeriodicAt ?: 0L
            t != 0L && SystemClock.elapsedRealtime() - t < WATCHDOG_STALE_MS
        }
    }

    private fun clearComponents() {
        for (c in Comp.all) c.probe = { false }
    }

    private fun reporterExpected(): Boolean {
        val p = SelfAdb.dpCtx(applicationContext).getSharedPreferences(BootReceiver.PREFS_NAME, Context.MODE_PRIVATE)
        return TelemetryReporter.isValidReportUrl((p.getString(TelemetryReporter.PREF_REPORT_URL, "") ?: "").trim())
    }

    private fun threadAlive(name: String): Boolean =
        try { Thread.getAllStackTraces().keys.any { it.isAlive && it.name == name } } catch (_: Throwable) { true }

    private fun supervise() {
        if (stopping) return
        val now = SystemClock.elapsedRealtime()
        for (c in Comp.all) {
            if (c.probe()) { c.failures = 0; continue }
            if (c === Comp.http && httpStarting) continue   // its own retry thread is working
            if (now < c.nextAt) continue
            val delay = minOf(SUP_BACKOFF_MIN_MS shl minOf(c.failures, 6), SUP_BACKOFF_MAX_MS)
            c.nextAt = now + delay
            c.failures++
            c.restarts++
            try {
                when (c) {
                    Comp.http -> { try { httpServer?.stop() } catch (_: Throwable) {}; httpServer = null; startHttpWithRetry() }
                    Comp.discovery -> {
                        try { discoveryServer?.stop() } catch (_: Throwable) {}
                        discoveryServer = DiscoveryServer(applicationContext, UDP_PORT).also { it.start() }
                    }
                    Comp.reporter -> {
                        try { telemetry?.stop() } catch (_: Throwable) {}
                        telemetry = TelemetryReporter(applicationContext).also { TelemetryReporter.active = it; it.start() }
                    }
                    Comp.watchdog -> {
                        try { watchdog?.stop() } catch (_: Throwable) {}
                        watchdog = AdbWatchdog(applicationContext).also { it.start() }
                    }
                }
                c.lastError = "not alive, restarted (next retry in ${delay / 1000}s if still down)"
            } catch (e: Throwable) {
                c.lastError = "restart failed: ${e.message}"
            }
            android.util.Log.w("VrhmService", "${c.name}: ${c.lastError}")
        }
    }

    class Comp(val name: String) {
        @Volatile var probe: () -> Boolean = { false }
        @Volatile var lastError: String? = null
        @Volatile var restarts = 0
        @Volatile var failures = 0
        @Volatile var nextAt = 0L
        fun up(): Boolean = try { probe() } catch (_: Throwable) { false }

        companion object {
            val http = Comp("http")
            val discovery = Comp("discovery")
            val reporter = Comp("reporter")
            val watchdog = Comp("watchdog")
            val all = listOf(http, discovery, reporter, watchdog)
        }
    }

    override fun onDestroy() {
        stopping = true
        supHandler.removeCallbacksAndMessages(null)
        clearComponents()
        telemetry?.stop()
        TelemetryReporter.active = null
        watchdog?.stop()
        httpServer?.stop()
        discoveryServer?.stop()
        KeepAwake.release()
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
        const val SUP_PERIOD_MS = 30_000L
        const val SUP_FIRST_MS = 45_000L
        const val SUP_BACKOFF_MIN_MS = 30_000L
        const val SUP_BACKOFF_MAX_MS = 600_000L
        const val WATCHDOG_STALE_MS = 3 * 60_000L

        /** Per-component state for GET /status. */
        fun componentsStatus(): Map<String, Any?> = Comp.all.associate {
            it.name to mapOf("up" to it.up(), "lastError" to it.lastError, "restarts" to it.restarts)
        }

        /** Minimal up/down summary for GET /health (no sensitive data). */
        fun componentsHealthJson(): String =
            Comp.all.joinToString(",", "{", "}") { "\"" + it.name + "\":" + it.up() }
    }
}
