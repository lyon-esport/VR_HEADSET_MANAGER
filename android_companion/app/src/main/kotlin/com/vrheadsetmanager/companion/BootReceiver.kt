package com.vrheadsetmanager.companion

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.provider.Settings

class BootReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return

        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        if (prefs.getBoolean(PREF_AUTO_ADB, true)) {
            try {
                Settings.Secure.putInt(context.contentResolver, "adb_wifi_enabled", 1)
            } catch (e: SecurityException) {
                // WRITE_SECURE_SETTINGS not yet granted via adb shell pm grant
            }
        }

        val svc = Intent(context, CompanionService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.startForegroundService(svc)
        } else {
            context.startService(svc)
        }
    }

    companion object {
        const val PREFS_NAME = "companion_prefs"
        const val PREF_AUTO_ADB = "auto_adb_wifi"
    }
}
