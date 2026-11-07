package com.vrheadsetmanager.companion

import android.content.Context
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import com.google.gson.Gson
import com.google.gson.JsonArray
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import java.net.HttpURLConnection
import java.net.URL
import java.util.Random
import java.util.UUID

/**
 * Telemetry v2 sender (ADR-0042, ADR-0043; spec docs/improvement_plan/companion-hardening/telemetry-v2.md).
 *
 * One owner HandlerThread per start ([Loop]). [TelemetryCollector] keeps the latest value per field
 * on that same thread and calls back when something moved. The loop diffs against the last ACKED
 * (2xx) values, coalesces changes (min gap 1-2 s), sends a bare keepalive when nothing changed, and
 * reads the server config (intervalSec, keepaliveSec, staleSec, hot, requestFull, appsSig, tokenEpoch)
 * from each response. Failures back off 1,2,4..60 s (+-20 %); 401 waits 60 s, 404 waits 30 s and the
 * next push is full. Against a v1 PC (no "proto":2 in the response) it falls back to the v1 behaviour:
 * apps sent whole, full resend every 5 min, fixed 5 s keepalive.
 *
 * No self-ADB session is opened here: the local shell probes (ADR-0046, [ProbeEngine] over the one
 * [ShellSession]) feed controllers, CPU/GPU/skin temperature and the refresh rate into the collector.
 * A withdrawn probe is announced as "unknown"; every [fullResendMs] a periodic full push is sent.
 */
class TelemetryReporter(private val ctx: Context) {

    @Volatile private var loop: Loop? = null
    @Volatile private var reportUrl: String = ""
    @Volatile private var intervalSec: Int = 1

    fun start() {
        reload()
        if (reportUrl.isBlank()) { stop(); return }
        if (loop != null) return
        loop = Loop().also { it.begin() }
    }

    fun stop() {
        val l = loop ?: return
        loop = null
        l.end()
    }

    /** Re-read the prefs; (re)start or stop if the target changed. */
    fun reconfigure() {
        val oldUrl = reportUrl
        reload()
        val l = loop
        when {
            reportUrl.isBlank() -> stop()
            l == null -> start()
            reportUrl != oldUrl -> l.urlChanged()
        }
    }

    private fun reload() {
        val p = SelfAdb.dpCtx(ctx).getSharedPreferences(BootReceiver.PREFS_NAME, Context.MODE_PRIVATE)
        reportUrl = (p.getString(PREF_REPORT_URL, "") ?: "").trim().takeIf { isValidReportUrl(it) } ?: ""
        val iv = p.getInt(PREF_REPORT_INTERVAL, 1)
        intervalSec = if (iv < 1) 1 else iv
    }

