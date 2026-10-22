<#
    adb_wifi_modes.ps1 - the two WiFi ADB modes of ADR-0034 (classic tcpip and ADB over TLS).

    This file holds the TLS discovery primitives (S10-1):
      - ConvertFrom-AdbMdnsServices / Get-AdbTlsServices : ONE "adb mdns services" call, parsed into
        serial-keyed endpoints. The instance name is "adb-<serial>-<rand>", so discovery yields the
        permanent identity (ADR-0016) directly - no IP matching.
      - Publish-AdbTlsEndpoints : writes the app_kv row adb_tls_endpoints (VRMonitor / discovery only).
      - Get-PublishedAdbTlsEndpoints / Find-AdbTlsEndpointBySerial : the cheap read side, memoised,
        like Get-PublishedUsbDevices (ADR-0021/0024).

    And the mode-aware resolution (S10-3): Get-AdbWifiModeOrder (enabled modes, preferred first),
    Resolve-HeadsetWifiEndpoint / Resolve-HeadsetWifiDevice (used by Resolve-HeadsetAdbDevice),
    Get-AdbWifiModeFallbackDevice (Invoke-AdbCmd's one-shot fallback to the other mode) and
    Test-HeadsetWifiAdbUp (stage 1 of the poll, TCP probes only).

    Rule (ADR-0034 rule 3): nothing on a request or poll path may spawn "adb mdns"; they read the
    published set. The TLS port changes at every adbd restart (reboot, and also every "adb tcpip",
    measured in S10-0), which is why the endpoint is published and refreshed rather than stored.
#>


function ConvertFrom-AdbMdnsServices {
    <#
    .SYNOPSIS
    Parses the text of "adb mdns services" into the _adb-tls-connect endpoints, @(@{Serial;Ip;Port;Name}).

    .DESCRIPTION
    Pure parser (no adb), so it is testable with canned text. Pairing services (_adb-tls-pairing._tcp)
    and classic ones (_adb._tcp, advertised once tcpip is on) are ignored. Duplicate lines (one per
    network interface) are collapsed on Serial + Ip + Port. Never throws; @() on empty input.

    .EXAMPLE
    ConvertFrom-AdbMdnsServices -Text (& $global:adbPath mdns services)
    #>
    param($Text)

    $out = @()
    try {
        if ($null -eq $Text) { return @() }
        $lines = if ($Text -is [array]) { @($Text) } else { @(([string]$Text) -split "`r?`n") }
        $seen = @{}
        foreach ($line in $lines) {
            if ($null -eq $line) { continue }
            $m = [regex]::Match([string]$line, '^adb-(?<serial>[A-Za-z0-9]+)-(?<rand>\S+)\s+_adb-tls-connect\._tcp\.?\s+(?<ip>\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}):(?<port>\d{1,5})')
            if (-not $m.Success) { continue }
            $port = [int]$m.Groups['port'].Value
            if ($port -lt 1 -or $port -gt 65535) { continue }
            $key = '{0}|{1}|{2}' -f $m.Groups['serial'].Value, $m.Groups['ip'].Value, $port
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            $out += [PSCustomObject]@{
                Serial = $m.Groups['serial'].Value
                Ip     = $m.Groups['ip'].Value
                Port   = $port
                Name   = ('adb-{0}-{1}' -f $m.Groups['serial'].Value, $m.Groups['rand'].Value)
            }
        }
    } catch {
        return @()
    }
    return @($out)
}


function Get-AdbTlsServices {
    <#
    .SYNOPSIS
    The headsets advertising ADB over TLS right now: ONE "adb mdns services" call, @(@{Serial;Ip;Port;Name}).

    .DESCRIPTION
    For VRMonitor / discovery only (ADR-0034 rule 3) - never call it on a request or poll path; read
    Get-PublishedAdbTlsEndpoints there. adb's mDNS backend (Openscreen) can miss an entry for one
    call while the TLS session is up (S10-0), so a caller must not treat one absence as "gone"
    (Publish-AdbTlsEndpoints keeps a missed entry until it ages out). Never throws; @() on failure.

    .EXAMPLE
    @(Get-AdbTlsServices) | Format-Table Serial, Ip, Port
    #>
    param([int]$TimeoutSeconds = 5)

    try {
        $r = Invoke-Adb -Arguments @('mdns', 'services') -TimeoutSeconds $TimeoutSeconds
        if (-not $r -or -not $r.Ok) { return @() }
        return @(ConvertFrom-AdbMdnsServices -Text $r.StdOut)
    } catch {
        return @()
    }
}


function ConvertTo-AdbTlsSeenTime {
    # Internal. Seen stamp (ISO-8601 UTC string, or a DateTime) -> UTC DateTime, $null when unreadable.
    # Windows PowerShell 5.1's ConvertFrom-Json leaves ISO dates as strings, so both shapes occur.
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    $d = [datetime]::MinValue
    if ([datetime]::TryParse([string]$Value, [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$d)) {
        return $d
    }
    return $null
}


function Get-AdbTlsStaleSec {
    # Internal. Age after which a published TLS endpoint is ignored: 3 x the discovery interval
    # (floor 30 s), so one or two missed sweeps never drop a headset that is still there.
    $interval = 60
    if ($global:HeadsetDiscovery_interval_sec -and [int]$global:HeadsetDiscovery_interval_sec -gt 0) { $interval = [int]$global:HeadsetDiscovery_interval_sec }
    return [Math]::Max(30, 3 * $interval)
}


function Get-PublishedAdbTlsEndpoints {
    <#
    .SYNOPSIS
    The TLS endpoints VRMonitor/discovery last published (app_kv row 'adb_tls_endpoints'), @(@{Serial;Ip;Port;Seen}).

    .DESCRIPTION
    One cheap scalar read, memoised per process/runspace for -MaxAgeSec (default 2), like
    Get-PublishedUsbDevices. Entries whose Seen is older than 3 x HeadsetDiscovery_interval_sec are
    dropped unless -IncludeStale. @() when none. Wrap every call in @(). Never throws.

    .EXAMPLE
    @(Get-PublishedAdbTlsEndpoints) | Where-Object Serial -eq '1WMHH8242N0366'
    #>
    param([int]$MaxAgeSec = 2, [switch]$IncludeStale)

    try {
        $now = [datetime]::UtcNow
        $list = $null
        if ($MaxAgeSec -gt 0 -and $null -ne $script:AdbTlsCache -and $script:AdbTlsCacheAt -and
            (($now - $script:AdbTlsCacheAt).TotalSeconds -lt $MaxAgeSec)) {
            $list = @($script:AdbTlsCache)
        } else {
            $list = @()
            if (Get-Command Get-DbKeyValue -ErrorAction SilentlyContinue) {
                $raw = Get-DbKeyValue -Key 'adb_tls_endpoints'
                if ($raw -is [string]) {
                    $raw = if ([string]::IsNullOrWhiteSpace($raw) -or $raw -eq 'null') { $null } else { $raw | ConvertFrom-Json }
                }
                if ($null -ne $raw) {
                    foreach ($e in @($raw)) {
                        if ($null -eq $e -or -not $e.Serial -or -not $e.Ip -or -not $e.Port) { continue }
                        $list += [PSCustomObject]@{ Serial = [string]$e.Serial; Ip = [string]$e.Ip; Port = [int]$e.Port; Seen = [string]$e.Seen }
                    }
                }
            }
            $script:AdbTlsCache   = $list
            $script:AdbTlsCacheAt = $now
        }
        if ($IncludeStale) { return @($list) }

        $staleSec = Get-AdbTlsStaleSec
        $fresh = @()
        foreach ($e in $list) {
            $t = ConvertTo-AdbTlsSeenTime -Value $e.Seen
            if ($null -ne $t -and ($now - $t).TotalSeconds -le $staleSec) { $fresh += $e }
        }
        return @($fresh)
    } catch {
        return @()
    }
}


function Find-AdbTlsEndpointBySerial {
    <#
    .SYNOPSIS
    The published TLS endpoint of one headset (@{Serial;Ip;Port;Seen}), or $null.

    .DESCRIPTION
    Lookup on Get-PublishedAdbTlsEndpoints (memoised read, stale entries excluded). When a serial
    shows up more than once (two interfaces), the most recently seen entry wins. Never throws.

    .EXAMPLE
    $ep = Find-AdbTlsEndpointBySerial -Serial '1WMHH8242N0366'; if ($ep) { '{0}:{1}' -f $ep.Ip, $ep.Port }
    #>
    param([Parameter(Mandatory = $true)][string]$Serial, [int]$MaxAgeSec = 2)

    try {
        if ([string]::IsNullOrWhiteSpace($Serial)) { return $null }
        $hits = @(Get-PublishedAdbTlsEndpoints -MaxAgeSec $MaxAgeSec | Where-Object { $_.Serial -eq $Serial })
        if ($hits.Count -eq 0) { return $null }
        return ($hits | Sort-Object -Property @{ Expression = { ConvertTo-AdbTlsSeenTime -Value $_.Seen } } -Descending | Select-Object -First 1)
    } catch {
        return $null
    }
}


function Publish-AdbTlsEndpoints {
    <#
    .SYNOPSIS
    Merges one discovery pass into the app_kv row adb_tls_endpoints and writes it when it changed.

    .DESCRIPTION
    -Endpoints is the result of Get-AdbTlsServices (@{Serial;Ip;Port}). Each one is stamped
    Seen = now and replaces the previous entry of its serial (the port moves at every adbd restart).
    A serial missing from this pass KEEPS its previous entry and Seen, and is removed only once it is
    older than 3 x HeadsetDiscovery_interval_sec: adb's mDNS can miss a live headset for one call
    (S10-0), and a single miss must not make the resolver forget it.
    Written only when the Serial/Ip/Port set differs from the last value this process wrote, or
    when that write is older than one discovery interval (keeps Seen fresh with at most one write per
    interval instead of one per call). VRMonitor / discovery are the only writers (ADR-0034 rule 3).
    -Force writes regardless. Never throws: publishing must not abort a monitor tick.
    Returns the merged set that is (now) published.

    .EXAMPLE
    Publish-AdbTlsEndpoints -Endpoints @(Get-AdbTlsServices)
    #>
    param($Endpoints, [switch]$Force)

    try {
        $now = [datetime]::UtcNow
        $nowText = $now.ToString('o')
        $staleSec = Get-AdbTlsStaleSec

        # Previous set: what this process wrote last, else what is stored (first call of a process).
        $previous = if ($null -ne $script:AdbTlsLastSet) { @($script:AdbTlsLastSet) } else { @(Get-PublishedAdbTlsEndpoints -MaxAgeSec 0 -IncludeStale) }

        $merged = [ordered]@{}
        foreach ($e in @($Endpoints)) {
            if ($null -eq $e -or -not $e.Serial -or -not $e.Ip -or -not $e.Port) { continue }
            $merged[[string]$e.Serial] = [PSCustomObject]@{ Serial = [string]$e.Serial; Ip = [string]$e.Ip; Port = [int]$e.Port; Seen = $nowText }
        }
        foreach ($p in $previous) {
            if ($null -eq $p -or -not $p.Serial -or $merged.Contains([string]$p.Serial)) { continue }
            $t = ConvertTo-AdbTlsSeenTime -Value $p.Seen
            if ($null -eq $t -or ($now - $t).TotalSeconds -gt $staleSec) { continue }
            $merged[[string]$p.Serial] = [PSCustomObject]@{ Serial = [string]$p.Serial; Ip = [string]$p.Ip; Port = [int]$p.Port; Seen = [string]$p.Seen }
        }
        $set = @($merged.Values | Sort-Object -Property Serial)

        $shape = (@($set | ForEach-Object { '{0}|{1}|{2}' -f $_.Serial, $_.Ip, $_.Port }) -join ';')
        $refreshSec = [Math]::Max(10, [int]($staleSec / 3))
        $due = (-not $script:AdbTlsLastWriteAt) -or (($now - $script:AdbTlsLastWriteAt).TotalSeconds -ge $refreshSec)
        if (-not $Force -and $shape -eq $script:AdbTlsLastShape -and -not $due) { return @($script:AdbTlsLastSet) }

        if (Get-Command Set-DbKeyValue -ErrorAction SilentlyContinue) {
            $json = ConvertTo-Json -InputObject @($set) -Compress -Depth 4
            Set-DbKeyValue -Key 'adb_tls_endpoints' -Value $json
            $script:AdbTlsLastShape   = $shape
            $script:AdbTlsLastWriteAt = $now
            $script:AdbTlsLastSet     = $set
            $script:AdbTlsCache       = $set
            $script:AdbTlsCacheAt     = $now
        }
        return @($set)
    } catch {
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log ("Publish-AdbTlsEndpoints: " + $_.Exception.Message) -Level DEBUG }
        return @()
    }
}

# ---------------------------------------------------------------------------------------------
# Mode-aware resolution (S10-3). The resolver, Invoke-AdbCmd's fallback and stage 1 of the poll
# all go through these, so "which WiFi endpoint of this headset" is answered in ONE place. TLS
# endpoints come from the published set only (rule 3): nothing here spawns "adb mdns".
# ---------------------------------------------------------------------------------------------

function Get-AdbWifiModeOrder {
    <#
    .SYNOPSIS
    The enabled WiFi ADB modes, preferred first: @('Classic','TLS'), @('TLS','Classic'), or one of them.

    .DESCRIPTION
    Read from the globals Get-Config sets (ADB.wifi_classic_enabled, ADB.wifi_tls_enabled,
    ADB.wifi_preferred_mode through ADB_wifi_effective_preferred). A process or runspace that never
    loaded them gets the default (both on, classic first). Never empty: both off counts as classic,
    as in the loader. Never throws.

    .EXAMPLE
    Get-AdbWifiModeOrder    # Classic, TLS with the default config
    #>
    try {
        $classicOn = if ($null -ne $global:ADB_wifi_classic_enabled) { [bool]$global:ADB_wifi_classic_enabled } else { $true }
        $tlsOn     = if ($null -ne $global:ADB_wifi_tls_enabled)     { [bool]$global:ADB_wifi_tls_enabled }     else { $true }
        if (-not $classicOn -and -not $tlsOn) { $classicOn = $true }
        $pref = [string]$global:ADB_wifi_effective_preferred
        if (-not $pref) { $pref = [string]$global:ADB_wifi_preferred_mode }
        $order = if ($pref -eq 'tls') { @('TLS', 'Classic') } else { @('Classic', 'TLS') }
        return @($order | Where-Object { ($_ -eq 'Classic' -and $classicOn) -or ($_ -eq 'TLS' -and $tlsOn) })
    } catch {
        return @('Classic')
    }
}


function Get-AdbWifiHeadsetKey {
    # Internal. @{Serial;Ip} of a registry row: serial trimmed ('' for blank or '-'), address
    # $null when unknown (Test-UnknownIp), so every helper below applies the same rules.
    param($Headset)
    $serial = ''
    if ($Headset -and $Headset.SerialNumber) { $serial = ([string]$Headset.SerialNumber).Trim() }
    if ($serial -eq '-') { $serial = '' }
    $ip = $null
    if ($Headset -and $Headset.IPAddress) {
        $unknown = if (Get-Command Test-UnknownIp -ErrorAction SilentlyContinue) { Test-UnknownIp $Headset.IPAddress } else { $false }
        if (-not $unknown) { $ip = [string]$Headset.IPAddress }
    }
    return @{ Serial = $serial; Ip = $ip }
}


function Resolve-HeadsetWifiEndpoint {
    <#
    .SYNOPSIS
    The WiFi ADB endpoint of a known headset in ONE mode: @{Mode;Ip;Port}, or $null.

    .DESCRIPTION
    Classic = registry IPAddress + the classic port (-ClassicPort, else Get-ClassicAdbPort).
    TLS     = the published endpoint of the headset's SERIAL (Find-AdbTlsEndpointBySerial: memoised
              read of app_kv adb_tls_endpoints, no adb spawn). The TLS address comes from mDNS and may
              differ from the registry address after a DHCP change.
    $null when the mode has no endpoint (no usable address, no serial, nothing published).
    Pure lookup: no network I/O. Never throws.

    .EXAMPLE
    Resolve-HeadsetWifiEndpoint -Headset $row -Mode TLS    # @{ Mode = 'TLS'; Ip = '192.168.1.243'; Port = 46443 }
    #>
    param(
        [Parameter(Mandatory = $true)] $Headset,
        [Parameter(Mandatory = $true)][ValidateSet('Classic', 'TLS')][string]$Mode,
        [int]$ClassicPort = 0
    )
    try {
        $k = Get-AdbWifiHeadsetKey -Headset $Headset
        if ($Mode -eq 'Classic') {
            if (-not $k.Ip) { return $null }
            $port = if ($ClassicPort -ge 1 -and $ClassicPort -le 65535) { $ClassicPort } else { Get-ClassicAdbPort }
            return [PSCustomObject]@{ Mode = 'Classic'; Ip = $k.Ip; Port = [int]$port }
        }
        if (-not $k.Serial) { return $null }
        $ep = Find-AdbTlsEndpointBySerial -Serial $k.Serial
        if (-not $ep) { return $null }
        return [PSCustomObject]@{ Mode = 'TLS'; Ip = [string]$ep.Ip; Port = [int]$ep.Port }
    } catch {
        return $null
    }
}


