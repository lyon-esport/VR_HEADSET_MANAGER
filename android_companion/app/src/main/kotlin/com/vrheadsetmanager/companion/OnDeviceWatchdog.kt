package com.vrheadsetmanager.companion

import android.content.Context
import android.provider.Settings
import android.util.Base64
import android.util.Log
import java.util.concurrent.atomic.AtomicBoolean

/**
 * On-headset watchdog (companion 1.4.2). A force-stop (for example QGO "free RAM") clears every alarm,
 * job and receiver of the app, so nothing inside it can bring it back. The self-ADB shell (uid shell)
 * launches a detached loop that is NOT a child of the app: it restarts the service through the
 * CmdReceiver `start` command, and keeps the approver accessibility service enabled.
 *
 * Gate: the "auto-enable ADB on boot" switch, mirrored into `settings global vrhm_companion_watchdog`
 * (1/0) which the loop reads; it exits by itself when the value is not 1. All shell work goes through
 * [ShellSession] (single owner of the self-ADB connection).
 */
object OnDeviceWatchdog {
    private const val TAG = "VrhmWatchdog"
    const val GATE_KEY = "vrhm_companion_watchdog"
    private const val SCRIPT = "/data/local/tmp/vrhm_watchdog.sh"
    private const val PIDFILE = "/data/local/tmp/vrhm_watchdog.pid"
    private const val LASTFILE = "/data/local/tmp/vrhm_watchdog.last"
    private const val PKG = "com.vrheadsetmanager.companion"

    private val running = AtomicBoolean(false)
    @Volatile private var armed = false
    @Volatile private var pid = 0
    @Volatile private var lastRestartEpoch = 0L
    @Volatile private var lastError = ""
    @Volatile private var lastSyncAt = 0L
    @Volatile private var armCount = 0

    // '~' stands for the dollar sign so the shell script stays readable inside a Kotlin string.
    private val SCRIPT_TEMPLATE = """#!/system/bin/sh
P=@PIDFILE@
L=@LASTFILE@
PK=@PKG@
if [ -f ~P ]; then
  o=~(cat ~P)
  if [ -n "~o" ] && [ "~o" != "~~" ] && grep -q vrhm_watchdog /proc/~o/cmdline 2>/dev/null; then exit 0; fi
fi
echo ~~ > ~P
log -t VRHMWatchdog "started ~~"
while true; do
  g=~(settings get global @GATE@)
  if [ "~g" != "1" ]; then log -t VRHMWatchdog "gate off, exit"; rm -f ~P; exit 0; fi
  if [ -z "~(pidof ~PK)" ] || [ "~(dumpsys activity services ~PK | grep -c ServiceRecord)" = "0" ]; then
    log -t VRHMWatchdog "companion service not running, starting it"
    am broadcast -f 0x20 -n ~PK/.CmdReceiver -a ~PK.CMD --es cmd start >/dev/null 2>&1
    date +%s > ~L
  fi
  cur=~(settings get secure enabled_accessibility_services)
  case ":~cur:" in
    *":~PK/~PK.ApproveService:"*) ;;
    *)
      if [ -z "~cur" ] || [ "~cur" = "null" ]; then n="~PK/~PK.ApproveService"; else n="~cur:~PK/~PK.ApproveService"; fi
      settings put secure enabled_accessibility_services "~n"
      log -t VRHMWatchdog "approver service re-enabled"
      ;;
  esac
  [ "~(settings get secure accessibility_enabled)" = "1" ] || settings put secure accessibility_enabled 1
  sleep 20
done
"""

    private fun scriptText(): String = SCRIPT_TEMPLATE.replace('~', '$')
        .replace("@PIDFILE@", PIDFILE).replace("@LASTFILE@", LASTFILE)
        .replace("@PKG@", PKG).replace("@GATE@", GATE_KEY)

