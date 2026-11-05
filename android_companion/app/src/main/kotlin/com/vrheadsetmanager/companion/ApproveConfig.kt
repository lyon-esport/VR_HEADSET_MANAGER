package com.vrheadsetmanager.companion

import android.content.Context

/**
 * Operator-controlled configuration of the auto-approve feature.
 *
 * Auto-approve of Android's "allow debugging" dialog is OFF by default and, when on, only
 * approves a per-computer dialog whose RSA fingerprint is on the allowlist. The allowlist is
 * provisioned by VRHM over ADB at onboarding (the VRHM server key plus the keys of PCs running
 * the VRHM Headset Toolbox). Stored in device-protected prefs so it is readable before unlock.
 */
object ApproveConfig {
    const val PREFS = "approve"
    const val KEY_AUTO = "auto_approve"
    const val KEY_TRUSTED = "trusted_fingerprints" // newline-separated RSA fingerprints

    private fun prefs(ctx: Context) =
        SelfAdb.dpCtx(ctx.applicationContext).getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun autoApprove(ctx: Context): Boolean = prefs(ctx).getBoolean(KEY_AUTO, false)

    fun setAutoApprove(ctx: Context, on: Boolean) {
        prefs(ctx).edit().putBoolean(KEY_AUTO, on).apply()
    }

    fun trustedFingerprints(ctx: Context): List<String> =
        (prefs(ctx).getString(KEY_TRUSTED, "") ?: "")
            .split("\n").map { it.trim() }.filter { it.isNotEmpty() }

    fun addTrusted(ctx: Context, fingerprint: String) {
        val fp = fingerprint.trim()
        if (fp.isEmpty()) return
        val cur = trustedFingerprints(ctx).toMutableList()
        if (cur.none { it.equals(fp, ignoreCase = true) }) {
            cur.add(fp)
            prefs(ctx).edit().putString(KEY_TRUSTED, cur.joinToString("\n")).apply()
        }
    }

    fun setTrusted(ctx: Context, fingerprints: List<String>) {
        prefs(ctx).edit().putString(KEY_TRUSTED, fingerprints.joinToString("\n")).apply()
    }

    fun clearTrusted(ctx: Context) {
        prefs(ctx).edit().remove(KEY_TRUSTED).apply()
    }
}
