package com.vrheadsetmanager.adbwifi

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Settings

/**
 * "Auto start on headset startup": enables ADB over Wi-Fi in the background, and also
 * opens the app window when Android allows it. Android blocks activity starts from the
 * background unless the app may "display over other apps" (SYSTEM_ALERT_WINDOW).
 */
class BootReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action !in BOOT_ACTIONS) return
        if (!Prefs(context).startOnBoot) return

        AdbWifiService.start(context)

        if (Settings.canDrawOverlays(context)) {
            try {
                context.startActivity(Intent(context, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    .putExtra(MainActivity.EXTRA_FROM_BOOT, true))
            } catch (_: Exception) {
                // Window could not be opened; the service still enables ADB.
            }
        }
    }

    companion object {
        private val BOOT_ACTIONS = setOf(
            Intent.ACTION_BOOT_COMPLETED,
            "android.intent.action.QUICKBOOT_POWERON",
        )
    }
}
