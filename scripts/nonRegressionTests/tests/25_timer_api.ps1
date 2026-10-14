#Requires -Version 5.1
<#
.SYNOPSIS
    Section 25 - /api/timer behaviour: config, start, status, pause, resume,
    stop. Behaviour only - nothing here depends on how the timer is driven
    (jobs or an engine), so it must keep passing after the timer rework.

.DESCRIPTION
    Dot-sourced by scripts\Invoke-NonRegressionTests.ps1 inside a section
    context. Uses a synthetic TEST-NET-1 headset (192.0.2.x) and restores the
    timer config and removes the headset in finally.

    ASCII only (CLAUDE.md rule 1).
#>

$target = $global:TestRun.TargetRoot
$paths  = Get-SandboxPaths -TargetRoot $target

$nrtName = 'NRT_Timer'
$nrtIp   = '192.0.2.25'

function Get-Nrt25Timer {
    param([int]$Id, [string]$Action, [string]$Extra = '')
    return (Invoke-VrmApi -Path ("/api/timer?id={0}&action={1}{2}" -f $Id, $Action, $Extra))
}

function ConvertTo-Nrt25Seconds {
    param($Value)
    if ($Value -match '^(\d+):(\d{2})$') { return ([int]$Matches[1] * 60 + [int]$Matches[2]) }
    return $null
}

function Get-Nrt25OverlayText {
    $file = Join-Path (Join-Path $paths.WebsiteFolder 'timer') ((ConvertTo-VrmSafeName $nrtName) + '[timer].txt')
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    try { return [System.IO.File]::ReadAllText($file, [System.Text.Encoding]::UTF8) } catch { return $null }
}

Invoke-RegressionTest -Name 'App is running' -Test {
    Assert-True (Confirm-SandboxApp -TargetRoot $target) 'the sandbox app is not running'
}

Invoke-RegressionTest -Name '/api/timer: config, start, pause, resume, stop' -Test {
    Invoke-VrmApi -Path '/api/removeheadset' -Method POST -Body @{ name = $nrtName } | Out-Null
    $id = 0
    $orig = $null
    try {
        $add = Invoke-VrmApi -Path '/api/addheadset' -Method POST -Body @{
            name = $nrtName; ip = $nrtIp; model = 'Quest 3'; serialNumber = 'NRTTIMER001'
        }
        Assert-VrmOk -Result $add -Label 'add the synthetic headset'
        foreach ($h in @(Get-VrmHeadsets)) { if ($h.Name -eq $nrtName) { $id = [int]$h.ID } }
        Assert-True ($id -gt 0) 'resolve the synthetic headset id'

        $s0 = Get-Nrt25Timer -Id $id -Action 'status'
        Assert-VrmOk -Result $s0 -Label 'status (initial)' -RequireOkField
        $orig = $s0.Json

        $cfg = Get-Nrt25Timer -Id $id -Action 'config' -Extra '&minutes=2&seconds=0&mode=dec'
        Assert-VrmOk -Result $cfg -Label 'config' -RequireOkField

        $st = Get-Nrt25Timer -Id $id -Action 'start'
        Assert-VrmOk -Result $st -Label 'start' -RequireOkField

        Start-Sleep -Milliseconds 1500
        $a = Get-Nrt25Timer -Id $id -Action 'status'
        Assert-True ($a.Json.active -eq $true) 'status active=true after start'
        $overlayA = Get-Nrt25OverlayText
        $va = ConvertTo-Nrt25Seconds $a.Json.value
        Start-Sleep -Seconds 3
        $b = Get-Nrt25Timer -Id $id -Action 'status'
        $vb = ConvertTo-Nrt25Seconds $b.Json.value
        Add-TestEvidence ("value {0} -> {1}" -f $a.Json.value, $b.Json.value)
        Assert-True (($null -ne $va) -and ($null -ne $vb) -and ($vb -lt $va)) 'remaining time must decrease while running'
        $overlayB = Get-Nrt25OverlayText
        Add-TestEvidence ("overlay {0} -> {1}" -f $overlayA, $overlayB)
        Assert-True (($overlayB) -and ($overlayB -ne $overlayA)) 'overlay text file must change while running'

        $p = Get-Nrt25Timer -Id $id -Action 'pause'
        Assert-VrmOk -Result $p -Label 'pause' -RequireOkField
        Start-Sleep -Milliseconds 800
        $p1 = Get-Nrt25Timer -Id $id -Action 'status'
        Start-Sleep -Seconds 2
        $p2 = Get-Nrt25Timer -Id $id -Action 'status'
        Assert-True ($p1.Json.paused -eq $true) 'status paused=true after pause'
        Assert-Equal $p1.Json.value $p2.Json.value 'value frozen while paused'

        $r = Get-Nrt25Timer -Id $id -Action 'resume'
        Assert-VrmOk -Result $r -Label 'resume' -RequireOkField
        Start-Sleep -Seconds 3
        $r2 = Get-Nrt25Timer -Id $id -Action 'status'
        Assert-True ($r2.Json.paused -ne $true) 'status paused=false after resume'
        Assert-True ((ConvertTo-Nrt25Seconds $r2.Json.value) -lt (ConvertTo-Nrt25Seconds $p2.Json.value)) 'value moves again after resume'

        $sp = Get-Nrt25Timer -Id $id -Action 'stop'
        Assert-VrmOk -Result $sp -Label 'stop' -RequireOkField
        $z = Get-Nrt25Timer -Id $id -Action 'status'
        Assert-True ($z.Json.active -ne $true) 'status active=false after stop'

        $u = Get-Nrt25Timer -Id $id -Action 'bogus'
        Assert-True ($u.JsonOk -ne $true) 'unknown action must answer ok:false'
        $m = Invoke-VrmApi -Path '/api/timer?action=status'
        Assert-Equal 400 $m.StatusCode 'missing id answers 400'
    }
    finally {
        if ($id -gt 0) {
            Get-Nrt25Timer -Id $id -Action 'stop' | Out-Null
            if ($orig) {
                $min  = if ($null -ne $orig.minutes) { [int]$orig.minutes } else { 5 }
                $sec  = if ($null -ne $orig.seconds) { [int]$orig.seconds } else { 0 }
                $mode = if ($orig.mode) { [string]$orig.mode } else { 'dec' }
                Get-Nrt25Timer -Id $id -Action 'config' -Extra ("&minutes={0}&seconds={1}&mode={2}" -f $min, $sec, $mode) | Out-Null
            }
        }
        Invoke-VrmApi -Path '/api/removeheadset' -Method POST -Body @{ name = $nrtName } | Out-Null
    }
}
