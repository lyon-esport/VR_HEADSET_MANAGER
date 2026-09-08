#################
# BACKGROUND HEADSET DISCOVERY
#
# Sweeps the LAN for devices answering on the ADB port, identifies them by serial, and
# hands each hit to Set-HeadsetIdentity so a known headset that moved to a new DHCP lease
# heals itself. A serial we do not know is never added silently: it is queued in
# data\discovered_headsets.json and proposed to the operator (web "Discovered devices"
# button, or console sub-menu), who either names and adds it, or forgets it permanently.
#
# The sweep itself runs in its own runspace (Start-HeadsetDiscoveryRunspace) because a
# full /24 scan takes ~10s and must never stall the 500ms VRMonitor loop. Results are
# handed back through $sharedState and applied by the main thread, so every registry
# write stays serialized exactly like the rest of the monitor.
#################


function Get-DiscoveredHeadsetsPath {
    <#
    .SYNOPSIS
    Path of data\discovered_headsets.json - devices seen on the LAN whose serial is not
    in known_headsets.csv, waiting for an operator decision.
    #>
    return (Join-Path $global:ScriptPath "data\discovered_headsets.json")
}


function Get-HeadsetDiscoveryIgnorePath {
    <#
    .SYNOPSIS
    Path of data\headset_discovery_ignore.json - a flat JSON array of SERIAL NUMBERS the
    operator chose to forget.
    .DESCRIPTION
    Keyed on the serial and never on the IP: a forgotten device must stay forgotten when
    DHCP moves it. Mirrors the kiosk denylist (Get-KioskAutoAddIgnorePath), and like it,
    only gates the automatic proposal path - a manual add still works.
    #>
    return (Join-Path $global:ScriptPath "data\headset_discovery_ignore.json")
}


