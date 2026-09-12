#################
# HEADSET TOOLBOX PACKAGE
#
# Builds a downloadable zip a technician runs on a DIFFERENT PC than this
# server, bundling 3 self-contained, portable .exe tools:
#   Start-HeadsetToolbox.exe  - enables WiFi ADB on a USB-connected headset,
#                               then registers it with this server via
#                               POST /api/headsets/register-by-serial
#   Start-Kiosk-Agent.exe     - kiosk screen launcher/agent
#   Find-VRHM-Server.exe      - standalone LAN scanner / cache-populator
#
# No server address or IP is ever baked into the zip: each exe embeds its own
# script (and, for the headset tool, adb.exe + its DLLs) as resources and
# self-extracts them into its own subfolder on first run, then self-discovers
# the VRHM server (LAN scan, confirmed via GET /api/version returning
# {"app":"VRHM",...}) and remembers it in a single vrhm_server_cache.json
# shared by all 3 tools at the root of the extracted folder. This makes the
# zip fully portable - it works unmodified on any VRHM installation and
# survives a DHCP change on either side.
#################

function Get-HeadsetToolboxPackagePath {
    <#
    .SYNOPSIS
    Returns the path of the generated headset toolbox zip. It lives under
    website\generated\ (excluded from releases, served through the web server's
    transparent generated\ fallback), so the URL is
    /headset-toolbox/VRHM-Headset-Toolbox.zip.
    #>
    return (Join-Path $global:ScriptPath "website\generated\headset-toolbox\VRHM-Headset-Toolbox.zip")
}


function New-HeadsetToolboxPackage {
    <#
    .SYNOPSIS
    Builds the ready-to-use VRHM-Headset-Toolbox.zip by copying 3 committed,
    self-contained .exe binaries into a zip root and adding one static
    reference file for Linux kiosks. The zip's content is fully static (no
    server-specific data is ever baked in - see the module header), so this
    is just a copy+zip; it is still rebuilt at every app startup purely for
    consistency with how the app has always refreshed this download.

    Zip contents:
      Start-HeadsetToolbox.exe   -> committed binary; embeds Enable-HeadsetWifiAdb.ps1 + adb.exe + AdbWinApi.dll + AdbWinUsbApi.dll
      Start-Kiosk-Agent.exe      -> committed binary; embeds Start-KioskAgent.ps1
      Find-VRHM-Server.exe       -> committed binary; embeds Find-VRHM-Server.ps1
      kiosk-launcher\Start-KioskAgent-Linux.sh -> static copy for Linux kiosks (the exe above is Windows-only)

    Each exe self-extracts its own dependencies into its own subfolder next to
    itself on first run (never overwriting an existing local copy), and all
    3 share one vrhm_server_cache.json written at the extracted root the
    first time any of them finds the VRHM server on the LAN.

    Returns the zip path on success, $null on failure. Never throws: a missing
    zip only costs the operator a convenience download.
    .EXAMPLE
    New-HeadsetToolboxPackage
    #>
    param(
        [string]$OutputPath = (Get-HeadsetToolboxPackagePath)
    )

    $staging = Join-Path $env:TEMP ("vrhm_headset_toolbox_pkg_" + [guid]::NewGuid().ToString('N'))

    try {
        New-Item -ItemType Directory -Path $staging -Force -ErrorAction Stop | Out-Null

        # ---- Copy the 3 self-contained exe tools into the zip root ----
        $exeSpecs = @(
            @{ Src = Join-Path $global:ScriptPath "website\headset-toolbox\Start-HeadsetToolbox.exe"; Name = 'Start-HeadsetToolbox.exe' },
            @{ Src = Join-Path $global:ScriptPath "website\kiosk-launcher\Start-Kiosk-Agent.exe";      Name = 'Start-Kiosk-Agent.exe' },
            @{ Src = Join-Path $global:ScriptPath "website\find-server\Find-VRHM-Server.exe";          Name = 'Find-VRHM-Server.exe' }
        )
        foreach ($spec in $exeSpecs) {
            if (-not (Test-Path -LiteralPath $spec.Src)) {
                Write-Log "New-HeadsetToolboxPackage: '$($spec.Name)' missing at $($spec.Src) - aborting." -Level WARNING
                return $null
            }
            Copy-Item -LiteralPath $spec.Src -Destination (Join-Path $staging $spec.Name) -Force -ErrorAction Stop
        }

        # ---- Static reference copy for Linux kiosks (Start-Kiosk-Agent.exe is Windows-only) ----
        $kioskLinuxSrc = Join-Path $global:ScriptPath "website\kiosk-launcher\Start-KioskAgent-Linux.sh"
        if (Test-Path -LiteralPath $kioskLinuxSrc) {
            $kioskStaging = Join-Path $staging "kiosk-launcher"
            New-Item -ItemType Directory -Path $kioskStaging -Force -ErrorAction Stop | Out-Null
            Copy-Item -LiteralPath $kioskLinuxSrc -Destination (Join-Path $kioskStaging 'Start-KioskAgent-Linux.sh') -Force -ErrorAction Stop
        } else {
            Write-Log "New-HeadsetToolboxPackage: 'Start-KioskAgent-Linux.sh' missing from website\kiosk-launcher - not included in the package." -Level WARNING
        }

        # ---- Zip it ----
        $outFolder = Split-Path -Parent $OutputPath
        if (-not (Test-Path -LiteralPath $outFolder)) {
            New-Item -ItemType Directory -Path $outFolder -Force -ErrorAction Stop | Out-Null
        }
        if (Test-Path -LiteralPath $OutputPath) {
            Remove-Item -LiteralPath $OutputPath -Force -ErrorAction Stop
        }

        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        [System.IO.Compression.ZipFile]::CreateFromDirectory($staging, $OutputPath)

        Write-Log "New-HeadsetToolboxPackage: headset toolbox package rebuilt -> $OutputPath" -Level INFO
        return $OutputPath
    } catch {
        Write-Log "New-HeadsetToolboxPackage: failed to build the headset toolbox package - $($_.Exception.Message)" -Level WARNING
        return $null
    } finally {
        if (Test-Path -LiteralPath $staging) {
            Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
