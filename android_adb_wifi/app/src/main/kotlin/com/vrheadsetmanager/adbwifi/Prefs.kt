package com.vrheadsetmanager.adbwifi

import android.content.Context
import android.content.SharedPreferences

/** User options, persisted in SharedPreferences. */
class Prefs(context: Context) {

    private val sp: SharedPreferences =
        context.applicationContext.getSharedPreferences(NAME, Context.MODE_PRIVATE)

    /** TCP port adbd should listen on (classic "adb tcpip <port>" mode). */
    var port: Int
        get() = sp.getInt(KEY_PORT, DEFAULT_PORT)
        set(value) = sp.edit().putInt(KEY_PORT, value).apply()

    var enableAtLaunch: Boolean
        get() = sp.getBoolean(KEY_ENABLE_AT_LAUNCH, true)
        set(value) = sp.edit().putBoolean(KEY_ENABLE_AT_LAUNCH, value).apply()

    var startOnBoot: Boolean
        get() = sp.getBoolean(KEY_START_ON_BOOT, false)
        set(value) = sp.edit().putBoolean(KEY_START_ON_BOOT, value).apply()

    var autoHide: Boolean
        get() = sp.getBoolean(KEY_AUTO_HIDE, false)
        set(value) = sp.edit().putBoolean(KEY_AUTO_HIDE, value).apply()

    /** Last port we saw adbd listening on - used to switch port without wireless debugging. */
    var lastActivePort: Int
        get() = sp.getInt(KEY_LAST_ACTIVE_PORT, 0)
        set(value) = sp.edit().putInt(KEY_LAST_ACTIVE_PORT, value).apply()

    /** True once the headset accepted the built-in adb client's key ("Always allow"). */
    var clientAuthorized: Boolean
        get() = sp.getBoolean(KEY_CLIENT_AUTHORIZED, false)
        set(value) = sp.edit().putBoolean(KEY_CLIENT_AUTHORIZED, value).apply()

    companion object {
        const val DEFAULT_PORT = 5555
        const val MIN_PORT = 1024
        const val MAX_PORT = 65535

        private const val NAME = "adb_wifi_prefs"
        private const val KEY_PORT = "port"
        private const val KEY_ENABLE_AT_LAUNCH = "enable_at_launch"
        private const val KEY_START_ON_BOOT = "start_on_boot"
        private const val KEY_AUTO_HIDE = "auto_hide"
        private const val KEY_LAST_ACTIVE_PORT = "last_active_port"
        private const val KEY_CLIENT_AUTHORIZED = "client_authorized"
    }
}
