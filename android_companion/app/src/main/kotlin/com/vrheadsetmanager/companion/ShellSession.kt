package com.vrheadsetmanager.companion

import android.content.Context
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import io.github.muntashirakon.adb.AbsAdbConnectionManager
import io.github.muntashirakon.adb.AdbStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.OutputStream
import java.util.ArrayDeque
import java.util.Random
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.locks.ReentrantLock

data class ShellResult(
    val ok: Boolean, val lines: List<String>, val exit: Int?, val ms: Long, val error: String?,
    /** True when the failure is the session itself (no connection / lost), not the command. */
    val down: Boolean = false
)

/** Pure framing helpers of the shell stream (unit-tested). */
object ShellFraming {
    private val MARKER = Regex("^__VRHM_(\\d+)_(\\d+)__$")

    /** One line sent to sh: the marker always lands on its own line (the echo before it ends any partial line). */
    fun frame(cmd: String, seq: Int): String =
        "{ $cmd ; } 2>/dev/null; r=\$?; echo; echo \"__VRHM_${seq}_\${r}__\"\n"

    /** (seq, exit) of a marker line, else null. */
    fun parseMarker(line: String): Pair<Int, Int?>? {
        val m = MARKER.find(line) ?: return null
        return Pair(m.groupValues[1].toInt(), m.groupValues[2].toIntOrNull())
    }

    /** Drops the blank line the framing echo adds before the marker. */
    fun dropFramingBlank(lines: List<String>): List<String> =
        if (lines.isNotEmpty() && lines.last().isEmpty()) lines.dropLast(1) else lines
}

/**
 * THE only owner of the app's self-ADB connection (local-probes.md section 3, ADR-0046): connects,
 * disconnects and opens streams on [SelfAdb]; everything else borrows it through [run] or
 * [withConnection]. One long-lived `shell,raw:` stream per boot, one command in flight at a time,
 * each command framed by an echoed marker line. Failures follow a capped backoff; boot and operator
 * paths pass `force` to bypass the backoff / unauthorized gate (still single-flight).
 */
object ShellSession {
    private const val TAG = "VrhmProbe"
    private val BACKOFF_S = longArrayOf(3, 5, 10, 20, 40, 80, 160, 300)
    private const val UNAUTH_RETRY_MS = 600_000L

    private val lock = ReentrantLock()
    private val rnd = Random()
    @Volatile private var appCtx: Context? = null

    @Volatile private var mgr: AbsAdbConnectionManager? = null
    @Volatile private var sc: StreamCtx? = null
    /** Set by [invalidate] when the lock is busy; the holder applies it when it unlocks. */
    @Volatile private var pendingInvalidate: String? = null
    private var seq = 0
    private var lastTransport: String? = null
    private var backoffIdx = 0
    private var backoffUntil = 0L
    private val reopenTimes = ArrayDeque<Long>()

    @Volatile var state = "idle"; private set          // up | connecting | backoff | unauthorized | idle | disabled
    @Volatile var transport = ""; private set
    @Volatile var connects = 0; private set
    @Volatile var streamOpens = 0; private set
    @Volatile var timeouts = 0; private set
    @Volatile var lastError = ""; private set
    @Volatile var since = System.currentTimeMillis(); private set

    /** Idempotent; call before the first use (service start, boot receiver paths). */
    fun init(ctx: Context) { if (appCtx == null) appCtx = ctx.applicationContext }

    private fun log(m: String) { Log.i(TAG, m) }

    private fun setState(s: String) { if (state != s) { state = s; since = System.currentTimeMillis() } }

    private class StreamCtx(val stream: AdbStream) {
        val out: OutputStream = stream.openOutputStream()
        private val inp = stream.openInputStream()
        private val q = LinkedBlockingQueue<ByteArray>()
        private val buf = ByteArrayOutputStream()
        private val lines = ArrayDeque<String>()
        @Volatile var closed = false
        private val reader = Thread({
            try {
                val b = ByteArray(4096)
                while (true) {
                    val n = inp.read(b)
                    if (n < 0) break
                    q.add(b.copyOf(n))
                }
            } catch (_: Throwable) {}
            q.add(EOF)
        }, "vrhm-shell-reader").also { it.isDaemon = true; it.start() }

        /** Next line, null on timeout; IOException when the stream ended. */
        fun readLine(deadline: Long): String? {
            while (true) {
                lines.pollFirst()?.let { return it }
                val wait = deadline - SystemClock.elapsedRealtime()
                if (wait <= 0) return null
                val c = q.poll(wait, TimeUnit.MILLISECONDS) ?: return null
                if (c === EOF) { q.add(EOF); throw IOException("stream closed") }
                for (x in c) {
                    if (x == 10.toByte()) {
                        lines.add(String(buf.toByteArray(), Charsets.UTF_8).trimEnd('\r')); buf.reset()
                    } else buf.write(x.toInt())
                }
            }
        }

