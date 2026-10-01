package com.vrheadsetmanager.adbwifi

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.provider.Settings

/**
 * Switches the headset's adbd to classic TCP mode on a chosen port - the on-device
 * equivalent of running `adb tcpip <port>` from a computer.
 *
 * An app cannot restart adbd by itself, so it talks to adbd with the bundled adb client:
 *  1. Port already listening          -> nothing to do (only checks our client is authorized).
 *  2. adbd listening on another port  -> connect there and run `tcpip <port>`.
 *  3. Otherwise                       -> turn on Android "wireless debugging" (needs
 *     WRITE_SECURE_SETTINGS), find its random TLS port with mDNS, connect, `tcpip <port>`.
 *
 * Paths 2 and 3 need the bundled client's key to be authorized once (see the docs).
 * All calls are serialized: the UI and the boot service may run at the same time.
 */
object AdbWifiController {

    data class Result(val success: Boolean, val message: String)

    private const val LOCALHOST = "127.0.0.1"
    private const val SETTING_ADB_ENABLED = "adb_enabled"
    private const val SETTING_ADB_WIFI_ENABLED = "adb_wifi_enabled"

    fun hasWriteSecureSettings(context: Context): Boolean =
        context.checkSelfPermission(Manifest.permission.WRITE_SECURE_SETTINGS) == PackageManager.PERMISSION_GRANTED

    fun isEnabled(port: Int): Boolean = NetUtils.isLocalPortOpen(port)

    @Synchronized
    fun enable(context: Context, port: Int, log: (String) -> Unit): Result {
        val prefs = Prefs(context)
        val adb = AdbClient(context)
        if (!adb.isAvailable) return Result(false, "Bundled adb client is missing - reinstall the app.")

        try {
            if (NetUtils.isLocalPortOpen(port)) {
                log("adbd already listens on port $port.")
                prefs.lastActivePort = port
                if (!prefs.clientAuthorized) {
                    // First run after `adb tcpip` from a PC: get our key accepted now,
                    // so later activations (after a reboot) work without a computer.
                    log("Authorizing the built-in adb client - accept the prompt in the headset and tick \"Always allow\".")
                    if (connectAuthorized(adb, "$LOCALHOST:$port", prefs, log, waitSeconds = 30)) {
                        log("Built-in adb client authorized.")
                    } else {
                        log("Built-in adb client NOT authorized: activation after a reboot will not work yet.")
                    }
                }
                return Result(true, "ADB over Wi-Fi enabled on port $port.")
            }

            // Path 2: adbd is still in TCP mode on another port (port changed in the UI).
            val otherPorts = listOf(prefs.lastActivePort, Prefs.DEFAULT_PORT).filter { it > 0 && it != port }.distinct()
            for (old in otherPorts) {
                if (!NetUtils.isLocalPortOpen(old)) continue
                log("adbd listens on port $old - switching it to $port.")
                val serial = "$LOCALHOST:$old"
                if (connectAuthorized(adb, serial, prefs, log, waitSeconds = 30) && switchToTcp(adb, serial, port, prefs, log)) {
                    return Result(true, "ADB over Wi-Fi enabled on port $port.")
                }
            }

            // Path 3: through Android wireless debugging.
            if (!hasWriteSecureSettings(context)) {
                return Result(false, "Permission WRITE_SECURE_SETTINGS is missing. Grant it once from a computer:\n" +
                        "adb shell pm grant ${context.packageName} android.permission.WRITE_SECURE_SETTINGS")
            }
            val resolver = context.contentResolver
            if (Settings.Global.getInt(resolver, SETTING_ADB_ENABLED, 0) != 1) {
                return Result(false, "USB debugging is off. Enable developer mode / USB debugging on the headset first.")
            }
            val ip = NetUtils.wifiIpv4() ?: return Result(false, "The headset is not connected to Wi-Fi.")

            log("Turning on wireless debugging...")
            Settings.Global.putInt(resolver, SETTING_ADB_WIFI_ENABLED, 1)
            log("Looking for the wireless debugging port (mDNS on ${ip.hostAddress})...")
            val tlsPort = MdnsAdbDiscovery(context).discoverTlsPort(ip)
                ?: return Result(false, "Wireless debugging port not found. Check the Wi-Fi connection, or that " +
                        "the headset did not ask to allow wireless debugging on this network.")
            log("Wireless debugging is on port $tlsPort.")

            val serial = "${ip.hostAddress}:$tlsPort"
            if (!connectAuthorized(adb, serial, prefs, log, waitSeconds = 5)) {
                return Result(false, "The built-in adb client is not authorized yet (one-time setup). Plug the headset " +
                        "into a computer, run 'adb tcpip $port', then press Enable here and accept the prompt " +
                        "in the headset with \"Always allow\".")
            }
            return if (switchToTcp(adb, serial, port, prefs, log)) {
                Result(true, "ADB over Wi-Fi enabled on port $port.")
            } else {
                Result(false, "adbd did not start listening on port $port.")
            }
        } finally {
            adb.run("kill-server", timeoutSeconds = 5)
        }
    }

