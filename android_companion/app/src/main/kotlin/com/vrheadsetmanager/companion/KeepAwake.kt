package com.vrheadsetmanager.companion

import android.content.Context
import android.os.PowerManager
import android.provider.Settings

/**
 * "Keep headset awake" (default ON): the headset must not go to sleep.
 *
 * Two mechanisms, both owned here:
 *  1. A screen wake lock held by the process while the switch is ON (SCREEN_BRIGHT_WAKE_LOCK, deprecated
 *     but still honoured for a background foreground service; ACQUIRE_CAUSES_WAKEUP wakes a sleeping
 *     screen once at acquire). VERIFY ON DEVICE: Horizon OS may still sleep on the proximity sensor.
 *  2. Meta only: the proximity override "prox_close" (headset behaves as if worn) sent through the app's
 *     OWN ADB session (ShellSession, which owns the connection), one command through the shared ShellSession when the switch turns on and one after each boot. Off sends
 *     "automation_disable" once. Never periodic (telemetry v2 spec: no steady-state self-ADB).
 * Pico has no ADB over TLS, so only the wake lock applies there ("not-supported" for the override).
 * With the switch OFF no wake lock of any kind is held.
 */
object KeepAwake {
    const val PREF_KEEP_AWAKE = "keep_awake"
    private const val PREF_BOOT_COUNT = "keep_awake_boot_count"
    private const val CMD_ON = "am broadcast -a com.oculus.vrpowermanager.prox_close"
    private const val CMD_OFF = "am broadcast -a com.oculus.vrpowermanager.automation_disable"
    private const val BOOT_DELAY_MS = 20_000L
    private const val ATTEMPTS = 4
    private const val BACKOFF_MS = 15_000L

    private var wakeLock: PowerManager.WakeLock? = null
    @Volatile private var prox = "pending"   // pending | ok | failed | not-supported | off
    private val running = java.util.concurrent.atomic.AtomicBoolean(false)

    private fun prefs(ctx: Context) =
        SelfAdb.dpCtx(ctx.applicationContext).getSharedPreferences(BootReceiver.PREFS_NAME, Context.MODE_PRIVATE)

    fun isEnabled(ctx: Context): Boolean = prefs(ctx).getBoolean(PREF_KEEP_AWAKE, true)

    /** Persists the wish and applies it now (wake lock at once, override on a background thread). */
    fun setEnabled(ctx: Context, enabled: Boolean) {
        prefs(ctx).edit().putBoolean(PREF_KEEP_AWAKE, enabled).apply()
        apply(ctx, forceProx = true)
    }

    /** Wake lock to match the pref; [forceProx] also (re)sends the override once. Safe to call often. */
    @Synchronized
    fun apply(ctx: Context, forceProx: Boolean = false) {
        val app = ctx.applicationContext
        val on = isEnabled(app)
        try {
            val pm = app.getSystemService(Context.POWER_SERVICE) as PowerManager
            if (on) {
                if (wakeLock?.isHeld != true) {
                    @Suppress("DEPRECATION")
                    wakeLock = pm.newWakeLock(
                        PowerManager.SCREEN_BRIGHT_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP,
                        "VRHM:KeepAwake"
                    ).also { it.setReferenceCounted(false); it.acquire() }
                }
            } else {
                if (wakeLock?.isHeld == true) wakeLock?.release()
                wakeLock = null
            }
        } catch (e: Throwable) { AdbBootManager.log("keepAwake wake lock: ${e.message}") }
        if (AdbBootManager.isPico()) { prox = "not-supported"; return }
        if (forceProx) sendProxAsync(app, on, 0L)
    }

    /** Called by the service at start: wake lock now, and the override once per boot. */
    fun onServiceStart(ctx: Context) {
        val app = ctx.applicationContext
        apply(app)
        if (AdbBootManager.isPico()) return
        val bc = try { Settings.Global.getInt(app.contentResolver, "boot_count", -1) } catch (_: Throwable) { -1 }
        val p = prefs(app)
        if (bc >= 0 && p.getInt(PREF_BOOT_COUNT, -2) == bc) return   // already sent on this boot
        if (!isEnabled(app)) { prox = "off"; return }
        sendProxAsync(app, true, BOOT_DELAY_MS) { if (bc >= 0) p.edit().putInt(PREF_BOOT_COUNT, bc).apply() }
    }

    private fun sendProxAsync(app: Context, on: Boolean, delayMs: Long, onOk: (() -> Unit)? = null) {
        if (!running.compareAndSet(false, true)) return
        prox = "pending"
        Thread({
            try {
                if (delayMs > 0) try { Thread.sleep(delayMs) } catch (_: InterruptedException) { return@Thread }
                for (attempt in 1..ATTEMPTS) {
                    val want = isEnabled(app)
                    try {
                        ShellSession.init(app)
                        val r = ShellSession.run(if (want) CMD_ON else CMD_OFF, 10_000, 4096, force = true)
                        val out = r.lines.joinToString(" ")
                        AdbBootManager.log("keepAwake prox ${if (want) "on" else "off"} -> ${(r.error ?: out).trim().take(120)}")
                        // Broadcast completed = confirmed; the shell ran the command (exit 0) but printed
                        // nothing we recognise = "sent" (unconfirmed).
                        val confirmed = r.ok && out.contains("Broadcast completed")
                        val sent = r.ok && !confirmed && r.exit == 0
                        prox = if (confirmed) (if (want) "ok" else "off") else if (sent) (if (want) "sent" else "off") else "failed"
                        if (confirmed || sent) { onOk?.invoke(); return@Thread }
                    } catch (e: Throwable) {
                        AdbBootManager.log("keepAwake prox attempt $attempt: ${e.message}")
                    }
                    prox = "failed"
                    if (attempt < ATTEMPTS) try { Thread.sleep(BACKOFF_MS) } catch (_: InterruptedException) { return@Thread }
                }
            } finally { running.set(false) }
        }, "VRHM-KeepAwakeProx").also { it.isDaemon = true; it.start() }
    }

    fun release() {
        try { if (wakeLock?.isHeld == true) wakeLock?.release() } catch (_: Throwable) {}
        wakeLock = null
    }

    fun status(ctx: Context): Map<String, Any?> = linkedMapOf(
        "enabled" to isEnabled(ctx),
        "wakeLock" to (wakeLock?.isHeld == true),
        "proxOverride" to (if (AdbBootManager.isPico()) "not-supported" else prox)
    )
}