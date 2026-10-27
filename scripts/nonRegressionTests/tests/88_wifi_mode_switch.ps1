#Requires -Version 5.1
<#
.SYNOPSIS
    Section 88 - ADB WiFi mode switch on a real Meta headset (ADR-0034, ADR-0037). OPT-IN.

.DESCRIPTION
    Dot-sourced by scripts\Invoke-NonRegressionTests.ps1 inside a section context.

    Runs only with -TestModeSwitch (or VRHM_TEST_MODE_SWITCH=1); otherwise it SKIPs. It moves the
    test headset to the OTHER WiFi ADB mode and back through the app's own switch engine, i.e.
    exactly what an operator triggers by changing ADB.wifi_preferred_mode:

      classic -> TLS : the engine enables Wireless debugging over the classic session
      TLS -> classic : the engine runs `adb tcpip` over the published TLS session

    Every switch restarts the headset's ADB daemon (running captures drop for ~10-20 s and the TLS
    port changes), so the number of switches is CAPPED: -MaxModeSwitches (default 2: out and back).
    One extra rollback switch is allowed on top of the cap, never more. The second switch IS the
    rollback, so a clean run ends in the mode it started in.

    Safety:
      - Meta only (the app never switches a Pico, ADR-0038); the headset is identified by serial.
      - Skips when ADB.wifi_preferred_mode in the sandbox config would fight the test.
      - The ADB WiFi config keys are restored at the end without causing a switch.
      - A state file (nrt_wifi_mode_state.json, next to the reports) records the original mode, so a
        crashed run can be put back by hand: set ADB.wifi_preferred_mode to that mode in the
        config page, or run `adb tcpip 5555` (classic) / turn Wireless debugging on (TLS).

    ASCII only (CLAUDE.md rule 1).
#>

$target  = $global:TestRun.TargetRoot
$devRoot = $global:TestRun.DevRoot
$depth   = $global:TestRun.Depth

$appUp = Confirm-SandboxApp -TargetRoot $target -DevRoot $devRoot
$ports = Get-NrtSandboxPorts -TargetRoot $target

$nrt88 = @{
    Enabled   = [bool]$global:TestRun.TestModeSwitch
    Max       = [int]$global:TestRun.MaxModeSwitches
    Switches  = 0
    Headset   = $null
    Row       = $null
    Original  = ''
    OrigCfg   = $null
    Ready     = $false
    Why       = 'section 88 is opt-in: pass -TestModeSwitch (or set VRHM_TEST_MODE_SWITCH=1)'
    StateFile = (Join-Path $devRoot 'scripts\nonRegressionTests\reports\nrt_wifi_mode_state.json')
}
if ($nrt88.Max -lt 2) { $nrt88.Max = 2 }

if ($depth -eq 'Light') { $nrt88.Why = 'hardware section, not run at Light depth' }
elseif ($nrt88.Enabled) {
    $nrt88.Headset = Resolve-NrtTestHeadset -DevRoot $devRoot -AdbPort $ports.Adb
    if (-not $nrt88.Headset) {
        $nrt88.Why = 'no reachable headset in the dev registry (classic or TLS, identity verified) - pass -HeadsetName to force one'
    }
    elseif ([string]$nrt88.Headset.Brand -eq 'Pico') {
        $nrt88.Why = 'Pico headset: the app never switches a Pico to ADB over TLS (ADR-0038); this test is Meta only'
    }
    elseif (-not [bool]$nrt88.Headset.ReachVerified) {
        $nrt88.Why = 'the headset identity could not be verified by serial; refusing to switch an unverified device'
    }
    else {
        $nrt88.Original = [string]$nrt88.Headset.ReachMode
        $row = Get-NrtSandboxHeadset -Name $nrt88.Headset.Name
        if (-not $row) { Add-NrtSandboxHeadset -Headset $nrt88.Headset | Out-Null; $row = Get-NrtSandboxHeadset -Name $nrt88.Headset.Name }
        $nrt88.Row = $row
        $nrt88.Ready = [bool]$row
        if (-not $row) { $nrt88.Why = 'the headset could not be registered in the sandbox' }
    }
}

function Assert-Nrt88Ready { if (-not $nrt88.Ready) { Skip-Test $nrt88.Why } }

