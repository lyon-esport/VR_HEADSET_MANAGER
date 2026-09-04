#################
# MANAGE KNOWN KIOSK SCREENS FILE
#################

# Function to retrieve kiosk screens from the CSV file
# Example usage:
# $kiosks = Get-KnownKiosks
function Get-KnownKiosks {
    param (
        [string]$knownKiosksFilePath = $global:knownKiosksFilePath
    )

    # Check whether the global variable $knownKiosksFilePath is defined
    if (-not $knownKiosksFilePath) {
        Write-Log "Get-KnownKiosks: knownKiosksFilePath is not set." -Level "ERROR"
        return
    }

    # Check whether the file exists
    if (-not (Test-Path -LiteralPath $knownKiosksFilePath)) {
        Write-Log "Get-KnownKiosks: kiosk CSV file not found at $knownKiosksFilePath" -Level "ERROR"
        return
    }

    # Read the CSV file and return data as PowerShell objects
    try {
        $kiosks = @(Import-Csv -LiteralPath $knownKiosksFilePath -Encoding UTF8)
        return $kiosks
    }
    catch {
        Write-Log "Get-KnownKiosks: failed to read kiosk CSV file." -Level "ERROR"
    }
} # OK


# Add-Kiosk -IPAddress "192.168.1.230"
function Add-Kiosk {
    param (
        [array]$kiosks = (Get-KnownKiosks),  # Default value: CSV file
        [Parameter(Mandatory = $true)][string]$IPAddress,
        [string]$Name = "",
        [int]$Port = 9222
    )

    # Check if a kiosk with the same IP does not already exist
    if ($kiosks.IPAddress -contains $IPAddress) {
        Write-Log "Add-Kiosk: a kiosk with IP $IPAddress already exists." -Level "WARNING"
        return
    }

    # Default Name to the IP address when not provided (deliberate product decision)
    if ([string]::IsNullOrWhiteSpace($Name)) {
        $Name = $IPAddress
    }

    # Add a new kiosk to the list
    $newKiosk = [PSCustomObject]@{
        ID           = ($kiosks | Measure-Object).Count + 1
        Name         = $Name
        IPAddress    = $IPAddress
        Port         = $Port
        PushedURL    = ""
        LastPushedAt = ""
    }

    # Add to the kiosk list
    $kiosks += $newKiosk

    Write-Log "Add-Kiosk: adding kiosk '$Name' ($IPAddress)." -Level "INFO"

    # Save to the CSV file
    Save-Kiosks -kiosks $kiosks
} # OK


# Update-KioskField -ID 1 -Field "Name" -NewValue "Lobby screen"
function Update-KioskField {
    param (
        [array]$kiosks = (Get-KnownKiosks),  # Default value: CSV file
        [int]$ID,
        [string]$Field,
        [string]$NewValue
    )

    $kiosk = $kiosks | Where-Object { $_.ID -eq $ID }

    if ($kiosk) {
        if ($kiosk.PSObject.Properties.Name -contains $Field) {
            $kiosk.$Field = $NewValue
            Write-Log "Update-KioskField: field '$Field' updated for kiosk ID $ID to '$NewValue'." -Level "INFO"
        } else {
            Write-Log "Update-KioskField: field '$Field' does not exist on kiosk objects." -Level "ERROR"
        }
    } else {
        Write-Log "Update-KioskField: kiosk ID $ID not found." -Level "ERROR"
    }

    # Save changes to the CSV file
    Save-Kiosks -kiosks $kiosks
} # OK


# Remove-Kiosk -ID 1
function Remove-Kiosk {
    param (
        [array]$kiosks = (Get-KnownKiosks),
        [int]$ID
    )

    $kioskToRemove = $kiosks | Where-Object { $_.ID -eq $ID }

    if ($kioskToRemove) {
        $kiosks = @($kiosks | Where-Object { $_.ID -ne $ID })
        Write-Log "Remove-Kiosk: removed kiosk ID $ID ($($kioskToRemove.Name))." -Level "INFO"

        # If this kiosk has ever sent an advanced-agent report, denylist its IP so a
        # still-running agent does not silently re-add it on its next heartbeat
        # (see Register-KioskFromAgentReport / Add-KioskAutoAddIgnore in kiosk_functions.ps1).
        # Kiosks that were only ever added manually have no agent history and need no entry.
        if ((Get-Command Get-KioskAgentInfo -ErrorAction SilentlyContinue) -and (Get-Command Add-KioskAutoAddIgnore -ErrorAction SilentlyContinue)) {
            $agent = Get-KioskAgentInfo -IPAddress $kioskToRemove.IPAddress
            if ($agent) {
                Add-KioskAutoAddIgnore -IPAddress $kioskToRemove.IPAddress
            }
        }
    } else {
        Write-Log "Remove-Kiosk: kiosk ID $ID not found." -Level "ERROR"
    }

    # Save changes to the CSV file
    Save-Kiosks -kiosks $kiosks
} # OK


function Save-Kiosks {
    param (
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$kiosks,
        [string]$FilePath = $global:knownKiosksFilePath
    )

    # Reassign IDs starting from 1
    $newKiosks = @($kiosks | Sort-Object ID)
    $newID = 1
    foreach ($kiosk in $newKiosks) {
        $kiosk.ID = $newID
        $newID++
    }

    # Save to the CSV file as UTF-8 without BOM.
    if ($newKiosks.Count -eq 0) {
        $csvContent = '"ID","Name","IPAddress","Port","PushedURL","LastPushedAt"'
    } else {
        $csvContent = ($newKiosks | Select-Object ID, Name, IPAddress, Port, PushedURL, LastPushedAt | ConvertTo-Csv -NoTypeInformation) -join [Environment]::NewLine
    }
    if (Get-Command Write-FileWithoutBom -ErrorAction SilentlyContinue) {
        Write-FileWithoutBom -Path $FilePath -Content ($csvContent + [Environment]::NewLine)
    } else {
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText($FilePath, ($csvContent + [Environment]::NewLine), $utf8NoBom)
    }
    Write-Log "Save-Kiosks: kiosk list saved to $FilePath." -Level "INFO"
} #OK
