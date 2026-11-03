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

.PARAMETER UpdateType
    Major or Minor: written as "type" in release.json (self-update manifest, see .dev\update\spec.md S2).
    When omitted: a TEST version is written as major; any other version is prompted.

.PARAMETER Base
    Major release that started this update line (release.json "base"). Default: the version itself for a
    major, the line prefix (YYYY-MM.RCn, checked against `git tag`) for a minor.

.PARAMETER MinUpgradeFrom
    Oldest installed Release this package applies on (release.json "minUpgradeFrom").
    Default: empty for a major (any older release may reach it: a major is a new install with an import),
    the base for a minor.

.PARAMETER Breaking
    Short sentences shown to the operator before applying (release.json "breaking").

.PARAMETER NotesFile
    Text/markdown file whose content becomes release.json "notes" (UTF-8).

.NOTES
    release.json is written at the top folder of the zip and a copy with zipName/zipSha256/zipSize is
    written beside the zip as <zip name without .zip>.release.json.

.EXAMPLE
    .\Create-ZipRelease.ps1
    .\Create-ZipRelease.ps1 -Version "26.05B"
    .\Create-ZipRelease.ps1 -Version "26.05B" -Unzip
    .\Create-ZipRelease.ps1 -Version "26.05B" -Unzip -TestApp
    .\Create-ZipRelease.ps1 -Version "2026-11.RC1.2" -UpdateType Minor -Breaking "Restart needed" -NotesFile notes.md
