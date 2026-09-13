#################
# HEADSET TOOLBOX SUPPORT
#
# The toolbox a technician runs on a DIFFERENT PC than this server is now ONE
# committed binary, website\headset-toolbox\VRHM-Headset-Toolbox.exe, served
# straight off the website folder. Nothing is generated for it at startup and
# there is no zip any more - the exe embeds its own program files and
# self-discovers this server (LAN scan confirmed via GET /api/version returning
# {"app":"VRHM",...}).
#
# What this module still owns is the ONE thing the toolbox cannot carry itself:
# adb. The exe deliberately does not embed adb.exe - it downloads it from this
# server on first use (GET /api/adb-tools), so it always runs the exact adb
# build this server manages its headsets with, and the binary stays small.
#
# The package below is that download: a zip of adb.exe + its two DLLs, taken
# from the live config.ADB.folder and rebuilt whenever the source adb is newer
# than the zip.
#################

function Get-AdbToolsPackagePath {
    <#
    .SYNOPSIS
    Path of the generated adb tools zip. It lives under website\generated\
    (excluded from releases and from git), and is streamed by
    GET /api/adb-tools rather than being linked directly.
    .EXAMPLE
    $zip = Get-AdbToolsPackagePath
    #>
    return (Join-Path $global:ScriptPath "website\generated\headset-toolbox\adb-tools.zip")
}


function New-AdbToolsPackage {
    <#
    .SYNOPSIS
    Builds (or refreshes) the adb tools zip the remote toolbox downloads:
    adb.exe, AdbWinApi.dll and AdbWinUsbApi.dll from this server's active ADB
    folder.

    .DESCRIPTION
    Lazy: an existing zip is reused unless -Force is passed or the source
    adb.exe is newer than it, so the common case - a technician downloading it -
    costs nothing. Never throws; a failure only costs the operator a download.

    Returns the zip path on success, $null on failure.

    .EXAMPLE
    $zip = New-AdbToolsPackage
    #>
    param(
        [string]$OutputPath = (Get-AdbToolsPackagePath),
        [switch]$Force
    )

    try {
        $adbExe = $global:adbPath
        if (-not $adbExe -or -not (Test-Path -LiteralPath $adbExe)) {
            Write-Log "New-AdbToolsPackage: adb.exe not found at '$adbExe' - cannot build the adb tools package." -Level WARNING
            return $null
        }

        $adbFolder = Split-Path -Parent $adbExe
        $sources   = @($adbExe)
        # The two DLLs are what make USB work on Windows; a missing one is not
        # fatal here (some builds ship without them), it just is not included.
        foreach ($dll in @('AdbWinApi.dll', 'AdbWinUsbApi.dll')) {
            $dllPath = Join-Path $adbFolder $dll
            if (Test-Path -LiteralPath $dllPath) {
                $sources += $dllPath
            } else {
                Write-Log "New-AdbToolsPackage: '$dll' missing from $adbFolder - not included." -Level WARNING
            }
        }

        if ((-not $Force) -and (Test-Path -LiteralPath $OutputPath)) {
            $zipTime = (Get-Item -LiteralPath $OutputPath).LastWriteTimeUtc
            $srcTime = (Get-Item -LiteralPath $adbExe).LastWriteTimeUtc
            if ($zipTime -ge $srcTime) { return $OutputPath }
        }

        $staging = Join-Path $env:TEMP ("vrhm_adb_tools_pkg_" + [guid]::NewGuid().ToString('N'))
        try {
            New-Item -ItemType Directory -Path $staging -Force -ErrorAction Stop | Out-Null
            foreach ($src in $sources) {
                Copy-Item -LiteralPath $src -Destination (Join-Path $staging (Split-Path -Leaf $src)) -Force -ErrorAction Stop
            }

            $outFolder = Split-Path -Parent $OutputPath
            if (-not (Test-Path -LiteralPath $outFolder)) {
                New-Item -ItemType Directory -Path $outFolder -Force -ErrorAction Stop | Out-Null
            }
            if (Test-Path -LiteralPath $OutputPath) {
                Remove-Item -LiteralPath $OutputPath -Force -ErrorAction Stop
            }

            Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
            [System.IO.Compression.ZipFile]::CreateFromDirectory($staging, $OutputPath)

            Write-Log "New-AdbToolsPackage: adb tools package rebuilt -> $OutputPath" -Level INFO
            return $OutputPath
        } finally {
            if (Test-Path -LiteralPath $staging) {
                Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    } catch {
        Write-Log "New-AdbToolsPackage: failed to build the adb tools package - $($_.Exception.Message)" -Level WARNING
        return $null
    }
}
