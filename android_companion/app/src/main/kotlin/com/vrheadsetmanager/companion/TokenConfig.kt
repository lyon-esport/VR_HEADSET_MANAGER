package com.vrheadsetmanager.companion

import android.content.Context

/** Shared API token (device-protected prefs "companion_api", key "token"). */
object TokenConfig {
    const val PREFS = "companion_api"
    private const val KEY = "token"

    private fun prefs(ctx: Context) =
        SelfAdb.dpCtx(ctx.applicationContext).getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun token(ctx: Context): String? = prefs(ctx).getString(KEY, null)?.takeIf { it.isNotBlank() }
    /** Stores the token; refuses a blank/whitespace one (would leave the API unprotected). */
    fun setToken(ctx: Context, token: String?): Boolean {
        val t = token?.trim() ?: return false
        if (t.isEmpty()) return false
        prefs(ctx).edit().putString(KEY, t).apply()
        return true
    }
    fun clearToken(ctx: Context) { prefs(ctx).edit().remove(KEY).apply() }
    fun hasToken(ctx: Context): Boolean = token(ctx) != null

    fun matches(ctx: Context, provided: String?): Boolean {
        if (provided == null) return false
        val t = token(ctx) ?: return false
        return java.security.MessageDigest.isEqual(t.toByteArray(Charsets.UTF_8), provided.toByteArray(Charsets.UTF_8))
    }
}
