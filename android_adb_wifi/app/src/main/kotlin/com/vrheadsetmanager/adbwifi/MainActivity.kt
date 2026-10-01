package com.vrheadsetmanager.adbwifi

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Bundle
import android.provider.Settings
import android.view.View
import android.widget.Button
import android.widget.CheckBox
import android.widget.EditText
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.Executors

class MainActivity : Activity() {

    private lateinit var prefs: Prefs
    private val worker = Executors.newSingleThreadExecutor()
    @Volatile private var busy = false

    private lateinit var tvStatus: TextView
    private lateinit var tvConnect: TextView
    private lateinit var etPort: EditText
    private lateinit var btnEnable: Button
    private lateinit var btnDisable: Button
    private lateinit var cbEnableAtLaunch: CheckBox
    private lateinit var cbStartOnBoot: CheckBox
    private lateinit var cbAutoHide: CheckBox
    private lateinit var tvSetup: TextView
    private lateinit var btnOverlay: Button
    private lateinit var tvLog: TextView
    private lateinit var scrollLog: ScrollView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        prefs = Prefs(this)

        tvStatus = findViewById(R.id.tv_status)
        tvConnect = findViewById(R.id.tv_connect)
        etPort = findViewById(R.id.et_port)
        btnEnable = findViewById(R.id.btn_enable)
        btnDisable = findViewById(R.id.btn_disable)
        cbEnableAtLaunch = findViewById(R.id.cb_enable_at_launch)
        cbStartOnBoot = findViewById(R.id.cb_start_on_boot)
        cbAutoHide = findViewById(R.id.cb_auto_hide)
        tvSetup = findViewById(R.id.tv_setup)
        btnOverlay = findViewById(R.id.btn_overlay)
        tvLog = findViewById(R.id.tv_log)
        scrollLog = findViewById(R.id.scroll_log)

        etPort.setText(prefs.port.toString())
        cbEnableAtLaunch.isChecked = prefs.enableAtLaunch
        cbStartOnBoot.isChecked = prefs.startOnBoot
        cbAutoHide.isChecked = prefs.autoHide
        cbEnableAtLaunch.setOnCheckedChangeListener { _, checked -> prefs.enableAtLaunch = checked }
        cbStartOnBoot.setOnCheckedChangeListener { _, checked ->
            prefs.startOnBoot = checked
            // The startup activation reports its result in a notification
            if (checked && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
            }
            refresh()
        }
        cbAutoHide.setOnCheckedChangeListener { _, checked -> prefs.autoHide = checked }

        btnEnable.setOnClickListener { readPort()?.let { enable(it, automatic = false) } }
        btnDisable.setOnClickListener { disable() }
        btnOverlay.setOnClickListener { openOverlaySettings() }

        val fromBoot = intent.getBooleanExtra(EXTRA_FROM_BOOT, false)
        if (savedInstanceState == null && (prefs.enableAtLaunch || fromBoot)) {
            enable(prefs.port, automatic = true)
        }
    }

    override fun onResume() {
        super.onResume()
        refresh()
    }

    override fun onDestroy() {
        worker.shutdown()
        super.onDestroy()
    }

    /** Validates the port field and saves it; null (with an error shown) when invalid. */
    private fun readPort(): Int? {
        val port = etPort.text.toString().trim().toIntOrNull()
        if (port == null || port < Prefs.MIN_PORT || port > Prefs.MAX_PORT) {
            etPort.error = getString(R.string.error_port, Prefs.MIN_PORT, Prefs.MAX_PORT)
            return null
        }
        prefs.port = port
        return port
    }

    private fun enable(port: Int, automatic: Boolean) {
        runTask(getString(R.string.log_enabling, port)) {
            val result = AdbWifiController.enable(applicationContext, port, ::log)
            runOnUiThread {
                if (result.success && automatic && prefs.autoHide && !isFinishing) {
                    Toast.makeText(this, result.message, Toast.LENGTH_SHORT).show()
                    // Leave a moment to read the result, then hide the window
                    tvStatus.postDelayed({ if (!isFinishing) finish() }, AUTO_HIDE_DELAY_MS)
                }
            }
            result
        }
    }

    private fun disable() {
        runTask(getString(R.string.log_disabling)) { AdbWifiController.disable(applicationContext, ::log) }
    }

    private fun runTask(title: String, task: () -> AdbWifiController.Result) {
        if (busy) return
        busy = true
        setButtonsEnabled(false)
        tvStatus.text = getString(R.string.status_working)
        log(title)
        worker.execute {
            val result = try { task() } catch (e: Exception) { AdbWifiController.Result(false, e.toString()) }
            log((if (result.success) "OK: " else "FAILED: ") + result.message)
            busy = false
            runOnUiThread {
                setButtonsEnabled(true)
                refresh()
            }
        }
    }

    private fun setButtonsEnabled(enabled: Boolean) {
        btnEnable.isEnabled = enabled
        btnDisable.isEnabled = enabled
    }

    /** Updates status and setup hints. Port probing is quick (localhost), done off the UI thread. */
    private fun refresh() {
        if (busy || worker.isShutdown) return
        val port = prefs.port
        worker.execute {
            val enabled = AdbWifiController.isEnabled(port)
            val ip = NetUtils.wifiIpv4()?.hostAddress
            runOnUiThread { showStatus(port, enabled, ip) }
        }
    }

    private fun showStatus(port: Int, enabled: Boolean, ip: String?) {
        if (busy) return
        tvStatus.text = getString(if (enabled) R.string.status_enabled else R.string.status_disabled, port)
        tvStatus.setTextColor(getColor(if (enabled) R.color.ok else R.color.ko))
        tvConnect.text = when {
            ip == null -> getString(R.string.no_wifi)
            enabled -> getString(R.string.connect_cmd, ip, port)
            else -> getString(R.string.headset_ip, ip)
        }

        val hasPermission = AdbWifiController.hasWriteSecureSettings(this)
        val canShowAtBoot = Settings.canDrawOverlays(this)
        val lines = mutableListOf<String>()
        lines += getString(if (hasPermission) R.string.setup_perm_ok else R.string.setup_perm_missing, packageName)
        lines += getString(if (prefs.clientAuthorized) R.string.setup_client_ok else R.string.setup_client_missing)
        if (prefs.startOnBoot && !canShowAtBoot) lines += getString(R.string.setup_overlay_missing, packageName)
        tvSetup.text = lines.joinToString("\n\n")
        btnOverlay.visibility = if (prefs.startOnBoot && !canShowAtBoot) View.VISIBLE else View.GONE
    }

    private fun openOverlaySettings() {
        try {
            startActivity(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:$packageName")))
        } catch (_: Exception) {
            Toast.makeText(this, getString(R.string.overlay_settings_unavailable), Toast.LENGTH_LONG).show()
        }
    }

    private fun log(message: String) {
        if (message.isBlank()) return
        val line = "${SimpleDateFormat("HH:mm:ss", Locale.US).format(Date())}  ${message.trim()}"
        runOnUiThread {
            tvLog.append(if (tvLog.text.isEmpty()) line else "\n$line")
            scrollLog.post { scrollLog.fullScroll(View.FOCUS_DOWN) }
        }
    }

    companion object {
        const val EXTRA_FROM_BOOT = "from_boot"
        private const val AUTO_HIDE_DELAY_MS = 1500L
    }
}