        fun close() {
            closed = true
            try { stream.close() } catch (_: Throwable) {}
            try { reader.interrupt() } catch (_: Throwable) {}
        }

        companion object { val EOF = ByteArray(0) }
    }

    private fun fail(msg: String, t0: Long, down: Boolean) =
        ShellResult(false, emptyList(), null, SystemClock.elapsedRealtime() - t0, msg, down)

    /** Runs one shell command through the shared stream. Blocking, background threads only. */
    fun run(cmd: String, timeoutMs: Long, maxBytes: Int, force: Boolean = false): ShellResult {
        val t0 = SystemClock.elapsedRealtime()
        val app = appCtx ?: return fail("not initialised", t0, true)
        if (AdbBootManager.isPico()) return fail("pico: shell session disabled", t0, true)
        if (!lock.tryLock(timeoutMs + 2000, TimeUnit.MILLISECONDS)) return fail("busy", t0, false)
        try {
            if (!force && (state == "backoff" || state == "unauthorized") && SystemClock.elapsedRealtime() < backoffUntil)
                return fail(lastError.ifEmpty { state }, t0, true)
            if (!ensureStream(app, force)) return fail(lastError.ifEmpty { "no session" }, t0, true)
            val s = sc!!
            val my = ++seq
            val lines = ArrayList<String>()
            var size = 0
            var overflow = false
            try {
                s.out.write(ShellFraming.frame(cmd, my).toByteArray(Charsets.UTF_8))
                s.out.flush()
                val deadline = SystemClock.elapsedRealtime() + timeoutMs
                while (true) {
                    val ln = s.readLine(deadline)
                    if (ln == null) {
                        timeouts++
                        log("timeout after ${timeoutMs}ms: ${cmd.take(60)}")
                        closeStream()   // adbd kills the shell and its children; the connection stays
                        return fail("timeout", t0, false)
                    }
                    val m = ShellFraming.parseMarker(ln)
                    if (m != null) {
                        if (m.first < my) { lines.clear(); size = 0; overflow = false; continue }   // leftover of a timed-out command
                        if (m.first == my) {
                            val ms = SystemClock.elapsedRealtime() - t0
                            return if (overflow) ShellResult(false, emptyList(), m.second, ms, "output too large")
                            else ShellResult(true, ShellFraming.dropFramingBlank(lines), m.second, ms, null)
                        }
                    }
                    size += ln.length + 1
                    if (size > maxBytes) overflow = true else lines.add(ln)   // keep reading to the marker
                }
            } catch (e: IOException) {
                connectionLost("stream: ${e.message}")
                return fail(lastError, t0, true)
            }
        } catch (e: Throwable) {
            connectionLost("run: ${e.message}")
            return fail(lastError, t0, true)
        } finally {
            unlockApply()
        }
    }

    /** Exclusive borrow of the connection (connects when needed). Null when no connection. */
    fun <T> withConnection(force: Boolean = false, block: (AbsAdbConnectionManager) -> T): T? {
        val app = appCtx ?: return null
        if (!lock.tryLock(30, TimeUnit.SECONDS)) return null
        try {
            if (!ensureConnected(app, force)) return null
            return try { block(mgr!!) } catch (e: Throwable) { log("withConnection: ${e.message}"); null }
        } finally {
            unlockApply()
        }
    }

    /**
     * Drops stream and connection (adbd about to restart, probes paused). No backoff. Never closes
     * without the lock: when it is busy the request is recorded and the holder applies it on unlock.
     */
    fun invalidate(reason: String) {
        val got = try { lock.tryLock(3, TimeUnit.SECONDS) } catch (_: InterruptedException) { false }
        if (!got) { pendingInvalidate = reason; return }
        try {
            pendingInvalidate = null
            doInvalidate(reason)
        } finally {
            unlockApply()
        }
    }

    private fun doInvalidate(reason: String) {
        log("invalidate: $reason")
        closeAll()
        backoffIdx = 0; backoffUntil = 0
        setState("idle")
    }

    /** Caller holds the lock: applies an invalidate that arrived while it was busy, then unlocks. */
    private fun unlockApply() {
        if (!lock.isHeldByCurrentThread) return
        val p = pendingInvalidate
        if (p != null && lock.holdCount == 1) { pendingInvalidate = null; doInvalidate(p) }
        lock.unlock()
    }

    fun status(): Map<String, Any?> = linkedMapOf(
        "state" to state, "transport" to transport, "connects" to connects, "streamOpens" to streamOpens,
        "timeouts" to timeouts, "lastError" to lastError, "since" to since
    )

    // ---- internals (caller holds the lock) ----------------------------------------------------------

