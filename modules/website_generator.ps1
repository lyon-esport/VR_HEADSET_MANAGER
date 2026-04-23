
#Update-OBSFile -knownHeadsetsInfo $knownHeadsetsInfo -obsTemplatePath (Join-Path -Path $global:ScriptPath -ChildPath "\website\template\headset_status_v2.eps") # $global:obsTemplatePath -obsOutputPath $global:obsOutputPath
function Update-OBSFile {
    param(
        [Parameter(Mandatory=$true)]
        [System.Collections.ArrayList]$knownHeadsetsInfo,

        #[string]$obsTemplatePath = (Join-Path -Path $global:ScriptPath -ChildPath "\website\template\headset_status_v2.eps") ,
        [string]$obsTemplatePath = $global:OBS_headsetTemplate ,

        [string]$obsOutputPath = (Join-Path -Path $global:ScriptPath -ChildPath "\website\")
    )

    if (-not (Test-Path -Path $obsTemplatePath)) {
        Write-Host "Error: The OBS template file does not exist at path $obsTemplatePath" -ForegroundColor Red
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
            temperature_highLevel             = $global:OBS_temperature_highLevel
            model                            = if ($headset.Model -and $headset.Model -ne "-") { $headset.Model } else { "" }
            headset_battery_warningLevel     = $global:OBS_headset_battery_warningLevel
            headset_battery_criticalLevel    = $global:OBS_headset_battery_criticalLevel
            controllers_battery_warningLevel  = $global:OBS_controllers_battery_warningLevel
            controllers_battery_criticalLevel = $global:OBS_controllers_battery_criticalLevel
            running_app     = if ($headset.RunningApp) { $headset.RunningApp } else { "-" }
            running_app_icon = if ($headset.RunningAppIcon) { $headset.RunningAppIcon } else { "" }
            power_state     = if ($headset.PowerState -and $headset.PowerState -ne "-") { $headset.PowerState } else { "" }
            time_remaining_min = if ($headset.TimeRemainingMin -and $headset.TimeRemainingMin -ne "-") { $headset.TimeRemainingMin } else { "" }
            #battery_emoji   = if ($([convert]::ToInt32($($headset.Battery -replace ' %','') , 10)) -lt 30) { [System.Char]::ConvertFromUtf32(0x1FAAB)  } else { [System.Char]::ConvertFromUtf32(0x1F50B) }
            #charging_emoji  = if ($headset.Charging -ne $true) { [System.Char]::ConvertFromUtf32(0x274C) } else { [System.Char]::ConvertFromUtf32(0x26A1) }
            #temp_emoji      = if ($headset.Temp -eq "-") { [System.Char]::ConvertFromUtf32(0x2753) } elseif ($headset.Temp -lt 50) { [System.Char]::ConvertFromUtf32(0x1F9CA) } else { [System.Char]::ConvertFromUtf32(0x1F525) }
        }
        $headsetsHtml = Invoke-EpsTemplate -Path $obsTemplatePath -Safe -binding $deviceInfo #$headset
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
        $outputFile = Join-Path -Path $obsOutputPath -ChildPath ((Convert-Displayname($headset.Name)) + "[monitoring].html")
        $headsetsHtml | Out-File -LiteralPath $outputFile -Encoding UTF8

    }
}

# Function Write-htmlMonitor $newHeadsets
function Write-htmlMonitor {
    param(
        [Parameter(Mandatory=$true)]
        [System.Collections.ArrayList]$knownHeadsets,
        [string]$obsMonitorTemplatePath = (Join-Path -Path $global:ScriptPath -ChildPath "\website\template\monitor.eps"),

        [string]$obsOutputPath = (Join-Path -Path $global:ScriptPath -ChildPath "\website\monitor.html")
    )

    if (-not (Test-Path -Path $obsMonitorTemplatePath)) {
        Write-Host "Error: The OBS monitor template file does not exist at path $obsMonitorTemplatePath" -ForegroundColor Red
        return
    }
    
   
    
    $TemplateVariables = @{
        headsets = $knownHeadsets | ForEach-Object { Convert-Displayname $_.Name }
    }
    $headsetsHtml = Invoke-EpsTemplate -Path $obsMonitorTemplatePath -Safe -binding $TemplateVariables
    $headsetsHtml | Out-File -FilePath $obsOutputPath -Encoding UTF8
}

# Generates one [video].html per headset using the scrcpy WHEP video template.
# Each file embeds a WebRTC player (WHEP) that connects to the mediamtx stream
# on demand (mediamtx starts ffmpeg GDI capture of the scrcpy window when a viewer connects).
# Output file naming: <DisplayName>[video].html  e.g. Q3_BLUE[video].html
function Update-OBSVideoFile {
    param(
        [Parameter(Mandatory=$true)]
        [System.Collections.ArrayList]$knownHeadsetsInfo,

        [string]$obsVideoTemplatePath = $global:OBS_videoTemplate,

        [string]$obsOutputPath = (Join-Path -Path $global:ScriptPath -ChildPath "\website\")
    )

    if (-not (Test-Path -Path $obsVideoTemplatePath)) {
        Write-Log ("Video template not found: $obsVideoTemplatePath") -Level WARNING
        return
    }

    foreach ($headset in $knownHeadsetsInfo) {
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
        }

        $videoHtml = Invoke-EpsTemplate -Path $obsVideoTemplatePath -Safe -binding $videoInfo

        # Write to <DisplayName>[video].html  e.g. Q3_BLUE[video].html
        # Use -LiteralPath because brackets in filenames are misread as wildcards by -FilePath.
        $outputFile = Join-Path -Path $obsOutputPath -ChildPath ((Convert-Displayname $headset.Name) + "[video].html")
        $videoHtml | Out-File -LiteralPath $outputFile -Encoding UTF8
    }
}

# Generates website/video_monitor.html from the video_monitor.eps template.
# Lists every headset in $knownHeadsets; the page JS polls the CSV at runtime
# to filter cells by All / Reachable (ping) / Streaming (scrcpy).
function Write-VideoMonitor {
    param(
        [Parameter(Mandatory=$true)]
        [System.Collections.ArrayList]$knownHeadsets,
        [string]$templatePath = (Join-Path -Path $global:ScriptPath -ChildPath "\website\template\video_monitor.eps"),
        [string]$outputPath   = (Join-Path -Path $global:ScriptPath -ChildPath "\website\video_monitor.html")
    )

    if (-not (Test-Path -Path $templatePath)) {
        Write-Log ("Video monitor template not found: $templatePath") -Level WARNING
        return
    }

    $headsetData = [System.Collections.ArrayList]@()
    foreach ($h in $knownHeadsets) {
        $null = $headsetData.Add(@{
            name        = $h.Name
            displayName = Convert-Displayname $h.Name
        })
    }

    $templateVars = @{ headsets = $headsetData }
    $html = Invoke-EpsTemplate -Path $templatePath -Safe -binding $templateVars
    $html | Out-File -LiteralPath $outputPath -Encoding UTF8
}
