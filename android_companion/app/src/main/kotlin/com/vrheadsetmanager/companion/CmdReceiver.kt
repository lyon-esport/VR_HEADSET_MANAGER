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
 * Results are logged to tag VRHMCmd.
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
            "settoken" -> { intent.getStringExtra("token")?.let { TokenConfig.setToken(ctx, it) }; Log.i(TAG, "settoken done") }
            "cleartoken" -> { TokenConfig.clearToken(ctx); Log.i(TAG, "cleartoken done") }
            "a11y_on" -> { enableSelfA11y(ctx) }
            else -> Log.i(TAG, "unknown cmd $cmd")
        }
    }

    /** Self-enable the approver accessibility service (needs WRITE_SECURE_SETTINGS); no reboot/toggle. */
    private fun enableSelfA11y(ctx: Context) {
        val svc = ctx.packageName + "/" + ApproveService::class.java.name
        try {
            val cur = Settings.Secure.getString(ctx.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES) ?: ""
            if (!cur.split(":").any { it.equals(svc, ignoreCase = true) }) {
                val next = if (cur.isBlank()) svc else "$cur:$svc"
                Settings.Secure.putString(ctx.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES, next)
            }
            Settings.Secure.putInt(ctx.contentResolver, Settings.Secure.ACCESSIBILITY_ENABLED, 1)
            Log.i(TAG, "a11y self-enabled: $svc")
        } catch (e: Exception) { Log.i(TAG, "a11y self-enable failed: ${e.message}") }
    }

    companion object { const val TAG = "VRHMCmd" }
}