function Resolve-HeadsetWifiDevice {
    <#
    .SYNOPSIS
    The WiFi ADB device object of a known headset, trying the enabled modes in preference order.

    .DESCRIPTION
    For each mode of Get-AdbWifiModeOrder (minus -ExcludeMode) that has an endpoint
    (Resolve-HeadsetWifiEndpoint), Get-AdbWifiDevice connects and verifies it; the first that
    answers wins. Always an explicit "ip:port" (ADR-0034 rule 4): adb's own mDNS-named ids are
    never used. The object keeps ConnectionType 'WiFi', IP, Port and gains SerialNumber,
    HeadsetIP (registry address), HeadsetPort (the classic port, for Invoke-AdbCmd) and WifiMode
    ('Classic' or 'TLS'). Failures of every attempt but the last are logged at DEBUG only, so a
    TLS-only headset with classic preferred does not log a port-closed WARNING per resolution.
    A DEBUG line names the mode used when it is not the preferred one. $null when no mode answers.

    .EXAMPLE
    $dev = Resolve-HeadsetWifiDevice -Headset $row; $dev.WifiMode
    #>
    param(
        [Parameter(Mandatory = $true)] $Headset,
        [ValidateSet('', 'Classic', 'TLS')][string]$ExcludeMode = '',
        [int]$ClassicPort = 0,
        [string]$adb = $global:adbPath
    )

    $order = @(Get-AdbWifiModeOrder)
    if ($order.Count -eq 0) { return $null }
    $k = Get-AdbWifiHeadsetKey -Headset $Headset
    $cp = if ($ClassicPort -ge 1 -and $ClassicPort -le 65535) { $ClassicPort } else { Get-ClassicAdbPort }

    $endpoints = @()
    foreach ($m in $order) {
        if ($ExcludeMode -and $m -eq $ExcludeMode) { continue }
        $ep = Resolve-HeadsetWifiEndpoint -Headset $Headset -Mode $m -ClassicPort $cp
        if ($ep) { $endpoints += $ep }
    }
    $label = if ($Headset.Name) { [string]$Headset.Name } elseif ($k.Serial) { $k.Serial } else { [string]$k.Ip }

    for ($i = 0; $i -lt $endpoints.Count; $i++) {
        $ep = $endpoints[$i]
        $isLast = ($i -eq $endpoints.Count - 1)
        $d = Get-AdbWifiDevice -headsetIP $ep.Ip -AdbPort $ep.Port -adb $adb -Quiet:(-not $isLast)
        if (-not $d) { continue }
        $d | Add-Member -NotePropertyName SerialNumber -NotePropertyValue $k.Serial -Force
        $d | Add-Member -NotePropertyName HeadsetIP    -NotePropertyValue $(if ($k.Ip) { $k.Ip } else { $ep.Ip }) -Force
        $d | Add-Member -NotePropertyName HeadsetPort  -NotePropertyValue $cp -Force
        $d | Add-Member -NotePropertyName WifiMode     -NotePropertyValue $ep.Mode -Force
        if ($ep.Mode -ne $order[0]) {
            Write-Log ("headset {0}: {1} WiFi ADB unavailable, using {2} ({3})" -f $label, $order[0], $ep.Mode, $d.DeviceId) -Level DEBUG
        }
        return $d
    }
    return $null
}