function Read-JsonArrayFile {
    <#
    .SYNOPSIS
    Reads a JSON array file and returns it as a PowerShell array. Missing, empty or
    unparsable file returns @() - callers treat all three as "nothing recorded".
    .DESCRIPTION
    -Encoding UTF8 is mandatory: these files are written without a BOM and the project
    root contains an accented character (CLAUDE.md rule 5b).

    Note the return idiom. ConvertFrom-Json emits a JSON array as ONE Object[] rather than
    enumerating it, so the usual "@(ConvertFrom-Json $raw)" wraps that array in a SECOND
    array and every element lookup then yields Object[] instead of a record. Assigning to a
    variable first and returning that (normally, not with a leading comma) lets the pipeline
    unroll it once, so callers get what they expect from @(Read-JsonArrayFile ...). The
    @($parsed) also normalises a lone JSON object into a one-element array.
    #>
    param(
        [Parameter(Mandatory)][string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
        $parsed = ConvertFrom-Json $raw
        if ($null -eq $parsed) { return @() }
        $items = @($parsed)
        return $items
    } catch {
        Write-Log ("Read-JsonArrayFile: could not parse " + $Path + " - " + $_.Exception.Message) -Level WARNING
        return @()
    }
}


function Test-HeadsetDiscoveryIgnored {
    <#
    .SYNOPSIS
    Returns $true when -SerialNumber was forgotten by the operator.
    .EXAMPLE
    if (Test-HeadsetDiscoveryIgnored -SerialNumber $s) { continue }
    #>
    param(
        [Parameter(Mandatory)][string]$SerialNumber
    )

    $serial = ([string]$SerialNumber).Trim()
    if (-not $serial) { return $false }
    try {
        return ([int](Invoke-DbScalar -Name 'discovery_ignore.exists' -Parameters @{ serial_number = $serial }) -gt 0)
    } catch {
        Write-Log ("Test-HeadsetDiscoveryIgnored: " + $_.Exception.Message) -Level DEBUG
        return $false
    }
}


function Add-HeadsetDiscoveryIgnore {
    <#
    .SYNOPSIS
    Forgets a device permanently: adds -SerialNumber to the denylist (dedup) and drops any
    pending proposal for it, so a headset still sitting on the LAN cannot re-propose itself
    on the next sweep.
    .EXAMPLE
    Add-HeadsetDiscoveryIgnore -SerialNumber "1WMHH812345678"
    #>
    param(
        [Parameter(Mandatory)][string]$SerialNumber
    )

    $serial = ([string]$SerialNumber).Trim()
    if (-not $serial) { return $false }

    try {
        # INSERT OR IGNORE dedups on the primary key, and a trigger drops any
        # pending proposal for this serial the moment the row lands - so the
        # explicit Remove- call the file version needed is no longer required.
        Invoke-DbNonQuery -Name 'discovery_ignore.insert' -Parameters @{ serial_number = $serial } | Out-Null
        Remove-PendingDiscoveredHeadset -SerialNumber $serial | Out-Null
        Write-Log ($msg.Discovery.Forgotten -f $serial) -Level INFO
        return $true
    } catch {
        Write-Log ("Add-HeadsetDiscoveryIgnore: write failed - " + $_.Exception.Message) -Level ERROR
        return $false
    }
}


function Remove-HeadsetDiscoveryIgnore {
    <#
    .SYNOPSIS
    Un-forgets a serial. Called when the operator adds that headset by hand (USB, manual
    entry, scan): an explicit add overrides an earlier "forget".
    #>
    param(
        [Parameter(Mandatory)][string]$SerialNumber
    )

    $serial = ([string]$SerialNumber).Trim()
    if (-not $serial) { return $false }

    try {
        $removed = [int](Invoke-DbNonQuery -Name 'discovery_ignore.delete' -Parameters @{ serial_number = $serial })
        return ($removed -gt 0)
    } catch {
        Write-Log ("Remove-HeadsetDiscoveryIgnore: write failed - " + $_.Exception.Message) -Level WARNING
        return $false
    }
}


function Get-PendingDiscoveredHeadsets {
    <#
    .SYNOPSIS
    Returns the devices waiting for an operator decision, as
    @(@{SerialNumber;IPAddress;Model;Brand;FirstSeen;LastSeen}).
    .DESCRIPTION
    Self-pruning on read: an entry is dropped once its serial is known (the operator added
    it, or another path did) or once it was forgotten. Keeps the "Discovered devices"
    button from advertising work that no longer exists.
    #>
    param(
        [switch]$SkipPrune
    )

    # The view already excludes serials that have become known or been
    # forgotten, so the read is filtered by construction rather than by a
    # prune-and-rewrite pass. -SkipPrune is honoured for callers that want the
    # raw table, but the two answers now differ only for rows written before
    # the pruning triggers existed.
    try {
        if ($SkipPrune) {
            return @(Invoke-DbQuery -Name 'discovery.list_all')
        }
        Invoke-DbNonQuery -Name 'discovery.prune' | Out-Null
        return @(Invoke-DbQuery -Name 'discovery.pending')
    } catch {
        Write-Log ("Get-PendingDiscoveredHeadsets: " + $_.Exception.Message) -Level WARNING
        return @()
    }
}


function Save-PendingDiscoveredHeadsets {
    <#
    .SYNOPSIS
    Overwrites data\discovered_headsets.json with -Devices. Internal helper - callers
    normally use Add-PendingDiscoveredHeadset / Remove-PendingDiscoveredHeadset.
    #>
    param(
        [array]$Devices = @()
    )

    # Replaces the whole pending set, which is what overwriting the JSON file
    # did. Kept for compatibility; Add-/Remove- are the normal entry points.
    try {
        $rows = @($Devices)
        Invoke-DbTransaction -Script {
            Invoke-DbNonQuery -Name 'discovery.clear' | Out-Null
            foreach ($d in $rows) {
                $serial = ([string]$d.SerialNumber).Trim()
                if (-not $serial) { continue }
                Invoke-DbNonQuery -Name 'discovery.upsert' -Parameters @{
                    serial_number = $serial
                    ip_address    = [string]$d.IPAddress
                    model         = [string]$d.Model
                    brand         = [string]$d.Brand
                    first_seen    = [string]$d.FirstSeen
                    last_seen     = [string]$d.LastSeen
                } | Out-Null
            }
        } | Out-Null
        return $true
    } catch {
        Write-Log ("Save-PendingDiscoveredHeadsets: write failed - " + $_.Exception.Message) -Level ERROR
        return $false
    }
}


function Add-PendingDiscoveredHeadset {
    <#
    .SYNOPSIS
    Records one unknown device as pending, or refreshes an existing entry (IP/model/brand
    and LastSeen). Deduped by serial. Refuses forgotten serials.
    .EXAMPLE
    Add-PendingDiscoveredHeadset -SerialNumber $s -IPAddress $ip -Model "Quest 3" -Brand "Meta"
    #>
    param(
        [Parameter(Mandatory)][string]$SerialNumber,
        [Parameter(Mandatory)][string]$IPAddress,
        [string]$Model = "",
        [string]$Brand = ""
    )

    $serial = ([string]$SerialNumber).Trim()
    if (-not $serial) { return $false }
    if (Test-HeadsetDiscoveryIgnored -SerialNumber $serial) { return $false }

    $now = (Get-Date).ToString("s")
    try {
        $alreadyKnown = ([int](Invoke-DbScalar -Name 'discovery.exists' -Parameters @{ serial_number = $serial }) -gt 0)
        # ON CONFLICT keeps first_seen and refreshes the rest, so "when did we
        # first see this device" survives every later sweep.
        Invoke-DbNonQuery -Name 'discovery.upsert' -Parameters @{
            serial_number = $serial
            ip_address    = $IPAddress
            model         = $Model
            brand         = $Brand
            first_seen    = $now
            last_seen     = $now
        } | Out-Null
        # Log a genuinely new device once, not on every sweep that re-sees it.
        if (-not $alreadyKnown) {
            Write-Log ($msg.Discovery.UnknownDevice -f $serial, $Model, $IPAddress) -Level INFO
        }
        return $true
    } catch {
        Write-Log ("Add-PendingDiscoveredHeadset: " + $_.Exception.Message) -Level ERROR
        return $false
    }
}


function Remove-PendingDiscoveredHeadset {
    <#
    .SYNOPSIS
    Drops one serial from the pending list (it was added, or forgotten).
    #>
    param(
        [Parameter(Mandatory)][string]$SerialNumber
    )

    $serial = ([string]$SerialNumber).Trim()
    if (-not $serial) { return $false }
    try {
        $removed = [int](Invoke-DbNonQuery -Name 'discovery.delete' -Parameters @{ serial_number = $serial })
        return ($removed -gt 0)
    } catch {
        Write-Log ("Remove-PendingDiscoveredHeadset: " + $_.Exception.Message) -Level WARNING
        return $false
    }
}


function Test-DiscoveredHeadsetDevice {
    <#
    .SYNOPSIS
    Decides whether an ADB device that answered on the scan port is actually a VR headset.
    .DESCRIPTION
    An open port 5555 proves only that something speaks ADB - a phone, a TV box or a
    developer tablet would answer too. Accept a device only when it reports a serial AND
    its brand/model looks like a supported headset, so unrelated hardware is never
    proposed as a headset to add.
    #>
    param(
        [string]$Brand,
        [string]$Model
    )

    $probe = (([string]$Brand) + " " + ([string]$Model)).Trim()
    if (-not $probe) { return $false }
    return ($probe -match '(?i)oculus|meta|quest|pico')
}


function Invoke-HeadsetNetworkSweep {
    <#
    .SYNOPSIS
    Scans the local private network(s) for VR headsets exposing the ADB port and returns
    @(@{IPAddress;SerialNumber;Model;Brand;SeenAt}).
    .DESCRIPTION
    Identity comes from ADB (ro.serialno / ro.product.model / ro.product.brand), never from
    the address, so the caller can correct a headset that changed lease. Devices that are
    not headsets are dropped (see Test-DiscoveredHeadsetDevice).

    Intended to be called from the discovery runspace - a full /24 sweep takes ~10s.
    .EXAMPLE
    $found = Invoke-HeadsetNetworkSweep
    #>
    param(
        [int]$Port = $global:adbPort_default,
        [int]$Timeout = 300,
        [string]$adb = $global:adbPath
    )

    $results = @()
    if (-not (Test-Path -LiteralPath $adb)) {
        Write-Log ($msg.ADBExecutableNotFound -f $adb) -Level WARNING
        return $results
    }

    $networks = @(Get-PrivateNetworks)
    if ($networks.Count -eq 0) { return $results }

    # Prefer the interface holding the default route - that is the LAN the headsets are
    # on. Scanning every private interface would multiply the sweep duration.
    $target = @($networks | Where-Object { $_.HasDefaultGateway })
    if ($target.Count -eq 0) { $target = @($networks | Select-Object -First 1) }

    foreach ($net in $target) {
        Write-Log ($msg.Discovery.SweepStart -f $net.NetworkCIDR) -Level DEBUG
        $open = @()
        try {
            $open = @(Test-PortForCidr -CIDR $net.NetworkCIDR -Port $Port -Timeout $Timeout)
        } catch {
            Write-Log ($msg.Discovery.SweepFailed -f $_.Exception.Message) -Level WARNING
            continue
        }

        foreach ($hit in $open) {
            $ip = if ($hit.IPAddress) { $hit.IPAddress } else { $hit.hostname }
            if (-not $ip) { continue }
            if (Test-UnknownIp $ip) { continue }

            try {
                $device = Get-AdbWifiDevice -headsetIP $ip -AdbPort $Port -adb $adb
                if (-not $device) { continue }

                $serial = (Invoke-AdbCmd -Device $device -Command "shell getprop ro.serialno" -adb $adb) | Select-Object -First 1
                $model  = (Invoke-AdbCmd -Device $device -Command "shell getprop ro.product.model" -adb $adb) | Select-Object -First 1
                $brand  = (Invoke-AdbCmd -Device $device -Command "shell getprop ro.product.brand" -adb $adb) | Select-Object -First 1

                $serial = ([string]$serial).Trim()
                $model  = ([string]$model).Trim()
                $brand  = ([string]$brand).Trim()

                if (-not $serial) { continue }
                if (-not (Test-DiscoveredHeadsetDevice -Brand $brand -Model $model)) {
                    Write-Log ("Headset discovery: " + $ip + " speaks ADB but is not a headset (" + $brand + " " + $model + ") - ignored.") -Level DEBUG
                    continue
                }

                $results += @{
                    IPAddress    = $ip
                    SerialNumber = $serial
                    Model        = $model
                    Brand        = $brand
                    SeenAt       = (Get-Date).ToString("s")
                }
                Write-Log ($msg.Discovery.Found -f $serial, $model, $ip) -Level DEBUG
            } catch {
                Write-Log ("Headset discovery: probe of " + $ip + " failed - " + $_.Exception.Message) -Level DEBUG
            }
        }
    }

    return $results
}


function Update-HeadsetsFromDiscovery {
    <#
    .SYNOPSIS
    Applies one sweep's results: heals the address of every KNOWN serial, and queues every
    unknown serial as a pending proposal. Returns the number of registry rows changed.
    .DESCRIPTION
    Must run in the VRMonitor main thread - it writes the registry, and Save-Headsets is
    not concurrency-safe.
    .EXAMPLE
    $changed = Update-HeadsetsFromDiscovery -Devices $found
    #>
    param(
        [array]$Devices = @()
    )

    $changed = 0
    foreach ($device in $Devices) {
        if (-not $device -or -not $device.SerialNumber) { continue }
        try {
            # No -AllowAdd on purpose: discovery never creates inventory rows by itself.
            $r = Set-HeadsetIdentity -SerialNumber $device.SerialNumber -IPAddress $device.IPAddress `
                                     -Model $device.Model -Brand $device.Brand -Source 'lan-scan'
            if ($r.Action -eq 'skipped') {
                Add-PendingDiscoveredHeadset -SerialNumber $device.SerialNumber -IPAddress $device.IPAddress `
                                             -Model $device.Model -Brand $device.Brand | Out-Null
            }
            elseif ($r.Ok -and $r.Action -ne 'unchanged') {
                $changed++
            }
        } catch {
            Write-Log ("Update-HeadsetsFromDiscovery: " + $device.SerialNumber + " - " + $_.Exception.Message) -Level WARNING
        }
    }
    return $changed
}


