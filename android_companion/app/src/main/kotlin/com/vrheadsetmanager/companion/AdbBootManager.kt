package com.vrheadsetmanager.companion

import android.content.Context
import android.provider.Settings
import android.util.Log
import io.github.muntashirakon.adb.AbsAdbConnectionManager
import java.util.concurrent.TimeUnit

enum class BootMode { NONE, CLASSIC, TLS }

/**
 * Self-ADB + boot-mode engine. Connects the app to its own device's adbd (TLS or classic)
 * and, in CLASSIC mode, runs "tcpip <port>" at boot so the PC can reach the headset.
 */
object AdbBootManager {
    const val TAG = "VrhmAdbBoot"
    const val PREFS = "adb_boot"
    const val KEY_MODE = "adb_boot_mode"
    const val KEY_PORT = "adb_classic_port"
    const val DEFAULT_PORT = 5555
    private const val ATTEMPTS = 5
    private const val BACKOFF_MS = 8000L

    @Volatile private var lastOk: Boolean? = null
    @Volatile private var lastWhen: Long = 0
    @Volatile private var lastTransport: String? = null
    @Volatile private var lastError: String? = null

    fun log(msg: String) { Log.i(TAG, msg) }

    /**
     * Pico headsets: the firmware's adbd accepts the TLS socket but immediately closes the adb
     * session (measured on a Pico 4 Ultra / Android 14: "connect ok=true transport=tls" followed at
     * once by SocketException in AdbProtocol.parse), so self-ADB over TLS never yields a usable
     * shell. We therefore never attempt TLS self-ADB on Pico - it only churns and spams the log.
     * adb_wifi_enabled is still set at boot (ensureWirelessDebugging); cable-free ADB simply is not
     * achievable there (ADR-0038). Telemetry still works over the Android APIs.
     */
    fun isPico(): Boolean =
        ("${android.os.Build.BRAND} ${android.os.Build.MANUFACTURER} ${android.os.Build.MODEL}")
            .lowercase().let { it.contains("pico") || it.contains("pvr") }

    private fun prefs(ctx: Context) =
        SelfAdb.dpCtx(ctx.applicationContext).getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun hasBootMode(ctx: Context): Boolean = prefs(ctx).contains(KEY_MODE)

    // Mode preference (TLS default). On/off is the separate "auto-enable on boot" switch
    // (BootReceiver.PREF_AUTO_ADB), so there is no NONE option in the UI dropdown any more.
    fun getBootMode(ctx: Context): BootMode = try {
        when (BootMode.valueOf(prefs(ctx).getString(KEY_MODE, BootMode.TLS.name) ?: BootMode.TLS.name)) {
            BootMode.CLASSIC -> BootMode.CLASSIC
            else -> BootMode.TLS   // NONE from an older install reads as TLS; the switch gates it
        }
    } catch (e: Exception) { BootMode.TLS }

    /** The master on/off: the "auto-enable ADB WiFi on boot" switch (companion_prefs). */
    fun autoEnabled(ctx: Context): Boolean =
        SelfAdb.dpCtx(ctx.applicationContext)
            .getSharedPreferences(BootReceiver.PREFS_NAME, Context.MODE_PRIVATE)
            .getBoolean(BootReceiver.PREF_AUTO_ADB, true)

    fun getClassicPort(ctx: Context): Int = prefs(ctx).getInt(KEY_PORT, DEFAULT_PORT)

    fun setBootMode(ctx: Context, mode: BootMode) {
        prefs(ctx).edit().putString(KEY_MODE, mode.name).apply()
        log("boot mode set to $mode")
        if (mode != BootMode.NONE) applyAsync(ctx)
    }

    fun setClassicPort(ctx: Context, port: Int) {
        if (port !in 1024..65535) return
        prefs(ctx).edit().putInt(KEY_PORT, port).apply()
        log("classic port set to $port")
    }

