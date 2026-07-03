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
                session.method == Method.POST && session.uri == "/adb/enable" -> serveAdbEnable(session)
                session.method == Method.POST && session.uri == "/settings"   -> serveSettings(session)
                session.method == Method.POST && session.uri == "/wake"       -> serveWake(session)
                else -> newFixedLengthResponse(Response.Status.NOT_FOUND, MIME_PLAINTEXT, "Not found")
            }
        } catch (e: Exception) {
            jsonError(500, e.message ?: "Internal error")
        }
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
            Settings.Secure.putInt(context.contentResolver, "adb_wifi_enabled", if (enable) 1 else 0)
            jsonOk(mapOf("adb_wifi_enabled" to enable))
        } catch (_: SecurityException) {
            jsonError(403, "WRITE_SECURE_SETTINGS not granted - run: adb shell pm grant com.vrheadsetmanager.companion android.permission.WRITE_SECURE_SETTINGS")
        }
    }

    private fun serveSettings(session: IHTTPSession): Response {
        val body = readBody(session)
        return try {
            val json = JsonParser.parseString(body).asJsonObject
            val prefs = context.getSharedPreferences(BootReceiver.PREFS_NAME, Context.MODE_PRIVATE)

            if (json.has("auto_adb_wifi")) {
                prefs.edit().putBoolean(BootReceiver.PREF_AUTO_ADB, json["auto_adb_wifi"].asBoolean).apply()
            }
            if (json.has("brightness")) {
                val pct = json["brightness"].asInt.coerceIn(0, 100)
                try { Settings.System.putInt(context.contentResolver, Settings.System.SCREEN_BRIGHTNESS, pct * 255 / 100) } catch (_: Exception) {}
            }
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
            403 -> Response.Status.FORBIDDEN
            404 -> Response.Status.NOT_FOUND
            else -> Response.Status.INTERNAL_ERROR
        }
        return newFixedLengthResponse(status, "application/json",
            """{"ok":false,"error":${gson.toJson(message)}}""")
    }
}
