package com.vrheadsetmanager.companion

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.net.wifi.WifiManager
import android.os.BatteryManager
import android.os.Build
import android.os.Environment
import android.os.StatFs
import android.provider.Settings
import com.google.gson.Gson
import java.io.File

object DeviceInfo {

    private val gson = Gson()

    fun getSerial(): String {
        // ro.serialno matches what `adb devices` shows; no runtime permission needed when read-only
        return try {
            (Class.forName("android.os.SystemProperties")
                .getMethod("get", String::class.java)
                .invoke(null, "ro.serialno") as? String)
                ?.takeIf { it.isNotBlank() && it != "unknown" }
                ?: Build.UNKNOWN
        } catch (_: Exception) {
            // Fallback: Android ID is stable but not the same as ADB serial
            Settings.Secure.getString(null, Settings.Secure.ANDROID_ID) ?: Build.UNKNOWN
        }
    }

    fun getInfo(context: Context): String {
        val bat = getBattery(context)
        val wifi = getWifi(context)
        val prefs = context.getSharedPreferences(BootReceiver.PREFS_NAME, Context.MODE_PRIVATE)
        val info = mapOf(
            "serial"           to getSerial(),
            "model"            to Build.MODEL,
            "android_version"  to Build.VERSION.RELEASE,
            "battery_level"    to bat["level"],
            "battery_charging" to bat["charging"],
            "battery_temp_c"   to bat["temp_c"],
            "wifi_ssid"        to wifi["ssid"],
            "wifi_ip"          to wifi["ip"],
            "wifi_rssi"        to wifi["rssi"],
            "cpu_usage_pct"    to getCpuUsage(),
            "storage"          to getStorage(),
            "thermals"         to getThermals(),
            "adb_wifi_enabled" to (Settings.Secure.getInt(context.contentResolver, "adb_wifi_enabled", 0) == 1),
            "auto_adb_wifi"    to prefs.getBoolean(BootReceiver.PREF_AUTO_ADB, true),
            "companion_port"   to CompanionService.HTTP_PORT,
            "version"          to "1.0"
        )
        return gson.toJson(info)
    }

    private fun getBattery(context: Context): Map<String, Any?> {
        val intent = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val level = intent?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val scale = intent?.getIntExtra(BatteryManager.EXTRA_SCALE, 100) ?: 100
        val status = intent?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
        val tempRaw = intent?.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, -1) ?: -1
        return mapOf(
            "level"    to if (level >= 0 && scale > 0) level * 100 / scale else -1,
            "charging" to (status == BatteryManager.BATTERY_STATUS_CHARGING || status == BatteryManager.BATTERY_STATUS_FULL),
            "temp_c"   to if (tempRaw >= 0) tempRaw / 10.0 else -1.0
        )
    }

    @Suppress("DEPRECATION")
    private fun getWifi(context: Context): Map<String, Any> {
        return try {
            val wm = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            val info = wm.connectionInfo
            val ipInt = info.ipAddress
            val ip = "${ipInt and 0xFF}.${(ipInt shr 8) and 0xFF}.${(ipInt shr 16) and 0xFF}.${(ipInt shr 24) and 0xFF}"
            mapOf(
                "ssid" to (info.ssid?.removeSurrounding("\"") ?: ""),
                "ip"   to ip,
                "rssi" to info.rssi
            )
        } catch (_: Exception) {
            mapOf("ssid" to "", "ip" to "", "rssi" to -99)
        }
    }

    fun getCpuUsage(): Float {
        return try {
            fun readStat() = File("/proc/stat").readLines().first()
                .trim().split("\\s+".toRegex()).drop(1)
                .map { it.toLongOrNull() ?: 0L }
            val s1 = readStat()
            Thread.sleep(300)
            val s2 = readStat()
            val idle1 = s1.getOrElse(3) { 0L }
            val idle2 = s2.getOrElse(3) { 0L }
            val total1 = s1.sum()
            val total2 = s2.sum()
            val dTotal = (total2 - total1).toFloat()
            val dIdle = (idle2 - idle1).toFloat()
            if (dTotal <= 0f) 0f else ((dTotal - dIdle) / dTotal * 100f).coerceIn(0f, 100f)
        } catch (_: Exception) { -1f }
    }

    private fun getStorage(): Map<String, Double> {
        return try {
            val stat = StatFs(Environment.getExternalStorageDirectory().path)
            val total = stat.totalBytes / 1e9
            val avail = stat.availableBytes / 1e9
            mapOf("total_gb" to total, "used_gb" to (total - avail), "free_gb" to avail)
        } catch (_: Exception) {
            mapOf("total_gb" to -1.0, "used_gb" to -1.0, "free_gb" to -1.0)
        }
    }

    private fun getThermals(): List<Map<String, Any>> {
        return try {
            File("/sys/class/thermal").listFiles()
                ?.filter { it.name.startsWith("thermal_zone") }
                ?.mapNotNull { zone ->
                    val tempFile = File(zone, "temp")
                    if (!tempFile.exists()) return@mapNotNull null
                    val milliDeg = tempFile.readText().trim().toLongOrNull() ?: return@mapNotNull null
                    val type = File(zone, "type").takeIf { it.exists() }?.readText()?.trim() ?: zone.name
                    mapOf("type" to type, "temp_c" to milliDeg / 1000.0)
                } ?: emptyList()
        } catch (_: Exception) { emptyList() }
    }

    fun getInstalledApps(context: Context): String {
        val pm = context.packageManager
        val apps = pm.getInstalledApplications(PackageManager.GET_META_DATA)
            .filter { (it.flags and ApplicationInfo.FLAG_SYSTEM) == 0 }
            .map { app ->
                mapOf(
                    "package" to app.packageName,
                    "name"    to try { pm.getApplicationLabel(app).toString() } catch (_: Exception) { app.packageName }
                )
            }
        return gson.toJson(apps)
    }
}
