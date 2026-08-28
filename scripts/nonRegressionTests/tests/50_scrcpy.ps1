#Requires -Version 5.1
<#
.SYNOPSIS
    Section 50 - scrcpy lifecycle against a real headset.

.DESCRIPTION
    Dot-sourced by scripts\Invoke-NonRegressionTests.ps1 inside a section context.

    NEEDS HARDWARE. The whole section SKIPs (never FAILs) when no headset from
    the operator's dev registry answers ping + ADB, so a run on a machine with
    nothing plugged in stays green.

    What this proves, in order:
      - the app starts scrcpy on its own when auto-restart is enabled
      - the process that started is the RELEASE's binary, not a stray one
      - its command line reflects the headset's configured scrcpy profile
      - stopping through the API really kills it
      - the auto-restart watchdog relaunches it after an external kill
      - a profile change is picked up by restarting scrcpy with new arguments

    Everything is driven through the public web API, the same way an operator
    drives it, except the external-kill test which is deliberately out-of-band.

    ASCII only (CLAUDE.md rule 1).
#>

$target  = $global:TestRun.TargetRoot
$devRoot = $global:TestRun.DevRoot
$depth   = $global:TestRun.Depth

# Boot BEFORE reading ports - see the note in 60_streaming.ps1. Confirm-SandboxApp
# is idempotent and also points Invoke-VrmApi at the sandbox web server.
$appUp       = Confirm-SandboxApp -TargetRoot $target -DevRoot $devRoot
$ports       = Get-NrtSandboxPorts -TargetRoot $target
$nrtHeadset  = Resolve-NrtTestHeadset -DevRoot $devRoot -AdbPort $ports.Adb
$nrtSafeName = ''
if ($nrtHeadset) { $nrtSafeName = ConvertTo-NrtSafeName -Name $nrtHeadset.Name }

function Assert-NrtHeadsetAvailable {
    <#
    .SYNOPSIS
        Skips the current test when section 50 has no headset to drive.
    #>
    if (-not $nrtHeadset) {
        Skip-Test 'no reachable headset in the dev registry (ping + ADB port) - pass -HeadsetName to force one'
    }
}

Invoke-RegressionTest -Name 'A real headset is available for streaming tests' -Test {
    Assert-NrtHeadsetAvailable
    Add-TestEvidence ("headset: {0}  model {1}" -f $nrtHeadset.Name, $nrtHeadset.Model)
    Add-TestEvidence ("profile: {0}" -f $nrtHeadset.ScrcpyProfile)
    Add-TestEvidence ("adb port {0}, mediamtx api port {1}" -f $ports.Adb, $ports.MediaMtxApi)
}

Invoke-RegressionTest -Name 'App is running' -Test {
    Assert-True $appUp 'the sandbox app is not running'
}

# ---------------------------------------------------------------------------
# Start
# ---------------------------------------------------------------------------

Invoke-RegressionTest -Name 'Auto-restart starts scrcpy for the headset' -Test {
    Assert-NrtHeadsetAvailable

    $up = Start-NrtHeadsetStream -TargetRoot $target -Headset $nrtHeadset
    Add-TestEvidence $up.Reason
    Assert-True $up.Ok $up.Reason

    Add-TestEvidence ("window title: '{0}'" -f $up.Process.MainWindowTitle)
}

Invoke-RegressionTest -Name 'The running scrcpy is the release binary' -Test {
    Assert-NrtHeadsetAvailable

    $proc = Get-NrtScrcpyProcess -TargetRoot $target -Name $nrtHeadset.Name -IPAddress $nrtHeadset.IPAddress
    Assert-NotNull $proc 'scrcpy process for the test headset'

    $path = ''
    try { $path = $proc.Path } catch { }
    Add-TestEvidence ("exe: {0}" -f $path)

    # Start-NrtHeadsetStream already filters on the target root, so this asserts
    # the sharper claim: it came out of sources\scrcpy\ inside the release.
    Assert-True ($path -like '*\sources\scrcpy\*') 'scrcpy must run from the release sources\scrcpy\ folder'
}

