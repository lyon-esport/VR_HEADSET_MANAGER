#Requires -Version 5.1
<#
.SYNOPSIS
    Section 86 - ADB WiFi modes (ADR-0034): classic + TLS, ADB auto-enable app.

.DESCRIPTION
    Dot-sourced by scripts\Invoke-NonRegressionTests.ps1 inside a section context.

    Tests, in order:
      1. The headset-free unit suite scripts\Test-AdbWifiModes.ps1 (run from the DEV tree: scripts\
         is not shipped in a release). The section fails when it fails.
      2. Config round trip of ADB.wifi_classic_enabled / wifi_tls_enabled / wifi_preferred_mode and
         the defaults served by /api/config/defaults, including the "both off" case.
      3. /api/headsets-status carries adb_wifi_mode.
      4. /api/usbdeviceinfo carries autoEnableInstalled.
      5. POST /api/installadbautoenable without a USB headset answers {ok:false} and the USB-busy
         claim is shrunk again (the route must not leave the watcher blocked for 180 s).
      6. (needs hardware, SKIP otherwise) a headset reachable only over TLS: status green,
         adb_wifi_mode = TLS, a DIAG firmware section answers. Name it with
         VRHM_TEST_TLS_HEADSET (registered in the DEV registry) and optionally
         VRHM_TEST_TLS_HEADSET_IP.

    Light depth runs 1 to 5 only (no headset needed).

    ASCII only (CLAUDE.md rule 1).
#>

$target  = $global:TestRun.TargetRoot
$devRoot = $global:TestRun.DevRoot
$depth   = $global:TestRun.Depth
$appUp   = Confirm-SandboxApp -TargetRoot $target -DevRoot $devRoot

function Get-Nrt86Config {
    $cur = Invoke-VrmApi -Path '/api/config'
    $cfg = $cur.Json
    if ($cfg -and $cfg.config) { $cfg = $cfg.config }
    return $cfg
}

function Save-Nrt86Config {
    param($Config)
    return (Invoke-VrmApi -Path '/api/config/save' -Method POST -Body $Config -TimeoutSec 180)
}

function Set-Nrt86AdbKeys {
    param([bool]$Classic, [bool]$Tls, [string]$Preferred)
    $cfg = Get-Nrt86Config
    $cfg.ADB.wifi_classic_enabled = $Classic
    $cfg.ADB.wifi_tls_enabled     = $Tls
    $cfg.ADB.wifi_preferred_mode  = $Preferred
    return (Save-Nrt86Config -Config $cfg)
}

Invoke-RegressionTest -Name 'App is running' -Test {
    Assert-True $appUp 'the sandbox app is not running'
}

Invoke-RegressionTest -Name 'The headset-free unit suite (Test-AdbWifiModes.ps1) passes' -Test {
    $script = Join-Path $devRoot 'scripts\Test-AdbWifiModes.ps1'
    if (-not (Test-Path -LiteralPath $script)) { Skip-Test 'scripts\Test-AdbWifiModes.ps1 not found in the dev tree' }
    # The console host from $PSHOME, never the current process: run from the ISE, $PID is
    # powershell_ise.exe, which rejects -ExecutionPolicy (TEST30: exit -1, no output, an
    # error dialog on screen).
    $psExe = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $psExe)) { $psExe = Join-Path $PSHOME 'pwsh.exe' }
    # Output and errors go to files, with a timeout: TEST30 saw exit -1 with NO output at all,
    # which a 2>&1 pipe cannot explain. Exit 0/1 is the suite's own verdict; any other code is
    # the process failing (load error, crash, kill), retried once with its stderr as evidence.
    $code = $null; $out = @(); $err = ''
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $outFile = Join-Path $env:TEMP ('vrhm_nrt86_{0}_out.txt' -f [guid]::NewGuid().ToString('N'))
        $errFile = [IO.Path]::ChangeExtension($outFile, '.err.txt')
        try {
            $p = Start-Process -FilePath $psExe -PassThru -NoNewWindow `
                -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $script)) `
                -RedirectStandardOutput $outFile -RedirectStandardError $errFile
            $null = $p.Handle   # PS 5.1: without the handle cached now, ExitCode reads back empty
            if (-not $p.WaitForExit(120000)) { try { $p.Kill() } catch { }; $code = 'timeout' }
            else { $code = $p.ExitCode }
            if (Test-Path -LiteralPath $outFile) { $out = @(Get-Content -LiteralPath $outFile -Encoding UTF8) }
            if (Test-Path -LiteralPath $errFile) { $err = [string](Get-Content -LiteralPath $errFile -Raw -Encoding UTF8) }
        } finally {
            Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
        }
        if ($code -eq 0 -or $code -eq 1) { break }
        Add-TestEvidence ("attempt {0}: exit {1}, {2} output line(s), stderr: {3}" -f $attempt, $code, $out.Count, ($err -replace '\s+', ' ').Trim())
    }
    $summary = @($out | Where-Object { $_ -match 'case\(s\)' }) | Select-Object -Last 1
    Add-TestEvidence ("summary: {0}" -f $summary)
    $failed = @($out | Where-Object { $_ -match '^\[FAIL\]' })
    foreach ($f in ($failed | Select-Object -First 10)) { Add-TestEvidence $f }
    Assert-True ($code -eq 0) ("unit suite exit code {0}, {1} failed case(s)" -f $code, $failed.Count)
}

