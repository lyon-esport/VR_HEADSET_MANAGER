##########################
### BASE FUNCTIONS    ####
##########################


function Write-Log {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [ValidateSet("DEBUG", "INFO", "SUCCESS", "WARNING", "ERROR", "NONE")]
        [string]$Level = "INFO"
    )

    # Color dictionary for the console
    $colors = @{
        "DEBUG"   = "DarkGray"
        "INFO"    = "Green"
        "SUCCESS" = @{ Background = "Magenta"; Foreground = "White" }
        "WARNING" = "Yellow"
        "ERROR"   = @{ Background = "Red"; Foreground = "White" }
    }
    
    # Get the current time in "yyyy-MM-dd HH:mm:ss" format
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "$timestamp [$Level] $Message"
    $consoleEntry = "[$Level] $Message"

    # List of log levels sorted by importance
    $logLevels = @("DEBUG", "INFO", "SUCCESS", "WARNING", "ERROR")
    
    # Check whether the log level allows console output
    if ($logLevels.IndexOf($Level) -ge $logLevels.IndexOf($global:debugLevelToConsole) -or $global:debugLevelToConsole -eq "DEBUG") {
        
        if ($colors[$Level].GetType().Name -eq "Hashtable") {
            # Display with colored background for errors/success
            Write-Host $consoleEntry -BackgroundColor $colors[$Level].Background -ForegroundColor $colors[$Level].Foreground
        } else {
            # Normal display for other log levels
            Write-Host $consoleEntry -ForegroundColor $colors[$Level]
        }
    }

    # Check whether the log level allows writing to file
    if ($logLevels.IndexOf($Level) -ge $logLevels.IndexOf($global:debugLevelToFile) -or $global:debugLevelToFile -eq "DEBUG") {
        try {
            $mtx = [System.Threading.Mutex]::new($false, 'Global\VRHMLog')
            $acq = $false
            try {
                $acq = $mtx.WaitOne(1000)
                $bytes = [System.Text.Encoding]::Default.GetBytes($logEntry + "`r`n")
                $fs = [System.IO.File]::Open(
                    $global:logFile,
                    [System.IO.FileMode]::Append,
                    [System.IO.FileAccess]::Write,
                    [System.IO.FileShare]::ReadWrite)
                try { $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Close() }
            } finally {
                if ($acq) { $mtx.ReleaseMutex() }
                $mtx.Dispose()
            }
        } catch {
            Write-Warning "Failed to write to the log file: $logEntry"
        }
    }

}


# 📌 **Usage examples:**
<#
Write-Log -Message "This is a debug message" -Level "DEBUG"
Write-Log -Message "Process completed successfully" -Level "INFO"
Write-Log -Message "Warning: A configuration item is missing" -Level "WARNING"
Write-Log -Message "Fatal error: Cannot continue" -Level "ERROR"
#>


function Remove-OldLogFiles {
    if (-not $global:logFolder -or -not (Test-Path -LiteralPath $global:logFolder)) { return }

    $retention = if ($global:logRetentionDays -and $global:logRetentionDays -gt 0) { [int]$global:logRetentionDays } else { 30 }
    $cutoff = (Get-Date).AddDays(-$retention)

    try {
        # Every file in the folder, not just log_*.txt: the folder is dedicated to logs
        # (one per COMPUTERNAME, no subfolders) and it also holds mediamtx_<date>.log,
        # webserver_<date>_out/_err.log, kiosk_<date>.log and the scrcpy/ffmpeg stderr
        # dumps - none of which were ever purged. Selection stays on LastWriteTime, so a
        # file a running process is still appending to is never touched.
        $files = Get-ChildItem -LiteralPath $global:logFolder -File -ErrorAction Stop
    } catch {
        Write-Log "Log retention: failed to list folder '$($global:logFolder)': $($_.Exception.Message)" -Level WARNING
        return
    }

    $deleted = 0
    foreach ($file in $files) {
        if ($global:logFile -and ($file.FullName -eq $global:logFile)) { continue }
        if ($file.LastWriteTime -ge $cutoff) { continue }
        try {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
            Write-Log "Deleted old log file: $($file.Name)" -Level INFO
            $deleted++
        } catch {
            Write-Log "Failed to delete log file '$($file.Name)': $($_.Exception.Message)" -Level WARNING
        }
    }

    if ($deleted -gt 0) {
        if ($global:msg -and $global:msg.LogRetentionPurged) {
            Write-Log ($global:msg.LogRetentionPurged -f $deleted, $retention) -Level SUCCESS
        } else {
            Write-Log "Deleted $deleted old log file(s) older than $retention days." -Level SUCCESS
        }
    }
}


