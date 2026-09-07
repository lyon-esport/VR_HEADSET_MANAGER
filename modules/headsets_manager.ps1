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
    if (-not (Test-Path -LiteralPath $knownHeadsetsFilePath)) {
        Write-Log -Message ($msg.HeadsetCsvNotFound -f $knownHeadsetsFilePath) -Level "ERROR"
        return
    }

    # Read the CSV file and return data as PowerShell objects
    try {
        $headsets = @(Import-Csv -LiteralPath $knownHeadsetsFilePath -Encoding UTF8)
        # Back-compat: ensure every row has a Brand property. Legacy CSVs (pre-Pico
        # support) had no Brand column; populate with a best-effort guess from Model
        # so brand-dispatch sites have something to work with on first read.
        # Allowed values: "Meta", "Pico", or "" (empty = unknown).
        foreach ($row in $headsets) {
            if (-not $row.PSObject.Properties['Brand']) {
                $guess = ""
                if ($row.Model -match '(?i)quest') { $guess = "Meta" }
                elseif ($row.Model -match '(?i)pico') { $guess = "Pico" }
                $row | Add-Member -MemberType NoteProperty -Name Brand -Value $guess -Force
            }
        }
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

function Get-HeadsetInfosMerged {
    # Reads the live-status file and grafts the identity columns back on from the registry,
    # joined by ID. known_headsets_infos.csv carries ID + live status only (ADR-0016), so any
    # display that wants Name / IPAddress / Brand / Model / SerialNumber has to come here.
    # Rows whose ID is no longer in the registry (removed headset) are dropped.
    param (
        [string]$FilePath = $global:knownHeadsetsInfosFilePath
    )

    if (-not $FilePath -or -not (Test-Path -LiteralPath $FilePath)) { return @() }

    $infos = @(Import-Csv -LiteralPath $FilePath -Delimiter ";" -Encoding UTF8)
    if ($infos.Count -eq 0) { return @() }

    $registryById = @{}
    foreach ($h in @(Get-KnownHeadsets)) {
        $rid = [string]$h.ID
        if (-not [string]::IsNullOrWhiteSpace($rid)) { $registryById[$rid] = $h }
    }

    $merged = @()
    foreach ($info in $infos) {
        $owner = $registryById[[string]$info.ID]
        if (-not $owner) { continue }
        $row = $info.PSObject.Copy()
        foreach ($field in @("Name","IPAddress","Brand","Model","SerialNumber")) {
            $value = if ($owner.PSObject.Properties[$field]) { $owner.$field } else { "" }
            if ($row.PSObject.Properties[$field]) { $row.$field = $value }
            else { $row | Add-Member -MemberType NoteProperty -Name $field -Value $value }
        }
        $merged += $row
    }
    return $merged
}

function Show-HeadsetsTable {
    param (
        [string]$FilePath = $global:knownHeadsetsInfosFilePath,
        [string[]]$FieldsToShow = @("all")
    )

    # Live status joined to the registry by ID - the infos file has no identity columns.
    $headsets = @(Get-HeadsetInfosMerged -FilePath $FilePath)

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
            [array]$FieldsToShow = @("ID","Name","IPAddress","scrcpy_AutoRestart","Record","ScrcpyProfile","Model","SerialNumber"),
            [bool]$UseColors = $true
        )
    $knownHeadsetsConfig = @(Get-KnownHeadsets)

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
            Name = 17
            IPAddress = 15
            scrcpy_AutoRestart = 4
            Record = 6
            ScrcpyProfile = 20
            SerialNumber = 14
            Model = 8
        }

        # Display name overrides (field name -> column header label)
        $FieldLabels = @{
            scrcpy_AutoRestart = "Cast"
        }

        # Build the table header
        $header = ""
        foreach ($field in $FieldsToShow) {
            $label = if ($FieldLabels.ContainsKey($field)) { $FieldLabels[$field] } else { $field }
            $header += $label.PadRight($Padding[$field]).Substring(0,$Padding[$field]) + " | "
        }
        Write-Host $header.Substring(0, [Math]::Min($header.Length, $consoleWidth)) -ForegroundColor Yellow

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

    # Live status joined to the registry by ID - the infos file has no identity columns.
    $knownHeadsetsInfo = @(Get-HeadsetInfosMerged -FilePath $knownHeadsetsInfosFilePath)
    # Check whether data is present
    if (-not $knownHeadsetsInfo -or $knownHeadsetsInfo.Count -eq 0) {
        Write-Log ($msg.NoHeadsetInInfosFile -f $knownHeadsetsInfosFilePath) -Level DEBUG
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
            $bgColor = $null
            
            if (-not (ConvertTo-BoolField $headset.Ping)) {
                $bgColor = "DarkGray" # Headset not responding
            }
            elseif (-not (ConvertTo-BoolField $headset.ADBWifi)) {
                $bgColor = "Black"  # Headset ADB not responding on the specified port
            }
            elseif ($headset.Temp -match '^\d' -and [int]($headset.Temp -replace ',','.') -gt 55) {
                $bgColor = "DarkRed" # Temperature > 50 degrees
            }
            elseif ($headset.Battery -and [int]($headset.Battery -replace '[^\d]','') -lt 40 -and -not (ConvertTo-BoolField $headset.Charging)) {
                $bgColor = "DarkRed" # Battery < 40% and not charging
            }
            elseif ($headset.Battery -and [int]($headset.Battery -replace '[^\d]','') -lt 30 -and (ConvertTo-BoolField $headset.Charging)) {
                $bgColor = "DarkYellow" # Battery < 30% and charging
            }
            elseif (-not (ConvertTo-BoolField $headset.Charging)) {
                $bgColor = "DarkBlue" # Headset is not charging
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
                # A released/never-set address is a placeholder, not a reachable host -
                # show it as such rather than printing a bogus 127.0.0.x at the operator.
                if ($field -eq "IPAddress" -and (Test-UnknownIp $value)) {
                    $value = $msg.Discovery.IpUnknownLabel
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





# Set-HeadsetIdentity -SerialNumber "1WMHH812345678" -IPAddress "192.168.1.243" -Source 'adb-poll'
function Set-HeadsetIdentity {
    <#
    .SYNOPSIS
    THE single serial-keyed writer for a headset's IP address. Every path that learns
    "serial S is now at address X" must go through this function.
    .DESCRIPTION
    SerialNumber is the headset's permanent identity; IPAddress is a volatile DHCP lease.
    Keying an update on the IP is what lets two headsets swap leases and silently inherit
    each other's row (battery, model, scrcpy stream, recording all follow the wrong
    headset). This function inverts that: it finds the row by serial, and if the target
    address is currently held by a DIFFERENT row, that row's address is released to an
    unknown-IP placeholder (Get-NextUnknownIp) instead of ending up duplicated.

    All mutations are computed against a single Get-KnownHeadsets read and committed with
    a single Save-Headsets, so the registry is never left half-updated. When nothing
    actually changes the function returns 'unchanged' WITHOUT saving - important because
    the VRMonitor fast path calls this on every poll and Save-Headsets regenerates every
    HTML overlay.

    Requires a serial, so it is NOT the entry point for an operator adding a headset by
    hand from an IP alone - that path stays on Add-Headset and creates a row with an empty
    serial, which is then adopted here (step 5) or by the VRMonitor learning branch.

    Returns @{ Ok; Action='added'|'updated'|'unchanged'|'skipped'; ID; Name;
               Released=@(@{ID;Name;OldIP;NewIP}); Error }.
    .EXAMPLE
    $r = Set-HeadsetIdentity -SerialNumber $serial -IPAddress $ip -Source 'usb-local'
    if ($r.Ok -and $r.Action -ne 'unchanged') { Write-Log "Healed $($r.Name)" -Level INFO }
    .EXAMPLE
    # Discovery: never create rows, just report unknown serials back to the caller
    $r = Set-HeadsetIdentity -SerialNumber $s -IPAddress $ip -Source 'lan-scan'
    if ($r.Action -eq 'skipped') { Add-PendingDiscoveredHeadset ... }
    #>
    param (
        [Parameter(Mandatory = $true)][string]$SerialNumber,
        [Parameter(Mandatory = $true)][string]$IPAddress,
        [string]$Name  = "",
        [string]$Model = "",
        [string]$Brand = "",
        [switch]$AllowAdd,
        [string]$Source = "unknown"
    )

    $result = @{ Ok = $false; Action = 'skipped'; ID = $null; Name = ""; Released = @(); Error = $null }

    $serial = ([string]$SerialNumber).Trim()
    if (-not $serial) {
        $result.Error = "SerialNumber is required"
        return $result
    }

    $ip = ([string]$IPAddress).Trim()
    if (-not (Test-ValidIPv4 -IPAddress $ip)) {
        $result.Error = "Invalid IP address '$ip'"
        return $result
    }
    # A placeholder address is an output of this function, never a valid input - accepting
    # one would let a caller "move" a headset onto loopback and lose it.
    if (Test-UnknownIp $ip) {
        $result.Error = "Refusing to assign the placeholder address '$ip'"
        return $result
    }

    $rows  = @(Get-KnownHeadsets)
    $owner = $rows | Where-Object { $_.SerialNumber -and ([string]$_.SerialNumber).Trim() -eq $serial } | Select-Object -First 1

    # Rows sitting on the target address that are not the legitimate owner.
    $squatters = @($rows | Where-Object {
        $_.IPAddress -and ([string]$_.IPAddress).Trim() -eq $ip -and -not ($owner -and $_.ID -eq $owner.ID)
    })

    $changed   = $false
    $released  = @()
    $isNewRow  = $false

    if (-not $owner) {
        if (-not $AllowAdd) {
            # Caller (typically LAN discovery) decides what to do with an unknown headset.
            Write-Log ($msg.Discovery.IdentityUnknownSerial -f $serial, $ip, $Source) -Level DEBUG
            return $result
        }

        # Adoption: a serial-less row already claims this address - almost always a row the
        # operator created by hand from an IP alone. Stamp the serial onto it rather than
        # creating a second row for the same physical headset.
        $adoptable = $squatters | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.SerialNumber) } | Select-Object -First 1
        if ($adoptable) {
            $owner = $adoptable
            $squatters = @($squatters | Where-Object { $_.ID -ne $adoptable.ID })
            $owner.SerialNumber = $serial
            # Stamping the serial IS a change even when the address already matches -
            # without this the function would report 'unchanged' and never save it.
            $changed = $true
            Write-Log ($msg.Discovery.IdentityAdopted -f $owner.Name, $serial, $ip, $Source) -Level SUCCESS
        }
        else {
            $isNewRow = $true
        }
    }

    # Free the address before assigning it, so the registry never holds a duplicate IP.
    foreach ($squatter in $squatters) {
        $oldIp = [string]$squatter.IPAddress
        $newIp = Get-NextUnknownIp -Rows $rows
        $squatter.IPAddress = $newIp
        $released += @{ ID = $squatter.ID; Name = $squatter.Name; OldIP = $oldIp; NewIP = $newIp }
        $changed = $true
        Write-Log ($msg.Discovery.IdentityReleased -f $squatter.Name, $oldIp, $serial, $Source) -Level WARNING
    }

    if ($isNewRow) {
        $safeName = if ($Name) { $Name } elseif ($Model) { $Model } else { "Headset $serial" }
        Add-Headset -headsets $rows -IPAddress $ip -Name $safeName -Model $Model -SerialNumber $serial

        # Add-Headset saves on its own; re-read to confirm the row exists and pick up its ID.
        $added = @(Get-KnownHeadsets) | Where-Object { ([string]$_.SerialNumber).Trim() -eq $serial } | Select-Object -First 1
        if (-not $added) {
            $result.Error = "Failed to add headset for serial '$serial'"
            return $result
        }
        if ($Brand) { Update-HeadsetField -Field 'Brand' -ID ([int]$added.ID) -NewValue $Brand }

        $result.Ok       = $true
        $result.Action   = 'added'
        $result.ID       = [int]$added.ID
        $result.Name     = $added.Name
        $result.Released = $released
        return $result
    }

    $oldOwnerIp = [string]$owner.IPAddress
    if ($oldOwnerIp -ne $ip) {
        $owner.IPAddress = $ip
        $changed = $true
        Write-Log ($msg.Discovery.IdentityMoved -f $owner.Name, $oldOwnerIp, $ip, $Source) -Level SUCCESS
    }

    # Model/Brand are merged opportunistically - only overwrite with a real value.
    if ($Model -and $Model -ne "-" -and $Model -ne $owner.Model) {
        $owner.Model = $Model
        $changed = $true
    }
    if ($Brand) {
        $currentBrand = if ($owner.PSObject.Properties['Brand']) { [string]$owner.Brand } else { "" }
        if ($Brand -ne $currentBrand) {
            if (-not $owner.PSObject.Properties['Brand']) {
                $owner | Add-Member -MemberType NoteProperty -Name Brand -Value $Brand -Force
            } else {
                $owner.Brand = $Brand
            }
            $changed = $true
        }
    }

    $result.Ok       = $true
    $result.ID       = [int]$owner.ID
    $result.Name     = $owner.Name
    $result.Released = $released

    if (-not $changed) {
        # No write, no HTML regeneration - this is the common case on a steady-state poll.
        $result.Action = 'unchanged'
        return $result
    }

    Save-Headsets -headsets $rows
    $result.Action = 'updated'
    return $result
} # OK

