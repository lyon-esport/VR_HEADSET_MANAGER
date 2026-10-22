<#
.SYNOPSIS
    Headset-free tests of the ADB WiFi modes primitives (ADR-0034, task S10-1).

.DESCRIPTION
    - ConvertFrom-AdbMdnsServices on canned "adb mdns services" text.
    - Read-MdnsPacket / Read-DnsName on crafted packets (16-bit fields above 255: the [byte] -shl bug).
    - Publish-AdbTlsEndpoints / Get-PublishedAdbTlsEndpoints / Find-AdbTlsEndpointBySerial against an
      in-memory app_kv (Set-DbKeyValue / Get-DbKeyValue are replaced by fakes, no database needed).
    - S10-3: mode order from the config globals, endpoint and device resolution in preference order
      (Get-AdbWifiDevice and Test-Port replaced by fakes), adb id classification (USB / WiFi / TLS),
      Invoke-AdbCmd's one-shot fallback to the other WiFi mode, and the scrcpy command-line match
      on a TLS port.
    Prints PASS/FAIL per case; exit 1 when any case fails.

.EXAMPLE
    .\scripts\Test-AdbWifiModes.ps1
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'modules\mdns_scanner.ps1')
. (Join-Path $root 'modules\utils.ps1')
. (Join-Path $root 'modules\adb_wifi_modes.ps1')
. (Join-Path $root 'modules\adb_transport.ps1')

$script:fails = 0
$script:count = 0
function Assert-Case([string]$Name, [bool]$Condition, [string]$Detail = '') {
    $script:count++
    if ($Condition) { Write-Host ("[PASS] {0}" -f $Name) -ForegroundColor Green }
    else { $script:fails++; Write-Host ("[FAIL] {0} {1}" -f $Name, $Detail) -ForegroundColor Red }
}

# ------------------------------------------------------------------ parser
$canned = @"
List of discovered mdns services
adb-2G0YC5ZG1W00ZJ-AbC123`t_adb-tls-connect._tcp`t192.168.1.243:46443
adb-1WMHH8242N0366-f4JCQ1`t_adb-tls-connect._tcp`t192.168.1.242:38987
adb-1WMHH8242N0366`t_adb._tcp`t192.168.1.242:5555
adb-1WMHH8242N0366-xyz9`t_adb-tls-pairing._tcp`t192.168.1.242:41234
adb-2G0YC5ZG1W00ZJ-AbC123   _adb-tls-connect._tcp.   192.168.1.243:46443
"@
$p = @(ConvertFrom-AdbMdnsServices -Text $canned)
Assert-Case 'parser: 2 TLS endpoints (pairing, classic and duplicate ignored)' ($p.Count -eq 2) ("got {0}" -f $p.Count)
$q3 = $p | Where-Object Serial -eq '2G0YC5ZG1W00ZJ'
$q2 = $p | Where-Object Serial -eq '1WMHH8242N0366'
Assert-Case 'parser: Quest 3 ip/port/name' ($q3 -and $q3.Ip -eq '192.168.1.243' -and $q3.Port -eq 46443 -and $q3.Name -eq 'adb-2G0YC5ZG1W00ZJ-AbC123') ("got {0}:{1} {2}" -f $q3.Ip, $q3.Port, $q3.Name)
Assert-Case 'parser: Quest 2 TLS port (not the classic 5555)' ($q2 -and $q2.Port -eq 38987) ("got {0}" -f $q2.Port)
Assert-Case 'parser: Port is an int' ($q2.Port -is [int])
$pa = @(ConvertFrom-AdbMdnsServices -Text ($canned -split "`r?`n"))
Assert-Case 'parser: string[] input (Invoke-Adb StdOut shape)' ($pa.Count -eq 2)
Assert-Case 'parser: $null input -> empty' (@(ConvertFrom-AdbMdnsServices -Text $null).Count -eq 0)
Assert-Case 'parser: header only -> empty' (@(ConvertFrom-AdbMdnsServices -Text 'List of discovered mdns services').Count -eq 0)

# ------------------------------------------------------------------ mDNS packet (bytes above 255)
function New-DnsNameBytes([string]$Name) {
    $b = New-Object System.Collections.Generic.List[byte]
    foreach ($label in $Name.Split('.')) { $b.Add([byte]$label.Length); $b.AddRange([Text.Encoding]::ASCII.GetBytes($label)) }
    $b.Add(0); return ,$b.ToArray()
}
$pkt = New-Object System.Collections.Generic.List[byte]
$pkt.AddRange([byte[]](0,0, 0x84,0, 0,0, 0,1, 0,0, 0,0))          # header: 1 answer
$pkt.AddRange((New-DnsNameBytes 'adb-SERIAL-rand._adb-tls-connect._tcp.local'))
$target = New-DnsNameBytes 'Quest.local'
$pkt.AddRange([byte[]](0,33, 0,1, 0,0,0,120))                    # type SRV, class IN, ttl
$rdLen = 6 + $target.Length
$pkt.AddRange([byte[]](([int]$rdLen -shr 8), ($rdLen -band 0xFF)))
$pkt.AddRange([byte[]](0,0, 0,0, 0xB5,0x6B))                     # priority, weight, port 46443
$pkt.AddRange($target)
$recs = @(Read-MdnsPacket -Data $pkt.ToArray())
$srv = $recs | Where-Object { $_.Type -eq 'SRV' } | Select-Object -First 1
Assert-Case 'mDNS: SRV port 46443 (high byte kept)' ($srv -and [int]$srv.Port -eq 46443) ("got {0}" -f $(if ($srv) { $srv.Port } else { 'no SRV record' }))
Assert-Case 'mDNS: SRV target name' ($srv -and $srv.Target -eq 'Quest.local') ("got {0}" -f $srv.Target)

# Name compression pointer to an offset above 255 (0xC1 0x02 -> 258).
$buf = New-Object byte[] 280
$buf[0] = 0xC1; $buf[1] = 0x02
$nm = New-DnsNameBytes 'x.local'
[Array]::Copy($nm, 0, $buf, 258, $nm.Length)
$dn = Read-DnsName -Data $buf -Offset 0
Assert-Case 'mDNS: compression pointer above 255' ($dn.Name -eq 'x.local' -and $dn.NextOffset -eq 2) ("got '{0}' next={1}" -f $dn.Name, $dn.NextOffset)

# ------------------------------------------------------------------ publish / read (in-memory app_kv)
$script:kv = @{}
$script:kvWrites = 0
function Set-DbKeyValue { param([string]$Key, $Value) $script:kvWrites++; $script:kv[$Key] = [string]$Value }
function Get-DbKeyValue { param([string]$Key, $Default = $null) if ($script:kv.ContainsKey($Key)) { return ($script:kv[$Key] | ConvertFrom-Json) } else { return $Default } }
function Reset-TlsState { $script:AdbTlsLastSet = $null; $script:AdbTlsLastShape = $null; $script:AdbTlsLastWriteAt = $null; $script:AdbTlsCache = $null; $script:AdbTlsCacheAt = $null; $script:kv = @{}; $script:kvWrites = 0 }
$global:HeadsetDiscovery_interval_sec = 10        # stale after 30 s, refresh write every 10 s

