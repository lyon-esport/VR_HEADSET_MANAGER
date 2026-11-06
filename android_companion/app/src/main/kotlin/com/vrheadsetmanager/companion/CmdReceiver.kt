package com.vrheadsetmanager.companion

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Settings
import android.util.Log
import com.google.gson.Gson

/**
 * Headless control surface for the ADB engine and the approver. Drives the same actions the
 * token-protected HTTP API will expose later; for now it is how the engine is tested and how
 * VRHM provisions the approve allowlist over ADB at onboarding:
 *   adb shell am broadcast -a com.vrheadsetmanager.companion.CMD -n com.vrheadsetmanager.companion/.CmdReceiver --es cmd <cmd> [extras]
 * Commands: status | key | setmode NONE|CLASSIC|TLS (--es mode) | setport (--ei port)
 *           forceclassic | forcetls | approve_on | approve_off | trust_add (--es fp) | trust_clear
 *           settoken (--es token) | cleartoken | setserial (--es serial: the adb serial, ro.serialno)
 * Results are logged to tag VRHMCmd.
 *
 * Access: the manifest guards this receiver with android:permission="android.permission.DUMP".
 * DUMP is signature|privileged|development: the adb shell user (uid 2000) holds it, root bypasses
 * permission checks, and no ordinary installed app can obtain it, so only `adb shell am broadcast`
 * (or root) reaches these commands. It stays exported so the explicit -n broadcast still works.
 */
class CmdReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val ctx = context.applicationContext
        val cmd = intent.getStringExtra("cmd") ?: return
        when (cmd) {
            "status" -> Log.i(TAG, "STATUS " + Gson().toJson(AdbBootManager.status(ctx)))
            "key" -> Log.i(TAG, "KEY " + (try { SelfAdb.get(ctx).fingerprint() } catch (e: Throwable) { "err ${e.message}" }))
            "setmode" -> {
                val m = intent.getStringExtra("mode")?.uppercase()
                try { AdbBootManager.setBootMode(ctx, BootMode.valueOf(m ?: "NONE")); Log.i(TAG, "setmode $m ok") }
                catch (e: Exception) { Log.i(TAG, "setmode bad value $m") }
            }
            "setport" -> { AdbBootManager.setClassicPort(ctx, intent.getIntExtra("port", 5555)); Log.i(TAG, "setport ok") }
            "forceclassic" -> { AdbBootManager.forceClassicNow(ctx); Log.i(TAG, "forceclassic issued") }
            "forcetls" -> { AdbBootManager.forceTlsNow(ctx); Log.i(TAG, "forcetls issued") }
            "approve_on" -> { ApproveConfig.setAutoApprove(ctx, true); Log.i(TAG, "approve ON") }
            "approve_off" -> { ApproveConfig.setAutoApprove(ctx, false); Log.i(TAG, "approve OFF") }
            "trust_add" -> { intent.getStringExtra("fp")?.let { ApproveConfig.addTrusted(ctx, it) }; Log.i(TAG, "trust now=" + ApproveConfig.trustedFingerprints(ctx)) }
            "trust_clear" -> { ApproveConfig.clearTrusted(ctx); Log.i(TAG, "trust cleared") }
            "settoken" -> {
                if (TokenConfig.setToken(ctx, intent.getStringExtra("token"))) Log.i(TAG, "settoken done")
                else Log.w(TAG, "settoken refused: blank or missing token")
            }
            "cleartoken" -> { TokenConfig.clearToken(ctx); Log.i(TAG, "cleartoken done") }
            "setserial" -> {
                if (DeviceInfo.setProvisionedSerial(ctx, intent.getStringExtra("serial"))) Log.i(TAG, "setserial done")
                else Log.w(TAG, "setserial refused: missing or invalid serial")
            }
            "a11y_on" -> { enableSelfA11y(ctx) }
            else -> Log.i(TAG, "unknown cmd $cmd")
        }
    }

    private fun enableSelfA11y(ctx: Context) { ensureApproverEnabled(ctx, force = true) }

    companion object {
        const val TAG = "VRHMCmd"

        /**
         * Makes sure the approver accessibility service is enabled (needs WRITE_SECURE_SETTINGS).
         * An app update or a Horizon reset can leave it off, which silently disables every auto-approve.
         * Cheap when already enabled (one settings read, no write, no log) so it can run on every
         * service start and watchdog tick. `force` logs even when nothing had to be changed.
         */
        fun ensureApproverEnabled(ctx: Context, force: Boolean = false) {
            val svc = ctx.packageName + "/" + ApproveService::class.java.name
            try {
                val cur = Settings.Secure.getString(ctx.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES) ?: ""
                val listed = cur.split(":").any { it.equals(svc, ignoreCase = true) }
                val on = Settings.Secure.getInt(ctx.contentResolver, Settings.Secure.ACCESSIBILITY_ENABLED, 0) == 1
                if (listed && on) { if (force) Log.i(TAG, "a11y already enabled: $svc"); return }
                if (!listed) {
                    val next = if (cur.isBlank()) svc else "$cur:$svc"
                    Settings.Secure.putString(ctx.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES, next)
                }
                Settings.Secure.putInt(ctx.contentResolver, Settings.Secure.ACCESSIBILITY_ENABLED, 1)
                Log.i(TAG, "a11y self-enabled: $svc")
            } catch (e: Exception) { Log.i(TAG, "a11y self-enable failed: ${e.message}") }
        }
    }
}
