package com.vrheadsetmanager.companion

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.display.DisplayManager
import android.os.Handler
import android.os.HandlerThread
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log

/**
 * Local shell probes scheduler (local-probes.md 3.4, ADR-0046). Runs the FIXED catalogue commands
 * through [ShellSession] on its own thread and hands the parsed fields to the live
 * [TelemetryCollector]. Meta only. The PC can only toggle a probe and re-time it ([applyControl]);
 * it never sends a command.
 */
object ProbeEngine {
    private const val TAG = "VrhmProbe"
    private const val FIRST_RUN_MS = 2000L
    private const val PAUSE_INVALIDATE_MS = 300_000L
    private const val WITHDRAW_FAILS = 2
    private val NEEDS_OUTPUT = setOf("controllers", "thermal", "display")

    private class PS(val def: ProbeDef) {
        var nextAt = 0L
        var runs = 0L
        var fails = 0L
        var consec = 0
        var lastOkAt = 0L
        var lastMs = 0L
        var lastError = ""
        var ovEnabled: Boolean? = null
        var ovEvery: Int? = null
        var state = "nosession"
        var withdrawn = false
    }

    private var thread: HandlerThread? = null
    private var handler: Handler? = null
    private var ctx: Context? = null
    private var probes: List<PS> = emptyList()
    @Volatile private var catalogVersion = ""
    @Volatile private var disabled = true
    @Volatile private var stopped = true
    private var master = true
    private var pausedAt = 0L
    private var startedAt = 0L
    private var pm: PowerManager? = null
    private var screenReceiver: BroadcastReceiver? = null
    private var displayListener: DisplayManager.DisplayListener? = null

    @Volatile private var stateSnapshot: Map<String, String> = emptyMap()
    @Volatile private var statusSnapshot: Map<String, Any?> = emptyMap()

    private val tickR = Runnable { tick() }
    private val displayR = Runnable { runSoon("display", 0L) }

    /** Starts the engine (idempotent). A non-Meta headset or a bad catalogue leaves it disabled. */
    @Synchronized
    fun start(context: Context) {
        if (thread != null) return
        val app = context.applicationContext
        ctx = app
        ShellSession.init(app)
        val cat = ProbeCatalog.load(app)
        if (cat == null) { Log.w(TAG, "probe catalogue unreadable or schema != 1: engine disabled"); disabled = true; publish(); return }
        catalogVersion = cat.version
        val family = TelemetryCollector.family()
        if (family != "meta") { Log.i(TAG, "family $family: probe engine disabled"); disabled = true; publish(); return }
        stopped = false
        disabled = false
        startedAt = SystemClock.elapsedRealtime()
        probes = cat.probes.map { PS(it) }
        pm = app.getSystemService(Context.POWER_SERVICE) as PowerManager
        val t = HandlerThread("vrhm-probes").also { it.start() }
        thread = t
        val h = Handler(t.looper)
        handler = h
        h.post {
            refreshActive()
            val now = SystemClock.elapsedRealtime()
            probes.forEachIndexed { i, p -> p.nextAt = now + FIRST_RUN_MS + i * 300L }
            try {
                val r = object : BroadcastReceiver() {
                    override fun onReceive(c: Context?, i: Intent?) {
                        val n = SystemClock.elapsedRealtime()
                        probes.forEachIndexed { k, p -> if (isActive(p)) p.nextAt = n + 500L + k * 150L }
                        schedule()
                    }
                }
                app.registerReceiver(r, IntentFilter(Intent.ACTION_SCREEN_ON), null, h)
                screenReceiver = r
            } catch (_: Throwable) {}
            try {
                val dm = app.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
                val l = object : DisplayManager.DisplayListener {
                    override fun onDisplayAdded(id: Int) {}
                    override fun onDisplayRemoved(id: Int) {}
                    override fun onDisplayChanged(id: Int) {
                        if (id != 0) return
                        h.removeCallbacks(displayR); h.postDelayed(displayR, 1000L)   // debounced
                    }
                }
                dm.registerDisplayListener(l, h)
                displayListener = l
            } catch (_: Throwable) {}
            publish()
            schedule()
        }
    }