    /**
     * Turns on Wireless debugging. The network-allow dialog and the per-key "Allow debugging"
     * trust dialog are NOT handled here: they are accepted by the orchestrator's approver or
     * once by hand.
     */
    fun ensureWirelessDebugging(ctx: Context) {
        try {
            Settings.Global.putInt(ctx.contentResolver, "adb_wifi_enabled", 1)
        } catch (e: SecurityException) {
            lastError = "WRITE_SECURE_SETTINGS not granted"
            log("ensureWirelessDebugging: ${e.message}")
        } catch (e: Exception) {
            lastError = "wireless debugging: ${e.message}"
            log("ensureWirelessDebugging failed: ${e.message}")
        }
    }

    private fun adbWifiEnabled(ctx: Context): Int =
        try { Settings.Global.getInt(ctx.contentResolver, "adb_wifi_enabled") } catch (e: Exception) { -1 }

    /** Try TLS first (mDNS autoConnect), then classic on loopback. Null when neither works. */
    fun selfConnect(ctx: Context): AbsAdbConnectionManager? {
        val app = ctx.applicationContext
        val mgr: AbsAdbConnectionManager = try { SelfAdb.get(app) } catch (e: Throwable) {
            lastError = "key init: ${e.message}"; lastOk = false; lastWhen = System.currentTimeMillis()
            log("SelfAdb init failed: ${e.message}")
            return null
        }
        try { mgr.setTimeout(20_000, TimeUnit.MILLISECONDS) } catch (_: Throwable) {}
        // TODO(orchestrator): the per-key "Allow debugging" dialog must be accepted by the
        // approver before TLS connect can succeed. Assumed already trusted here.
        // Pico never gets a usable TLS self-ADB session (see isPico): skip it entirely.
        if (!isPico()) {
            try {
                if (mgr.autoConnect(app, 10_000)) { record(true, "tls", null); return mgr }
            } catch (e: Throwable) { log("tls connect failed: ${e.message}") }
        }
        try {
            if (mgr.connect("127.0.0.1", getClassicPort(app))) { record(true, "classic", null); return mgr }
        } catch (e: Throwable) { log("classic connect failed: ${e.message}") }
        record(false, null, if (isPico()) "pico: TLS self-ADB not supported" else "no adb transport reachable")
        return null
    }

    private fun record(ok: Boolean, transport: String?, err: String?) {
        lastOk = ok; lastWhen = System.currentTimeMillis(); lastTransport = transport
        lastError = if (ok) null else (err ?: lastError)
        log("connect ok=$ok transport=$transport err=$err")
    }

    fun runShell(mgr: AbsAdbConnectionManager, cmd: String, timeoutMs: Long = 15000): String {
        return try {
            mgr.openStream("shell:$cmd").use { stream ->
                val input = stream.openInputStream()
                val sb = StringBuilder()
                val buf = ByteArray(4096)
                val deadline = System.currentTimeMillis() + timeoutMs
                while (System.currentTimeMillis() < deadline) {
                    val n = input.read(buf)
                    if (n < 0) break
                    sb.append(String(buf, 0, n, Charsets.UTF_8))
                    if (sb.length > 16384) break
                }
                sb.toString()
            }
        } catch (e: Throwable) { "shell-ex ${e.message}" }
    }

    /** "tcpip <port>" restarts adbd in classic mode; the connection usually drops, which is fine. */
    fun openTcpip(mgr: AbsAdbConnectionManager, port: Int): String {
        return try {
            mgr.openStream("tcpip:$port").use { stream ->
                val input = stream.openInputStream()
                val buf = ByteArray(256)
                val n = try { input.read(buf) } catch (_: Exception) { -1 }
                if (n > 0) String(buf, 0, n, Charsets.UTF_8) else "(no reply)"
            }
        } catch (e: Throwable) { "tcpip-ex ${e.message}" }
    }

