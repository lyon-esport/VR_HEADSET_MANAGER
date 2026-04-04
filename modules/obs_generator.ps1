
#Update-OBSFile -knownHeadsetsInfo $knownHeadsetsInfo -obsTemplatePath (Join-Path -Path $global:ScriptPath -ChildPath "\OBS\template\headset_status_v2.eps") # $global:obsTemplatePath -obsOutputPath $global:obsOutputPath
function Update-OBSFile {
    param(
        [Parameter(Mandatory=$true)]
        [System.Collections.ArrayList]$knownHeadsetsInfo,

        #[string]$obsTemplatePath = (Join-Path -Path $global:ScriptPath -ChildPath "\OBS\template\headset_status_v2.eps") ,
        [string]$obsTemplatePath = $global:OBS_headsetTemplate ,

        [string]$obsOutputPath = (Join-Path -Path $global:ScriptPath -ChildPath "\OBS\")
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
            battery_lowLevel = $global:OBS_battery_lowLevel
            battery_ctrl_left  = if ($headset.BatteryControllerLeft  -ne "-") { [convert]::ToInt32($($headset.BatteryControllerLeft  -replace ' %','') , 10) } else { $headset.BatteryControllerLeft }
            battery_ctrl_right = if ($headset.BatteryControllerRight -ne "-") { [convert]::ToInt32($($headset.BatteryControllerRight -replace ' %','') , 10) } else { $headset.BatteryControllerRight }
            charging        = [bool]$headset.Charging
            temp            = if ($headset.Temp -ne "-"){ ([int]($headset.Temp -replace ',','.')) } else { $headset.Temp } # convert to int
            temperature_highLevel = $global:OBS_temperature_highLevel
            running_app     = if ($headset.RunningApp) { $headset.RunningApp } else { "-" }
            running_app_icon = if ($headset.RunningAppIcon) { $headset.RunningAppIcon } else { "" }
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
        # write html to $output/$name.html
        # $value =  @{ Name = "Quest3 BLEU" }
        $outputFile = Join-Path -Path $obsOutputPath -ChildPath ((Convert-Displayname($headset.Name)) + ".html")
        $headsetsHtml | Out-File -FilePath $outputFile -Encoding UTF8

    }
}

# Function Write-htmlMonitor $newHeadsets
function Write-htmlMonitor {
    param(
        [Parameter(Mandatory=$true)]
        [System.Collections.ArrayList]$knownHeadsets,
        [string]$obsMonitorTemplatePath = (Join-Path -Path $global:ScriptPath -ChildPath "\OBS\template\monitor.eps"),

        [string]$obsOutputPath = (Join-Path -Path $global:ScriptPath -ChildPath "\OBS\monitor.html")
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
