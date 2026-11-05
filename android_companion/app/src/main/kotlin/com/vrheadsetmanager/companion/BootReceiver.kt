package com.vrheadsetmanager.companion

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.provider.Settings

class BootReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action
        if (action != Intent.ACTION_LOCKED_BOOT_COMPLETED &&
            action != Intent.ACTION_BOOT_COMPLETED &&
            action != Intent.ACTION_USER_UNLOCKED) return

        val dp = SelfAdb.dpCtx(context)
        // Device-protected prefs are readable before first unlock.
        val prefs = dp.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

        // On/off is the "auto-enable ADB WiFi on boot" switch (PREF_AUTO_ADB); the mode (TLS/classic)
        // is AdbBootManager's own pref (TLS by default). applyBootMode itself re-checks the switch.
        if (action == Intent.ACTION_LOCKED_BOOT_COMPLETED) {
            // Engine first (before the service), on a background thread.
            val pending = goAsync()
            AdbBootManager.applyAsync(context) { pending.finish() }
        }

        if (action == Intent.ACTION_BOOT_COMPLETED || action == Intent.ACTION_LOCKED_BOOT_COMPLETED) {
            if (prefs.getBoolean(PREF_AUTO_ADB, true)) {
                try {
                    Settings.Global.putInt(context.contentResolver, "adb_wifi_enabled", 1)
                } catch (e: SecurityException) {
                    // WRITE_SECURE_SETTINGS not yet granted via adb shell pm grant
                }
            }
            try {
                val svc = Intent(context, CompanionService::class.java)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(svc)
                } else {
                    context.startService(svc)
                }
            } catch (e: Exception) {
                // Service start may be refused while locked; BOOT_COMPLETED will retry.
            }
        }
    }

    companion object {
        const val PREFS_NAME = "companion_prefs"
        const val PREF_AUTO_ADB = "auto_adb_wifi"
    }
}