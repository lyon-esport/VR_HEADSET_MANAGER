
#Update-HeadsetMonitoringFile -knownHeadsetsInfo $knownHeadsetsInfo -templatePath (Join-Path -Path $global:ScriptPath -ChildPath "\website\template\headset_status_v2.pshtml") # $global:Monitoring_headsetTemplate -outputPath $global:outputPath

# Per-file hash cache - avoids rewriting HTML when data has not changed since last render
$script:_monitoringHashes = @{}

function Update-HeadsetMonitoringFile {
    param(
        [System.Collections.ArrayList]$knownHeadsetsInfo = $null,

        #[string]$templatePath = (Join-Path -Path $global:ScriptPath -ChildPath "\website\template\headset_status_v2.pshtml") ,
        [string]$templatePath = $global:Monitoring_headsetTemplate ,

        [string]$outputPath = (Join-Path -Path $global:ScriptPath -ChildPath "\website\generated\")
    )

    if (-not (Test-Path -LiteralPath $templatePath)) {
        Write-Host "Error: The headset monitoring template file does not exist at path $templatePath" -ForegroundColor Red
        return
    }

    if ($null -eq $knownHeadsetsInfo) {
        $raw = @()
        if ($global:knownHeadsetsInfosFilePath -and (Test-Path -LiteralPath $global:knownHeadsetsInfosFilePath)) {
            $raw = @(Import-Csv -LiteralPath $global:knownHeadsetsInfosFilePath -Delimiter ";")
        }
        $knownHeadsetsInfo = [System.Collections.ArrayList]$raw
    }

    # Generate the dynamic content for headsets
    foreach ($headset in $knownHeadsetsInfo) {

        $deviceInfo = @{
            name            = $headset.Name
            ping            = [bool]$headset.Ping
            battery         = if ($headset.Battery -ne "-") { [convert]::ToInt32($($headset.Battery -replace ' %','') , 10) } else { $headset.Battery }
            battery_ctrl_left  = if ($headset.BatteryControllerLeft  -ne "-") { [convert]::ToInt32($($headset.BatteryControllerLeft  -replace ' %','') , 10) } else { $headset.BatteryControllerLeft }
            battery_ctrl_right = if ($headset.BatteryControllerRight -ne "-") { [convert]::ToInt32($($headset.BatteryControllerRight -replace ' %','') , 10) } else { $headset.BatteryControllerRight }
            charging        = [bool]$headset.Charging
            temp            = if ($headset.Temp -ne "-"){ ([int]($headset.Temp -replace ',','.')) } else { $headset.Temp } # convert to int
            temperature_highLevel             = $global:Monitoring_temperature_highLevel
            model                            = if ($headset.Model -and $headset.Model -ne "-") { $headset.Model } else { "" }
            headset_battery_warningLevel     = $global:Monitoring_headset_battery_warningLevel
            headset_battery_criticalLevel    = $global:Monitoring_headset_battery_criticalLevel
            controllers_battery_warningLevel  = $global:Monitoring_controllers_battery_warningLevel
            controllers_battery_criticalLevel = $global:Monitoring_controllers_battery_criticalLevel
            running_app     = if ($headset.RunningApp) { $headset.RunningApp } else { "-" }
            running_app_icon = if ($headset.RunningAppIcon) { $headset.RunningAppIcon } else { "" }
            power_state     = if ($headset.PowerState -and $headset.PowerState -ne "-") { $headset.PowerState } else { "" }
            time_remaining_min = if ($headset.TimeRemainingMin -and $headset.TimeRemainingMin -ne "-") { $headset.TimeRemainingMin } else { "" }
        }
        $headsetsHtml = Invoke-EpsTemplate -Path $templatePath -Safe -binding $deviceInfo

        $outputFile = Join-Path -Path $outputPath -ChildPath ((Convert-Displayname($headset.Name)) + "[monitoring].html")

        # Skip write if content has not changed
        $hashBytes = [System.Security.Cryptography.MD5]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($headsetsHtml))
        $hashStr = ($hashBytes | ForEach-Object { $_.ToString('x2') }) -join ''
        if ($script:_monitoringHashes[$outputFile] -ne $hashStr) {
            Write-FileWithoutBom -Path $outputFile -Content $headsetsHtml
            $script:_monitoringHashes[$outputFile] = $hashStr
        }
    }
}

# Function Write-htmlMonitor $newHeadsets
function Write-htmlMonitor {
    param(
        [Parameter(Mandatory=$true)]
        [AllowEmptyCollection()]
        [System.Collections.ArrayList]$knownHeadsets,
        [string]$templatePath = (Join-Path -Path $global:ScriptPath -ChildPath "\website\template\monitor.pshtml"),

        [string]$outputPath = (Join-Path -Path $global:ScriptPath -ChildPath "\website\generated\monitor.html")
    )

    if (-not (Test-Path -LiteralPath $templatePath)) {
        Write-Host "Error: The monitor template file does not exist at path $templatePath" -ForegroundColor Red
        return
    }

    $TemplateVariables = @{
        headsets = $knownHeadsets | ForEach-Object { Convert-Displayname $_.Name }
    }
    $headsetsHtml = Invoke-EpsTemplate -Path $templatePath -Safe -binding $TemplateVariables
    Write-FileWithoutBom -Path $outputPath -Content $headsetsHtml
}

# Generates one [video].html per headset using the scrcpy WHEP video template.
# Each file embeds a WebRTC player (WHEP) that connects to the mediamtx stream
# on demand (mediamtx starts ffmpeg GDI capture of the scrcpy window when a viewer connects).
# Output file naming: <DisplayName>[video].html  e.g. Q3_BLUE[video].html
function Update-HeadsetVideoFile {
    param(
        [string]$templatePath = $global:Monitoring_videoTemplate,

        [string]$outputPath = (Join-Path -Path $global:ScriptPath -ChildPath "\website\generated\")
    )

    if (-not (Test-Path -LiteralPath $templatePath)) {
        Write-Log ("Video template not found: $templatePath") -Level WARNING
        return
    }

    $allKnown = Get-KnownHeadsets
    foreach ($headset in $allKnown) {
        # Compute the mediamtx stream path from the headset name.
        # Matches ConvertTo-RestreamPathName in restream.ps1:
        #   Convert-Displayname replaces spaces with underscores, then lowercase.
        $streamPath = (Convert-Displayname -displayName $headset.Name).ToLower()

        $videoInfo = @{
            name                  = $headset.Name
            display_name          = Convert-Displayname $headset.Name
            stream_path           = $streamPath
            mediamtx_webrtc_port  = $global:mediamtxWebrtcPort
            mediamtx_hls_port     = $global:mediamtxHlsPort
            headset_id            = [int]$headset.ID
        }

        $videoHtml = Invoke-EpsTemplate -Path $templatePath -Safe -binding $videoInfo

        $outputFile = Join-Path -Path $outputPath -ChildPath ((Convert-Displayname $headset.Name) + "[video].html")

        # Skip write if content has not changed
        $hash = ($videoHtml | Get-FileHash -Algorithm MD5 -ErrorAction SilentlyContinue)
        $hashStr = if ($hash) { $hash.Hash } else { [guid]::NewGuid().ToString() }
        if ($script:_monitoringHashes[$outputFile] -ne $hashStr) {
            Write-FileWithoutBom -Path $outputFile -Content $videoHtml
            $script:_monitoringHashes[$outputFile] = $hashStr
        }
    }
}