    @Synchronized
    fun stop() {
        stopped = true
        val h = handler
        val app = ctx
        handler = null
        h?.removeCallbacksAndMessages(null)
        try { screenReceiver?.let { app?.unregisterReceiver(it) } } catch (_: Throwable) {}
        try { displayListener?.let { (app?.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager).unregisterDisplayListener(it) } } catch (_: Throwable) {}
        screenReceiver = null; displayListener = null
        try { thread?.quitSafely() } catch (_: Throwable) {}
        thread = null
        probes = emptyList()
        publish()
        // invalidate may wait for the session lock (a probe in flight): never on the caller's (main) thread.
        Thread({ try { ShellSession.invalidate("engine stop") } catch (_: Throwable) {} }, "vrhm-probe-stop").also { it.isDaemon = true; it.start() }
    }

    /** PC control from a telemetry response (section 7). Unknown ids and keys are ignored. */
    fun applyControl(probesEnabled: Boolean?, overrides: Map<String, Pair<Boolean?, Int?>>?) {
        val h = handler ?: return
        h.post {
            if (probesEnabled != null && probesEnabled != master) {
                master = probesEnabled
                pausedAt = if (master) 0L else SystemClock.elapsedRealtime()
                val n = SystemClock.elapsedRealtime()
                if (master) probes.forEach { if (isActive(it)) it.nextAt = n + 500L }
            }
            if (overrides != null) {
                for (p in probes) {
                    val o = overrides[p.def.id]
                    p.ovEnabled = o?.first
                    p.ovEvery = o?.second
                }
            }
            refreshActive()
            // A probe switched off by the PC leaves its fields: same hand-back to the ADB fallback as a failure.
            for (p in probes) {
                if (p.state == "disabled" && p.lastOkAt > 0 && !p.withdrawn) {
                    p.withdrawn = true
                    TelemetryCollector.withdrawLive(p.def.fields.map { it.name })
                }
            }
            publish()
            schedule()
        }
    }

    // ---- state ----------------------------------------------------------------------------------

    private fun supported(p: PS) = "meta" in p.def.brands && "companion" in p.def.runOn
    private fun enabledNow(p: PS) = p.ovEnabled ?: p.def.enabled
    private fun isActive(p: PS) = supported(p) && enabledNow(p) && master

    /** Sets the static states (unsupported / disabled / paused); keeps ok / failed / nosession otherwise. */
    private fun refreshActive() {
        for (p in probes) {
            val want = when {
                !supported(p) -> "unsupported"
                !enabledNow(p) -> "disabled"
                !master -> "paused"
                else -> null
            }
            if (want != null) p.state = want
            else if (p.state == "unsupported" || p.state == "disabled" || p.state == "paused") p.state = "nosession"
        }
    }

    private fun publish() {
        val prev = stateSnapshot
        val m = LinkedHashMap<String, String>()
        for (p in probes) m[p.def.id] = p.state
        stateSnapshot = m
        val now = SystemClock.elapsedRealtime()
        val st = LinkedHashMap<String, Any?>()
        for (p in probes) {
            st[p.def.id] = linkedMapOf(
                "state" to p.state, "everySec" to (p.ovEvery ?: p.def.everySec), "effectiveSec" to periodMs(p) / 1000L,
                "runs" to p.runs, "fails" to p.fails,
                "lastOkAgeSec" to (if (p.lastOkAt > 0) (now - p.lastOkAt) / 1000L else -1L),
                "lastMs" to p.lastMs, "lastError" to p.lastError
            )
        }
        statusSnapshot = st
        if (prev != m) TelemetryCollector.probeStateChangedLive()
    }

    // ---- scheduling -----------------------------------------------------------------------------

    private fun interactive(): Boolean = try { pm?.isInteractive != false } catch (_: Throwable) { true }

