package com.vrheadsetmanager.companion

import android.content.Context
import android.os.PowerManager
import android.provider.Settings
import com.google.gson.Gson
import com.google.gson.JsonParser
import fi.iki.elonen.NanoHTTPD

/**
 * Embedded HTTP server (NanoHTTPD) on [port] (default 8765).
 *
 * Endpoints:
 *   GET  /health       -> {"ok":true,"version":"1.0"}
 *   GET  /info         -> full device state JSON
 *   GET  /apps         -> list of installed third-party apps
 *   POST /adb/enable   -> {"enable":true|false}  - toggle ADB WiFi immediately
 *   POST /settings     -> {"auto_adb_wifi":bool, "brightness":0-100}
 *   POST /wake         -> {"acquire":true|false}  - FULL_WAKE_LOCK for demo mode
 */
class HttpApiServer(port: Int, private val context: Context) : NanoHTTPD(port) {

    private val gson = Gson()
    private var screenWakeLock: PowerManager.WakeLock? = null

    override fun serve(session: IHTTPSession): Response {
        return try {
            when {
                session.method == Method.GET  && session.uri == "/health"     -> serveHealth()
                session.method == Method.GET  && session.uri == "/info"       -> serveInfo()
                session.method == Method.GET  && session.uri == "/apps"       -> serveApps()
                session.method == Method.GET  && session.uri == "/status"     -> serveStatus()
                session.method == Method.GET  && session.uri == "/key"        -> serveKey()
                session.method == Method.POST -> servePost(session)
                else -> newFixedLengthResponse(Response.Status.NOT_FOUND, MIME_PLAINTEXT, "Not found")
            }
        } catch (e: Exception) {
            jsonError(500, e.message ?: "Internal error")
        }
    }

    private fun servePost(session: IHTTPSession): Response {
        if (TokenConfig.hasToken(context)) {
            if (!TokenConfig.matches(context, session.headers["x-vrhm-token"])) return jsonError(401, "bad or missing token")
        } else {
            android.util.Log.w("VRHMApi", "POST " + session.uri + " accepted with NO token set (unprotected)")
        }
        return when (session.uri) {
            "/adb/enable"   -> serveAdbEnable(session)
            "/settings"     -> serveSettings(session)
            "/wake"         -> serveWake(session)
            "/adb/mode"     -> serveAdbMode(session)
            "/adb/force"    -> serveAdbForce(session)
            "/adb/boot"     -> serveAdbBoot(session)
            "/approve"      -> serveApprove(session)
            "/approve/trust" -> serveApproveTrust(session)
            "/token"        -> serveToken(session)
            else -> newFixedLengthResponse(Response.Status.NOT_FOUND, MIME_PLAINTEXT, "Not found")
        }
    }

    private fun bodyObj(session: IHTTPSession) = JsonParser.parseString(readBody(session)).asJsonObject

    private fun serveStatus(): Response {
        val m = LinkedHashMap<String, Any?>(AdbBootManager.status(context))
        m["autoApprove"] = ApproveConfig.autoApprove(context)
        m["trustedCount"] = ApproveConfig.trustedFingerprints(context).size
        m["autoEnabled"] = AdbBootManager.autoEnabled(context)
        m["tokenSet"] = TokenConfig.hasToken(context)
        val tp = SelfAdb.dpCtx(context).getSharedPreferences(BootReceiver.PREFS_NAME, Context.MODE_PRIVATE)
        val rUrl = tp.getString(TelemetryReporter.PREF_REPORT_URL, "") ?: ""
        m["reportUrl"] = rUrl
        m["reporting"] = rUrl.isNotBlank()
        m["reportIntervalSec"] = tp.getInt(TelemetryReporter.PREF_REPORT_INTERVAL, 1)
        return jsonOk(m)
    }

    private fun serveKey(): Response =
        try { jsonOk(mapOf("fingerprint" to SelfAdb.get(context).fingerprint())) }
        catch (e: Throwable) { jsonError(500, e.message ?: "key error") }

    private fun serveAdbMode(session: IHTTPSession): Response {
        return try {
            val j = bodyObj(session)
            val mode = BootMode.valueOf(j.get("mode")?.asString?.uppercase() ?: "")
            AdbBootManager.setBootMode(context, mode)
            if (j.has("port")) {
                val p = j.get("port").asInt
                if (p in 1024..65535) AdbBootManager.setClassicPort(context, p)
            }
            jsonOk(AdbBootManager.status(context))
        } catch (e: Exception) { jsonError(400, "bad mode or body") }
    }

    private fun serveAdbForce(session: IHTTPSession): Response {
        return try {
            val mode = (bodyObj(session).get("mode")?.asString ?: "").uppercase()
            when (mode) {
                "CLASSIC" -> AdbBootManager.forceClassicNow(context)
                "TLS" -> AdbBootManager.forceTlsNow(context)
                else -> return jsonError(400, "mode must be CLASSIC or TLS")
            }
            jsonOk(mapOf("mode" to mode))
        } catch (e: Exception) { jsonError(400, "bad body") }
    }

    private fun serveAdbBoot(session: IHTTPSession): Response {
        return try {
            val en = bodyObj(session).get("enabled")!!.asBoolean
            SelfAdb.dpCtx(context).getSharedPreferences(BootReceiver.PREFS_NAME, Context.MODE_PRIVATE)
                .edit().putBoolean(BootReceiver.PREF_AUTO_ADB, en).apply()
            if (en) AdbBootManager.applyAsync(context)
            jsonOk(mapOf("autoEnabled" to en))
        } catch (e: Exception) { jsonError(400, "bad body") }
    }