Reset-TlsState
Assert-Case 'publish: empty store reads as empty' (@(Get-PublishedAdbTlsEndpoints).Count -eq 0)
$set1 = @(Publish-AdbTlsEndpoints -Endpoints $p)
Assert-Case 'publish: 2 entries written once' ($set1.Count -eq 2 -and $script:kvWrites -eq 1) ("count={0} writes={1}" -f $set1.Count, $script:kvWrites)
Assert-Case 'publish: stored as a JSON array' ($script:kv['adb_tls_endpoints'].StartsWith('['))
$script:AdbTlsCache = $null
$got = @(Get-PublishedAdbTlsEndpoints)
Assert-Case 'read: 2 fresh entries' ($got.Count -eq 2) ("got {0}" -f $got.Count)
$f = Find-AdbTlsEndpointBySerial -Serial '1WMHH8242N0366'
Assert-Case 'find: by serial' ($f -and $f.Port -eq 38987 -and $f.Ip -eq '192.168.1.242')
Assert-Case 'find: unknown serial -> $null' ($null -eq (Find-AdbTlsEndpointBySerial -Serial 'NOPE'))

[void](Publish-AdbTlsEndpoints -Endpoints $p)
Assert-Case 'publish: same set again -> no write' ($script:kvWrites -eq 1) ("writes={0}" -f $script:kvWrites)

[void](Publish-AdbTlsEndpoints -Endpoints @($q3))
$script:AdbTlsCache = $null
Assert-Case 'publish: a headset missed in one pass is kept' (@(Get-PublishedAdbTlsEndpoints).Count -eq 2 -and $script:kvWrites -eq 1) ("writes={0}" -f $script:kvWrites)

$moved = [PSCustomObject]@{ Serial = '1WMHH8242N0366'; Ip = '192.168.1.242'; Port = 34941; Name = 'x' }
[void](Publish-AdbTlsEndpoints -Endpoints @($q3, $moved))
$script:AdbTlsCache = $null
Assert-Case 'publish: new TLS port is written' ($script:kvWrites -eq 2 -and (Find-AdbTlsEndpointBySerial -Serial '1WMHH8242N0366').Port -eq 34941) ("writes={0}" -f $script:kvWrites)

$script:AdbTlsLastWriteAt = [datetime]::UtcNow.AddSeconds(-11)
[void](Publish-AdbTlsEndpoints -Endpoints @($q3, $moved))
Assert-Case 'publish: unchanged set refreshed after one interval' ($script:kvWrites -eq 3) ("writes={0}" -f $script:kvWrites)

# Stale entries: stored Seen 40 s ago, stale limit 30 s.
Reset-TlsState
$old = [datetime]::UtcNow.AddSeconds(-40).ToString('o')
$fresh = [datetime]::UtcNow.ToString('o')
$script:kv['adb_tls_endpoints'] = ConvertTo-Json -Compress -InputObject @(
    [PSCustomObject]@{ Serial = 'OLD1'; Ip = '10.0.0.5'; Port = 40001; Seen = $old },
    [PSCustomObject]@{ Serial = 'NEW1'; Ip = '10.0.0.6'; Port = 40002; Seen = $fresh })
Assert-Case 'read: stale entry dropped' (@(Get-PublishedAdbTlsEndpoints).Count -eq 1 -and (@(Get-PublishedAdbTlsEndpoints)[0].Serial -eq 'NEW1'))
Assert-Case 'read: -IncludeStale keeps it' (@(Get-PublishedAdbTlsEndpoints -IncludeStale).Count -eq 2)
$after = @(Publish-AdbTlsEndpoints -Endpoints @())
Assert-Case 'publish: stale entry removed from the row, fresh one kept' ($after.Count -eq 1 -and $after[0].Serial -eq 'NEW1' -and $script:kv['adb_tls_endpoints'] -notmatch 'OLD1')

# Memo: a change in the store is not seen within MaxAgeSec, seen with -MaxAgeSec 0.
Reset-TlsState
$script:kv['adb_tls_endpoints'] = ConvertTo-Json -Compress -InputObject @([PSCustomObject]@{ Serial = 'A'; Ip = '10.0.0.7'; Port = 40003; Seen = $fresh })
[void](Get-PublishedAdbTlsEndpoints)
$script:kv['adb_tls_endpoints'] = '[]'
Assert-Case 'read: memoised within 2 s' (@(Get-PublishedAdbTlsEndpoints).Count -eq 1)
Assert-Case 'read: -MaxAgeSec 0 re-reads' (@(Get-PublishedAdbTlsEndpoints -MaxAgeSec 0).Count -eq 0)

# Single-element row (ConvertFrom-Json returns a lone object, not an array).
Reset-TlsState
$script:kv['adb_tls_endpoints'] = '[{"Serial":"S1","Ip":"10.0.0.8","Port":40004,"Seen":"' + $fresh + '"}]'
Assert-Case 'read: single-element row' (@(Get-PublishedAdbTlsEndpoints).Count -eq 1)
$script:kv['adb_tls_endpoints'] = 'not json'
$script:AdbTlsCache = $null
Assert-Case 'read: unreadable row -> empty, no throw' (@(Get-PublishedAdbTlsEndpoints).Count -eq 0)

# ------------------------------------------------------------------ S10-3: mode-aware resolution
$script:logLines = @()
function Write-Log { param($Message, $Level = 'INFO') $script:logLines += ('{0}|{1}' -f $Level, $Message) }
$global:msg = Import-PowerShellDataFile -LiteralPath (Join-Path $root 'modules\translations\en-US.psd1')
$global:adbPort_default = 5555
function Set-Modes([bool]$Classic, [bool]$Tls, [string]$Pref) {
    $global:ADB_wifi_classic_enabled = $Classic; $global:ADB_wifi_tls_enabled = $Tls
    $global:ADB_wifi_preferred_mode = $Pref; $global:ADB_wifi_effective_preferred = $Pref
    if ($Pref -eq 'classic' -and -not $Classic) { $global:ADB_wifi_effective_preferred = 'tls' }
    if ($Pref -eq 'tls' -and -not $Tls) { $global:ADB_wifi_effective_preferred = 'classic' }
}

Set-Modes $true $true 'classic'
Assert-Case 'order: default = Classic, TLS' ((@(Get-AdbWifiModeOrder) -join ',') -eq 'Classic,TLS')
Set-Modes $true $true 'tls'
Assert-Case 'order: tls preferred = TLS, Classic' ((@(Get-AdbWifiModeOrder) -join ',') -eq 'TLS,Classic')
Set-Modes $false $true 'classic'
Assert-Case 'order: classic disabled = TLS only' ((@(Get-AdbWifiModeOrder) -join ',') -eq 'TLS')
Set-Modes $true $false 'tls'
Assert-Case 'order: tls disabled = Classic only' ((@(Get-AdbWifiModeOrder) -join ',') -eq 'Classic')
Remove-Variable -Name ADB_wifi_classic_enabled, ADB_wifi_tls_enabled, ADB_wifi_preferred_mode, ADB_wifi_effective_preferred -Scope Global -ErrorAction SilentlyContinue
Assert-Case 'order: no globals = Classic, TLS' ((@(Get-AdbWifiModeOrder) -join ',') -eq 'Classic,TLS')

$global:adbPort_default = 70000
Assert-Case 'classic port: out of range -> 5555' ((Get-ClassicAdbPort) -eq 5555)
$global:adbPort_default = 5600
Assert-Case 'classic port: from config' ((Get-ClassicAdbPort) -eq 5600)
$global:adbPort_default = 5555