# Log file families found in $global:logFolder, and how each one is labelled and decoded.
# Order drives the "Log type" dropdown in help.html and the console log picker.
# Encoding is per family: Write-Log and the scrcpy/ffmpeg redirections write ANSI
# (see Write-Log's [System.Text.Encoding]::Default), while mediamtx (Go), the web
# server child process and Write-KioskLog all write UTF-8.
$script:LogFamilies = @(
    @{ Order = 10; Type = 'main';      TypeLabel = 'Main program';  Encoding = 'ansi'; Pattern = '^log_(\d{4}-\d{2}-\d{2})\.txt$' }
    @{ Order = 20; Type = 'mediamtx';  TypeLabel = 'mediamtx';      Encoding = 'utf8'; Pattern = '^mediamtx(?:_(\d{4}-\d{2}-\d{2}))?\.log$' }
    @{ Order = 30; Type = 'webserver'; TypeLabel = 'Web server';    Encoding = 'utf8'; Pattern = '^webserver_(\d{4}-\d{2}-\d{2})_(out|err)\.log$' }
    @{ Order = 40; Type = 'scrcpy';    TypeLabel = 'scrcpy';        Encoding = 'ansi'; Pattern = '^(.+?)_(StandardOutput|StandardError)\.txt$' }
    @{ Order = 50; Type = 'ffmpeg';    TypeLabel = 'ffmpeg push';   Encoding = 'ansi'; Pattern = '^(.+?)_ffmpegPush_stderr\.txt$' }
    @{ Order = 60; Type = 'kiosk';     TypeLabel = 'Kiosk screens'; Encoding = 'utf8'; Pattern = '^kiosk_(\d{4}-\d{2}-\d{2})\.log$' }
)


function Get-LogSources {
    <#
    .SYNOPSIS
    Lists every log file in the log folder, classified by family (main program,
    mediamtx, web server, scrcpy, ffmpeg push, kiosk, other).

    .DESCRIPTION
    Single source of truth for "which logs exist and how do I read each one".
    Feeds the web UI's log-type / log-file dropdowns (/api/logs/sources) and the
    console picker in Show-SubMenu-FilesAndFolders, so both offer the same list.

    Returns [PSCustomObject[]] with Id (file name), Type, TypeLabel, Label,
    SizeBytes, LastWrite, Encoding, Order - sorted by family order, then newest
    file first inside each family, so "the first entry of a type" is always the
    one an operator wants by default.

    .EXAMPLE
    Get-LogSources | Where-Object { $_.Type -eq 'mediamtx' } | Select-Object -First 1
    #>
    param(
        [string]$Folder = $global:logFolder
    )

    if (-not $Folder -or -not (Test-Path -LiteralPath $Folder)) { return @() }
    try {
        $files = Get-ChildItem -LiteralPath $Folder -File -ErrorAction Stop
    } catch {
        return @()
    }

    $today  = Get-Date -Format 'yyyy-MM-dd'
    $result = New-Object System.Collections.Generic.List[object]

    foreach ($file in $files) {
        $name      = $file.Name
        $type      = 'other'
        $typeLabel = 'Other'
        $encoding  = 'ansi'
        $order     = 90
        $label     = $name

        foreach ($family in $script:LogFamilies) {
            if ($name -notmatch $family.Pattern) { continue }

            $type      = $family.Type
            $typeLabel = $family.TypeLabel
            $encoding  = $family.Encoding
            $order     = $family.Order

            switch ($type) {
                'webserver' {
                    $kind  = if ($matches[2] -eq 'err') { 'errors' } else { 'output' }
                    $label = "$($matches[1]) - $kind"
                }
                'scrcpy' {
                    # The prefix is Convert-Displayname's output (spaces -> underscores),
                    # so turn it back into the headset name the operator knows.
                    $kind  = if ($matches[2] -eq 'StandardError') { 'errors' } else { 'output' }
                    $label = "$($matches[1] -replace '_', ' ') - $kind"
                }
                'ffmpeg' {
                    $label = ($matches[1] -replace '_', ' ')
                }
                'mediamtx' {
                    # The undated file predates the date split - keep it selectable.
                    $label = if ($matches[1]) { $matches[1] } else { 'before date split' }
                }
                default {
                    $label = $matches[1]
                }
            }
            break
        }

        if ($label -eq $today) {
            $label = "$today (today)"
        } elseif ($label -like "$today - *") {
            $label = "$today (today)" + $label.Substring($today.Length)
        }

        $result.Add([PSCustomObject]@{
            Id        = $name
            Type      = $type
            TypeLabel = $typeLabel
            Label     = $label
            SizeBytes = $file.Length
            LastWrite = $file.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
            Encoding  = $encoding
            Order     = $order
        })
    }

    return @($result | Sort-Object @{ Expression = 'Order' }, @{ Expression = 'LastWrite'; Descending = $true })
}