    private inner class Loop {
        private val gson = Gson()   // cap and other objects: null entries dropped as before
        private val gsonNulls = com.google.gson.GsonBuilder().serializeNulls().create()   // POST body: null = known-absent field
        private val rnd = Random()
        private val thread = HandlerThread("vrhm-telemetry")
        private lateinit var handler: Handler
        private lateinit var collector: TelemetryCollector
        @Volatile private var alive = false

        private val run = UUID.randomUUID().toString().replace("-", "").substring(0, 8)
        private var seq = 0L

        // Acked state (diff base)
        private val acked = HashMap<String, Any>()
        private var ackedApps: Map<String, String> = emptyMap()   // pkg -> version
        private var ackedAppsSig = ""
        private var ackedCap = ""
        private var forcedAppsSig = ""
        private var forcedAppsAt = 0L

        // Negotiated / server config
        private var proto2 = false
        private var needFull = true
        private var serverIntervalSec = this@TelemetryReporter.intervalSec
        private var serverKeepaliveSec = 5
        private var serverAppsSig: String? = null
        private var hot = false
        private var fullResendMs = 300_000L

        // Timing (elapsedRealtime)
        private var lastAttemptAt = 0L
        private var lastOkAt = 0L
        private var lastFullAt = 0L
        private var blockedUntil = 0L
        private var fails = 0
        private var lastRtt = 0L

        private val pumpR = Runnable { pump() }

        fun begin() {
            alive = true
            thread.start()
            handler = Handler(thread.looper)
            collector = TelemetryCollector(ctx.applicationContext, handler) { wake() }
            Status.reset(run)
            collector.start()
        }

        fun end() {
            alive = false
            try { collector.stop() } catch (_: Throwable) {}
            try { handler.removeCallbacksAndMessages(null) } catch (_: Throwable) {}
            try { thread.quitSafely() } catch (_: Throwable) {}
        }

        fun urlChanged() {
            if (!alive) return
            handler.post { needFull = true; blockedUntil = 0L; proto2 = false; pump() }
        }

        /** Something changed (collector thread = this thread): re-evaluate, coalesced by the min gap. */
        private fun wake() {
            if (!alive) return
            handler.removeCallbacks(pumpR)
            handler.post(pumpR)
        }

        private fun now() = SystemClock.elapsedRealtime()

        private fun scheduleAt(t: Long) {
            handler.removeCallbacks(pumpR)
            handler.postDelayed(pumpR, maxOf(1L, t - now()))
        }

        private fun keepaliveMs(): Long {
            if (!proto2) return 5_000L
            val base = serverKeepaliveSec.coerceIn(2, 120)
            val s = when {
                hot || collector.isInteractive() -> base
                collector.isCharging() -> maxOf(base, 60)
                else -> maxOf(base, 30)
            }
            return s * 1000L
        }

        private fun minGapMs(): Long {
            val bat = collector.values["battery"]?.v as? Int
            val own = if (hot || (collector.isCharging() && (bat == null || bat < 100))) 1000L else 2000L
            return maxOf(own, serverIntervalSec.coerceIn(1, 60) * 1000L)
        }

        private inner class Built(val body: JsonObject, val changed: Boolean, val sentFields: Map<String, Any>,
                            val appsSnap: Map<String, String>?, val appsSig: String?, val capJson: String?,
                            val unknownSent: List<String>)

        private fun build(full: Boolean, periodic: Boolean): Built {
            val body = JsonObject()
            val t = now()
            body.addProperty("proto", 2)
            body.addProperty("serial", DeviceInfo.getSerial(ctx))
            body.addProperty("run", run)
            body.addProperty("seq", seq + 1)
            body.addProperty("full", full)
            if (periodic) body.addProperty("periodic", true)
            var changed = full
            val sent = LinkedHashMap<String, Any>()
            val age = JsonObject()
            for ((k, o) in collector.values) {
                if (full || acked[k] != o.v) {
                    addField(body, k, o.v); sent[k] = o.v
                    age.addProperty(k, maxOf(0L, t - o.at))
                    changed = true
                }
            }
            if (sent.isNotEmpty()) body.add("age", age)

            // Fields a probe no longer delivers: the PC hands them back to its ADB fallback.
            if (full) collector.withdrawn.clear()
            val unk = if (full) emptyList() else collector.withdrawn.toList()
            if (unk.isNotEmpty()) {
                val ua = JsonArray(); unk.forEach { ua.add(it) }
                body.add("unknown", ua); changed = true
            }
            if (lastRtt > 0) body.addProperty("rtt", lastRtt)

            // Capability block: on full pushes and when it changed.
            val capJson = gson.toJson(collector.capabilities((keepaliveMs() / 1000).toInt()))
            var capOut: String? = null
            if (full || capJson != ackedCap) {
                body.add("cap", JsonParser.parseString(capJson)); capOut = capJson; changed = true
            }

            // Apps: only on change (or full / when the PC asks by signature).
            val ourSig = collector.appsSig
            var snap: Map<String, String>? = null
            var sigOut: String? = null
            if (ourSig.isNotEmpty()) {
                val cur = collector.appsMap
                if (periodic) body.addProperty("appsSig", ourSig)
                val pcDiffers = proto2 && serverAppsSig != null && serverAppsSig != ourSig
                val needList = (full && !periodic) || !proto2 && ourSig != ackedAppsSig ||
                    (pcDiffers && !(forcedAppsSig == ourSig && t - forcedAppsAt < 600_000L))
                if (needList) {
                    body.addProperty("appsSig", ourSig)
                    body.add("apps", appsArray(cur.keys))
                    snap = cur.mapValues { it.value.version }; sigOut = ourSig; changed = true
                    if (pcDiffers) { forcedAppsSig = ourSig; forcedAppsAt = t }
                } else if (proto2 && ourSig != ackedAppsSig) {
                    val add = cur.keys.filter { ackedApps[it] != cur[it]!!.version }
                    val del = ackedApps.keys.filter { !cur.containsKey(it) }
                    body.addProperty("appsSig", ourSig)
                    body.add("appsAdd", appsArray(add))
                    val da = JsonArray(); del.forEach { da.add(it) }
                    body.add("appsDel", da)
                    snap = cur.mapValues { it.value.version }; sigOut = ourSig; changed = true
                }
            }
            return Built(body, changed, sent, snap, sigOut, capOut, unk)
        }

        private fun appsArray(pkgs: Collection<String>): JsonArray {
            val arr = JsonArray()
            for (p in pkgs) {
                val a = collector.appsMap[p] ?: continue
                val o = JsonObject()
                o.addProperty("pkg", p); o.addProperty("version", a.version); o.addProperty("label", a.label)
                arr.add(o)
            }
            return arr
        }

        private fun pump() {
            if (!alive) return
            val url = this@TelemetryReporter.reportUrl
            if (url.isBlank()) return
            val t = now()
            if (t < blockedUntil) { scheduleAt(blockedUntil); return }

            val periodic = !needFull && t - lastFullAt > fullResendMs
            val full = needFull || periodic
            val b = build(full, periodic)
            val keepaliveDue = t - lastOkAt >= keepaliveMs()
            if (!b.changed && !keepaliveDue) { scheduleAt(lastOkAt + keepaliveMs()); return }
            if (b.changed && !full && t - lastAttemptAt < minGapMs()) { scheduleAt(lastAttemptAt + minGapMs()); return }

            lastAttemptAt = t
            val r = post(url, b.body)
            if (!alive) return
            val t2 = now()
            if (r.code in 200..299) {
                lastOkAt = t2; fails = 0; lastRtt = t2 - t
                if (full) { lastFullAt = t2; needFull = false }
                for ((k, v) in b.sentFields) acked[k] = v
                if (full) acked.keys.retainAll(collector.values.keys)
                if (b.unknownSent.isNotEmpty()) {
                    acked.keys.removeAll(b.unknownSent.toSet())
                    collector.withdrawn.removeAll(b.unknownSent.toSet())
                }
                b.appsSnap?.let { ackedApps = it }
                b.appsSig?.let { ackedAppsSig = it }
                b.capJson?.let { ackedCap = it }
                seq++
                applyConfig(r.json)
                Status.ok(seq, proto2, serverKeepaliveSec, hot)
                // More to send right away (changes that arrived during the call)?
                scheduleAt(t2 + minGapMs())
            } else {
                val wait: Long
                when (r.code) {
                    401 -> { wait = 60_000L; Status.authFailure(); Status.error("401 unauthorized") }
                    404 -> { wait = 30_000L; needFull = true; Status.error("404 unknown serial") }
                    else -> {
                        fails++
                        val base = minOf(60L, 1L shl minOf(fails - 1, 6)) * 1000L
                        wait = (base * (0.8 + rnd.nextDouble() * 0.4)).toLong()
                        Status.error(r.err ?: ("http " + r.code))
                    }
                }
                blockedUntil = t2 + wait
                scheduleAt(blockedUntil)
            }
        }

        private fun applyConfig(j: JsonObject?) {
            val p = j?.get("proto")?.takeIf { it.isJsonPrimitive }?.asInt ?: 0
            if (p >= 2) {
                proto2 = true
                j!!.get("intervalSec")?.takeIf { it.isJsonPrimitive }?.asInt?.let { serverIntervalSec = it }
                j.get("keepaliveSec")?.takeIf { it.isJsonPrimitive }?.asInt?.let { serverKeepaliveSec = it }
                j.get("staleSec")?.takeIf { it.isJsonPrimitive }?.asInt?.let { Status.staleSec = it }
                j.get("hot")?.takeIf { it.isJsonPrimitive }?.asBoolean?.let { hot = it }
                fullResendMs = (j.get("fullResendMin")?.takeIf { it.isJsonPrimitive }?.asInt?.coerceIn(1, 60) ?: 5) * 60_000L
                applyProbeControl(j)
                if (j.get("requestFull")?.takeIf { it.isJsonPrimitive }?.asBoolean == true) needFull = true
                serverAppsSig = j.get("appsSig")?.takeIf { it.isJsonPrimitive }?.asString
                j.get("tokenEpoch")?.takeIf { it.isJsonPrimitive }?.asInt?.let { storeEpoch(it) }
            } else {
                proto2 = false   // PC rolled back (or v1): own full resend, fixed keepalive
                fullResendMs = 300_000L
                serverAppsSig = null
            }
        }

        /** probesEnabled / probes (local-probes.md section 7); unknown keys and ids are ignored by the engine. */
        private fun applyProbeControl(j: JsonObject) {
            try {
                val en = j.get("probesEnabled")?.takeIf { it.isJsonPrimitive }?.asBoolean
                var ov: MutableMap<String, Pair<Boolean?, Int?>>? = null
                val po = j.get("probes")?.takeIf { it.isJsonObject }?.asJsonObject
                if (po != null) {
                    ov = HashMap()
                    for ((id, v) in po.entrySet()) {
                        if (!v.isJsonObject) continue
                        val o = v.asJsonObject
                        ov[id] = Pair(
                            o.get("enabled")?.takeIf { it.isJsonPrimitive }?.asBoolean,
                            o.get("everySec")?.takeIf { it.isJsonPrimitive }?.asInt
                        )
                    }
                } else if (j.has("probesEnabled")) ov = HashMap()   // a v2 PC without overrides = catalogue defaults
                ProbeEngine.applyControl(en, ov)
            } catch (_: Throwable) {}
        }

        private fun storeEpoch(e: Int) {
            try {
                SelfAdb.dpCtx(ctx.applicationContext).getSharedPreferences(TokenConfig.PREFS, Context.MODE_PRIVATE)
                    .edit().putInt(PREF_TOKEN_EPOCH, e).apply()
                Status.tokenEpoch = e
            } catch (_: Throwable) {}
        }

        private fun addField(o: JsonObject, key: String, value: Any) {
            when (value) {
                is Absent -> o.add(key, com.google.gson.JsonNull.INSTANCE)
                is Boolean -> o.addProperty(key, value)
                is Int -> o.addProperty(key, value)
                is Long -> o.addProperty(key, value)
                is Double -> o.addProperty(key, value)
                else -> o.addProperty(key, value.toString())
            }
        }

        private inner class Resp(val code: Int, val json: JsonObject?, val err: String?)

        /** Keep-alive POST: the body is read to the end and the connection is NOT disconnected. */
        private fun post(url: String, body: JsonObject): Resp {
            var c: HttpURLConnection? = null
            return try {
                val bytes = gsonNulls.toJson(body).toByteArray(Charsets.UTF_8)
                c = (URL(url).openConnection() as HttpURLConnection).apply {
                    requestMethod = "POST"
                    connectTimeout = 3000
                    readTimeout = 4000
                    doOutput = true
                    setFixedLengthStreamingMode(bytes.size)
                    setRequestProperty("Content-Type", "application/json")
                    TokenConfig.token(ctx)?.let { setRequestProperty("X-VRHM-Token", it) }
                    try {
                        val ep = SelfAdb.dpCtx(ctx.applicationContext)
                            .getSharedPreferences(TokenConfig.PREFS, Context.MODE_PRIVATE).getInt(PREF_TOKEN_EPOCH, -1)
                        if (ep >= 0) setRequestProperty("X-VRHM-Token-Epoch", ep.toString())
                    } catch (_: Throwable) {}
                }
                c.outputStream.use { it.write(bytes) }
                val code = c.responseCode
                val stream = if (code >= 400) c.errorStream else c.inputStream
                val text = stream?.bufferedReader(Charsets.UTF_8)?.use { it.readText() } ?: ""
                val j = try { JsonParser.parseString(text).takeIf { it.isJsonObject }?.asJsonObject } catch (_: Throwable) { null }
                Resp(code, j, null)
            } catch (e: Throwable) {
                try { c?.disconnect() } catch (_: Throwable) {}   // drop a broken socket only
                Resp(-1, null, e.javaClass.simpleName + ": " + (e.message ?: ""))
            }
        }
    }

