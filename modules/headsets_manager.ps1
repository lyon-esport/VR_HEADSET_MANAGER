#################
# MANAGE KNOWN HEADSET FILE
#################

# Function to retrieve VR headsets from the CSV file
# Example usage of the Get-KnownHeadsets function
# $headsets=Get-KnownHeadsets
function Get-KnownHeadsets {
    param (
        # Accepted and ignored: kept so existing callers keep compiling. The CSV
        # is no longer the source of truth. No default value: referencing a
        # $global: that may not be set throws under Set-StrictMode, and nothing
        # reads this.
        [string]$knownHeadsetsFilePath
    )

    # Rows come back in display order (sort_order, then id) with the legacy
    # column names, ID as TEXT and the booleans as the strings "True"/"False",
    # so every caller keeps the shape Import-Csv used to give it.
    #
    # The Brand back-fill the CSV version did is gone: the column always exists
    # now, and the legacy importer applies the same Model-based guess once,
    # during the migration, rather than on every read forever.
    try {
        return @(Invoke-DbQuery -Name 'headsets.list')
    }
    catch {
        Write-Log -Message $msg.HeadsetCsvReadError -Level "ERROR"
        return @()
    }
} # OK


<#
.SYNOPSIS
    Resolve a headset display name to its permanent id. Returns 0 when unknown.
.DESCRIPTION
    The app-related functions all take a -headsetName, because in the CSV era the
    name WAS the storage key: data\<Name>_installed_apps.csv. The tables are keyed
    on the permanent id instead, so every one of those call sites needs this
    translation.

    It has to accept two spellings of the same headset. The console passes the
    real name with spaces ("Q3 RED"); the web server passes the already
    underscore-converted form ("Q3_RED") because that is what it built the
    filename from. Both produced the same file, so the difference never mattered
    before - Convert-Displayname is idempotent. Against the database it does
    matter, and a silent 0 here would empty a headset's app list in the web UI
    while the console kept working. So: try the name as given, then retry with
    underscores read back as spaces.

    A name that matches nothing returns 0 rather than throwing; callers treat
    that as "no rows", exactly as a missing CSV file used to behave.
.EXAMPLE
    $id = Resolve-HeadsetIdByName -Name 'Q3_RED'
#>
function Resolve-HeadsetIdByName {
    param (
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) { return 0 }

    # Underscores back to spaces for the second attempt. Skipped when the name
    # holds no underscore, so the common case is a single query.
    $candidates = @($Name)
    if ($Name -like '*_*') { $candidates += ($Name -replace '_', ' ') }

    foreach ($candidate in $candidates) {
        try {
            $row = @(Invoke-DbQuery -Name 'headsets.get_by_name' -Parameters @{ name = [string]$candidate })
            if ($row.Count -gt 0) {
                $id = 0
                if ([int]::TryParse([string]$row[0].ID, [ref]$id) -and $id -gt 0) {
                    # Add-Headset and Rename-Headset both refuse a duplicate name,
                    # so this should be impossible. If it happens anyway - a
                    # registry that predates those guards - say so loudly rather
                    # than silently attaching this headset's apps to another row.
                    if ($row.Count -gt 1) {
                        Write-Log ((Get-MessageString -Key 'Headset.NameAmbiguous') -f $candidate, $id) -Level WARNING
                    }
                    return $id
                }
            }
        }
        catch {
            Write-Log ("Resolve-HeadsetIdByName failed for '{0}' - {1}" -f $candidate, $_.Exception.Message) -Level DEBUG
            return 0
        }
    }
    return 0
} # OK


# DISPLAY ALL HEADSETS
# WITH PING, ADB PORT, AND SCRCPY STREAM STATUS TESTING
#Show-HeadsetsTable -FieldsToShow @("ID", "Name", "Model", "Ping", "ADBReachable", "SCRCPY")
#$FieldsToShow = "all"

#  $headset = $headsets[0]

#Show-HeadsetsTable -FieldsToShow @("ID","Name","Model","IPAddress","Ping","ADBWifi")

function Get-HeadsetInfosMerged {
    # Registry identity plus live status, joined on ID and returned in display order.
    # Status rows carry ID + live fields only (ADR-0016), so any display that wants
    # Name / IPAddress / Brand / Model / SerialNumber has to come here.
    #
    # The hand-rolled join this replaces - read the file, hashtable the registry, graft
    # five fields back on, skip rows whose headset is gone - is now one query. The INNER
    # JOIN inside v_headset_full drops the orphan rows for the same reason the old loop
    # did: a status row without a headset is not displayable.
    param (
        # Accepted and ignored: kept so existing callers keep compiling. No
        # default value on purpose - referencing a $global: that may not be set
        # throws under Set-StrictMode, and this parameter is never read.
        [string]$FilePath
    )

    try {
        return @(Invoke-DbQuery -Name 'status.merged')
    }
    catch {
        Write-Log ("Get-HeadsetInfosMerged failed - " + $_.Exception.Message) -Level ERROR
        return @()
    }
}

