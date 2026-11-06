package com.vrheadsetmanager.companion

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.os.BatteryManager
import android.os.Handler
import android.os.HandlerThread
import com.google.gson.Gson
import com.google.gson.JsonArray
import com.google.gson.JsonObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest

/**
 * ADR-0042: pushes this headset's telemetry to VRHM's POST /api/companion/telemetry so the PC does
 * not have to poll it over ADB. Values: battery / charging / headset + CPU/GPU/skin temperature /
 * controller batteries / foreground app / installed apps + versions.
 *
 * Delta protocol: the first POST after a (re)start carries everything (full=true) and replaces the
 * stored set; afterwards only changed fields are sent. A keepalive (bare {serial, full:false}) is
 * sent at least every KEEPALIVE_MS so VRHM's staleness window never expires while nothing changes.
 *
 * Cheap reads (battery, temperatures via /sys and BatteryManager, apps via PackageManager) run on
 * the tick interval. Controller batteries and the foreground app need a shell, so they are read
 * over self-ADB at a slower sub-cadence and cached (a failed read just keeps the last value).
 *
 * Started/reconfigured by CompanionService from the device-protected prefs report_url /
 * report_interval_sec (written by HttpApiServer.serveSettings). The POST carries the per-fleet
 * token in X-VRHM-Token.
 */
class TelemetryReporter(private val ctx: Context) {

    private var thread: HandlerThread? = null
    private var handler: Handler? = null
    @Volatile private var running = false
    private val gson = Gson()

    private var reportUrl: String = ""
    private var intervalMs: Long = 1000
    private var serial: String = ""

    // Last values actually sent (for the delta); last apps signature; timing.
    private val lastSent = HashMap<String, Any?>()
    private var lastAppsSig = ""
    private var lastFullAt = 0L
    private var lastPostAt = 0L
    private var tick = 0L

    // Cached control-read results (controllers + foreground), refreshed over self-ADB slowly.
    private var ctrlLeft: Int? = null
    private var ctrlRight: Int? = null
    private var foregroundApp: String? = null

    // Persistent self-ADB session of the control read, and when the next read is due (elapsedRealtime).
    private var controlMgr: io.github.muntashirakon.adb.AbsAdbConnectionManager? = null
    private var nextControlAt = 0L
    private var controlFailures = 0

    fun start() {
        reload()
        if (reportUrl.isBlank()) { stop(); return }
        if (running) return
        running = true
        val t = HandlerThread("vrhm-telemetry").also { it.start() }
        thread = t
        handler = Handler(t.looper)
        serial = DeviceInfo.getSerial()
        lastSent.clear(); lastAppsSig = ""; lastFullAt = 0L; lastPostAt = 0L; tick = 0L
        schedule(0)
    }

    fun stop() {
        running = false
        dropControlSession()
        nextControlAt = 0L; controlFailures = 0
        try { handler?.removeCallbacksAndMessages(null) } catch (_: Throwable) {}
        try { thread?.quitSafely() } catch (_: Throwable) {}
        thread = null; handler = null
    }

    /** Re-read the prefs; (re)start or stop the loop if the target or interval changed. */
    fun reconfigure() {
        val oldUrl = reportUrl; val oldInterval = intervalMs
        reload()
        when {
            reportUrl.isBlank() -> stop()
            !running -> start()
            reportUrl != oldUrl || intervalMs != oldInterval -> { stop(); start() }
        }
    }

    private fun reload() {
        val p = SelfAdb.dpCtx(ctx).getSharedPreferences(BootReceiver.PREFS_NAME, Context.MODE_PRIVATE)
        // A stored URL that is not http(s) with a host is treated as "no target" (reporting off).
        reportUrl = (p.getString(PREF_REPORT_URL, "") ?: "").trim().takeIf { isValidReportUrl(it) } ?: ""
        val iv = p.getInt(PREF_REPORT_INTERVAL, 1)
        intervalMs = (if (iv < 1) 1 else iv).toLong() * 1000L
    }

