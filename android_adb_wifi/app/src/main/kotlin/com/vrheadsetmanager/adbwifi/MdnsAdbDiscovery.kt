package com.vrheadsetmanager.adbwifi

import android.content.Context
import android.net.wifi.WifiManager
import java.net.Inet4Address
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import javax.jmdns.JmDNS
import javax.jmdns.ServiceEvent
import javax.jmdns.ServiceListener

/**
 * Finds the random TLS port of Android "wireless debugging" by listening to the
 * mDNS service adbd advertises. Only this headset's own advert is accepted (matched
 * by IP), which matters in a room full of headsets on the same Wi-Fi.
 */
class MdnsAdbDiscovery(private val context: Context) {

    fun discoverTlsPort(localIp: Inet4Address, timeoutSeconds: Long = 20): Int? {
        val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        val lock = wifi.createMulticastLock("vrhm_adb_mdns").apply { setReferenceCounted(false) }
        val found = AtomicInteger(0)
        val latch = CountDownLatch(1)
        var jmdns: JmDNS? = null
        return try {
            lock.acquire()
            val dns = JmDNS.create(localIp)
            jmdns = dns
            val listener = object : ServiceListener {
                override fun serviceAdded(event: ServiceEvent) {
                    dns.requestServiceInfo(event.type, event.name, true)
                }

                override fun serviceRemoved(event: ServiceEvent) {}

                override fun serviceResolved(event: ServiceEvent) {
                    val info = event.info ?: return
                    val isMine = info.inet4Addresses.any { it.hostAddress == localIp.hostAddress }
                    if (isMine && info.port > 0 && found.compareAndSet(0, info.port)) latch.countDown()
                }
            }
            SERVICE_TYPES.forEach { dns.addServiceListener(it, listener) }
            latch.await(timeoutSeconds, TimeUnit.SECONDS)
            found.get().takeIf { it > 0 }
        } catch (_: Exception) {
            null
        } finally {
            try { jmdns?.close() } catch (_: Exception) { }
            if (lock.isHeld) lock.release()
        }
    }

    companion object {
        private val SERVICE_TYPES = listOf("_adb-tls-connect._tcp.local.", "_adb_secure_connect._tcp.local.")
    }
}