    private fun periodMs(p: PS): Long {
        val d = p.def
        var s = (p.ovEvery ?: d.everySec).coerceIn(d.minEverySec, d.maxEverySec).toLong()
        if (!interactive()) s *= maxOf(1, d.screenOffFactor)
        return minOf(s, d.maxEverySec.toLong()) * 1000L
    }

    private fun runSoon(id: String, delay: Long) {
        val p = probes.firstOrNull { it.def.id == id } ?: return
        if (!isActive(p)) return
        p.nextAt = SystemClock.elapsedRealtime() + delay
        schedule()
    }

    private fun schedule() {
        val h = handler ?: return
        h.removeCallbacks(tickR)
        if (!master) {
            h.postDelayed(tickR, 5000L)
            return
        }
        val next = probes.filter { isActive(it) }.minOfOrNull { it.nextAt } ?: (SystemClock.elapsedRealtime() + 5000L)
        h.postDelayed(tickR, maxOf(100L, next - SystemClock.elapsedRealtime()))
    }

    private fun tick() {
        if (handler == null) return
        val now = SystemClock.elapsedRealtime()
        if (!master) {
            if (pausedAt > 0 && now - pausedAt >= PAUSE_INVALIDATE_MS) { pausedAt = Long.MAX_VALUE / 2; ShellSession.invalidate("probes paused") }
            schedule(); return
        }
        val due = probes.filter { isActive(it) && it.nextAt <= now }.minByOrNull { it.nextAt }
        if (due != null) {
            if (TelemetryCollector.hasLive()) runProbe(due)
            due.nextAt = SystemClock.elapsedRealtime() + periodMs(due)
            publish()
        }
        schedule()
    }

    private fun runProbe(p: PS) {
        val d = p.def
        val r = ShellSession.run(d.command, d.timeoutMs.toLong(), d.maxOutputBytes)
        if (stopped) return
        p.runs++
        p.lastMs = r.ms
        val now = SystemClock.elapsedRealtime()
        var fields: Map<String, Any?>? = null
        var err = r.error
        if (r.ok) {
            try {
                if (d.parser in NEEDS_OUTPUT && r.lines.all { it.isBlank() }) err = "empty output"
                else {
                    fields = ProbeParsers.parse(d.parser, r.lines)
                    if (fields == null) err = "unknown parser ${d.parser}"
                    else if (d.parser in NEEDS_OUTPUT && fields.values.all { it == null }) { fields = null; err = "no value parsed" }
                }
            } catch (e: Throwable) { err = "parser: ${e.message}" }
        }
        if (fields != null) {
            p.consec = 0; p.lastOkAt = now; p.lastError = ""; p.state = "ok"; p.withdrawn = false
            val names = d.fields.map { it.name }.toSet()
            TelemetryCollector.applyProbeLive(fields.filterKeys { it in names })
            return
        }
        p.fails++; p.consec++
        p.lastError = err ?: "failed"
        p.state = if (r.down) "nosession" else "failed"
        val downFor = now - maxOf(p.lastOkAt, startedAt)
        if (!p.withdrawn && (p.consec >= WITHDRAW_FAILS || (r.down && downFor >= 2 * periodMs(p)))) {
            p.withdrawn = true
            TelemetryCollector.withdrawLive(d.fields.map { it.name })
            Log.i(TAG, "probe ${d.id} withdrawn: ${p.lastError}")
        }
    }

    // ---- read side ------------------------------------------------------------------------------

    fun probeStates(): Map<String, String> = stateSnapshot
    fun catalogVersion(): String = catalogVersion
    fun shellState(): String = if (disabled) "disabled" else ShellSession.state

    /** /status block. */
    fun status(): Map<String, Any?> = linkedMapOf(
        "probeCatalog" to catalogVersion,
        "shell" to (LinkedHashMap(ShellSession.status()).also { if (disabled) it["state"] = "disabled" }),
        "probes" to statusSnapshot
    )
}
