<#
    Build-HeadsetToolboxExe.ps1

    One-time (re-runnable) dev tool. Compiles HeadsetToolboxStub.cs into
    website\headset-toolbox\Start-HeadsetToolbox.exe, with the current
    website\headset-toolbox\Enable-HeadsetWifiAdb.ps1 PLUS adb.exe,
    AdbWinApi.dll and AdbWinUsbApi.dll (copied from the currently active ADB
    folder) embedded as manifest resources - so the exe is a single,
    standalone download with no companion files at all. It self-extracts all
    four into a headset-toolbox\ subfolder next to itself on first run, and
    shares its vrhm_server_cache.json with the other toolbox tools when run
    from inside VRHM-Headset-Toolbox.zip. The existing
    sources\graph_assets\VR_HEADSET_MANAGER.ico is embedded as its icon.

    Re-run this whenever HeadsetToolboxStub.cs, Enable-HeadsetWifiAdb.ps1, or
    the active ADB build changes, then commit the resulting .exe. Not
    dot-sourced by scripts_init.ps1 and not run automatically by the app -
    the .exe is a committed binary asset, same as adb.exe/scrcpy.exe/mediamtx.exe.

    Run manually from the project root:
        powershell -File scripts\headset-toolbox\Build-HeadsetToolboxExe.ps1
#>

$ErrorActionPreference = "Stop"

$projectRoot   = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$stubSourcePath = Join-Path $PSScriptRoot "HeadsetToolboxStub.cs"
$icoPath        = Join-Path $projectRoot "sources\graph_assets\VR_HEADSET_MANAGER.ico"
$scriptPath     = Join-Path $projectRoot "website\headset-toolbox\Enable-HeadsetWifiAdb.ps1"
$exeOutputPath  = Join-Path $projectRoot "website\headset-toolbox\Start-HeadsetToolbox.exe"

if (-not (Test-Path -LiteralPath $stubSourcePath)) {
    throw "Headset toolbox stub source not found: $stubSourcePath"
}
if (-not (Test-Path -LiteralPath $scriptPath)) {
    throw "Enable-HeadsetWifiAdb.ps1 not found to embed: $scriptPath"
}
if (-not (Test-Path -LiteralPath $icoPath)) {
    Write-Host "Icon not found at $icoPath - run scripts\Build-AppIcon.ps1 first. Compiling without an icon." -ForegroundColor Yellow
}

# ---- Locate the active ADB folder the same way the running app would
#      (config.json's ADB.folder - falls back to the template if config.json
#      does not exist yet on this dev machine) ----
$configPath = Join-Path $projectRoot "config\config.json"
if (-not (Test-Path -LiteralPath $configPath)) {
    $configPath = Join-Path $projectRoot "templates\config\config.json"
}
if (-not (Test-Path -LiteralPath $configPath)) {
    throw "Neither config\config.json nor templates\config\config.json found to read ADB.folder from."
}
$configJson = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
$adbRelFolder = $configJson.ADB.folder
if (-not $adbRelFolder) {
    throw "ADB.folder is not set in $configPath."
}
$adbFolder = Join-Path (Join-Path $projectRoot "sources") $adbRelFolder
if (-not (Test-Path -LiteralPath (Join-Path $adbFolder "adb.exe"))) {
    throw "adb.exe not found at $adbFolder (from ADB.folder='$adbRelFolder' in $configPath)."
}
Write-Host "Using adb.exe from: $adbFolder"

$adbExePath    = Join-Path $adbFolder "adb.exe"
$adbApiDll     = Join-Path $adbFolder "AdbWinApi.dll"
$adbUsbApiDll  = Join-Path $adbFolder "AdbWinUsbApi.dll"
foreach ($p in @($adbExePath, $adbApiDll, $adbUsbApiDll)) {
    if (-not (Test-Path -LiteralPath $p)) { throw "Required ADB file missing: $p" }
}

$cscCandidates = @(
    "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
    "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"
)
$csc = $cscCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $csc) {
    throw "csc.exe (C# compiler) not found. Expected under Microsoft.NET\Framework(64)\v4.0.30319."
}

Write-Host "Compiling headset toolbox stub with: $csc"
$cscArgs = @(
    "/nologo",
    "/target:exe"
)
if (Test-Path -LiteralPath $icoPath) {
    $cscArgs += "/win32icon:`"$icoPath`""
}
$cscArgs += "/resource:`"$scriptPath`",Enable-HeadsetWifiAdb.ps1"
$cscArgs += "/resource:`"$adbExePath`",adb.exe"
$cscArgs += "/resource:`"$adbApiDll`",AdbWinApi.dll"
$cscArgs += "/resource:`"$adbUsbApiDll`",AdbWinUsbApi.dll"
$cscArgs += "/out:`"$exeOutputPath`""
$cscArgs += "`"$stubSourcePath`""

$proc = Start-Process -FilePath $csc -ArgumentList $cscArgs -NoNewWindow -Wait -PassThru
if ($proc.ExitCode -ne 0) {
    throw "csc.exe compilation failed with exit code $($proc.ExitCode)"
}

Write-Host "Headset toolbox exe built: $exeOutputPath"
Write-Host "Remember to commit it to git."
