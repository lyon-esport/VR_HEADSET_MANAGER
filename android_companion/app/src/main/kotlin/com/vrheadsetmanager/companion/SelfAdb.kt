package com.vrheadsetmanager.companion

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.sun.security.x509.AlgorithmId
import android.sun.security.x509.CertificateAlgorithmId
import android.sun.security.x509.CertificateExtensions
import android.sun.security.x509.CertificateIssuerName
import android.sun.security.x509.CertificateSerialNumber
import android.sun.security.x509.CertificateSubjectName
import android.sun.security.x509.CertificateValidity
import android.sun.security.x509.CertificateVersion
import android.sun.security.x509.CertificateX509Key
import android.sun.security.x509.KeyIdentifier
import android.sun.security.x509.PrivateKeyUsageExtension
import android.sun.security.x509.SubjectKeyIdentifierExtension
import android.sun.security.x509.X500Name
import android.sun.security.x509.X509CertImpl
import android.sun.security.x509.X509CertInfo
import android.util.Base64
import io.github.muntashirakon.adb.AbsAdbConnectionManager
import java.io.File
import java.math.BigInteger
import java.net.NetworkInterface
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.SecureRandom
import java.security.cert.Certificate
import java.security.cert.CertificateFactory
import java.security.interfaces.RSAPublicKey
import java.security.spec.PKCS8EncodedKeySpec
import java.util.Date
import java.util.Random
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Self-ADB connection manager (ported from spike); keys are stored in DEVICE-PROTECTED storage so they are usable before first unlock. */
class SelfAdb private constructor(ctx: Context) : AbsAdbConnectionManager() {
    private val privKey: PrivateKey
    private val cert: Certificate
    val pubKey: RSAPublicKey

    init {
        setApi(Build.VERSION.SDK_INT)
        val dir = dpCtx(ctx).filesDir
        val kf = File(dir, "private.key")
        val cf = File(dir, "cert.der")
        if (kf.exists() && cf.exists()) {
            privKey = KeyFactory.getInstance("RSA").generatePrivate(PKCS8EncodedKeySpec(kf.readBytes()))
            cert = CertificateFactory.getInstance("X.509").generateCertificate(cf.inputStream())
        } else {
            val g = KeyPairGenerator.getInstance("RSA")
            g.initialize(2048, SecureRandom.getInstance("SHA1PRNG"))
            val kp = g.generateKeyPair()
            privKey = kp.private
            val algo = "SHA512withRSA"
            val ext = CertificateExtensions()
            ext.set("SubjectKeyIdentifier", SubjectKeyIdentifierExtension(KeyIdentifier(kp.public).identifier))
            val name = X500Name("CN=VRHM Companion")
            val nb = Date()
            val na = Date(System.currentTimeMillis() + 10L * 365 * 86400000)
            ext.set("PrivateKeyUsage", PrivateKeyUsageExtension(nb, na))
            val info = X509CertInfo()
            info.set("version", CertificateVersion(2))
            info.set("serialNumber", CertificateSerialNumber(Random().nextInt() and Int.MAX_VALUE))
            info.set("algorithmID", CertificateAlgorithmId(AlgorithmId.get(algo)))
            info.set("subject", CertificateSubjectName(name))
            info.set("key", CertificateX509Key(kp.public))
            info.set("validity", CertificateValidity(nb, na))
            info.set("issuer", CertificateIssuerName(name))
            info.set("extensions", ext)
            val c = X509CertImpl(info)
            c.sign(privKey, algo)
            cert = c
            kf.writeBytes(privKey.encoded)
            cf.writeBytes(c.encoded)
            AdbBootManager.log("key: generated new keypair")
        }
        pubKey = cert.publicKey as RSAPublicKey
    }

    override fun getPrivateKey(): PrivateKey = privKey
    override fun getCertificate(): Certificate = cert
    override fun getDeviceName(): String = "vrhm-companion"

    /** adb-format public key (base64 of the android RSAPublicKey struct), no trailing name. */
    fun adbPublicKeyBase64(): String {
        val n = pubKey.modulus
        val e = pubKey.publicExponent
        val words = 64
        val r = BigInteger.ONE.shiftLeft(2048)
        val rr = r.multiply(r).mod(n)
        val n0inv = n.modInverse(BigInteger.ONE.shiftLeft(32)).negate().mod(BigInteger.ONE.shiftLeft(32))
        val bb = ByteBuffer.allocate(4 + 4 + 256 + 256 + 4).order(ByteOrder.LITTLE_ENDIAN)
        bb.putInt(words)
        bb.putInt(n0inv.toLong().toInt())
        bb.put(leBytes(n, 256))
        bb.put(leBytes(rr, 256))
        bb.putInt(e.toInt())
        return Base64.encodeToString(bb.array(), Base64.NO_WRAP)
    }