# Published set: Q2 on TLS 38987, Q3 has nothing published.
Reset-TlsState
$script:kv['adb_tls_endpoints'] = ConvertTo-Json -Compress -InputObject @([PSCustomObject]@{ Serial = '1WMHH8242N0366'; Ip = '192.168.1.242'; Port = 38987; Seen = [datetime]::UtcNow.ToString('o') })
$q2Row = [PSCustomObject]@{ ID = 2; Name = 'Q2'; IPAddress = '192.168.1.242'; SerialNumber = '1WMHH8242N0366' }
$q3Row = [PSCustomObject]@{ ID = 3; Name = 'Q3'; IPAddress = '192.168.1.243'; SerialNumber = '2G0YC5ZG1W00ZJ' }
$unk   = [PSCustomObject]@{ ID = 4; Name = 'U';  IPAddress = '127.0.0.3';     SerialNumber = '1WMHH8242N0366' }

$e = Resolve-HeadsetWifiEndpoint -Headset $q2Row -Mode Classic
Assert-Case 'endpoint: classic = registry ip + config port' ($e -and $e.Ip -eq '192.168.1.242' -and $e.Port -eq 5555)
$e = Resolve-HeadsetWifiEndpoint -Headset $q2Row -Mode TLS
Assert-Case 'endpoint: TLS = published endpoint of the serial' ($e -and $e.Port -eq 38987 -and $e.Mode -eq 'TLS')
Assert-Case 'endpoint: TLS without a published entry -> $null' ($null -eq (Resolve-HeadsetWifiEndpoint -Headset $q3Row -Mode TLS))
Assert-Case 'endpoint: classic for an unknown (127.x) address -> $null' ($null -eq (Resolve-HeadsetWifiEndpoint -Headset $unk -Mode Classic))
Assert-Case 'endpoint: TLS still found for an unknown address (serial-keyed)' ($null -ne (Resolve-HeadsetWifiEndpoint -Headset $unk -Mode TLS))

# Fake Get-AdbWifiDevice: only the endpoints listed in $script:upEndpoints answer.
$script:wifiCalls = @()
function Get-AdbWifiDevice { param([string]$headsetIP, [int]$AdbPort, [string]$adb, [switch]$Quiet)
    $id = '{0}:{1}' -f $headsetIP, $AdbPort
    $script:wifiCalls += ('{0}{1}' -f $id, $(if ($Quiet) { ' quiet' } else { '' }))
    if ($script:upEndpoints -contains $id) { return [PSCustomObject]@{ DeviceId = $id; ConnectionType = 'WiFi'; IP = $headsetIP; Port = $AdbPort } }
    return $null
}

Set-Modes $true $true 'classic'
$script:upEndpoints = @('192.168.1.242:5555', '192.168.1.242:38987'); $script:wifiCalls = @(); $script:logLines = @()
$d = Resolve-HeadsetWifiDevice -Headset $q2Row
Assert-Case 'resolve: both up, classic preferred -> Classic, one attempt' ($d -and $d.WifiMode -eq 'Classic' -and $d.DeviceId -eq '192.168.1.242:5555' -and $script:wifiCalls.Count -eq 1) ("calls={0}" -f ($script:wifiCalls -join ';'))
Assert-Case 'resolve: device carries serial / HeadsetIP / HeadsetPort' ($d.SerialNumber -eq '1WMHH8242N0366' -and $d.HeadsetIP -eq '192.168.1.242' -and $d.HeadsetPort -eq 5555 -and $d.ConnectionType -eq 'WiFi')

$script:upEndpoints = @('192.168.1.242:38987'); $script:wifiCalls = @(); $script:logLines = @()
$d = Resolve-HeadsetWifiDevice -Headset $q2Row
Assert-Case 'resolve: classic closed -> falls back to TLS' ($d -and $d.WifiMode -eq 'TLS' -and $d.Port -eq 38987)
Assert-Case 'resolve: first (non-last) attempt is quiet' ($script:wifiCalls[0] -eq '192.168.1.242:5555 quiet' -and $script:wifiCalls[1] -eq '192.168.1.242:38987') ("calls={0}" -f ($script:wifiCalls -join ';'))
Assert-Case 'resolve: DEBUG line names the non-preferred mode' (@($script:logLines | Where-Object { $_ -like 'DEBUG|*Classic WiFi ADB unavailable, using TLS*' }).Count -eq 1) ($script:logLines -join ' / ')

$script:upEndpoints = @('192.168.1.243:5555'); $script:wifiCalls = @()
$d = Resolve-HeadsetWifiDevice -Headset $q3Row
Assert-Case 'resolve: classic-only fleet = exactly one loud attempt (as before S10-3)' ($d -and $d.WifiMode -eq 'Classic' -and $script:wifiCalls.Count -eq 1 -and $script:wifiCalls[0] -eq '192.168.1.243:5555') ("calls={0}" -f ($script:wifiCalls -join ';'))
$script:upEndpoints = @(); $script:wifiCalls = @()
Assert-Case 'resolve: classic-only headset down -> $null, last attempt loud' ($null -eq (Resolve-HeadsetWifiDevice -Headset $q3Row) -and $script:wifiCalls[0] -eq '192.168.1.243:5555')

Set-Modes $true $true 'tls'
$script:upEndpoints = @('192.168.1.242:5555', '192.168.1.242:38987'); $script:wifiCalls = @()
$d = Resolve-HeadsetWifiDevice -Headset $q2Row
Assert-Case 'resolve: tls preferred -> TLS first' ($d -and $d.WifiMode -eq 'TLS' -and $script:wifiCalls.Count -eq 1)
$d = Resolve-HeadsetWifiDevice -Headset $q2Row -ExcludeMode TLS
Assert-Case 'resolve: -ExcludeMode TLS -> Classic' ($d -and $d.WifiMode -eq 'Classic')
Set-Modes $false $true 'classic'
$script:upEndpoints = @('192.168.1.242:5555')
Assert-Case 'resolve: classic disabled -> never tried' ($null -eq (Resolve-HeadsetWifiDevice -Headset $q2Row))

# Resolve-HeadsetAdbDevice: USB rule unchanged, WiFi through the modes.
Set-Modes $true $true 'classic'
function Get-PublishedUsbDevices { param([int]$MaxAgeSec = 2, [switch]$IncludeDead) return @($script:usbSet) }
function Test-UsbBusy { return $false }
$script:usbSet = @(); $script:upEndpoints = @('192.168.1.242:38987')
$d = Resolve-HeadsetAdbDevice -Headset $q2Row
Assert-Case 'resolver: not cabled, TLS only -> WiFi TLS device' ($d -and $d.ConnectionType -eq 'WiFi' -and $d.WifiMode -eq 'TLS')
$script:usbSet = @([PSCustomObject]@{ Serial = '1WMHH8242N0366'; State = 'device'; Since = 'x' })
$global:ADB_prefer_usb = $true
$d = Resolve-HeadsetAdbDevice -Headset $q2Row
Assert-Case 'resolver: cabled -> USB (ADR-0024 unchanged)' ($d -and $d.ConnectionType -eq 'USB' -and $d.DeviceId -eq '1WMHH8242N0366')
$d = Resolve-HeadsetAdbDevice -Headset $q2Row -PreferTransport WiFi
Assert-Case 'resolver: -PreferTransport WiFi -> WiFi first' ($d -and $d.ConnectionType -eq 'WiFi' -and $d.WifiMode -eq 'TLS')
$script:usbSet = @()

