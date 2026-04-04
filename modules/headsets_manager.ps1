#################
# MANAGE KNOWN HEADSET FILE
#################

# Function to retrieve VR headsets from the CSV file
# Example usage of the Get-KnownHeadsets function
# $headsets=Get-KnownHeadsets
function Get-KnownHeadsets {
    param (
        [string]$knownHeadsetsFilePath = $global:knownHeadsetsFilePath 
    )

    # Check whether the global variable $knownHeadsetsFilePath is defined
    if (-not $knownHeadsetsFilePath) {
        Write-Log -Message $msg.HeadsetCsvPathEmpty -Level "ERROR"
        return
    }

    # Check whether the file exists
    if (-not (Test-Path $knownHeadsetsFilePath)) {
        Write-Log -Message ($msg.HeadsetCsvNotFound -f $knownHeadsetsFilePath) -Level "ERROR"
        return
    }

    # Read the CSV file and return data as PowerShell objects
    try {
        $headsets = @(Import-Csv -Path $knownHeadsetsFilePath)
        return $headsets
    }
    catch {
        Write-Log -Message $msg.HeadsetCsvReadError -Level "ERROR"
    } 
} # OK


# DISPLAY ALL HEADSETS
# WITH PING, ADB PORT, AND SCRCPY STREAM STATUS TESTING
#Show-HeadsetsTable -FieldsToShow @("ID", "Name", "Model", "Ping", "ADBReachable", "SCRCPY")
#$FieldsToShow = "all"

#  $headset = $headsets[0]

#Show-HeadsetsTable -FieldsToShow @("ID","Name","Model","IPAddress","Ping","ADBWifi")

function Show-HeadsetsTable {
    param (
        [string]$FilePath = $global:knownHeadsetsInfosFilePath,
        [string[]]$FieldsToShow = @("all")
    )

    # Load headsets from the CSV file
    $headsets = @(Import-Csv -Path $FilePath -Delimiter ";" )

    if ($headsets.Count -eq 0) {
        Write-Log $msg.NoHeadsetToDisplay -Level "INFO"
        return
    }

    if ($FieldsToShow -contains 'all') {
        $FieldsToShow = @("ID","Name","IPAddress","Ping","ADBWifi","Model","SerialNumber","Battery","Temp","Charging","SCRCPY","RunningApp")
    }

    # Add "Ping", "ADBReachable", "SCRCPY" to valid fields
    $validFields = $headsets[0].PSObject.Properties.Name.Split(";").replace('"',"") + "SCRCPY"
    $invalidFields = $FieldsToShow | Where-Object { $_ -notin $validFields }

    if ($invalidFields.Count -gt 0) {
        Write-Log ($msg.InvalidFieldsIgnored -f ($invalidFields -join ', ')) -Level "WARNING"
    }

    $FieldsToShow = $FieldsToShow | Where-Object { $_ -in $validFields }




    # Replace True & False by OK & KO
    foreach ($headset in $headsets) {
        foreach ($field in $FieldsToShow){
            $headset | Add-Member -NotePropertyName $field -NotePropertyValue ($headset.$field -replace '\bTrue\b', 'OK' -replace '\bFalse\b', 'KO') -Force
        }
    }


    if ($headsets.Count -gt 0) {
        $headsets  | Select-Object $FieldsToShow | Format-Table -AutoSize
    } else {
        Write-Log ($msg.NoHeadsetFoundInFile -f $FilePath) -Level WARNING
    }
}


