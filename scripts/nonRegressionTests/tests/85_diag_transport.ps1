#Requires -Version 5.1
<#
.SYNOPSIS
    Section 85 - DIAG page, USB-first ADB transport and the metric history of the
    new temperature readings.

.DESCRIPTION
    Dot-sourced by scripts\Invoke-NonRegressionTests.ps1 inside a section context.

    NEEDS HARDWARE: a headset cabled to this PC over USB (headset A, WiFi ADB also enabled
    so the unplug test can fall back) and, optionally, a second headset reachable only over
    WiFi ADB (headset B). Name them with the environment variables

        VRHM_TEST_USB_HEADSET    name of headset A (registered in the DEV registry)
        VRHM_TEST_USB_HEADSET_IP / VRHM_TEST_WIFI_HEADSET_IP   OPTIONAL current address of A / B,
                             for when the dev registry still holds an address from another network
    VRHM_TEST_WIFI_HEADSET   name of headset B (OPTIONAL: without it, the tests that need a
                             second headset skip, and the action tests run on headset A)

    The section SKIPs (never FAILs) when they are absent, mirroring how sections 50
    and 60 stay green with no headset configured. Steps that need a person (unplug
    the cable, reboot a headset, confirm a message is visible) go through
    Wait-OperatorAction and are skipped when the run is -Unattended or at Light depth.

    What this proves, in order:
      - Transport: A reports AdbTransport USB and B reports WiFi; a command on A
        really runs over USB (the response says which transport answered).
      - DIAG API: every section answers for both headsets with real fields; the
        fleet comparison lists both; the USB section exists only for A; the cable
        test runs on A and is refused on B.
      - Temperatures: CPU temperature samples land in the metric history.
      - Actions: Bluetooth round trip, clock sync, recovery keys, presets, a free
        text command and a refused command.
      - Unplug / replug (operator): A falls back to WiFi within 15 s with ADB still
        working, then returns to USB according to scrcpy.usb_switch_mode.
      - ADB over TLS (EXPERIMENTAL): evidence only, never asserted. The question it
        answers is whether TLS could replace re-enabling tcpip after a reboot.

    ASCII only (CLAUDE.md rule 1).
#>

$target     = $global:TestRun.TargetRoot
$devRoot    = $global:TestRun.DevRoot
$depth      = $global:TestRun.Depth
$unattended = ($global:TestRun -and $global:TestRun.Unattended)
$appUp      = Confirm-SandboxApp -TargetRoot $target -DevRoot $devRoot

function Resolve-Nrt85Headset {
    <# The SANDBOX registry row (with its ID) of a DEV headset named by the operator, importing it when absent. #>
    param([string]$Name, [string]$IpOverride = '')
    if (-not $Name) { return $null }
    $dev = Get-NrtDevHeadsets -DevRoot $devRoot | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    if (-not $dev) { return $null }
    # The dev registry keeps the LAST address the headset had, which is wrong when this PC has
    # moved to another network (a real run found 10.20.24.x entries on a 192.168.1.x PC). An
    # explicit address, from VRHM_TEST_*_HEADSET_IP, wins for the sandbox copy only.
    if ($IpOverride) { $dev = $dev.PSObject.Copy(); $dev.IPAddress = $IpOverride }
    $row = Get-NrtSandboxHeadset -Name $Name
    if (-not $row) { Add-NrtSandboxHeadset -Headset $dev | Out-Null; $row = Get-NrtSandboxHeadset -Name $Name }
    return $row
}

function Get-Nrt85Status {
    param($Id)
    $r = Invoke-VrmApi -Path '/api/headsets-status'
    if (-not $r.Ok -or -not $r.Json) { return $null }
    return (@($r.Json) | Where-Object { [string]$_.id -eq [string]$Id } | Select-Object -First 1)
}

