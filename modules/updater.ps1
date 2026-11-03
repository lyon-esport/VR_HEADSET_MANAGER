#Requires -Version 5.1
<#
.SYNOPSIS
    VRHM in-place updater (ADR-0041, .dev\update\spec.md S8). STANDALONE: never dot-sourced, no module
    dependency, excluded from the module glob in scripts_init.ps1 (like reaper.ps1).

.DESCRIPTION
    Runs as its own process, from a COPY in data\update\updater.ps1 (so it never replaces itself).
    Reads data\update\job.json and walks the phases:
      waiting -> backup -> copy -> relaunched -> healthy
    On a failure after files were touched, or when the new version does not write
    data\update\started.ok (containing the job id) within healthTimeoutSec: rollback
    (restore the backup, remove added files, relaunch the old version) -> rolledback | failed.
    A failure before any change: aborted (old version relaunched).
    Every phase is written to job.json and state.json BEFORE acting. Log:
    logs\<COMPUTERNAME>\update_<yyyy-MM-dd>.log (UTF-8 no BOM).

.PARAMETER JobFile
    Full path of data\update\job.json.

.PARAMETER NoRelaunch
    Test switch: do everything but start main.ps1 (health is then judged on started.ok written by
    the test itself within the timeout).

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File data\update\updater.ps1 -JobFile data\update\job.json
#>
param(
    [Parameter(Mandatory = $true)][string]$JobFile,
    [switch]$NoRelaunch
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:LogFile   = $null

# Paths that the updater never copies over, never deletes and never backs up (spec S8).
$script:ProtectedPrefixes = @('data/', 'config/', 'logs/', 'website/generated/', 'website/timer/',
    'website/assets/app_icons/', '.git/', '.dev/', 'scripts/')

function Write-UpdaterLog {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] [updater PID {2}] {3}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Level, $PID, $Message
    try { Write-Host $line } catch { }
    if ($script:LogFile) {
        try { [System.IO.File]::AppendAllText($script:LogFile, $line + [Environment]::NewLine, $script:Utf8NoBom) } catch { }
    }
}

function Test-UpdaterProtectedPath {
    param([string]$RelPath)
    $p = ($RelPath -replace '\\', '/').TrimStart('/').ToLowerInvariant()
    if (-not $p -or $p.Contains('..')) { return $true }
    foreach ($pre in $script:ProtectedPrefixes) { if ($p.StartsWith($pre)) { return $true } }
    if ($p -like 'sources/ffmpeg*') { return $true }
    if ($p -match '^website/[^/]*\[[^/]*\]\.html$') { return $true }
    if ($p -eq 'website/monitor.html') { return $true }
    return $false
}

function Write-UpdaterJson {
    param([string]$Path, $Object)
    $json = $Object | ConvertTo-Json -Depth 12
    $tmp = $Path + '.tmp'
    [System.IO.File]::WriteAllText($tmp, $json, $script:Utf8NoBom)
    if (Test-Path -LiteralPath $Path) { [System.IO.File]::Replace($tmp, $Path, [NullString]::Value) }
    else { [System.IO.File]::Move($tmp, $Path) }
}

function Set-UpdaterPhase {
    param([string]$Phase, [string]$Message = '')
    $script:Job.phase = $Phase
    $script:Job | Add-Member -NotePropertyName phaseAt -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('o')) -Force
    try { Write-UpdaterJson -Path $JobFile -Object $script:Job } catch { Write-UpdaterLog ("cannot write job.json: " + $_.Exception.Message) 'WARNING' }
    $state = [ordered]@{
        jobId       = $script:Job.jobId
        mode        = $script:Job.mode
        phase       = $Phase
        fromVersion = $script:Job.fromVersion
        toVersion   = $script:Job.toVersion
        at          = (Get-Date).ToUniversalTime().ToString('o')
        message     = $Message
        backup      = $script:BackupPath
        log         = $script:LogFile
    }
    try { Write-UpdaterJson -Path $script:StatePath -Object $state } catch { Write-UpdaterLog ("cannot write state.json: " + $_.Exception.Message) 'WARNING' }
    Write-UpdaterLog ("phase {0} {1}" -f $Phase, $Message)
}

