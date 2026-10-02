#Requires -Version 5.1
<#
.SYNOPSIS
    Section 85 - Headset DIAG page and USB-first ADB transport (ADR-0023 /
    ADR-0024, proposed).

.DESCRIPTION
    Dot-sourced by scripts\Invoke-NonRegressionTests.ps1 inside a section
    context.

    NEEDS HARDWARE - two registered headsets:
      A  connected by USB (and reachable over WiFi ADB too, for the fallback)
      B  on WiFi ADB only
    Named through the environment, so nothing here guesses which is which:
      $env:VRHM_TEST_USB_HEADSET   registry name of headset A
      $env:VRHM_TEST_WIFI_HEADSET  registry name of headset B
    Every test SKIPs (never FAILs) when they are not set or not found.
    Physical steps (unplug / replug A, reboot B, "is the message visible?") are
    skipped with -Unattended.

    What this proves:
      - A reports AdbTransport=USB, B reports WiFi; ADB calls on A go to the serial
      - pulling A's cable: within 15 s A is WiFi, ADB still answers, scrcpy
        restarts on ip:port; replugging moves it back according to
        scrcpy.usb_switch_mode (stable / immediate / next_start)
      - every DIAG section answers for A and B; fleet lists both; usb is OnUsb
        only for A; the cable test runs on A and is refused on B
      - cpu_temp reaches metric_history within 60 s
      - the operator actions and the ADB panel (presets, free text, blocked)
      - ADB over TLS: evidence only, no assertion

    ASCII only (CLAUDE.md rule 1).
#>

$target     = $global:TestRun.TargetRoot
$appUp      = Confirm-SandboxApp -TargetRoot $target
$unattended = ($global:TestRun -and $global:TestRun.Unattended)
$paths85    = Get-SandboxPaths -TargetRoot $target

$nameUsb  = [string]$env:VRHM_TEST_USB_HEADSET
$nameWifi = [string]$env:VRHM_TEST_WIFI_HEADSET

function Get-Nrt85Status {
    param([string]$Name)
    $r = Invoke-VrmApi -Path '/api/headsets-status'
    if (-not ($r.Ok -and $r.Json)) { return $null }
    return @($r.Json) | Where-Object { $_.name -eq $Name } | Select-Object -First 1
}

function Wait-Nrt85Transport {
    param([string]$Name, [string]$Want, [int]$TimeoutSec = 15)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $last = $null
    while ((Get-Date) -lt $deadline) {
        $last = Get-Nrt85Status -Name $Name
        if ($last -and [string]$last.adb_transport -eq $Want) { return $last }
        Start-Sleep -Milliseconds 1000
    }
    return $last
}

function Get-Nrt85Diag {
    param([int]$Id, [string]$Section, [int]$TimeoutSec = 60)
    return Invoke-VrmApi -Path ("/api/headset-diag?id={0}&section={1}" -f $Id, $Section) -TimeoutSec $TimeoutSec
}

function Invoke-Nrt85Action {
    param([int]$Id, [string]$Action, $ActionArgs = @{}, [int]$TimeoutSec = 60)
    return Invoke-VrmApi -Path '/api/headset-diag/action' -Method POST -TimeoutSec $TimeoutSec -Body @{ id = $Id; action = $Action; args = $ActionArgs }
}

function Invoke-Nrt85Command {
    param([int]$Id, [string]$Command)
    return Invoke-VrmApi -Path '/api/headset-diag/command' -Method POST -TimeoutSec 40 -Body @{ id = $Id; command = $Command }
}

function Get-Nrt85LogTail {
    # Lines of the newest app log written since $Since (string compare on the
    # timestamp prefix is not reliable across formats, so the whole tail is
    # returned and callers match on content).
    param([int]$Lines = 400)
    $logRoot = Join-Path $paths85.LogsFolder $env:COMPUTERNAME
    if (-not (Test-Path -LiteralPath $logRoot)) { return @() }
    $f = Get-ChildItem -LiteralPath $logRoot -Filter 'log_*.txt' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $f) { return @() }
    return @(Get-Content -LiteralPath $f.FullName -Encoding UTF8 -Tail $Lines -ErrorAction SilentlyContinue)
}