# Fallback device for a failed WiFi transport.
$cls = [PSCustomObject]@{ DeviceId = '192.168.1.242:5555'; ConnectionType = 'WiFi'; IP = '192.168.1.242'; Port = 5555; SerialNumber = '1WMHH8242N0366'; HeadsetIP = '192.168.1.242'; HeadsetPort = 5555; WifiMode = 'Classic' }
$script:upEndpoints = @('192.168.1.242:38987')
$alt = Get-AdbWifiModeFallbackDevice -Device $cls
Assert-Case 'fallback: Classic -> TLS' ($alt -and $alt.WifiMode -eq 'TLS' -and $alt.Port -eq 38987)
$plain = [PSCustomObject]@{ DeviceId = '192.168.1.242:38987'; ConnectionType = 'WiFi'; IP = '192.168.1.242'; Port = 38987 }
$script:upEndpoints = @('192.168.1.242:5555')
$alt = Get-AdbWifiModeFallbackDevice -Device $plain
Assert-Case 'fallback: bare TLS ip:port (no WifiMode) -> Classic' ($alt -and $alt.WifiMode -eq 'Classic' -and $alt.Port -eq 5555)
Set-Modes $true $false 'classic'
Assert-Case 'fallback: one mode enabled -> $null' ($null -eq (Get-AdbWifiModeFallbackDevice -Device $cls))
Set-Modes $true $true 'classic'

# Invoke-AdbCmd: a transport failure on Classic is retried ONCE over TLS, device updated in place.
$script:adbCalls = @()
function Invoke-Adb { param([string[]]$Arguments, [string]$Adb, [int]$TimeoutSeconds = 15)
    $script:adbCalls += ($Arguments -join ' ')
    if ($Arguments[0] -eq '-s' -and $Arguments[1] -eq '192.168.1.242:38987') { return @{ ExitCode = 0; StdOut = @('Quest 2'); StdErr = @(); Ok = $true } }
    if ($Arguments[0] -eq '-s') { return @{ ExitCode = 1; StdOut = @(); StdErr = @("error: device '" + $Arguments[1] + "' not found"); Ok = $false } }
    return @{ ExitCode = 0; StdOut = @(); StdErr = @(); Ok = $true }
}
$script:openPorts = @('192.168.1.242:38987')
function Test-Port { param([string]$hostname, [int]$port, [int]$timeout = 200) return @{ open = ($script:openPorts -contains ('{0}:{1}' -f $hostname, $port)) } }
$script:upEndpoints = @('192.168.1.242:38987'); $script:adbCalls = @()
$dev = [PSCustomObject]@{ DeviceId = '192.168.1.242:5555'; ConnectionType = 'WiFi'; IP = '192.168.1.242'; Port = 5555; SerialNumber = '1WMHH8242N0366'; HeadsetIP = '192.168.1.242'; HeadsetPort = 5555; WifiMode = 'Classic' }
$out = Invoke-AdbCmd -Device $dev -Command 'shell getprop ro.product.model' -adb $PSCommandPath
Assert-Case 'Invoke-AdbCmd: classic dead -> answered over TLS' ((@($out) -join '') -eq 'Quest 2') ("calls={0}" -f ($script:adbCalls -join ' ; '))
Assert-Case 'Invoke-AdbCmd: caller device updated in place' ($dev.DeviceId -eq '192.168.1.242:38987' -and $dev.Port -eq 38987 -and $dev.WifiMode -eq 'TLS' -and $dev.ConnectionType -eq 'WiFi')
Assert-Case 'Invoke-AdbCmd: exactly two command attempts (no chained fallback)' (@($script:adbCalls | Where-Object { $_ -like '-s *getprop*' }).Count -eq 2)
$script:upEndpoints = @(); $script:adbCalls = @()
$dev = [PSCustomObject]@{ DeviceId = '192.168.1.242:5555'; ConnectionType = 'WiFi'; IP = '192.168.1.242'; Port = 5555; SerialNumber = '1WMHH8242N0366'; HeadsetIP = '192.168.1.242'; HeadsetPort = 5555; WifiMode = 'Classic' }
$threw = $false; try { Invoke-AdbCmd -Device $dev -Command 'shell getprop ro.product.model' -adb $PSCommandPath | Out-Null } catch { $threw = $true }
Assert-Case 'Invoke-AdbCmd: no other mode answering -> original exception' $threw

# Stage 1 probe (TCP only).
$script:openPorts = @('192.168.1.242:38987')
$w = Test-HeadsetWifiAdbUp -Headset $q2Row -PingOk $true
Assert-Case 'stage 1: classic closed, TLS answering -> Up TLS' ($w.Up -and $w.Mode -eq 'TLS')
$script:openPorts = @('192.168.1.242:5555', '192.168.1.242:38987')
$w = Test-HeadsetWifiAdbUp -Headset $q2Row -PingOk $true
Assert-Case 'stage 1: both open, classic preferred -> Classic' ($w.Up -and $w.Mode -eq 'Classic')
$w = Test-HeadsetWifiAdbUp -Headset $q2Row -PingOk $false
Assert-Case 'stage 1: no ping, TLS on the same address -> not probed' (-not $w.Up -and $w.Mode -eq '-')
$script:openPorts = @()
Assert-Case 'stage 1: nothing answering -> Up false, Mode -' (-not (Test-HeadsetWifiAdbUp -Headset $q3Row).Up)

# adb id classification.
Assert-Case 'id: serial is USB' (Test-AdbDeviceIdIsUsb '2G0YC5ZG1W00ZJ')
Assert-Case 'id: ip:port is not USB' (-not (Test-AdbDeviceIdIsUsb '192.168.1.243:5555'))
Assert-Case 'id: mDNS TLS id is not USB' (-not (Test-AdbDeviceIdIsUsb 'adb-1WMHH8242N0366-f4JCQ1._adb-tls-connect._tcp'))
Assert-Case 'id: mDNS TLS id is TLS' (Test-AdbDeviceIdIsTls 'adb-1WMHH8242N0366-f4JCQ1._adb-tls-connect._tcp')
Assert-Case 'id: empty is not USB' (-not (Test-AdbDeviceIdIsUsb ''))

# scrcpy command line on a TLS port (Test-ScrcpyCommandLineTarget matches -s ip:anyport).
$cl = 'scrcpy.exe -s 192.168.1.242:38987 --crop=1:1:0:0 --window-title=Q2'
Assert-Case 'scrcpy: -s ip:<TLS port> matches the headset' (Test-ScrcpyCommandLineTarget -CommandLine $cl -IPAddress '192.168.1.242')
Assert-Case 'scrcpy: TLS port does not match a prefix IP' (-not (Test-ScrcpyCommandLineTarget -CommandLine $cl -IPAddress '192.168.1.24'))
# S10-4: sweep merge (same serial found in both modes -> one result, first = classic wins).
. (Join-Path $root 'modules\headsets_discovery.ps1')
$m = @(Merge-DiscoveredHeadsetHits -Hits @(
    @{ SerialNumber = 'A'; Mode = 'Classic'; IPAddress = '10.0.0.1' },
    @{ SerialNumber = 'B'; Mode = 'TLS'; IPAddress = '10.0.0.2' },
    @{ SerialNumber = 'A'; Mode = 'TLS'; IPAddress = '10.0.0.1' },
    @{ SerialNumber = ''; Mode = 'TLS' }))
Assert-Case 'sweep merge: same serial in both modes -> one result' ($m.Count -eq 2)
Assert-Case 'sweep merge: classic hit kept for the duplicated serial' (($m | Where-Object { $_.SerialNumber -eq 'A' }).Mode -eq 'Classic')
Assert-Case 'sweep merge: TLS-only serial kept with Mode TLS' (($m | Where-Object { $_.SerialNumber -eq 'B' }).Mode -eq 'TLS')
Assert-Case 'sweep merge: empty input -> empty' (@(Merge-DiscoveredHeadsetHits -Hits @()).Count -eq 0)