#Add-Headset -IPAddress "192.168.1.223" -Name "Q3 Manu"
function Add-Headset {
    param (
        [array]$headsets = (Get-KnownHeadsets),  # Default value: CSV file
        [Parameter(Mandatory = $true)][string]$IPAddress,
        [string]$Name         = "New headset",
        [string]$Model        = "",
        [string]$SerialNumber = ""
        #[int]$AdbPort = 5555
    )

    #Check if a headset with the same @IP does not already exist
    if ( $headsets.IPAddress -contains $IPAddress){
        Write-Log ($msg.HeadsetIpExists -f $IPAddress) -Level WARNING
        return
    }

    # A serial is a permanent identity: never create a second row for a headset we already
    # know. Callers that legitimately want "add or move" must use Set-HeadsetIdentity.
    if ($SerialNumber) {
        $serialTrim = ([string]$SerialNumber).Trim()
        $existing = $headsets | Where-Object { ([string]$_.SerialNumber).Trim() -eq $serialTrim } | Select-Object -First 1
        if ($existing) {
            Write-Log ($msg.HeadsetSerialExists -f $serialTrim, $existing.Name) -Level WARNING
            return
        }
    }

    # Add a new headset to the list
    # ID is a permanent identity, never a position - assign the next unused value
    # so it stays unique even after removals leave gaps.
    $nextID = 1
    if ($headsets.Count -gt 0) {
        $nextID = (($headsets | ForEach-Object { [int]$_.ID } | Measure-Object -Maximum).Maximum) + 1
    }
    $newHeadset = [PSCustomObject]@{
        ID          = $nextID
        Name         = $Name
        IPAddress    = $IPAddress
        scrcpy_AutoRestart = "True"
        Record       = "False"
        ScrcpyProfile = "square-R-N-45-20"
        Brand        = ""
        Model        = $Model
        SerialNumber = $SerialNumber
        #AdbPort      = $AdbPort
    }

    # Add to the headset list
    $headsets += $newHeadset

    Write-Log ($msg.HeadsetAdding -f $Name, $IPAddress) -Level INFO

    # Save to the CSV file
    Save-Headsets -headsets $headsets

    # Copy default favorites template to the new headset's favorites file
    $safeName        = $Name -replace ' ','_'
    $templateFavPath = Join-Path $global:ScriptPath "templates\data\default_favorite_apps.csv"
    $newFavPath      = Join-Path $global:ScriptPath "data\${safeName}_favorite_apps.csv"
    if ((Test-Path -LiteralPath $templateFavPath) -and -not (Test-Path -LiteralPath $newFavPath)) {
        Copy-Item -LiteralPath $templateFavPath -Destination $newFavPath
    }
} # OK