Invoke-RegressionTest -Name 'scrcpy arguments match the headset profile' -Test {
    Assert-NrtHeadsetAvailable

    $proc = Get-NrtScrcpyProcess -TargetRoot $target -Name $nrtHeadset.Name -IPAddress $nrtHeadset.IPAddress
    Assert-NotNull $proc 'scrcpy process for the test headset'

    $cmdLine = Get-NrtProcessCommandLine -ProcessId $proc.Id
    if (-not $cmdLine) { Skip-Test 'command line unreadable (WMI denied it)' }
    Add-TestEvidence ("cmdline: {0}" -f $cmdLine)

    # Assert against the SANDBOX registry, not the dev row: that is what the app
    # is actually configured to launch, and the two can legitimately differ.
    $row = Get-NrtSandboxHeadset -Name $nrtHeadset.Name
    Assert-NotNull $row 'the headset must be in the sandbox registry'
    $activeProfile = $row.ScrcpyProfile
    Add-TestEvidence ("registry profile: {0}" -f $activeProfile)

    $parsed = Invoke-InTargetModules -TargetRoot $target -Body ([scriptblock]::Create(
        "ConvertFrom-ScrcpyProfile -Profile '$activeProfile'"
    ))
    Assert-NotNull $parsed ("profile '{0}' must parse" -f $activeProfile)

    Assert-True ($cmdLine -match [regex]::Escape("--max-fps=$($parsed.Fps)")) `
        ("cmdline must carry --max-fps={0} from profile '{1}'" -f $parsed.Fps, $activeProfile)
    Assert-True ($cmdLine -match ("-b\s+{0}M" -f [regex]::Escape("$($parsed.BitrateMbps)"))) `
        ("cmdline must carry -b {0}M from profile '{1}'" -f $parsed.BitrateMbps, $activeProfile)

    # Audio duplication is the one profile field with a visible on/off flag.
    if ($parsed.AudioDup) {
        Assert-True ($cmdLine -match '--audio-dup') 'profile asks for audio duplication'
    }
    else {
        Assert-True ($cmdLine -match '--no-audio') 'profile asks for no audio'
    }
}

Invoke-RegressionTest -Name 'The headset reports SCRCPY running in its live status' -Test {
    Assert-NrtHeadsetAvailable

    $paths    = Get-SandboxPaths -TargetRoot $target
    $deadline = (Get-Date).AddSeconds(30)
    $seen     = $false
    $observed = ''

    while ((Get-Date) -lt $deadline -and -not $seen) {
        if (Test-Path -LiteralPath $paths.HeadsetsInfos) {
            try {
                $row = @(Import-Csv -LiteralPath $paths.HeadsetsInfos -Delimiter ';' -Encoding UTF8) |
                       Where-Object { $_.Name -eq $nrtHeadset.Name } | Select-Object -First 1
                if ($row) {
                    # Get-KnownHeadsetInfos writes the string "OK" or "-" here,
                    # not a boolean - see headsets_monitoring.ps1.
                    $observed = "$($row.SCRCPY)"
                    if ($observed -eq 'OK') { $seen = $true }
                }
            }
            catch { }
        }
        if (-not $seen) { Start-Sleep -Milliseconds 1000 }
    }

    Add-TestEvidence ("known_headsets_infos.csv SCRCPY = '{0}'" -f $observed)
    Assert-True $seen 'VRMonitor must report SCRCPY running once scrcpy is up'
}

# ---------------------------------------------------------------------------
# Stop
# ---------------------------------------------------------------------------

