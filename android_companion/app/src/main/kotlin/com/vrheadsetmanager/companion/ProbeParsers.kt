package com.vrheadsetmanager.companion

/**
 * Pure-Kotlin parsers of the local shell probes (local-probes.md section 4). No Android types, so
 * the JVM unit tests run them against the shared fixtures (scripts\companionFixtures). Every parser
 * must give exactly the wire fields of the PowerShell side; a null value means "known absent".
 */
object ProbeParsers {
    /** Parser by catalogue name; null for an unknown parser. */
    fun parse(parser: String, lines: List<String>): Map<String, Any?>? = when (parser) {
        "controllers" -> ControllersParser.parse(lines)
        "thermal" -> ThermalParser.parse(lines)
        "display" -> DisplayParser.parse(lines)
        "battery_power" -> BatteryPowerMapper.fromDump(lines)
        else -> null
    }

    /** One decimal, half away from zero. */
    fun round1(v: Double): Double =
        if (v >= 0) Math.floor(v * 10.0 + 0.5) / 10.0 else -Math.floor(-v * 10.0 + 0.5) / 10.0

    /** Integer, half away from zero. */
    fun roundInt(v: Double): Int =
        if (v >= 0) Math.floor(v + 0.5).toInt() else -Math.floor(-v + 0.5).toInt()
}

object ControllersParser {
    private val SIDE = Regex("Type:\\s+(Left|Right)", RegexOption.IGNORE_CASE)
    private val BATT = Regex("Battery:\\s*(\\d+)%")
    private val STATE = Regex("ExternalStatus:\\s*(\\S+)")

    private class Side { var battery: Int? = null; var state: String = "none" }

    fun parse(lines: List<String>): Map<String, Any?> {
        val left = Side(); val right = Side()
        for (ln in lines) {
            if (!ln.contains("Paired device:")) continue
            val sm = SIDE.find(ln) ?: continue
            val s = if (sm.groupValues[1].equals("left", true)) left else right
            // The last line of a side wins.
            var batt = BATT.find(ln)?.groupValues?.get(1)?.toIntOrNull()
            val st = STATE.find(ln)?.groupValues?.get(1)?.trimEnd(',')?.lowercase()
            if (st != null) {
                s.state = st
                if (!st.startsWith("connected")) batt = null   // the dump keeps a stale level while searching
            } else s.state = "unknown"
            s.battery = batt
        }
        val m = LinkedHashMap<String, Any?>()
        m["ctrlLeft"] = left.battery
        m["ctrlRight"] = right.battery
        m["ctrlLeftState"] = left.state
        m["ctrlRightState"] = right.state
        return m
    }
}

object ThermalParser {
    private val TEMP = Regex("Temperature\\{mValue=([^,]+),\\s*mType=(\\d+),\\s*mName=([^,]*),\\s*mStatus=(\\d+)\\}")
    private class Sensor(val v: Double, val type: Int, val name: String)

    fun parse(lines: List<String>): Map<String, Any?> {
        var scan: List<String> = lines
        val head = lines.indexOfFirst { it.contains("Current temperatures from HAL") }
        if (head >= 0) {
            val out = ArrayList<String>()
            for (i in head + 1 until lines.size) {
                val l = lines[i]
                if (l.isNotEmpty() && !l[0].isWhitespace() && !l.contains("Temperature{")) break
                out.add(l)
            }
            scan = out
        }
        val sensors = ArrayList<Sensor>()
        for (l in scan) {
            val m = TEMP.find(l) ?: continue
            val v = m.groupValues[1].trim().toDoubleOrNull() ?: continue
            if (v.isNaN() || v <= 0.0 || v > 150.0) continue
            sensors.add(Sensor(v, m.groupValues[2].toInt(), m.groupValues[3]))
        }
        fun max(type: Int): Double? = sensors.filter { it.type == type }.maxOfOrNull { it.v }
        val t3 = sensors.filter { it.type == 3 }
        var skin: Double? = null
        for (re in listOf(Regex("^virtual-skin$", RegexOption.IGNORE_CASE), Regex("^skin", RegexOption.IGNORE_CASE),
            Regex("^surf-virt", RegexOption.IGNORE_CASE))) {
            val s = t3.firstOrNull { re.containsMatchIn(it.name) }
            if (s != null) { skin = s.v; break }
        }
        if (skin == null) skin = t3.maxOfOrNull { it.v }
        val m = LinkedHashMap<String, Any?>()
        m["cpuTemp"] = max(0)?.let { ProbeParsers.round1(it) }
        m["gpuTemp"] = max(1)?.let { ProbeParsers.round1(it) }
        m["skinTemp"] = skin?.let { ProbeParsers.round1(it) }
        return m
    }
}

