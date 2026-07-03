package com.vrheadsetmanager.companion

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.Settings
import android.widget.Button
import android.widget.Switch
import android.widget.TextView

class MainActivity : Activity() {

    private lateinit var tvStatus: TextView
    private lateinit var tvAdbStatus: TextView
    private lateinit var switchAutoAdb: Switch
    private lateinit var btnEnableAdb: Button
    private lateinit var btnGrantSettings: Button

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        tvStatus        = findViewById(R.id.tv_status)
        tvAdbStatus     = findViewById(R.id.tv_adb_status)
        switchAutoAdb   = findViewById(R.id.switch_auto_adb)
        btnEnableAdb    = findViewById(R.id.btn_enable_adb)
        btnGrantSettings= findViewById(R.id.btn_grant_settings)

        val prefs = getSharedPreferences(BootReceiver.PREFS_NAME, MODE_PRIVATE)
        switchAutoAdb.isChecked = prefs.getBoolean(BootReceiver.PREF_AUTO_ADB, true)
        switchAutoAdb.setOnCheckedChangeListener { _, checked ->
            prefs.edit().putBoolean(BootReceiver.PREF_AUTO_ADB, checked).apply()
        }

        btnEnableAdb.setOnClickListener {
            try {
                val cur = Settings.Secure.getInt(contentResolver, "adb_wifi_enabled", 0)
                Settings.Secure.putInt(contentResolver, "adb_wifi_enabled", if (cur == 0) 1 else 0)
            } catch (_: SecurityException) {
                tvAdbStatus.text = "Error: WRITE_SECURE_SETTINGS not granted - grant via ADB"
            }
            updateUi()
        }

        btnGrantSettings.setOnClickListener {
            startActivity(Intent(Settings.ACTION_MANAGE_WRITE_SETTINGS).apply {
                data = Uri.parse("package:$packageName")
            })
        }

        // Ensure service is running
        startForegroundService(Intent(this, CompanionService::class.java))
    }

    override fun onResume() {
        super.onResume()
        updateUi()
    }

    private fun updateUi() {
        val adbEnabled = Settings.Secure.getInt(contentResolver, "adb_wifi_enabled", 0) == 1
        val canWrite = Settings.System.canWrite(this)

        tvStatus.text = "HTTP API: port ${CompanionService.HTTP_PORT}  |  UDP: port ${CompanionService.UDP_PORT}"
        tvAdbStatus.text = "ADB WiFi: ${if (adbEnabled) "ENABLED" else "DISABLED"}"
        btnEnableAdb.text = if (adbEnabled) "Disable ADB WiFi" else "Enable ADB WiFi"
        btnGrantSettings.text = if (canWrite) "WRITE_SETTINGS: Granted" else "Grant WRITE_SETTINGS"
        btnGrantSettings.isEnabled = !canWrite
    }
}