    /** Process-wide reporter status, read by HttpApiServer /status. */
    object Status {
        @Volatile var run = ""
        @Volatile var seq = 0L
        @Volatile var proto = 1
        @Volatile var keepaliveSec = 5
        @Volatile var staleSec = 0
        @Volatile var hot = false
        @Volatile var tokenEpoch = -1
        @Volatile var lastPushOk = 0L        // epoch ms
        @Volatile var lastError = ""
        @Volatile var lastErrorAt = 0L
        @Volatile var authFailures = 0
        @Volatile var pushes = 0L

        fun reset(r: String) { run = r; seq = 0; pushes = 0; lastError = "" }
        fun ok(s: Long, p2: Boolean, ka: Int, h: Boolean) {
            seq = s; proto = if (p2) 2 else 1; keepaliveSec = ka; hot = h
            lastPushOk = System.currentTimeMillis(); authFailures = 0; lastError = ""; pushes++
        }
        fun error(m: String) { lastError = m; lastErrorAt = System.currentTimeMillis() }
        fun authFailure() { authFailures++ }

        fun asMap(): Map<String, Any?> = linkedMapOf(
            "run" to run, "seq" to seq, "proto" to proto, "pushes" to pushes,
            "lastPushOk" to lastPushOk, "lastError" to lastError, "lastErrorAt" to lastErrorAt,
            "authFailures" to authFailures, "keepaliveSec" to keepaliveSec, "staleSec" to staleSec,
            "hot" to hot, "tokenEpoch" to tokenEpoch
        )
    }

    companion object {
        // The running reporter, so HttpApiServer.serveSettings can reconfigure it on a settings POST.
        @Volatile var active: TelemetryReporter? = null
        fun notifySettingsChanged() { try { active?.reconfigure() } catch (_: Throwable) {} }

        /** True only for an http/https URL with a non-empty host (no file:, content:, etc.). */
        fun isValidReportUrl(url: String?): Boolean {
            if (url.isNullOrBlank()) return false
            return try {
                val u = URL(url.trim())
                val proto = u.protocol?.lowercase()
                (proto == "http" || proto == "https") && !u.host.isNullOrBlank()
            } catch (_: Throwable) { false }
        }

        const val PREF_REPORT_URL = "report_url"
        const val PREF_REPORT_INTERVAL = "report_interval_sec"
        const val PREF_TOKEN_EPOCH = "token_epoch"
    }
}