    private fun disconnectQuietly(mgr: AbsAdbConnectionManager?) {
        try { mgr?.disconnect() } catch (_: Throwable) {}
    }

    /**
     * Blocking: applies the persisted boot mode with up to 5 attempts, 8 s apart.
     * Call from a background thread (use applyAsync otherwise).
     */
    fun applyBootMode(ctx: Context) {
        val app = ctx.applicationContext
        if (!autoEnabled(app)) { log("applyBootMode: auto-enable switch OFF, skipping"); return }
        // Pico: NEVER enable TLS (adb_wifi_enabled) here - it is useless on Pico (session dropped,
        // and the firmware reverts the setting while idle). Classic WiFi ADB on Pico cannot be
        // bootstrapped by the app either (tcpip needs an adb shell the app cannot get cable-free),
        // so it must come from persist.adb.tcp.port set once over USB. Companion stays telemetry-only.
        if (isPico()) { log("applyBootMode: Pico - app does not manage ADB (classic is via persist.adb.tcp.port over USB)"); return }
        val mode = getBootMode(app)
        log("applyBootMode: $mode")
        if (mode == BootMode.NONE) return
        for (attempt in 1..ATTEMPTS) {
            try {
                ensureWirelessDebugging(app)
                if (mode == BootMode.TLS) {
                    // TLS self-advertises over mDNS once adb_wifi_enabled=1; the PC key must be trusted.
                    log("TLS mode: wireless debugging enabled (attempt $attempt)")
                    return
                }
                val mgr = selfConnect(app)
                if (mgr != null) {
                    val res = openTcpip(mgr, getClassicPort(app))
                    log("tcpip ${getClassicPort(app)} -> $res")
                    disconnectQuietly(mgr)
                    return
                }
            } catch (e: Throwable) {
                lastError = e.message
                log("applyBootMode attempt $attempt error: ${e.message}")
            }
            if (attempt < ATTEMPTS) try { Thread.sleep(BACKOFF_MS) } catch (_: InterruptedException) { return }
        }
        log("applyBootMode: gave up after $ATTEMPTS attempts")
    }

    /** Runs applyBootMode on a background thread; finish() is called when done (goAsync use). */
    fun applyAsync(ctx: Context, finish: (() -> Unit)? = null) {
        val app = ctx.applicationContext
        Thread {
            try { applyBootMode(app) } catch (e: Throwable) { log("applyAsync: ${e.message}") }
            finally { try { finish?.invoke() } catch (_: Throwable) {} }
        }.start()
    }

    fun forceClassicNow(ctx: Context) {
        val app = ctx.applicationContext
        Thread {
            try {
                ensureWirelessDebugging(app)
                val mgr = selfConnect(app)
                if (mgr != null) {
                    log("forceClassic tcpip -> " + openTcpip(mgr, getClassicPort(app)))
                    disconnectQuietly(mgr)
                }
            } catch (e: Throwable) { lastError = e.message; log("forceClassicNow: ${e.message}") }
        }.start()
    }

    fun forceTlsNow(ctx: Context) {
        val app = ctx.applicationContext
        Thread {
            try {
                ensureWirelessDebugging(app)
                val mgr = selfConnect(app)
                disconnectQuietly(mgr)
            } catch (e: Throwable) { lastError = e.message; log("forceTlsNow: ${e.message}") }
        }.start()
    }

    fun status(ctx: Context): Map<String, Any?> {
        val app = ctx.applicationContext
        val fp = try { SelfAdb.get(app).fingerprint() } catch (e: Throwable) { null }
        return mapOf(
            "bootMode" to getBootMode(app).name,
            "classicPort" to getClassicPort(app),
            "adbWifiEnabled" to adbWifiEnabled(app),
            "keyFingerprint" to fp,
            "lastConnect" to mapOf("ok" to lastOk, "when" to lastWhen, "transport" to lastTransport),
            "lastError" to lastError
        )
    }
}