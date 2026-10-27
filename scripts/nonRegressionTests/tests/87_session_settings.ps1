#Requires -Version 5.1
<#
.SYNOPSIS
    Section 87 - session-only headset settings and their re-apply after a reboot (ADR-0040).

.DESCRIPTION
    Dot-sourced by scripts\Invoke-NonRegressionTests.ps1 inside a section context.

    NEEDS A REAL META HEADSET. The section SKIPs (never FAILs) when no headset answers (classic OR
    TLS ADB, identity verified by serial) or when it is a Pico. Everything is driven through the
    public web API, and each change is CONFIRMED ON THE HEADSET with adb (the sandbox app and the
    headset must agree), then the original state is restored.

    Tests, in order:
      1. GET /api/headset-settings carries the session fields.
      2. Side double tap: disable / enable (sensor uid state idle / active).
      3. Hand tracking wide-motion mode: on / off (debug.bodyapi.* props).
      4. Image sharpening: FidelityFX CAS (layerFilter 4), Meta Quest Super Resolution (3), off;
         an invalid mode is refused.
      5. Guardian pause on / off.
      6. Proximity override on / off (accepted and remembered; the state cannot be read back).
      7. The "re-apply after reboot" switch is stored.
      8. (-AllowDestructive, Full) drift correction: a setting changed behind the app's back is put
         back within ~3 minutes while the switch is on.
      9. (-AllowDestructive, Full) a headset reboot: the remembered settings come back by themselves.
     10. The original settings are restored.

    Light depth does not run this section.

    ASCII only (CLAUDE.md rule 1).
#>

$target  = $global:TestRun.TargetRoot
$devRoot = $global:TestRun.DevRoot
$depth   = $global:TestRun.Depth

$appUp = Confirm-SandboxApp -TargetRoot $target -DevRoot $devRoot
$ports = Get-NrtSandboxPorts -TargetRoot $target

$nrt87Headset = $null
if ($depth -ne 'Light') { $nrt87Headset = Resolve-NrtTestHeadset -DevRoot $devRoot -AdbPort $ports.Adb }
$nrt87Safe   = ''
$nrt87State  = @{ Target = ''; Orig = $null; NoWifiAfterReboot = $false }
$nrt87Ready  = $false
$nrt87Why    = 'no reachable headset in the dev registry (classic or TLS, identity verified) - pass -HeadsetName to force one'

if ($depth -eq 'Light') { $nrt87Why = 'hardware section, not run at Light depth' }
elseif ($nrt87Headset) {
    if ([string]$nrt87Headset.Brand -eq 'Pico') {
        $nrt87Why = 'Pico headset: the session settings are Meta Quest only'
    } else {
        $nrt87Safe   = ConvertTo-NrtSafeName -Name $nrt87Headset.Name
        $nrt87State.Target = [string]$nrt87Headset.ReachTarget
        $row = Get-NrtSandboxHeadset -Name $nrt87Headset.Name
        if (-not $row) { Add-NrtSandboxHeadset -Headset $nrt87Headset | Out-Null }
        $nrt87Ready = $true
    }
}

function Assert-Nrt87Ready { if (-not $nrt87Ready) { Skip-Test $nrt87Why } }

function Get-Nrt87Settings {
    $r = Invoke-VrmApi -Path ('/api/headset-settings?name={0}' -f [uri]::EscapeDataString($nrt87Safe)) -TimeoutSec 120
    return $r
}

function Set-Nrt87Setting {
    param([Parameter(Mandatory = $true)][hashtable]$Settings)
    return (Invoke-VrmApi -Path '/api/headset-settings/apply' -Method POST -Body @{ name = $nrt87Safe; settings = $Settings } -TimeoutSec 120)
}