function Get-Nrt85HeadsetLabel {
    <#
    Identifies ONE physical headset for an operator prompt: name, serial, and how it is connected
    right now (USB cable or WiFi, with its address). With two headsets on the bench a prompt that
    only says "the headset" is unusable, and the name alone is not enough to tell two Quest 3 apart.
    #>
    param($Headset)
    $s      = Get-Nrt85Status -Id $Headset.ID
    $ip     = if ($s -and $s.ip_address) { [string]$s.ip_address } else { [string]$Headset.IPAddress }
    $serial = if ($Headset.SerialNumber) { [string]$Headset.SerialNumber } else { 'n/a' }
    $link   = if ($s -and [string]$s.adb_transport -eq 'USB') { "connected by USB cable (WiFi address $ip)" }
              elseif ($s -and [string]$s.adb_transport -eq 'WiFi') { "connected by WiFi at $ip" }
              else { "address $ip" }
    return ("'{0}' - serial {1} - {2}" -f $Headset.Name, $serial, $link)
}

function Wait-Nrt85Transport {
    param($Id, [string]$Want, [int]$TimeoutSec = 30)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $last = $null
    while ((Get-Date) -lt $deadline) {
        $last = Get-Nrt85Status -Id $Id
        if ($last -and [string]$last.adb_transport -eq $Want) { return $last }
        Start-Sleep -Milliseconds 1000
    }
    return $last
}

function Invoke-Nrt85Diag {
    param($Id, [string]$Section, [string]$Transport = 'Auto')
    return (Invoke-VrmApi -Path ('/api/headset-diag?id={0}&section={1}&transport={2}' -f $Id, $Section, $Transport) -TimeoutSec 90)
}

function Invoke-Nrt85Action {
    param($Id, [string]$Action, $ActionArgs = @{}, [string]$Transport = 'Auto')
    return (Invoke-VrmApi -Path '/api/headset-diag/action' -Method POST -Body @{ id = [int]$Id; action = $Action; args = $ActionArgs; transport = $Transport } -TimeoutSec 120)
}

function Invoke-Nrt85Command {
    param($Id, [string]$Command, [string]$Transport = 'Auto')
    return (Invoke-VrmApi -Path '/api/headset-diag/command' -Method POST -Body @{ id = [int]$Id; command = $Command; transport = $Transport } -TimeoutSec 60)
}

$nrtA = Resolve-Nrt85Headset -Name $env:VRHM_TEST_USB_HEADSET  -IpOverride $env:VRHM_TEST_USB_HEADSET_IP
$nrtB = Resolve-Nrt85Headset -Name $env:VRHM_TEST_WIFI_HEADSET -IpOverride $env:VRHM_TEST_WIFI_HEADSET_IP
# Headset B is OPTIONAL. With only the cabled headset, the tests that need a second headset skip
# with a reason, and the action tests run on the cabled one ($nrtT).
$nrtT = if ($nrtB) { $nrtB } else { $nrtA }

function Assert-Nrt85Headsets {
    if (-not $nrtA) {
        Skip-Test 'set VRHM_TEST_USB_HEADSET to the name of a registered headset cabled over USB'
    }
}

function Assert-Nrt85Two {
    Assert-Nrt85Headsets
    if (-not $nrtB) { Skip-Test 'needs a second, WiFi-only headset (set VRHM_TEST_WIFI_HEADSET)' }
}

Invoke-RegressionTest -Name 'App is running' -Test {
    Assert-True $appUp 'the sandbox app is not running'
}

Invoke-RegressionTest -Name 'The test headsets are configured' -Test {
    Assert-Nrt85Headsets
    Add-TestEvidence ("A (USB):  {0}  id {1}  serial {2}" -f $nrtA.Name, $nrtA.ID, $nrtA.SerialNumber)
    if ($nrtB) {
        Add-TestEvidence ("B (WiFi): {0}  id {1}  serial {2}" -f $nrtB.Name, $nrtB.ID, $nrtB.SerialNumber)
        Assert-True ($nrtA.ID -ne $nrtB.ID) 'the two test headsets must be different headsets'
    } else {
        Add-TestEvidence 'B (WiFi): not configured - single-headset run'
    }
}

$nrt85Ports = Get-NrtSandboxPorts -TargetRoot $target

