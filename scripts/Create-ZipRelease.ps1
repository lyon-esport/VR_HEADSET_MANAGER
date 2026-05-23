#Requires -Version 5.1
<#
.SYNOPSIS
    Creates a clean release zip of VR_HEADSET_MANAGER without touching the source folder.

.NOTES
    Run this script from within the scripts\ folder of the project. It resolves
    the project root as its own parent directory and writes the zip one level above
    (alongside the project folder). Makes zero changes to the project folder.

.DESCRIPTION
    Scans the project folder and adds all files to a zip, excluding:
      - logs\, data\, scripts\
      - website\timer\, website\assets\app_icons\
      - Generated HTML overlays and monitor pages
      - config\config.json, config\mediamtx_headsets.yml, config backups
      - docs\ scratch/test files
      - CLAUDE.md, ToDo.txt, root *.json files, all dot-files/dot-folders
      - Unused sources subfolders (resolved from config.json)
    A synthetic version.txt is added to the zip root entry.

.PARAMETER Version
    Release version string (e.g. "1.2.3" or "26.05B"). Prompted if omitted.

.EXAMPLE
    .\Create-ZipRelease.ps1
    .\Create-ZipRelease.ps1 -Version "26.05B"
#>
param(
    [string]$Version = ""
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

# --- BUILD EXCLUSION RULES ---
# Read config.json to determine which sources subfolders to keep
$sourcesKeep = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
@("ADB Wireless activator", "powershell_Modules") | ForEach-Object { $sourcesKeep.Add($_) | Out-Null }
$configJsonPath = Join-Path $projectRoot "config\config.json"
if (Test-Path -LiteralPath $configJsonPath) {
    $cfg = Get-Content -LiteralPath $configJsonPath -Raw | ConvertFrom-Json
    if ($cfg.scrcpy.folder)                      { $sourcesKeep.Add(($cfg.scrcpy.folder   -split '[/\\]')[0]) | Out-Null }
    if ($cfg.ADB.folder)                         { $sourcesKeep.Add(($cfg.ADB.folder      -split '[/\\]')[0]) | Out-Null }
    if ($cfg.mediamtx -and $cfg.mediamtx.folder) { $sourcesKeep.Add(($cfg.mediamtx.folder -split '[/\\]')[0]) | Out-Null }
} else {
    Write-Host "  [Warning] config.json not found - using static sources keep-list only." -ForegroundColor Yellow
}

# Excluded directory absolute paths - any file under these is skipped
$excludedDirPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
@("logs", "data", "scripts", "website\timer", "website\assets\app_icons",
  ".git", ".github", ".claude", ".vscode") | ForEach-Object {
    $excludedDirPaths.Add((Join-Path $projectRoot $_)) | Out-Null
}
# Excluded sources subfolders (dynamic, resolved from config)
$sourcesDir = Join-Path $projectRoot "sources"
if (Test-Path -LiteralPath $sourcesDir) {
    foreach ($item in @(Get-ChildItem -LiteralPath $sourcesDir -Directory -ErrorAction SilentlyContinue)) {
        if (-not $sourcesKeep.Contains($item.Name)) {
            $excludedDirPaths.Add($item.FullName) | Out-Null
        }
    }
}

function Test-FileExcluded {
    param([System.IO.FileInfo]$File)
    $full = $File.FullName
    $rel  = $full.Substring($projectRoot.Length + 1)  # relative to project root, e.g. "website\monitor.html"
    $dir  = Split-Path $rel -Parent                    # parent segment, e.g. "website"
    $name = $File.Name

    # Excluded directory prefixes
    foreach ($excl in $excludedDirPaths) {
        if ($full.StartsWith($excl + '\') -or $full -eq $excl) { return $true }
    }

    # Root-level: dot-files (.gitignore etc.)
    if ($dir -eq '' -and $name -like '.*') { return $true }
    # Root-level: *.json scratch files
    if ($dir -eq '' -and $name -like '*.json') { return $true }
    # Root-level: named dev/AI files
    if ($rel -in @('CLAUDE.md', 'ToDo.txt')) { return $true }

    # sources\ root: only subfolders are kept; loose files at sources root are excluded
    if ($dir -eq 'sources') { return $true }

    # website\ generated files
    if ($dir -eq 'website') {
        if ($name.EndsWith('[monitoring].html') -or $name.EndsWith('[video].html')) { return $true }
        if ($name -eq 'monitor.html') { return $true }
    }

    # config\ generated/backup files
    if ($dir -eq 'config') {
        if ($name -in @('mediamtx_headsets.yml', 'config.json')) { return $true }
        if ($name -like '* - Copie*.json' -or $name -like '*_backup*.json') { return $true }
    }

    # docs\ scratch/test files
    if ($rel -in @('docs\test.ps1', 'docs\test_invoke_usb.ps1', 'docs\TODO_AI.txt', 'docs\fr-FR\test.psd1')) { return $true }

    return $false
}

# --- SCAN FILES ---
Write-Host "[ Scanning files ]" -ForegroundColor Gray
$allFiles = @(Get-ChildItem -LiteralPath $projectRoot -Recurse -File -Force -ErrorAction SilentlyContinue)
$included = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
$skipped  = 0
foreach ($f in $allFiles) {
    if (Test-FileExcluded -File $f) { $skipped++ } else { $included.Add($f) }
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

if ($Version -match 'TEST') {
    $extractDir = Join-Path $outputDir ([System.IO.Path]::GetFileNameWithoutExtension($zipName))
    Write-Host "[ TEST release detected - extracting to folder ]" -ForegroundColor Yellow
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