    /** Puts adbd back in USB-only mode (`adb usb`) and turns wireless debugging off. */
    @Synchronized
    fun disable(context: Context, log: (String) -> Unit): Result {
        val prefs = Prefs(context)
        val adb = AdbClient(context)
        try {
            val port = listOf(prefs.port, prefs.lastActivePort, Prefs.DEFAULT_PORT)
                .filter { it > 0 }.distinct().firstOrNull { NetUtils.isLocalPortOpen(it) }
            if (port != null) {
                val serial = "$LOCALHOST:$port"
                if (!connectAuthorized(adb, serial, prefs, log, waitSeconds = 30)) {
                    return Result(false, "Cannot disable: the built-in adb client is not authorized.")
                }
                log(adb.run("-s", serial, "usb"))
                waitUntil(10) { !NetUtils.isLocalPortOpen(port) }
            }
            if (hasWriteSecureSettings(context)) {
                Settings.Global.putInt(context.contentResolver, SETTING_ADB_WIFI_ENABLED, 0)
            }
            val stillOpen = port != null && NetUtils.isLocalPortOpen(port)
            return if (stillOpen) Result(false, "adbd still listens on port $port.")
            else Result(true, "ADB over Wi-Fi disabled.")
        } finally {
            adb.run("kill-server", timeoutSeconds = 5)
        }
    }

    /** Connects to [serial] and waits until adbd accepts our key (state "device"). */
    private fun connectAuthorized(adb: AdbClient, serial: String, prefs: Prefs, log: (String) -> Unit, waitSeconds: Int): Boolean {
        val out = adb.run("connect", serial)
        log(out)
        if (!out.contains("connected to")) return false
        val deadline = System.currentTimeMillis() + waitSeconds * 1000L
        do {
            val state = adb.run("-s", serial, "get-state", timeoutSeconds = 5)
            if (state.trim() == "device") {
                prefs.clientAuthorized = true
                return true
            }
            Thread.sleep(1000)
        } while (System.currentTimeMillis() < deadline)
        log("Not authorized on $serial.")
        prefs.clientAuthorized = false
        return false
    }

    private fun switchToTcp(adb: AdbClient, serial: String, port: Int, prefs: Prefs, log: (String) -> Unit): Boolean {
        log(adb.run("-s", serial, "tcpip", port.toString()))
        // adbd restarts itself; give it a moment to listen on the new port
        val ok = waitUntil(15) { NetUtils.isLocalPortOpen(port) }
        if (ok) prefs.lastActivePort = port
        return ok
    }

    private fun waitUntil(seconds: Int, condition: () -> Boolean): Boolean {
        val deadline = System.currentTimeMillis() + seconds * 1000L
        while (System.currentTimeMillis() < deadline) {
            if (condition()) return true
            Thread.sleep(500)
        }
        return condition()
    }
}
