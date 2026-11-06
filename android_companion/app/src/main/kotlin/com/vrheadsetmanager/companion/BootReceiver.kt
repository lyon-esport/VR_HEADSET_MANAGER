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
        // Wireless debugging is switched on from BOOT_COMPLETED only, never at LOCKED_BOOT_COMPLETED:
        // forcing it before the user and the WiFi network are settled made Horizon raise the
        // "allow wireless debugging" alert at every boot. The service still starts early (it only
        // reads and pushes telemetry); the watchdog it hosts re-enables ADB once the network is up.
        if (action == Intent.ACTION_BOOT_COMPLETED) {
            val pending = goAsync()
            AdbBootManager.applyAsync(context) { pending.finish() }
        }

        if (action == Intent.ACTION_BOOT_COMPLETED || action == Intent.ACTION_LOCKED_BOOT_COMPLETED) {
            if (action == Intent.ACTION_BOOT_COMPLETED && prefs.getBoolean(PREF_AUTO_ADB, true) && !AdbBootManager.isPico()) {
                try {
                    // Only write when it is not already on (QGO or a previous write may have set it).
                    if (Settings.Global.getInt(context.contentResolver, "adb_wifi_enabled", 0) != 1) {
                        Settings.Global.putInt(context.contentResolver, "adb_wifi_enabled", 1)
                    }
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