# One value read straight from the headset with adb (never through the app under test).
function Get-Nrt87Device {
    param([Parameter(Mandatory = $true)][string]$Command)
    if (-not $nrt87State.Target) { return $null }
    $r = Invoke-NrtAdb -Arguments @('-s', $nrt87State.Target, 'shell', $Command) -TimeoutMs 12000
    if (-not $r.Ok) { return $null }
    return ([string]$r.Out).Trim()
}

function Wait-Nrt87Setting {
    # Polls GET /api/headset-settings until -Check returns $true or the time is up.
    param([Parameter(Mandatory = $true)][scriptblock]$Check, [int]$TimeoutSec = 60, [int]$EverySec = 5)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ($true) {
        $g = Get-Nrt87Settings
        if ($g.Ok -and $g.Json -and (& $Check $g.Json)) { return $true }
        if ((Get-Date) -ge $deadline) { return $false }
        Start-Sleep -Seconds $EverySec
    }
}

Invoke-RegressionTest -Name 'App is running' -Test {
    Assert-True $appUp 'the sandbox app is not running'
}

Invoke-RegressionTest -Name 'A Meta headset is available for the session settings tests' -Test {
    Assert-Nrt87Ready
    Add-TestEvidence ("headset: {0}  model {1}  serial {2}" -f $nrt87Headset.Name, $nrt87Headset.Model, $nrt87Headset.SerialNumber)
    Add-TestEvidence ("reached over {0} at {1} (identity verified: {2})" -f $nrt87Headset.ReachMode, $nrt87Headset.ReachTarget, $nrt87Headset.ReachVerified)
}

Invoke-RegressionTest -Name 'GET /api/headset-settings carries the session settings' -Test {
    Assert-Nrt87Ready
    $g = Get-Nrt87Settings
    Add-TestEvidence ("HTTP {0}" -f $g.StatusCode)
    Assert-True ($g.Ok -and $g.Json.ok) 'the route answers ok'
    $j = $g.Json
    Add-TestEvidence ("doubleTapDisabled={0} wideMotion={1} guardianPaused={2} sharpening={3} proxKeepAwake={4} sessionReapply={5}" -f $j.doubleTapDisabled, $j.wideMotion, $j.guardianPaused, $j.sharpening, $j.proxKeepAwake, $j.sessionReapply)
    Assert-True ($j.doubleTapDisabled -is [bool]) 'doubleTapDisabled is a boolean (the headset answered)'
    Assert-True ($j.wideMotion -is [bool]) 'wideMotion is a boolean'
    Assert-True ($j.guardianPaused -is [bool]) 'guardianPaused is a boolean'
    Assert-True ([string]$j.sharpening -in @('none', 'fcas', 'mqsr', 'custom')) 'sharpening is none, fcas, mqsr or custom'
    Assert-True ($j.proxKeepAwake -is [bool]) 'proxKeepAwake is a boolean'
    Assert-True ($j.sessionReapply -is [bool]) 'sessionReapply is a boolean'
    $nrt87State.Orig = $j
}

Invoke-RegressionTest -Name 'Side double tap: disable and enable, confirmed on the headset' -Test {
    Assert-Nrt87Ready
    $r1 = Set-Nrt87Setting -Settings @{ doubleTapDisabled = $true }
    Add-TestEvidence ("disable: HTTP {0} ok={1} error={2}" -f $r1.StatusCode, $r1.Json.ok, $r1.Json.error)
    Assert-True ($r1.Ok -and $r1.Json.ok) 'disabling is accepted'
    Assert-Equal 'idle' (Get-Nrt87Device 'cmd sensorservice get-uid-state com.oculus.vrshell; true') 'the headset reports the sensor idle'
    $g1 = Get-Nrt87Settings
    Assert-Equal $true ([bool]$g1.Json.doubleTapDisabled) 'the API reads disabled'
    $r2 = Set-Nrt87Setting -Settings @{ doubleTapDisabled = $false }
    Assert-True ($r2.Ok -and $r2.Json.ok) 'enabling is accepted'
    Assert-Equal 'active' (Get-Nrt87Device 'cmd sensorservice get-uid-state com.oculus.vrshell; true') 'the headset reports the sensor active'
    $g2 = Get-Nrt87Settings
    Assert-Equal $false ([bool]$g2.Json.doubleTapDisabled) 'the API reads enabled'
}