# ------------------------------------------------------------------ S10-5: switch to the preferred mode
$script:mdnsText = @(); $script:mdnsOk = $true; $script:adbCalls = @(); $script:checks = @(); $script:identity = @(); $script:tlsEnables = @()
$script:propSerial = '1WMHH8242N0366'
function Invoke-Adb { param([string[]]$Arguments, [string]$Adb, [int]$TimeoutSeconds = 15)
    $script:adbCalls += ($Arguments -join ' ')
    if ($Arguments[0] -eq 'mdns') { return @{ ExitCode = $(if ($script:mdnsOk) { 0 } else { 1 }); StdOut = @($script:mdnsText); StdErr = @(); Ok = $script:mdnsOk } }
    return @{ ExitCode = 0; StdOut = @(); StdErr = @(); Ok = $true }
}
function Get-AdbPropBatch { param($Device, [string[]]$Properties, [switch]$IncludeWlanIp, [int]$TimeoutSeconds = 10, [string]$adb) return @{ 'ro.serialno' = $script:propSerial } }
function Enable-HeadsetAdbTls { param($Device) $script:tlsEnables += $Device.DeviceId; return [PSCustomObject]@{ Ok = $true; Output = ''; Error = $null } }
function Request-ScrcpyCheck { param([int[]]$HeadsetId, [switch]$All, [switch]$NoMark, [string]$Reason) $script:checks += ('{0}|{1}' -f ($HeadsetId -join ','), [bool]$NoMark); return $HeadsetId }
function Set-HeadsetIdentity { param($SerialNumber, $IPAddress, $Source) $script:identity += ('{0}|{1}' -f $SerialNumber, $IPAddress) }
function Reset-SwitchState {
    Reset-TlsState
    $script:AdbWifiSwitchMemo = $null; $script:AdbTlsPolledAt = $null; $script:AdbTlsFastUntil = $null; $script:AdbTlsMisses = $null; $script:AdbWifiCaptureState = $null
    $script:AdbWifiPrefSig = $null; $script:AdbWifiSwitchStateLast = $null
    $script:adbCalls = @(); $script:checks = @(); $script:identity = @(); $script:tlsEnables = @(); $script:logLines = @()
    $script:usbSet = @(); $script:openPorts = @(); $script:upEndpoints = @(); $script:mdnsOk = $true
}
$mdnsQ2 = { param($port) @('List of discovered mdns services', ('adb-1WMHH8242N0366-f4JCQ1' + "`t" + '_adb-tls-connect._tcp' + "`t" + '192.168.1.242:' + $port)) }
$infoTls     = @{ '192.168.1.242' = [PSCustomObject]@{ ID = 2; AdbWifiMode = 'TLS';     SCRCPY = '-' } }
$infoClassic = @{ '192.168.1.242' = [PSCustomObject]@{ ID = 2; AdbWifiMode = 'Classic'; SCRCPY = '-' } }
$t0 = [datetime]::UtcNow
$global:scrcpyUsbSwitchMode = 'stable'; $global:scrcpyUsbSwitchStableSec = 10; $global:ADB_prefer_usb = $true

# Pure decision table.
Set-Modes $true $true 'classic'
$dd = { param($info, $o) $p = @{ Headset = $q2Row; Info = $info }; foreach ($k in $o.Keys) { $p[$k] = $o[$k] }; Get-AdbWifiModeSwitchDecision @p }
Assert-Case 'decide: TLS, classic preferred -> ToClassic' ((& $dd $infoTls['192.168.1.242'] @{}).Action -eq 'ToClassic')
Assert-Case 'decide: already on classic -> none' ((& $dd $infoClassic['192.168.1.242'] @{}).Action -eq 'none')
Assert-Case 'decide: not reachable over WiFi -> none' ((& $dd ([PSCustomObject]@{ AdbWifiMode = '-' }) @{}).Action -eq 'none')
Assert-Case 'decide: cabled + prefer_usb -> none' ((& $dd $infoTls['192.168.1.242'] @{ Cabled = $true }).Action -eq 'none')
$global:ADB_prefer_usb = $false
Assert-Case 'decide: cabled without prefer_usb -> ToClassic' ((& $dd $infoTls['192.168.1.242'] @{ Cabled = $true }).Action -eq 'ToClassic')
$global:ADB_prefer_usb = $true
Assert-Case 'decide: USB busy -> none' ((& $dd $infoTls['192.168.1.242'] @{ UsbBusy = $true }).Action -eq 'none')
Assert-Case 'decide: benchmark -> none' ((& $dd $infoTls['192.168.1.242'] @{ Benchmark = $true }).Action -eq 'none')
Assert-Case 'decide: shutting down -> none' ((& $dd $infoTls['192.168.1.242'] @{ ShuttingDown = $true }).Action -eq 'none')
$cap = & $dd $infoTls['192.168.1.242'] @{ Capturing = $true; SwitchMode = 'stable' }
Assert-Case 'decide: capturing + stable -> deferred' ($cap.Action -eq 'none' -and $cap.Deferred)
Assert-Case 'decide: capturing + next_start -> deferred' ((& $dd $infoTls['192.168.1.242'] @{ Capturing = $true; SwitchMode = 'next_start' }).Action -eq 'none')
Assert-Case 'decide: capturing + immediate -> ToClassic' ((& $dd $infoTls['192.168.1.242'] @{ Capturing = $true; SwitchMode = 'immediate' }).Action -eq 'ToClassic')
Assert-Case 'decide: backoff not over -> none' ((& $dd $infoTls['192.168.1.242'] @{ Memo = @{ NextAt = $t0.AddSeconds(30) }; Now = $t0 }).Action -eq 'none')
Assert-Case 'decide: no serial -> none' ((Get-AdbWifiModeSwitchDecision -Headset ([PSCustomObject]@{ ID = 9; Name = 'X'; IPAddress = '10.0.0.9'; SerialNumber = '-' }) -Info $infoTls['192.168.1.242']).Action -eq 'none')
Set-Modes $true $false 'classic'
Assert-Case 'decide: only one mode enabled -> none' ((& $dd $infoTls['192.168.1.242'] @{}).Action -eq 'none')
Set-Modes $true $true 'tls'
Assert-Case 'decide: classic, TLS preferred -> ToTLS' ((& $dd $infoClassic['192.168.1.242'] @{}).Action -eq 'ToTLS')
Assert-Case 'decide: capturing does not block ToTLS' ((& $dd $infoClassic['192.168.1.242'] @{ Capturing = $true }).Action -eq 'ToTLS')