    private fun serveApprove(session: IHTTPSession): Response {
        return try {
            val en = bodyObj(session).get("enabled")!!.asBoolean
            ApproveConfig.setAutoApprove(context, en)
            jsonOk(mapOf("autoApprove" to en))
        } catch (e: Exception) { jsonError(400, "bad body") }
    }

    private fun serveApproveTrust(session: IHTTPSession): Response {
        return try {
            val j = bodyObj(session)
            if (j.get("clear")?.asBoolean == true) ApproveConfig.clearTrusted(context)
            if (j.has("set") && j.get("set").isJsonArray) {
                ApproveConfig.setTrusted(context, j.getAsJsonArray("set").map { it.asString })
            }
            if (j.has("add")) ApproveConfig.addTrusted(context, j.get("add").asString)
            jsonOk(mapOf("trusted" to ApproveConfig.trustedFingerprints(context)))
        } catch (e: Exception) { jsonError(400, "bad body") }
    }

    private fun serveToken(session: IHTTPSession): Response {
        return try {
            val t = bodyObj(session).get("token")!!.asString
            if (t.isBlank()) return jsonError(400, "empty token")
            TokenConfig.setToken(context, t)
            jsonOk()
        } catch (e: Exception) { jsonError(400, "bad body") }
    }

    private fun serveHealth() =
        newFixedLengthResponse(Response.Status.OK, "application/json",
            """{"ok":true,"version":"1.0"}""")

    private fun serveInfo() =
        newFixedLengthResponse(Response.Status.OK, "application/json", DeviceInfo.getInfo(context))

    private fun serveApps() =
        newFixedLengthResponse(Response.Status.OK, "application/json", DeviceInfo.getInstalledApps(context))

    private fun serveAdbEnable(session: IHTTPSession): Response {
        val body = readBody(session)
        val enable = try { JsonParser.parseString(body).asJsonObject.get("enable")?.asBoolean ?: true } catch (_: Exception) { true }
        return try {
            // adb_wifi_enabled is a GLOBAL setting on Horizon (Settings.Secure reverts); the watchdog
            // keeps it on via Settings.Global too.
            Settings.Global.putInt(context.contentResolver, "adb_wifi_enabled", if (enable) 1 else 0)
            jsonOk(mapOf("adb_wifi_enabled" to enable))
        } catch (_: SecurityException) {
            jsonError(403, "WRITE_SECURE_SETTINGS not granted - run: adb shell pm grant com.vrheadsetmanager.companion android.permission.WRITE_SECURE_SETTINGS")
        }
    }

    private fun serveSettings(session: IHTTPSession): Response {
        val body = readBody(session)
        return try {
            val json = JsonParser.parseString(body).asJsonObject
            // device-protected prefs: the boot path (BootReceiver / AdbBootManager) reads it there
            val prefs = SelfAdb.dpCtx(context).getSharedPreferences(BootReceiver.PREFS_NAME, Context.MODE_PRIVATE)

            if (json.has("auto_adb_wifi")) {
                prefs.edit().putBoolean(BootReceiver.PREF_AUTO_ADB, json["auto_adb_wifi"].asBoolean).apply()
            }
            if (json.has("brightness")) {
                val pct = json["brightness"].asInt.coerceIn(0, 100)
                try { Settings.System.putInt(context.contentResolver, Settings.System.SCREEN_BRIGHTNESS, pct * 255 / 100) } catch (_: Exception) {}
            }
            // Telemetry report target (ADR-0042): where to POST telemetry, and how often.
            var reportChanged = false
            if (json.has("report_url")) {
                prefs.edit().putString(TelemetryReporter.PREF_REPORT_URL, json["report_url"].asString).apply()
                reportChanged = true
            }
            if (json.has("report_interval_sec")) {
                val iv = json["report_interval_sec"].asInt.coerceIn(1, 3600)
                prefs.edit().putInt(TelemetryReporter.PREF_REPORT_INTERVAL, iv).apply()
                reportChanged = true
            }
            if (reportChanged) TelemetryReporter.notifySettingsChanged()
            jsonOk()
        } catch (e: Exception) {
            jsonError(400, e.message ?: "Bad request")
        }
    }

    private fun serveWake(session: IHTTPSession): Response {
        val body = readBody(session)
        val acquire = try { JsonParser.parseString(body).asJsonObject.get("acquire")?.asBoolean ?: true } catch (_: Exception) { true }
        val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        if (acquire) {
            if (screenWakeLock?.isHeld != true) {
                screenWakeLock = pm.newWakeLock(
                    PowerManager.FULL_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP,
                    "VRHM:DemoWakeLock"
                ).also { it.acquire(8 * 60 * 60 * 1000L) }
            }
        } else {
            if (screenWakeLock?.isHeld == true) screenWakeLock?.release()
            screenWakeLock = null
        }
        return jsonOk(mapOf("wake_held" to (screenWakeLock?.isHeld == true)))
    }

    private fun readBody(session: IHTTPSession): String {
        val map = HashMap<String, String>()
        session.parseBody(map)
        return map["postData"] ?: ""
    }

    private fun jsonOk(extra: Map<String, Any?> = emptyMap()): Response {
        val data = mutableMapOf<String, Any?>("ok" to true)
        data.putAll(extra)
        return newFixedLengthResponse(Response.Status.OK, "application/json", gson.toJson(data))
    }

    private fun jsonError(code: Int, message: String): Response {
        val status = when (code) {
            400 -> Response.Status.BAD_REQUEST
            401 -> Response.Status.UNAUTHORIZED
            403 -> Response.Status.FORBIDDEN
            404 -> Response.Status.NOT_FOUND
            else -> Response.Status.INTERNAL_ERROR
        }
        return newFixedLengthResponse(status, "application/json",
            """{"ok":false,"error":${gson.toJson(message)}}""")
    }
}