Invoke-RegressionTest -Name 'The ADB WiFi mode keys round trip through /api/config/save' -Test {
    $orig = Get-Nrt86Config
    Assert-NotNull $orig.ADB 'config has an ADB section'
    $keep = @{
        c = [bool]$orig.ADB.wifi_classic_enabled
        t = [bool]$orig.ADB.wifi_tls_enabled
        p = [string]$orig.ADB.wifi_preferred_mode
    }
    try {
        $s = Set-Nrt86AdbKeys -Classic $false -Tls $true -Preferred 'tls'
        Assert-True ($s.Ok) 'save (TLS only, preferred tls)'
        $back = (Get-Nrt86Config).ADB
        Add-TestEvidence ("read back: classic={0} tls={1} preferred={2}" -f $back.wifi_classic_enabled, $back.wifi_tls_enabled, $back.wifi_preferred_mode)
        Assert-False ([bool]$back.wifi_classic_enabled) 'classic stays off'
        Assert-True  ([bool]$back.wifi_tls_enabled) 'tls stays on'
        Assert-Equal 'tls' ([string]$back.wifi_preferred_mode) 'preferred mode'

        # Both off: the file may keep the operator's values, the loader forces classic on (WARNING).
        # What must hold: the save is accepted and the app keeps serving.
        $s2 = Set-Nrt86AdbKeys -Classic $false -Tls $false -Preferred 'classic'
        Assert-True ($s2.Ok) 'save with both modes off is accepted'
        $ping = Invoke-VrmApi -Path '/api/headsets-status'
        Assert-True ($ping.Ok) 'the app still answers after both modes were switched off'
    } finally {
        $null = Set-Nrt86AdbKeys -Classic $keep.c -Tls $keep.t -Preferred $keep.p
    }
    $final = (Get-Nrt86Config).ADB
    Assert-Equal ([string]$keep.p) ([string]$final.wifi_preferred_mode) 'preferred mode restored'
}

Invoke-RegressionTest -Name '/api/config/defaults serves the ADB WiFi mode defaults' -Test {
    $d = Invoke-VrmApi -Path '/api/config/defaults'
    Assert-True ($d.Ok) '/api/config/defaults answers'
    $cfg = $d.Json
    if ($cfg -and $cfg.config) { $cfg = $cfg.config }
    Add-TestEvidence ("defaults: classic={0} tls={1} preferred={2}" -f $cfg.ADB.wifi_classic_enabled, $cfg.ADB.wifi_tls_enabled, $cfg.ADB.wifi_preferred_mode)
    Assert-True ([bool]$cfg.ADB.wifi_classic_enabled) 'default classic is on'
    Assert-True ([bool]$cfg.ADB.wifi_tls_enabled) 'default tls is on'
    # ADR-0037: the shipped default is 'auto' (no preference, classic first, no switching).
    Assert-Equal 'auto' ([string]$cfg.ADB.wifi_preferred_mode) 'default preferred mode'
}

Invoke-RegressionTest -Name '/api/headsets-status carries adb_wifi_mode' -Test {
    $r = Invoke-VrmApi -Path '/api/headsets-status'
    Assert-True ($r.Ok) '/api/headsets-status answers'
    $rows = @($r.Json)
    if ($rows.Count -eq 0) { Skip-Test 'no headset registered in the sandbox' }
    foreach ($row in $rows) {
        Assert-True ($row.PSObject.Properties['adb_wifi_mode']) ("headset {0} has the adb_wifi_mode field" -f $row.id)
        Assert-True (@('Classic', 'TLS', '') -contains [string]$row.adb_wifi_mode -or [string]$row.adb_wifi_mode -eq '-') ("adb_wifi_mode value '{0}' is Classic, TLS or empty" -f $row.adb_wifi_mode)
    }
}

