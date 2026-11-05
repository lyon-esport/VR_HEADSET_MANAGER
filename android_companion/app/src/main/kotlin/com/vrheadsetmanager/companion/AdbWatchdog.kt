package com.vrheadsetmanager.companion

import android.content.Context
import android.database.ContentObserver
import android.net.ConnectivityManager
import android.net.Network
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.util.Log

/**
 * Keeps wireless ADB on. Android/Horizon FORCE-DISABLES wireless debugging on every reboot (a plain
 * one-shot write of adb_wifi_enabled=1 reverts), so this does not try to prevent the revert - it
 * out-waits it: it re-writes adb_wifi_enabled=1 whenever it drops, driven by a change-observer on
 * that setting, a WiFi availability callback, and a 60 s fallback timer, debounced. Technique from the
 * MIT-licensed eu.project_simple.adbautoenable watchdog (reimplemented). Needs WRITE_SECURE_SETTINGS.
 *
 * Only runs while the master switch (auto-enable on boot) is on and the mode is not NONE. Hosted by
 * CompanionService (START_STICKY foreground), so it lives across the whole session.
 */
class AdbWatchdog(ctx: Context) {
    private val app = ctx.applicationContext
    private val handler = Handler(Looper.getMainLooper())
    private var observer: ContentObserver? = null
    private var netCb: ConnectivityManager.NetworkCallback? = null
    private var lastTick = 0L
    private var classicDoneForSession = false

    private val periodic = object : Runnable {
        override fun run() { tick("periodic"); handler.postDelayed(this, PERIOD_MS) }
    }

    fun start() {
        try {
            observer = object : ContentObserver(handler) {
                override fun onChange(selfChange: Boolean) { tick("observer") }
            }
            app.contentResolver.registerContentObserver(
                Settings.Global.getUriFor(KEY), false, observer!!)
        } catch (e: Exception) { Log.i(TAG, "observer register failed: ${e.message}") }

        try {
            val cm = app.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            netCb = object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) { classicDoneForSession = false; tick("net") }
            }
            cm.registerDefaultNetworkCallback(netCb!!)
        } catch (e: Exception) { Log.i(TAG, "net callback register failed: ${e.message}") }

        handler.removeCallbacks(periodic)
        handler.post(periodic)
        Log.i(TAG, "watchdog started")
    }

    fun stop() {
        handler.removeCallbacksAndMessages(null)
        try { observer?.let { app.contentResolver.unregisterContentObserver(it) } } catch (_: Exception) {}
        try {
            val cm = app.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            netCb?.let { cm.unregisterNetworkCallback(it) }
        } catch (_: Exception) {}
        observer = null; netCb = null
        Log.i(TAG, "watchdog stopped")
    }

    private fun tick(reason: String) {
        val now = SystemClock.elapsedRealtime()
        if (now - lastTick < DEBOUNCE_MS) return
        lastTick = now

        if (!AdbBootManager.autoEnabled(app)) return
        val mode = AdbBootManager.getBootMode(app)
        if (mode == BootMode.NONE) return

        val cur = try { Settings.Global.getInt(app.contentResolver, KEY) } catch (_: Exception) { -1 }
        if (cur != 1) {
            try {
                Settings.Global.putInt(app.contentResolver, KEY, 1)
                Log.i(TAG, "re-enabled $KEY (was $cur, reason=$reason)")
            } catch (e: SecurityException) {
                Log.i(TAG, "cannot write $KEY: WRITE_SECURE_SETTINGS not granted")
                return
            } catch (e: Exception) {
                Log.i(TAG, "write $KEY failed: ${e.message}"); return
            }
        }

        // CLASSIC mode also needs tcpip opened once the wireless transport is up. Do it ONCE per
        // network session (reset on a new network / when wifi drops) so we do not loop on the
        // adbd restart that tcpip causes.
        if (mode == BootMode.CLASSIC && cur == 1 && !classicDoneForSession) {
            classicDoneForSession = true
            handler.postDelayed({ AdbBootManager.forceClassicNow(app) }, 2500)
        }
    }

    companion object {
        const val TAG = "VrhmWatchdog"
        const val KEY = "adb_wifi_enabled"
        const val DEBOUNCE_MS = 500L
        const val PERIOD_MS = 60_000L
    }
}