function Get-AdbWifiDeviceMode {
    # Internal. The WiFi mode of a device object: its WifiMode when the resolver set one, else
    # inferred from the port (the classic port means Classic, anything else TLS).
    param($Device, [int]$ClassicPort = 0)
    if ($Device -and $Device.PSObject.Properties['WifiMode'] -and $Device.WifiMode) { return [string]$Device.WifiMode }
    $cp = if ($ClassicPort -ge 1) { $ClassicPort } else { Get-ClassicAdbPort }
    if ($Device -and $Device.Port -and [int]$Device.Port -ne $cp) { return 'TLS' }
    return 'Classic'
}


function Get-AdbWifiModeFallbackDevice {
    <#
    .SYNOPSIS
    For a WiFi device whose transport just failed: the same headset over the OTHER enabled WiFi
    mode, connected and verified, or $null.

    .DESCRIPTION
    Called once by Invoke-AdbCmd (ADR-0034: one fallback per call, never chained). The headset is
    rebuilt from the device object (SerialNumber, HeadsetIP or IP), so it works for any object
    Resolve-HeadsetAdbDevice handed out; a bare "ip:port" device without a serial can only fall
    back to classic. $null when only one mode is enabled or the other mode does not answer.

    .EXAMPLE
    $alt = Get-AdbWifiModeFallbackDevice -Device $dev
    #>
    param([Parameter(Mandatory = $true)] $Device, [string]$adb = $global:adbPath)
    try {
        if (@(Get-AdbWifiModeOrder).Count -lt 2) { return $null }
        $cp = if ($Device.PSObject.Properties['HeadsetPort'] -and $Device.HeadsetPort) { [int]$Device.HeadsetPort } else { Get-ClassicAdbPort }
        $current = Get-AdbWifiDeviceMode -Device $Device -ClassicPort $cp
        $serial = if ($Device.PSObject.Properties['SerialNumber']) { [string]$Device.SerialNumber } else { '' }
        $ip = if ($Device.PSObject.Properties['HeadsetIP'] -and $Device.HeadsetIP) { [string]$Device.HeadsetIP } else { [string]$Device.IP }
        $hs = [PSCustomObject]@{ Name = $(if ($serial) { $serial } else { $ip }); SerialNumber = $serial; IPAddress = $ip }
        return (Resolve-HeadsetWifiDevice -Headset $hs -ExcludeMode $current -ClassicPort $cp -adb $adb)
    } catch {
        return $null
    }
}