function Get-LogTail {
    <#
    .SYNOPSIS
    Returns the last N lines of one log file in the log folder.

    .DESCRIPTION
    Reads BACKWARDS from the end of the file in 64 KB blocks and decodes only the
    tail. This matters: the log folder routinely holds files of hundreds of MB
    (mediamtx reached 780 MB before it was date-split), and loading a whole file
    into memory to slice its last 200 lines would stall the single-threaded web
    server request loop.

    Blocks are cut on 0x0A, which never occurs inside a multi-byte UTF-8 sequence,
    so a block boundary can never split a character.

    Opened with FileShare::ReadWrite so a log being actively written is readable.
    Returns @() for a missing/unreadable file - never throws.

    .EXAMPLE
    Get-LogTail -Name 'mediamtx_2026-09-10.log' -MaxLines 200 -Encoding utf8
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [int]$MaxLines = 200,
        [ValidateSet('ansi', 'utf8')]
        [string]$Encoding = 'ansi',
        [string]$Folder = $global:logFolder
    )

    if (-not $Folder) { return @() }
    if ($MaxLines -lt 1) { $MaxLines = 1 }

    # A log source id is a bare file name. Reject any directory part outright, then
    # confirm the resolved path really is inside the log folder (path-traversal guard,
    # the same helper the web server's file routes use).
    if ([System.IO.Path]::GetFileName($Name) -ne $Name) { return @() }
    $fullPath = Test-RequestPath -Path (Join-Path $Folder $Name) -Root $Folder
    if (-not $fullPath -or -not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { return @() }

    $encoder   = if ($Encoding -eq 'utf8') { [System.Text.Encoding]::UTF8 } else { [System.Text.Encoding]::Default }
    $blockSize = 65536

    try {
        $fs = [System.IO.File]::Open($fullPath, [System.IO.FileMode]::Open,
              [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    } catch {
        return @()
    }

    try {
        $position = $fs.Length
        if ($position -le 0) { return @() }

        $chunks    = New-Object System.Collections.Generic.List[byte[]]
        $totalRead = 0
        $newlines  = 0

        # One extra newline over MaxLines guarantees the first (possibly partial) line
        # can be dropped and still leave MaxLines complete ones.
        while ($position -gt 0 -and $newlines -le $MaxLines) {
            $size     = [int][Math]::Min([long]$blockSize, $position)
            $position = $position - $size
            $buffer   = New-Object byte[] $size
            $fs.Position = $position

            $filled = 0
            while ($filled -lt $size) {
                $read = $fs.Read($buffer, $filled, $size - $filled)
                if ($read -le 0) { break }
                $filled += $read
            }
            if ($filled -lt $size) { break }

            $chunks.Insert(0, $buffer)
            $totalRead += $size
            for ($i = 0; $i -lt $size; $i++) {
                if ($buffer[$i] -eq 10) { $newlines++ }
            }
        }

        if ($totalRead -le 0) { return @() }

        $bytes  = New-Object byte[] $totalRead
        $offset = 0
        foreach ($chunk in $chunks) {
            [Array]::Copy($chunk, 0, $bytes, $offset, $chunk.Length)
            $offset += $chunk.Length
        }

        # -split takes a regex, so '\r?\n' here is the regex, not PowerShell escapes.
        $lines = @($encoder.GetString($bytes) -split '\r?\n')

        # The first line is cut in half whenever we did not read from byte 0.
        if ($position -gt 0 -and $lines.Count -gt 1) {
            $lines = $lines[1..($lines.Count - 1)]
        }
        # A trailing newline yields one empty element - drop it, but keep blank lines
        # that are genuinely inside the log.
        if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') {
            if ($lines.Count -eq 1) { return @() }
            $lines = $lines[0..($lines.Count - 2)]
        }
        if ($lines.Count -gt $MaxLines) {
            $lines = $lines[($lines.Count - $MaxLines)..($lines.Count - 1)]
        }

        # Plain return: the caller wraps in @(), the project's standard read idiom.
        return $lines
    } catch {
        return @()
    } finally {
        $fs.Close()
    }
}
