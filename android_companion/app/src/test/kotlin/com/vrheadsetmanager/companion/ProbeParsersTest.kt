package com.vrheadsetmanager.companion

import com.google.gson.JsonObject
import com.google.gson.JsonParser
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

/**
 * Parity tests (local-probes.md section 10): the Kotlin parsers must give exactly the wire fields
 * the shared fixtures (scripts\companionFixtures) expect, which are the same the PowerShell side
 * checks in scripts\Test-CompanionProbes.ps1.
 */
class ProbeParsersTest {
    private val fixtures: File? = System.getProperty("vrhm.fixtures")?.let { File(it) }?.takeIf { it.isDirectory }

    private fun lines(f: File): List<String> =
        f.readText(Charsets.UTF_8).replace("\r\n", "\n").replace("\r", "\n").split("\n").let {
            if (it.isNotEmpty() && it.last().isEmpty()) it.dropLast(1) else it
        }

    private fun check(probe: String, parser: String) {
        assumeTrue("fixtures folder missing: test pending", fixtures != null)
        val dir = File(fixtures, probe)
        val expected = JsonParser.parseString(File(dir, "expected.json").readText(Charsets.UTF_8)).asJsonObject
        var n = 0
        for ((name, exp) in expected.entrySet()) {
            val txt = File(dir, name)
            assertTrue("fixture missing: $probe/$name", txt.exists())
            val intent = File(dir, name.removeSuffix(".txt") + ".intent.json")
            val got: Map<String, Any?> = if (probe == "battery_power" && intent.exists()) {
                val j = JsonParser.parseString(intent.readText(Charsets.UTF_8)).asJsonObject
                BatteryPowerMapper.fromIntent(j.get("plugged").asInt, j.get("status").asInt, j.get("chargeCounterUah").asLong)
            } else ProbeParsers.parse(parser, lines(txt))!!
            assertSame("$probe/$name", exp.asJsonObject, got)
            n++
        }
        assertTrue("no fixture in $probe", n > 0)
        // The dump parser of battery_power must agree with the same expectations.
        if (probe == "battery_power") {
            for ((name, exp) in expected.entrySet()) assertSame("$probe/$name (dump)", exp.asJsonObject, ProbeParsers.parse(parser, lines(File(dir, name)))!!)
        }
    }

    private fun assertSame(label: String, exp: JsonObject, got: Map<String, Any?>) {
        assertEquals("$label field set", exp.keySet(), got.keys)
        for ((k, ev) in exp.entrySet()) {
            val g = got[k]
            when {
                ev.isJsonNull -> assertEquals("$label.$k", null, g)
                ev.isJsonPrimitive && ev.asJsonPrimitive.isNumber -> {
                    assertNotNull("$label.$k is null", g)
                    assertEquals("$label.$k", ev.asDouble, (g as Number).toDouble(), 0.051)
                }
                else -> assertEquals("$label.$k", ev.asString, g.toString())
            }
        }
    }

    @Test fun controllers() = check("controllers", "controllers")
    @Test fun thermal() = check("thermal", "thermal")
    @Test fun display() = check("display", "display")
    @Test fun batteryPower() = check("battery_power", "battery_power")

    @Test fun catalogueParses() {
        val p = System.getProperty("vrhm.catalog")?.let { File(it) }
        assumeTrue("catalogue missing: test pending", p != null && p.exists())
        val cat = ProbeCatalog.parse(p!!.readText(Charsets.UTF_8))
        assertNotNull("catalogue must parse with schema 1", cat)
        assertTrue(cat!!.probes.isNotEmpty())
        val declared = JsonParser.parseString(p.readText(Charsets.UTF_8)).asJsonObject.getAsJsonArray("probes").size()
        assertEquals("no catalogue probe may be skipped by validation", declared, cat.probes.size)
        for (d in cat.probes) {
            assertNotNull("parser ${d.parser} of ${d.id}", ProbeParsers.parse(d.parser, emptyList()))
            assertTrue("${d.id} cadence range", d.minEverySec <= d.everySec && d.everySec <= d.maxEverySec)
        }
    }

    @Test fun schemaMismatchRejected() {
        assertEquals(null, ProbeCatalog.parse("{\"schema\":2,\"version\":\"x\",\"probes\":[]}"))
    }

    @Test fun framingMarkerOnOwnLine() {
        val f = ShellFraming.frame("dumpsys battery", 7)
        assertTrue(f.endsWith("\n") && f.count { it == '\n' } == 1)
        assertTrue(f.contains("; echo; echo \"__VRHM_7_"))
        assertEquals(Pair(7, 0), ShellFraming.parseMarker("__VRHM_7_0__"))
        assertEquals(Pair(3, 127), ShellFraming.parseMarker("__VRHM_3_127__"))
        assertEquals(null, ShellFraming.parseMarker("x__VRHM_7_0__"))
        assertEquals(null, ShellFraming.parseMarker("echo \"__VRHM_7_$?__\""))
        assertEquals(listOf("a", "b"), ShellFraming.dropFramingBlank(listOf("a", "b", "")))
        assertEquals(listOf("a"), ShellFraming.dropFramingBlank(listOf("a")))
    }

    @Test fun catalogueValidationSkipsBadProbes() {
        fun probe(id: String, cmd: String) = "{\"id\":\"$id\",\"command\":\"$cmd\",\"parser\":\"display\",\"everySec\":10,\"minEverySec\":5,\"maxEverySec\":60," +
            "\"timeoutMs\":1000,\"maxOutputBytes\":100,\"brands\":[\"meta\"],\"runOn\":[\"companion\"],\"fields\":[{\"name\":\"refreshHz\",\"type\":\"int\"}]}"
        val text = "{\"schema\":1,\"version\":\"v\",\"probes\":[" + listOf(
            probe("ok_one", "getprop a"), probe("semi", "getprop a;"), probe("amp", "sleep 1 &"),
            probe("hash", "echo a # b"), "{\"id\":\"broken\"}"
        ).joinToString(",") + "]}"
        val cat = ProbeCatalog.parse(text)
        assertNotNull(cat)
        assertEquals(listOf("ok_one"), cat!!.probes.map { it.id })
    }
}