function Start-HeadsetDiscoveryRunspace {
    <#
    .SYNOPSIS
    Creates and starts the persistent LAN-discovery runspace. Mirrors
    Start-HeadsetRunspace: $sharedState is injected via InitialSessionState so the
    runspace shares the same synchronized hashtable reference. Returns @{PS;Runspace;Handle}.
    .DESCRIPTION
    The runspace loops "sweep -> publish -> sleep". The stop flag is only honoured BETWEEN
    sweeps: a sweep in progress always runs to completion rather than being killed, so
    half-probed devices are never published.

    Shared state keys written here:
      _discovery_results  array of sweep hits, drained by the main loop
      _discovery_status   @{Running;LastSweepAt;LastDurationSec;Found}
    #>
    param(
        [hashtable]$sharedState,
        [string]$scriptPath,
        [string]$configFilePath,
        [scriptblock]$pollBlock
    )

    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $iss.Variables.Add([System.Management.Automation.Runspaces.SessionStateVariableEntry]::new(
        'sharedState', $sharedState, ''))
    $rs = [runspacefactory]::CreateRunspace($iss)
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $ps.AddScript($pollBlock).AddArgument($scriptPath).AddArgument($configFilePath) | Out-Null
    $handle = $ps.BeginInvoke()
    return @{ PS = $ps; Runspace = $rs; Handle = $handle }
}