Invoke-RegressionTest -Name 'WiFi ADB is available on the cabled headset (enabled automatically when missing)' -Test {
    Assert-Nrt85Headsets
    # Several tests below need the cabled headset to ALSO answer over WiFi (the unplug fallback,
    # the forced-WiFi test). A headset that slept or rebooted has lost tcpip mode, and the sandbox
    # app only auto-onboards headsets already in its registry, so enable it here instead of
    # leaving the operator to do it by hand. Only when it is not already answering: the bridge
    # runs "adb tcpip", which briefly drops the USB transport.
    $ip = [string]$nrtA.IPAddress
    if (Test-NrtHeadsetReachable -IPAddress $ip -AdbPort $nrt85Ports.Adb) {
        Add-TestEvidence ("{0}:{1} already answers - nothing to enable" -f $ip, $nrt85Ports.Adb)
        return
    }
    $bridged = Invoke-NrtEnableUsbWifiAdb
    if ($bridged) {
        $ip = [string]$bridged.Ip
        Add-TestEvidence ("WiFi ADB enabled over USB: {0} -> {1}" -f $bridged.Model, $ip)
    } else {
        # The bridge call can lose a race with the app's own USB watcher, which onboards a cabled
        # headset by itself (seen in a real run: the call returned nothing and the watcher logged
        # "WiFi ADB enabled" a moment later). So do not judge the call - judge the outcome below.
        Add-TestEvidence 'the bridge call returned nothing - waiting to see whether the USB watcher enabled WiFi ADB itself'
    }
    $deadline = (Get-Date).AddSeconds(45)
    $up = $false
    while ((Get-Date) -lt $deadline) {
        if (Test-NrtHeadsetReachable -IPAddress $ip -AdbPort $nrt85Ports.Adb) { $up = $true; break }
        Start-Sleep -Seconds 2
    }
    Assert-True $up ("{0}:{1} must answer after enabling WiFi ADB (same WiFi network as this PC?)" -f $ip, $nrt85Ports.Adb)
    # tcpip re-enumerates USB for a few seconds; let the monitor see the cable again.
    $null = Wait-Nrt85Transport -Id $nrtA.ID -Want 'USB' -Timeout 45
}

Invoke-RegressionTest -Name 'The cabled headset reports AdbTransport USB' -Test {
    Assert-Nrt85Headsets
    $s = Wait-Nrt85Transport -Id $nrtA.ID -Want 'USB' -Timeout 60
    Add-TestEvidence ("adb_transport = '{0}'  adb = {1}  ping = {2}  scrcpy = {3}  ip = {4}" -f $s.adb_transport, $s.adb, $s.ping, $s.scrcpy, $s.ip_address)
    Assert-Equal 'USB' ([string]$s.adb_transport) 'headset A transport'
}

Invoke-RegressionTest -Name 'The WiFi-only headset reports AdbTransport WiFi' -Test {
    Assert-Nrt85Two
    $s = Wait-Nrt85Transport -Id $nrtB.ID -Want 'WiFi' -Timeout 60
    Add-TestEvidence ("adb_transport = '{0}'  adb = {1}" -f $s.adb_transport, $s.adb)
    Assert-Equal 'WiFi' ([string]$s.adb_transport) 'headset B transport'
}

Invoke-RegressionTest -Name 'An ADB command on the cabled headset runs over USB' -Test {
    Assert-Nrt85Headsets
    $r = Invoke-Nrt85Command -Id $nrtA.ID -Command 'getprop ro.product.model'
    Add-TestEvidence ("transport: {0}  output: {1}" -f $r.Json.transport, $r.Json.output)
    Assert-True ($r.Ok -and $r.Json.ok) 'the command must succeed'
    Assert-Equal 'USB' ([string]$r.Json.transport) 'transport that answered'
    Assert-True ([bool]([string]$r.Json.output).Trim()) 'the model name must come back'
}

Invoke-RegressionTest -Name 'An ADB command on the WiFi-only headset runs over WiFi' -Test {
    Assert-Nrt85Two
    $r = Invoke-Nrt85Command -Id $nrtB.ID -Command 'getprop ro.product.model'
    Add-TestEvidence ("transport: {0}  output: {1}" -f $r.Json.transport, $r.Json.output)
    Assert-True ($r.Ok -and $r.Json.ok) 'the command must succeed'
    Assert-Equal 'WiFi' ([string]$r.Json.transport) 'transport that answered'
}

# ---------------------------------------------------------------------------
# DIAG API
# ---------------------------------------------------------------------------