# TLS -> classic: issue on one tick, confirm on the next, TLS re-published on its new port.
Set-Modes $true $true 'classic'
Reset-SwitchState
$script:mdnsText = & $mdnsQ2 38987; $script:upEndpoints = @('192.168.1.242:38987')
$r = Update-AdbWifiModeState -KnownHeadsets @($q2Row) -HeadsetInfo $infoTls -ScrcpyPids @{} -Now $t0
Assert-Case 'switch: TLS endpoint published by the refresh' ((Find-AdbTlsEndpointBySerial -Serial '1WMHH8242N0366' -MaxAgeSec 0).Port -eq 38987)
Assert-Case 'switch: tcpip issued over the TLS session' ($r.Issued -contains 'Q2' -and $script:adbCalls -contains '-s 192.168.1.242:38987 tcpip 5555') ($script:adbCalls -join ' ; ')
Assert-Case 'switch: no INFO yet (not confirmed)' (@($script:logLines | Where-Object { $_ -like 'INFO|Switched*' }).Count -eq 0)
$script:mdnsText = & $mdnsQ2 34941; $script:openPorts = @('192.168.1.242:5555'); $script:upEndpoints = @('192.168.1.242:5555', '192.168.1.242:34941')
$r = Update-AdbWifiModeState -KnownHeadsets @($q2Row) -HeadsetInfo $infoTls -ScrcpyPids @{} -Now $t0.AddSeconds(2)
Assert-Case 'switch: confirmed once classic answers with the right serial' ($r.Switched -contains 'Q2')
Assert-Case 'switch: one INFO line' (@($script:logLines | Where-Object { $_ -like 'INFO|Switched Q2 from TLS to classic*' }).Count -eq 1) ($script:logLines -join ' / ')
Assert-Case 'switch: watchdog nudged with -NoMark' ($script:checks -contains '2|True')
Assert-Case 'switch: fast refresh re-published the NEW TLS port' ((Find-AdbTlsEndpointBySerial -Serial '1WMHH8242N0366' -MaxAgeSec 0).Port -eq 34941)
Assert-Case 'switch: registry address unchanged -> no identity write' ($script:identity.Count -eq 0)
$script:adbCalls = @()
$r = Update-AdbWifiModeState -KnownHeadsets @($q2Row) -HeadsetInfo $infoClassic -ScrcpyPids @{} -Now $t0.AddSeconds(4)
Assert-Case 'switch: now on classic -> nothing issued (no flapping)' ($r.Issued.Count -eq 0 -and -not ($script:adbCalls -match 'tcpip'))

# Capturing headset: stable defers (one DEBUG line), immediate issues.
Reset-SwitchState
$script:mdnsText = & $mdnsQ2 38987; $script:upEndpoints = @('192.168.1.242:38987')
$r = Update-AdbWifiModeState -KnownHeadsets @($q2Row) -HeadsetInfo $infoTls -ScrcpyPids @{ '2' = 4242 } -Now $t0
$r2 = Update-AdbWifiModeState -KnownHeadsets @($q2Row) -HeadsetInfo $infoTls -ScrcpyPids @{ '2' = 4242 } -Now $t0.AddSeconds(6)
Assert-Case 'capture + stable: tcpip not issued' ($r.Issued.Count -eq 0 -and $r2.Issued.Count -eq 0 -and -not ($script:adbCalls -match 'tcpip'))
Assert-Case 'capture + stable: one DEBUG line only' (@($script:logLines | Where-Object { $_ -like 'DEBUG|*waits until the capture stops*' }).Count -eq 1)
$global:scrcpyUsbSwitchMode = 'immediate'
$r = Update-AdbWifiModeState -KnownHeadsets @($q2Row) -HeadsetInfo $infoTls -ScrcpyPids @{ '2' = 4242 } -Now $t0.AddSeconds(12)
Assert-Case 'capture + immediate: tcpip issued' ($r.Issued -contains 'Q2')
$global:scrcpyUsbSwitchMode = 'stable'

# Not confirmed in time -> failure; retry after 60 s; after 3 failures the preferred mode is given
# up (ONE WARNING) until the preference changes or the headset drops off WiFi ADB and comes back.
Reset-SwitchState
$script:mdnsText = & $mdnsQ2 38987; $script:upEndpoints = @('192.168.1.242:38987')
[void](Update-AdbWifiModeState -KnownHeadsets @($q2Row) -HeadsetInfo $infoTls -Now $t0)
$r = Update-AdbWifiModeState -KnownHeadsets @($q2Row) -HeadsetInfo $infoTls -Now $t0.AddSeconds(16)
Assert-Case 'give-up: not confirmed within 15 s -> failed' ($r.Failed -contains 'Q2')
$r = Update-AdbWifiModeState -KnownHeadsets @($q2Row) -HeadsetInfo $infoTls -Now $t0.AddSeconds(40)
Assert-Case 'give-up: no retry before 60 s' ($r.Issued.Count -eq 0)
$r = Update-AdbWifiModeState -KnownHeadsets @($q2Row) -HeadsetInfo $infoTls -Now $t0.AddSeconds(80)
Assert-Case 'give-up: retried after 60 s' ($r.Issued -contains 'Q2')
[void](Update-AdbWifiModeState -KnownHeadsets @($q2Row) -HeadsetInfo $infoTls -Now $t0.AddSeconds(100))
Assert-Case 'give-up: no WARNING after two failures' (@($script:logLines | Where-Object { $_ -like 'WARNING|*' }).Count -eq 0) ($script:logLines -join ' / ')
[void](Update-AdbWifiModeState -KnownHeadsets @($q2Row) -HeadsetInfo $infoTls -Now $t0.AddSeconds(170))
[void](Update-AdbWifiModeState -KnownHeadsets @($q2Row) -HeadsetInfo $infoTls -Now $t0.AddSeconds(190))
$m = $script:AdbWifiSwitchMemo['1WMHH8242N0366']
Assert-Case 'give-up: third failure -> given up, ONE WARNING' ($m.Unavailable -and @($script:logLines | Where-Object { $_ -like 'WARNING|*cannot be enabled on Q2*' }).Count -eq 1) ($script:logLines -join ' / ')
$r = Update-AdbWifiModeState -KnownHeadsets @($q2Row) -HeadsetInfo $infoTls -Now $t0.AddSeconds(5000)
Assert-Case 'give-up: no more attempts, even much later' ($r.Issued.Count -eq 0)
$st = Get-AdbWifiModeSwitchStatus -Serial '1WMHH8242N0366' -Published
Assert-Case 'give-up: state published for DIAG' ($st -and $st.Unavailable -and $st.Reason -eq 'not confirmed in time')
# Reboot edge: off WiFi ADB, then back -> tried again.
$infoDown = @{ '192.168.1.242' = [PSCustomObject]@{ ID = 2; AdbWifiMode = '-'; SCRCPY = '-' } }
[void](Update-AdbWifiModeState -KnownHeadsets @($q2Row) -HeadsetInfo $infoDown -Now $t0.AddSeconds(5010))
$r = Update-AdbWifiModeState -KnownHeadsets @($q2Row) -HeadsetInfo $infoTls -Now $t0.AddSeconds(5020)
Assert-Case 'give-up: back on WiFi ADB after a drop -> tried again' ($r.Issued -contains 'Q2' -and -not $script:AdbWifiSwitchMemo['1WMHH8242N0366'].Unavailable)
$script:openPorts = @('192.168.1.242:5555'); $script:upEndpoints += '192.168.1.242:5555'
$r = Update-AdbWifiModeState -KnownHeadsets @($q2Row) -HeadsetInfo $infoTls -Now $t0.AddSeconds(5022)
Assert-Case 'give-up: success resets the failures' ($r.Switched -contains 'Q2' -and $script:AdbWifiSwitchMemo['1WMHH8242N0366'].Failures -eq 0)
Assert-Case 'give-up: published state cleared after success' ($null -eq (Get-AdbWifiModeSwitchStatus -Serial '1WMHH8242N0366' -Published))
Reset-SwitchState
[void](Update-AdbWifiModeState -KnownHeadsets @($q2Row) -HeadsetInfo $infoTls -Now $t0)
Assert-Case 'switch: no TLS session to issue over -> failure, nothing sent' (-not ($script:adbCalls -match 'tcpip') -and $script:AdbWifiSwitchMemo['1WMHH8242N0366'].Failures -eq 1)
Reset-SwitchState
$script:mdnsText = & $mdnsQ2 38987; $script:upEndpoints = @('192.168.1.242:38987'); $script:usbSet = @([PSCustomObject]@{ Serial = '1WMHH8242N0366'; State = 'device'; Since = 'x' })
$r = Update-AdbWifiModeState -KnownHeadsets @($q2Row) -HeadsetInfo $infoTls -Now $t0
Assert-Case 'switch: cabled headset left to USB' ($r.Issued.Count -eq 0)

