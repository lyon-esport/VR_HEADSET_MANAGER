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
    if (-not (Test-Path -LiteralPath $paths.HeadsetsInfos)) { return $null }
    try {
        return (@(Import-Csv -LiteralPath $paths.HeadsetsInfos -Delimiter ';' -Encoding UTF8) |
            Where-Object { $_.Name -eq $Name } | Select-Object -First 1)
    }
    catch { return $null }
}

Invoke-RegressionTest -Name 'App is running' -Test {
    Assert-True (Confirm-SandboxApp -TargetRoot $target) 'the sandbox app is not running'
}

Invoke-RegressionTest -Name 'VRMonitor poll loop is still advancing' -Test {
    Assert-FileExists $paths.ComputerMonJson 'data\computer_monitoring.json'

    $config = Read-JsonFileUtf8 -Path $paths.ConfigFile
    $refreshSec = 15
    if ($config -and $config.ComputerMonitoring -and $config.ComputerMonitoring.refresh_timer_sec) {
        $refreshSec = [int]$config.ComputerMonitoring.refresh_timer_sec
    }

    $before = Read-JsonFileUtf8 -Path $paths.ComputerMonJson
    Assert-NotNull $before 'first computer_monitoring.json sample'
    Add-TestArtifact -SourcePath $paths.ComputerMonJson -Category data -Rename 'computer_monitoring_before.json'

    $waitSec = $refreshSec + 8
    Add-TestEvidence ("waiting {0}s (refresh_timer_sec={1}) for the loop to produce a new sample" -f $waitSec, $refreshSec)
    Start-Sleep -Seconds $waitSec

    $after = Read-JsonFileUtf8 -Path $paths.ComputerMonJson
    Assert-NotNull $after 'second computer_monitoring.json sample'
    Add-TestArtifact -SourcePath $paths.ComputerMonJson -Category data -Rename 'computer_monitoring_after.json'

    Add-TestEvidence ("timestamp {0} -> {1}" -f $before.Timestamp, $after.Timestamp)
    Assert-True ($after.Timestamp -ne $before.Timestamp) `
        'computer_monitoring.json Timestamp must advance - the poll loop looks stalled otherwise'
}

Invoke-RegressionTest -Name 'computer_monitoring.json carries plausible hardware fields' -Test {
    $snapshot = Read-JsonFileUtf8 -Path $paths.ComputerMonJson
    Assert-NotNull $snapshot 'computer_monitoring.json parses'
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