function Get-RootProcesses {
    # Processes belonging to THIS install (not this updater): powershell whose command line names a
    # file under the root, and any exe whose path is under the root (adb, scrcpy, mediamtx, ffmpeg).
    $root = $script:Root.TrimEnd('\') + '\'
    $list = @()
    try {
        $all = @(Get-CimInstance Win32_Process -ErrorAction Stop)
    } catch { return @() }
    foreach ($p in $all) {
        if ([int]$p.ProcessId -eq $PID) { continue }
        $exe = [string]$p.ExecutablePath
        $cl  = [string]$p.CommandLine
        $mine = $false
        if ($exe -and $exe.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { $mine = $true }
        elseif ($p.Name -in @('powershell.exe', 'pwsh.exe') -and $cl -and
                $cl.IndexOf('updater.ps1', [StringComparison]::OrdinalIgnoreCase) -lt 0) {
            # Only a script FILE of this install (-File "<root>\main.ps1", web_server.ps1, reaper.ps1...),
            # never a shell that merely mentions the folder.
            $m = [regex]::Match($cl, '(?i)-File\s+"?([^"]+?\.ps1)"?(\s|$)')
            if ($m.Success -and $m.Groups[1].Value.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { $mine = $true }
        }
        if ($mine) { $list += $p }
    }
    return $list
}

function Wait-RootProcessesExit {
    param([int]$TimeoutSec = 120)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $left = @(Get-RootProcesses)
        if ($left.Count -eq 0) { return $true }
        Start-Sleep -Milliseconds 500
    }
    $left = @(Get-RootProcesses)
    foreach ($p in $left) {
        Write-UpdaterLog ("still running after {0} s, killing PID {1} {2}" -f $TimeoutSec, $p.ProcessId, $p.Name) 'WARNING'
        try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop } catch { }
    }
    Start-Sleep -Seconds 2
    return (@(Get-RootProcesses).Count -eq 0)
}

function Stop-NewMainTree {
    # Rollback: stop the new main.ps1 of this root (the reaper it spawned then kills mediamtx, the
    # web server and scrcpy); then whatever is still alive under the root.
    foreach ($p in @(Get-RootProcesses)) {
        if ($p.Name -in @('powershell.exe', 'pwsh.exe') -and ([string]$p.CommandLine) -match 'main\.ps1') {
            Write-UpdaterLog ("rollback: stopping new main.ps1 PID {0}" -f $p.ProcessId) 'WARNING'
            try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop } catch { }
        }
    }
    Start-Sleep -Seconds 5
    Wait-RootProcessesExit -TimeoutSec 20 | Out-Null
}

function Copy-WithRetry {
    param([string]$Source, [string]$Target)
    $dir = Split-Path -Path $Target -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    for ($i = 1; $i -le 5; $i++) {
        try { [System.IO.File]::Copy($Source, $Target, $true); return }
        catch {
            if ($i -eq 5) { throw }
            Start-Sleep -Milliseconds 500
        }
    }
}

function Remove-WithRetry {
    param([string]$Target)
    for ($i = 1; $i -le 5; $i++) {
        try { if (Test-Path -LiteralPath $Target) { [System.IO.File]::Delete($Target) }; return }
        catch {
            if ($i -eq 5) { throw }
            Start-Sleep -Milliseconds 500
        }
    }
}

