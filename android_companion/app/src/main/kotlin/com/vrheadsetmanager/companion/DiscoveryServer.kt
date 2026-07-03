package com.vrheadsetmanager.companion

import android.content.Context
import android.net.wifi.WifiManager
import android.os.Build
import android.provider.Settings
import com.google.gson.Gson
import com.google.gson.JsonParser
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress

/**
 * UDP server on [port] (default 5556).
 * VRHM broadcasts {"type":"VRHM_DISCOVER","server_ip":"...","ws_port":...}.
 * This server replies UNICAST to the sender with the headset's identity and current state.
 * The reply goes back to the sender's source address:port so VRHM's bound socket receives it.
 */
class DiscoveryServer(private val context: Context, private val port: Int) {

    private val gson = Gson()
    @Volatile private var running = false
    private var thread: Thread? = null

    fun start() {
        if (running) return
        running = true
        thread = Thread(::loop, "VRHM-Discovery").also {
            it.isDaemon = true
            it.start()
        }
    }

    fun stop() {
        running = false
        thread?.interrupt()
        thread = null
    }

    private fun loop() {
        while (running) {
            var socket: DatagramSocket? = null
            try {
                socket = DatagramSocket(port)
                socket.soTimeout = 3000
                val buf = ByteArray(2048)
                while (running) {
                    try {
                        val pkt = DatagramPacket(buf, buf.size)
                        socket.receive(pkt)
                        handlePacket(socket, pkt.address, pkt.port, String(pkt.data, 0, pkt.length, Charsets.UTF_8))
                    } catch (_: java.net.SocketTimeoutException) { /* idle tick */ }
                }
            } catch (e: Exception) {
                if (running) Thread.sleep(3000)
            } finally {
                socket?.close()
            }
        }
    }

    private fun handlePacket(socket: DatagramSocket, senderAddr: InetAddress, senderPort: Int, message: String) {
        try {
            val json = JsonParser.parseString(message).asJsonObject
            if (json.get("type")?.asString != "VRHM_DISCOVER") return

            val prefs = context.getSharedPreferences(BootReceiver.PREFS_NAME, Context.MODE_PRIVATE)
            val autoAdb = prefs.getBoolean(BootReceiver.PREF_AUTO_ADB, true)
            val adbEnabled = Settings.Secure.getInt(context.contentResolver, "adb_wifi_enabled", 0) == 1

            val ipInt = (context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager)
                .connectionInfo.ipAddress
            val ip = "${ipInt and 0xFF}.${(ipInt shr 8) and 0xFF}.${(ipInt shr 16) and 0xFF}.${(ipInt shr 24) and 0xFF}"

            val reply = gson.toJson(mapOf(
                "type"             to "VRHM_COMPANION",
                "serial"           to DeviceInfo.getSerial(),
                "model"            to Build.MODEL,
                "ip"               to ip,
                "companion_port"   to CompanionService.HTTP_PORT,
                "auto_adb_wifi"    to autoAdb,
                "adb_wifi_enabled" to adbEnabled,
                "version"          to "1.0"
            ))

            val replyBytes = reply.toByteArray(Charsets.UTF_8)
            socket.send(DatagramPacket(replyBytes, replyBytes.size, senderAddr, senderPort))
        } catch (_: Exception) { /* malformed or reply failed */ }
    }
}
