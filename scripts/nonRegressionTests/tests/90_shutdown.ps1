#Requires -Version 5.1
<#
.SYNOPSIS
    Section 90 - graceful shutdown, and the reaper watchdog's ungraceful-death
    recovery.

.DESCRIPTION
    Dot-sourced by scripts\Invoke-NonRegressionTests.ps1 inside a section
    context. Needs no hardware.

    This section deliberately ends the sandboxed app instance (twice - once
    gracefully, once by force), so it must run LAST. It already is: 90 is the
    highest section id, and the harness runs sections in registry order.

    What this proves, in order:
      - POST /api/app-shutdown (Invoke-AppShutdown) takes main, the web
        server, mediamtx and the reaper all the way down together
      - the reaper watchdog - whose entire job is otherwise untested anywhere
        in this harness - actually detects an ungraceful main death and reaps
        the orphaned web server / mediamtx processes within its poll interval,
        then exits itself

    ASCII only (CLAUDE.md rule 1).
#>

$target  = $global:TestRun.TargetRoot
$devRoot = $global:TestRun.DevRoot
$paths   = Get-SandboxPaths -TargetRoot $target

function Get-Nrt90MainProcess {
    return (Get-VrmProcessInventory -UnderRoot $target | Where-Object { $_.Role -eq 'main' } | Select-Object -First 1)
}

function Get-Nrt90ReaperProcess {
    return (Get-VrmProcessInventory -UnderRoot $target | Where-Object { $_.Role -eq 'reaper' } | Select-Object -First 1)
}

function Wait-Nrt90ProcessGone {
    param([Parameter(Mandatory = $true)][int]$ProcessId, [int]$TimeoutSec = 30)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return (-not (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue))
}

Invoke-RegressionTest -Name 'App is running' -Test {
    Assert-True (Confirm-SandboxApp -TargetRoot $target -DevRoot $devRoot) 'the sandbox app is not running'
}

# ---------------------------------------------------------------------------
# Graceful shutdown
# ---------------------------------------------------------------------------

Invoke-RegressionTest -Name 'Graceful shutdown stops main, its services and the reaper' -Test {
    $config = Read-JsonFileUtf8 -Path $paths.ConfigFile
    $wantMediaMtx = $true
    if ($null -ne $config -and $config.mediamtx) { $wantMediaMtx = [bool]$config.mediamtx.enabled }

    $mainBefore = Get-Nrt90MainProcess
    Assert-NotNull $mainBefore 'a running main.ps1 process'
    Add-TestEvidence ("main PID {0}" -f $mainBefore.Id)

    $r = Invoke-VrmApi -Path '/api/app-shutdown' -Method POST
    Assert-VrmOk -Result $r -Label 'POST /api/app-shutdown'

    Assert-True (Wait-Nrt90ProcessGone -ProcessId $mainBefore.Id -TimeoutSec 60) `
        'main.ps1 must exit within 60s of a graceful /api/app-shutdown'

    # Stop-WebServer / Stop-MediaMtx remove their own pid files on a clean exit -
    # their presence afterwards means shutdown did not finish cleanly.
    Start-Sleep -Seconds 2
    Assert-FileMissing $paths.WebServerPid 'data\webserver.pid after graceful shutdown'
    if ($wantMediaMtx) {
        Assert-FileMissing $paths.MediaMtxPid 'data\mediamtx.pid after graceful shutdown'
    }

    # Invoke-AppShutdown drops reaper_exit.flag before it returns, so the
    # standalone reaper should see it on its next ~2s poll and exit quietly
    # (no cleanup needed - everything above is already stopped).
    $deadline = (Get-Date).AddSeconds(15)
    $reaperGone = $false
    while ((Get-Date) -lt $deadline -and -not $reaperGone) {
        if (-not (Get-Nrt90ReaperProcess)) { $reaperGone = $true }
        else { Start-Sleep -Milliseconds 500 }
    }
    Add-TestEvidence ("reaper exited: {0}" -f $reaperGone)
    Assert-True $reaperGone 'the reaper must exit once reaper_exit.flag appears after a graceful shutdown'
}

# ---------------------------------------------------------------------------
# Reaper - ungraceful death recovery (the reaper's actual documented job,
# otherwise completely untested)
# ---------------------------------------------------------------------------

Invoke-RegressionTest -Name 'Reaper reaps orphans after an ungraceful main death' -Test {
    Assert-True (Confirm-SandboxApp -TargetRoot $target -DevRoot $devRoot) 'could not bring the app back up for this test'

    $config = Read-JsonFileUtf8 -Path $paths.ConfigFile
    $wantMediaMtx = $true
    if ($null -ne $config -and $config.mediamtx) { $wantMediaMtx = [bool]$config.mediamtx.enabled }

    $mainProc = Get-Nrt90MainProcess
    Assert-NotNull $mainProc 'a running main.ps1 process'

    $reaperProc = Get-Nrt90ReaperProcess
    Assert-NotNull $reaperProc 'a running reaper.ps1 process to test'

    Assert-FileExists $paths.WebServerPid 'data\webserver.pid before the kill'
    $webServerPid = [int](Get-Content -LiteralPath $paths.WebServerPid -Raw -Encoding UTF8).Trim()

    $mediaMtxPid = 0
    if ($wantMediaMtx) {
        Assert-FileExists $paths.MediaMtxPid 'data\mediamtx.pid before the kill'
        $mediaMtxPid = [int](Get-Content -LiteralPath $paths.MediaMtxPid -Raw -Encoding UTF8).Trim()
    }

    Add-TestEvidence ("killing main PID {0} out-of-band (bypassing /api/app-shutdown)" -f $mainProc.Id)
    Stop-Process -Id $mainProc.Id -Force -ErrorAction SilentlyContinue

    # The reaper polls every 2s (modules\reaper.ps1); give it a wide margin.
    Assert-True (Wait-Nrt90ProcessGone -ProcessId $webServerPid -TimeoutSec 30) `
        'the reaper must kill the orphaned web server process after main dies ungracefully'
    if ($wantMediaMtx) {
        Assert-True (Wait-Nrt90ProcessGone -ProcessId $mediaMtxPid -TimeoutSec 30) `
            'the reaper must kill the orphaned mediamtx process after main dies ungracefully'
    }

    Assert-FileMissing $paths.WebServerPid 'data\webserver.pid after the reaper cleaned up'
    if ($wantMediaMtx) {
        Assert-FileMissing $paths.MediaMtxPid 'data\mediamtx.pid after the reaper cleaned up'
    }

    # Having done its job, the reaper's own loop breaks and it exits.
    Assert-True (Wait-Nrt90ProcessGone -ProcessId $reaperProc.Id -TimeoutSec 15) `
        'the reaper must exit after reaping the orphaned services'

    Add-TestEvidence 'web server, mediamtx and the reaper itself were all reaped after an ungraceful main death'
}