Invoke-RegressionTest -Name 'Hand tracking wide-motion mode: on and off, confirmed on the headset' -Test {
    Assert-Nrt87Ready
    $r1 = Set-Nrt87Setting -Settings @{ wideMotion = $true }
    Assert-True ($r1.Ok -and $r1.Json.ok) 'switching on is accepted'
    $p1 = Get-Nrt87Device 'echo F=$(getprop debug.oculus.forceEnablePerformanceFeatures) A=$(getprop debug.bodyapi.allowhandoverride) T=$(getprop debug.bodyapi.handoverridetype)'
    Add-TestEvidence ("on: {0}" -f $p1)
    Assert-Match ([string]$p1) 'F=BODY_TRACKING A=1 T=3' 'the three props are set'
    $r2 = Set-Nrt87Setting -Settings @{ wideMotion = $false }
    Assert-True ($r2.Ok -and $r2.Json.ok) 'switching off is accepted'
    $p2 = Get-Nrt87Device 'echo F=$(getprop debug.oculus.forceEnablePerformanceFeatures) A=$(getprop debug.bodyapi.allowhandoverride) T=$(getprop debug.bodyapi.handoverridetype)'
    Add-TestEvidence ("off: {0}" -f $p2)
    Assert-Match ([string]$p2) '^F=\s+A=\s+T=\s*$' 'the three props are cleared'
}

Invoke-RegressionTest -Name 'Image sharpening: FidelityFX CAS, Meta Quest Super Resolution and off' -Test {
    Assert-Nrt87Ready
    $cases = @(
        @{ Mode = 'fcas'; Pattern = '^L=4 A=4$' },
        @{ Mode = 'mqsr'; Pattern = '^L=3 A=4$' },
        @{ Mode = 'none'; Pattern = '^L=\s+A=\s*$' }
    )
    foreach ($c in $cases) {
        $r = Set-Nrt87Setting -Settings @{ sharpening = $c.Mode }
        Assert-True ($r.Ok -and $r.Json.ok) ("setting {0} is accepted ({1})" -f $c.Mode, $r.Json.error)
        $p = Get-Nrt87Device 'echo L=$(getprop debug.oculus.layerFilter) A=$(getprop debug.oculus.pfr.autofilter)'
        Add-TestEvidence ("{0}: {1}" -f $c.Mode, $p)
        Assert-Match ([string]$p) $c.Pattern ("the headset props for {0}" -f $c.Mode)
        $g = Get-Nrt87Settings
        Assert-Equal $c.Mode ([string]$g.Json.sharpening) ("the API reads {0}" -f $c.Mode)
    }
    $bad = Set-Nrt87Setting -Settings @{ sharpening = 'bogus' }
    Add-TestEvidence ("invalid mode: HTTP {0} ok={1}" -f $bad.StatusCode, $bad.Json.ok)
    Assert-False ([bool]$bad.Json.ok) 'an invalid sharpening mode is refused'
}

Invoke-RegressionTest -Name 'Guardian pause: on and off, confirmed on the headset' -Test {
    Assert-Nrt87Ready
    $r1 = Set-Nrt87Setting -Settings @{ guardianPause = $true }
    Assert-True ($r1.Ok -and $r1.Json.ok) 'pausing is accepted'
    Assert-Equal '1' (Get-Nrt87Device 'getprop debug.oculus.guardian_pause') 'the headset prop is 1'
    $g = Get-Nrt87Settings
    Assert-Equal $true ([bool]$g.Json.guardianPaused) 'the API reads paused'
    $r2 = Set-Nrt87Setting -Settings @{ guardianPause = $false }
    Assert-True ($r2.Ok -and $r2.Json.ok) 'resuming is accepted'
    Assert-Equal '0' (Get-Nrt87Device 'getprop debug.oculus.guardian_pause') 'the headset prop is 0'
}