Invoke-RegressionTest -Name '/api/usbdeviceinfo carries autoEnableInstalled' -Test {
    $r = Invoke-VrmApi -Path '/api/usbdeviceinfo'
    Assert-True ($r.Ok) '/api/usbdeviceinfo answers'
    Add-TestEvidence ("found={0} autoEnableInstalled={1}" -f $r.Json.found, $r.Json.autoEnableInstalled)
    Assert-True ($r.Json.PSObject.Properties['autoEnableInstalled']) 'the autoEnableInstalled field exists'
}

Invoke-RegressionTest -Name 'POST /api/installadbautoenable with no USB headset answers ok:false and frees the USB claim' -Test {
    $det = Invoke-VrmApi -Path '/api/usbdeviceinfo'
    if ($det.Json.found) { Skip-Test 'a USB headset is cabled: this route would really install the app' }
    $r = Invoke-VrmApi -Path '/api/installadbautoenable' -Method POST -Body @{} -TimeoutSec 60
    Add-TestEvidence ("HTTP {0} ok={1} error={2}" -f $r.StatusCode, $r.Json.ok, $r.Json.error)
    Assert-True ($r.Ok) 'the route answers'
    Assert-False ([bool]$r.Json.ok) 'ok is false'
    Assert-True ([bool][string]$r.Json.error) 'an error message is given'
    # The route claims USB for 180 s and must shrink the claim to 10 s in finally. A second call
    # right away must still answer at once (not wait for, or be refused by, a stale claim).
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r2 = Invoke-VrmApi -Path '/api/installadbautoenable' -Method POST -Body @{} -TimeoutSec 60
    Add-TestEvidence ("second call: ok={0} after {1} ms" -f $r2.Json.ok, $sw.ElapsedMilliseconds)
    Assert-False ([bool]$r2.Json.ok) 'second call also ok:false'
    Assert-True ($sw.ElapsedMilliseconds -lt 15000) 'the second call is not blocked by a leftover USB claim'
}

# ---------------------------------------------------------------------------
# Hardware: a headset reachable only over TLS. Skips when none is named.
# ---------------------------------------------------------------------------

Invoke-RegressionTest -Name 'A TLS-only headset is green, reports adb_wifi_mode TLS and answers a DIAG section' -Test {
    if ($depth -eq 'Light') { Skip-Test 'hardware test, not run at Light depth' }
    $name = $env:VRHM_TEST_TLS_HEADSET
    if (-not $name) { Skip-Test 'set VRHM_TEST_TLS_HEADSET to a registered headset reachable only over TLS (classic ADB off)' }
    $dev = Get-NrtDevHeadsets -DevRoot $devRoot | Where-Object { $_.Name -eq $name } | Select-Object -First 1
    if (-not $dev) { Skip-Test ("headset '{0}' not found in the dev registry" -f $name) }
    if ($env:VRHM_TEST_TLS_HEADSET_IP) { $dev = $dev.PSObject.Copy(); $dev.IPAddress = $env:VRHM_TEST_TLS_HEADSET_IP }
    $row = Get-NrtSandboxHeadset -Name $name
    if (-not $row) { Add-NrtSandboxHeadset -Headset $dev | Out-Null; $row = Get-NrtSandboxHeadset -Name $name }

    $deadline = (Get-Date).AddSeconds(120)
    $s = $null
    while ((Get-Date) -lt $deadline) {
        $r = Invoke-VrmApi -Path '/api/headsets-status'
        $s = @($r.Json) | Where-Object { [string]$_.id -eq [string]$row.ID } | Select-Object -First 1
        if ($s -and $s.adb -and [string]$s.adb_wifi_mode -eq 'TLS') { break }
        Start-Sleep -Seconds 3
    }
    Add-TestEvidence ("status: adb={0} adb_wifi_mode='{1}' transport='{2}'" -f $s.adb, $s.adb_wifi_mode, $s.adb_transport)
    Assert-True ([bool]$s.adb) 'ADB reports up'
    Assert-Equal 'TLS' ([string]$s.adb_wifi_mode) 'adb_wifi_mode'

    $d = Invoke-VrmApi -Path ('/api/headset-diag?id={0}&section=firmware' -f $row.ID) -TimeoutSec 90
    Add-TestEvidence ("firmware: ok={0} transport={1} error={2}" -f $d.Json.ok, $d.Json.transport, $d.Json.error)
    Assert-True ($d.Ok -and $d.Json.ok) 'the DIAG firmware section answers over TLS'
}
