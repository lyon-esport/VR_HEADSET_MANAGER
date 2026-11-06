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
 * What is NOT collected, on purpose (the PC reads it over ADB): CPU/GPU/skin temperature (sysfs is
 * SELinux-denied on Horizon, so it is never probed in a loop) and controller batteries.
 *
 * Fields: battery, charging, temp (battery), wattage (charging only), thermalStatus, headroom, rssi,
 * foregroundApp; plus the installed apps (pkg -> version/label).
 */
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
    private var wattOk = true
    private var wattBad = 0

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
        charging = status == BatteryManager.BATTERY_STATUS_CHARGING || status == BatteryManager.BATTERY_STATUS_FULL
        if (level >= 0 && scale > 0) ch = put("battery", level * 100 / scale) or ch
        ch = put("charging", charging) or ch
        if (tempRaw > 0) ch = put("temp", tempRaw / 10.0) or ch
        ch = updateWattage() or ch
        if (ch) onChange()
    }

    /** current_now x voltage, only while charging. Units/sign vary by vendor (VOD): implausible = never sent. */
    private fun updateWattage(): Boolean {
        if (!wattOk) return false
        if (!charging) return putNum("wattage", 0.0, 0.0)
        return try {
            val bm = ctx.getSystemService(Context.BATTERY_SERVICE) as BatteryManager
            val raw = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CURRENT_NOW)
            if (raw == Int.MIN_VALUE || raw == 0 || voltageMv <= 0) return false
            val a = Math.abs(raw.toDouble())
            val amps = if (a > 20000.0) a / 1e6 else a / 1e3
            val w = Math.round(amps * voltageMv / 1000.0 * 10.0) / 10.0
            if (w < 0.1 || w > 100.0) {
                if (++wattBad >= 3) wattOk = false
                false
            } else { wattBad = 0; putNum("wattage", w, 0.5) }
        } catch (_: Throwable) { wattOk = false; false }
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
            if (charging && updateWattage()) onChange()
        }
        if (tick % 40 == 0) { if (refreshApps()) onChange() }   // 10 min safety check
        if (foregroundMode() == "usage") queryUsageForeground()
    }

    // ---- capability block ---------------------------------------------------------------------

    fun isInteractive(): Boolean = try { pm.isInteractive } catch (_: Throwable) { true }
    fun isCharging(): Boolean = charging

    fun capabilities(keepaliveSec: Int): Map<String, Any?> = linkedMapOf(
        "brand" to Build.MANUFACTURER,
        "model" to Build.MODEL,
        "appVersion" to BuildConfig.VERSION_NAME,
        "versionCode" to BuildConfig.VERSION_CODE,
        "hasTls" to !AdbBootManager.isPico(),
        "canSelfAdb" to !AdbBootManager.isPico(),
        "canReadControllers" to false,
        "canForeground" to foregroundMode(),
        "canThermal" to if (headroomSeen) "headroom" else "battery",
        "canWattage" to wattOk,
        "serialSource" to DeviceInfo.serialSource(ctx),
        "keepAwake" to KeepAwake.status(ctx),
        "keepaliveSec" to keepaliveSec
    )

    companion object {
        private const val PERIODIC_MS = 15_000L
        @Volatile private var instance: TelemetryCollector? = null
        @Volatile var a11yConnected = false
        @Volatile var a11yEvents = 0L

        /** Called by ApproveService on every window-state event (cheap: it just posts). */
        fun onWindowEvent(pkg: String?) { try { instance?.postWindow(pkg) } catch (_: Throwable) {} }
    }
}