    private fun leBytes(v: BigInteger, len: Int): ByteArray {
        val be = v.toByteArray()
        val out = ByteArray(len)
        for (i in 0 until len) {
            val idx = be.size - 1 - i
            out[i] = if (idx >= 0) be[idx] else 0
        }
        return out
    }

    /**
     * The RSA key fingerprint EXACTLY as Horizon shows it in the "Allow debugging" dialog:
     * MD5 over the DECODED adb public-key blob (not the base64 text), upper-hex, colon-separated.
     * Must match so the approve allowlist can compare against what the dialog displays.
     */
    fun fingerprint(): String {
        val blob = Base64.decode(adbPublicKeyBase64(), Base64.NO_WRAP)
        val md = MessageDigest.getInstance("MD5").digest(blob)
        return md.joinToString(":") { "%02X".format(it) }
    }

    companion object {
        fun dpCtx(ctx: Context): Context = if (ctx.isDeviceProtectedStorage) ctx else ctx.createDeviceProtectedStorageContext()

        @Volatile private var inst: SelfAdb? = null
        fun get(ctx: Context): SelfAdb = inst ?: synchronized(this) {
            inst ?: SelfAdb(ctx.applicationContext).also { inst = it }
        }

        fun localAddresses(): Set<String> = try {
            NetworkInterface.getNetworkInterfaces().toList()
                .flatMap { it.inetAddresses.toList() }.mapNotNull { it.hostAddress }.toSet()
        } catch (e: Exception) { emptySet() }

        /** Discover a service type with NsdManager; returns (host, port) preferring a local address. */
        fun discover(ctx: Context, type: String, timeoutMs: Long = 8000): Pair<String, Int>? {
            val nsd = ctx.getSystemService(Context.NSD_SERVICE) as NsdManager
            val local = localAddresses()
            val found = java.util.concurrent.CopyOnWriteArrayList<Pair<String, Int>>()
            val queue = java.util.concurrent.LinkedBlockingQueue<NsdServiceInfo>()
            val done = CountDownLatch(1)
            val listener = object : NsdManager.DiscoveryListener {
                override fun onDiscoveryStarted(t: String) { AdbBootManager.log("nsd: discovery started $t") }
                override fun onServiceFound(si: NsdServiceInfo) { queue.add(si) }
                override fun onServiceLost(si: NsdServiceInfo) {}
                override fun onDiscoveryStopped(t: String) {}
                override fun onStartDiscoveryFailed(t: String, c: Int) { AdbBootManager.log("nsd: start failed $c"); done.countDown() }
                override fun onStopDiscoveryFailed(t: String, c: Int) {}
            }
            nsd.discoverServices(type, NsdManager.PROTOCOL_DNS_SD, listener)
            val end = System.currentTimeMillis() + timeoutMs
            try {
                while (System.currentTimeMillis() < end) {
                    val si = queue.poll(300, TimeUnit.MILLISECONDS) ?: continue
                    val latch = CountDownLatch(1)
                    @Suppress("DEPRECATION")
                    nsd.resolveService(si, object : NsdManager.ResolveListener {
                        override fun onResolveFailed(s: NsdServiceInfo, c: Int) { AdbBootManager.log("nsd: resolve failed ${s.serviceName} $c"); latch.countDown() }
                        override fun onServiceResolved(s: NsdServiceInfo) {
                            val h = s.host?.hostAddress
                            if (h != null) { found.add(h to s.port); AdbBootManager.log("nsd: resolved ${s.serviceName} $h:${s.port}") }
                            latch.countDown()
                        }
                    })
                    latch.await(3, TimeUnit.SECONDS)
                    if (found.any { it.first in local || it.first == "127.0.0.1" }) break
                }
            } finally {
                try { nsd.stopServiceDiscovery(listener) } catch (_: Exception) {}
            }
            return found.firstOrNull { it.first in local } ?: found.firstOrNull()
        }
    }
}