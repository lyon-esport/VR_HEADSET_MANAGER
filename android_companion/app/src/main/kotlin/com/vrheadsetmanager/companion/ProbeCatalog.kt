package com.vrheadsetmanager.companion

import android.content.Context
import com.google.gson.JsonObject
import com.google.gson.JsonParser

data class ProbeField(val name: String, val type: String, val unit: String)

data class ProbeDef(
    val id: String, val description: String, val command: String, val parser: String,
    val everySec: Int, val minEverySec: Int, val maxEverySec: Int, val screenOffFactor: Int,
    val timeoutMs: Int, val maxOutputBytes: Int,
    val brands: List<String>, val runOn: List<String>, val enabled: Boolean, val fields: List<ProbeField>
)

/** The probe catalogue (assets/probes.json, copied from templates\companion\probes.json at build time). */
class ProbeCatalog(val version: String, val probes: List<ProbeDef>) {
    companion object {
        const val ASSET = "probes.json"
        private val ID = Regex("^[a-z][a-z0-9_]{1,31}$")

        /** Parsed catalogue, or null when it is unreadable or its schema is not 1. Never throws. */
        fun parse(text: String): ProbeCatalog? = try {
            val root = JsonParser.parseString(text).asJsonObject
            if (root.get("schema")?.asInt != 1) null else {
                val list = ArrayList<ProbeDef>()
                val seen = HashSet<String>()
                for (e in root.getAsJsonArray("probes")) {
                    try {
                    val p = e.asJsonObject
                    val id = p.get("id").asString
                    if (!ID.matches(id) || !seen.add(id)) { warn("probe skipped: bad or duplicate id $id"); continue }
                    val bad = badCommand(p.get("command").asString)
                    if (bad != null) { warn("probe $id skipped: $bad"); continue }
                    list.add(ProbeDef(
                        id, str(p, "description"), p.get("command").asString, p.get("parser").asString,
                        p.get("everySec").asInt, p.get("minEverySec").asInt, p.get("maxEverySec").asInt,
                        p.get("screenOffFactor")?.asInt ?: 1, p.get("timeoutMs").asInt, p.get("maxOutputBytes").asInt,
                        strList(p, "brands"), strList(p, "runOn"), p.get("enabled")?.asBoolean ?: true,
                        p.getAsJsonArray("fields").map {
                            val f = it.asJsonObject
                            ProbeField(f.get("name").asString, str(f, "type"), str(f, "unit"))
                        }
                    ))
                    } catch (x: Throwable) { warn("probe entry skipped: ${x.message}") }
                }
                ProbeCatalog(root.get("version").asString, list)
            }
        } catch (_: Throwable) { null }

        /** Why a command is refused, or null. A trailing ; or & or a # would swallow the framing marker. */
        fun badCommand(c: String): String? {
            val t = c.trim()
            return when {
                t.isEmpty() -> "empty command"
                t.endsWith(";") || t.endsWith("&") -> "command ends with ; or &"
                t.contains("#") -> "command contains #"
                t.contains("__VRHM_") -> "command contains the marker prefix"
                else -> null
            }
        }

        private fun warn(m: String) { try { android.util.Log.w("VrhmProbe", m) } catch (_: Throwable) {} }

        fun load(ctx: Context): ProbeCatalog? = try {
            parse(ctx.assets.open(ASSET).bufferedReader(Charsets.UTF_8).use { it.readText() })
        } catch (_: Throwable) { null }

        private fun str(o: JsonObject, k: String) = o.get(k)?.takeIf { it.isJsonPrimitive }?.asString ?: ""
        private fun strList(o: JsonObject, k: String): List<String> =
            o.getAsJsonArray(k)?.map { it.asString } ?: emptyList()
    }
}