function Remove-EmptyParents {
    param([string]$RelPath)
    $dir = Split-Path -Path (Join-Path $script:Root $RelPath) -Parent
    $rootFull = $script:Root.TrimEnd('\')
    while ($dir -and $dir.Length -gt $rootFull.Length -and $dir.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
        $rel = $dir.Substring($rootFull.Length + 1)
        if (Test-UpdaterProtectedPath -RelPath ($rel + '/')) { break }
        try {
            if ((Test-Path -LiteralPath $dir) -and -not (Get-ChildItem -LiteralPath $dir -Force | Select-Object -First 1)) {
                Remove-Item -LiteralPath $dir -Force
            } else { break }
        } catch { break }
        $dir = Split-Path -Path $dir -Parent
    }
}

function Start-MainScript {
    param([string]$Reason)
    if ($NoRelaunch) { Write-UpdaterLog ("NoRelaunch: not starting main.ps1 ({0})" -f $Reason); return }
    $mainScript = Join-Path $script:Root 'main.ps1'
    Write-UpdaterLog ("starting {0} ({1})" -f $mainScript, $Reason)
    # Same launch as the console '00' restart: its own console, not a child of this updater.
    Start-Process cmd.exe -ArgumentList @(
        '/c', 'start', '"VR HEADSET MANAGER"',
        'powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $mainScript)
    ) -WindowStyle Hidden
}

function Invoke-Rollback {
    param([string]$Why)
    Write-UpdaterLog ("ROLLBACK: {0}" -f $Why) 'ERROR'
    Set-UpdaterPhase -Phase 'rollback' -Message $Why
    $ok = $true
    try {
        Stop-NewMainTree
        # Remove files the update ADDED (they did not exist before).
        foreach ($rel in @($script:Added)) {
            try { Remove-WithRetry -Target (Join-Path $script:Root $rel); Remove-EmptyParents -RelPath $rel }
            catch { $ok = $false; Write-UpdaterLog ("rollback: cannot remove added {0}: {1}" -f $rel, $_.Exception.Message) 'ERROR' }
        }
        # Restore every file from the backup.
        if ($script:BackupPath -and (Test-Path -LiteralPath $script:BackupPath)) {
            $zip = [System.IO.Compression.ZipFile]::OpenRead($script:BackupPath)
            try {
                foreach ($e in $zip.Entries) {
                    if (-not $e.Name) { continue }
                    $target = Join-Path $script:Root ($e.FullName -replace '/', '\')
                    try {
                        $dir = Split-Path -Path $target -Parent
                        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
                        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, $target, $true)
                    } catch { $ok = $false; Write-UpdaterLog ("rollback: cannot restore {0}: {1}" -f $e.FullName, $_.Exception.Message) 'ERROR' }
                }
            } finally { $zip.Dispose() }
        }
    } catch { $ok = $false; Write-UpdaterLog ("rollback error: " + $_.Exception.Message) 'ERROR' }
    try { Remove-WithRetry -Target $script:StartedOk } catch { }
    if ($ok) { Set-UpdaterPhase -Phase 'rolledback' -Message $Why }
    else { Set-UpdaterPhase -Phase 'failed' -Message ("rollback incomplete, backup: {0}. Cause: {1}" -f $script:BackupPath, $Why) }
    try { Start-MainScript -Reason 'previous version after rollback' } catch { Write-UpdaterLog ("cannot relaunch: " + $_.Exception.Message) 'ERROR' }
}

# ------------------------------------------------------------------ main
try {
    $script:Job = (Get-Content -LiteralPath $JobFile -Raw -Encoding UTF8).TrimStart([char]0xFEFF) | ConvertFrom-Json
} catch {
    Write-Host ("updater: cannot read job file {0}: {1}" -f $JobFile, $_.Exception.Message)
    exit 2
}
$script:Root       = [string]$script:Job.installRoot
$script:UpdateDir  = Split-Path -Path $JobFile -Parent
$script:StatePath  = Join-Path $script:UpdateDir 'state.json'
$script:StartedOk  = Join-Path $script:UpdateDir 'started.ok'
$script:BackupPath = $null
$script:Added      = @()
try {
    $logDir = Join-Path (Join-Path $script:Root 'logs') $env:COMPUTERNAME
    if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $script:LogFile = Join-Path $logDir ('update_{0}.log' -f (Get-Date -Format 'yyyy-MM-dd'))
} catch { }

Write-UpdaterLog ("job {0}: {1} {2} -> {3}, {4} to copy, {5} to delete" -f $script:Job.jobId, $script:Job.mode,
    $script:Job.fromVersion, $script:Job.toVersion, @($script:Job.copy).Count, @($script:Job.delete).Count)

if ([string]$script:Job.mode -eq 'major') {
    Write-UpdaterLog 'job mode is major (new folder): not an in-place job, nothing to do' 'WARNING'
    exit 0
}
if ([string]$script:Job.phase -notin @('staged', 'launching')) {
    Write-UpdaterLog ("job phase is '{0}', nothing to do" -f $script:Job.phase) 'WARNING'
    exit 0
}
if (-not $script:Root -or -not (Test-Path -LiteralPath (Join-Path $script:Root 'main.ps1'))) {
    Write-UpdaterLog ("install root invalid: {0}" -f $script:Root) 'ERROR'
    exit 2
}
$stageRoot = [string]$script:Job.stageRoot
$copyList   = @(@($script:Job.copy)   | Where-Object { $_ -and -not (Test-UpdaterProtectedPath -RelPath $_) })
$deleteList = @(@($script:Job.delete) | Where-Object { $_ -and -not (Test-UpdaterProtectedPath -RelPath $_) })

# 1. waiting ----------------------------------------------------------------
try {
    Set-UpdaterPhase -Phase 'waiting'
    if (-not (Wait-RootProcessesExit -TimeoutSec 120)) { throw 'processes of this install are still running' }
    foreach ($rel in $copyList) {
        if (-not (Test-Path -LiteralPath (Join-Path $stageRoot $rel))) { throw ("staged file missing: {0}" -f $rel) }
    }
} catch {
    Set-UpdaterPhase -Phase 'aborted' -Message $_.Exception.Message
    Start-MainScript -Reason 'update aborted before any change'
    exit 1
}

# 2. backup -----------------------------------------------------------------
try {
    Set-UpdaterPhase -Phase 'backup'
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $safeFrom = ([string]$script:Job.fromVersion) -replace '[^\w.\-]', '_'
    $script:BackupPath = Join-Path $script:UpdateDir ('backup_{0}_{1}.zip' -f $safeFrom, $stamp)
    $zip = [System.IO.Compression.ZipFile]::Open($script:BackupPath, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($rel in @($copyList + $deleteList + @('version.txt') | Select-Object -Unique)) {
            $src = Join-Path $script:Root $rel
            if (Test-Path -LiteralPath $src -PathType Leaf) {
                [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $src, ($rel -replace '\\', '/'))
            } elseif ($copyList -contains $rel) { $script:Added += $rel }
        }
    } finally { $zip.Dispose() }
    # Keep the 3 newest backups.
    Get-ChildItem -LiteralPath $script:UpdateDir -Filter 'backup_*.zip' -File | Sort-Object LastWriteTime -Descending |
        Select-Object -Skip 3 | ForEach-Object { try { Remove-Item -LiteralPath $_.FullName -Force } catch { } }
    Write-UpdaterLog ("backup {0} ({1} new files)" -f $script:BackupPath, $script:Added.Count)
} catch {
    Set-UpdaterPhase -Phase 'aborted' -Message ("backup failed: " + $_.Exception.Message)
    Start-MainScript -Reason 'update aborted before any change'
    exit 1
}

# 3. copy -------------------------------------------------------------------
try {
    Set-UpdaterPhase -Phase 'copy'
    foreach ($rel in $copyList) { Copy-WithRetry -Source (Join-Path $stageRoot $rel) -Target (Join-Path $script:Root $rel) }
    foreach ($rel in $deleteList) { Remove-WithRetry -Target (Join-Path $script:Root $rel); Remove-EmptyParents -RelPath $rel }
    if ($script:Job.PSObject.Properties['versionText'] -and $script:Job.versionText) {
        [System.IO.File]::WriteAllText((Join-Path $script:Root 'version.txt'), [string]$script:Job.versionText, $script:Utf8NoBom)
    }
} catch {
    Invoke-Rollback -Why ("copy failed: " + $_.Exception.Message)
    exit 1
}

# 4. relaunched + health check ----------------------------------------------
try {
    try { Remove-WithRetry -Target $script:StartedOk } catch { }
    Set-UpdaterPhase -Phase 'relaunched'
    Start-MainScript -Reason ("new version {0}" -f $script:Job.toVersion)
    $timeout = 300
    if ($script:Job.PSObject.Properties['healthTimeoutSec'] -and [int]$script:Job.healthTimeoutSec -ge 30) { $timeout = [int]$script:Job.healthTimeoutSec }
    $deadline = (Get-Date).AddSeconds($timeout)
    $healthy = $false
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $script:StartedOk) {
            $txt = ''
            try { $txt = ([System.IO.File]::ReadAllText($script:StartedOk)).Trim() } catch { }
            if ($txt -eq [string]$script:Job.jobId) { $healthy = $true; break }
        }
        Start-Sleep -Seconds 1
    }
    if (-not $healthy) { throw ("the new version did not start within {0} s" -f $timeout) }
} catch {
    Invoke-Rollback -Why $_.Exception.Message
    exit 1
}

# 5. healthy ----------------------------------------------------------------
try {
    if ($script:Job.PSObject.Properties['manifest'] -and $script:Job.manifest) {
        Write-UpdaterJson -Path (Join-Path $script:UpdateDir 'installed.json') -Object $script:Job.manifest
    }
} catch { Write-UpdaterLog ("cannot write installed.json: " + $_.Exception.Message) 'WARNING' }
Set-UpdaterPhase -Phase 'healthy' -Message ("now running {0}" -f $script:Job.toVersion)
try {
    if ($stageRoot -and (Test-Path -LiteralPath $stageRoot) -and $stageRoot.StartsWith($script:UpdateDir, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $stageRoot -Recurse -Force
    }
} catch { Write-UpdaterLog ("cannot remove stage folder: " + $_.Exception.Message) 'WARNING' }
try { Remove-WithRetry -Target $JobFile } catch { }
Write-UpdaterLog 'done'
exit 0
