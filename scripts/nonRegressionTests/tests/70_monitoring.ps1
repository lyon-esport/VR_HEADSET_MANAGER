#Requires -Version 5.1
<#
.SYNOPSIS
    Section 70 - the VRMonitor subsystem itself: is the poll loop genuinely
    still running, and does it pick up registry changes without an app
    restart. Not the API surface - section 20 already cross-validates that.

.DESCRIPTION
    Dot-sourced by scripts\Invoke-NonRegressionTests.ps1 inside a section
    context. Needs no hardware: the topology-change check uses a synthetic
    TEST-NET-1 headset (192.0.2.x, RFC 5737 - never routable), the same
    convention section 40 uses, since a row appearing in
    known_headsets_infos.csv only depends on registration, not reachability
    (Get-KnownHeadsetInfos always reports a row, ping success or not).

    VQA is force-disabled by the sandbox for determinism (Initialize-
    SandboxConfig) and section 20 already asserts /api/vqa/status reflects
    that, so this section does not repeat it.

    ASCII only (CLAUDE.md rule 1).
#>

$target = $global:TestRun.TargetRoot
$paths  = Get-SandboxPaths -TargetRoot $target

$nrtName = 'NRT_Monitoring'
$nrtIp   = '192.0.2.20'

function Get-Nrt70InfoRow {
    param([Parameter(Mandatory = $true)][string]$Name)
    return (Get-SandboxHeadsetInfoRow -TargetRoot $target -Name $Name)
}

Invoke-RegressionTest -Name 'App is running' -Test {
    Assert-True (Confirm-SandboxApp -TargetRoot $target) 'the sandbox app is not running'
}

Invoke-RegressionTest -Name 'VRMonitor poll loop is still advancing' -Test {
    # Reads the snapshot through GET /api/computer-monitoring, not off disk.
    # ADR-0017 moved it into the app_kv table (Set-DbKeyValue -Key
    # 'computer_monitoring'); data\computer_monitoring.json is not written any
    # more, so the old file assertions failed on every post-migration run.
    $r = Invoke-VrmApi -Path '/api/computer-monitoring'
    $before = if ($r.Ok) { $r.Json } else { $null }
    Assert-NotNull $before 'first computer-monitoring sample'
    Assert-NotNull $before.Timestamp 'first sample Timestamp'

    # Force the refresh rather than waiting out the timer.
    #
    # Sleeping refresh_timer_sec + 8 was not reliable: the interval is ADAPTIVE
    # (Get-AdaptiveMonitorInterval = refresh_timer_sec * Get-LoadMultiplier, capped
    # at 600s), and this section runs straight after the streaming matrix, so
    # scrcpy + ffmpeg + mediamtx have the load multiplier well above 1. The loop
    # was healthy and simply not due yet - the app logs "Computer monitoring
    # skipped (not due yet)" - so the test failed on a machine doing exactly what
    # it was designed to do.
    #
    # POST /api/computer-monitoring/force-refresh drops the flag file that
    # Update-ComputerMonitoring checks BEFORE the throttle, which is precisely
    # what it exists for. That makes this a test of "is the loop alive and does it
    # produce new samples", not a race against a variable timer.
    $fr = Invoke-VrmApi -Path '/api/computer-monitoring/force-refresh' -Method POST -Body @{}
    Assert-True $fr.Ok 'POST /api/computer-monitoring/force-refresh accepted'

    $deadline = (Get-Date).AddSeconds(90)
    $after    = $null
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        $r2 = Invoke-VrmApi -Path '/api/computer-monitoring'
        if ($r2.Ok -and $r2.Json -and $r2.Json.Timestamp -and $r2.Json.Timestamp -ne $before.Timestamp) {
            $after = $r2.Json
            break
        }
    }

    Assert-NotNull $after 'the loop must publish a new sample after a forced refresh'
    Add-TestEvidence ("timestamp {0} -> {1}" -f $before.Timestamp, $after.Timestamp)
}

Invoke-RegressionTest -Name 'computer-monitoring snapshot carries plausible hardware fields' -Test {
    $r = Invoke-VrmApi -Path '/api/computer-monitoring'
    $snapshot = if ($r.Ok) { $r.Json } else { $null }
    Assert-NotNull $snapshot 'GET /api/computer-monitoring returns a snapshot'
    Assert-NotNull $snapshot.CPU 'CPU node'
    Assert-NotNull $snapshot.CPU.Model 'CPU.Model'
    Assert-NotNull $snapshot.RAM 'RAM node'
    Add-TestEvidence ("CPU: {0} ({1} cores)" -f $snapshot.CPU.Model, $snapshot.CPU.PhysicalCores)
    Add-TestEvidence ("RAM: {0} GB total" -f $snapshot.RAM.TotalGB)

    if ($snapshot.PSObject.Properties.Name -contains 'RecordingDrive' -and $snapshot.RecordingDrive) {
        Add-TestEvidence ("RecordingDrive: {0} free of {1} GB" -f $snapshot.RecordingDrive.FreeGB, $snapshot.RecordingDrive.TotalGB)
    }
}

Invoke-RegressionTest -Name 'Sync-HeadsetRunspaces picks up a headset added mid-run' -Test {
    # Clean slate in case a previous run died mid-section.
    Invoke-VrmApi -Path '/api/removeheadset' -Method POST -Body @{ name = $nrtName } | Out-Null

    $config = Read-JsonFileUtf8 -Path $paths.ConfigFile
    $refreshSec = 5
    if ($config -and $config.VRMonitor -and $config.VRMonitor.refresh_timer) {
        $refreshSec = [int]$config.VRMonitor.refresh_timer
    }
    $waitSec = $refreshSec + 10

    try {
        $add = Invoke-VrmApi -Path '/api/addheadset' -Method POST -Body @{
            name = $nrtName; ip = $nrtIp; model = 'Quest 3'; serialNumber = 'NRTMONITOR001'
        }
        Assert-VrmOk -Result $add -Label 'add the synthetic headset'

        $deadline = (Get-Date).AddSeconds($waitSec)
        $row = $null
        while ((Get-Date) -lt $deadline -and -not $row) {
            $row = Get-Nrt70InfoRow -Name $nrtName
            if (-not $row) { Start-Sleep -Milliseconds 1000 }
        }
        Add-TestEvidence ("row appeared: {0}" -f ($null -ne $row))
        Assert-NotNull $row ("a known_headsets_infos.csv row for '{0}' within {1}s of registration" -f $nrtName, $waitSec)

        $remove = Invoke-VrmApi -Path '/api/removeheadset' -Method POST -Body @{ name = $nrtName }
        Assert-VrmOk -Result $remove -Label 'remove the synthetic headset'

        $deadline = (Get-Date).AddSeconds($waitSec)
        $gone = $false
        while ((Get-Date) -lt $deadline -and -not $gone) {
            if (-not (Get-Nrt70InfoRow -Name $nrtName)) { $gone = $true }
            else { Start-Sleep -Milliseconds 1000 }
        }
        Add-TestEvidence ("row removed: {0}" -f $gone)
        Assert-True $gone ("the known_headsets_infos.csv row for '{0}' must disappear within {1}s of removal" -f $nrtName, $waitSec)
    }
    finally {
        Invoke-VrmApi -Path '/api/removeheadset' -Method POST -Body @{ name = $nrtName } | Out-Null
    }
}