foreach ($nrt85Which in @('A', 'B')) {
    $nrt85Label = $nrt85Which
    Invoke-RegressionTest -Name ("Every DIAG section answers for headset {0}" -f $nrt85Label) -Test {
        Assert-Nrt85Headsets
        if ($nrt85Label -eq 'B') { Assert-Nrt85Two }
        $h = if ($nrt85Label -eq 'A') { $nrtA } else { $nrtB }
        foreach ($section in @('firmware', 'health', 'wireless')) {
            $r = Invoke-Nrt85Diag -Id $h.ID -Section $section
            Add-TestEvidence ("{0}/{1}: HTTP {2} ok={3} transport={4} error={5}" -f $h.Name, $section, $r.StatusCode, $r.Json.ok, $r.Json.transport, $r.Json.error)
            Assert-True ($r.Ok -and $r.Json.ok) ("section '{0}' must answer ok" -f $section)
            Assert-NotNull $r.Json.data ("section '{0}' data" -f $section)
        }
        # Key fields. Meta only: a PICO headset has no OculusUpdater or SystemUX package.
        if ([string]$h.Brand -ne 'Pico') {
            $fw = (Invoke-Nrt85Diag -Id $h.ID -Section 'firmware').Json.data
            Assert-NotNull $fw.FirmwareVersion 'firmware version'
            Assert-NotNull $fw.Build 'build'
        }
        $hl = (Invoke-Nrt85Diag -Id $h.ID -Section 'health').Json.data
        Assert-True ($null -ne $hl.Battery -and $null -ne $hl.Battery.Level) 'battery level'
        $wl = (Invoke-Nrt85Diag -Id $h.ID -Section 'wireless').Json.data
        Assert-NotNull $wl.Ssid 'WiFi SSID'
        Assert-NotNull $wl.Ip 'WiFi IP address'
    }
}

Invoke-RegressionTest -Name 'The fleet comparison lists both headsets' -Test {
    Assert-Nrt85Headsets
    # firmware_history is written by the monitor on its slow cadence; give it time.
    $deadline = (Get-Date).AddSeconds(90)
    $names = @()
    while ((Get-Date) -lt $deadline) {
        $r = Invoke-Nrt85Diag -Id $nrtA.ID -Section 'fleet'
        $names = @($r.Json.data | ForEach-Object { $_.Name })
        if (($names -contains $nrtA.Name) -and (-not $nrtB -or ($names -contains $nrtB.Name))) { break }
        Start-Sleep -Seconds 5
    }
    Add-TestEvidence ("fleet: {0}" -f ($names -join ', '))
    Assert-Contains $names $nrtA.Name 'headset A in the fleet table'
    if ($nrtB) { Assert-Contains $names $nrtB.Name 'headset B in the fleet table' }
}

Invoke-RegressionTest -Name 'The USB section exists only for the cabled headset' -Test {
    Assert-Nrt85Headsets
    $a = (Invoke-Nrt85Diag -Id $nrtA.ID -Section 'usb').Json.data
    Add-TestEvidence ("A: OnUsb={0} speed={1}" -f $a.OnUsb, $a.Speed)
    Assert-True ([bool]$a.OnUsb) 'headset A is on USB'
    if ($nrtB) {
        $b = (Invoke-Nrt85Diag -Id $nrtB.ID -Section 'usb').Json.data
        Add-TestEvidence ("B: OnUsb={0}" -f $b.OnUsb)
        Assert-False ([bool]$b.OnUsb) 'headset B is not on USB'
    }
}

Invoke-RegressionTest -Name 'The cable test runs on the cabled headset and is refused on the other' -Test {
    Assert-Nrt85Headsets
    if ($nrtB) {
        $b = Invoke-Nrt85Action -Id $nrtB.ID -Action 'cable_test'
        Add-TestEvidence ("B: ok={0} message={1}" -f $b.Json.ok, $b.Json.message)
        Assert-False ([bool]$b.Json.ok) 'the cable test must be refused over WiFi'
    }

    $a = Invoke-Nrt85Action -Id $nrtA.ID -Action 'cable_test' -ActionArgs @{ passes = 1 }
    Add-TestEvidence ("A: ok={0} push={1} MB/s pull={2} MB/s" -f $a.Json.ok, $a.Json.result.AvgPushMBps, $a.Json.result.AvgPullMBps)
    Assert-True ($a.Ok -and $a.Json.ok) 'the cable test must complete'
    Assert-True ($a.Json.result.AvgPushMBps -gt 0 -and $a.Json.result.AvgPullMBps -gt 0) 'throughput is reported'
}