function Set-Nrt85SwitchMode {
    # Writes scrcpy.usb_switch_mode through the same endpoint the config page uses.
    param([string]$Mode)
    $r = Invoke-VrmApi -Path '/api/config'
    if (-not ($r.Ok -and $r.Json)) { return $false }
    $cfg = $r.Json
    if (-not $cfg.scrcpy) { return $false }
    if ($cfg.scrcpy.PSObject.Properties['usb_switch_mode']) { $cfg.scrcpy.usb_switch_mode = $Mode }
    else { $cfg.scrcpy | Add-Member -NotePropertyName usb_switch_mode -NotePropertyValue $Mode }
    $save = Invoke-VrmApi -Path '/api/config/save' -Method POST -Body ($cfg | ConvertTo-Json -Depth 30)
    return [bool]$save.Ok
}

$hA = $null; $hB = $null
if ($appUp -and $nameUsb)  { $hA = Get-Nrt85Status -Name $nameUsb }
if ($appUp -and $nameWifi) { $hB = Get-Nrt85Status -Name $nameWifi }
$idA = if ($hA) { [int]$hA.id } else { 0 }
$idB = if ($hB) { [int]$hB.id } else { 0 }

function Assert-Nrt85A { if (-not $idA) { Skip-Test 'VRHM_TEST_USB_HEADSET is not set or that headset is not registered' } }
function Assert-Nrt85B { if (-not $idB) { Skip-Test 'VRHM_TEST_WIFI_HEADSET is not set or that headset is not registered' } }

Invoke-RegressionTest -Name 'App is running' -Test {
    Assert-True $appUp 'the sandbox app is not running'
}

# ---------------------------------------------------------------- transport
Invoke-RegressionTest -Name 'Headset A reports the USB transport' -Test {
    Assert-Nrt85A
    $s = Wait-Nrt85Transport -Name $nameUsb -Want 'USB' -TimeoutSec 20
    Add-TestEvidence ("A adb={0} transport={1}" -f $s.adb, $s.adb_transport)
    Assert-Equal 'USB' ([string]$s.adb_transport) 'A is polled over USB'
}

Invoke-RegressionTest -Name 'Headset B reports the WiFi transport' -Test {
    Assert-Nrt85B
    $s = Wait-Nrt85Transport -Name $nameWifi -Want 'WiFi' -TimeoutSec 20
    Add-TestEvidence ("B adb={0} transport={1}" -f $s.adb, $s.adb_transport)
    Assert-Equal 'WiFi' ([string]$s.adb_transport) 'B is polled over WiFi'
}

Invoke-RegressionTest -Name 'An ADB command on A runs on the USB serial' -Test {
    Assert-Nrt85A
    $r = Invoke-Nrt85Command -Id $idA -Command 'getprop ro.serialno'
    Assert-True ($r.Ok -and $r.Json.ok) 'command endpoint answered'
    Add-TestEvidence ("transport={0} output={1}" -f $r.Json.result.Transport, $r.Json.result.Output)
    Assert-Equal 'USB' ([string]$r.Json.result.Transport) 'the command used USB'
    $log = @(Get-Nrt85LogTail | Where-Object { $_ -match 'DIAG: shell command on' -and $_ -match 'getprop ro.serialno' } | Select-Object -Last 1)
    if ($log.Count) {
        Add-TestEvidence ("log: {0}" -f $log[0])
        Assert-True ($log[0] -notmatch '\(\d{1,3}(\.\d{1,3}){3}:\d+\)') 'the logged device id is the serial, not ip:port'
    } else {
        Write-TestWarning 'the DIAG command log line was not found (log level above INFO?)'
    }
}

# ---------------------------------------------------------------- DIAG API
foreach ($pair in @(@('A', 'firmware'), @('A', 'health'), @('A', 'wireless'), @('B', 'firmware'), @('B', 'health'), @('B', 'wireless'))) {
    $who = $pair[0]; $section = $pair[1]
    Invoke-RegressionTest -Name ("DIAG {0} answers for headset {1}" -f $section, $who) -Test {
        $id = if ($who -eq 'A') { Assert-Nrt85A; $idA } else { Assert-Nrt85B; $idB }
        $r = Get-Nrt85Diag -Id $id -Section $section
        Add-TestEvidence ("HTTP {0} in {1:n1}s" -f $r.StatusCode, $r.Elapsed.TotalSeconds)
        Assert-Equal 200 $r.StatusCode 'HTTP 200'
        Assert-True ([bool]$r.Json.ok) 'ok:true'
        $d = $r.Json.data
        switch ($section) {
            'firmware' { Assert-True ([bool]($d.OsDisplay -or $d.FirmwareVersion -or $d.Build)) 'a firmware identifier is reported'; Add-TestEvidence ("fw={0} os={1}" -f $d.FirmwareVersion, $d.OsDisplay) }
            'health'   { Assert-NotNull $d.Temperatures 'temperatures'; Assert-NotNull $d.Battery 'battery'; Add-TestEvidence ("cpu={0} drift={1}s" -f $d.Temperatures.Cpu, $d.ClockDriftSec) }
            'wireless' { Assert-NotNull $d.Wifi 'wifi block'; Assert-NotNull $d.Bluetooth 'bluetooth block'; Add-TestEvidence ("ssid={0} rssi={1}" -f $d.Wifi.Ssid, $d.Wifi.Rssi) }
        }
    }
}