Invoke-RegressionTest -Name 'Stopping through the API kills scrcpy' -Test {
    Assert-NrtHeadsetAvailable

    # Auto-restart must go first, or the watchdog immediately relaunches it.
    $r = Set-NrtAutoRestart -Name $nrtHeadset.Name -Enabled $false
    Assert-True $r.Ok ('POST /api/autorestart returned HTTP ' + $r.StatusCode)

    $r = Invoke-VrmApi -Path '/api/stop-scrcpy' -Method POST -Body @{ name = $nrtSafeName }
    Assert-VrmOk -Result $r -Label 'stop scrcpy'

    $still = Wait-NrtScrcpy -TargetRoot $target -Name $nrtHeadset.Name -IPAddress $nrtHeadset.IPAddress `
                            -Running $false -TimeoutSec 45
    Assert-True ($null -eq $still) 'scrcpy must be gone within 45s of POST /api/stop-scrcpy'
    Add-TestEvidence 'scrcpy stopped and stayed stopped'
}

# ---------------------------------------------------------------------------
# Watchdog - Standard and Full only, it costs a full restart cycle
# ---------------------------------------------------------------------------

if ($depth -ne 'Light') {

    Invoke-RegressionTest -Name 'Auto-restart watchdog relaunches scrcpy after an external kill' -Test {
        Assert-NrtHeadsetAvailable

        $up = Start-NrtHeadsetStream -TargetRoot $target -Headset $nrtHeadset
        Assert-True $up.Ok $up.Reason
        $firstPid = $up.Process.Id
        Add-TestEvidence ("first PID {0}" -f $firstPid)

        # Out-of-band kill: simulates scrcpy crashing, which is exactly what the
        # watchdog exists for. Not done through the API on purpose.
        Stop-Process -Id $firstPid -Force -ErrorAction SilentlyContinue
        $gone = Wait-NrtScrcpy -TargetRoot $target -Name $nrtHeadset.Name -IPAddress $nrtHeadset.IPAddress `
                               -Running $false -TimeoutSec 30
        Assert-True ($null -eq $gone) 'the killed scrcpy should be gone'

        # 180s, not 120s: recovery is usually ~10s, but the killed scrcpy leaves
        # its ffmpeg and pipe bridge behind (Stop-Scrcpy never ran), and until
        # those clear, start-screenCopy cannot rebuild the pipeline. Observed
        # spread across runs is wide enough that a tighter bound is flaky.
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $again = Wait-NrtScrcpy -TargetRoot $target -Name $nrtHeadset.Name -IPAddress $nrtHeadset.IPAddress `
                                -Running $true -TimeoutSec 180
        $sw.Stop()
        Assert-NotNull $again 'the watchdog must relaunch scrcpy within 180s'
        Add-TestEvidence ("relaunched as PID {0} after {1:N0}s" -f $again.Id, $sw.Elapsed.TotalSeconds)
        Assert-True ($again.Id -ne $firstPid) 'the relaunched process must be a new one'

        if ($sw.Elapsed.TotalSeconds -gt 60) {
            Write-TestWarning ("watchdog recovery took {0:N0}s - orphaned ffmpeg/pipe from the killed scrcpy is slowing the relaunch" -f $sw.Elapsed.TotalSeconds)
        }
    }
}

# ---------------------------------------------------------------------------
# Profile change - Full only, it is another full restart cycle
# ---------------------------------------------------------------------------

if ($depth -eq 'Full') {

    Invoke-RegressionTest -Name 'Changing the profile restarts scrcpy with new arguments' -Test {
        Assert-NrtHeadsetAvailable

        $up = Start-NrtHeadsetStream -TargetRoot $target -Headset $nrtHeadset
        Assert-True $up.Ok $up.Reason
        $beforePid = $up.Process.Id

        $row = Get-NrtSandboxHeadset -Name $nrtHeadset.Name
        Assert-NotNull $row 'the headset must be in the sandbox registry'
        $activeProfile = $row.ScrcpyProfile

        $parsed = Invoke-InTargetModules -TargetRoot $target -Body ([scriptblock]::Create(
            "ConvertFrom-ScrcpyProfile -Profile '$activeProfile'"
        ))
        Assert-NotNull $parsed 'current profile must parse'

        # Nudge the framerate to a different legal value so the watchdog sees drift.
        $newFps = 30
        if ([int]$parsed.Fps -eq 30) { $newFps = 45 }
        $newProfile = "{0}-{1}-{2}-{3}-{4}" -f $parsed.View, $parsed.Eye,
                      $(if ($parsed.AudioDup) { 'D' } else { 'N' }), $newFps, $parsed.BitrateMbps
        Add-TestEvidence ("profile {0} -> {1}" -f $activeProfile, $newProfile)

        $r = Invoke-VrmApi -Path '/api/updateprofile' -Method POST -Body @{ name = $nrtSafeName; profile = $newProfile }
        Assert-VrmOk -Result $r -Label 'update profile'

        $deadline = (Get-Date).AddSeconds(120)
        $restarted = $null
        while ((Get-Date) -lt $deadline) {
            $p = Get-NrtScrcpyProcess -TargetRoot $target -Name $nrtHeadset.Name -IPAddress $nrtHeadset.IPAddress
            if ($p -and $p.Id -ne $beforePid) { $restarted = $p; break }
            Start-Sleep -Milliseconds 1000
        }
        Assert-NotNull $restarted 'scrcpy must restart within 120s of a profile change'

        $cmdLine = Get-NrtProcessCommandLine -ProcessId $restarted.Id
        Add-TestEvidence ("new cmdline: {0}" -f $cmdLine)
        if ($cmdLine) {
            Assert-True ($cmdLine -match [regex]::Escape("--max-fps=$newFps")) `
                ("restarted scrcpy must carry --max-fps={0}" -f $newFps)
        }

        # Put the profile the section started with back.
        Set-NrtScrcpyProfile -Name $nrtHeadset.Name -Profile $activeProfile | Out-Null
    }
}

# ---------------------------------------------------------------------------
# Teardown - always leave the sandbox quiet for section 60
# ---------------------------------------------------------------------------

Invoke-RegressionTest -Name 'Tear down the section scrcpy session' -Test {
    Assert-NrtHeadsetAvailable

    $stopped = Stop-NrtHeadsetStream -TargetRoot $target -Headset $nrtHeadset
    Add-TestEvidence ("scrcpy stopped: {0}" -f $stopped)
    Assert-True $stopped 'scrcpy must be stopped at the end of section 50'
}