    private fun schedule(delay: Long) {
        val h = handler ?: return
        h.postDelayed({
            if (running) {
                try { tickOnce() } catch (_: Throwable) {}
                schedule(intervalMs)
            }
        }, delay)
    }

    private fun tickOnce() {
        if (reportUrl.isBlank()) return
        tick++

        // Control read (controllers + foreground) over self-ADB at a slower cadence.
        val nowMs = android.os.SystemClock.elapsedRealtime()
        if (nowMs >= nextControlAt) { readControlOverAdb() }

        val cur = collect()
        val now = System.currentTimeMillis()
        val isFull = lastSent.isEmpty() || (now - lastFullAt) > FULL_EVERY_MS

        val body = JsonObject()
        body.addProperty("serial", serial)
        var changed = false

        if (isFull) {
            for ((k, v) in cur) addField(body, k, v)
            body.addProperty("full", true)
            changed = true
        } else {
            for ((k, v) in cur) {
                if (lastSent[k] != v) { addField(body, k, v); changed = true }
            }
            body.addProperty("full", false)
        }

        // Apps (package + version): sent whole when the set/versions changed, or on a full push.
        val apps = collectApps()
        if (isFull || apps.first != lastAppsSig) {
            body.add("apps", apps.second)
            changed = true
        }

        // Keepalive when nothing changed, so VRHM keeps the push "fresh".
        val keepalive = (now - lastPostAt) >= KEEPALIVE_MS
        if (!changed && !keepalive) return

        if (post(body)) {
            lastPostAt = now
            if (isFull) lastFullAt = now
            for ((k, v) in cur) lastSent[k] = v
            if (isFull || apps.first != lastAppsSig) lastAppsSig = apps.first
        }
    }

    /** Current cheap telemetry (no shell). Null fields are omitted from the push. */
    private fun collect(): LinkedHashMap<String, Any?> {
        val m = LinkedHashMap<String, Any?>()
        val bat = readBattery()
        m["battery"] = bat.level
        m["charging"] = bat.charging
        if (bat.tempC != null) m["temp"] = bat.tempC
        val th = readThermals()
        if (th.cpu != null) m["cpuTemp"] = th.cpu
        if (th.gpu != null) m["gpuTemp"] = th.gpu
        if (th.skin != null) m["skinTemp"] = th.skin
        if (ctrlLeft != null) m["ctrlLeft"] = ctrlLeft
        if (ctrlRight != null) m["ctrlRight"] = ctrlRight
        if (!foregroundApp.isNullOrBlank()) m["foregroundApp"] = foregroundApp
        return m
    }

    private data class Battery(val level: Int?, val charging: Boolean, val tempC: Double?)