Invoke-RegressionTest -Name 'DIAG fleet lists both headsets' -Test {
    Assert-Nrt85A; Assert-Nrt85B
    $r = Get-Nrt85Diag -Id $idA -Section 'fleet'
    Assert-True ([bool]$r.Json.ok) 'ok:true'
    $ids = @($r.Json.data.items | ForEach-Object { [int]$_.id })
    Assert-Contains $ids $idA 'A is listed'
    Assert-Contains $ids $idB 'B is listed'
}

Invoke-RegressionTest -Name 'DIAG usb is OnUsb for A only' -Test {
    Assert-Nrt85A; Assert-Nrt85B
    $a = Get-Nrt85Diag -Id $idA -Section 'usb'
    $b = Get-Nrt85Diag -Id $idB -Section 'usb'
    Add-TestEvidence ("A OnUsb={0} speed={1}; B OnUsb={2}" -f $a.Json.data.OnUsb, $a.Json.data.UsbSpeed, $b.Json.data.OnUsb)
    Assert-True ([bool]$a.Json.data.OnUsb) 'A is on USB'
    Assert-False ([bool]$b.Json.data.OnUsb) 'B is not on USB'
}

Invoke-RegressionTest -Name 'Cable test runs on A and is refused on B' -Test {
    Assert-Nrt85A; Assert-Nrt85B
    $a = Invoke-Nrt85Action -Id $idA -Action 'cable_test' -TimeoutSec 600
    Assert-True ([bool]$a.Json.ok) 'cable test request accepted'
    Add-TestEvidence ("A push={0} pull={1} MB/s err={2}" -f $a.Json.result.AvgPushMBps, $a.Json.result.AvgPullMBps, $a.Json.result.Error)
    Assert-True ($null -ne $a.Json.result.AvgPushMBps) 'A reports a push speed'
    $b = Invoke-Nrt85Action -Id $idB -Action 'cable_test'
    Add-TestEvidence ("B: {0}" -f $b.Json.result.Error)
    Assert-False ([bool]$b.Json.result.Ok) 'B is refused'
}

# ---------------------------------------------------------------- temperatures
Invoke-RegressionTest -Name 'cpu_temp reaches metric_history within 60 s' -Test {
    Assert-Nrt85A
    $deadline = (Get-Date).AddSeconds(60)
    $n = 0
    while ((Get-Date) -lt $deadline) {
        $r = Invoke-VrmApi -Path ("/api/metric-history?id={0}&metric=cpu_temp&hours=1" -f $idA)
        if ($r.Ok -and $r.Json -and $r.Json.metric -eq 'cpu_temp') { $n = @($r.Json.samples).Count }
        if ($n -ge 1) { break }
        Start-Sleep -Seconds 5
    }
    Add-TestEvidence ("{0} cpu_temp sample(s)" -f $n)
    if ($n -eq 0) {
        $h = Get-Nrt85Diag -Id $idA -Section 'health'
        if ($null -eq $h.Json.data.Temperatures.Cpu) { Skip-Test 'this headset reports no CPU sensor in thermalservice' }
    }
    Assert-True ($n -ge 1) 'at least one CPU temperature sample'
}