Invoke-RegressionTest -Name 'Proximity override is accepted both ways and remembered' -Test {
    Assert-Nrt87Ready
    $r1 = Set-Nrt87Setting -Settings @{ proxOverride = $true }
    Assert-True ($r1.Ok -and $r1.Json.ok) 'bypassing the sensor is accepted'
    $g1 = Get-Nrt87Settings
    Assert-Equal $true ([bool]$g1.Json.proxKeepAwake) 'the wish is remembered'
    $r2 = Set-Nrt87Setting -Settings @{ proxOverride = $false }
    Assert-True ($r2.Ok -and $r2.Json.ok) 'handing the sensor back is accepted'
    $g2 = Get-Nrt87Settings
    Assert-Equal $false ([bool]$g2.Json.proxKeepAwake) 'the wish is cleared'
}

Invoke-RegressionTest -Name 'The re-apply after reboot switch is stored' -Test {
    Assert-Nrt87Ready
    $r1 = Set-Nrt87Setting -Settings @{ sessionReapply = $true }
    Assert-True ($r1.Ok -and $r1.Json.ok) 'switching on is accepted'
    Assert-Equal $true ([bool](Get-Nrt87Settings).Json.sessionReapply) 'read back on'
    $r2 = Set-Nrt87Setting -Settings @{ sessionReapply = $false }
    Assert-True ($r2.Ok -and $r2.Json.ok) 'switching off is accepted'
    Assert-Equal $false ([bool](Get-Nrt87Settings).Json.sessionReapply) 'read back off'
}

Invoke-RegressionTest -Name 'A setting changed behind the app is put back while the switch is on (drift check)' -Test {
    Assert-Nrt87Ready
    if ($depth -ne 'Full') { Skip-Test 'Full depth only (takes up to 3 minutes)' }
    if (-not $global:TestRun.AllowDestructive) { Skip-Test 'pass -AllowDestructive: this changes the headset display settings for a few minutes' }
    if (-not $nrt87State.Target) { Skip-Test 'no verified adb target for the headset' }

    $r = Set-Nrt87Setting -Settings @{ sharpening = 'fcas'; sessionReapply = $true }
    Assert-True ($r.Ok -and $r.Json.ok) 'FidelityFX CAS remembered with the switch on'
    # Let the monitor take its first pass, then change the value without telling the app.
    Start-Sleep -Seconds 20
    [void](Invoke-NrtAdb -Arguments @('-s', $nrt87State.Target, 'shell', 'setprop debug.oculus.layerFilter ""') -TimeoutMs 12000)
    $p0 = Get-Nrt87Device 'echo L=$(getprop debug.oculus.layerFilter)'
    Add-TestEvidence ("after the outside change: {0}" -f $p0)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $back = Wait-Nrt87Setting -TimeoutSec 190 -EverySec 10 -Check { param($j) [string]$j.sharpening -eq 'fcas' }
    Add-TestEvidence ("back to fcas: {0} after {1} s" -f $back, [int]$sw.Elapsed.TotalSeconds)
    Assert-True $back 'the monitor sets FidelityFX CAS again within 190 s'
}

