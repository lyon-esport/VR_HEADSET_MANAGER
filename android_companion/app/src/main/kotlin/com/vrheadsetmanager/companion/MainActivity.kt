package com.vrheadsetmanager.companion

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.Settings
import android.view.View
import android.widget.AdapterView
import android.widget.ArrayAdapter
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.Spinner
import android.widget.Switch
import android.widget.TextView

class MainActivity : Activity() {

    private lateinit var tvStatus: TextView
    private lateinit var tvAdbPill: TextView
    private lateinit var tvEngine: TextView
    private lateinit var tvHint: TextView
    private lateinit var switchAutoAdb: Switch
    private lateinit var btnEnableAdb: Button
    private lateinit var btnGrantSettings: Button
    private lateinit var spinnerMode: Spinner
    private lateinit var rowPort: LinearLayout
    private lateinit var etPort: EditText
    private lateinit var btnApply: Button

    // spinner index -> engine BootMode (on/off is the auto-enable switch, so no "disabled" entry)
    private val modes = listOf(BootMode.TLS, BootMode.CLASSIC)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        tvStatus         = findViewById(R.id.tv_status)
        tvAdbPill        = findViewById(R.id.tv_adb_pill)
        tvEngine         = findViewById(R.id.tv_engine)
        tvHint           = findViewById(R.id.tv_hint)
        switchAutoAdb    = findViewById(R.id.switch_auto_adb)
        btnEnableAdb     = findViewById(R.id.btn_enable_adb)
        btnGrantSettings = findViewById(R.id.btn_grant_settings)
        spinnerMode      = findViewById(R.id.spinner_mode)
        rowPort          = findViewById(R.id.row_port)
        etPort           = findViewById(R.id.et_port)
        btnApply         = findViewById(R.id.btn_apply_connect)

        // master on/off is stored in device-protected prefs so the boot path reads the same value
        val prefs = SelfAdb.dpCtx(this).getSharedPreferences(BootReceiver.PREFS_NAME, MODE_PRIVATE)
        switchAutoAdb.isChecked = prefs.getBoolean(BootReceiver.PREF_AUTO_ADB, true)
        switchAutoAdb.setOnCheckedChangeListener { _, checked ->
            prefs.edit().putBoolean(BootReceiver.PREF_AUTO_ADB, checked).apply()
            if (checked) AdbBootManager.applyAsync(this)
            updateUi()
        }

        // Boot ADB mode dropdown (TLS / classic). On/off is the switch above.
        val labels = listOf(getString(R.string.mode_tls), getString(R.string.mode_classic))
        spinnerMode.adapter = ArrayAdapter(this, android.R.layout.simple_spinner_dropdown_item, labels)
        spinnerMode.setSelection(modes.indexOf(AdbBootManager.getBootMode(this)).coerceAtLeast(0))
        spinnerMode.onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
            override fun onItemSelected(p: AdapterView<*>?, v: View?, pos: Int, id: Long) {
                val mode = modes[pos]
                AdbBootManager.setBootMode(this@MainActivity, mode)
                rowPort.visibility = if (mode == BootMode.CLASSIC) View.VISIBLE else View.GONE
            }
            override fun onNothingSelected(p: AdapterView<*>?) {}
        }

        etPort.setText(AdbBootManager.getClassicPort(this).toString())
        rowPort.visibility = if (AdbBootManager.getBootMode(this) == BootMode.CLASSIC) View.VISIBLE else View.GONE

        btnApply.setOnClickListener {
            val port = etPort.text.toString().toIntOrNull()
            if (port != null && port in 1024..65535) AdbBootManager.setClassicPort(this, port)
            when (modes[spinnerMode.selectedItemPosition]) {
                BootMode.CLASSIC -> AdbBootManager.forceClassicNow(this)
                BootMode.TLS -> AdbBootManager.forceTlsNow(this)
                BootMode.NONE -> {}
            }
            tvEngine.postDelayed({ updateUi() }, 2500)
            updateUi()
        }

        btnEnableAdb.setOnClickListener {
            try {
                val cur = Settings.Global.getInt(contentResolver, "adb_wifi_enabled", 0)
                Settings.Global.putInt(contentResolver, "adb_wifi_enabled", if (cur == 0) 1 else 0)
            } catch (_: SecurityException) {
                tvHint.text = "WRITE_SECURE_SETTINGS not granted - run the adb grant below."
            }
            updateUi()
        }

        btnGrantSettings.setOnClickListener {
            startActivity(Intent(Settings.ACTION_MANAGE_WRITE_SETTINGS).apply {
                data = Uri.parse("package:$packageName")
            })
        }

        startForegroundService(Intent(this, CompanionService::class.java))
    }

    override fun onResume() {
        super.onResume()
        updateUi()
    }

    private fun updateUi() {
        val adbEnabled = try { Settings.Global.getInt(contentResolver, "adb_wifi_enabled", 0) == 1 } catch (_: Exception) { false }
        val canWrite = Settings.System.canWrite(this)

        tvStatus.text = "HTTP :${CompanionService.HTTP_PORT}    UDP :${CompanionService.UDP_PORT}"

        tvAdbPill.text = if (adbEnabled) "ENABLED" else "DISABLED"
        tvAdbPill.setBackgroundResource(if (adbEnabled) R.drawable.bg_pill_on else R.drawable.bg_pill_off)
        tvAdbPill.setTextColor(getColor(if (adbEnabled) R.color.vrhm_green else R.color.vrhm_text_secondary))

        btnEnableAdb.text = if (adbEnabled) getString(R.string.btn_disable_adb) else getString(R.string.btn_enable_adb)

        // Grant row only matters until WRITE_SETTINGS is granted; hide the button + hint once it is.
        btnGrantSettings.visibility = if (canWrite) android.view.View.GONE else android.view.View.VISIBLE
        tvHint.visibility = if (canWrite) android.view.View.GONE else android.view.View.VISIBLE

        val st = AdbBootManager.status(this)
        val lc = st["lastConnect"] as? Map<*, *>
        val conn = if (lc?.get("ok") == true) "connected (${lc["transport"]})" else "not connected"
        tvEngine.text = "engine  mode=${st["bootMode"]}  port=${st["classicPort"]}  $conn"
    }
}
