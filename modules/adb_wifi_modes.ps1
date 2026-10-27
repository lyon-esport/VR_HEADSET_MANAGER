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

    And the switch to the preferred mode (S10-5), VRMonitor slow tick only: Update-AdbWifiModeState
    (non-blocking state machine per serial), Get-AdbWifiModeSwitchDecision (pure decision),
    Update-AdbTlsEndpointsFromMdns (the throttled TLS refresh that publishes the endpoints) and
    Get-AdbWifiCaptureModeDecision (should a running WiFi capture follow the mode change).

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


function Repair-AdbTlsEndpointAddress {
    <#
    .SYNOPSIS
    Corrects the IP of mDNS TLS endpoints with the registry address of the same serial when that
    address answers on the advertised port. Returns the endpoints (corrected copies).

    .DESCRIPTION
    "adb mdns services" is right about the serial (service name) and the port (SRV record), but
    the IP comes from the A record of the device's HOST name, which several Android devices can
    share: measured 2026-10-23, Q3 BLUE (192.168.1.243, TLS port 42547) was listed as
    192.168.1.239:42547 - the address of another headset - and every reader of
    adb_tls_endpoints then judged the live capture "gone" and resolved a dead endpoint.
    For each endpoint whose serial is a known headset with a different, usable registry address,
    ONE TCP probe of <registry ip>:<port>: open -> the registry address is published; closed ->
    the mDNS address is kept (a real DHCP change). The verdict is memoised per
    serial|mdns ip|port|registry ip, so a steady state costs no probe. The registry is read
    through Get-KnownHeadsets, cached on the 'headsets' change counter; without it (unit tests,
    a process that does not load headsets_manager.ps1) the endpoints pass unchanged. Never throws.

    .EXAMPLE
    Repair-AdbTlsEndpointAddress -Endpoints @(Get-AdbTlsServices)
    #>
    param($Endpoints, [int]$TimeoutMs = 300)

    $list = @($Endpoints | Where-Object { $_ })
    try {
        if ($list.Count -eq 0 -or -not (Get-Command Get-KnownHeadsets -ErrorAction SilentlyContinue) -or
            -not (Get-Command Test-Port -ErrorAction SilentlyContinue)) { return $list }

        # serial -> registry IP, re-read only when the registry changed
        $ver = $null
        if (Get-Command Get-DbTableVersion -ErrorAction SilentlyContinue) { try { $ver = Get-DbTableVersion -Name 'headsets' } catch { $ver = $null } }
        if ($null -eq $script:AdbTlsRegistryMap -or $null -eq $ver -or $ver -ne $script:AdbTlsRegistryVer) {
            $map = @{}
            foreach ($h in @(Get-KnownHeadsets)) {
                $k = Get-AdbWifiHeadsetKey -Headset $h
                if ($k.Serial -and $k.Ip) { $map[$k.Serial] = $k.Ip }
            }
            $script:AdbTlsRegistryMap = $map
            $script:AdbTlsRegistryVer = $ver
        }
        if ($null -eq $script:AdbTlsAddressMemo) { $script:AdbTlsAddressMemo = @{} }

        $out = @()
        foreach ($e in $list) {
            $serial = [string]$e.Serial; $ip = [string]$e.Ip; $port = [int]$e.Port
            $regIp = $script:AdbTlsRegistryMap[$serial]
            if (-not $regIp -or $regIp -eq $ip) { $out += $e; continue }
            $memoKey = '{0}|{1}|{2}|{3}' -f $serial, $ip, $port, $regIp
            if (-not $script:AdbTlsAddressMemo.ContainsKey($memoKey)) {
                $useReg = [bool](Test-Port -hostname $regIp -port $port -timeout $TimeoutMs).open
                $script:AdbTlsAddressMemo[$memoKey] = $useReg
                if ($script:AdbTlsAddressMemo.Count -gt 200) { $script:AdbTlsAddressMemo.Clear() }
                if ($useReg -and (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
                    Write-Log ("ADB TLS: mDNS lists serial {0} at {1}:{2}, but it answers at its registry address {3}:{2} - using the registry address" -f $serial, $ip, $port, $regIp) -Level DEBUG
                }
            }
            if ($script:AdbTlsAddressMemo[$memoKey]) {
                $c = [PSCustomObject]@{ Serial = $serial; Ip = $regIp; Port = $port }
                if ($e.PSObject.Properties['Name']) { $c | Add-Member -NotePropertyName Name -NotePropertyValue $e.Name }
                $out += $c
            } else {
                $out += $e
            }
        }
        return @($out)
    } catch {
        return $list
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
    -Force writes regardless. -Drop removes the previous entries of those serials (S10-5: a serial
    missed by two refreshes in a row, Update-AdbTlsEndpointsFromMdns). Never throws: publishing
    must not abort a monitor tick. Returns the merged set that is (now) published.

    .EXAMPLE
    Publish-AdbTlsEndpoints -Endpoints @(Get-AdbTlsServices)
    #>
    param($Endpoints, [switch]$Force, [string[]]$Drop = @())

    try {
        $now = [datetime]::UtcNow
        $nowText = $now.ToString('o')
        $staleSec = Get-AdbTlsStaleSec

        # Previous set: what this process wrote last, else what is stored (first call of a process).
        $previous = if ($null -ne $script:AdbTlsLastSet) { @($script:AdbTlsLastSet) } else { @(Get-PublishedAdbTlsEndpoints -MaxAgeSec 0 -IncludeStale) }

        $merged = [ordered]@{}
        # mDNS can give a serial the IP of ANOTHER device (shared host name): fix it first.
        foreach ($e in @(Repair-AdbTlsEndpointAddress -Endpoints $Endpoints)) {
            if ($null -eq $e -or -not $e.Serial -or -not $e.Ip -or -not $e.Port) { continue }
            $merged[[string]$e.Serial] = [PSCustomObject]@{ Serial = [string]$e.Serial; Ip = [string]$e.Ip; Port = [int]$e.Port; Seen = $nowText }
        }
        foreach ($p in $previous) {
            if ($null -eq $p -or -not $p.Serial -or $merged.Contains([string]$p.Serial)) { continue }
            if (@($Drop) -contains [string]$p.Serial) { continue }
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


function Get-AdbWifiPreferredMode {
    <#
    .SYNOPSIS
    The WiFi ADB mode headsets are moved to: 'Classic', 'TLS', or '' for no preference.

    .DESCRIPTION
    ADB.wifi_preferred_mode 'auto' (the default, ADR-0037) means no preference: the resolver uses
    whatever mode answers (classic first, Get-AdbWifiModeOrder) and nothing is ever switched. ''
    also when only one mode is enabled (nothing to switch to). THE single read used by the switch
    engine, the running-capture rule, DIAG and the console - never Get-AdbWifiModeOrder's first
    entry, which is classic under 'auto' too. Never throws.

    .EXAMPLE
    if (Get-AdbWifiPreferredMode) { 'switching to ' + (Get-AdbWifiPreferredMode) }
    #>
    try {
        $pref = [string]$global:ADB_wifi_effective_preferred
        if (-not $pref) { $pref = [string]$global:ADB_wifi_preferred_mode }
        if (@(Get-AdbWifiModeOrder).Count -lt 2) { return '' }
        if ($pref -eq 'tls') { return 'TLS' }
        if ($pref -eq 'classic') { return 'Classic' }
        return ''
    } catch {
        return ''
    }
}


function Test-AdbWifiModeConfig {
    <#
    .SYNOPSIS
    Validates the WiFi ADB mode keys of a posted ADB config section: '' when valid, else the error text.

    .DESCRIPTION
    Used by /api/config/save before it writes config.json (ADR-0037). wifi_preferred_mode must be
    auto, classic or tls (case-insensitive); wifi_classic_enabled / wifi_tls_enabled must be
    booleans; adbPort_default 1..65535. Missing keys are valid (the loader defaults them).

    .EXAMPLE
    Test-AdbWifiModeConfig -Adb $newCfg.ADB
    #>
    param($Adb)
    try {
        if ($null -eq $Adb) { return '' }
        $p = $Adb.PSObject.Properties
        if ($p['wifi_preferred_mode'] -and $null -ne $Adb.wifi_preferred_mode -and
            ([string]$Adb.wifi_preferred_mode).Trim().ToLowerInvariant() -notin @('auto', 'classic', 'tls')) {
            return 'ADB.wifi_preferred_mode must be auto, classic or tls.'
        }
        foreach ($b in 'wifi_classic_enabled', 'wifi_tls_enabled') {
            if ($p[$b] -and $null -ne $Adb.$b -and -not ($Adb.$b -is [bool])) { return ('ADB.{0} must be true or false.' -f $b) }
        }
        if ($p['adbPort_default'] -and $null -ne $Adb.adbPort_default) {
            $port = 0
            if (-not [int]::TryParse([string]$Adb.adbPort_default, [ref]$port) -or $port -lt 1 -or $port -gt 65535) { return 'ADB.adbPort_default must be a port number (1-65535).' }
        }
        return ''
    } catch {
        return 'ADB section is not valid.'
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


function Test-AdbWifiPreferredModeBack {
    <#
    .SYNOPSIS
    $true when a WiFi device sits on the fallback mode while the preferred mode now answers - a
    memoised device should then be dropped and resolved again (ADR-0037).

    .DESCRIPTION
    $false with no preference ('auto'), for a USB device, or when the device already uses the
    preferred mode. Otherwise one TCP probe of the preferred endpoint (Resolve-HeadsetWifiEndpoint:
    registry address + classic port, or the published TLS endpoint of the serial). Never throws.

    .EXAMPLE
    if (Test-AdbWifiPreferredModeBack -Device $cached -Headset $row) { $cache.Clear() }
    #>
    param([Parameter(Mandatory = $true)] $Device, [Parameter(Mandatory = $true)] $Headset, [int]$TimeoutMs = 300)
    try {
        $preferred = Get-AdbWifiPreferredMode
        if (-not $preferred -or $Device.ConnectionType -ne 'WiFi') { return $false }
        if ((Get-AdbWifiDeviceMode -Device $Device) -eq $preferred) { return $false }
        $ep = Resolve-HeadsetWifiEndpoint -Headset $Headset -Mode $preferred
        if (-not $ep -or -not (Get-Command Test-Port -ErrorAction SilentlyContinue)) { return $false }
        return [bool](Test-Port -hostname $ep.Ip -port $ep.Port -timeout $TimeoutMs).open
    } catch {
        return $false
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

# ---------------------------------------------------------------------------------------------
# Switch to the preferred mode (S10-5, ADR-0034 rule 5). Run by the VRMonitor slow tick on the
# main thread only - never from a request or a poll runspace. Commands measured in S10-0:
#   TLS -> classic : "adb -s <ip:tlsport> tcpip <port>" (exit 0, EMPTY output, classic answers
#                    after ~2.3 s). It restarts adbd: every WiFi session of the headset drops and
#                    TLS comes back on a NEW port; a capture over TLS hangs instead of exiting.
#   classic -> TLS : "settings put global adb_wifi_enabled 1" (TLS advertised ~1.2 s later,
#                    interrupts nothing).
# Nothing here waits for the headset: a tick issues the command, the next ticks confirm it, so
# the 500 ms fast path is never held for seconds.
# ---------------------------------------------------------------------------------------------
$script:AdbTlsRefreshSec        = 5     # TLS refresh period while nothing is switching
$script:AdbTlsFastSec           = 15    # refresh on every tick for this long after a switch
$script:AdbTlsMissLimit         = 2     # a published serial missed this many refreshes in a row is dropped
$script:AdbWifiSwitchConfirmSec = 15    # a switch not confirmed within this window failed
$script:AdbWifiSwitchHoldSec    = 30    # quiet time after a successful switch (no flapping)
$script:AdbWifiSwitchRetrySec   = 60    # wait after a failure
$script:AdbWifiSwitchGiveUpAfter = 3    # failures in a row before the preferred mode is given up (one WARNING)
$script:AdbWifiEndpointDeadMax  = 2     # closed-port checks in a row before a capture endpoint counts as dead


function Update-AdbTlsEndpointsFromMdns {
    <#
    .SYNOPSIS
    The TLS refresh of the VRMonitor slow tick: ONE "adb mdns services", published through
    Publish-AdbTlsEndpoints. Returns the published set, or $null when it did not run.

    .DESCRIPTION
    Runs only when TLS is enabled, at most every 5 s ($script:AdbTlsRefreshSec), except on -Force
    or within 15 s after a mode switch ($script:AdbTlsFastUntil), when it runs on every call: the
    TLS port changes when "tcpip" restarts adbd and must be re-published at once. adb's mDNS can
    miss a live headset for one call (S10-0), so a published serial is dropped only after it was
    missed by two successful refreshes in a row; a failed adb call counts as no refresh at all.
    Main thread only (the single writer of adb_tls_endpoints, ADR-0034 rule 3). Never throws.

    .EXAMPLE
    Update-AdbTlsEndpointsFromMdns -Force
    #>
    param([switch]$Force, [datetime]$Now = [datetime]::UtcNow, [string]$adb = $global:adbPath)
    try {
        if ($null -ne $global:ADB_wifi_tls_enabled -and -not [bool]$global:ADB_wifi_tls_enabled) { return $null }
        $fast = ($null -ne $script:AdbTlsFastUntil -and $Now -lt $script:AdbTlsFastUntil)
        if (-not $Force -and -not $fast -and $null -ne $script:AdbTlsPolledAt -and
            (($Now - $script:AdbTlsPolledAt).TotalSeconds -lt $script:AdbTlsRefreshSec)) { return $null }
        $script:AdbTlsPolledAt = $Now

        $r = Invoke-Adb -Arguments @('mdns', 'services') -Adb $adb -TimeoutSeconds 5
        if (-not $r -or -not $r.Ok) { return $null }
        $found = @(ConvertFrom-AdbMdnsServices -Text $r.StdOut)

        if ($null -eq $script:AdbTlsMisses) { $script:AdbTlsMisses = @{} }
        $seen = @{}
        foreach ($e in $found) { $seen[[string]$e.Serial] = $true }
        $drop = @()
        foreach ($p in @(Get-PublishedAdbTlsEndpoints -MaxAgeSec 0 -IncludeStale)) {
            $s = [string]$p.Serial
            if ($seen.ContainsKey($s)) { continue }
            $n = 1 + [int]$script:AdbTlsMisses[$s]
            if ($n -ge $script:AdbTlsMissLimit) { $drop += $s; $script:AdbTlsMisses.Remove($s) }
            else { $script:AdbTlsMisses[$s] = $n }
        }
        foreach ($s in @($seen.Keys)) { $script:AdbTlsMisses.Remove($s) }
        return @(Publish-AdbTlsEndpoints -Endpoints $found -Drop $drop)
    } catch {
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log ("Update-AdbTlsEndpointsFromMdns: " + $_.Exception.Message) -Level DEBUG }
        return $null
    }
}


function Get-AdbWifiModeSwitchDecision {
    <#
    .SYNOPSIS
    Pure decision: should this headset be moved to the preferred WiFi ADB mode now?
    Returns @{ Action = 'none'|'ToClassic'|'ToTLS'; Reason; Current; Preferred; Deferred }.

    .DESCRIPTION
    No I/O. Current is the live status AdbWifiMode (stage 1: the first mode, in preference order,
    that answers). No action when: no preference (Get-AdbWifiPreferredMode '' - 'auto', or only one
    mode enabled), no serial, not reachable over WiFi, already on the preferred mode, shutting
    down, benchmark running, USB held by an operator action (Test-UsbBusy), cabled while
    ADB.prefer_usb (USB wins, ADR-0024), a switch is pending, the per-serial retry delay
    (-Memo.NextAt) is not over, or the preferred mode was given up for this headset
    (-Memo.Unavailable: 3 failures in a row). ToTLS interrupts nothing. ToClassic
    restarts adbd and kills a running capture (S10-0), so while the headset is capturing it is
    issued only with scrcpy.usb_switch_mode 'immediate'; otherwise Deferred is $true.

    .EXAMPLE
    Get-AdbWifiModeSwitchDecision -Headset $row -Info $info -Capturing $false
    #>
    param(
        [Parameter(Mandatory = $true)] $Headset,
        $Info = $null,
        [bool]$Capturing = $false,
        [bool]$Cabled = $false,
        [bool]$UsbBusy = $false,
        [bool]$Benchmark = $false,
        [bool]$ShuttingDown = $false,
        [string]$SwitchMode = 'stable',
        $Memo = $null,
        [datetime]$Now = [datetime]::UtcNow
    )
    $d = [PSCustomObject]@{ Action = 'none'; Reason = ''; Current = '-'; Preferred = '-'; Deferred = $false }
    try {
        $preferred = Get-AdbWifiPreferredMode
        if (-not $preferred) { $d.Reason = 'no preferred mode'; return $d }
        $d.Preferred = $preferred
        # A brand without Wireless debugging (Pico, ADR-0038) stays on classic: nothing to switch.
        if ($Headset.PSObject.Properties['Brand'] -and -not (Test-HeadsetAdbTlsSupported -Brand ([string]$Headset.Brand))) {
            $d.Reason = 'ADB over TLS not supported on this brand'; return $d
        }
        $k = Get-AdbWifiHeadsetKey -Headset $Headset
        if (-not $k.Serial) { $d.Reason = 'no serial'; return $d }
        $cur = if ($Info -and $Info.AdbWifiMode) { [string]$Info.AdbWifiMode } else { '-' }
        $d.Current = $cur
        if ($cur -notin @('Classic', 'TLS')) { $d.Reason = 'not reachable over WiFi'; return $d }
        if ($cur -eq $preferred) { $d.Reason = 'already on the preferred mode'; return $d }
        if ($ShuttingDown) { $d.Reason = 'shutting down'; return $d }
        if ($Benchmark)    { $d.Reason = 'stream benchmark running'; return $d }
        if ($UsbBusy)      { $d.Reason = 'USB held by an operator action'; return $d }
        $preferUsb = if ($null -ne $global:ADB_prefer_usb) { [bool]$global:ADB_prefer_usb } else { $true }
        if ($Cabled -and $preferUsb) { $d.Reason = 'cabled, USB is used'; return $d }
        if ($Memo) {
            if ($Memo.Unavailable) { $d.Reason = 'preferred mode not available on this headset'; return $d }
            if ($Memo.Pending) { $d.Reason = 'switch pending'; return $d }
            if ($Memo.NextAt -and $Now -lt [datetime]$Memo.NextAt) { $d.Reason = 'backoff'; return $d }
        }
        if ($preferred -eq 'Classic') {
            if ($Capturing -and $SwitchMode -ne 'immediate') {
                $d.Reason = 'capturing (tcpip would cut the capture)'; $d.Deferred = $true
                return $d
            }
            $d.Action = 'ToClassic'
        } else {
            $d.Action = 'ToTLS'
        }
        $d.Reason = ('{0} -> {1}' -f $cur, $preferred)
    } catch {
        $d.Action = 'none'; $d.Reason = 'decision failed: ' + $_.Exception.Message
    }
    return $d
}


function Get-AdbWifiSwitchMemo {
    # Internal. The per-serial switch memo {LastAttempt;Failures;NextAt;DeferLogged;Pending;
    # Unavailable;UnavailableReason;WasDown}, created on first use (same shape idea as
    # usb_manager.ps1's $script:UsbMemo).
    param([Parameter(Mandatory = $true)][string]$Serial)
    if ($null -eq $script:AdbWifiSwitchMemo) { $script:AdbWifiSwitchMemo = @{} }
    if (-not $script:AdbWifiSwitchMemo.ContainsKey($Serial)) {
        $script:AdbWifiSwitchMemo[$Serial] = @{ LastAttempt = $null; Failures = 0; NextAt = $null; DeferLogged = $false; Pending = $null
                                                Unavailable = $false; UnavailableReason = ''; WasDown = $false }
    }
    return $script:AdbWifiSwitchMemo[$Serial]
}


function Reset-AdbWifiModeState {
    <#
    .SYNOPSIS
    Forgets every switch memo (retry delays, pending switches, "preferred mode not available")
    and the running-capture mode timers, and forces the next TLS refresh.

    .DESCRIPTION
    Called by Update-AdbWifiModeState when the WiFi ADB mode settings change (ADR-0037): a new
    preference is a fresh start - a headset given up under the old one is tried again at once.
    Process-local (VRMonitor main thread). Never throws.

    .EXAMPLE
    Reset-AdbWifiModeState
    #>
    $script:AdbWifiSwitchMemo   = @{}
    $script:AdbWifiCaptureState = @{}
    $script:AdbTlsPolledAt      = $null
}


function Get-AdbWifiModeSwitchStatus {
    <#
    .SYNOPSIS
    The switch state of one headset in THIS process: @{ Preferred; Pending; Failures; Unavailable; Reason; NextAt }.

    .DESCRIPTION
    Read side of the memo kept by Update-AdbWifiModeState (VRMonitor). Also published by it in
    the app_kv row adb_wifi_switch_state (serial -> state) so the web server (DIAG page) can show
    why a headset stays on its fallback mode: Get-AdbWifiModeSwitchStatus -Published reads that
    row instead of the local memo. Never throws; $null when nothing is known.

    .EXAMPLE
    (Get-AdbWifiModeSwitchStatus -Serial '1WMHH8242N0366' -Published).Reason
    #>
    param([Parameter(Mandatory = $true)][string]$Serial, [switch]$Published)
    try {
        if ($Published) {
            if (-not (Get-Command Get-DbKeyValue -ErrorAction SilentlyContinue)) { return $null }
            $row = Get-DbKeyValue -Key 'adb_wifi_switch_state'
            if ($row -is [string]) { $row = if ([string]::IsNullOrWhiteSpace($row)) { $null } else { $row | ConvertFrom-Json } }
            if ($null -eq $row) { return $null }
            $p = $row.PSObject.Properties[$Serial]
            if ($p) { return $p.Value }
            return $null
        }
        if ($null -eq $script:AdbWifiSwitchMemo -or -not $script:AdbWifiSwitchMemo.ContainsKey($Serial)) { return $null }
        $m = $script:AdbWifiSwitchMemo[$Serial]
        return [PSCustomObject]@{
            Preferred   = Get-AdbWifiPreferredMode
            Pending     = [bool]$m.Pending
            Failures    = [int]$m.Failures
            Unavailable = [bool]$m.Unavailable
            Reason      = [string]$m.UnavailableReason
            NextAt      = $(if ($m.NextAt) { ([datetime]$m.NextAt).ToString('o') } else { '' })
        }
    } catch {
        return $null
    }
}


function Get-AdbWifiModeText {
    # Internal. Operator wording of a mode for the log lines.
    param([string]$Mode)
    if ($Mode -eq 'TLS') { return 'TLS' }
    return 'classic'
}


function Complete-AdbWifiModeSwitch {
    # Internal. Ends the pending switch of one headset: success (log INFO, quiet hold, ask the
    # watchdog to look at its capture) or failure (retry after 60 s; after 3 failures in a row the
    # preferred mode is given up for this headset with ONE WARNING - it stays on the other mode
    # until the preference changes, the headset reboots or the app restarts).
    param([Parameter(Mandatory = $true)] $Headset, [Parameter(Mandatory = $true)] $Memo, [bool]$Ok, [string]$Detail = '', [datetime]$Now = [datetime]::UtcNow)
    $p = $Memo.Pending
    $Memo.Pending = $null
    $from = Get-AdbWifiModeText -Mode $p.From
    $to   = Get-AdbWifiModeText -Mode $p.Target
    if ($Ok) {
        $Memo.Failures = 0; $Memo.DeferLogged = $false; $Memo.Unavailable = $false; $Memo.UnavailableReason = ''
        $Memo.NextAt = $Now.AddSeconds($script:AdbWifiSwitchHoldSec)
        $script:AdbTlsFastUntil = $Now.AddSeconds($script:AdbTlsFastSec)
        Write-Log ((Get-MessageString -Key 'AdbWifi.Switched' -Fallback 'Switched {0} from {1} to {2} WiFi ADB.') -f $Headset.Name, $from, $to) -Level INFO
        if (Get-Command Request-ScrcpyCheck -ErrorAction SilentlyContinue) {
            [void](Request-ScrcpyCheck -HeadsetId @([int]$Headset.ID) -NoMark -Reason 'adb wifi mode switched')
        }
        return
    }
    $Memo.Failures = [int]$Memo.Failures + 1
    if ($Memo.Failures -ge $script:AdbWifiSwitchGiveUpAfter) {
        $Memo.Unavailable = $true
        $Memo.UnavailableReason = $Detail
        $Memo.NextAt = $null
        Write-Log ((Get-MessageString -Key 'AdbWifi.PreferredUnavailable' -Fallback '{2} WiFi ADB cannot be enabled on {0} ({3}): it stays on {1} until the preferred mode changes, the headset reboots or the app restarts.') -f $Headset.Name, $from, $to, $Detail) -Level WARNING
    } else {
        $Memo.NextAt = $Now.AddSeconds($script:AdbWifiSwitchRetrySec)
        Write-Log ("ADB WiFi mode: switch of {0} to {1} failed ({2}), retry in {3} s" -f $Headset.Name, $to, $Detail, $script:AdbWifiSwitchRetrySec) -Level DEBUG
    }
}


function Update-AdbWifiModeState {
    <#
    .SYNOPSIS
    Moves headsets reachable only in the non-preferred WiFi ADB mode onto the preferred one.
    VRMonitor slow tick, main thread only. Returns @{ Issued; Switched; Failed } (headset names).

    .DESCRIPTION
    First refreshes the published TLS endpoints (Update-AdbTlsEndpointsFromMdns: every 5 s, every
    tick while a switch runs). Then, per registered headset with a serial, a non-blocking state
    machine kept in $script:AdbWifiSwitchMemo:
      - no switch pending: Get-AdbWifiModeSwitchDecision on the live status (-HeadsetInfo, keyed
        by registry IP, as VRMonitor's $infoByIp). ToClassic runs "tcpip <classic port>" over the
        live TLS session (output not parsed: it is empty); ToTLS runs Enable-HeadsetAdbTls over
        the classic session. The command is issued and the call moves on.
      - switch pending: confirmed on the following ticks - classic port open, adb connect and
        ro.serialno equal to the serial; or the serial advertised over mDNS with its port answering
        and connecting. Not confirmed within 15 s = failure. Success logs ONE INFO line and calls
        Request-ScrcpyCheck -NoMark so the watchdog re-evaluates the capture.
    A failure is retried after 60 s; after 3 in a row the preferred mode is given up for that
    headset (ONE WARNING) until the preference changes, the headset drops off WiFi ADB and comes
    back (a reboot), or the app restarts. A success holds 30 s.
    Preference change (ADR-0037): when the classic/TLS toggles or the preferred mode differ from
    the previous call, every memo is reset (Reset-AdbWifiModeState), the TLS refresh is forced and
    Request-ScrcpyCheck -All -NoMark asks the watchdog to re-evaluate every capture (which then
    follows scrcpy.usb_switch_mode). With no preference ('auto') nothing is switched; the TLS
    refresh still runs. The switch state is published in app_kv adb_wifi_switch_state (serial ->
    state) for the DIAG page. Nothing runs while data\shutdown.flag exists or a stream benchmark
    is active. Never throws.

    .EXAMPLE
    Update-AdbWifiModeState -KnownHeadsets @(Get-KnownHeadsets) -HeadsetInfo $infoByIp -ScrcpyPids $sharedState['_scrcpy_pids']
    #>
    param(
        $KnownHeadsets = $null,
        [hashtable]$HeadsetInfo = $null,
        $ScrcpyPids = $null,
        [string]$adb = $global:adbPath,
        [datetime]$Now = [datetime]::UtcNow
    )
    $res = @{ Issued = @(); Switched = @(); Failed = @(); PreferenceChanged = $false }
    try {
        if ($global:ScriptPath -and (Test-Path -LiteralPath (Join-Path $global:ScriptPath 'data\shutdown.flag'))) { return $res }
        $bench = [bool]((Get-Command Test-StreamBenchmarkActive -ErrorAction SilentlyContinue) -and (Test-StreamBenchmarkActive))
        if ($bench) { return $res }

        # ---- preference change = trigger (ADR-0037) ----
        $sig = '{0}|{1}|{2}' -f [bool]$global:ADB_wifi_classic_enabled, [bool]$global:ADB_wifi_tls_enabled, (Get-AdbWifiPreferredMode)
        $prefChanged = ($null -ne $script:AdbWifiPrefSig -and $sig -ne $script:AdbWifiPrefSig)
        $script:AdbWifiPrefSig = $sig
        if ($prefChanged) {
            Reset-AdbWifiModeState
            $res.PreferenceChanged = $true
            $prefText = if (Get-AdbWifiPreferredMode) { Get-AdbWifiModeText -Mode (Get-AdbWifiPreferredMode) } else { 'none' }
            Write-Log ((Get-MessageString -Key 'AdbWifi.PreferenceChanged' -Fallback 'WiFi ADB mode settings changed (preferred: {0}) - re-checking every headset and capture.') -f $prefText) -Level INFO
            if (Get-Command Request-ScrcpyCheck -ErrorAction SilentlyContinue) {
                [void](Request-ScrcpyCheck -All -NoMark -Reason 'adb wifi mode settings changed')
            }
        }

        $anyPending = $false
        if ($script:AdbWifiSwitchMemo) { $anyPending = @($script:AdbWifiSwitchMemo.Values | Where-Object { $_.Pending }).Count -gt 0 }
        [void](Update-AdbTlsEndpointsFromMdns -Force:($anyPending -or $prefChanged) -Now $Now -adb $adb)

        if (-not (Get-AdbWifiPreferredMode) -and -not $anyPending) {
            Publish-AdbWifiSwitchState
            return $res
        }
        if ($null -eq $KnownHeadsets) { $KnownHeadsets = @(Get-KnownHeadsets) }

        $usbBusy = [bool]((Get-Command Test-UsbBusy -ErrorAction SilentlyContinue) -and (Test-UsbBusy))
        $cabledSet = @{}
        if (Get-Command Get-PublishedUsbDevices -ErrorAction SilentlyContinue) {
            foreach ($u in @(Get-PublishedUsbDevices)) { if ($u.Serial) { $cabledSet[[string]$u.Serial] = $true } }
        }
        $switchMode = if ($global:scrcpyUsbSwitchMode) { [string]$global:scrcpyUsbSwitchMode } else { 'stable' }
        $classicPort = Get-ClassicAdbPort

        foreach ($h in @($KnownHeadsets)) {
            if ($null -eq $h) { continue }
            $k = Get-AdbWifiHeadsetKey -Headset $h
            if (-not $k.Serial) { continue }
            $memo = Get-AdbWifiSwitchMemo -Serial $k.Serial

            # ---- confirm a pending switch ----
            if ($memo.Pending) {
                $p = $memo.Pending
                $ok = $false
                if ($p.Target -eq 'Classic') {
                    if ((Test-Port -hostname $p.Ip -port $classicPort -timeout 400).open) {
                        $dev = Get-AdbWifiDevice -headsetIP $p.Ip -AdbPort $classicPort -adb $adb -Quiet
                        if ($dev) {
                            $props = Get-AdbPropBatch -Device $dev -Properties @('ro.serialno') -TimeoutSeconds 5 -adb $adb
                            $ok = ([string]$props['ro.serialno']).Trim() -eq $k.Serial
                        }
                    }
                } else {
                    $ep = Find-AdbTlsEndpointBySerial -Serial $k.Serial -MaxAgeSec 0
                    if ($ep -and (Test-Port -hostname $ep.Ip -port $ep.Port -timeout 400).open) {
                        $ok = [bool](Get-AdbWifiDevice -headsetIP $ep.Ip -AdbPort $ep.Port -adb $adb -Quiet)
                    }
                }
                if ($ok) {
                    # The headset answered at an address the registry may not hold (DHCP change
                    # seen through mDNS): Set-HeadsetIdentity is the only IP writer (ADR-0016).
                    if ($p.Ip -and $p.Ip -ne $k.Ip -and (Get-Command Set-HeadsetIdentity -ErrorAction SilentlyContinue)) {
                        [void](Set-HeadsetIdentity -SerialNumber $k.Serial -IPAddress $p.Ip -Source 'adb-tls')
                    }
                    Complete-AdbWifiModeSwitch -Headset $h -Memo $memo -Ok $true -Now $Now
                    $res.Switched += [string]$h.Name
                } elseif ($Now -ge [datetime]$p.Deadline) {
                    Complete-AdbWifiModeSwitch -Headset $h -Memo $memo -Ok $false -Detail 'not confirmed in time' -Now $Now
                    $res.Failed += [string]$h.Name
                }
                continue
            }

            # ---- decide ----
            $info = $null
            if ($HeadsetInfo -and $h.IPAddress -and $HeadsetInfo.ContainsKey([string]$h.IPAddress)) { $info = $HeadsetInfo[[string]$h.IPAddress] }

            # A headset that dropped off WiFi ADB and came back (a reboot, typically) gets its
            # preferred mode tried again: it may well be possible now (auto-enable app, new AP).
            $wifiUp = [bool]($info -and ([string]$info.AdbWifiMode -in @('Classic', 'TLS')))
            if (-not $wifiUp) { $memo.WasDown = $true }
            elseif ($memo.WasDown) {
                $memo.WasDown = $false
                if ($memo.Unavailable) {
                    $memo.Unavailable = $false; $memo.UnavailableReason = ''; $memo.Failures = 0; $memo.NextAt = $null
                    Write-Log ("ADB WiFi mode: {0} is back on WiFi ADB - its preferred mode is tried again" -f $h.Name) -Level DEBUG
                }
            }

            $capturing = $false
            if ($ScrcpyPids -and $ScrcpyPids.ContainsKey([string]$h.ID)) { $capturing = $true }
            elseif ($info -and (Get-Command ConvertTo-BoolField -ErrorAction SilentlyContinue) -and (ConvertTo-BoolField $info.SCRCPY)) { $capturing = $true }
            if (-not $capturing -and (Get-Command Test-ScrcpyCaptureBusy -ErrorAction SilentlyContinue)) { $capturing = [bool](Test-ScrcpyCaptureBusy -HeadsetId ([int]$h.ID)) }

            $dec = Get-AdbWifiModeSwitchDecision -Headset $h -Info $info -Capturing $capturing -Cabled ($cabledSet.ContainsKey($k.Serial)) `
                -UsbBusy $usbBusy -SwitchMode $switchMode -Memo $memo -Now $Now
            if ($dec.Action -eq 'none') {
                if ($dec.Deferred -and -not $memo.DeferLogged) {
                    $memo.DeferLogged = $true
                    Write-Log ((Get-MessageString -Key 'AdbWifi.SwitchDeferred' -Fallback '{0} is on TLS WiFi ADB while capturing: the switch to classic waits until the capture stops (scrcpy.usb_switch_mode = {1}).') -f $h.Name, $switchMode) -Level DEBUG
                }
                elseif (-not $dec.Deferred -and $dec.Reason -and $dec.Reason -ne 'already on the preferred mode' -and $memo['LastNoSwitchReason'] -ne $dec.Reason) {
                    # One DEBUG line per change of reason: a preferred mode that is set but not applied
                    # used to be completely silent, which made "why did it not switch" unanswerable.
                    $memo['LastNoSwitchReason'] = $dec.Reason
                    Write-Log ("ADB WiFi mode: no switch for {0} ({1}; live mode {2}, preferred {3})" -f $h.Name, $dec.Reason, $dec.Current, $dec.Preferred) -Level DEBUG
                }
                continue
            }

            # ---- target already up? ----
            # The live status may lag (a poll runspace still on an older mode order, or its
            # memoised device): when the preferred mode already answers there is nothing to switch.
            # Re-issuing the command would only cost a reconnect - or, for tcpip, cut the captures.
            $targetUp = $false
            if ($dec.Action -eq 'ToClassic') {
                $targetUp = [bool]($k.Ip -and (Test-Port -hostname $k.Ip -port $classicPort -timeout 400).open)
            } else {
                $tep = Find-AdbTlsEndpointBySerial -Serial $k.Serial -MaxAgeSec 0
                $targetUp = [bool]($tep -and (Test-Port -hostname $tep.Ip -port $tep.Port -timeout 400).open)
            }
            if ($targetUp) {
                $memo.NextAt = $Now.AddSeconds($script:AdbWifiSwitchHoldSec)
                Write-Log ("ADB WiFi mode: {0} already answers in {1} mode, nothing to switch (live status reports {2})" -f $h.Name, (Get-AdbWifiModeText -Mode $dec.Preferred), $dec.Current) -Level DEBUG
                continue
            }

            # ---- issue ----
            $memo.LastAttempt = $Now
            $memo.DeferLogged = $false
            $issued = $false
            $detail = ''
            if ($dec.Action -eq 'ToClassic') {
                $ep = Find-AdbTlsEndpointBySerial -Serial $k.Serial -MaxAgeSec 0
                $dev = if ($ep) { Get-AdbWifiDevice -headsetIP $ep.Ip -AdbPort $ep.Port -adb $adb -Quiet } else { $null }
                if ($dev) {
                    $r = Invoke-Adb -Arguments @('-s', [string]$dev.DeviceId, 'tcpip', [string]$classicPort) -Adb $adb -TimeoutSeconds 5
                    $issued = [bool]($r -and $r.Ok)
                    if (-not $issued) { $detail = 'tcpip refused: ' + ((@($r.StdOut) + @($r.StdErr)) -join ' ').Trim() }
                } else { $detail = 'no TLS session' }
                if ($issued) {
                    $memo.Pending = @{ Target = 'Classic'; From = 'TLS'; Ip = $(if ($ep.Ip) { [string]$ep.Ip } else { $k.Ip }); IssuedAt = $Now; Deadline = $Now.AddSeconds($script:AdbWifiSwitchConfirmSec); Capturing = $capturing }
                }
            } else {
                $dev = if ($k.Ip) { Get-AdbWifiDevice -headsetIP $k.Ip -AdbPort $classicPort -adb $adb -Quiet } else { $null }
                if ($dev -and (Get-Command Enable-HeadsetAdbTls -ErrorAction SilentlyContinue)) {
                    $r = Enable-HeadsetAdbTls -Device $dev
                    $issued = [bool]($r -and $r.Ok)
                    if (-not $issued) { $detail = 'enable refused: ' + [string]$r.Error }
                } else { $detail = 'no classic session' }
                if ($issued) {
                    $memo.Pending = @{ Target = 'TLS'; From = 'Classic'; Ip = $k.Ip; IssuedAt = $Now; Deadline = $Now.AddSeconds($script:AdbWifiSwitchConfirmSec); Capturing = $capturing }
                }
            }
            if ($issued) {
                $script:AdbTlsFastUntil = $Now.AddSeconds($script:AdbWifiSwitchConfirmSec + $script:AdbTlsFastSec)
                Write-Log ("ADB WiFi mode: {0} {1} issued for {2}" -f $dec.Action, $dec.Reason, $h.Name) -Level DEBUG
                $res.Issued += [string]$h.Name
            } else {
                $memo.Pending = @{ Target = $(if ($dec.Action -eq 'ToClassic') { 'Classic' } else { 'TLS' }); From = $dec.Current }
                Complete-AdbWifiModeSwitch -Headset $h -Memo $memo -Ok $false -Detail $detail -Now $Now
                $res.Failed += [string]$h.Name
            }
        }
        Publish-AdbWifiSwitchState
    } catch {
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log ("Update-AdbWifiModeState: " + $_.Exception.Message) -Level WARNING }
    }
    return $res
}


function Publish-AdbWifiSwitchState {
    # Internal. Writes the switch state of every headset this process tracks to the app_kv row
    # adb_wifi_switch_state (serial -> @{Preferred;Pending;Failures;Unavailable;Reason;NextAt}),
    # only when it changed since the last write, so the web server (DIAG) can read why a headset
    # stays on its fallback mode. Never throws.
    try {
        if (-not (Get-Command Set-DbKeyValue -ErrorAction SilentlyContinue)) { return }
        $map = [ordered]@{}
        if ($script:AdbWifiSwitchMemo) {
            foreach ($s in @($script:AdbWifiSwitchMemo.Keys | Sort-Object)) {
                $st = Get-AdbWifiModeSwitchStatus -Serial $s
                if ($st -and ($st.Pending -or $st.Failures -gt 0 -or $st.Unavailable)) {
                    $map[$s] = @{ Preferred = $st.Preferred; Pending = $st.Pending; Failures = $st.Failures; Unavailable = $st.Unavailable; Reason = $st.Reason }
                }
            }
        }
        $json = ConvertTo-Json -InputObject $map -Compress -Depth 4
        if ($json -eq $script:AdbWifiSwitchStateLast) { return }
        Set-DbKeyValue -Key 'adb_wifi_switch_state' -Value $json
        $script:AdbWifiSwitchStateLast = $json
    } catch { }
}


function Get-AdbWifiCaptureModeDecision {
    <#
    .SYNOPSIS
    Should a RUNNING WiFi capture be restarted because of its WiFi ADB mode? @{ Restart; Reason; Dead }.

    .DESCRIPTION
    Called by Get-ScrcpyTransportDecision for a session launched over WiFi. -CurrentWifiMode and
    -CurrentEndpoint are what start-screenCopy stored ('Classic'/'TLS', 'ip:port');
    -LiveWifiMode is the live status AdbWifiMode (first mode, in preference order, that answers).
      1. Endpoint dead -> restart at once: the published TLS port of the serial moved (adbd was
         restarted, scrcpy hangs instead of exiting - S10-0), or the stored port refused TCP on
         2 checks in a row (one failed probe is not enough to cut a recording).
      2. Live mode differs from the session's (the preferred mode is back): scrcpy.usb_switch_mode
         'immediate' -> restart; 'stable' -> once the difference lasted -StableSec and not
         recording; 'next_start' -> never.
    State per headset id in $script:AdbWifiCaptureState. Never throws.

    .EXAMPLE
    Get-AdbWifiCaptureModeDecision -Headset $row -CurrentWifiMode TLS -CurrentEndpoint '192.168.1.242:40551' -LiveWifiMode Classic -Recording $false
    #>
    param(
        [Parameter(Mandatory = $true)] $Headset,
        [string]$CurrentWifiMode = '',
        [string]$CurrentEndpoint = '',
        [string]$LiveWifiMode = '',
        [bool]$Recording = $false,
        [string]$SwitchMode = '',
        [int]$StableSec = 0,
        [datetime]$Now = [datetime]::UtcNow
    )
    $d = [PSCustomObject]@{ Restart = $false; Reason = ''; Dead = $false }
    try {
        if ($null -eq $script:AdbWifiCaptureState) { $script:AdbWifiCaptureState = @{} }
        $key = [string]$Headset.ID
        if (-not $script:AdbWifiCaptureState.ContainsKey($key)) { $script:AdbWifiCaptureState[$key] = @{ MismatchSince = $null; DeadCount = 0; Endpoint = '' } }
        $st = $script:AdbWifiCaptureState[$key]
        if ($st.Endpoint -ne $CurrentEndpoint) { $st.Endpoint = $CurrentEndpoint; $st.DeadCount = 0; $st.MismatchSince = $null }
        if (-not $SwitchMode) { $SwitchMode = if ($global:scrcpyUsbSwitchMode) { [string]$global:scrcpyUsbSwitchMode } else { 'stable' } }
        if ($StableSec -le 0) { $StableSec = if ($global:scrcpyUsbSwitchStableSec) { [int]$global:scrcpyUsbSwitchStableSec } else { 10 } }

        # 1. dead endpoint
        $m = [regex]::Match($CurrentEndpoint, '^(?<ip>\d{1,3}(\.\d{1,3}){3}):(?<port>\d{1,5})$')
        if ($m.Success) {
            $ip = $m.Groups['ip'].Value; $port = [int]$m.Groups['port'].Value
            $dead = $false
            $k = Get-AdbWifiHeadsetKey -Headset $Headset
            if ($CurrentWifiMode -eq 'TLS' -and $k.Serial) {
                $ep = Find-AdbTlsEndpointBySerial -Serial $k.Serial
                if ($ep -and ([int]$ep.Port -ne $port -or [string]$ep.Ip -ne $ip)) { $dead = $true }
            }
            if (-not $dead -and (Get-Command Test-Port -ErrorAction SilentlyContinue)) {
                if ((Test-Port -hostname $ip -port $port -timeout 400).open) { $st.DeadCount = 0 }
                else {
                    $st.DeadCount = [int]$st.DeadCount + 1
                    if ($st.DeadCount -ge $script:AdbWifiEndpointDeadMax) { $dead = $true }
                }
            }
            if ($dead) {
                $d.Restart = $true; $d.Dead = $true
                $d.Reason = (Get-MessageString -Key 'AdbWifi.ScrcpyEndpointLost' -Fallback 'WiFi ADB endpoint {1} of {0} is gone - restarting the capture.') -f $Headset.Name, $CurrentEndpoint
                $script:AdbWifiCaptureState.Remove($key)
                return $d
            }
        }

        # 2. the preferred mode is back. Only ever TOWARDS the preferred mode of this process: a
        #    live status written with another mode order (a runspace that had not reloaded the
        #    config yet) would otherwise move the capture to the fallback, and the restart would
        #    put it straight back on the preferred mode - a restart every slow tick.
        #    With no preference ('auto', ADR-0037) a working capture is never moved.
        $preferred = Get-AdbWifiPreferredMode
        if ($preferred -and $CurrentWifiMode -in @('Classic', 'TLS') -and $LiveWifiMode -in @('Classic', 'TLS') -and $LiveWifiMode -ne $CurrentWifiMode -and
            $LiveWifiMode -eq $preferred) {
            if (-not $st.MismatchSince) { $st.MismatchSince = $Now }
            $go = $false
            if ($SwitchMode -eq 'immediate') { $go = $true }
            elseif ($SwitchMode -eq 'stable' -and -not $Recording -and (($Now - [datetime]$st.MismatchSince).TotalSeconds -ge $StableSec)) { $go = $true }
            if ($go) {
                $d.Restart = $true
                $d.Reason = (Get-MessageString -Key 'AdbWifi.ScrcpyModeSwitch' -Fallback 'WiFi ADB of {0} is now {2} - moving the capture from {1}.') -f $Headset.Name, (Get-AdbWifiModeText -Mode $CurrentWifiMode), (Get-AdbWifiModeText -Mode $LiveWifiMode)
                $script:AdbWifiCaptureState.Remove($key)
            }
        } else {
            $st.MismatchSince = $null
        }
    } catch { }
    return $d
}