function Show-HeadsetsConfig {
    param (
            #[array]$knownHeadsetsInfosFilePath = $global:knownHeadsetsInfosFilePath,
            [array]$FieldsToShow = @("ID","Name","IPAddress","scrcpy_AutoRestart","Record","ScrcpyProfile","SerialNumber"),
            [bool]$UseColors = $true
        )
    $knownHeadsetsConfig = @(Import-Csv -Path $global:knownHeadsetsFilePath -Delimiter "," )

    if (-not $knownHeadsetsConfig -or $knownHeadsetsConfig.Count -eq 0) {
        Write-Log ($msg.NoHeadsetFoundInFile -f $global:knownHeadsetsFilePath) -Level INFO
        return
    }
    # display table formated with "|" as separator and colored if $UseColors is true
    if ($UseColors){

        # Determine the console width
        $consoleWidth = $Host.UI.RawUI.WindowSize.Width - 1
        if ($consoleWidth -lt 0) { $consoleWidth = 80 } # Default value

        # Define the padding lengths for each field and store them in a hashtable
        $Padding = @{
            ID = 2
            Name = 15
            IPAddress = 13
            scrcpy_AutoRestart = 15
            Record = 6
            ScrcpyProfile = 14
            SerialNumber = 20
        }
        
        # Build the table header
        $header = ""
        foreach ($field in $FieldsToShow) {
            $header += $field.PadRight($Padding[$field]).Substring(0,$Padding[$field]) + " | "
        }
        Write-Host $header.Substring(0, [Math]::Min($header.Length, $consoleWidth))

        # Display each row with appropriate formatting
        foreach ($headset in $knownHeadsetsConfig) {
            foreach ($field in $FieldsToShow) {
                $value = $headset.$field
                
                if ($null -eq $value) {
                    $value = "-"
                }
                $fgColor = "White"
                if ($value -eq "True") {
                    $value = "OK"
                    $fgColor = "Green" 
                } elseif ($value -eq "False") {
                    $value = "KO" 
                    $fgColor = "Red"
                }

                # Print line with colors (each field with its own color)
                Write-Host "$($value.PadRight($Padding[$field]).Substring(0,$Padding[$field]))" -ForegroundColor $fgColor -NoNewline
                 Write-Host " | " -NoNewline
            }
            Write-Host "" # New line
        }
       
    } else {
        $knownHeadsetsConfig | Select-Object $FieldsToShow | Format-Table -AutoSize
    }
}

# Show-HeadsetsTableColored -FieldsToShow @("ID","Name","Ping","ADBWifi","Battery","Charging","Temp") -UseColors $true 

