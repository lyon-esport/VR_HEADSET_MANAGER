#################
# MANAGE KNOWN KIOSK SCREENS
#
# Backed by the `kiosks` table (was data\known_kiosks.csv). Every function
# keeps the signature, the return shape and the side effects it had as CSV
# code, so the console and the web routes did not have to change.
#
# ONE DELIBERATE BEHAVIOUR CHANGE: ids are PERMANENT now. Save-Kiosks used to
# resequence them 1..N on every write, using `Sort-Object ID` on values that
# Import-Csv had made strings - so with ten or more kiosks a save reordered
# the rows (1, 10, 11, 2, ...) and silently changed what every id meant. The
# web UI uses the id as its handle throughout (kiosk_screens.html reads `ID`
# 46 times), so an id that moves is a bug waiting to happen. Display order now
# lives in the `sort_order` column instead.
#################


# Retrieve every kiosk screen, in display order.
# Returns PSCustomObject rows with the legacy column names - ID, Name,
# IPAddress, Port, PushedURL, LastPushedAt - all as strings, exactly as
# Import-Csv used to hand them back.
# Example usage:
# $kiosks = Get-KnownKiosks
function Get-KnownKiosks {
    param (
        # Accepted and ignored: kept so existing callers keep compiling. The
        # CSV path is no longer the source of truth.
        [string]$knownKiosksFilePath = $global:knownKiosksFilePath
    )

    try {
        return @(Invoke-DbQuery -Name 'kiosks.list')
    }
    catch {
        Write-Log "Get-KnownKiosks: failed to read the kiosk list - $($_.Exception.Message)" -Level "ERROR"
        return @()
    }
} # OK


# Add-Kiosk -IPAddress "192.168.1.230"
function Add-Kiosk {
    param (
        # Advisory only: the duplicate check queries the table. Defaults to an
        # empty array so a caller that omits it does not pay for a wasted read.
        [array]$kiosks = @(),
        [Parameter(Mandatory = $true)][string]$IPAddress,
        [string]$Name = "",
        [int]$Port = 9222
    )

    # Check if a kiosk with the same IP does not already exist. Asked of the
    # table rather than the caller's snapshot, which may be stale - the web
    # server and the console both add kiosks, and an agent heartbeat can add
    # one at any moment.
    if ([int](Invoke-DbScalar -Name 'kiosks.exists_ip' -Parameters @{ ip_address = $IPAddress }) -gt 0) {
        Write-Log "Add-Kiosk: a kiosk with IP $IPAddress already exists." -Level "WARNING"
        return
    }

    # Default Name to the IP address when not provided (deliberate product decision)
    if ([string]::IsNullOrWhiteSpace($Name)) {
        $Name = $IPAddress
    }

    Write-Log "Add-Kiosk: adding kiosk '$Name' ($IPAddress)." -Level "INFO"

    try {
        Invoke-DbTransaction -Script {
            # max + 1, never a row count: ids are permanent, so a count would
            # collide with an existing row as soon as anything is deleted.
            $newId = [int](Invoke-DbScalar -Name 'kiosks.next_id')
            Invoke-DbNonQuery -Name 'kiosks.upsert' -Parameters @{
                id             = $newId
                name           = $Name
                ip_address     = $IPAddress
                port           = $Port
                pushed_url     = ''
                last_pushed_at = ''
                sort_order     = $newId
            } | Out-Null
        } | Out-Null
    } catch {
        Write-Log "Add-Kiosk: failed to add '$Name' ($IPAddress) - $($_.Exception.Message)" -Level "ERROR"
    }
} # OK