# classic -> TLS.
Set-Modes $true $true 'tls'
Reset-SwitchState
$script:upEndpoints = @('192.168.1.242:5555'); $script:mdnsText = @('List of discovered mdns services')
$r = Update-AdbWifiModeState -KnownHeadsets @($q2Row) -HeadsetInfo $infoClassic -Now $t0
Assert-Case 'to TLS: Wireless debugging enabled over classic' ($r.Issued -contains 'Q2' -and $script:tlsEnables -contains '192.168.1.242:5555')
$script:mdnsText = & $mdnsQ2 40001; $script:openPorts = @('192.168.1.242:40001'); $script:upEndpoints += '192.168.1.242:40001'
$r = Update-AdbWifiModeState -KnownHeadsets @($q2Row) -HeadsetInfo $infoClassic -Now $t0.AddSeconds(2)
Assert-Case 'to TLS: confirmed once advertised and connected' ($r.Switched -contains 'Q2')
Assert-Case 'to TLS: INFO line' (@($script:logLines | Where-Object { $_ -like 'INFO|Switched Q2 from classic to TLS*' }).Count -eq 1)
Set-Modes $true $true 'classic'

# TLS refresh: throttled, and a serial is dropped only after two missed polls.
Reset-SwitchState
$script:mdnsText = & $mdnsQ2 38987
[void](Update-AdbTlsEndpointsFromMdns -Now $t0)
$script:adbCalls = @()
[void](Update-AdbTlsEndpointsFromMdns -Now $t0.AddSeconds(2))
Assert-Case 'refresh: throttled to every 5 s' ($script:adbCalls.Count -eq 0)
$script:mdnsText = @('List of discovered mdns services')
[void](Update-AdbTlsEndpointsFromMdns -Now $t0.AddSeconds(6))
Assert-Case 'refresh: one miss keeps the endpoint' ($null -ne (Find-AdbTlsEndpointBySerial -Serial '1WMHH8242N0366' -MaxAgeSec 0))
$script:mdnsOk = $false
[void](Update-AdbTlsEndpointsFromMdns -Force -Now $t0.AddSeconds(12))
Assert-Case 'refresh: a failed adb call is not a miss' ($null -ne (Find-AdbTlsEndpointBySerial -Serial '1WMHH8242N0366' -MaxAgeSec 0))
$script:mdnsOk = $true
[void](Update-AdbTlsEndpointsFromMdns -Force -Now $t0.AddSeconds(18))
Assert-Case 'refresh: second miss drops it' ($null -eq (Find-AdbTlsEndpointBySerial -Serial '1WMHH8242N0366' -MaxAgeSec 0))
$global:ADB_wifi_tls_enabled = $false; $script:adbCalls = @()
[void](Update-AdbTlsEndpointsFromMdns -Force -Now $t0.AddSeconds(30))
Assert-Case 'refresh: TLS disabled -> no adb mdns' ($script:adbCalls.Count -eq 0)
Set-Modes $true $true 'classic'

# Running capture vs its WiFi mode.
Reset-SwitchState
$script:kv['adb_tls_endpoints'] = ConvertTo-Json -Compress -InputObject @([PSCustomObject]@{ Serial = '1WMHH8242N0366'; Ip = '192.168.1.242'; Port = 34941; Seen = [datetime]::UtcNow.ToString('o') })
$c = Get-AdbWifiCaptureModeDecision -Headset $q2Row -CurrentWifiMode TLS -CurrentEndpoint '192.168.1.242:38987' -LiveWifiMode Classic -SwitchMode next_start
Assert-Case 'capture: TLS port moved (adbd restarted) -> restart at once' ($c.Restart -and $c.Dead)
$script:openPorts = @()
$c1 = Get-AdbWifiCaptureModeDecision -Headset $q2Row -CurrentWifiMode Classic -CurrentEndpoint '192.168.1.242:5555' -LiveWifiMode Classic
$c2 = Get-AdbWifiCaptureModeDecision -Headset $q2Row -CurrentWifiMode Classic -CurrentEndpoint '192.168.1.242:5555' -LiveWifiMode Classic
Assert-Case 'capture: one closed probe is not enough, two are' (-not $c1.Restart -and $c2.Restart -and $c2.Dead)
$script:openPorts = @('192.168.1.242:34941', '192.168.1.242:5555')
$ep = '192.168.1.242:34941'
Assert-Case 'capture: on fallback, immediate -> restart' ((Get-AdbWifiCaptureModeDecision -Headset $q2Row -CurrentWifiMode TLS -CurrentEndpoint $ep -LiveWifiMode Classic -SwitchMode immediate).Restart)
Assert-Case 'capture: on fallback, next_start -> never' (-not (Get-AdbWifiCaptureModeDecision -Headset $q2Row -CurrentWifiMode TLS -CurrentEndpoint $ep -LiveWifiMode Classic -SwitchMode next_start).Restart)
$script:AdbWifiCaptureState = $null
Assert-Case 'capture: stable, recording -> no restart' (-not (Get-AdbWifiCaptureModeDecision -Headset $q2Row -CurrentWifiMode TLS -CurrentEndpoint $ep -LiveWifiMode Classic -SwitchMode stable -StableSec 10 -Recording $true -Now $t0).Restart)
Assert-Case 'capture: stable, before stable_sec -> no restart' (-not (Get-AdbWifiCaptureModeDecision -Headset $q2Row -CurrentWifiMode TLS -CurrentEndpoint $ep -LiveWifiMode Classic -SwitchMode stable -StableSec 10 -Now $t0.AddSeconds(5)).Restart)
Assert-Case 'capture: stable, after stable_sec -> restart' ((Get-AdbWifiCaptureModeDecision -Headset $q2Row -CurrentWifiMode TLS -CurrentEndpoint $ep -LiveWifiMode Classic -SwitchMode stable -StableSec 10 -Now $t0.AddSeconds(11)).Restart)
Assert-Case 'capture: same mode -> no restart' (-not (Get-AdbWifiCaptureModeDecision -Headset $q2Row -CurrentWifiMode Classic -CurrentEndpoint '192.168.1.242:5555' -LiveWifiMode Classic -SwitchMode immediate).Restart)

# Regression (2026-10-22, dev app): preferred changed to TLS while the app ran; the poll runspace
# kept classic first, so the live status said Classic while the capture ran on the preferred TLS.
# The capture was restarted every ~20 s and the switch to TLS re-issued every ~40 s.
Set-Modes $true $true 'tls'
$script:AdbWifiCaptureState = $null
Assert-Case 'loop: capture on preferred TLS, stale live Classic -> no restart' (-not (Get-AdbWifiCaptureModeDecision -Headset $q2Row -CurrentWifiMode TLS -CurrentEndpoint $ep -LiveWifiMode Classic -SwitchMode immediate).Restart)
Reset-SwitchState
$script:mdnsText = & $mdnsQ2 40001; $script:openPorts = @('192.168.1.242:40001', '192.168.1.242:5555'); $script:upEndpoints = @('192.168.1.242:5555', '192.168.1.242:40001')
$r = Update-AdbWifiModeState -KnownHeadsets @($q2Row) -HeadsetInfo $infoClassic -Now $t0
Assert-Case 'loop: TLS already answering, stale live Classic -> nothing issued' ($r.Issued.Count -eq 0 -and $script:tlsEnables.Count -eq 0)
Set-Modes $true $true 'classic'
Reset-SwitchState
$script:mdnsText = & $mdnsQ2 38987; $script:openPorts = @('192.168.1.242:5555'); $script:upEndpoints = @('192.168.1.242:38987', '192.168.1.242:5555')
$r = Update-AdbWifiModeState -KnownHeadsets @($q2Row) -HeadsetInfo $infoTls -ScrcpyPids @{} -Now $t0
Assert-Case 'loop: classic already answering, stale live TLS -> no tcpip' ($r.Issued.Count -eq 0 -and -not ($script:adbCalls -match 'tcpip'))