function Get-Nrt88Config {
    $cur = Invoke-VrmApi -Path '/api/config'
    $cfg = $cur.Json
    if ($cfg -and $cfg.config) { $cfg = $cfg.config }
    return $cfg
}

function Save-Nrt88Config {
    param($Config)
    return (Invoke-VrmApi -Path '/api/config/save' -Method POST -Body $Config -TimeoutSec 180)
}

function Write-Nrt88State {
    param([string]$Note = '', [bool]$Restored = $false)
    try {
        $dir = Split-Path -Parent $nrt88.StateFile
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $o = [ordered]@{
            headset       = [string]$nrt88.Headset.Name
            serial        = [string]$nrt88.Headset.SerialNumber
            originalMode  = $nrt88.Original
            switchesMade  = $nrt88.Switches
            maxSwitches   = $nrt88.Max
            restored      = $Restored
            note          = $Note
            at            = (Get-Date).ToString('s')
        }
        [IO.File]::WriteAllText($nrt88.StateFile, ($o | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
    } catch { }
}

function Get-Nrt88Status {
    $r = Invoke-VrmApi -Path '/api/headsets-status'
    if (-not $r.Ok) { return $null }
    return (@($r.Json) | Where-Object { [string]$_.id -eq [string]$nrt88.Row.ID } | Select-Object -First 1)
}

function Invoke-Nrt88Switch {
    <#
    .SYNOPSIS
        THE only place that switches the headset's WiFi ADB mode. Counts every switch, refuses once
        the budget is used (-Rollback gets one extra), asks the app's engine through the config and
        waits until the headset reports the wanted mode. Returns @{Ok;Refused;Reason;ElapsedSec;Mode}.
    #>
    param([Parameter(Mandatory = $true)][ValidateSet('Classic', 'TLS')][string]$To, [switch]$Rollback, [int]$TimeoutSec = 240)

    $limit = $nrt88.Max + $(if ($Rollback) { 1 } else { 0 })
    if ($nrt88.Switches -ge $limit) {
        return @{ Ok = $false; Refused = $true; Reason = ("switch budget used ({0} of {1})" -f $nrt88.Switches, $limit); ElapsedSec = 0; Mode = '' }
    }
    $nrt88.Switches++
    Write-Nrt88State -Note ("switch {0} to {1} requested" -f $nrt88.Switches, $To)

    $cfg = Get-Nrt88Config
    $cfg.ADB.wifi_classic_enabled = $true
    $cfg.ADB.wifi_tls_enabled     = $true
    $cfg.ADB.wifi_preferred_mode  = $To.ToLower()
    $s = Save-Nrt88Config -Config $cfg
    if (-not ($s.Ok -and $s.Json.ok)) {
        return @{ Ok = $false; Refused = $false; Reason = ("config save refused: HTTP {0} {1}" -f $s.StatusCode, $s.Json.error); ElapsedSec = 0; Mode = '' }
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $st = $null
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        $st = Get-Nrt88Status
        if ($st -and $st.adb -and [string]$st.adb_wifi_mode -eq $To) {
            # Identity check on top of the app's own report: the endpoint answering must carry this serial.
            $e = Find-NrtHeadsetEndpoint -IPAddress ([string]$nrt88.Headset.IPAddress) -Serial ([string]$nrt88.Headset.SerialNumber) -AdbPort $ports.Adb
            if ($e.Ok -and $e.Verified) {
                return @{ Ok = $true; Refused = $false; Reason = ("answers over {0} at {1}" -f $e.Mode, $e.Target); ElapsedSec = [int]$sw.Elapsed.TotalSeconds; Mode = [string]$st.adb_wifi_mode }
            }
        }
        Start-Sleep -Seconds 5
    }
    return @{ Ok = $false; Refused = $false; Reason = ("the headset did not report {0} within {1} s (status mode '{2}', adb {3})" -f $To, $TimeoutSec, $st.adb_wifi_mode, $st.adb); ElapsedSec = [int]$sw.Elapsed.TotalSeconds; Mode = [string]$st.adb_wifi_mode }
}

function Test-Nrt88ClassicOpen {
    $c = $null
    try { $c = New-Object System.Net.Sockets.TcpClient; return [bool]$c.ConnectAsync([string]$nrt88.Headset.IPAddress, $ports.Adb).Wait(1500) }
    catch { return $false }
    finally { if ($c) { try { $c.Close() } catch { } } }
}

function Restore-Nrt88SingleMode {
    <#
    .SYNOPSIS
        Puts the headset back to answering in ONLY its original mode. The app's engine adds a mode but
        never removes the other one, so this is done with the same commands an operator would use:
          original TLS     : `adb usb` over the classic session closes the classic port (adbd restarts,
                             Wireless debugging stays on and re-advertises on a NEW port)
          original Classic : `settings put global adb_wifi_enabled 0` turns Wireless debugging off
        It restarts adbd once, so it counts as the (single, always allowed) rollback switch.
        Returns @{Ok;Reason;ElapsedSec}.
    #>
    $limit = $nrt88.Max + 1
    if ($nrt88.Switches -ge $limit) { return @{ Ok = $false; Reason = ("switch budget used ({0} of {1})" -f $nrt88.Switches, $limit); ElapsedSec = 0 } }
    $nrt88.Switches++
    Write-Nrt88State -Note ("restoring the single original mode ({0})" -f $nrt88.Original)
    $ip     = [string]$nrt88.Headset.IPAddress
    $serial = [string]$nrt88.Headset.SerialNumber
    $classic = "{0}:{1}" -f $ip, $ports.Adb
    [void](Invoke-NrtAdb -Arguments @('connect', $classic) -TimeoutMs 8000)
    if ($nrt88.Original -eq 'TLS') {
        $r = Invoke-NrtAdb -Arguments @('-s', $classic, 'usb') -TimeoutMs 15000
    } else {
        $r = Invoke-NrtAdb -Arguments @('-s', $classic, 'shell', 'settings put global adb_wifi_enabled 0') -TimeoutMs 15000
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt 150) {
        Start-Sleep -Seconds 4
        $svc = @(Get-NrtTlsServices | Where-Object { $_.Serial -ieq $serial })
        $classicOpen = Test-Nrt88ClassicOpen
        if ($nrt88.Original -eq 'TLS') {
            if (-not $classicOpen -and $svc.Count -gt 0) {
                foreach ($s in $svc) { if (Test-NrtAdbSerial -Target ("{0}:{1}" -f $ip, $s.Port) -Serial $serial) { return @{ Ok = $true; Reason = ("classic closed, TLS answers at {0}:{1}" -f $ip, $s.Port); ElapsedSec = [int]$sw.Elapsed.TotalSeconds } } }
            }
        } else {
            if ($classicOpen -and $svc.Count -eq 0 -and (Test-NrtAdbSerial -Target $classic -Serial $serial)) { return @{ Ok = $true; Reason = 'Wireless debugging off, classic answers'; ElapsedSec = [int]$sw.Elapsed.TotalSeconds } }
        }
    }
    return @{ Ok = $false; Reason = ("the headset did not return to {0} only within 150 s (classic open: {1}, TLS services: {2})" -f $nrt88.Original, (Test-Nrt88ClassicOpen), @(Get-NrtTlsServices | Where-Object { $_.Serial -ieq $serial }).Count); ElapsedSec = [int]$sw.Elapsed.TotalSeconds }
}

Invoke-RegressionTest -Name 'App is running' -Test {
    Assert-True $appUp 'the sandbox app is not running'
}

Invoke-RegressionTest -Name 'The headset is eligible for the WiFi mode switch test' -Test {
    Assert-Nrt88Ready
    $h = $nrt88.Headset
    Add-TestEvidence ("headset: {0}  model {1}  serial {2}" -f $h.Name, $h.Model, $h.SerialNumber)
    Add-TestEvidence ("reached over {0} at {1} (identity verified: {2})" -f $h.ReachMode, $h.ReachTarget, $h.ReachVerified)
    Assert-True ($nrt88.Original -in @('Classic', 'TLS')) 'the current WiFi ADB mode is known'

    # The engine never turns the other mode off: after a switch BOTH answer. The test therefore needs a
    # headset that answers in exactly one mode to start with, so that "back to the original state" means
    # something and can be restored (Restore-Nrt88SingleMode).
    $classicOpen = Test-Nrt88ClassicOpen
    $tlsUp = @(Get-NrtTlsServices | Where-Object { $_.Serial -ieq [string]$h.SerialNumber }).Count -gt 0
    Add-TestEvidence ("answers: classic port open = {0}, TLS service advertised = {1}" -f $classicOpen, $tlsUp)
    if ($classicOpen -and $tlsUp) {
        $nrt88.Ready = $false
        $nrt88.Why = 'the headset answers in BOTH classic and TLS mode: the test needs a headset in a single mode (turn Wireless debugging off, or run `adb usb`)'
        Skip-Test $nrt88.Why
    }

    $cfg = Get-Nrt88Config
    $nrt88.OrigCfg = @{ Classic = [bool]$cfg.ADB.wifi_classic_enabled; Tls = [bool]$cfg.ADB.wifi_tls_enabled; Preferred = [string]$cfg.ADB.wifi_preferred_mode }
    Add-TestEvidence ("sandbox ADB config: classic={0} tls={1} preferred={2}" -f $nrt88.OrigCfg.Classic, $nrt88.OrigCfg.Tls, $nrt88.OrigCfg.Preferred)
    # A preference that differs from the current mode would make the engine switch BEFORE the test
    # starts, outside the budget: refuse to run rather than switch the headset by accident.
    $pref = $nrt88.OrigCfg.Preferred.ToLower()
    if ($pref -in @('classic', 'tls') -and $pref -ne $nrt88.Original.ToLower()) {
        $nrt88.Ready = $false
        $nrt88.Why = ("ADB.wifi_preferred_mode is '{0}' but the headset is on {1}: the engine would switch it on its own" -f $pref, $nrt88.Original)
        Skip-Test $nrt88.Why
    }
    Write-Nrt88State -Note 'eligible, nothing switched yet'
    Add-TestEvidence ("state file: {0}" -f $nrt88.StateFile)
    Add-TestEvidence ("switch budget: {0} (plus 1 rollback)" -f $nrt88.Max)
}

Invoke-RegressionTest -Name 'The headset is not capturing, so its ADB daemon may be restarted' -Test {
    Assert-Nrt88Ready
    # A headset added through the API starts with auto-cast on, so the app streams it at once. Moving
    # a headset to classic runs `adb tcpip`, which restarts adbd and would cut that capture: the engine
    # therefore WAITS while a capture runs (it logs "the switch to classic waits until the capture
    # stops", scrcpy.usb_switch_mode = stable). The test stops the capture first, like an operator.
    $stopped = Stop-NrtHeadsetStream -TargetRoot $target -Headset $nrt88.Headset
    Add-TestEvidence ("auto-cast off and capture stopped: {0}" -f $stopped)
    Assert-True $stopped 'the capture of the test headset is stopped'
}

Invoke-RegressionTest -Name 'Switch 1: the app moves the headset to the other WiFi ADB mode' -Test {
    Assert-Nrt88Ready
    $to = if ($nrt88.Original -eq 'TLS') { 'Classic' } else { 'TLS' }
    Add-TestEvidence ("{0} -> {1}" -f $nrt88.Original, $to)
    $r = Invoke-Nrt88Switch -To $to
    Add-TestEvidence ("result: ok={0} {1} ({2} s)" -f $r.Ok, $r.Reason, $r.ElapsedSec)
    Assert-True $r.Ok ("the headset reports {0}: {1}" -f $to, $r.Reason)
}

Invoke-RegressionTest -Name 'In the new mode the headset is green and a DIAG section answers' -Test {
    Assert-Nrt88Ready
    if ($nrt88.Switches -lt 1) { Skip-Test 'no switch was made' }
    $st = Get-Nrt88Status
    Add-TestEvidence ("status: adb={0} adb_wifi_mode='{1}' transport='{2}'" -f $st.adb, $st.adb_wifi_mode, $st.adb_transport)
    Assert-True ([bool]$st.adb) 'ADB reports up'
    $d = Invoke-VrmApi -Path ('/api/headset-diag?id={0}&section=firmware' -f $nrt88.Row.ID) -TimeoutSec 90
    Add-TestEvidence ("firmware: ok={0} transport={1} error={2}" -f $d.Json.ok, $d.Json.transport, $d.Json.error)
    Assert-True ($d.Ok -and $d.Json.ok) 'the DIAG firmware section answers in the new mode'
}

Invoke-RegressionTest -Name 'Switch 2: asking for the original mode again is accepted by the engine' -Test {
    Assert-Nrt88Ready
    if ($nrt88.Switches -lt 1) { Skip-Test 'no switch was made' }
    Add-TestEvidence ("preferred mode back to {0} (the other mode keeps answering, the engine only changes the preference order)" -f $nrt88.Original)
    $r = Invoke-Nrt88Switch -To $nrt88.Original -Rollback
    Add-TestEvidence ("result: ok={0} refused={1} {2} ({3} s)" -f $r.Ok, $r.Refused, $r.Reason, $r.ElapsedSec)
    Assert-True $r.Ok ("the headset reports {0} again: {1}" -f $nrt88.Original, $r.Reason)
}

Invoke-RegressionTest -Name 'Rollback: the headset answers again in its original mode ONLY' -Test {
    Assert-Nrt88Ready
    if ($nrt88.Switches -lt 1) { Skip-Test 'no switch was made, nothing to roll back' }
    $r = Restore-Nrt88SingleMode
    Add-TestEvidence ("result: ok={0} {1} ({2} s)" -f $r.Ok, $r.Reason, $r.ElapsedSec)
    Assert-True $r.Ok $r.Reason
}

Invoke-RegressionTest -Name 'The headset ends in its original mode and the switch budget was respected' -Test {
    Assert-Nrt88Ready
    if ($nrt88.Switches -lt 1) { Skip-Test 'no switch was made' }
    # The app needs a moment to see the new TLS port after the daemon restart.
    $st = $null
    $deadline = (Get-Date).AddSeconds(90)
    while ((Get-Date) -lt $deadline) {
        $st = Get-Nrt88Status
        if ($st -and $st.adb -and [string]$st.adb_wifi_mode -eq $nrt88.Original) { break }
        Start-Sleep -Seconds 4
    }
    $ok = [bool]($st -and $st.adb -and [string]$st.adb_wifi_mode -eq $nrt88.Original)
    $single = if ($nrt88.Original -eq 'TLS') { -not (Test-Nrt88ClassicOpen) } else { @(Get-NrtTlsServices | Where-Object { $_.Serial -ieq [string]$nrt88.Headset.SerialNumber }).Count -eq 0 }
    Write-Nrt88State -Note $(if ($ok -and $single) { 'rolled back' } else { 'NOT rolled back - put the headset back to its original mode by hand' }) -Restored ($ok -and $single)
    Add-TestEvidence ("switches made: {0} (cap {1} + 1 rollback)" -f $nrt88.Switches, $nrt88.Max)
    Add-TestEvidence ("final status mode: {0}, original {1}, only that mode answers: {2}" -f $st.adb_wifi_mode, $nrt88.Original, $single)
    Assert-True ($nrt88.Switches -le ($nrt88.Max + 1)) 'no more than the cap plus one rollback'
    Assert-True $ok ("the status reports {0}. If not, see {1}" -f $nrt88.Original, $nrt88.StateFile)
    Assert-True $single ("only {0} answers again" -f $nrt88.Original)
}

Invoke-RegressionTest -Name 'The ADB WiFi configuration is restored without switching the headset' -Test {
    Assert-Nrt88Ready
    if (-not $nrt88.OrigCfg) { Skip-Test 'the original configuration was never read' }
    $before = $nrt88.Switches
    $cfg = Get-Nrt88Config
    $cfg.ADB.wifi_classic_enabled = [bool]$nrt88.OrigCfg.Classic
    $cfg.ADB.wifi_tls_enabled     = [bool]$nrt88.OrigCfg.Tls
    $cfg.ADB.wifi_preferred_mode  = [string]$nrt88.OrigCfg.Preferred
    $s = Save-Nrt88Config -Config $cfg
    Add-TestEvidence ("restore: HTTP {0} ok={1} error={2}" -f $s.StatusCode, $s.Json.ok, $s.Json.error)
    Assert-True ($s.Ok -and $s.Json.ok) 'the original keys are saved again'
    Start-Sleep -Seconds 20
    $st = Get-Nrt88Status
    Add-TestEvidence ("20 s later: adb_wifi_mode='{0}'" -f $st.adb_wifi_mode)
    Assert-Equal $nrt88.Original ([string]$st.adb_wifi_mode) 'restoring the keys did not move the headset'
    Assert-Equal $before $nrt88.Switches 'no switch was caused by the restore'
}