package com.vrheadsetmanager.companion

import android.app.AppOpsManager
import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ApplicationInfo
import android.net.wifi.WifiManager
import android.os.BatteryManager
import android.os.Build
import android.os.Handler
import android.os.PowerManager
import android.os.Process
import android.os.SystemClock
import android.view.inputmethod.InputMethodManager
import java.security.MessageDigest
import java.util.concurrent.Executor

/**
 * Telemetry v2 collectors (docs/improvement_plan/companion-hardening/telemetry-v2.md, section 1).
 *
 * Everything here runs on ONE thread: the Handler passed in (the reporter's owner thread). Receivers
 * and listeners are registered on that handler, so [values] and the apps state need no locking.
 * A reading overwrites the previous one (latest-value map, no queue); [onChange] tells the reporter
 * something moved so it can coalesce and send.
 *
 * CPU/GPU/skin temperature, controllers and the display refresh rate come from the local shell
 * probes ([ProbeEngine], ADR-0046) through [applyProbe]; sysfs is SELinux-denied on Horizon.
 *
 * Fields: battery, charging, temp (battery), sourceW (charger rating), battW (signed, + into battery), thermalStatus, headroom, rssi,
 * foregroundApp; plus the installed apps (pkg -> version/label).
 */
/** Known-absent marker: travels as JSON null (e.g. controller not connected, refresh not forced). */
object Absent