function Show-HeadsetsTableColored {
    param (
        [array]$knownHeadsetsInfosFilePath = $global:knownHeadsetsInfosFilePath,
        [array]$FieldsToShow = @("ID","Name","IPAddress","Ping","ADBWifi","Battery","Charging","Temp","SCRCPY","Model","SerialNumber","RunningApp"),
        [bool]$UseColors = $true
    )

    $knownHeadsetsInfo = @(Import-Csv -Path $knownHeadsetsInfosFilePath -Delimiter ";" )
    # Check whether data is present
    if (-not $knownHeadsetsInfo -or $knownHeadsetsInfo.Count -eq 0) {
        Write-Log ($msg.NoHeadsetInInfosFile -f $knownHeadsetsInfosFilePath) -Level WARNING
        return
    }


    if ($UseColors){

        # Determine the console width
        $consoleWidth = $Host.UI.RawUI.WindowSize.Width - 1
        if ($consoleWidth -lt 0) { $consoleWidth = 80 } # Default value


        # Compute column widths dynamically: max of header length and longest value in each column
        $Padding = @{}
        foreach ($field in $FieldsToShow) {
            $maxLen = $field.Length  # start with header length
            foreach ($headset in $knownHeadsetsInfo) {
                # Mirror the same transformations applied during rendering
                $value = $headset.$field
                if ($field -eq "Battery") {
                    $h  = ($headset.Battery               -replace '[^\d]','').Trim()
                    $cl = ($headset.BatteryControllerLeft  -replace '[^\d]','').Trim()
                    $cr = ($headset.BatteryControllerRight -replace '[^\d]','').Trim()
                    if (-not $h)  { $h  = "-" }
                    if (-not $cl) { $cl = "-" }
                    if (-not $cr) { $cr = "-" }
                    $value = "$cl|$h|$cr"
                } elseif ($field -eq "Temp" -and $value) {
                    $value = ($value -replace '\,0$','') + ([char]0x00B0) + 'C'
                } elseif ($field -eq "ADBWifi") {
                    $value = if ($headset.ADBWifi -eq "True") { "OK" } else { "KO" }
                } elseif ($field -eq "Ping") {
                    $value = if ($headset.Ping -eq "True") { "OK" } else { "KO" }
                } elseif ($value -is [bool]) {
                    $value = if ($value) { "OK" } else { "KO" }
                } elseif ($null -eq $value) {
                    $value = "-"
                }
                if ($value.Length -gt $maxLen) { $maxLen = $value.Length }
            }
            $Padding[$field] = $maxLen
        }


        # Build the table header
        $header = ""
        foreach ($field in $FieldsToShow) {
            $header += $field.PadRight($Padding[$field]).Substring(0,$Padding[$field]) + " | "
        }
        Write-Host $header.Substring(0, [Math]::Min($header.Length, $consoleWidth))

        # Display each row with appropriate formatting
        foreach ($headset in $knownHeadsetsInfo) {
            # Determine the background color
            $bgColor = "$null"
            
            if ($headset.Ping -eq $False) {
                $bgColor = "DarkGray" # Headset not responding
            }
            elseif ($headset.ADBWifi -eq $False) {
                $bgColor = "Black"  # Headset ADB not responding on the specified port
            }
            elseif ($headset.Temp -and [int]($headset.Temp -replace ',','.') -gt 55) {
                $bgColor = "DarkRed" # Temperature > 50°
            }
            elseif ($headset.Battery -and [int]($headset.Battery -replace '[^\d]','') -lt 40 -and $headset.Charging -eq $False) {
                $bgColor = "DarkRed" # Battery < 40% and not charging
            }
            elseif ($headset.Battery -and [int]($headset.Battery -replace '[^\d]','') -lt 30 -and $headset.Charging -eq $True) {
                $bgColor = "DarkYellow" # Battery < 30% and charging
            }
            elseif ($headset.Charging -eq $False) {
                $bgColor = "DarkYellow" # Headset is not charging
            }
            elseif (
                ($headset.BatteryControllerLeft  -match '\d' -and [int]($headset.BatteryControllerLeft  -replace '[^\d]','') -lt 20) -or
                ($headset.BatteryControllerRight -match '\d' -and [int]($headset.BatteryControllerRight -replace '[^\d]','') -lt 20)
            ) {
                $bgColor = "DarkYellow" # A controller battery is below 20%
            }
            elseif ($headset.SCRCPY -eq "OK") {
                $bgColor = "Green" # Scrcpy is running
            }
            else {
                $bgColor = "White" # Default color (everything is fine)
            }
            

            # Define the foreground color (default White)
            $fgColor = "White"
            if ($headset.SCRCPY -eq "OK" -and $bgColor -ne "Green"){
                $fgColor = "DarkGreen"
            }
            elseif ($bgColor -eq "DarkGray" -or $bgColor -eq "Black") {
                $fgColor = "Gray"
            }
            elseif ($bgColor -eq "Green" -or $bgColor -eq "White") {
                $fgColor = "Black"
            }
            elseif ($bgColor -eq "DarkYellow") {
                $fgColor = "Black"
            }


            # line to display
            $line = ""



            foreach ($field in $FieldsToShow) {
                $value = $headset.$field
                
                #convert value from 42.0 to 42 °c
                if ($field -eq "Temp" -and $value) {
                    $degree = [char]0x00B0
                    $value = $($value -replace '\,0$','')+$degree+'C'
                }
                # Composite battery: [CtrlL|Headset|CtrlR] without %
                if ($field -eq "Battery") {
                    $h  = ($headset.Battery              -replace '[^\d]','').Trim()
                    $cl = ($headset.BatteryControllerLeft  -replace '[^\d]','').Trim()
                    $cr = ($headset.BatteryControllerRight -replace '[^\d]','').Trim()
                    if (-not $h)  { $h  = "-" }
                    if (-not $cl) { $cl = "-" }
                    if (-not $cr) { $cr = "-" }
                    $value = "$cl[$h]$cr"
                }
                # Add the field to the row
                if ($null -eq $value) {
                    $value = "-"
                }
                elseif ($value -is [bool]) {
                    $value = if ($value) { "OK" } else { "KO" }
                }
                elseif ($field -eq "ADBWifi") {
                    $value = if ($headset.ADBWifi -eq "True") { "OK" } else { "KO" }
                }
                if ($field -eq "Ping") {
                    $value = if ($headset.Ping -eq "True") { "OK" } else { "KO" }
                }

                if ($field -eq "Battery") { # Center battery result in its column
                    $pad   = $Padding[$field]
                    $total = $pad - $value.Length
                    $left  = [Math]::Floor($total / 2)
                    $right = $total - $left
                    $line += (" " * $left + $value + " " * $right).Substring(0, $pad) + " | "
                } else {
                    $line += "$($value.PadRight($Padding[$field]).Substring(0,$Padding[$field])) | "
                }
            }

            # Display the row with appropriate colors

            Write-Host $line.Substring(0, [Math]::Min($line.Length, $consoleWidth)) -BackgroundColor $bgColor -ForegroundColor $fgColor
            
        }
    } else { # No colors
        $knownHeadsetsInfo | Select-Object $FieldsToShow | Format-Table -AutoSize
    }
}