    private fun readBattery(): Battery {
        return try {
            val intent = ctx.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            val level = intent?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
            val scale = intent?.getIntExtra(BatteryManager.EXTRA_SCALE, 100) ?: 100
            val status = intent?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
            val tempRaw = intent?.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, -1) ?: -1
            Battery(
                level = if (level >= 0 && scale > 0) level * 100 / scale else null,
                charging = (status == BatteryManager.BATTERY_STATUS_CHARGING || status == BatteryManager.BATTERY_STATUS_FULL),
                tempC = if (tempRaw > 0) tempRaw / 10.0 else null
            )
        } catch (_: Throwable) { Battery(null, false, null) }
    }

    private data class Thermals(val cpu: Double?, val gpu: Double?, val skin: Double?)

    /** Best-effort CPU/GPU/skin from /sys/class/thermal (max per family). Needs headset validation. */
    private fun readThermals(): Thermals {
        var cpu: Double? = null; var gpu: Double? = null; var skin: Double? = null
        try {
            File("/sys/class/thermal").listFiles()
                ?.filter { it.name.startsWith("thermal_zone") }
                ?.forEach { zone ->
                    val tf = File(zone, "temp"); if (!tf.exists()) return@forEach
                    val milli = tf.readText().trim().toLongOrNull() ?: return@forEach
                    val c = milli / 1000.0
                    if (c <= 0.0 || c > 150.0) return@forEach
                    val type = (File(zone, "type").takeIf { it.exists() }?.readText()?.trim() ?: "").lowercase()
                    when {
                        type.contains("cpu") -> if (cpu == null || c > cpu!!) cpu = c
                        type.contains("gpu") -> if (gpu == null || c > gpu!!) gpu = c
                        type.contains("skin") || type.contains("skt") -> if (skin == null || c > skin!!) skin = c
                    }
                }
        } catch (_: Throwable) {}
        fun r(d: Double?) = d?.let { Math.round(it * 10.0) / 10.0 }
        return Thermals(r(cpu), r(gpu), r(skin))
    }

    /** Installed user apps with versions, plus a stable signature of (pkg@version) for change detection. */
    private fun collectApps(): Pair<String, JsonArray> {
        val arr = JsonArray()
        val sb = StringBuilder()
        try {
            val pm = ctx.packageManager
            val apps = pm.getInstalledApplications(PackageManager.GET_META_DATA)
                .filter { (it.flags and ApplicationInfo.FLAG_SYSTEM) == 0 }
                .sortedBy { it.packageName }
            for (app in apps) {
                val pkg = app.packageName
                val version = try { pm.getPackageInfo(pkg, 0).versionName ?: "" } catch (_: Throwable) { "" }
                val label = try { pm.getApplicationLabel(app).toString() } catch (_: Throwable) { pkg }
                val o = JsonObject()
                o.addProperty("pkg", pkg)
                o.addProperty("version", version)
                o.addProperty("label", label)
                arr.add(o)
                sb.append(pkg).append('@').append(version).append(';')
            }
        } catch (_: Throwable) {}
        val sig = try {
            MessageDigest.getInstance("MD5").digest(sb.toString().toByteArray())
                .joinToString("") { "%02x".format(it) }
        } catch (_: Throwable) { sb.toString() }
        return Pair(sig, arr)
    }

    /** Reads the controllers + foreground app over self-ADB in ONE short session. Best-effort. */
    private fun readControlOverAdb() {
        // Pico has no usable self-ADB shell (see AdbBootManager.isPico): telemetry-only there, so we
        // never open a self-ADB session - it would only fail and churn. Battery/thermals/storage/wifi
        // still come from the Android APIs; controllers and foreground app are simply not reported.
        if (AdbBootManager.isPico()) return
        // ONE persistent self-ADB session, reused between reads. A fresh connect per read (the old
        // behaviour, every ~5 s) made Horizon raise the "Allow USB debugging?" popup each time the
        // companion key was not trusted yet. A failed connect backs off (30 s doubling to 10 min) so
        // an untrusted key raises the popup at most once per backoff window, not continuously.
        var mgr = controlMgr
        if (mgr == null || !isSessionAlive(mgr)) {
            try { mgr?.disconnect() } catch (_: Throwable) {}
            controlMgr = null
            AdbBootManager.log("control read: opening self-ADB session")
            mgr = try { AdbBootManager.selfConnect(ctx) } catch (_: Throwable) { null }
            if (mgr == null) {
                controlFailures++
                val wait = minOf(CONTROL_BACKOFF_MAX_MS, CONTROL_BACKOFF_MIN_MS shl minOf(controlFailures - 1, 5))
                nextControlAt = android.os.SystemClock.elapsedRealtime() + wait
                AdbBootManager.log("control read: no self-ADB session, retry in ${wait / 1000} s")
                return
            }
            controlMgr = mgr
            controlFailures = 0
        }
        nextControlAt = android.os.SystemClock.elapsedRealtime() + CONTROL_EVERY_MS
        try {
            val marker = "===VRHM==="
            val script = "dumpsys OVRRemoteService 2>/dev/null; echo $marker; " +
                "dumpsys activity activities 2>/dev/null | grep -E 'mResumedActivity|topResumedActivity'"
            val out = AdbBootManager.runShell(mgr!!, script, 8000)
            if (out.startsWith("shell-ex")) {
                AdbBootManager.log("control read: shell failed (${out.take(80)}), dropping session")
                dropControlSession(); return
            }
            val parts = out.split(marker)
            val ctrl = parseControllers(parts.getOrElse(0) { "" })
            ctrlLeft = ctrl.first ?: ctrlLeft
            ctrlRight = ctrl.second ?: ctrlRight
            val fg = parseForeground(parts.getOrElse(1) { "" })
            if (!fg.isNullOrBlank()) foregroundApp = fg
        } catch (_: Throwable) {
            dropControlSession()
        }
    }

    private fun isSessionAlive(mgr: io.github.muntashirakon.adb.AbsAdbConnectionManager): Boolean =
        try { mgr.isConnected } catch (_: Throwable) { false }

    private fun dropControlSession() {
        try { controlMgr?.disconnect() } catch (_: Throwable) {}
        controlMgr = null
    }

    /**
     * Pulls the two controller battery levels out of `dumpsys OVRRemoteService`. The exact field
     * layout varies by firmware; this looks for "left"/"right" near a percentage and falls back to
     * the first two "battery=NN" values. TODO: align with ConvertFrom-ControllerDump on a headset.
     */
    private fun parseControllers(text: String): Pair<Int?, Int?> {
        if (text.isBlank()) return Pair(null, null)
        var left: Int? = null; var right: Int? = null
        val lineRe = Regex("(?i)(left|right)[^0-9]{0,40}?(\\d{1,3})\\s*%?")
        for (m in lineRe.findAll(text)) {
            val side = m.groupValues[1].lowercase()
            val v = m.groupValues[2].toIntOrNull() ?: continue
            if (v !in 0..100) continue
            if (side == "left" && left == null) left = v
            if (side == "right" && right == null) right = v
        }
        if (left == null && right == null) {
            val vals = Regex("(?i)battery[^0-9]{0,8}?(\\d{1,3})").findAll(text)
                .mapNotNull { it.groupValues[1].toIntOrNull()?.takeIf { n -> n in 0..100 } }.toList()
            if (vals.isNotEmpty()) left = vals[0]
            if (vals.size > 1) right = vals[1]
        }
        return Pair(left, right)
    }

    /** Pulls the foreground package out of the mResumedActivity / topResumedActivity lines. */
    private fun parseForeground(text: String): String? {
        if (text.isBlank()) return null
        val m = Regex("[uU]\\d+\\s+([a-zA-Z0-9_.]+)/").find(text)
            ?: Regex("cmp=([a-zA-Z0-9_.]+)/").find(text)
        return m?.groupValues?.getOrNull(1)
    }

    private fun addField(o: JsonObject, key: String, value: Any?) {
        when (value) {
            null -> {}
            is Boolean -> o.addProperty(key, value)
            is Int -> o.addProperty(key, value)
            is Long -> o.addProperty(key, value)
            is Double -> o.addProperty(key, value)
            is Float -> o.addProperty(key, value)
            else -> o.addProperty(key, value.toString())
        }
    }

    private fun post(body: JsonObject): Boolean {
        val url = reportUrl
        if (url.isBlank()) return false
        var conn: HttpURLConnection? = null
        return try {
            conn = (URL(url).openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                connectTimeout = 3000
                readTimeout = 3000
                doOutput = true
                setRequestProperty("Content-Type", "application/json")
                TokenConfig.token(ctx)?.let { setRequestProperty("X-VRHM-Token", it) }
            }
            conn.outputStream.use { it.write(gson.toJson(body).toByteArray(Charsets.UTF_8)) }
            val code = conn.responseCode
            code in 200..299
        } catch (_: Throwable) {
            false
        } finally {
            try { conn?.disconnect() } catch (_: Throwable) {}
        }
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
        private const val CONTROL_EVERY_MS = 10_000L        // controllers + foreground every 10 s on the open session
        private const val CONTROL_BACKOFF_MIN_MS = 30_000L  // first retry after a failed self-ADB connect
        private const val CONTROL_BACKOFF_MAX_MS = 600_000L // then doubling, capped at 10 min
        private const val FULL_EVERY_MS = 300_000L // resend everything every 5 min (resync)
        private const val KEEPALIVE_MS = 5_000L    // refresh freshness at least every 5 s
    }
}