# ------------------------------------------------------------------ ADR-0037: 'auto' = no preference
Set-Modes $true $true 'auto'
Assert-Case 'auto: order is Classic, TLS' ((@(Get-AdbWifiModeOrder) -join ',') -eq 'Classic,TLS')
Assert-Case 'auto: no preferred mode' ((Get-AdbWifiPreferredMode) -eq '')
Set-Modes $true $true 'tls';     Assert-Case 'preferred: tls -> TLS' ((Get-AdbWifiPreferredMode) -eq 'TLS')
Set-Modes $true $true 'classic'; Assert-Case 'preferred: classic -> Classic' ((Get-AdbWifiPreferredMode) -eq 'Classic')
Set-Modes $true $false 'classic'; Assert-Case 'preferred: one mode enabled -> none' ((Get-AdbWifiPreferredMode) -eq '')
Remove-Variable -Name ADB_wifi_classic_enabled, ADB_wifi_tls_enabled, ADB_wifi_preferred_mode, ADB_wifi_effective_preferred -Scope Global -ErrorAction SilentlyContinue
Assert-Case 'preferred: no globals -> none' ((Get-AdbWifiPreferredMode) -eq '')
Set-Modes $true $true 'auto'
Assert-Case 'auto: TLS headset -> no switch' ((Get-AdbWifiModeSwitchDecision -Headset $q2Row -Info $infoTls['192.168.1.242']).Action -eq 'none')
Reset-SwitchState
$script:mdnsText = & $mdnsQ2 38987; $script:upEndpoints = @('192.168.1.242:38987')
$r = Update-AdbWifiModeState -KnownHeadsets @($q2Row) -HeadsetInfo $infoTls -Now $t0
Assert-Case 'auto: nothing issued, TLS still refreshed' ($r.Issued.Count -eq 0 -and $null -ne (Find-AdbTlsEndpointBySerial -Serial '1WMHH8242N0366' -MaxAgeSec 0))
$script:AdbWifiCaptureState = $null; $script:openPorts = @('192.168.1.242:38987', '192.168.1.242:5555')
Assert-Case 'auto: a capture on TLS is not moved' (-not (Get-AdbWifiCaptureModeDecision -Headset $q2Row -CurrentWifiMode TLS -CurrentEndpoint '192.168.1.242:38987' -LiveWifiMode Classic -SwitchMode immediate).Restart)
$script:openPorts = @()
$c1 = Get-AdbWifiCaptureModeDecision -Headset $q2Row -CurrentWifiMode TLS -CurrentEndpoint '192.168.1.242:38987' -LiveWifiMode Classic
$c2 = Get-AdbWifiCaptureModeDecision -Headset $q2Row -CurrentWifiMode TLS -CurrentEndpoint '192.168.1.242:38987' -LiveWifiMode Classic
Assert-Case 'auto: a dead endpoint still restarts the capture' ($c2.Restart -and $c2.Dead)

# Preference change = trigger: memos reset (a given-up headset is tried again), watchdog nudged.
Set-Modes $true $true 'classic'
Reset-SwitchState
$script:mdnsText = & $mdnsQ2 38987; $script:upEndpoints = @('192.168.1.242:38987')
[void](Update-AdbWifiModeState -KnownHeadsets @($q2Row) -HeadsetInfo $infoTls -Now $t0)
$m = Get-AdbWifiSwitchMemo -Serial '1WMHH8242N0366'; $m.Pending = $null; $m.Unavailable = $true; $m.Failures = 3
$r = Update-AdbWifiModeState -KnownHeadsets @($q2Row) -HeadsetInfo $infoTls -Now $t0.AddSeconds(30)
Assert-Case 'pref change: none -> given-up headset stays put' ($r.Issued.Count -eq 0 -and -not $r.PreferenceChanged)
$script:checks = @(); $script:logLines = @()
Set-Modes $true $true 'tls'
[void](Update-AdbWifiModeState -KnownHeadsets @($q2Row) -HeadsetInfo $infoTls -Now $t0.AddSeconds(32))
Set-Modes $true $true 'classic'
$r = Update-AdbWifiModeState -KnownHeadsets @($q2Row) -HeadsetInfo $infoTls -Now $t0.AddSeconds(34)
Assert-Case 'pref change: detected and every capture re-checked' ($r.PreferenceChanged -and @($script:checks | Where-Object { $_ -like '*|True' }).Count -ge 1) ($script:checks -join ';')
Assert-Case 'pref change: given-up headset tried again at once' ($r.Issued -contains 'Q2')
Assert-Case 'pref change: one INFO line per change' (@($script:logLines | Where-Object { $_ -like 'INFO|WiFi ADB mode settings changed*' }).Count -eq 2) ($script:logLines -join ' / ')

# /api/config/save validation of the ADB section.
Assert-Case 'config: auto/classic/tls accepted' ((Test-AdbWifiModeConfig -Adb ([PSCustomObject]@{ wifi_preferred_mode = 'AUTO'; wifi_classic_enabled = $true; wifi_tls_enabled = $false; adbPort_default = 5555 })) -eq '')
Assert-Case 'config: unknown preferred mode refused' ((Test-AdbWifiModeConfig -Adb ([PSCustomObject]@{ wifi_preferred_mode = 'usb' })) -ne '')
Assert-Case 'config: non-boolean toggle refused' ((Test-AdbWifiModeConfig -Adb ([PSCustomObject]@{ wifi_tls_enabled = 'yes' })) -ne '')
Assert-Case 'config: bad classic port refused' ((Test-AdbWifiModeConfig -Adb ([PSCustomObject]@{ adbPort_default = 70000 })) -ne '')
Assert-Case 'config: missing section is valid' ((Test-AdbWifiModeConfig -Adb $null) -eq '')

# Poll memo: a device on the fallback mode is dropped once the preferred mode answers.
$tlsDev = [PSCustomObject]@{ DeviceId = '192.168.1.242:38987'; ConnectionType = 'WiFi'; IP = '192.168.1.242'; Port = 38987; WifiMode = 'TLS' }
$script:openPorts = @('192.168.1.242:5555')
Assert-Case 'memo: fallback device, preferred classic answers -> drop' (Test-AdbWifiPreferredModeBack -Device $tlsDev -Headset $q2Row)
$script:openPorts = @()
Assert-Case 'memo: preferred classic closed -> keep' (-not (Test-AdbWifiPreferredModeBack -Device $tlsDev -Headset $q2Row))
Set-Modes $true $true 'auto'; $script:openPorts = @('192.168.1.242:5555')
Assert-Case 'memo: no preference -> keep' (-not (Test-AdbWifiPreferredModeBack -Device $tlsDev -Headset $q2Row))
Set-Modes $true $true 'classic'

Write-Host ''
Write-Host ("{0} case(s), {1} failed" -f $script:count, $script:fails)
if ($script:fails -gt 0) { exit 1 } else { exit 0 }