# Update-KioskField -ID 1 -Field "Name" -NewValue "Lobby screen"
#
# The field name reaches here straight from the request body of
# /api/kiosks/update, so it is resolved through a fixed map to a named query.
# It is never interpolated into SQL.
function Update-KioskField {
    param (
        [array]$kiosks = @(),  # advisory only, kept for the existing call signature
        [int]$ID,
        [string]$Field,
        [string]$NewValue
    )

    $setters = @{
        'Name'         = 'kiosks.set_name'
        'IPAddress'    = 'kiosks.set_ip'
        'Port'         = 'kiosks.set_port'
        'PushedURL'    = 'kiosks.set_pushed_url'
        'LastPushedAt' = 'kiosks.set_last_pushed_at'
    }

    if (-not $setters.ContainsKey($Field)) {
        Write-Log "Update-KioskField: field '$Field' does not exist on kiosk objects." -Level "ERROR"
        return
    }

    # Unlike the CSV version, a rejected update writes NOTHING. That code
    # called Save-Kiosks unconditionally, so a bogus id still rewrote the whole
    # file and resequenced every id.
    $affected = 0
    try {
        $affected = [int](Invoke-DbNonQuery -Name $setters[$Field] -Parameters @{ id = $ID; value = $NewValue })
    } catch {
        Write-Log "Update-KioskField: failed to update '$Field' for kiosk ID $ID - $($_.Exception.Message)" -Level "ERROR"
        return
    }

    if ($affected -lt 1) {
        Write-Log "Update-KioskField: kiosk ID $ID not found." -Level "ERROR"
        return
    }
    Write-Log "Update-KioskField: field '$Field' updated for kiosk ID $ID to '$NewValue'." -Level "INFO"
} # OK


# Remove-Kiosk -ID 1
function Remove-Kiosk {
    param (
        [array]$kiosks = @(),  # advisory only, kept for the existing call signature
        [int]$ID
    )

    $kioskToRemove = @(Invoke-DbQuery -Name 'kiosks.get_by_id' -Parameters @{ id = $ID }) | Select-Object -First 1
    if (-not $kioskToRemove) {
        Write-Log "Remove-Kiosk: kiosk ID $ID not found." -Level "ERROR"
        return
    }

    try {
        Invoke-DbNonQuery -Name 'kiosks.delete' -Parameters @{ id = $ID } | Out-Null
    } catch {
        Write-Log "Remove-Kiosk: failed to remove kiosk ID $ID - $($_.Exception.Message)" -Level "ERROR"
        return
    }
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
} # OK


# Persist a kiosk list in the given array order. The array order IS the display
# order, so it is written to sort_order; rows absent from the array are removed,
# which reproduces the old rewrite-the-whole-CSV semantics.
#
# Ids are NOT reassigned. See the note at the top of this file.
function Save-Kiosks {
    param (
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$kiosks,
        # Accepted and ignored: kept so existing callers keep compiling.
        [string]$FilePath = $global:knownKiosksFilePath
    )

    try {
        $rows = @($kiosks)
        Invoke-DbTransaction -Script {
            $keptIds = @{}
            $order   = 0
            foreach ($k in $rows) {
                $id = 0
                if (-not [int]::TryParse([string]$k.ID, [ref]$id) -or $id -le 0) {
                    # A row with no usable id gets the next free one, mirroring
                    # how Save-Headsets treats an id-less row.
                    $id = [int](Invoke-DbScalar -Name 'kiosks.next_id')
                }
                $port = 9222
                [void][int]::TryParse([string]$k.Port, [ref]$port)

                Invoke-DbNonQuery -Name 'kiosks.upsert' -Parameters @{
                    id             = $id
                    name           = [string]$k.Name
                    ip_address     = [string]$k.IPAddress
                    port           = $port
                    pushed_url     = [string]$k.PushedURL
                    last_pushed_at = [string]$k.LastPushedAt
                    sort_order     = $order
                } | Out-Null
                $keptIds[[string]$id] = $true
                $order++
            }

            # Anything the caller left out is deleted. Computed here rather than
            # in SQL so no id list has to be interpolated into a statement.
            foreach ($existing in @(Invoke-DbQuery -Name 'kiosks.list')) {
                if (-not $keptIds.ContainsKey([string]$existing.ID)) {
                    Invoke-DbNonQuery -Name 'kiosks.delete' -Parameters @{ id = [int]$existing.ID } | Out-Null
                }
            }
        } | Out-Null
        Write-Log "Save-Kiosks: kiosk list saved ($($rows.Count) row(s))." -Level "INFO"
    } catch {
        Write-Log "Save-Kiosks: failed to save the kiosk list - $($_.Exception.Message)" -Level "ERROR"
    }
} #OK