function Show-HeadsetsTable {
    param (
        # Vestigial, see Get-HeadsetInfosMerged. No default: an unset $global:
        # throws under strict mode and nothing reads this.
        [string]$FilePath,
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
        # Vestigial, see Get-HeadsetInfosMerged. No default: an unset $global:
        # throws under strict mode and nothing reads this.
        [array]$knownHeadsetsInfosFilePath,
        [array]$FieldsToShow = @("ID","Name","IPAddress","Ping","ADBWifi","Battery","Charging","Temp","SCRCPY","Model","SerialNumber","RunningApp"),
        [bool]$UseColors = $true
    )

    # Live status joined to the registry by ID - status rows have no identity columns.
    $knownHeadsetsInfo = @(Get-HeadsetInfosMerged)
    # Check whether data is present
    if (-not $knownHeadsetsInfo -or $knownHeadsetsInfo.Count -eq 0) {
        Write-Log ($msg.NoHeadsetInInfosFile -f $global:databaseFilePath) -Level DEBUG
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

    # Both guards ask the table rather than the caller's snapshot. That snapshot
    # can be stale - the monitor job, the web server and the console all add
    # headsets - and `$headsets.IPAddress` throws under strict mode when the
    # registry is empty, because the property exists on no element.
    if ([int](Invoke-DbScalar -Name 'headsets.exists_ip' -Parameters @{ ip_address = $IPAddress }) -gt 0) {
        Write-Log ($msg.HeadsetIpExists -f $IPAddress) -Level WARNING
        return
    }

    # A serial is a permanent identity: never create a second row for a headset we already
    # know. Callers that legitimately want "add or move" must use Set-HeadsetIdentity.
    if ($SerialNumber) {
        $serialTrim = ([string]$SerialNumber).Trim()
        $existing = @(Invoke-DbQuery -Name 'headsets.get_by_serial' -Parameters @{ serial_number = $serialTrim }) | Select-Object -First 1
        if ($existing) {
            Write-Log ($msg.HeadsetSerialExists -f $serialTrim, $existing.Name) -Level WARNING
            return
        }
    }

    # The name has to be unique, because it is a lookup key. Every apps,
    # favourites and installed-apps call resolves a headset through
    # Resolve-HeadsetIdByName, which can only return one row - so a second
    # headset with the same name would silently share the first one's app data.
    # The CSV era had the same defect for the same reason (both wrote
    # data\<Name>_installed_apps.csv); it is guarded here rather than with a
    # UNIQUE index so an existing registry that already holds duplicates still
    # opens, and can be corrected by renaming.
    $nameTrim = ([string]$Name).Trim()
    if ($nameTrim) {
        $sameName = @(Invoke-DbQuery -Name 'headsets.get_by_name' -Parameters @{ name = $nameTrim }) | Select-Object -First 1
        if ($sameName) {
            Write-Log ((Get-MessageString -Key 'Headset.NameExists') -f $nameTrim, $sameName.ID) -Level WARNING
            return
        }
    }

    # Add a new headset to the list
    # ID is a permanent identity, never a position - assign the next unused value
    # so it stays unique even after removals leave gaps.
    $headsets = @(Get-KnownHeadsets)
    $nextID   = [int](Invoke-DbScalar -Name 'headsets.next_id')
    $newHeadset = [PSCustomObject]@{
        ID          = $nextID
        Name         = $Name
        IPAddress    = $IPAddress
        scrcpy_AutoRestart = "True"
        Record       = "False"
        ScrcpyProfile = "square-R-N-45-10"
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

    # Seed the new headset's favourites from the shipped template. The template
    # stays a FILE on purpose (templates\data\, operator-editable, shipped); only
    # the per-headset copy of it moved into the database. Save-Headsets above has
    # already created the row, so the id exists to attach the favourites to.
    Initialize-HeadsetFavorites -headsetName $Name
} # OK


<#
.SYNOPSIS
    Seed one headset's favourites from templates\data\default_favorite_apps.csv.
.DESCRIPTION
    Replaces the file copy Add-Headset used to do. Only seeds a headset that has
    no favourites yet, which is what "and the destination file does not exist"
    meant before - re-running it never overwrites an operator's choices.
.EXAMPLE
    Initialize-HeadsetFavorites -headsetName 'Q3 RED'
#>
function Initialize-HeadsetFavorites {
    param (
        [Parameter(Mandatory = $true)][string]$headsetName
    )

    $headsetId = Resolve-HeadsetIdByName -Name $headsetName
    if ($headsetId -le 0) {
        Write-Log ("Initialize-HeadsetFavorites: no headset named '{0}'" -f $headsetName) -Level DEBUG
        return
    }

    try {
        if (@(Invoke-DbQuery -Name 'favorites.list' -Parameters @{ headset_id = $headsetId }).Count -gt 0) { return }
    } catch { return }

    $templateFavPath = Join-Path $global:ScriptPath "templates\data\default_favorite_apps.csv"
    if (-not (Test-Path -LiteralPath $templateFavPath)) { return }

    try {
        $rows  = @(Import-Csv -LiteralPath $templateFavPath -Delimiter "," -Encoding UTF8)
        $batch = @()
        $order = 0
        foreach ($r in $rows) {
            if (-not $r.PackageName) { continue }
            $display = ''
            if ($r.PSObject.Properties['DisplayName']) { $display = [string]$r.DisplayName }
            $batch += @{
                headset_id   = $headsetId
                package_name = [string]$r.PackageName
                display_name = $display
                sort_order   = $order
            }
            $order++
        }
        if ($batch.Count -gt 0) {
            Invoke-DbBatch -Name 'favorites.insert' -Rows $batch | Out-Null
            Write-Log ("Seeded {0} default favourites for '{1}'." -f $batch.Count, $headsetName) -Level DEBUG
        }
    }
    catch {
        Write-Log ("Initialize-HeadsetFavorites failed for '{0}' - {1}" -f $headsetName, $_.Exception.Message) -Level WARNING
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

    # Renaming ONTO an existing name would create the duplicate Add-Headset
    # refuses, with the same consequence: the two headsets would share one set of
    # installed apps and favourites, because both resolve through
    # Resolve-HeadsetIdByName and it can only return one row.
    $newTrim = ([string]$NewName).Trim()
    if ($newTrim -and $newTrim -ne ([string]$OldName).Trim()) {
        $clash = @(Invoke-DbQuery -Name 'headsets.get_by_name' -Parameters @{ name = $newTrim }) | Select-Object -First 1
        if ($clash) {
            Write-Log ((Get-MessageString -Key 'Headset.NameExists') -f $newTrim, $clash.ID) -Level WARNING
            return $false
        }
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

    # 5. Installed apps and favourites need NO work on a rename any more.
    #    They used to live in data\<Name>_installed_apps.csv and
    #    data\<Name>_favorite_apps.csv, so the name was the storage key and a
    #    rename meant renaming files - which silently lost both caches whenever
    #    the rename raced anything holding them open. The rows are keyed on the
    #    permanent headset id now, so the rename is invisible to them. This is
    #    the same argument ADR-0016 makes for the live status file.

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
        # The installed-apps cache and the favourites are removed by
        # ON DELETE CASCADE when Save-Headsets drops the headset row below, so
        # there is nothing to delete here any more. Doing it explicitly would
        # also be wrong: it would run before the row is gone.
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
        # The timer row, the live status row and (once apps move) the per-headset
        # app rows are removed by ON DELETE CASCADE when Save-Headsets drops the
        # headset below. The CSV era had to delete each by hand, and a row was
        # missed whenever a rename had moved its file first.
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

    # One transaction: upsert every row in the caller's order (that order IS the
    # display order), then delete whatever the caller left out. Rewriting the
    # whole CSV used to give those delete semantics for free.
    try {
        $rowsToSave = $newHeadsets
        Invoke-DbTransaction -Script {
            # Rows are written one at a time, so two headsets swapping addresses
            # would trip the UNIQUE index on ip_address the moment the first is
            # written while the second still holds the value - which is exactly
            # what a DHCP lease swap looks like, and the case Set-HeadsetIdentity
            # exists to heal. Park every CHANGING address first so write order
            # stops mattering; a three-way rotation works for the same reason.
            # The parked values never leave this transaction.
            $currentIps = @{}
            foreach ($e in @(Invoke-DbQuery -Name 'headsets.list')) { $currentIps[[string]$e.ID] = [string]$e.IPAddress }
            foreach ($h in $rowsToSave) {
                $hid = [string]$h.ID
                if ($currentIps.ContainsKey($hid) -and $currentIps[$hid] -ne [string]$h.IPAddress) {
                    Invoke-DbNonQuery -Name 'headsets.park_ip' -Parameters @{ id = [int]$h.ID } | Out-Null
                }
            }

            $keptIds = @{}
            $order   = 0
            foreach ($h in $rowsToSave) {
                $brand = ''
                if ($h.PSObject.Properties['Brand']) { $brand = [string]$h.Brand }
                Invoke-DbNonQuery -Name 'headsets.upsert' -Parameters @{
                    id                  = [int]$h.ID
                    name                = [string]$h.Name
                    ip_address          = [string]$h.IPAddress
                    scrcpy_auto_restart = (ConvertTo-DbBool $h.scrcpy_AutoRestart -Default $true)
                    record              = (ConvertTo-DbBool $h.Record)
                    scrcpy_profile      = [string]$h.ScrcpyProfile
                    brand               = $brand
                    model               = [string]$h.Model
                    serial_number       = [string]$h.SerialNumber
                    sort_order          = $order
                } | Out-Null
                $keptIds[[string]$h.ID] = $true
                $order++
            }
            foreach ($existing in @(Invoke-DbQuery -Name 'headsets.list')) {
                if (-not $keptIds.ContainsKey([string]$existing.ID)) {
                    Invoke-DbNonQuery -Name 'headsets.delete' -Parameters @{ id = [int]$existing.ID } | Out-Null
                }
            }
        } | Out-Null
    } catch {
        Write-Log ("Save-Headsets: failed to persist the registry - " + $_.Exception.Message) -Level ERROR
        return
    }
    # The existing message takes a location; give it the real one.
    Write-Log ($msg.HeadsetsSaved -f $global:databaseFilePath) -Level INFO
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