function Test-HeadsetWifiAdbUp {
    <#
    .SYNOPSIS
    Is WiFi ADB of a known headset reachable, and in which mode? @{Up;Mode;Ip;Port}.

    .DESCRIPTION
    Stage 1 of the poll (every second per headset): TCP probes only, no adb spawn. Modes are
    tried in preference order and the first whose port answers wins: Classic = registry address +
    classic port (only when -PingOk, as before S10-3), TLS = the published endpoint and its TCP
    port answering (skipped without a ping only when it sits on the same address). With the
    default config (classic first) a classic headset costs exactly the one probe it did before.
    Mode is '-' when nothing answers. Never throws.

    .EXAMPLE
    (Test-HeadsetWifiAdbUp -Headset $row -PingOk $true).Mode    # Classic / TLS / -
    #>
    param(
        [Parameter(Mandatory = $true)] $Headset,
        [int]$ClassicPort = 0,
        [bool]$PingOk = $true,
        [int]$TimeoutMs = 400
    )
    $res = @{ Up = $false; Mode = '-'; Ip = $null; Port = 0 }
    try {
        if (-not (Get-Command Test-Port -ErrorAction SilentlyContinue)) { return $res }
        $k = Get-AdbWifiHeadsetKey -Headset $Headset
        foreach ($m in @(Get-AdbWifiModeOrder)) {
            $ep = Resolve-HeadsetWifiEndpoint -Headset $Headset -Mode $m -ClassicPort $ClassicPort
            if (-not $ep) { continue }
            if (-not $PingOk -and ($ep.Mode -eq 'Classic' -or $ep.Ip -eq $k.Ip)) { continue }
            if ((Test-Port -hostname $ep.Ip -port $ep.Port -timeout $TimeoutMs).open) {
                $res.Up = $true; $res.Mode = $ep.Mode; $res.Ip = $ep.Ip; $res.Port = $ep.Port
                return $res
            }
        }
    } catch { }
    return $res
}
