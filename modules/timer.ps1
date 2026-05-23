
# Per-headset timers. Timer state is stored in $script:activeTimers so it
# persists across API calls within the same process (web server or main console).
# Timer files live in website\timer\<DisplayName>[timer].txt and are served as static files.
# The elapsed handler runs in a Start-Job child process to avoid PS runspace conflicts.
# A run-token file (<DisplayName>[timer].run) lets orphaned jobs from previous processes stop
# themselves when a new timer starts: the job exits as soon as its token no longer matches the file.

$script:activeTimers = @{}   # key: int headsetId, value: @{job; filePath; paused; pausedRemaining; mode; startTime; totalSecs}

function Get-TimerSafeName {
    param([int]$headsetId)
    $h = @(Get-KnownHeadsets) | Where-Object { [int]$_.ID -eq $headsetId } | Select-Object -First 1
    if ($h -and $h.Name) { return Convert-Displayname $h.Name }
    return [string]$headsetId
}

function Get-TimerFilePath {
    param([int]$headsetId)
    return Join-Path $global:ScriptPath ("website\timer\" + (Get-TimerSafeName $headsetId) + "[timer].txt")
}

function Get-TimerRunFilePath {
    param([int]$headsetId)
    return Join-Path $global:ScriptPath ("website\timer\" + (Get-TimerSafeName $headsetId) + "[timer].run")
}

function Get-TimerCsvPath {
    return Join-Path $global:ScriptPath "data\timer.csv"
}

function Initialize-TimerFiles {
    $timerFolder = Join-Path $global:ScriptPath "website\timer"
    if (-not (Test-Path -LiteralPath $timerFolder)) {
        $null = New-Item -ItemType Directory -Path $timerFolder -Force
        Write-Log ($msg.TimerFolderCreated -f $timerFolder) -Level INFO
    }

    $csvPath = Get-TimerCsvPath
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    if (-not (Test-Path -LiteralPath $csvPath)) {
        [System.IO.File]::WriteAllText($csvPath, '"HeadsetID","Minutes","Seconds","Mode"' + "`n", $utf8NoBom)
    }

    # Load existing CSV rows once to avoid re-reading for each headset
    $existingCsvIds = @{}
    if (Test-Path -LiteralPath $csvPath) {
        @(Import-Csv -LiteralPath $csvPath) | ForEach-Object { $existingCsvIds[[int]$_.HeadsetID] = $true }
    }

    $headsets = Get-KnownHeadsets
    $count = 0
    foreach ($h in $headsets) {
        $id = [int]$h.ID
        # Only create files if they don't exist - never overwrite a running timer
        $filePath = Get-TimerFilePath -headsetId $id
        if (-not (Test-Path -LiteralPath $filePath)) {
            [System.IO.File]::WriteAllText($filePath, '', $utf8NoBom)
            $count++
        }
        $runFilePath = Get-TimerRunFilePath -headsetId $id
        if (-not (Test-Path -LiteralPath $runFilePath)) {
            [System.IO.File]::WriteAllText($runFilePath, '', $utf8NoBom)
        }
        # Add default CSV config row only if this headset has no entry yet
        if (-not $existingCsvIds.ContainsKey($id)) {
            Set-TimerConfig -headsetId $id -minutes 5 -seconds 0 -mode 'dec'
        }
    }
    if ($count -gt 0) {
        Write-Log ($msg.TimerFilesInitialized -f $count) -Level DEBUG
    }

    # Clean up any old numeric or intermediate-named files; ensure only [timer]-named files remain
    foreach ($h in $headsets) {
        $id = [int]$h.ID
        $safeName = Get-TimerSafeName $id
        foreach ($suffix in @('.txt', '.run')) {
            $timerSuffix = if ($suffix -eq '.txt') { '[timer].txt' } else { '[timer].run' }
            $correctFile = Join-Path $global:ScriptPath ("website\timer\" + $safeName + $timerSuffix)
            foreach ($oldName in @(([string]$id + $suffix), ($safeName + $suffix))) {
                $oldFile = Join-Path $global:ScriptPath ("website\timer\" + $oldName)
                if ((Test-Path -LiteralPath $oldFile) -and ($oldFile -ne $correctFile)) {
                    if (Test-Path -LiteralPath $correctFile) {
                        Remove-Item -LiteralPath $oldFile -Force -ErrorAction SilentlyContinue
                    } else {
                        Rename-Item -LiteralPath $oldFile -NewName (Split-Path $correctFile -Leaf) -Force -ErrorAction SilentlyContinue
                    }
                }
            }
        }
    }
}

function Clear-TimerFile {
    param([int]$headsetId)
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText((Get-TimerFilePath    -headsetId $headsetId), '', $utf8NoBom)
    [System.IO.File]::WriteAllText((Get-TimerRunFilePath -headsetId $headsetId), '', $utf8NoBom)
}

function Get-TimerConfig {
    param([int]$headsetId)
    $csvPath = Get-TimerCsvPath
    if (Test-Path -LiteralPath $csvPath) {
        $rows = @(Import-Csv -LiteralPath $csvPath)
        $row = $rows | Where-Object { [int]$_.HeadsetID -eq $headsetId } | Select-Object -First 1
        if ($row) {
            return @{
                minutes = [int]$row.Minutes
                seconds = [int]$row.Seconds
                mode    = [string]$row.Mode
            }
        }
    }
    return @{ minutes = 5; seconds = 0; mode = 'dec' }
}

function Set-TimerConfig {
    param(
        [int]$headsetId,
        [int]$minutes,
        [int]$seconds,
        [string]$mode
    )
    $csvPath = Get-TimerCsvPath
    $rows = @()
    if (Test-Path -LiteralPath $csvPath) {
        $rows = @(Import-Csv -LiteralPath $csvPath)
    }

    $found = $false
    foreach ($row in $rows) {
        if ([int]$row.HeadsetID -eq $headsetId) {
            $row.Minutes = $minutes
            $row.Seconds = $seconds
            $row.Mode    = $mode
            $found = $true
            break
        }
    }
    if (-not $found) {
        $rows += [PSCustomObject]@{
            HeadsetID = $headsetId
            Minutes   = $minutes
            Seconds   = $seconds
            Mode      = $mode
        }
    }
    $rows | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8 -Force
}

# Script block executed as a Start-Job child process.
# Uses only .NET File I/O and Start-Sleep - no module imports needed.
# Checks the run-token file on every tick: exits immediately if the token
# changed (a new timer started or Stop-HeadsetTimer was called).
$script:timerJobBlock = {
    param([string]$filePath, [string]$runFilePath, [string]$runToken, [int]$totalSecs, [string]$mode, [int]$startAt = 0)
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false

    function Test-StillOwner {
        try {
            $t = [System.IO.File]::ReadAllText($runFilePath).Trim()
            return ($t -eq $runToken)
        } catch { return $false }
    }

    if ($mode -eq 'inc') {
        # startAt = total seconds already elapsed before this segment (display offset)
        $end = $startAt + $totalSecs
        for ($i = $startAt; $i -le $end; $i++) {
            if (-not (Test-StillOwner)) { return }
            if ($i -eq $end) {
                [System.IO.File]::WriteAllText($filePath, "Time's up !", $utf8NoBom)
            } else {
                $m = [int][Math]::Floor($i / 60)
                $s = $i % 60
                [System.IO.File]::WriteAllText($filePath, ('{0:D2}:{1:D2}' -f $m, $s), $utf8NoBom)
                Start-Sleep -Seconds 1
            }
        }
    } else {
        for ($i = $totalSecs; $i -ge 0; $i--) {
            if (-not (Test-StillOwner)) { return }
            if ($i -eq 0) {
                [System.IO.File]::WriteAllText($filePath, "Time's up !", $utf8NoBom)
            } else {
                $m = [int][Math]::Floor($i / 60)
                $s = $i % 60
                [System.IO.File]::WriteAllText($filePath, ('{0:D2}:{1:D2}' -f $m, $s), $utf8NoBom)
                Start-Sleep -Seconds 1
            }
        }
    }
}

function Start-HeadsetTimer {
    param([int]$headsetId)

    # Stop any in-process job and clear the run token (kills orphaned jobs too)
    Stop-HeadsetTimer -headsetId $headsetId

    $config    = Get-TimerConfig -headsetId $headsetId
    $totalSecs = $config.minutes * 60 + $config.seconds
    if ($totalSecs -le 0) { $totalSecs = 1 }

    $filePath    = Get-TimerFilePath    -headsetId $headsetId
    $runFilePath = Get-TimerRunFilePath -headsetId $headsetId

    # Write a unique token so this job owns the file; orphaned jobs will exit on their next tick
    $runToken  = [System.Guid]::NewGuid().ToString('N')
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($runFilePath, $runToken, $utf8NoBom)

    # Write initial value immediately so the overlay shows at once
    if ($config.mode -eq 'inc') {
        [System.IO.File]::WriteAllText($filePath, '00:00', $utf8NoBom)
    } else {
        $initM = [int][Math]::Floor($totalSecs / 60)
        $initS = $totalSecs % 60
        [System.IO.File]::WriteAllText($filePath, ('{0:D2}:{1:D2}' -f $initM, $initS), $utf8NoBom)
    }

    $job = Start-Job -ScriptBlock $script:timerJobBlock -ArgumentList $filePath, $runFilePath, $runToken, $totalSecs, $config.mode, 0
    $script:activeTimers[$headsetId] = @{
        job             = $job
        filePath        = $filePath
        paused          = $false
        pausedRemaining = 0
        mode            = $config.mode
        startTime       = [DateTime]::UtcNow
        totalSecs       = $totalSecs
        elapsedBefore   = 0
    }
    Write-Log ($msg.TimerStarted -f $headsetId, $totalSecs, $config.mode) -Level INFO
}

function Suspend-HeadsetTimer {
    param([int]$headsetId)
    if (-not $script:activeTimers.ContainsKey($headsetId)) { return $false }
    $entry = $script:activeTimers[$headsetId]
    if ($entry.paused) { return $true }

    # Calculate remaining from stored start time to avoid a race with the background job's file writes.
    # The job uses WriteAllText (truncate + write) every second; reading the file at the same moment
    # can yield an empty string, which would reset pausedRemaining to 0 and corrupt the resume.
    $segmentElapsed  = [int]([DateTime]::UtcNow - $entry.startTime).TotalSeconds
    $elapsedBefore   = if ($entry.ContainsKey('elapsedBefore')) { $entry.elapsedBefore } else { 0 }
    $totalElapsed    = [Math]::Min($elapsedBefore + $segmentElapsed, $entry.totalSecs)
    $remainingSecs   = $entry.totalSecs - $totalElapsed

    # Stop the job but keep file value as-is (don't clear - user sees the frozen time)
    try { Stop-Job  -Job $entry.job -ErrorAction SilentlyContinue } catch {}
    try { Remove-Job -Job $entry.job -Force -ErrorAction SilentlyContinue } catch {}

    # Clear run token so any orphaned job stops; keep file value
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText((Get-TimerRunFilePath -headsetId $headsetId), '', $utf8NoBom)

    $entry.job             = $null
    $entry.paused          = $true
    $entry.pausedRemaining = $remainingSecs
    $entry.elapsedBefore   = $totalElapsed   # total elapsed at pause; used as inc display offset on resume
    $script:activeTimers[$headsetId] = $entry
    Write-Log ($msg.TimerStopped -f $headsetId) -Level INFO
    return $true
}

function Resume-HeadsetTimer {
    param([int]$headsetId)
    if (-not $script:activeTimers.ContainsKey($headsetId)) { return $false }
    $entry = $script:activeTimers[$headsetId]
    if (-not $entry.paused) { return $false }

    $remaining    = $entry.pausedRemaining
    $elapsedSoFar = if ($entry.ContainsKey('elapsedBefore')) { $entry.elapsedBefore } else { 0 }
    $originalTotal = $entry.totalSecs

    $filePath    = Get-TimerFilePath    -headsetId $headsetId
    $runFilePath = Get-TimerRunFilePath -headsetId $headsetId

    $runToken  = [System.Guid]::NewGuid().ToString('N')
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($runFilePath, $runToken, $utf8NoBom)

    $mode = $entry.mode
    if (-not $mode) { $mode = 'dec' }

    if ($mode -eq 'inc') {
        # For inc: job resumes counting from elapsedSoFar, for 'remaining' more seconds
        # Display offset = elapsedSoFar so the clock shows the correct elapsed time
        $startAt   = $elapsedSoFar
        $jobTotal  = if ($remaining -le 0) { 1 } else { $remaining }
        $shownM    = [int][Math]::Floor($elapsedSoFar / 60)
        $shownS    = $elapsedSoFar % 60
    } else {
        # For dec: job counts down from remaining to 0
        $startAt   = 0
        $jobTotal  = if ($remaining -le 0) { 1 } else { $remaining }
        $shownM    = [int][Math]::Floor($remaining / 60)
        $shownS    = $remaining % 60
    }

    # Write current display value immediately so overlay updates at once
    [System.IO.File]::WriteAllText($filePath, ('{0:D2}:{1:D2}' -f $shownM, $shownS), $utf8NoBom)

    $job = Start-Job -ScriptBlock $script:timerJobBlock -ArgumentList $filePath, $runFilePath, $runToken, $jobTotal, $mode, $startAt
    $script:activeTimers[$headsetId] = @{
        job             = $job
        filePath        = $filePath
        paused          = $false
        pausedRemaining = 0
        mode            = $mode
        startTime       = [DateTime]::UtcNow
        totalSecs       = $originalTotal
        elapsedBefore   = $elapsedSoFar
    }
    Write-Log ($msg.TimerStarted -f $headsetId, $jobTotal, $mode) -Level INFO
    return $true
}

function Stop-HeadsetTimer {
    param([int]$headsetId)
    if ($script:activeTimers.ContainsKey($headsetId)) {
        $entry = $script:activeTimers[$headsetId]
        try { Stop-Job  -Job $entry.job -ErrorAction SilentlyContinue } catch {}
        try { Remove-Job -Job $entry.job -Force -ErrorAction SilentlyContinue } catch {}
        $script:activeTimers.Remove($headsetId)
        Write-Log ($msg.TimerStopped -f $headsetId) -Level INFO
    }
    Clear-TimerFile -headsetId $headsetId
}

function Get-TimerStatus {
    param([int]$headsetId)
    $active = $false
    $paused = $false
    if ($script:activeTimers.ContainsKey($headsetId)) {
        $entry = $script:activeTimers[$headsetId]
        if ($entry.paused) {
            $paused = $true
        } elseif ($entry.job) {
            $state = $entry.job.State
            $active = ($state -eq 'Running' -or $state -eq 'NotStarted')
            if (-not $active) {
                try { Remove-Job -Job $entry.job -Force -ErrorAction SilentlyContinue } catch {}
                $script:activeTimers.Remove($headsetId)
            }
        }
    }

    $value = ''
    $filePath = Get-TimerFilePath -headsetId $headsetId
    if (Test-Path -LiteralPath $filePath) {
        $value = (Get-Content -LiteralPath $filePath -Raw -ErrorAction SilentlyContinue)
        if ($value) { $value = $value.Trim() }
    }

    $config = Get-TimerConfig -headsetId $headsetId
    return @{
        active  = $active
        paused  = $paused
        value   = if ($value) { $value } else { '' }
        minutes = $config.minutes
        seconds = $config.seconds
        mode    = $config.mode
    }
}
