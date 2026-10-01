package com.vrheadsetmanager.adbwifi

import java.net.Inet4Address
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.Socket

object NetUtils {

    /** IPv4 address of the Wi-Fi interface (wlan*), or null when Wi-Fi is not connected. */
    fun wifiIpv4(): Inet4Address? = try {
        NetworkInterface.getNetworkInterfaces()?.toList().orEmpty()
            .filter { it.isUp && !it.isLoopback && it.name.startsWith("wlan") }
            .flatMap { it.inetAddresses.toList() }
            .filterIsInstance<Inet4Address>()
            .firstOrNull()
    } catch (_: Exception) {
        null
    }

    /** True when something (adbd in TCP mode) accepts connections on 127.0.0.1:[port]. */
    fun isLocalPortOpen(port: Int, timeoutMs: Int = 500): Boolean = try {
        Socket().use { it.connect(InetSocketAddress("127.0.0.1", port), timeoutMs); true }
    } catch (_: Exception) {
        false
    }
}