function Sync-HeadsetDiscoveryRunspace {
    <#
    .SYNOPSIS
    Starts or stops the discovery runspace to match $global:HeadsetDiscovery_enabled, and
    respawns it if it died. Called from the VRMonitor slow path, so toggling the setting in
    the web config page takes effect without an application restart.
    .EXAMPLE
    Sync-HeadsetDiscoveryRunspace -registry ([ref]$discoveryRegistry) -sharedState $sharedState `
        -scriptPath $global:ScriptPath -configFilePath $global:ConfigFilePath -pollBlock $discoveryPollBlock
    #>
    param(
        [ref]$registry,
        [hashtable]$sharedState,
        [string]$scriptPath,
        [string]$configFilePath,
        [scriptblock]$pollBlock
    )

    $enabled = [bool]$global:HeadsetDiscovery_enabled
    $entry   = $registry.Value

    if (-not $enabled) {
        if ($entry) {
            # Signal and wait: the runspace only checks this between sweeps, so allow for a
            # full sweep to finish rather than tearing down mid-scan.
            $sharedState["_stop_discovery"] = $true
            $deadline = (Get-Date).AddSeconds(30)
            while (-not $entry.Handle.IsCompleted -and (Get-Date) -lt $deadline) {
                Start-Sleep -Milliseconds 500
            }
            try { $entry.PS.Dispose() }       catch {}
            try { $entry.Runspace.Dispose() } catch {}
            $registry.Value = $null
            $sharedState.Remove("_stop_discovery")
            $sharedState.Remove("_discovery_status")
            Write-Log $msg.Discovery.Disabled -Level INFO
        }
        return
    }

    if ($entry -and $entry.Handle.IsCompleted) {
        Write-Log "VRMonitor: headset discovery runspace died, restarting" -Level WARNING
        try { $entry.PS.Dispose() }       catch {}
        try { $entry.Runspace.Dispose() } catch {}
        $registry.Value = $null
        $entry = $null
    }

    if (-not $entry) {
        $sharedState.Remove("_stop_discovery")
        $registry.Value = Start-HeadsetDiscoveryRunspace -sharedState $sharedState `
            -scriptPath $scriptPath -configFilePath $configFilePath -pollBlock $pollBlock
        Write-Log ("VRMonitor: started headset discovery runspace (interval " + $global:HeadsetDiscovery_interval_sec + "s)") -Level INFO
    }
}