    private fun closeStream() { sc?.close(); sc = null }

    private fun closeAll() {
        closeStream()
        try { mgr?.disconnect() } catch (_: Throwable) {}
        transport = ""
    }

    private fun connectionLost(why: String) {
        lastError = why
        log("connection lost: $why")
        closeAll()
        if (pendingInvalidate != null) return   // an invalidate is pending: stay idle, no backoff
        scheduleBackoff()
    }

    private fun scheduleBackoff() {
        val d = BACKOFF_S[minOf(backoffIdx, BACKOFF_S.size - 1)]
        backoffIdx++
        backoffUntil = SystemClock.elapsedRealtime() + (d * 1000L * (0.8 + rnd.nextDouble() * 0.4)).toLong()
        setState("backoff")
    }

    private fun adbWifiOn(app: Context): Boolean =
        try { Settings.Global.getInt(app.contentResolver, "adb_wifi_enabled") == 1 } catch (_: Throwable) { false }

    private fun ensureConnected(app: Context, force: Boolean = false): Boolean {
        val cur = mgr
        if (cur != null && cur.isConnected) return true
        if (!force && (state == "backoff" || state == "unauthorized") && SystemClock.elapsedRealtime() < backoffUntil) return false
        setState("connecting")
        val m: AbsAdbConnectionManager = try { SelfAdb.get(app) } catch (e: Throwable) {
            lastError = "key init: ${e.message}"
            AdbBootManager.recordConnect(false, null, lastError)
            scheduleBackoff(); return false
        }
        mgr = m
        try { m.disconnect() } catch (_: Throwable) {}
        try { m.setTimeout(20_000, TimeUnit.MILLISECONDS) } catch (_: Throwable) {}
        val order = ArrayList<String>()
        lastTransport?.let { order.add(it) }
        for (t in (if (adbWifiOn(app)) listOf("tls", "classic") else listOf("classic", "tls"))) if (t !in order) order.add(t)
        if (AdbBootManager.isPico()) order.remove("tls")   // Pico: the adbd drops the TLS session at once
        var unauthorized = false
        var err = "no adb transport reachable"
        for (t in order) {
            try {
                val ok = if (t == "tls") m.autoConnect(app, 10_000) else m.connect("127.0.0.1", AdbBootManager.getClassicPort(app))
                if (ok) {
                    connects++; transport = t; lastTransport = t
                    AdbBootManager.recordConnect(true, t, null)
                    log("connected ($t), connects=$connects")
                    setState("idle")
                    return true
                }
            } catch (e: Throwable) {
                err = "$t: ${e.message}"
                val low = (e.message ?: "").lowercase()
                if (low.contains("authoriz") || low.contains("denied")) unauthorized = true
                log("$t connect failed: ${e.message}")
            }
        }
        lastError = err
        AdbBootManager.recordConnect(false, null, err)
        if (unauthorized) { backoffUntil = SystemClock.elapsedRealtime() + UNAUTH_RETRY_MS; setState("unauthorized") }
        else scheduleBackoff()
        return false
    }

    private fun ensureStream(app: Context, force: Boolean = false): Boolean {
        val s = sc
        if (s != null && !s.closed && mgr?.isConnected == true) return true
        closeStream()
        if (!ensureConnected(app, force)) return false
        val now = SystemClock.elapsedRealtime()
        while (!reopenTimes.isEmpty() && now - reopenTimes.peekFirst()!! > 600_000L) reopenTimes.pollFirst()
        if (reopenTimes.size >= 5) { reopenTimes.clear(); connectionLost("5 stream reopens within 10 min"); return false }
        reopenTimes.addLast(now)
        for (service in listOf("shell,raw:", "shell:")) {
            var ctx: StreamCtx? = null
            try {
                ctx = StreamCtx(mgr!!.openStream(service))
                streamOpens++
                val first = if (service == "shell:") "stty -echo; PS1=''; echo \"__VRHM_0_0__\"\n" else "echo \"__VRHM_0_0__\"\n"
                ctx.out.write(first.toByteArray(Charsets.UTF_8)); ctx.out.flush()
                val deadline = SystemClock.elapsedRealtime() + 4000
                var synced = false
                while (true) {
                    val ln = ctx.readLine(deadline) ?: break
                    if (ln.trim() == "__VRHM_0_0__") { synced = true; break }
                }
                if (synced) {
                    sc = ctx; backoffIdx = 0; backoffUntil = 0; setState("up")
                    log("stream open ($service) over $transport, opens=$streamOpens")
                    return true
                }
                log("stream $service: no sync")
            } catch (e: Throwable) {
                log("stream $service failed: ${e.message}")
            }
            ctx?.close()
        }
        connectionLost("cannot open a shell stream")
        return false
    }
}
