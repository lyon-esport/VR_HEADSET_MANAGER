#Requires -Version 5.1
<#
.SYNOPSIS
    Creates a clean release zip of VR_HEADSET_MANAGER without touching the source folder.

.NOTES
    Run this script from within the scripts\ folder of the project. It resolves
    the project root as its own parent directory and writes the zip one level above
    (alongside the project folder). Makes zero changes to the project folder.

.DESCRIPTION
    Reads scripts\.releaseinclude to determine which files to bundle.
    The include file uses an inverted .gitignore syntax:
      - Lines without ! = include pattern
      - Lines with !    = exclude pattern (highest priority)
      - /folder/ or /folder/* = include all files under that folder recursively
      - * wildcard matches any characters except \ (no path separator crossing)
    A synthetic version.txt is added to the zip root entry.

.PARAMETER Version
    Release version string (e.g. "1.2.3" or "26.05B"). Prompted if omitted.

.PARAMETER Unzip
    Automatically extracts the created zip to a sibling folder after packaging, for testing the release.

.PARAMETER TestApp
    After packaging and extracting, runs scripts\Invoke-NonRegressionTests.ps1
    against the extracted release. Implies -Unzip. The harness exit code becomes
    this script's exit code (0 = all passed, 1 = failures, 2 = prerequisites).
    Requires an exclusive run: close the dev app first.

.EXAMPLE
    .\Create-ZipRelease.ps1
    .\Create-ZipRelease.ps1 -Version "26.05B"
    .\Create-ZipRelease.ps1 -Version "26.05B" -Unzip
    .\Create-ZipRelease.ps1 -Version "26.05B" -Unzip -TestApp
#>
param(
    [string]$Version = "",
    [switch]$Unzip,
    [switch]$TestApp
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

# --- LOCATE PROJECT ---
# Script lives in scripts\ so parent = project root
$projectRoot = Split-Path $PSScriptRoot -Parent
$folderName  = Split-Path $projectRoot -Leaf
$outputDir   = Split-Path $projectRoot -Parent   # one level above = DEV_VERSION\

Write-Host ""
Write-Host "=== VR HEADSET MANAGER - Create Zip Release ===" -ForegroundColor White
Write-Host "    Project : $projectRoot" -ForegroundColor DarkGray
Write-Host ""

# --- VERSION ---
while ($Version -notmatch '^[\d][\w.\-_]*$') {
    $Version = (Read-Host "  Enter release version (e.g. 1.2.3, 26.05B, 26.05-beta, 26.05_RC1)").Trim()
    if ($Version -notmatch '^[\d][\w.\-_]*$') {
        Write-Host "  Invalid format. Must start with a digit (e.g. 1.2.3, 26.05B, 26.05-beta, 26.05_RC1)." -ForegroundColor Red
    }
}
Write-Host "  Version : $Version" -ForegroundColor White
Write-Host ""

# --- ZIP PATH ---
$zipName = "$folderName.v$Version.zip"
$zipPath = Join-Path $outputDir $zipName
if (Test-Path -LiteralPath $zipPath) {
    Write-Host "  WARNING: $zipName already exists." -ForegroundColor Yellow
    $answer = (Read-Host "  Overwrite? [Y/N]").Trim().ToUpper()
    if ($answer -ne 'Y') { Write-Host "  Aborted." -ForegroundColor Red; exit 0 }
    Remove-Item -LiteralPath $zipPath -Force
}

# --- PARSE .releaseinclude ---
$releaseIncludePath = Join-Path $PSScriptRoot ".releaseinclude"
if (-not (Test-Path -LiteralPath $releaseIncludePath)) {
    Write-Host "  ERROR: .releaseinclude not found at: $releaseIncludePath" -ForegroundColor Red
    exit 1
}

function ConvertTo-PatternRegex {
    param([string]$Pattern)
    # Normalize separators to \
    $p = $Pattern.Replace('/', '\')
    # Strip leading \
    if ($p.StartsWith('\')) { $p = $p.Substring(1) }
    # Folder pattern: ends with \ or \* => match anything under that prefix
    if ($p.EndsWith('\') -or $p.EndsWith('\*')) {
        $prefix = $p.TrimEnd('*').TrimEnd('\')
        return '^' + [regex]::Escape($prefix) + '(\\.+|$)'
    }
    # File pattern: replace * wildcard (no path crossing)
    $escaped = [regex]::Escape($p)
    $regexStr = $escaped.Replace('\*', '[^\\]*').Replace('\?', '[^\\]')
    return '^' + $regexStr + '$'
}

$includeRegexes = [System.Collections.Generic.List[string]]::new()
$excludeRegexes = [System.Collections.Generic.List[string]]::new()

foreach ($rawLine in (Get-Content -LiteralPath $releaseIncludePath)) {
    $line = $rawLine.Trim()
    if ($line -eq '' -or $line.StartsWith('#')) { continue }
    if ($line.StartsWith('!')) {
        $excludeRegexes.Add((ConvertTo-PatternRegex -Pattern $line.Substring(1))) | Out-Null
    } else {
        $includeRegexes.Add((ConvertTo-PatternRegex -Pattern $line)) | Out-Null
    }
}

function Test-FileIncluded {
    param([System.IO.FileInfo]$File)
    $rel = $File.FullName.Substring($projectRoot.Length + 1)  # relative path from project root

    # Always exclude: scripts\ folder (the release tooling itself)
    if ($rel.StartsWith('scripts\') -or $rel -eq 'scripts') { return $false }

    # Always exclude: dot-files and dot-folders at root level
    $topSegment = ($rel -split '\\')[0]
    if ($topSegment.StartsWith('.')) { return $false }

    # Check include patterns
    $included = $false
    foreach ($rx in $includeRegexes) {
        if ($rel -match $rx) { $included = $true; break }
    }
    if (-not $included) { return $false }

    # Check exclude patterns (highest priority)
    foreach ($rx in $excludeRegexes) {
        if ($rel -match $rx) { return $false }
    }

    return $true
}

# --- SCAN FILES ---
Write-Host "[ Scanning files ]" -ForegroundColor Gray
$allFiles = @(Get-ChildItem -LiteralPath $projectRoot -Recurse -File -Force -ErrorAction SilentlyContinue)
$included = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
$skipped  = 0
foreach ($f in $allFiles) {
    if (Test-FileIncluded -File $f) { $included.Add($f) } else { $skipped++ }
}
Write-Host "  Including : $($included.Count) files" -ForegroundColor White
Write-Host "  Excluding : $skipped files" -ForegroundColor DarkGray
Write-Host ""

# --- CREATE ZIP ---
Write-Host "[ Creating zip: $zipName ]" -ForegroundColor Gray
$zip     = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
$counter = 0
try {
    foreach ($file in $included) {
        $rel       = $file.FullName.Substring($projectRoot.Length + 1)
        $entryName = "$folderName\$rel"
        $entry     = $zip.CreateEntry($entryName, [System.IO.Compression.CompressionLevel]::Optimal)
        $es = $entry.Open()
        $fs = [System.IO.File]::OpenRead($file.FullName)
        $fs.CopyTo($es)
        $fs.Dispose()
        $es.Dispose()
        $counter++
        if ($counter % 200 -eq 0) {
            Write-Host "  ... $counter / $($included.Count) files" -ForegroundColor DarkGray
        }
    }

    # Synthetic version.txt (not written to disk)
    $vEntry  = $zip.CreateEntry("$folderName\version.txt")
    $vStream = $vEntry.Open()
    $vBytes  = [System.Text.Encoding]::UTF8.GetBytes($Version)
    $vStream.Write($vBytes, 0, $vBytes.Length)
    $vStream.Dispose()

} finally {
    $zip.Dispose()
}

$zipSizeMB = [math]::Round((Get-Item -LiteralPath $zipPath).Length / 1MB, 1)
Write-Host ""
Write-Host "  $counter files + version.txt packed." -ForegroundColor White
Write-Host "  Output : $zipPath" -ForegroundColor White
Write-Host "  Size   : $zipSizeMB MB" -ForegroundColor White
Write-Host ""

$extractDir = ""
if ($Unzip -or $TestApp -or $Version -match 'TEST') {
    $extractDir = Join-Path $outputDir ([System.IO.Path]::GetFileNameWithoutExtension($zipName))
    Write-Host "[ Extracting release for testing ]" -ForegroundColor Yellow
    Write-Host "  $extractDir" -ForegroundColor White
    if (Test-Path -LiteralPath $extractDir) {
        Remove-Item -LiteralPath $extractDir -Recurse -Force
    }
    [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $extractDir)
    Write-Host "  Extracted." -ForegroundColor Green
    Write-Host ""
}

Write-Host "=== Zip release complete (v$Version). ===" -ForegroundColor Green
Write-Host ""

# --- OPTIONAL: NON-REGRESSION TESTS ---
if ($TestApp) {
    $harness = Join-Path $PSScriptRoot 'Invoke-NonRegressionTests.ps1'
    if (-not (Test-Path -LiteralPath $harness)) {
        Write-Host "ERROR: -TestApp requested but the harness is missing:" -ForegroundColor Red
        Write-Host "  $harness" -ForegroundColor DarkGray
        exit 2
    }

    Write-Host "[ Running non-regression tests against the extracted release ]" -ForegroundColor Yellow
    Write-Host ""

    if ($Host.Name -eq 'Windows PowerShell ISE') {
        # ISE's console pane is not a real Win32 console; a child process spawned via the call
        # operator inherits no usable console handle, so Read-Host in the harness would hang with
        # no way to type. Start-Process (without -NoNewWindow) always opens a real console window.
        Write-Host "  (Detected ISE - opening a separate console window so interactive prompts work.)" -ForegroundColor DarkGray
        $harnessArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$harness`" -TargetRoot `"$extractDir`" -Version `"$Version`""
        $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $harnessArgs -Wait -PassThru
        $testExit = $proc.ExitCode
    } else {
        # Child process, not dot-sourced: the harness sets its own strict-mode and
        # error preferences, and its exit code must survive back to the caller.
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $harness -TargetRoot $extractDir -Version $Version
        $testExit = $LASTEXITCODE
    }

    Write-Host ""
    if ($testExit -eq 0) {
        Write-Host "=== Non-regression tests PASSED for v$Version. ===" -ForegroundColor Green
    } elseif ($testExit -eq 1) {
        Write-Host "=== Non-regression tests FAILED for v$Version. ===" -ForegroundColor Red
    } else {
        Write-Host "=== Non-regression tests could not run (exit $testExit). ===" -ForegroundColor Red
    }
    Write-Host ""
    exit $testExit
}