Invoke-RegressionTest -Name 'After a headset reboot the remembered settings come back by themselves' -Test {
    Assert-Nrt87Ready
    if ($depth -ne 'Full') { Skip-Test 'Full depth only (a reboot takes several minutes)' }
    if (-not $global:TestRun.AllowDestructive) { Skip-Test 'pass -AllowDestructive: this reboots the headset' }

    $r = Set-Nrt87Setting -Settings @{ doubleTapDisabled = $true; sharpening = 'fcas'; sessionReapply = $true }
    Assert-True ($r.Ok -and $r.Json.ok) 'settings remembered with the switch on'
    Start-Sleep -Seconds 15

    $rb = Invoke-VrmApi -Path '/api/reboot' -Method POST -Body @{ name = $nrt87Safe } -TimeoutSec 60
    Add-TestEvidence ("reboot requested: HTTP {0} ok={1}" -f $rb.StatusCode, $rb.Json.ok)
    if (-not ($rb.Ok -and $rb.Json.ok)) { Skip-Test 'the reboot request was refused (headset not reachable over ADB)' }
    $wait = Wait-NrtHeadsetRebooted -IPAddress ([string]$nrt87Headset.IPAddress) -AdbPort $ports.Adb -TimeoutSec 300 -Serial ([string]$nrt87Headset.SerialNumber)
    Add-TestEvidence ("went down={0} back={1} after {2} s" -f $wait.Down, $wait.Back, $wait.ElapsedSec)
    Assert-True $wait.Down 'the headset really went down'
    if (-not $wait.Back) {
        # Not a verdict on the feature: after a reboot WiFi ADB only returns when something re-enables
        # Wireless debugging (the headset's own setting, QGO or the ADB auto-enable app, ADR S10-6).
        # With neither, the re-apply cannot run at all because the app cannot reach the headset.
        $nrt87State.NoWifiAfterReboot = $true
        Add-TestEvidence 'the headset answers ping but WiFi ADB did not return within 300 s (Wireless debugging is off after the reboot and nothing re-enabled it)'
        Skip-Test 'WiFi ADB did not come back after the reboot, so the re-apply cannot be observed (turn Wireless debugging on again, or install the ADB auto-enable app)'
    }

    # The address and port may have changed (TLS): point the adb confirmation at the new endpoint.
    $e = Find-NrtHeadsetEndpoint -IPAddress ([string]$nrt87Headset.IPAddress) -Serial ([string]$nrt87Headset.SerialNumber) -AdbPort $ports.Adb
    if ($e.Ok) { $nrt87State.Target = [string]$e.Target }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $ok = Wait-Nrt87Setting -TimeoutSec 240 -EverySec 10 -Check { param($j) ($j.doubleTapDisabled -eq $true) -and ([string]$j.sharpening -eq 'fcas') }
    Add-TestEvidence ("settings restored: {0} after {1} s" -f $ok, [int]$sw.Elapsed.TotalSeconds)
    Assert-True $ok 'the double tap is disabled and FidelityFX CAS is on again after the reboot'
}

Invoke-RegressionTest -Name 'The original session settings are restored' -Test {
    Assert-Nrt87Ready
    if (-not $nrt87State.Orig) { Skip-Test 'the initial settings were never read' }
    $o = $nrt87State.Orig
    $restore = @{
        doubleTapDisabled = [bool]$o.doubleTapDisabled
        wideMotion        = [bool]$o.wideMotion
        guardianPause     = [bool]$o.guardianPaused
        proxOverride      = [bool]$o.proxKeepAwake
        sessionReapply    = [bool]$o.sessionReapply
    }
    if ([string]$o.sharpening -in @('none', 'fcas', 'mqsr')) { $restore['sharpening'] = [string]$o.sharpening }
    $r = Set-Nrt87Setting -Settings $restore
    Add-TestEvidence ("restore: HTTP {0} ok={1} error={2}" -f $r.StatusCode, $r.Json.ok, $r.Json.error)
    if (-not ($r.Ok -and $r.Json.ok) -and $nrt87State.NoWifiAfterReboot) {
        # The headset has no WiFi ADB after the reboot. Nothing needs undoing: the overrides are runtime-only
        # and the reboot already cleared them.
        Skip-Test 'the headset is not reachable over WiFi ADB after the reboot; its session overrides were cleared by the reboot itself'
    }
    Assert-True ($r.Ok -and $r.Json.ok) 'the original settings are applied again'
}