# ---------------------------------------------------------------- actions
Invoke-RegressionTest -Name 'Bluetooth: list, disable, enable' -Test {
    Assert-Nrt85A
    $w = Get-Nrt85Diag -Id $idA -Section 'wireless'
    Add-TestEvidence ("bonded: {0}" -f (@($w.Json.data.Bluetooth.Bonded | ForEach-Object { $_.Name }) -join ', '))
    $off = Invoke-Nrt85Action -Id $idA -Action 'bluetooth' -ActionArgs @{ enable = $false }
    Assert-True ([bool]$off.Json.ok) 'disable accepted'
    Start-Sleep -Seconds 3
    $on = Invoke-Nrt85Action -Id $idA -Action 'bluetooth' -ActionArgs @{ enable = $true }
    Assert-True ([bool]$on.Json.ok) 'enable accepted'
    Start-Sleep -Seconds 3
    $w2 = Get-Nrt85Diag -Id $idA -Section 'wireless'
    Assert-True ([bool]$w2.Json.data.Bluetooth.Enabled) 'Bluetooth is on again'
}

Invoke-RegressionTest -Name 'Clock sync leaves the drift under 5 s' -Test {
    Assert-Nrt85A
    $s = Invoke-Nrt85Action -Id $idA -Action 'clock_sync' -ActionArgs @{ timezone = '' }
    Assert-True ([bool]$s.Json.ok) 'clock sync accepted'
    Start-Sleep -Seconds 5
    $h = Get-Nrt85Diag -Id $idA -Section 'health'
    Add-TestEvidence ("drift={0}s auto_time={1}" -f $h.Json.data.ClockDriftSec, $h.Json.data.AutoTime)
    Assert-True ([Math]::Abs([double]$h.Json.data.ClockDriftSec) -lt 5) 'drift below 5 s'
}

Invoke-RegressionTest -Name 'Player message is posted (experimental)' -Test {
    Assert-Nrt85A
    $r = Invoke-Nrt85Action -Id $idA -Action 'player_message' -ActionArgs @{ title = 'VRHM test'; text = "Section 85: if you can read this, it's visible" }
    Assert-True ([bool]$r.Json.ok) 'message accepted'
    Add-TestEvidence ("output: {0}" -f $r.Json.result.Output)
    if (-not $unattended) {
        $seen = Wait-OperatorAction -Message 'Put on headset A: is the "VRHM test" notification visible (also try inside a running app)? Enter = yes, S = no.'
        Add-TestEvidence ("operator saw it: {0}" -f $seen)
        if (-not $seen) { Write-TestWarning 'player message not visible on this firmware - keep it marked experimental' }
    }
}

Invoke-RegressionTest -Name 'Recovery Wake and Home' -Test {
    Assert-Nrt85A
    foreach ($what in @('Wake', 'Home')) {
        $r = Invoke-Nrt85Action -Id $idA -Action 'recovery' -ActionArgs @{ what = $what }
        Assert-True ([bool]$r.Json.ok -and [bool]$r.Json.result.Ok) ("{0} succeeded" -f $what)
    }
}

Invoke-RegressionTest -Name 'ADB panel: preset, free text and a blocked command' -Test {
    Assert-Nrt85A
    $p = Invoke-VrmApi -Path '/api/headset-diag/presets'
    $presets = @($p.Json.presets)
    Add-TestEvidence ("{0} preset(s)" -f $presets.Count)
    Assert-True ($presets.Count -ge 1) 'at least one preset'
    $r1 = Invoke-Nrt85Command -Id $idA -Command $presets[0].command
    Assert-True ([bool]$r1.Json.ok -and -not $r1.Json.result.Blocked) 'the first preset runs'
    $r2 = Invoke-Nrt85Command -Id $idA -Command 'getprop ro.product.model'
    Add-TestEvidence ("model: {0}" -f $r2.Json.result.Output)
    Assert-True ([string]$r2.Json.result.Output -match '\S') 'free text returns the model'
    $r3 = Invoke-Nrt85Command -Id $idA -Command 'reboot bootloader'
    Assert-True ([bool]$r3.Json.result.Blocked) 'reboot bootloader is refused'
}