    fun status(): Map<String, Any?> = linkedMapOf(
        "armed" to armed, "pid" to pid,
        "lastRestart" to (if (lastRestartEpoch > 0) lastRestartEpoch else null),
        "lastSyncAt" to (if (lastSyncAt > 0) lastSyncAt else null),
        "armCount" to armCount, "error" to lastError.ifEmpty { null }
    )

    fun gateWanted(ctx: Context): Boolean = AdbBootManager.autoEnabled(ctx) && !AdbBootManager.isPico()

    private fun mirrorGate(ctx: Context, want: Boolean) {
        try {
            val cur = Settings.Global.getInt(ctx.contentResolver, GATE_KEY, -1)
            val v = if (want) 1 else 0
            if (cur != v) Settings.Global.putInt(ctx.contentResolver, GATE_KEY, v)
        } catch (e: Throwable) { lastError = "gate: ${e.message}" }
    }

    /** One background pass: mirror the gate, then arm (when wanted and not alive) or disarm. Single-flight. */
    fun syncAsync(ctx: Context) {
        val app = ctx.applicationContext
        if (!running.compareAndSet(false, true)) return
        Thread({
            try { sync(app) } catch (e: Throwable) { lastError = "sync: ${e.message}" }
            finally { running.set(false) }
        }, "VRHM-OnDeviceWd").also { it.isDaemon = true; it.start() }
    }

    private fun sync(app: Context) {
        if (AdbBootManager.isPico()) { armed = false; lastError = "pico: not supported"; return }
        val want = gateWanted(app)
        mirrorGate(app, want)
        ShellSession.init(app)
        val chk = "p=\$(cat $PIDFILE 2>/dev/null); if [ -n \"\$p\" ] && grep -q vrhm_watchdog /proc/\$p/cmdline 2>/dev/null; then echo ALIVE \$p \$(cat $LASTFILE 2>/dev/null); else echo DEAD; fi"
        var r = ShellSession.run(chk, 8000, 4096)
        if (!r.ok) { lastError = r.error ?: "shell"; if (r.down) armed = false; return }
        var line = r.lines.lastOrNull()?.trim() ?: ""
        if (!want) {
            if (line.startsWith("ALIVE")) {
                val p = line.split(" ").getOrNull(1) ?: ""
                ShellSession.run("kill $p 2>/dev/null; rm -f $PIDFILE", 5000, 8192)
                Log.i(TAG, "disarmed (pid $p)")
            }
            armed = false; pid = 0; lastSyncAt = System.currentTimeMillis(); lastError = ""
            return
        }
        if (!line.startsWith("ALIVE")) {
            val b64 = Base64.encodeToString(scriptText().toByteArray(Charsets.UTF_8), Base64.NO_WRAP)
            val w = ShellSession.run("echo $b64 | base64 -d > $SCRIPT && chmod 755 $SCRIPT; echo wrote", 8000, 65536)
            if (!w.ok || w.lines.none { it.trim() == "wrote" }) { lastError = "script write failed: ${w.error ?: w.exit} ok=${w.ok} lines=${w.lines.size} b64=${b64.length}"; armed = false; return }
            ShellSession.run("setsid nohup sh $SCRIPT >/dev/null 2>&1 </dev/null & true", 5000, 8192)
            try { Thread.sleep(1500) } catch (_: InterruptedException) {}
            r = ShellSession.run(chk, 8000, 4096)
            line = r.lines.lastOrNull()?.trim() ?: ""
            if (line.startsWith("ALIVE")) { armCount++; Log.i(TAG, "armed: $line") }
            else { lastError = "launch failed"; armed = false; return }
        }
        val parts = line.split(" ")
        armed = true; pid = parts.getOrNull(1)?.toIntOrNull() ?: 0
        lastRestartEpoch = parts.getOrNull(2)?.toLongOrNull() ?: lastRestartEpoch
        lastSyncAt = System.currentTimeMillis(); lastError = ""
    }
}