object DisplayParser {
    private val ACTIVE = Regex("refreshRate=([0-9.]+)")
    private val RENDER = Regex("renderFrameRate ([0-9.]+)")
    private val FORCED = Regex("^forced=(\\d+)$")

    fun parse(lines: List<String>): Map<String, Any?> {
        var hz: Int? = null
        val act = lines.firstOrNull { it.contains("mActiveSfDisplayMode=") }
        if (act != null) hz = ACTIVE.find(act)?.groupValues?.get(1)?.toDoubleOrNull()?.let { ProbeParsers.roundInt(it) }
        if (hz == null) {
            for (l in lines) {
                val v = RENDER.find(l)?.groupValues?.get(1)?.toDoubleOrNull()
                if (v != null) { hz = ProbeParsers.roundInt(v); break }
            }
        }
        var forced: Int? = null
        for (l in lines) {
            val f = FORCED.find(l.trim())?.groupValues?.get(1)?.toIntOrNull()
            if (f != null && f > 0) { forced = f; break }
        }
        val m = LinkedHashMap<String, Any?>()
        m["refreshHz"] = hz
        m["refreshForcedHz"] = forced
        return m
    }
}

/** Plug / charge state: the app maps the battery intent, the PC parity probe parses `dumpsys battery`. */
object BatteryPowerMapper {
    private val POWERED = Regex("^\\s*(AC|USB|Wireless|Dock) powered:\\s*(true|false)", RegexOption.IGNORE_CASE)
    private val COUNTER = Regex("Charge counter:\\s*(\\d+)")
    private val STATUS = Regex("^\\s*status:\\s*(\\d+)")

    fun pluggedName(bits: Int): String = when {
        bits and 1 != 0 -> "ac"
        bits and 2 != 0 -> "usb"
        bits and 4 != 0 -> "wireless"
        bits and 8 != 0 -> "dock"
        else -> "none"
    }

    fun statusName(status: Int): String = when (status) {
        2 -> "charging"
        3 -> "discharging"
        4 -> "not_charging"
        5 -> "full"
        else -> "unknown"
    }

    fun counterMah(uah: Long?): Int? =
        if (uah == null || uah == Int.MIN_VALUE.toLong() || uah <= 0L) null else (uah / 1000L).toInt().takeIf { it > 0 }

    fun fromIntent(plugged: Int, status: Int, chargeCounterUah: Long?): Map<String, Any?> = linkedMapOf(
        "plugged" to pluggedName(plugged),
        "battStatus" to statusName(status),
        "chargeCounterMah" to counterMah(chargeCounterUah)
    )

    fun fromDump(lines: List<String>): Map<String, Any?> {
        var status = -1
        var counter: Long? = null
        val on = HashSet<String>()
        for (l in lines) {
            val p = POWERED.find(l)
            if (p != null && p.groupValues[2].equals("true", true)) on.add(p.groupValues[1].lowercase())
            COUNTER.find(l)?.let { counter = it.groupValues[1].toLongOrNull() }
            STATUS.find(l)?.let { status = it.groupValues[1].toInt() }
        }
        var plugged = "none"
        for (o in listOf("ac", "usb", "wireless", "dock")) if (o in on) { plugged = o; break }
        return linkedMapOf("plugged" to plugged, "battStatus" to statusName(status), "chargeCounterMah" to counterMah(counter))
    }
}