class TelemetryCollector(
    private val ctx: Context,
    private val handler: Handler,
    private val onChange: () -> Unit
) {
    class Obs(val v: Any, val at: Long)
    class AppInfo(val version: String, val label: String)

    /** Latest value per wire field. Owner-thread only. */
    val values = LinkedHashMap<String, Obs>()
    var appsMap: Map<String, AppInfo> = emptyMap()
        private set
    var appsSig: String = ""
        private set

    @Volatile private var stopped = false
    private var started = false

    private val pm = ctx.getSystemService(Context.POWER_SERVICE) as PowerManager
    private val ownPkg = ctx.packageName

    // Battery bookkeeping
    private var charging = false
    private var voltageMv = 0
    private var srcOk = true
    private var battOk = true
    private var battBad = 0
    private var lastMaxCurrentUa = 0
    private var lastMaxVoltageUv = 0
    private var lastStatus = -1
    private var signMul = 1
    private var signConfirmed = false
    private var cntRefUah = 0L
    private var cntRefAt = 0L

    // Thermal
    private var headroomSeen = false
    private var headroomFail = 0
    private var thermalListener: PowerManager.OnThermalStatusChangedListener? = null

    // Foreground
    private var pendingPkg: String? = null
    private var imePkgs: Set<String> = emptySet()
    private var imeAt = 0L
    private var lastUsageQuery = 0L

    private var tick = 0

    /** Wire fields the engine withdrew (probe stopped working); the reporter sends them as "unknown". */
    val withdrawn = LinkedHashSet<String>()

    private val batteryReceiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context?, i: Intent?) { if (!stopped && i != null) handleBattery(i) }
    }
    private val packageReceiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context?, i: Intent?) {
            if (stopped) return
            // Debounce a burst (an update fires REMOVED + ADDED + REPLACED).
            handler.removeCallbacks(appsRefreshR)
            handler.postDelayed(appsRefreshR, 2000)
        }
    }
    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context?, i: Intent?) { if (!stopped) onChange() }
    }

    private val appsRefreshR = Runnable { if (!stopped && refreshApps()) onChange() }
    private val fgR = Runnable {
        val p = pendingPkg
        if (!stopped && p != null && acceptForeground(p) && put("foregroundApp", p)) onChange()
    }
    private val periodicR = object : Runnable {
        override fun run() {
            if (stopped) return
            try { periodic() } catch (_: Throwable) {}
            handler.postDelayed(this, PERIODIC_MS)
        }
    }

    fun start() {
        handler.post {
            if (stopped || started) return@post
            started = true
            instance = this
            try {
                ctx.registerReceiver(batteryReceiver, IntentFilter(Intent.ACTION_BATTERY_CHANGED), null, handler)
                    ?.let { handleBattery(it) }
            } catch (_: Throwable) {}
            try {
                val f = IntentFilter().apply {
                    addAction(Intent.ACTION_PACKAGE_ADDED); addAction(Intent.ACTION_PACKAGE_REMOVED)
                    addAction(Intent.ACTION_PACKAGE_REPLACED); addDataScheme("package")
                }
                ctx.registerReceiver(packageReceiver, f, null, handler)
            } catch (_: Throwable) {}
            try {
                val f = IntentFilter().apply { addAction(Intent.ACTION_SCREEN_ON); addAction(Intent.ACTION_SCREEN_OFF) }
                ctx.registerReceiver(screenReceiver, f, null, handler)
            } catch (_: Throwable) {}
            try {
                val l = PowerManager.OnThermalStatusChangedListener { s ->
                    if (!stopped && put("thermalStatus", s)) onChange()
                }
                pm.addThermalStatusListener(Executor { r -> handler.post(r) }, l)
                thermalListener = l
                put("thermalStatus", pm.currentThermalStatus)
            } catch (_: Throwable) {}
            refreshApps()
            readHeadroom(); readRssi()
            handler.postDelayed(periodicR, PERIODIC_MS)
            onChange()
        }
    }

    fun stop() {
        stopped = true
        if (instance === this) instance = null
        handler.removeCallbacks(periodicR); handler.removeCallbacks(appsRefreshR); handler.removeCallbacks(fgR)
        try { ctx.unregisterReceiver(batteryReceiver) } catch (_: Throwable) {}
        try { ctx.unregisterReceiver(packageReceiver) } catch (_: Throwable) {}
        try { ctx.unregisterReceiver(screenReceiver) } catch (_: Throwable) {}
        try { thermalListener?.let { pm.removeThermalStatusListener(it) } } catch (_: Throwable) {}
        thermalListener = null
    }

    // ---- latest-value map ---------------------------------------------------------------------

    /** @return true when the stored value changed. */
    private fun put(name: String, v: Any): Boolean {
        val cur = values[name]
        if (cur != null && cur.v == v) return false
        values[name] = Obs(v, SystemClock.elapsedRealtime())
        return true
    }

    private fun putNum(name: String, v: Double, minDelta: Double): Boolean {
        val cur = values[name]?.v as? Double
        if (cur != null && Math.abs(cur - v) < minDelta) return false
        return put(name, v)
    }

    // ---- battery / wattage --------------------------------------------------------------------

    private fun handleBattery(i: Intent) {
        var ch = false
        val level = i.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
        val scale = i.getIntExtra(BatteryManager.EXTRA_SCALE, 100)
        val status = i.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
        val tempRaw = i.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, -1)
        voltageMv = i.getIntExtra(BatteryManager.EXTRA_VOLTAGE, 0)
        val plugBits = i.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0)
        charging = plugBits != 0
        lastStatus = status
        lastMaxCurrentUa = i.getIntExtra("max_charging_current", 0)
        lastMaxVoltageUv = i.getIntExtra("max_charging_voltage", 0)
        if (level >= 0 && scale > 0) ch = put("battery", level * 100 / scale) or ch
        ch = put("charging", charging) or ch
        ch = put("plugged", BatteryPowerMapper.pluggedName(plugBits)) or ch
        ch = put("battStatus", BatteryPowerMapper.statusName(status)) or ch
        try {
            val bm = ctx.getSystemService(Context.BATTERY_SERVICE) as BatteryManager
            val uah = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CHARGE_COUNTER).toLong()
            val mah = BatteryPowerMapper.counterMah(uah)
            if (mah != null) {
                val cur = values["chargeCounterMah"]?.v as? Int
                if (cur == null || Math.abs(cur - mah) >= 20) ch = put("chargeCounterMah", mah) or ch
            }
        } catch (_: Throwable) {}
        if (tempRaw > 0) ch = put("temp", tempRaw / 10.0) or ch
        ch = updateWattage() or ch
        if (ch) onChange()
    }

    /**
     * Power source (sourceW: charger rating from the battery intent, 0 unplugged) and battery charge
     * (battW: signed, + = into the battery). Raw CURRENT_NOW sign varies by vendor, so it is
     * normalised: provisional from the status (CHARGING/DISCHARGING), then confirmed by the
     * charge-counter trend, and the decided multiplier is kept.
     */
    private fun updateWattage(): Boolean {
        var ch = false
        if (srcOk) {
            val w = if (!charging) 0.0 else {
                val a = lastMaxCurrentUa.toDouble() * lastMaxVoltageUv.toDouble() / 1e12
                Math.round(a * 10.0) / 10.0
            }
            if (w in 0.0..150.0) ch = putNum("sourceW", w, if (w == 0.0) 0.0 else 0.5) or ch
        }
        if (!battOk) return ch
        try {
            val bm = ctx.getSystemService(Context.BATTERY_SERVICE) as BatteryManager
            val raw = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CURRENT_NOW)
            if (raw == Int.MIN_VALUE || voltageMv <= 0) return ch
            val a = Math.abs(raw.toDouble())
            val amps = if (a > 20000.0) a / 1e6 else a / 1e3
            calibrateSign(bm, raw)
            val w = Math.round(signMul * Math.signum(raw.toDouble()) * amps * voltageMv / 1000.0 * 10.0) / 10.0
            if (w < -100.0 || w > 100.0) {
                if (++battBad >= 3) battOk = false
            } else { battBad = 0; ch = putNum("battW", if (raw == 0) 0.0 else w, 0.5) or ch }
        } catch (_: Throwable) { battOk = false }
        return ch
    }

    private fun calibrateSign(bm: BatteryManager, raw: Int) {
        if (raw == 0) return
        val r = if (raw > 0) 1 else -1
        // Provisional: the battery status says which way the current flows.
        if (!signConfirmed) {
            if (lastStatus == BatteryManager.BATTERY_STATUS_CHARGING) signMul = r
            else if (lastStatus == BatteryManager.BATTERY_STATUS_DISCHARGING) signMul = -r
        }
        try {
            val uah = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CHARGE_COUNTER).toLong()
            val now = SystemClock.elapsedRealtime()
            if (uah <= 0) return
            if (cntRefAt == 0L) { cntRefUah = uah; cntRefAt = now; return }
            val d = uah - cntRefUah
            if (Math.abs(d) >= 3000 && now - cntRefAt >= 60_000L) {
                signMul = (if (d > 0) 1 else -1) * r
                signConfirmed = true
                cntRefUah = uah; cntRefAt = now
            } else if (now - cntRefAt > 600_000L) { cntRefUah = uah; cntRefAt = now }
        } catch (_: Throwable) {}
    }
    // ---- local probes (ADR-0046) ------------------------------------------------------------------

    /** Posts a probe result onto the owner thread. A null value is "known absent". */
    fun applyProbe(fields: Map<String, Any?>) {
        handler.post {
            if (stopped) return@post
            var ch = false
            for ((k, v) in fields) {
                withdrawn.remove(k)
                ch = put(k, v ?: Absent) or ch
            }
            if (ch) onChange()
        }
    }

    /** A probe stopped working: its fields leave the map and are announced as "unknown". */
    fun withdraw(names: Collection<String>) {
        handler.post {
            if (stopped) return@post
            var ch = false
            for (k in names) {
                if (values.remove(k) != null) ch = true
                if (withdrawn.add(k)) ch = true
            }
            if (ch) onChange()
        }
    }

    // ---- thermal headroom / rssi --------------------------------------------------------------

    private fun readHeadroom() {
        if (Build.VERSION.SDK_INT < 30 || headroomFail >= 3) return
        try {
            val h = pm.getThermalHeadroom(10)
            if (h.isNaN() || h < 0f) { headroomFail++; return }
            headroomSeen = true
            if (putNum("headroom", Math.round(h * 100.0) / 100.0, 0.05)) onChange()
        } catch (_: Throwable) { headroomFail++ }
    }

    @Suppress("DEPRECATION")
    private fun readRssi() {
        try {
            val wm = ctx.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            val r = wm.connectionInfo?.rssi ?: return
            if (r in -127..-1 && putNum("rssi", r.toDouble(), 5.0)) onChange()
        } catch (_: Throwable) {}
    }

    // ---- foreground ---------------------------------------------------------------------------

    private fun acceptForeground(p: String): Boolean {
        if (p == ownPkg || p == "com.android.systemui" || p == "android") return false
        val now = SystemClock.elapsedRealtime()
        if (now - imeAt > 300_000L) {
            imeAt = now
            imePkgs = try {
                (ctx.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager)
                    .enabledInputMethodList.map { it.packageName }.toSet()
            } catch (_: Throwable) { emptySet() }
        }
        return p !in imePkgs
    }

    private fun postWindow(pkg: String?) {
        if (stopped || pkg.isNullOrBlank()) return
        handler.post {
            a11yEvents++
            pendingPkg = pkg
            handler.removeCallbacks(fgR)
            handler.postDelayed(fgR, 500)
        }
    }

    private fun usageAllowed(): Boolean = try {
        val ao = ctx.getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
        ao.unsafeCheckOpNoThrow("android:get_usage_stats", Process.myUid(), ownPkg) == AppOpsManager.MODE_ALLOWED
    } catch (_: Throwable) { false }

    /** "a11y", "usage" or "none". */
    fun foregroundMode(): String = when {
        a11yConnected && a11yEvents > 0 -> "a11y"
        usageAllowed() -> "usage"
        a11yConnected -> "a11y"
        else -> "none"
    }

    private fun queryUsageForeground() {
        try {
            val us = ctx.getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
            val end = System.currentTimeMillis()
            val begin = if (lastUsageQuery > 0) lastUsageQuery else end - 120_000L
            lastUsageQuery = end
            val ev = us.queryEvents(begin, end)
            val e = UsageEvents.Event()
            var last: String? = null
            while (ev.hasNextEvent()) {
                ev.getNextEvent(e)
                if (e.eventType == UsageEvents.Event.ACTIVITY_RESUMED && acceptForeground(e.packageName)) last = e.packageName
            }
            if (last != null && put("foregroundApp", last)) onChange()
        } catch (_: Throwable) {}
    }

    // ---- installed apps -----------------------------------------------------------------------

    private val labelCache = HashMap<String, String>()

    /** Rebuilds the user-app map + signature. @return true when the signature changed. */
    fun refreshApps(): Boolean {
        return try {
            val p = ctx.packageManager
            val m = LinkedHashMap<String, AppInfo>()
            for (pi in p.getInstalledPackages(0).sortedBy { it.packageName }) {
                val ai = pi.applicationInfo ?: continue
                if ((ai.flags and ApplicationInfo.FLAG_SYSTEM) != 0) continue
                val ver = pi.versionName ?: ""
                val key = pi.packageName + "@" + ver
                val label = labelCache.getOrPut(key) {
                    try { p.getApplicationLabel(ai).toString() } catch (_: Throwable) { pi.packageName }
                }
                m[pi.packageName] = AppInfo(ver, label)
            }
            val sb = StringBuilder()
            for ((k, v) in m) sb.append(k).append('@').append(v.version).append(';')
            val sig = MessageDigest.getInstance("MD5").digest(sb.toString().toByteArray())
                .joinToString("") { "%02x".format(it) }
            val changed = sig != appsSig
            appsMap = m; appsSig = sig
            changed
        } catch (_: Throwable) { false }
    }

    // ---- periodic (15 s): cheap, no network ---------------------------------------------------

    private fun periodic() {
        tick++
        if (tick % 2 == 0) {                 // every 30 s
            readHeadroom(); readRssi()
            if (updateWattage()) onChange()
        }
        if (tick % 40 == 0) { if (refreshApps()) onChange() }   // 10 min safety check
        if (foregroundMode() == "usage") queryUsageForeground()
    }

    // ---- capability block ---------------------------------------------------------------------

    fun isInteractive(): Boolean = try { pm.isInteractive } catch (_: Throwable) { true }
    fun isCharging(): Boolean = charging

    private fun brandFamily(): String = family()

    fun capabilities(keepaliveSec: Int): Map<String, Any?> = linkedMapOf(
        "family" to brandFamily(),
        "brand" to Build.MANUFACTURER,
        "model" to Build.MODEL,
        "appVersion" to BuildConfig.VERSION_NAME,
        "versionCode" to BuildConfig.VERSION_CODE,
        "hasTls" to !AdbBootManager.isPico(),
        "canSelfAdb" to !AdbBootManager.isPico(),
        "canReadControllers" to (brandFamily() == "meta" && ProbeEngine.probeStates()["controllers"] == "ok"),
        "canForeground" to foregroundMode(),
        "canThermal" to (if (ProbeEngine.probeStates()["thermal"] == "ok") "probe" else if (headroomSeen) "headroom" else "battery"),
        "canSourceW" to (srcOk && lastMaxCurrentUa > 0 || !charging),
        "canBattW" to battOk,
        "serialSource" to DeviceInfo.serialSource(ctx),
        "keepAwake" to KeepAwake.status(ctx),
        "keepaliveSec" to keepaliveSec,
        "probeCatalog" to ProbeEngine.catalogVersion(),
        "probes" to ProbeEngine.probeStates(),
        "shell" to ProbeEngine.shellState()
    )

    companion object {
        private const val PERIODIC_MS = 15_000L
        @Volatile private var instance: TelemetryCollector? = null
        @Volatile var a11yConnected = false
        @Volatile var a11yEvents = 0L

        /** Called by ApproveService on every window-state event (cheap: it just posts). */
        /** Capabilities of the live collector, or null when none runs (single source for /status). */
        fun liveCapabilities(keepaliveSec: Int): Map<String, Any?>? =
            try { instance?.capabilities(keepaliveSec) } catch (_: Throwable) { null }

        /** Brand family: pico / meta / other (same rule as the PC Get-HeadsetBrandFamily). */
        fun family(): String {
            if (AdbBootManager.isPico()) return "pico"
            val s = ((Build.MANUFACTURER ?: "") + " " + (Build.BRAND ?: "")).lowercase()
            return if (s.contains("oculus") || s.contains("meta")) "meta" else "other"
        }

        fun hasLive(): Boolean = instance != null
        fun applyProbeLive(fields: Map<String, Any?>) { try { instance?.applyProbe(fields) } catch (_: Throwable) {} }
        fun withdrawLive(names: Collection<String>) { try { instance?.withdraw(names) } catch (_: Throwable) {} }

        /** A probe state moved (cap.probes changed): wake the reporter so the cap goes out. */
        fun probeStateChangedLive() { try { instance?.let { c -> c.handler.post { if (!c.stopped) c.onChange() } } } catch (_: Throwable) {} }

        fun onWindowEvent(pkg: String?) { try { instance?.postWindow(pkg) } catch (_: Throwable) {} }
    }
}