# ---------------------------------------------------------------------------
# Temperatures in the metric history
# ---------------------------------------------------------------------------

Invoke-RegressionTest -Name 'CPU temperature samples reach the metric history' -Test {
    Assert-Nrt85Headsets
    if ([string]$nrtA.Brand -eq 'Pico') { Skip-Test 'PICO headsets expose no CPU sensor through thermalservice' }
    $deadline = (Get-Date).AddSeconds(120)
    $count = 0
    while ((Get-Date) -lt $deadline) {
        $r = Invoke-VrmApi -Path ('/api/metric-history?id={0}&metric=cpu_temp&hours=1' -f $nrtA.ID)
        $count = @($r.Json.samples).Count
        if ($count -ge 1) { break }
        Start-Sleep -Seconds 5
    }
    Add-TestEvidence ("cpu_temp samples in the last hour: {0}" -f $count)
    Assert-True ($count -ge 1) 'at least one cpu_temp sample'
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

Invoke-RegressionTest -Name 'Bluetooth can be switched off and on again' -Test {
    Assert-Nrt85Headsets
    $off = Invoke-Nrt85Action -Id $nrtT.ID -Action 'bluetooth_off'
    try {
        Assert-True ($off.Json.ok) 'bluetooth_off must succeed'
        Start-Sleep -Seconds 3
        $state = (Invoke-Nrt85Diag -Id $nrtT.ID -Section 'wireless').Json.data
        Add-TestEvidence ("after off: enabled={0} state={1}" -f $state.BluetoothEnabled, $state.BluetoothState)
        Assert-False ([bool]$state.BluetoothEnabled) 'Bluetooth is off'
    } finally {
        $on = Invoke-Nrt85Action -Id $nrtT.ID -Action 'bluetooth_on'
        Add-TestEvidence ("restored: ok={0}" -f $on.Json.ok)
    }
    Start-Sleep -Seconds 3
    $state2 = (Invoke-Nrt85Diag -Id $nrtT.ID -Section 'wireless').Json.data
    Add-TestEvidence ("after on: enabled={0}" -f $state2.BluetoothEnabled)
    Assert-True ([bool]$state2.BluetoothEnabled) 'Bluetooth is back on'
}

Invoke-RegressionTest -Name 'Syncing the clock leaves a drift under 5 seconds' -Test {
    Assert-Nrt85Headsets
    $sync = Invoke-Nrt85Action -Id $nrtT.ID -Action 'sync_clock' -ActionArgs @{ setTimeZone = $false }
    Assert-True ($sync.Json.ok) 'sync_clock must succeed'
    $drift = $null
    for ($i = 0; $i -lt 4; $i++) {
        Start-Sleep -Seconds 4
        $drift = (Invoke-Nrt85Diag -Id $nrtT.ID -Section 'health').Json.data.ClockDriftSec
        if ($null -ne $drift -and [Math]::Abs([int]$drift) -lt 5) { break }
    }
    Add-TestEvidence ("clock drift: {0} s" -f $drift)
    Assert-True ($null -ne $drift -and [Math]::Abs([int]$drift) -lt 5) 'clock within 5 seconds of this PC'
}

Invoke-RegressionTest -Name 'Wake and Home recovery keys are accepted' -Test {
    Assert-Nrt85Headsets
    foreach ($a in @('recover_wake', 'recover_home')) {
        $r = Invoke-Nrt85Action -Id $nrtT.ID -Action $a
        Add-TestEvidence ("{0}: ok={1}" -f $a, $r.Json.ok)
        Assert-True ($r.Json.ok) ("{0} must succeed" -f $a)
    }
}

Invoke-RegressionTest -Name 'Presets, a free-text command and a refused command behave' -Test {
    Assert-Nrt85Headsets
    $p = Invoke-VrmApi -Path '/api/headset-diag/presets'
    $presets = @($p.Json.presets)
    Add-TestEvidence ("presets: {0}" -f (($presets | ForEach-Object { $_.name }) -join ', '))
    Assert-True ($presets.Count -ge 1) 'at least one preset is configured'

    $run = Invoke-Nrt85Command -Id $nrtT.ID -Command ([string]$presets[0].command)
    Add-TestEvidence ("preset '{0}': ok={1}, {2} chars of output" -f $presets[0].name, $run.Json.ok, ([string]$run.Json.output).Length)
    Assert-True ($run.Json.ok) 'the first preset runs'

    $free = Invoke-Nrt85Command -Id $nrtT.ID -Command 'getprop ro.product.model'
    Assert-True ([bool]([string]$free.Json.output).Trim()) 'free text returns the model'

    $bad = Invoke-Nrt85Command -Id $nrtT.ID -Command 'reboot bootloader'
    Add-TestEvidence ("refused: ok={0} blocked={1}" -f $bad.Json.ok, $bad.Json.blocked)
    Assert-False ([bool]$bad.Json.ok) 'reboot bootloader must not run'
    Assert-True ([bool]$bad.Json.blocked) 'and is reported as blocked'
}

Invoke-RegressionTest -Name 'A player message is posted to the headset notification center (operator confirms)' -Test {
    Assert-Nrt85Headsets
    if ($unattended -or $depth -eq 'Light') { Skip-Test 'needs a person looking at the headset' }
    $r = Invoke-Nrt85Action -Id $nrtT.ID -Action 'player_message' -ActionArgs @{ title = 'NRT'; text = 'DIAG message test' }
    Assert-True ($r.Json.ok) 'player_message must be accepted by the headset'
    $answer = Read-OperatorObservation -Message ("On headset {0}: open the notification center. Is a notification titled NRT with the text DIAG message test listed there?" -f (Get-Nrt85HeadsetLabel -Headset $nrtT)) -Hint 'Known limit: it is NOT expected to pop up over the player view - that needs the companion app.'
    Add-TestEvidence ("operator answer: {0}" -f $answer)
    if ($answer -eq 'Skip') { Skip-Test 'operator skipped the check' }
    Assert-Equal 'Yes' $answer 'the posted message is listed in the headset notification center'
}

# ---------------------------------------------------------------------------
# Unplug / replug (operator)
# ---------------------------------------------------------------------------

Invoke-RegressionTest -Name 'A cabled headset can be asked over WiFi, and WiFi first really uses its WiFi link' -Test {
    Assert-Nrt85Headsets
    # No second headset and no setting change: the DIAG API takes a transport, which only changes
    # which link is tried FIRST (the other stays the fallback). That is enough to prove the WiFi
    # path of a cabled headset. Changing ADB.prefer_usb through the config API would NOT work
    # here: /api/config/save only refreshes the web server settings for streaming fields, the
    # rest needs a restart, so the test would be measuring a setting that has not been applied.
    $w = Invoke-Nrt85Command -Id $nrtA.ID -Command 'getprop ro.product.model' -Transport 'WiFi'
    Add-TestEvidence ("WiFi first: transport={0} ok={1} output={2}" -f $w.Json.transport, $w.Json.ok, $w.Json.output)
    Assert-True ($w.Json.ok) 'the command succeeds'
    Assert-Equal 'WiFi' ([string]$w.Json.transport) 'it went over WiFi although the cable is plugged (WiFi ADB must be enabled on A)'

    $h = Invoke-Nrt85Diag -Id $nrtA.ID -Section 'health' -Transport 'WiFi'
    Add-TestEvidence ("health section over {0}" -f $h.Json.transport)
    Assert-True ($h.Json.ok) 'a DIAG section works over WiFi'
    Assert-Equal 'WiFi' ([string]$h.Json.transport) 'and reports the WiFi transport'

    $u = Invoke-Nrt85Command -Id $nrtA.ID -Command 'getprop ro.product.model' -Transport 'USB'
    Add-TestEvidence ("USB first: transport={0} ok={1}" -f $u.Json.transport, $u.Json.ok)
    Assert-Equal 'USB' ([string]$u.Json.transport) 'USB first goes over the cable'

    $a = Invoke-Nrt85Command -Id $nrtA.ID -Command 'getprop ro.product.model'
    Add-TestEvidence ("Auto: transport={0}" -f $a.Json.transport)
    Assert-Equal 'USB' ([string]$a.Json.transport) 'Auto prefers the cable (ADB.prefer_usb is on by default)'
}

function Get-Nrt85ScrcpyCmdLine {
    $proc = Get-NrtScrcpyProcess -TargetRoot $target -Name $nrtA.Name -IPAddress $nrtA.IPAddress
    if (-not $proc) { return $null }
    return (Get-NrtProcessCommandLine -ProcessId $proc.Id)
}

function Set-Nrt85UsbSwitchMode {
    param([string]$Mode)
    $cur = Invoke-VrmApi -Path '/api/config'
    $config = $cur.Json
    if ($config.config) { $config = $config.config }
    $config.scrcpy.usb_switch_mode = $Mode
    $save = Invoke-VrmApi -Path '/api/config/save' -Method POST -Body $config -TimeoutSec 180
    return $save.Ok
}

Invoke-RegressionTest -Name 'Unplugging the cable falls back to WiFi, and replugging returns to USB' -Test {
    Assert-Nrt85Headsets
    if ($unattended -or $depth -eq 'Light') { Skip-Test 'needs a person to unplug and replug the cable' }

    $beforeCmd = Get-Nrt85ScrcpyCmdLine
    Add-TestEvidence ("scrcpy running on A before: {0}" -f [bool]$beforeCmd)

    $modes = @('stable')
    if ($depth -eq 'Full') { $modes = @('stable', 'immediate', 'next_start') }

    # Checks made while the cable is OUT are COLLECTED, never thrown. An assertion that aborted the
    # test here would leave the operator holding an unplugged headset with no prompt to put it
    # back (a real run did exactly that). The verdict is raised once, at the very end, and the
    # finally block always asks for the cable to be replugged.
    $problems = New-Object System.Collections.Generic.List[string]
    $cableOut = $false
    try {
        if (-not (Wait-OperatorAction -Message ("UNPLUG the USB cable of headset {0} now, leave it unplugged, then press Enter." -f (Get-Nrt85HeadsetLabel -Headset $nrtA)))) { Skip-Test 'operator declined the unplug step' }
        $cableOut = $true

        # 1. Function first: ADB must keep working at once, and over WiFi.
        $r = Invoke-Nrt85Command -Id $nrtA.ID -Command 'getprop ro.product.model'
        Add-TestEvidence ("after unplug: command ok={0} transport={1}" -f $r.Json.ok, $r.Json.transport)
        if (-not $r.Json.ok) { $problems.Add('an ADB command failed after the unplug') }
        elseif ([string]$r.Json.transport -ne 'WiFi') { $problems.Add(("the command answered over '{0}', expected WiFi" -f $r.Json.transport)) }

        # 2. A running capture must be restarted on ip:port. The monitor loop is busy for ~15 s while
        #    it relaunches scrcpy (encoder probe, pipeline start), so allow for that.
        if ($beforeCmd) {
            $deadline = (Get-Date).AddSeconds(45)
            $cmd = $null
            while ((Get-Date) -lt $deadline) {
                $cmd = Get-Nrt85ScrcpyCmdLine
                if ($cmd -match '-s\s+\S+:\d+') { break }
                Start-Sleep -Seconds 3
            }
            Add-TestEvidence ("scrcpy cmdline after unplug: {0}" -f $cmd)
            if ($cmd -notmatch '-s\s+\S+:\d+') { $problems.Add('scrcpy was not restarted on ip:port within 45 s') }
        }

        # 3. The status badge. It is written by the same loop that relaunches scrcpy, so it can lag.
        $s = Wait-Nrt85Transport -Id $nrtA.ID -Want 'WiFi' -Timeout 45
        Add-TestEvidence ("after unplug: adb_transport='{0}'" -f $s.adb_transport)
        if ([string]$s.adb_transport -ne 'WiFi') { $problems.Add(("status badge still '{0}' 45 s after the unplug" -f $s.adb_transport)) }

        foreach ($mode in $modes) {
            if (-not (Set-Nrt85UsbSwitchMode -Mode $mode)) { $problems.Add(("could not set scrcpy.usb_switch_mode = {0}" -f $mode)) }
            if (-not (Wait-OperatorAction -Message ("PLUG the USB cable of headset {0} back in (mode: {1}), accept the prompt if shown, then press Enter." -f (Get-Nrt85HeadsetLabel -Headset $nrtA), $mode))) { Skip-Test 'operator declined the replug step' }
            $cableOut = $false
            $s = Wait-Nrt85Transport -Id $nrtA.ID -Want 'USB' -Timeout 60
            Add-TestEvidence ("mode {0}: adb_transport='{1}'" -f $mode, $s.adb_transport)
            if ([string]$s.adb_transport -ne 'USB') { $problems.Add(("not back on USB within 60 s in mode {0} (badge '{1}')" -f $mode, $s.adb_transport)) }
            if ($beforeCmd) {
                Start-Sleep -Seconds 45
                $cmd = Get-Nrt85ScrcpyCmdLine
                Add-TestEvidence ("mode {0}: scrcpy cmdline {1}" -f $mode, $cmd)
                $onWifi = ($cmd -match '-s\s+\S+:\d+')
                if ($mode -eq 'next_start' -and -not $onWifi) { $problems.Add('next_start must not interrupt the running capture') }
                if ($mode -ne 'next_start' -and $onWifi)      { $problems.Add(("the capture did not move to USB in mode {0}" -f $mode)) }
            }
            if ($mode -ne $modes[-1]) {
                if (-not (Wait-OperatorAction -Message ("UNPLUG the USB cable of headset {0} again for the next mode, then press Enter." -f (Get-Nrt85HeadsetLabel -Headset $nrtA)))) { Skip-Test 'operator declined' }
                $cableOut = $true
                $null = Wait-Nrt85Transport -Id $nrtA.ID -Want 'WiFi' -Timeout 45
            }
        }
    } finally {
        Set-Nrt85UsbSwitchMode -Mode 'stable' | Out-Null
        if ($cableOut) {
            $null = Wait-OperatorAction -Message ("The test is ending with the cable still OUT. PLUG the USB cable of headset {0} back in, then press Enter." -f (Get-Nrt85HeadsetLabel -Headset $nrtA))
        }
    }
    # The message must never be empty: Assert-True binds it as a mandatory string, and an empty
    # one (no problems found) made a PASSING test fail with a parameter-binding error.
    Assert-True ($problems.Count -eq 0) ('unplug / replug checks: ' + $(if ($problems.Count -eq 0) { 'all ok' } else { $problems -join ' | ' }))
}

# ---------------------------------------------------------------------------
# ADB over TLS - EXPERIMENTAL, evidence only, nothing here asserts
# ---------------------------------------------------------------------------

Invoke-RegressionTest -Name 'ADB over TLS: record what the headset offers (evidence only)' -Test {
    Assert-Nrt85Headsets
    $t = Invoke-Nrt85Diag -Id $nrtT.ID -Section 'tls'
    Add-TestEvidence ("status: enabled={0} raw={1} mdnsPort={2}" -f $t.Json.data.Enabled, $t.Json.data.RawValue, $t.Json.data.MdnsPort)
    if ($t.Json.data.MdnsPort) {
        $c = Invoke-Nrt85Action -Id $nrtT.ID -Action 'tls_connect' -ActionArgs @{ port = [int]$t.Json.data.MdnsPort }
        Add-TestEvidence ("connect: ok={0} {1}" -f $c.Json.ok, $c.Json.message)
    }
    if ($unattended -or $depth -ne 'Full') { Skip-Test 'the reboot step needs a person (Full depth, attended)' }
    if (-not (Wait-OperatorAction -Message ("REBOOT headset {0}, wait until it is back on WiFi, then press Enter." -f (Get-Nrt85HeadsetLabel -Headset $nrtT)) -Hint 'Records whether Wireless debugging survives a reboot - the whole point of the experiment.')) { Skip-Test 'operator declined the reboot step' }
    Start-Sleep -Seconds 20
    $t2 = Invoke-Nrt85Diag -Id $nrtT.ID -Section 'tls'
    Add-TestEvidence ("after reboot: enabled={0} raw={1} mdnsPort={2}" -f $t2.Json.data.Enabled, $t2.Json.data.RawValue, $t2.Json.data.MdnsPort)
}