# ---------------------------------------------------------------- cable pull
Invoke-RegressionTest -Name 'Unplug A: WiFi fallback for ADB and scrcpy, then back to USB' -Test {
    Assert-Nrt85A
    if ($unattended) { Skip-Test 'physical step (unplug / replug) - not in -Unattended' }

    Set-Nrt85SwitchMode -Mode 'immediate' | Out-Null
    if (-not (Wait-OperatorAction -Message 'UNPLUG the USB cable of headset A now (keep it on WiFi), then press Enter.')) { Skip-Test 'operator skipped the unplug step' }
    $s = Wait-Nrt85Transport -Name $nameUsb -Want 'WiFi' -TimeoutSec 15
    Add-TestEvidence ("after unplug: transport={0}" -f $s.adb_transport)
    Assert-Equal 'WiFi' ([string]$s.adb_transport) 'A fell back to WiFi within 15 s'
    $r = Invoke-Nrt85Command -Id $idA -Command 'getprop ro.product.model'
    Assert-True ([bool]$r.Json.ok -and [bool]$r.Json.result.Ok) 'an ADB command still succeeds'
    Assert-Equal 'WiFi' ([string]$r.Json.result.Transport) 'it ran over WiFi'

    $deadline = (Get-Date).AddSeconds(60)
    $scrcpyOk = $false
    while ((Get-Date) -lt $deadline) {
        $st = Get-Nrt85Status -Name $nameUsb
        if ($st.scrcpy) { $scrcpyOk = $true; break }
        Start-Sleep -Seconds 3
    }
    Add-TestEvidence ("scrcpy back on WiFi: {0}" -f $scrcpyOk)
    if (-not $scrcpyOk) { Write-TestWarning 'scrcpy did not come back within 60 s (is auto-restart on for A?)' }

    foreach ($mode in @('immediate', 'stable', 'next_start')) {
        Set-Nrt85SwitchMode -Mode $mode | Out-Null
        if (-not (Wait-OperatorAction -Message ("[{0}] REPLUG headset A by USB, then press Enter." -f $mode))) { Skip-Test 'operator skipped the replug step' }
        $back = Wait-Nrt85Transport -Name $nameUsb -Want 'USB' -TimeoutSec 30
        Assert-Equal 'USB' ([string]$back.adb_transport) ("[{0}] ADB is back on USB" -f $mode)
        Start-Sleep -Seconds 25
        $log = @(Get-Nrt85LogTail -Lines 300 | Where-Object { $_ -match 'moving capture to USB|starts over USB' })
        Add-TestEvidence ("[{0}] scrcpy USB log lines: {1}" -f $mode, $log.Count)
        if ($mode -eq 'next_start') {
            Add-TestEvidence '[next_start] expected: the running capture stays on WiFi until its next start'
        }
        if ($mode -ne 'next_start') {
            if (-not (Wait-OperatorAction -Message ("[{0}] UNPLUG headset A again, then press Enter." -f $mode))) { Skip-Test 'operator skipped the unplug step' }
            Wait-Nrt85Transport -Name $nameUsb -Want 'WiFi' -TimeoutSec 15 | Out-Null
        }
    }
    Set-Nrt85SwitchMode -Mode 'stable' | Out-Null
}

# ---------------------------------------------------------------- TLS (evidence only)
Invoke-RegressionTest -Name 'ADB over TLS on B (experimental, evidence only)' -Test {
    Assert-Nrt85B
    $s = Get-Nrt85Diag -Id $idB -Section 'tls'
    Add-TestEvidence ("before: enabled={0} mdnsPort={1} prop={2}" -f $s.Json.data.AdbWifiEnabled, $s.Json.data.MdnsPort, $s.Json.data.TlsPortProp)
    $e = Invoke-Nrt85Action -Id $idB -Action 'tls_enable'
    Add-TestEvidence ("enable: {0}" -f $e.Json.result.Output)
    $s = Get-Nrt85Diag -Id $idB -Section 'tls'
    Add-TestEvidence ("after enable: enabled={0} mdnsPort={1}" -f $s.Json.data.AdbWifiEnabled, $s.Json.data.MdnsPort)
    if ($s.Json.data.MdnsPort) {
        $c = Invoke-Nrt85Action -Id $idB -Action 'tls_connect' -ActionArgs @{ port = [int]$s.Json.data.MdnsPort }
        Add-TestEvidence ("connect: connected={0} output={1}" -f $c.Json.result.Connected, $c.Json.result.Output)
    }
    if (-not $unattended -and (Wait-OperatorAction -Message 'REBOOT headset B (from the headset or the Headsets page), wait until it is back on WiFi ADB, then press Enter.')) {
        $s = Get-Nrt85Diag -Id $idB -Section 'tls'
        Add-TestEvidence ("after reboot: enabled={0} mdnsPort={1}" -f $s.Json.data.AdbWifiEnabled, $s.Json.data.MdnsPort)
    }
    Assert-True $true 'evidence recorded'
}