#Add-Headset -IPAddress "192.168.1.223" -Name "Q3 Manu"
function Add-Headset {
    param (
        [array]$headsets = (Import-Csv -Path $global:knownHeadsetsFilePath),  # Default value: CSV file
        [Parameter(Mandatory = $true)][string]$IPAddress,
        [string]$Name = "New headset"#,
        #[int]$AdbPort = 5555
    )

    #Check if a headset with the same @IP does not already exist
    if ( $headsets.IPAddress -contains $IPAddress){
        Write-Log ($msg.HeadsetIpExists -f $IPAddress) -Level WARNING
        return
    }
    
    # Add a new headset to the list
    $newHeadset = [PSCustomObject]@{
        ID          = ($headsets | Measure-Object).Count + 1
        Name         = $Name
        IPAddress    = $IPAddress
        scrcpy_AutoRestart = "False"
        Record       = "False"
        ScrcpyProfile = "R-N-45-20"
        SerialNumber = ""
        #AdbPort      = $AdbPort
    }

    # Add to the headset list
    $headsets += $newHeadset

    Write-Log ($msg.HeadsetAdding -f $Name, $IPAddress) -Level INFO

    # Save to the CSV file
    Save-Headsets -headsets $headsets
} # OK

# Update-HeadsetField -ID ([int]"1") -Field "SerialNumber" -NewValue "ABC123"
function Update-HeadsetField {
    param (
        [array]$headsets = (Import-Csv -Path $global:knownHeadsetsFilePath),  # Default value: CSV file
        [int]$ID,
        [string]$Field,
        [string]$NewValue
    )

    $headset = $headsets | Where-Object { $_.ID -eq $ID }

    if ($headset) {
        if ($headset.PSObject.Properties.Name -contains $Field) {
            $headset.$Field = $NewValue
            Write-Log ($msg.HeadsetFieldUpdated -f $Field, $ID, $NewValue) -Level INFO
        } else {
            Write-Log ($msg.HeadsetFieldNotExist -f $Field) -Level ERROR
        }
    } else {
        Write-Log ($msg.HeadsetIdNotFound -f $ID) -Level ERROR
    }
    # Save changes to the CSV file
    Save-Headsets -headsets $headsets
    #return $headsets
} # OK

function Remove-Headset {
    param (
        [array]$headsets = (Import-Csv -Path $global:knownHeadsetsFilePath),
        [int]$ID
    )

    # Find the headset with the specified ID
    $headsetToRemove = $headsets | Where-Object { $_.ID -eq $ID }

    if ($headsetToRemove) {
        # Remove the headset from the list
        $headsets = $headsets | Where-Object { $_.ID -ne $ID }
        Write-Log ($msg.HeadsetRemoved -f $ID, $headsetToRemove.Name) -Level INFO
    } else {
        Write-Log ($msg.HeadsetIdNotFound -f $ID) -Level ERROR
    }
    # Save changes to the CSV file
    Save-Headsets -headsets $headsets
    #return $headsets
} #OK

function Save-Headsets {
    param (
        [Parameter(Mandatory = $true)][array]$headsets,
        [string]$FilePath = $global:knownHeadsetsFilePath 
    )

    # Reassign IDs starting from 1
    $newHeadsets = $headsets | Sort-Object ID
    $newID = 1
    foreach ($headset in $newHeadsets) {
        $headset.ID = $newID
        $newID++
    }

    # Save to the CSV file
    $newHeadsets | Export-Csv -Path $FilePath -NoTypeInformation -Encoding UTF8
    Write-Log ($msg.HeadsetsSaved -f $FilePath) -Level INFO
    Write-htmlMonitor $newHeadsets
} #OK


function Add-Headset-Manually {
    # Clear the screen
    Clear-Host
    Start-Sleep -Milliseconds 200
    Write-Host "=== MANUAL HEADSET ADDITION ===" -BackgroundColor Green -ForegroundColor Black

    # Ask for the required information
    $name = Read-Host "Headset name (mandatory)"
    if (-not $name) {
        Write-Host "The name is mandatory. Aborting." -ForegroundColor Red
        return
    }

    $ip = Read-Host "Headset IP address (mandatory)"
    if (-not (Test-ValidIPv4 $ip)) {
        Write-Host "A valid IP address is mandatory. Aborting." -ForegroundColor Red
        return
    }

    # Optional fields
    #$adbPortInput = Read-Host "ADB port (optional, default: 5555)"

    # Handle default values
<#
    if ([string]::IsNullOrWhiteSpace($adbPortInput)) {
        $adbPort = 5555
    } else {
        $adbPort = [int]$adbPortInput
    }
 #>
    # Call the main function
    Add-Headset -IPAddress $ip -Name $name #-adbPort $adbPort

    Write-Host "Headset added successfully!" -ForegroundColor Cyan
} #OK