#>
param(
    [string]$Version = "",
    [switch]$Unzip,
    [switch]$TestApp,
    [ValidateSet('Major', 'Minor')]
    [string]$UpdateType = "",
    [string]$Base = "",
    [string]$MinUpgradeFrom = "",
    [string[]]$Breaking = @(),
    [string]$NotesFile = ""
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

# --- UPDATE TYPE / BASE (release.json) ---
$isTestVersion = ($Version -match '(?i)\.TEST\d*$')
if (-not $UpdateType) {
    if ($isTestVersion) {
        $UpdateType = 'Major'
    } else {
        while ($UpdateType -notin @('Major', 'Minor')) {
            $UpdateType = (Read-Host "  Update type for release.json [Major/Minor]").Trim()
            if ($UpdateType -match '(?i)^maj') { $UpdateType = 'Major' }
            elseif ($UpdateType -match '(?i)^min') { $UpdateType = 'Minor' }
        }
    }
}
$versionCore = ($Version -replace '(?i)^v', '') -replace '(?i)\+dev\..*$', ''
if ($UpdateType -eq 'Major') {
    if (-not $Base)           { $Base = $versionCore }
    # A major is a new install with an import of the old folder: by default any older release may
    # reach it (empty = no limit in Get-AppUpdatePath). Pass -MinUpgradeFrom only when the importer
    # cannot read installs older than a given release.
} else {
    if (-not $Base) {
        # Line prefix YYYY-MM.RCn of the version; the previous release of that line is looked up with git tag.
        if ($versionCore -match '^(\d{4}-\d{2}\.RC\d+)') {
            $Base = $Matches[1]
        } else {
            Write-Host "  ERROR: cannot derive the base of a minor from '$Version'; pass -Base." -ForegroundColor Red
            exit 1
        }
        $baseTagFound = $false
        foreach ($tag in @(& git -C $projectRoot tag 2>$null)) {
            if (([string]$tag -replace '(?i)^v', '') -ieq $Base) { $baseTagFound = $true; break }
        }
        if (-not $baseTagFound) {
            Write-Host "  WARNING: no git tag found for base '$Base'; using it anyway." -ForegroundColor Yellow
        }
    }
    if (-not $MinUpgradeFrom) { $MinUpgradeFrom = $Base }
}
$releaseNotes = ""
if ($NotesFile) {
    if (-not (Test-Path -LiteralPath $NotesFile)) {
        Write-Host "  ERROR: NotesFile not found: $NotesFile" -ForegroundColor Red
        exit 1
    }
    $releaseNotes = (Get-Content -LiteralPath $NotesFile -Raw -Encoding UTF8).TrimEnd()
}
Write-Host "  Type    : $($UpdateType.ToLower())  base=$Base  minUpgradeFrom=$MinUpgradeFrom" -ForegroundColor White
Write-Host ""

# --- RESTAMP TOOLBOX EXE WITH THE RELEASE VERSION ---
# The committed website\headset-toolbox\VRHM-Headset-Toolbox.exe was built with whatever
# version.txt said at the time (DEVELOPPMENT-VERSION in the dev tree). Rebuild it here with the
# real release version so the shipped exe's file properties actually match what is being
# released. website\generated\ is already release-excluded, so the stamped copy never leaks into
# the zip on its own - it is only ever substituted in explicitly below.
$toolboxBuildScript = Join-Path $projectRoot "scripts\headset-toolbox\Build-VrhmToolboxExe.ps1"
$toolboxRelativePath = "website\headset-toolbox\VRHM-Headset-Toolbox.exe"
$stampedToolboxExePath = $null
if (Test-Path -LiteralPath $toolboxBuildScript) {
    $candidatePath = Join-Path $projectRoot "website\generated\headset-toolbox\VRHM-Headset-Toolbox.release.exe"
    Write-Host "[ Restamping toolbox exe with version $Version ]" -ForegroundColor Gray
    try {
        & $toolboxBuildScript -Version $Version -OutputPath $candidatePath
        if (Test-Path -LiteralPath $candidatePath) {
            $stampedToolboxExePath = $candidatePath
            Write-Host "  Stamped exe : $candidatePath" -ForegroundColor White
        } else {
            Write-Host "  WARNING: restamp produced no output file - shipping the committed exe as-is." -ForegroundColor Yellow
        }
    } catch {
        Write-Host "  WARNING: could not restamp the toolbox exe ($($_.Exception.Message)) - shipping the committed exe as-is." -ForegroundColor Yellow
    }
} else {
    Write-Host "  WARNING: $toolboxBuildScript not found - shipping the committed toolbox exe as-is." -ForegroundColor Yellow
}
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
# The matcher lives in modules\release_include.ps1 so the update code uses the SAME rules.
$releaseIncludeModule = Join-Path $projectRoot "modules\release_include.ps1"
if (-not (Test-Path -LiteralPath $releaseIncludeModule)) {
    Write-Host "  ERROR: release_include.ps1 not found at: $releaseIncludeModule" -ForegroundColor Red
    exit 1
}
. $releaseIncludeModule

$releaseIncludePath = Join-Path $PSScriptRoot ".releaseinclude"
if (-not (Test-Path -LiteralPath $releaseIncludePath)) {
    Write-Host "  ERROR: .releaseinclude not found at: $releaseIncludePath" -ForegroundColor Red
    exit 1
}
$releaseRules = Read-ReleaseIncludeRules -Text (Get-Content -LiteralPath $releaseIncludePath -Raw -Encoding UTF8)

function Test-FileIncluded {
    param([System.IO.FileInfo]$File)
    $rel = $File.FullName.Substring($projectRoot.Length + 1)  # relative path from project root
    return (Test-ReleaseIncludePath -Path $rel -Rules $releaseRules)
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

# --- MANIFEST HELPERS (release.json) ---
$utf8NoBom     = New-Object System.Text.UTF8Encoding($false)
$manifestFiles = [System.Collections.Generic.List[object]]::new()

function Get-BytesSha256Hex {
    param([byte[]]$Bytes)
    $s = [System.Security.Cryptography.SHA256]::Create()
    try { return (($s.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') }) -join '') } finally { $s.Dispose() }
}

# Highest NNN of modules\db\schema\NNN_*.sql
$dbSchemaMax = 0
foreach ($sf in @(Get-ChildItem -LiteralPath (Join-Path $projectRoot 'modules\db\schema') -Filter '*.sql' -File -ErrorAction SilentlyContinue)) {
    if ($sf.Name -match '^(\d+)_') { $nn = [int]$Matches[1]; if ($nn -gt $dbSchemaMax) { $dbSchemaMax = $nn } }
}

# Git state: HEAD and whether uncommitted changes touch the release set
$gitCommit = ''
$gitDirty  = $false
try {
    $gitCommit = ([string](& git -C $projectRoot rev-parse HEAD 2>$null)).Trim()
    if ($gitCommit -notmatch '^[0-9a-f]{40}$') { $gitCommit = '' }
    $relSet = @($included | ForEach-Object { $_.FullName.Substring($projectRoot.Length + 1).Replace('\', '/') })
    foreach ($pl in @(& git -c core.quotepath=off -C $projectRoot status --porcelain 2>$null)) {
        $p = ([string]$pl)
        if ($p.Length -lt 4) { continue }
        $p = $p.Substring(3)
        if ($p -match ' -> ') { $p = ($p -split ' -> ')[-1] }
        $p = $p.Trim('"')
        $hit = $false
        foreach ($r in $relSet) {
            if ($r -eq $p -or ($p.EndsWith('/') -and $r.StartsWith($p))) { $hit = $true; break }
        }
        # a removed/renamed-away tracked file that would have been shipped also counts
        if (-not $hit -and (Test-ReleaseIncludePath -Path $p -Rules $releaseRules)) { $hit = $true }
        if ($hit) { $gitDirty = $true; break }
    }
} catch {
    Write-Host "  WARNING: git state unavailable ($($_.Exception.Message))" -ForegroundColor Yellow
}

function New-ReleaseManifestObject {
    return [ordered]@{
        schema         = 1
        app            = 'VRHM'
        version        = $Version
        type           = $UpdateType.ToLower()
        base           = $Base
        minUpgradeFrom = $MinUpgradeFrom
        dbSchema       = $dbSchemaMax
        commit         = $gitCommit
        dirty          = $gitDirty
        createdAt      = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        breaking       = @($Breaking)
        notes          = $releaseNotes
        files          = @($manifestFiles | Sort-Object path)
    }
}

# --- CREATE ZIP ---
Write-Host "[ Creating zip: $zipName ]" -ForegroundColor Gray
$zip     = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
$counter = 0
try {
    foreach ($file in $included) {
        $rel       = $file.FullName.Substring($projectRoot.Length + 1)
        $entryName = "$folderName\$rel"
        $entry     = $zip.CreateEntry($entryName, [System.IO.Compression.CompressionLevel]::Optimal)
        # The toolbox exe gets the release-stamped copy when the restamp above succeeded, so the
        # shipped binary's file properties match this release's version. Everything else - and
        # the toolbox exe itself when restamping was unavailable - is read straight off disk.
        $sourcePath = if ($rel -eq $toolboxRelativePath -and $stampedToolboxExePath) {
            $stampedToolboxExePath
        } else {
            $file.FullName
        }
        # Copy while hashing the exact bytes that go into the zip (release.json files[]).
        $es   = $entry.Open()
        $fs   = [System.IO.File]::OpenRead($sourcePath)
        $sha  = [System.Security.Cryptography.SHA256]::Create()
        $size = [long]0
        $buf  = New-Object byte[] 262144
        while (($n = $fs.Read($buf, 0, $buf.Length)) -gt 0) {
            $es.Write($buf, 0, $n)
            [void]$sha.TransformBlock($buf, 0, $n, $null, 0)
            $size += $n
        }
        [void]$sha.TransformFinalBlock($buf, 0, 0)
        $manifestFiles.Add([pscustomobject][ordered]@{
            path   = $rel.Replace('\', '/')
            sha256 = (($sha.Hash | ForEach-Object { $_.ToString('x2') }) -join '')
            size   = $size
        })
        $sha.Dispose()
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
    $manifestFiles.Add([pscustomobject][ordered]@{
        path   = 'version.txt'
        sha256 = Get-BytesSha256Hex -Bytes $vBytes
        size   = [long]$vBytes.Length
    })

    # release.json (self-update manifest, spec S2) - lists every file above except itself
    $manifest = New-ReleaseManifestObject
    $manifestBytes = $utf8NoBom.GetBytes((ConvertTo-Json -InputObject $manifest -Depth 6))
    $mEntry  = $zip.CreateEntry("$folderName\release.json")
    $mStream = $mEntry.Open()
    $mStream.Write($manifestBytes, 0, $manifestBytes.Length)
    $mStream.Dispose()

} finally {
    $zip.Dispose()
}

# Copy of the manifest beside the zip, with the zip identity (release asset)
$zipInfo = Get-Item -LiteralPath $zipPath
$manifest['zipName']   = $zipName
$manifest['zipSha256'] = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLower()
$manifest['zipSize']   = [long]$zipInfo.Length
$assetPath = Join-Path $outputDir ([System.IO.Path]::GetFileNameWithoutExtension($zipName) + '.release.json')
[System.IO.File]::WriteAllBytes($assetPath, $utf8NoBom.GetBytes((ConvertTo-Json -InputObject $manifest -Depth 6)))
Write-Host "  Manifest : $assetPath" -ForegroundColor White

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
