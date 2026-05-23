
#Update-HeadsetMonitoringFile -knownHeadsetsInfo $knownHeadsetsInfo -templatePath (Join-Path -Path $global:ScriptPath -ChildPath "\website\template\headset_status_v2.pshtml") # $global:Monitoring_headsetTemplate -outputPath $global:outputPath
function Update-HeadsetMonitoringFile {
    param(
        [Parameter(Mandatory=$true)]
        [System.Collections.ArrayList]$knownHeadsetsInfo,

        #[string]$templatePath = (Join-Path -Path $global:ScriptPath -ChildPath "\website\template\headset_status_v2.pshtml") ,
        [string]$templatePath = $global:Monitoring_headsetTemplate ,

        [string]$outputPath = (Join-Path -Path $global:ScriptPath -ChildPath "\website\")
    )

    if (-not (Test-Path -Path $templatePath)) {
        Write-Host "Error: The headset monitoring template file does not exist at path $templatePath" -ForegroundColor Red
        return
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
            #battery_emoji   = if ($([convert]::ToInt32($($headset.Battery -replace ' %','') , 10)) -lt 30) { [System.Char]::ConvertFromUtf32(0x1FAAB)  } else { [System.Char]::ConvertFromUtf32(0x1F50B) }
            #charging_emoji  = if ($headset.Charging -ne $true) { [System.Char]::ConvertFromUtf32(0x274C) } else { [System.Char]::ConvertFromUtf32(0x26A1) }
            #temp_emoji      = if ($headset.Temp -eq "-") { [System.Char]::ConvertFromUtf32(0x2753) } elseif ($headset.Temp -lt 50) { [System.Char]::ConvertFromUtf32(0x1F9CA) } else { [System.Char]::ConvertFromUtf32(0x1F525) }
        }
        $headsetsHtml = Invoke-EpsTemplate -Path $templatePath -Safe -binding $deviceInfo #$headset
        <#
        [System.Char]::ConvertFromUtf32(0x1F50B) # battery emoji
        [System.Char]::ConvertFromUtf32(0x1FAAB) # low battery emoji
        [System.Char]::ConvertFromUtf32(0x1F4A1) # light bulb emoji
        [System.Char]::ConvertFromUtf32(0x1F525) # fire emoji
        [System.Char]::ConvertFromUtf32(0x1F4A6) # sweat emoji
        [System.Char]::ConvertFromUtf32(0x1F4A4)    # sleep emoji
        [System.Char]::ConvertFromUtf32(0x1F480) # skull emoji
        [System.Char]::ConvertFromUtf32(0x2705) # check mark emoji
        [System.Char]::ConvertFromUtf32(0x26A1) # high voltage emoji
        [System.Char]::ConvertFromUtf32(0x26A0) # warning emoji
        [System.Char]::ConvertFromUtf32(0x1F6AB) # no entry emoji
#>
        # write html to $output/$name[monitoring].html
        # $value =  @{ Name = "Quest3 BLEU" }
        $outputFile = Join-Path -Path $outputPath -ChildPath ((Convert-Displayname($headset.Name)) + "[monitoring].html")
        $headsetsHtml | Out-File -LiteralPath $outputFile -Encoding UTF8

    }
}

# Function Write-htmlMonitor $newHeadsets
function Write-htmlMonitor {
    param(
        [Parameter(Mandatory=$true)]
        [AllowEmptyCollection()]
        [System.Collections.ArrayList]$knownHeadsets,
        [string]$templatePath = (Join-Path -Path $global:ScriptPath -ChildPath "\website\template\monitor.pshtml"),

        [string]$outputPath = (Join-Path -Path $global:ScriptPath -ChildPath "\website\monitor.html")
    )

    if (-not (Test-Path -Path $templatePath)) {
        Write-Host "Error: The monitor template file does not exist at path $templatePath" -ForegroundColor Red
        return
    }



    $TemplateVariables = @{
        headsets = $knownHeadsets | ForEach-Object { Convert-Displayname $_.Name }
    }
    $headsetsHtml = Invoke-EpsTemplate -Path $templatePath -Safe -binding $TemplateVariables
    $headsetsHtml | Out-File -FilePath $outputPath -Encoding UTF8
}

# Generates one [video].html per headset using the scrcpy WHEP video template.
# Each file embeds a WebRTC player (WHEP) that connects to the mediamtx stream
# on demand (mediamtx starts ffmpeg GDI capture of the scrcpy window when a viewer connects).
# Output file naming: <DisplayName>[video].html  e.g. Q3_BLUE[video].html
function Update-HeadsetVideoFile {
    param(
        [Parameter(Mandatory=$true)]
        [System.Collections.ArrayList]$knownHeadsetsInfo,

        [string]$templatePath = $global:Monitoring_videoTemplate,

        [string]$outputPath = (Join-Path -Path $global:ScriptPath -ChildPath "\website\")
    )

    if (-not (Test-Path -Path $templatePath)) {
        Write-Log ("Video template not found: $templatePath") -Level WARNING
        return
    }

    $allKnown = Get-KnownHeadsets
    foreach ($headset in $knownHeadsetsInfo) {
        # Compute the mediamtx stream path from the headset name.
        # Matches ConvertTo-RestreamPathName in restream.ps1:
        #   Convert-Displayname replaces spaces with underscores, then lowercase.
        $streamPath = (Convert-Displayname -displayName $headset.Name).ToLower()

        $km = $allKnown | Where-Object { $_.Name -eq $headset.Name } | Select-Object -First 1

        $videoInfo = @{
            name                  = $headset.Name
            display_name          = Convert-Displayname $headset.Name
            stream_path           = $streamPath
            mediamtx_webrtc_port  = $global:mediamtxWebrtcPort
            mediamtx_hls_port     = $global:mediamtxHlsPort
            headset_id            = if ($km) { [int]$km.ID } else { 0 }
        }

        $videoHtml = Invoke-EpsTemplate -Path $templatePath -Safe -binding $videoInfo

        # Write to <DisplayName>[video].html  e.g. Q3_BLUE[video].html
        # Use -LiteralPath because brackets in filenames are misread as wildcards by -FilePath.
        $outputFile = Join-Path -Path $outputPath -ChildPath ((Convert-Displayname $headset.Name) + "[video].html")
        $videoHtml | Out-File -LiteralPath $outputFile -Encoding UTF8
    }
}