# Update-HeadsetField -ID ([int]"1") -Field "SerialNumber" -NewValue "ABC123"
function Update-HeadsetField {
    param (
        [array]$headsets = (Get-KnownHeadsets),  # Default value: CSV file
        [int]$ID,
        [string]$Field,
        [string]$NewValue
    )

    $headset = $headsets | Where-Object { $_.ID -eq $ID }

    if (-not $headset) {
        Write-Log ($msg.HeadsetIdNotFound -f $ID) -Level ERROR
        return
    }
    if ($headset.PSObject.Properties.Name -notcontains $Field) {
        Write-Log ($msg.HeadsetFieldNotExist -f $Field) -Level ERROR
        return
    }

    $headset.$Field = $NewValue
    Write-Log ($msg.HeadsetFieldUpdated -f $Field, $ID, $NewValue) -Level INFO

    # Save only on success. Save-Headsets rewrites the CSV and regenerates every HTML
    # overlay, so a failed lookup must not pay that cost (nor risk rewriting the registry
    # from a stale in-memory copy).
    Save-Headsets -headsets $headsets
    #return $headsets
} # OK

# Set-HeadsetBySerial -SerialNumber "1WMHH812345678" -IPAddress "192.168.1.243" -Name "Q3 Blue" -Model "Quest 3"
function Set-HeadsetBySerial {
    <#
    .SYNOPSIS
    Adds a new headset, or updates an existing one's IP address, keyed by SerialNumber.
    .DESCRIPTION
    Shared by the web server's /api/headsets/register-by-serial route (used by the
    remote Headset Toolbox, website\headset-toolbox\Enable-HeadsetWifiAdb.ps1) and
    the console's equivalent "register by serial" option, so a headset plugged into
    the server itself or into a technician's remote PC goes through the same
    add-or-update logic.

    - If a headset with this SerialNumber is already known, only its IPAddress is
      updated (when it changed) - Name/Model are left untouched.
    - If not known, a new headset is added.

    This is now a thin wrapper over Set-HeadsetIdentity -AllowAdd, so it inherits the
    IP-conflict handling: when another row already holds the target address, that row's
    address is released to an unknown-IP placeholder instead of the add silently failing.
    The return shape is kept for its existing callers.

    Returns @{ Ok; Action='added'|'updated'; ID; Name; Error }.
    #>
    param (
        [Parameter(Mandatory = $true)][string]$SerialNumber,
        [Parameter(Mandatory = $true)][string]$IPAddress,
        [string]$Name  = "",
        [string]$Model = "",
        [string]$Brand = "",
        [string]$Source = "register-by-serial"
    )

    $r = Set-HeadsetIdentity -SerialNumber $SerialNumber -IPAddress $IPAddress `
                             -Name $Name -Model $Model -Brand $Brand -AllowAdd -Source $Source

    if (-not $r.Ok) {
        return @{ Ok = $false; Error = $r.Error }
    }
    # Callers only distinguish "created a row" from "kept the existing one"; a no-op
    # update is reported as 'updated' so their messaging stays unchanged.
    $action = if ($r.Action -eq 'added') { 'added' } else { 'updated' }
    return @{ Ok = $true; Action = $action; ID = $r.ID; Name = $r.Name }
} # OK

# Rename-Headset -OldName "Q3 BLUE" -NewName "Q3 Blue Lab"
function Rename-Headset {
    param (
        [Parameter(Mandatory=$true)][string]$OldName,
        [Parameter(Mandatory=$true)][string]$NewName,
        [array]$headsets = (Get-KnownHeadsets)
    )

    $headset = $headsets | Where-Object { $_.Name -eq $OldName }
    if (-not $headset) {
        Write-Log ($msg.HeadsetIdNotFound -f $OldName) -Level ERROR
        return $false
    }

    $oldDisplayName = Convert-Displayname $OldName
    $newDisplayName = Convert-Displayname $NewName

    # 1. Gracefully close the running scrcpy window for this headset (if any)
    $scrcpyProc = Get-ScrcpyProcess -displayName $oldDisplayName
    if ($scrcpyProc) {
        Write-Log ("Closing scrcpy window for '$oldDisplayName' before rename...") -Level INFO
        $closed = $scrcpyProc.CloseMainWindow()
        if ($closed) { $scrcpyProc.WaitForExit(5000) | Out-Null }
        if (-not $scrcpyProc.HasExited) {
            Stop-Process -Id $scrcpyProc.Id -Force -ErrorAction SilentlyContinue
        }
        Write-Log ("scrcpy closed for '$oldDisplayName'.") -Level INFO
    }

    # 2. Rename in the headsets list and save (triggers Write-htmlMonitor)
    $headset.Name = $NewName
    Save-Headsets -headsets $headsets
    Write-Log ("Headset renamed: '$OldName' -> '$NewName'") -Level INFO

    # 3. Delete old per-headset HTML files (monitoring + video)
    $websiteDir = Join-Path $global:ScriptPath "website\generated"
    foreach ($suffix in @('[monitoring].html', '[video].html', '[timer].html')) {
        $oldFile = Join-Path $websiteDir ($oldDisplayName + $suffix)
        if (Test-Path -LiteralPath $oldFile) {
            Remove-Item -LiteralPath $oldFile -Force -ErrorAction SilentlyContinue
            Write-Log ("Deleted old HTML: $oldFile") -Level DEBUG
        }
    }

    # 4. Regenerate [video].html for the new name
    $renamedRow = $headsets | Where-Object { $_.Name -eq $NewName }
    if ($renamedRow) {
        Update-HeadsetVideoFile
        Update-HeadsetTimerFile
        Write-Log ("Regenerated [video].html and [timer].html for '$newDisplayName'.") -Level DEBUG
    }

    # 5. Rename data files (installed_apps + favorites) if they exist
    foreach ($suffix in @('_installed_apps.csv', '_favorite_apps.csv')) {
        $oldDataFile = Join-Path $global:ScriptPath "data\$oldDisplayName$suffix"
        $newDataFile = Join-Path $global:ScriptPath "data\$newDisplayName$suffix"
        if (Test-Path $oldDataFile) {
            Rename-Item -LiteralPath $oldDataFile -NewName (Split-Path $newDataFile -Leaf) -Force -ErrorAction SilentlyContinue
            Write-Log ("Renamed data file: $oldDataFile -> $newDataFile") -Level DEBUG
        }
    }

    return $true
} # OK

function Remove-Headset {
    param (
        [array]$headsets = (Get-KnownHeadsets),
        [int]$ID
    )

    # Find the headset with the specified ID
    $headsetToRemove = $headsets | Where-Object { $_.ID -eq $ID }

    # Gracefully close the running scrcpy window for this headset (if any)
    $scrcpyProc = Get-ScrcpyProcess -displayName $headsetToRemove
    if ($scrcpyProc) {
        Write-Log ("Closing scrcpy window for '$headsetToRemove' before rename...") -Level INFO
        $closed = $scrcpyProc.CloseMainWindow()
        if ($closed) { $scrcpyProc.WaitForExit(5000) | Out-Null }
        if (-not $scrcpyProc.HasExited) {
            Stop-Process -Id $scrcpyProc.Id -Force -ErrorAction SilentlyContinue
        }
        Write-Log ("scrcpy closed for '$headsetToRemove'.") -Level INFO
    }


    if ($headsetToRemove) {
        # Remove the headset from the list
        $headsets = @($headsets | Where-Object { $_.ID -ne $ID })
        Write-Log ($msg.HeadsetRemoved -f $ID, $headsetToRemove.Name) -Level INFO
        # Delete the installed apps cache file for this headset
        $cachePath = Join-Path $global:ScriptPath "data\$(Convert-Displayname $headsetToRemove.Name)_installed_apps.csv"
        if (Test-Path $cachePath) {
            Remove-Item $cachePath -Force -ErrorAction SilentlyContinue
            Write-Log ("Deleted installed apps cache: $cachePath") -Level DEBUG
        }
        # Delete the per-headset favorites file
        $favPath = Join-Path $global:ScriptPath "data\$(Convert-Displayname $headsetToRemove.Name)_favorite_apps.csv"
        if (Test-Path $favPath) {
            Remove-Item $favPath -Force -ErrorAction SilentlyContinue
            Write-Log ("Deleted favorites cache: $favPath") -Level DEBUG
        }
        # Stop timer job and delete timer files (.txt and .run)
        Stop-HeadsetTimer -headsetId ([int]$headsetToRemove.ID)
        $timerTxt = Get-TimerFilePath    -headsetId ([int]$headsetToRemove.ID)
        $timerRun = Get-TimerRunFilePath -headsetId ([int]$headsetToRemove.ID)
        foreach ($f in @($timerTxt, $timerRun)) {
            if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
        }
        # Delete generated monitoring, video and timer HTML overlays
        foreach ($kind in @('monitoring', 'video', 'timer')) {
            $htmlPath = Get-HeadsetSitePath -Name $headsetToRemove.Name -Kind $kind
            if (Test-Path -LiteralPath $htmlPath) { Remove-Item -LiteralPath $htmlPath -Force -ErrorAction SilentlyContinue }
        }
        # Remove headset row from timer.csv
        $timerCsv = Join-Path $global:ScriptPath "data\timer.csv"
        if (Test-Path -LiteralPath $timerCsv) {
            $rows = @(@(Import-Csv -LiteralPath $timerCsv) | Where-Object { [int]$_.HeadsetID -ne [int]$headsetToRemove.ID })
            if ($rows.Count -gt 0) {
                $rows | Export-Csv -LiteralPath $timerCsv -NoTypeInformation -Encoding UTF8 -Force
            } else {
                Set-Content -LiteralPath $timerCsv -Value '"HeadsetID","Minutes","Seconds","Mode"' -Encoding UTF8
            }
        }
    } else {
        Write-Log ($msg.HeadsetIdNotFound -f $ID) -Level ERROR
    }
    # Save changes to the CSV file
    Save-Headsets -headsets $headsets
    #return $headsets
} #OK

function Save-Headsets {
    param (
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$headsets,
        [string]$FilePath = $global:knownHeadsetsFilePath 
    )

    # ID is a permanent identity, not a position: preserve the caller's array order
    # (that order IS the display order, e.g. after a drag-and-drop reorder) and only
    # assign an ID to rows that don't already have one (back-compat for legacy rows).
    $newHeadsets = @($headsets)
    $maxID = 0
    foreach ($headset in $newHeadsets) {
        $idVal = 0
        if ([int]::TryParse([string]$headset.ID, [ref]$idVal) -and $idVal -gt $maxID) { $maxID = $idVal }
    }
    foreach ($headset in $newHeadsets) {
        $idVal = 0
        if (-not [int]::TryParse([string]$headset.ID, [ref]$idVal) -or $idVal -le 0) {
            $maxID++
            $headset.ID = $maxID
        }
    }

    # Save to the CSV file
    if ($newHeadsets.Count -eq 0) {
        Set-Content -LiteralPath $FilePath -Value '"ID","Name","IPAddress","scrcpy_AutoRestart","Record","ScrcpyProfile","Brand","Model","SerialNumber"' -Encoding UTF8
    } else {
        # Ensure every row has a Brand column before export so the union of
        # properties (used by Export-Csv) includes Brand.
        foreach ($row in $newHeadsets) {
            if (-not $row.PSObject.Properties['Brand']) {
                $row | Add-Member -MemberType NoteProperty -Name Brand -Value "" -Force
            }
        }
        $newHeadsets | Export-Csv -LiteralPath $FilePath -NoTypeInformation -Encoding UTF8
    }
    Write-Log ($msg.HeadsetsSaved -f $FilePath) -Level INFO
    Write-htmlMonitor $newHeadsets
    Update-HeadsetMonitoringFile
    Update-HeadsetVideoFile
    Update-HeadsetTimerFile
    # Create timer files for any newly added headsets (non-destructive: skips existing files)
    Initialize-TimerFiles
} #OK


function Set-HeadsetsOrder {
    <#
    .SYNOPSIS
    Reorders the headset registry to match the given list of display names.
    Unlisted headsets are appended at the end. Triggers HTML monitor regeneration.
    #>
    param (
        [Parameter(Mandatory=$true)][string[]]$OrderedDisplayNames,
        [array]$headsets = (Get-KnownHeadsets)
    )

    # Build lookup: display name (spaces->underscores) -> row
    $lookup = [ordered]@{}
    foreach ($row in $headsets) {
        $dn = $row.Name -replace ' ', '_'
        $lookup[$dn] = $row
    }

    # Build ordered list: requested names first, then any unlisted remainder
    $ordered = @()
    foreach ($dn in $OrderedDisplayNames) {
        if ($lookup.Contains($dn)) { $ordered += $lookup[$dn]; $lookup.Remove($dn) }
    }
    foreach ($remaining in $lookup.Values) { $ordered += $remaining }

    # IDs are permanent identities and are left untouched here - Save-Headsets now
    # persists rows in the exact array order given, which is this reordered sequence.
    Save-Headsets -headsets $ordered
    Write-Log ("Headsets reordered: " + ($OrderedDisplayNames -join ', ')) -Level INFO
} #OK



