<#
    Build-KioskChromeExe.ps1

    One-time (re-runnable) dev tool. Compiles KioskChromeStub.cs into
    website\kiosk-launcher\Start-Kiosk-BASIC.exe, with the current
    website\kiosk-launcher\Start-KioskChrome.ps1 embedded as a manifest
    resource (so the exe is a single, standalone download - it self-extracts
    that script next to itself on first run) and the existing
    sources\graph_assets\VR_HEADSET_MANAGER.ico embedded as its icon.

    Re-run this whenever KioskChromeStub.cs or Start-KioskChrome.ps1 changes,
    then commit the resulting .exe. Not dot-sourced by scripts_init.ps1 and
    not run automatically by the app - the .exe is a committed binary asset,
    same as adb.exe/scrcpy.exe/mediamtx.exe.

    Run manually from the project root:
        powershell -File scripts\kiosk-launcher\Build-KioskChromeExe.ps1
#>

$ErrorActionPreference = "Stop"

$projectRoot      = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$stubSourcePath   = Join-Path $PSScriptRoot "KioskChromeStub.cs"
$icoPath          = Join-Path $projectRoot "sources\graph_assets\VR_HEADSET_MANAGER.ico"
$chromeScriptPath = Join-Path $projectRoot "website\kiosk-launcher\Start-KioskChrome.ps1"
$exeOutputPath    = Join-Path $projectRoot "website\kiosk-launcher\Start-Kiosk-BASIC.exe"

if (-not (Test-Path -LiteralPath $stubSourcePath)) {
    throw "Kiosk chrome stub source not found: $stubSourcePath"
}
if (-not (Test-Path -LiteralPath $chromeScriptPath)) {
    throw "Start-KioskChrome.ps1 not found to embed: $chromeScriptPath"
}
if (-not (Test-Path -LiteralPath $icoPath)) {
    Write-Host "Icon not found at $icoPath - run scripts\Build-AppIcon.ps1 first. Compiling without an icon." -ForegroundColor Yellow
}

$cscCandidates = @(
    "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
    "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"
)
$csc = $cscCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $csc) {
    throw "csc.exe (C# compiler) not found. Expected under Microsoft.NET\Framework(64)\v4.0.30319."
}

Write-Host "Compiling kiosk chrome stub with: $csc"
$cscArgs = @(
    "/nologo",
    "/target:exe"
)
if (Test-Path -LiteralPath $icoPath) {
    $cscArgs += "/win32icon:`"$icoPath`""
}
$cscArgs += "/resource:`"$chromeScriptPath`",KioskChromeScript"
$cscArgs += "/out:`"$exeOutputPath`""
$cscArgs += "`"$stubSourcePath`""

$proc = Start-Process -FilePath $csc -ArgumentList $cscArgs -NoNewWindow -Wait -PassThru
if ($proc.ExitCode -ne 0) {
    throw "csc.exe compilation failed with exit code $($proc.ExitCode)"
}

Write-Host "Kiosk chrome exe built: $exeOutputPath"
Write-Host "Remember to commit it to git."
