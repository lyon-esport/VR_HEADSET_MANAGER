
###############################################################
# utils.ps1 - cross-cutting helpers used by multiple modules.
# Auto-loaded by scripts_init.ps1.
# ASCII only (no em dashes, no curly quotes, no accents).
###############################################################

# Drive type cache for Get-RecordingDriveInfo.
# Keyed by drive letter; value: @{DriveType; SpeedGbps}.
# Drive type (NVMe/SSD/HDD) never changes at runtime, so we query StorageWMI once and cache.
$script:DriveTypeCache = @{}


# Tolerant SSID comparison. Pico headsets mask part of the SSID returned by
# dumpsys/cmd wifi (e.g. "*****yWifi_Unifi" for "CrazyWifi_Unifi"). Strip all
# '*' characters and treat the remaining substring as the visible suffix; the
# match succeeds when the expected SSID ends with that suffix (case-insensitive)
# and the unmasked suffix is at least 3 chars (avoids false positives).
# Exact equality also returns true. Empty values never match.
function Test-SsidMatch {
    param(
        [string]$Reported,
        [string]$Expected
    )
    if ([string]::IsNullOrWhiteSpace($Reported) -or [string]::IsNullOrWhiteSpace($Expected)) { return $false }
    if ([string]::Equals($Reported, $Expected, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    $unmasked = $Reported -replace '\*', ''
    if ($unmasked.Length -lt 3) { return $false }
    return $Expected.EndsWith($unmasked, [System.StringComparison]::OrdinalIgnoreCase)
}


# Diagnoses whether a folder/file path can be written to. Does NOT rely on
# Test-Path alone (it does not reflect ACL write permission) - it walks up to
# the nearest existing ancestor directory and attempts a real create+delete
# write probe there. Returns @{Writable; Reason; ParentExists; ProbedPath}.
# Use this in catch blocks after a New-Item/Out-File/WriteAllText failure to
# give the operator a specific, actionable reason (permission denied vs.
# missing parent vs. other) instead of a raw exception.
function Test-FolderWriteAccess {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $ancestor = $Path
    while ($ancestor -and -not (Test-Path -LiteralPath $ancestor)) {
        $parent = Split-Path -Path $ancestor -Parent
        if (-not $parent -or $parent -eq $ancestor) { break }
        $ancestor = $parent
    }

    $parentExists = [bool]($ancestor -and (Test-Path -LiteralPath $ancestor))
    if (-not $parentExists) {
        return @{
            Writable     = $false
            Reason       = "No existing parent directory could be found above '$Path'."
            ParentExists = $false
            ProbedPath   = $ancestor
        }
    }

    $probeFile = Join-Path -Path $ancestor -ChildPath (".vrhm_write_test_{0}.tmp" -f [guid]::NewGuid().ToString("N"))
    try {
        [System.IO.File]::WriteAllText($probeFile, "")
        Remove-Item -LiteralPath $probeFile -Force -ErrorAction SilentlyContinue
        return @{
            Writable     = $true
            Reason       = "OK"
            ParentExists = $true
            ProbedPath   = $ancestor
        }
    } catch [System.UnauthorizedAccessException] {
        return @{
            Writable     = $false
            Reason       = "Permission denied writing to '$ancestor'. This commonly happens when the app is installed under an admin-protected folder such as 'Program Files' or 'Windows'."
            ParentExists = $true
            ProbedPath   = $ancestor
        }
    } catch {
        return @{
            Writable     = $false
            Reason       = "Could not write to '$ancestor': $($_.Exception.Message)"
            ParentExists = $true
            ProbedPath   = $ancestor
        }
    }
}


# Checks that every executable this app depends on actually exists at its
# configured $global: path (set by Get-Config). adb.exe and scrcpy.exe are
# always required; mediamtx.exe/ffmpeg.exe are only required when restreaming
# is enabled ($global:mediamtxEnabled), since an operator with restreaming off
# never needs them. Returns @{ Ok; Missing } - Missing entries carry the exact
# resolved path plus the existing translation key that names that exe, so the
# caller can report precisely which file is missing and where it was expected.
function Test-RequiredBinaries {
    $candidates = @(
        [PSCustomObject]@{ ExeName = 'adb.exe';    Path = $global:adbPath;        MessageKey = 'ADBExecutableNotFound' }
        [PSCustomObject]@{ ExeName = 'scrcpy.exe'; Path = $global:scrcpyFilePath; MessageKey = 'ScrcpyNotFound' }
    )
    if ($global:mediamtxEnabled) {
        $candidates += [PSCustomObject]@{ ExeName = 'mediamtx.exe'; Path = $global:mediamtxFilePath; MessageKey = 'MediaMtxNotFound' }
        $candidates += [PSCustomObject]@{ ExeName = 'ffmpeg.exe';   Path = $global:ffmpegFilePath;   MessageKey = 'MediaMtxFfmpegNotFound' }
    }

    $missing = @($candidates | Where-Object { -not $_.Path -or -not (Test-Path -LiteralPath $_.Path) })
    return @{
        Ok      = ($missing.Count -eq 0)
        Missing = $missing
    }
}


# Parse a CSV/JSON field that may be the string "True"/"False" or a real
# boolean and return a real [bool]. Empty/null returns $false.
# Use this everywhere instead of comparing $row.Field -eq $True/$False.
function ConvertTo-BoolField {
    param(
        [Parameter(ValueFromPipeline = $true)]
        $Value,
        [bool]$Default = $false
    )
    process {
        if ($null -eq $Value) { return $Default }
        if ($Value -is [bool]) { return $Value }
        $s = ([string]$Value).Trim()
        if ($s.Length -eq 0) { return $Default }
        return [string]::Equals($s, 'True', [System.StringComparison]::OrdinalIgnoreCase)
    }
}


# Reads the ThirdParty boolean from a known_apps.csv row.
# Supports new ThirdParty column ("True"/"False") and old Type column ("third-party"/"built-in")
# so existing CSV files migrate transparently on first read.
function ConvertTo-ThirdPartyBool {
    param([Parameter(Mandatory=$true)] $Row)
    if ($null -ne $Row.ThirdParty -and "$($Row.ThirdParty)" -ne '') { return ConvertTo-BoolField $Row.ThirdParty }
    if ($null -ne $Row.Type      -and "$($Row.Type)"      -ne '') { return $Row.Type -eq 'third-party' }
    return $true
}


# Repairs a string that was UTF-8 text mis-decoded as Windows-1252 (mojibake), e.g. "VidÃ©os"
# instead of "Videos". Re-encodes as Windows-1252 bytes, then strictly re-decodes those bytes as
# UTF-8; if that succeeds and differs from the input, the fix is accepted and the loop repeats
# (capped at 3 passes) so a double mis-decode ("VidÃƒÂ©os") also unwinds in one call. A string that
# is not mojibake fails the strict UTF-8 decode and is returned unchanged - this cannot corrupt an
# already-correct accented string.
function Repair-MojibakeUtf8String {
    param([Parameter(Mandatory=$true)] [AllowEmptyString()] [string]$Value)

    $cp1252 = [System.Text.Encoding]::GetEncoding(1252)
    $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
    $current = $Value

    for ($i = 0; $i -lt 3; $i++) {
        try {
            $bytes = $cp1252.GetBytes($current)
            $candidate = $strictUtf8.GetString($bytes)
        } catch {
            break
        }
        if ($candidate -eq $current) { break }
        $current = $candidate
    }

    return $current
}


# Build the path of a per-headset data CSV (data/<safe>_<suffix>.csv).
# Suffix examples: 'favorite_apps', 'installed_apps'.
function Get-HeadsetDataPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [string]$Suffix
    )
    $safe = $Name -replace ' ', '_'
    $file = "{0}_{1}.csv" -f $safe, $Suffix
    return (Join-Path -Path $global:ScriptPath -ChildPath (Join-Path -Path 'data' -ChildPath $file))
}


# Build the path of a per-headset website file (website/<safe>[<kind>].html).
# Kind examples: 'monitoring', 'video'.
function Get-HeadsetSitePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [string]$Kind
    )
    $safe = $Name -replace ' ', '_'
    $file = "{0}[{1}].html" -f $safe, $Kind
    return (Join-Path -Path $global:ScriptPath -ChildPath (Join-Path -Path 'website\generated' -ChildPath $file))
}


# Write text to a file as UTF-8 WITHOUT BOM.
# .ps1 files in this project must not have a BOM (CLAUDE.md rule 1).
# Many web/HTML/YAML outputs also need this.
function Write-FileWithoutBom {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [AllowEmptyString()]
        [string]$Content
    )
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}


# Formats a duration in seconds as a short human-readable string ("3d 4h",
# "2h 15m", "45m", "30s"). Returns "-" for $null/negative input, so callers can
# print it directly without a null guard.
# Example: Get-FormattedUptime -Seconds 93784   ->  "1d 2h"
function Get-FormattedUptime {
    param(
        $Seconds
    )
    if ($null -eq $Seconds) { return "-" }
    $s = 0
    if (-not [int64]::TryParse([string]$Seconds, [ref]$s)) { return "-" }
    if ($s -lt 0) { return "-" }

    $days  = [math]::Floor($s / 86400)
    $hours = [math]::Floor(($s % 86400) / 3600)
    $mins  = [math]::Floor(($s % 3600) / 60)

    if ($days  -gt 0) { return "${days}d ${hours}h" }
    if ($hours -gt 0) { return "${hours}h ${mins}m" }
    if ($mins  -gt 0) { return "${mins}m" }
    return "${s}s"
}


# Print "<prefix> N..." on a single line, counting down once per second.
# Used by headsets_dashboard.ps1 and any "wait then refresh" loop.
function Wait-WithCountdown {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Seconds,
        [string]$Prefix = 'Refreshing in'
    )
    if ($Seconds -le 0) { return }
    for ($i = $Seconds; $i -ge 1; $i--) {
        Write-Host -NoNewline ("`r{0} {1}s ..." -f $Prefix, $i)
        Start-Sleep -Seconds 1
    }
    Write-Host -NoNewline ("`r" + (' ' * ($Prefix.Length + 12)) + "`r")
}


# Validate that a constructed file path stays under the project root.
# Returns the resolved absolute path on success, or $null if it would escape.
# Use this for any web-route handler that builds a path from request input.
function Test-RequestPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [string]$Root = $global:ScriptPath
    )
    if (-not $Root) { return $null }
    try {
        $resolved = [System.IO.Path]::GetFullPath($Path)
    } catch {
        return $null
    }
    $rootFull = [System.IO.Path]::GetFullPath($Root)
    $sep      = [System.IO.Path]::DirectorySeparatorChar
    if (-not $rootFull.EndsWith($sep)) { $rootFull = $rootFull + $sep }
    if ($resolved.Equals($rootFull.TrimEnd($sep), [System.StringComparison]::OrdinalIgnoreCase) -or
        $resolved.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $resolved
    }
    return $null
}


# Returns the path to the encrypted WiFi networks store (data/wifi_networks.dat).
function Get-WifiNetworksPath {
    return (Join-Path -Path $global:ScriptPath -ChildPath 'data\wifi_networks.dat')
}


# Reads the encrypted WiFi networks file and returns an array of PSCustomObjects
# with SSID and Password properties. Returns @() if the file does not exist.
# If the file exists but cannot be decrypted or parsed, it is deleted and @() is returned.
function Get-WifiNetworks {
    $path = Get-WifiNetworksPath
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    try {
        $encrypted = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($encrypted)) { throw "empty" }
        $ss   = ConvertTo-SecureString $encrypted.Trim() -ErrorAction Stop
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss)
        try {
            $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
        } finally {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
        $list = @(($plain | ConvertFrom-Json) | ForEach-Object {
            [PSCustomObject]@{ SSID = [string]$_.SSID; Password = [string]$_.Password; Preferred = [bool]$_.Preferred }
        })
        # Migration: if no entry is preferred, mark the first one and re-save
        if ($list.Count -gt 0 -and -not ($list | Where-Object { $_.Preferred })) {
            $list[0].Preferred = $true
            Save-WifiNetworks -Networks $list
        }
        return $list
    } catch {
        Write-Log ($msg.WifiNetworksFileCorrupt) -Level WARNING
        try { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue } catch {}
        return @()
    }
}


# Encrypts $Networks (array of objects with SSID + Password) and writes to
# data/wifi_networks.dat using Windows DPAPI (machine/user-bound, no passphrase).
# Overwrites any existing file.
function Save-WifiNetworks {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array]$Networks
    )
    $path  = Get-WifiNetworksPath
    $plain = ($Networks | ForEach-Object { @{ SSID = $_.SSID; Password = $_.Password; Preferred = [bool]$_.Preferred } }) |
             ConvertTo-Json -Compress
    $ss        = ConvertTo-SecureString $plain -AsPlainText -Force
    $encrypted = ConvertFrom-SecureString $ss
    Write-FileWithoutBom -Path $path -Content $encrypted
    Write-Log ($msg.WifiNetworksSaved -f $Networks.Count) -Level DEBUG
}


# Returns the names of all WLAN profiles saved on this computer (these are the
# real SSIDs, unlike the Windows NetworkList profile names returned by
# Get-NetConnectionProfile which can carry a " 2" / " 3" dedup suffix).
#
# Parsing note: the labels printed by netsh are localized (FR Windows prints
# "Profil Tous les utilisateurs"), so this parser NEVER matches on label text.
# It splits each line at the FIRST colon and keeps the remainder, which makes it
# locale-independent and safe for SSIDs that themselves contain a colon.
# Works without admin rights and without location services.
# Returns @() on any failure.
function Get-WlanProfileName {
    $names = @()
    try {
        $lines = & netsh wlan show profiles 2>$null
        if (-not $lines) { return @() }
        foreach ($line in $lines) {
            $idx = ([string]$line).IndexOf(':')
            if ($idx -lt 0) { continue }
            $value = ([string]$line).Substring($idx + 1).Trim()
            if (-not $value) { continue }
            # Skip placeholders such as <None> / <Aucun>
            if ($value.StartsWith('<') -and $value.EndsWith('>')) { continue }
            if ($names -notcontains $value) { $names += $value }
        }
    } catch { return @() }
    return $names
}


# Returns the plain-text pre-shared key of a saved WLAN profile, or $null when
# the profile is unknown, open (no key), or the key cannot be read.
#
# Why not `netsh wlan export ... key=clear`: netsh only writes the key in clear
# text when the caller is a local administrator; otherwise the exported XML
# carries a DPAPI-encrypted keyMaterial that we cannot decrypt. The interactive
# `netsh wlan show profile ... key=clear` form DOES return the clear key without
# elevation, so this uses that instead.
#
# The label printed for that line is localized ("Contenu de la cle" on FR
# Windows), so instead of matching label text this runs the command twice - once
# without key=clear, once with - and keeps the single extra line the second run
# produces. That line is the key by construction, whatever the display language.
function Get-WlanProfileKey {
    param([string]$ProfileName)
    if ([string]::IsNullOrWhiteSpace($ProfileName)) { return $null }
    try {
        $masked = @(& netsh wlan show profile ('name="{0}"' -f $ProfileName) 2>$null)
        $clear  = @(& netsh wlan show profile ('name="{0}"' -f $ProfileName) key=clear 2>$null)
        if ($masked.Count -eq 0 -or $clear.Count -eq 0) { return $null }

        $extra = Compare-Object -ReferenceObject $masked -DifferenceObject $clear |
                 Where-Object { $_.SideIndicator -eq '=>' }
        foreach ($line in $extra) {
            $text = [string]$line.InputObject
            $idx  = $text.IndexOf(':')
            if ($idx -lt 0) { continue }
            $value = $text.Substring($idx + 1).Trim()
            if ($value) { return $value }
        }
        return $null
    } catch { return $null }
}


# Returns the WiFi network this computer is currently connected to, as
# @{ Ssid; ProfileName; InterfaceAlias; Password }, or $null when no wireless
# adapter is up.
#
# Why this is not a one-liner: Get-NetConnectionProfile exposes no SSID at all.
# Its .Name is the Windows NetworkList profile name, and Windows appends
# " 2" / " 3" / " 4" to it whenever a duplicate network-list entry is created
# (adapter re-enumeration, dock/undock, network category change). Returning that
# name yields values like "MyWifi 4" that match no WLAN profile, which also
# breaks the password lookup below.
#
# Resolution order for the WLAN profile name (first source that answers wins):
#   1. netsh wlan show interfaces - authoritative, but on Windows 11 it needs
#      location services enabled AND elevation; it fails silently otherwise, so
#      it can never be the only source.
#   2. Reconcile Get-NetConnectionProfile().Name against the saved WLAN profile
#      list (exact match, then trailing " <digits>" stripped, then longest
#      prefix). Works unprivileged with location services off.
#   3. Raw Get-NetConnectionProfile().Name as a last resort.
#
# The SSID and the password then both come from a single `netsh wlan export`
# XML: its <SSIDConfig><SSID><name> node is the authoritative SSID and both
# nodes are locale-independent.
function Get-ComputerWifiInfo {
    $adapter = Get-NetAdapter | Where-Object {
        ($_.PhysicalMediaType -eq 'Native 802.11' -or $_.PhysicalMediaType -eq 'Wireless LAN') -and
        $_.Status -eq 'Up'
    } | Select-Object -First 1
    if (-not $adapter) { return $null }

    $profileName = $null

    # Source 1: authoritative when the OS allows it. The ^\s*SSID anchor is what
    # keeps the BSSID line from matching.
    try {
        $ifLines = & netsh wlan show interfaces 2>$null
        if ($ifLines) {
            foreach ($line in $ifLines) {
                if ([string]$line -match '^\s*SSID\s*:\s*(.+?)\s*$') { $profileName = $Matches[1]; break }
            }
        }
    } catch {}

    # Source 2: reconcile the NetworkList name against the saved WLAN profiles.
    $netProfile = Get-NetConnectionProfile -InterfaceAlias $adapter.InterfaceAlias -ErrorAction SilentlyContinue
    $connName   = if ($netProfile) { [string]$netProfile.Name } else { $null }

    if (-not $profileName -and $connName) {
        $saved = @(Get-WlanProfileName)
        if ($saved -contains $connName) {
            $profileName = $connName
        } elseif ($connName -match '^(.*?)\s+\d+$' -and $saved -contains $Matches[1]) {
            # "MyWifi 4" -> "MyWifi". Keep the string derived from the Windows API
            # rather than the netsh one: netsh output goes through the console OEM
            # codepage and can mangle accented SSIDs.
            $profileName = $Matches[1]
        } else {
            $profileName = $saved |
                Where-Object { $_ -and $connName.StartsWith($_) } |
                Sort-Object -Property Length -Descending |
                Select-Object -First 1
        }
    }

    # Source 3: last resort - today's behaviour, still better than nothing.
    if (-not $profileName) { $profileName = $connName }
    if (-not $profileName) { return $null }

    $ssid = $profileName

    # The profile name is normally the SSID, but it can be renamed. Export the
    # profile to get the authoritative SSID from the XML - <SSIDConfig><SSID>
    # <name> is locale-independent. Export into a fresh unique folder: netsh
    # names the file "<InterfaceAlias>-<ProfileName>.xml", so guessing the
    # filename breaks on a renamed adapter ("Wi-Fi 2") or on sanitized
    # characters, and a dedicated folder rules out picking up a stale export.
    # The key in this XML is unusable unless we are admin - the password comes
    # from Get-WlanProfileKey instead - so a failure here is not fatal.
    $tmpDir = Join-Path $env:TEMP ("vrhm_wlan_" + [guid]::NewGuid().ToString('N'))
    try {
        # New-Item has no -LiteralPath in PS 5.1; this API is literal by nature.
        [System.IO.Directory]::CreateDirectory($tmpDir) | Out-Null
        & netsh wlan export profile ('name="{0}"' -f $profileName) ('folder="{0}"' -f $tmpDir) 2>$null | Out-Null
        $xmlFile = Get-ChildItem -LiteralPath $tmpDir -Filter '*.xml' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($xmlFile) {
            [xml]$xml = Get-Content -LiteralPath $xmlFile.FullName -Raw -Encoding UTF8
            $xmlSsid = $xml.WLANProfile.SSIDConfig.SSID.name
            if ($xmlSsid) { $ssid = [string]$xmlSsid }
        }
    } catch {
        # Enterprise profile, export blocked, unreadable XML: keep the resolved
        # profile name as the SSID.
    } finally {
        try { Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue } catch {}
    }

    $wifiPassword = Get-WlanProfileKey -ProfileName $profileName

    return [PSCustomObject]@{
        Ssid           = $ssid
        ProfileName    = $profileName
        InterfaceAlias = $adapter.InterfaceAlias
        Password       = $wifiPassword
    }
}


# Returns the SSID of the WiFi network this computer is connected to, or $null.
# Thin wrapper over Get-ComputerWifiInfo - prefer that function when you also
# need the password, so the netsh export runs only once.
function Get-ComputerWifiSSID {
    $info = Get-ComputerWifiInfo
    if ($info) { return $info.Ssid }
    return $null
}


# Returns the plain-text password stored for a given network, or $null.
# $SSID accepts either an SSID or a WLAN profile name: when it does not match a
# saved profile directly, the profile whose exported SSID equals it is used.
function Get-ComputerWifiPassword {
    param([string]$SSID)
    if ([string]::IsNullOrWhiteSpace($SSID)) { return $null }

    $target = $SSID.Trim()
    $saved  = @(Get-WlanProfileName)
    if ($saved.Count -gt 0 -and $saved -notcontains $target) {
        # Not a profile name - it may be an SSID whose profile is named
        # differently. Fall back to the currently connected network when it
        # matches, which covers the common case without exporting every profile.
        $info = Get-ComputerWifiInfo
        if ($info -and $info.Ssid -eq $target) { return $info.Password }
        return $null
    }
    return Get-WlanProfileKey -ProfileName $target
}


# Returns $true if the internet is reachable, $false only if BOTH probes fail.
# Probe 1: ICMP ping to 8.8.8.8 (Google public DNS - no DNS lookup needed).
# Probe 2: DNS resolution of 'dns.google' (proves DNS is working end-to-end).
# Internet is considered UP if at least one probe succeeds.
function Test-InternetConnectivity {
    param(
        [int]$TimeoutMs = 3000
    )
    $ping   = [System.Net.NetworkInformation.Ping]::new()
    $reply  = try { $ping.Send('8.8.8.8', $TimeoutMs) } catch { $null }
    $pingOk = ($reply -and $reply.Status -eq 'Success')
    $dnsOk  = try { $null = [System.Net.Dns]::GetHostAddresses('dns.google'); $true } catch { $false }
    return ($pingOk -or $dnsOk)
}


# Returns CPU model, physical/logical core counts, and current load percentage.
# Model/core counts come from Win32_Processor (static metadata). LoadPercent is
# sampled from Win32_PerfFormattedData_PerfOS_Processor (instance "_Total")
# once per second for 5 seconds and averaged - Win32_Processor.LoadPercentage
# is a single stale/noisy WMI sample and is not accurate enough on its own.
# Get-Counter is avoided here because its counter paths are locale-localized
# (e.g. "Processeur" on FR Windows) and fail on non-English systems; the WMI
# class name is not localized.
# Returns $null on failure.
function Get-CpuInfo {
    $procs = $null
    try {
        $procs = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop)
        if ($procs.Count -eq 0) { return $null }

        $samples = for ($i = 0; $i -lt 5; $i++) {
            (Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop).PercentProcessorTime
            if ($i -lt 4) { Start-Sleep -Seconds 1 }
        }
        $load = [int][Math]::Round(($samples | Measure-Object -Average).Average)

        return [PSCustomObject]@{
            Model         = ($procs[0].Name -replace '\s+', ' ').Trim()
            PhysicalCores = ($procs | Measure-Object -Property NumberOfCores -Sum).Sum
            LogicalCores  = ($procs | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
            LoadPercent   = $load
        }
    } catch {
        return $null
    } finally {
        if ($procs) { foreach ($p in $procs) { if ($p) { $p.Dispose() } } }
    }
}


# Returns RAM generation (DDR3/DDR4/DDR5...), speed, total/used/free capacity.
# Uses Win32_PhysicalMemory for DIMM metadata and Win32_OperatingSystem for live usage.
# Returns $null on failure.
function Get-RamInfo {
    $ddrMap = @{ 20 = 'DDR'; 21 = 'DDR2'; 24 = 'DDR3'; 26 = 'DDR4'; 34 = 'DDR5' }
    $dimms = $null
    $os = $null
    try {
        $dimms = @(Get-CimInstance -ClassName Win32_PhysicalMemory -ErrorAction Stop)
        $os    = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop

        $gen   = 'Unknown'
        $speed = 0
        if ($dimms.Count -gt 0) {
            $type  = [int]$dimms[0].SMBIOSMemoryType
            $gen   = if ($ddrMap.ContainsKey($type)) { $ddrMap[$type] } else { 'Unknown' }
            $speed = [int]($dimms | Where-Object { $_.Speed } | Select-Object -First 1 -ExpandProperty Speed)
        }

        $totalKB = [double]$os.TotalVisibleMemorySize
        $freeKB  = [double]$os.FreePhysicalMemory
        $usedKB  = $totalKB - $freeKB
        $totalGB = [Math]::Round($totalKB / 1MB, 1)
        $usedGB  = [Math]::Round($usedKB  / 1MB, 1)
        $freeGB  = [Math]::Round($freeKB  / 1MB, 1)
        $usedPct = if ($totalKB -gt 0) { [int][Math]::Round($usedKB / $totalKB * 100) } else { 0 }
        $freePct = 100 - $usedPct

        return [PSCustomObject]@{
            Generation  = $gen
            SpeedMHz    = $speed
            TotalGB     = $totalGB
            UsedGB      = $usedGB
            FreeGB      = $freeGB
            UsedPercent = $usedPct
            FreePercent = $freePct
        }
    } catch {
        return $null
    } finally {
        if ($dimms) { foreach ($d in $dimms) { if ($d) { $d.Dispose() } } }
        if ($os)    { $os.Dispose() }
    }
}


# DXGI helper: enumerates GPU adapters and returns their LUID strings keyed by adapter name.
# Used by Get-GpuInfo to correlate Win32_VideoController entries to perf counter LUID instances.
# Defined once at module scope; guarded against duplicate Add-Type across dot-source cycles.
if (-not ([System.Management.Automation.PSTypeName]'_VRM_DxgiLuid').Type) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class _VRM_DxgiLuid {
    [DllImport("dxgi.dll")] static extern int CreateDXGIFactory(ref Guid riid, out IntPtr ppFactory);
    static Guid IID_IDXGIFactory = new Guid("7b7166ec-21c7-44ae-b21a-c9ae321ae369");
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct DXGI_ADAPTER_DESC {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Description;
        public uint VendorId, DeviceId, SubSysId, Revision;
        public UIntPtr DedicatedVideoMemory, DedicatedSystemMemory, SharedSystemMemory;
        public long AdapterLuid;
    }
    delegate int DEnumAdapters(IntPtr factory, uint index, out IntPtr adapter);
    delegate int DGetDesc(IntPtr adapter, out DXGI_ADAPTER_DESC desc);
    delegate uint DRelease(IntPtr obj);
    static T Vtbl<T>(IntPtr obj, int slot) where T : class {
        IntPtr fn = Marshal.ReadIntPtr(Marshal.ReadIntPtr(obj), slot * IntPtr.Size);
        return Marshal.GetDelegateForFunctionPointer(fn, typeof(T)) as T;
    }
    public static Dictionary<string, string> GetAdapterLuids() {
        var map = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        IntPtr factory = IntPtr.Zero;
        try {
            if (CreateDXGIFactory(ref IID_IDXGIFactory, out factory) < 0 || factory == IntPtr.Zero) return map;
            var enumAdapters = Vtbl<DEnumAdapters>(factory, 7);
            for (uint i = 0; ; i++) {
                IntPtr adapter;
                if (enumAdapters(factory, i, out adapter) < 0) break;
                DXGI_ADAPTER_DESC desc;
                if (Vtbl<DGetDesc>(adapter, 8)(adapter, out desc) == 0 && !string.IsNullOrEmpty(desc.Description)) {
                    long luid = desc.AdapterLuid;
                    uint lo = (uint)(luid & 0xFFFFFFFFL);
                    uint hi = (uint)((luid >> 32) & 0xFFFFFFFFL);
                    map[desc.Description] = string.Format("0x{0:x8}_0x{1:x8}", hi, lo);
                }
                Vtbl<DRelease>(adapter, 2)(adapter);
            }
        } catch { }
        if (factory != IntPtr.Zero) try { Vtbl<DRelease>(factory, 2)(factory); } catch { }
        return map;
    }
}
'@ -ErrorAction SilentlyContinue
}

# Returns an array of GPU info objects (one per adapter).
# Per-GPU: model, dedicated VRAM (GB), 3D/encode/decode/video utilization (%),
# overall utilization (%), VRAM used/free (GB and %). Utilization fields are $null
# when perf counters are unavailable (old Windows, Hyper-V, missing provider).
# VideoPercent covers every video engine whatever the vendor calls it, because AMD
# exposes one unified "video codec" engine instead of videoencode/videodecode -
# on AMD it is the ONLY field carrying transcode load. UtilizationPercent is the
# busiest engine (what Task Manager shows as the headline GPU figure).
# Returns @() if no GPU is found; never returns $null.
function Get-GpuInfo {
    # Counter instance names embed the adapter LUID:
    #   GPU Engine:         pid_NNNN_luid_0xHH_0xLL_phys_0_eng_N_engtype_3D
    #   GPU Adapter Memory: luid_0xHH_0xLL_phys_0
    # phys_N is always 0 per-adapter (not a global GPU index), so we key maps by LUID string.
    #
    # One pass over every GPU Engine instance, bucketed as [luid][engine type] = summed %
    # across all processes. A single Get-Counter call covers every engine type, which is
    # both cheaper than one call per type and required because the interesting engine
    # names differ per vendor (see _GetEngineStats).
    function _GetEngineMap {
        $map = @{}
        try {
            $samples = (Get-Counter -Counter '\GPU Engine(*)\Utilization Percentage' -ErrorAction Stop).CounterSamples
            foreach ($s in $samples) {
                if ($s.InstanceName -match 'luid_(0x[0-9a-f]+_0x[0-9a-f]+).*engtype_(.+)$') {
                    $luid = $Matches[1]
                    $eng  = $Matches[2].Trim().ToLower()
                    if (-not $map.ContainsKey($luid))       { $map[$luid] = @{} }
                    if (-not $map[$luid].ContainsKey($eng)) { $map[$luid][$eng] = 0.0 }
                    $map[$luid][$eng] += $s.CookedValue
                }
            }
        } catch { }
        return $map
    }

    # Reduce one adapter's engine hashtable to the figures we report.
    # Engine type names are vendor specific - measured on real hardware:
    #   AMD 780M : 3d, copy, compute 0/1, timer 0, security 1, high priority 3d/compute,
    #              video jpeg 0, "video codec 0"  <- ONE unified VCN engine, encode AND decode
    #   NVIDIA   : 3d, copy, videodecode, videoencode, jpeg_decode_0, ofa_0, security, vr
    #   Intel    : 3d, copy, legacyoverlay, videodecode, videoprocessing
    # AMD exposes no videoencode/videodecode at all, so Encode/Decode stay 0 there and
    # Video is the only field carrying the real (often dominant) transcode load.
    function _GetEngineStats {
        param($Engines)
        $r = @{ Load3D = 0.0; Encode = 0.0; Decode = 0.0; Video = 0.0; Utilization = 0.0 }
        if (-not $Engines) { return $r }
        foreach ($kv in $Engines.GetEnumerator()) {
            $name = [string]$kv.Key
            $val  = [double]$kv.Value
            # Task Manager's headline GPU figure is the busiest engine, not the sum
            if ($val -gt $r.Utilization) { $r.Utilization = $val }
            # Exact match: excludes "high priority 3d", matching Task Manager's 3D graph
            if ($name -eq '3d')              { $r.Load3D += $val }
            if ($name -like '*videodecode*') { $r.Decode += $val }
            if ($name -like '*videoencode*') { $r.Encode += $val }
            # JPEG engines are excluded so the same work is counted on every vendor
            # (AMD "video jpeg 0" would match *video*, NVIDIA "jpeg_decode_0" would not).
            if (($name -like '*video*' -or $name -like '*codec*') -and $name -notlike '*jpeg*') {
                $r.Video += $val
            }
        }
        return $r
    }

    # Build a lookup: GPU DriverDesc -> real VRAM bytes (64-bit QWORD from registry).
    # Win32_VideoController.AdapterRAM is a 32-bit field capped at ~4 GB; the registry
    # stores the full value. Falls back to AdapterRAM when the registry key is absent.
    $regVramMap = @{}
    try {
        $regBase = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
        Get-ChildItem -Path $regBase -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -match '^\d{4}$' } |
            ForEach-Object {
                $p   = Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue
                $qw  = $p.'HardwareInformation.qwMemorySize'
                $drv = $p.DriverDesc
                if ($drv -and $qw -gt 0) { $regVramMap[$drv] = [double]$qw }
            }
    } catch { }

    # GPU name -> LUID string via DXGI (authoritative adapter enumeration).
    # Falls back to empty map if DXGI is unavailable; counters will be skipped.
    $gpuLuidMap = @{}
    try {
        if (([System.Management.Automation.PSTypeName]'_VRM_DxgiLuid').Type) {
            $gpuLuidMap = [_VRM_DxgiLuid]::GetAdapterLuids()
        }
    } catch { }

    try {
        $controllers = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop)
    } catch {
        # Logged because a silent @() here renders no GPU card at all in the web UI,
        # which is indistinguishable from "feature not working" during remote support.
        try { Write-Log ("Get-GpuInfo: Win32_VideoController query failed: " + $_.Exception.Message) -Level WARNING } catch {}
        return @()
    }
    if ($controllers.Count -eq 0) {
        try { Write-Log "Get-GpuInfo: Win32_VideoController returned no adapter." -Level WARNING } catch {}
        return @()
    }

    # Drop virtual / software display adapters before indexing. Virtual Desktop,
    # Meta Quest Link, Parsec, Sunshine, IddSampleDriver and the RDP display driver
    # all register a Win32_VideoController on ROOT\DISPLAY or a non-PCI bus. They
    # enumerate FIRST (ahead of the real card), which pushed the physical GPU to
    # index 1: with the default Performance.GPU_Index = 0 the app then "selected"
    # e.g. "Virtual Desktop Monitor", Get-GpuVendor returned 'Unknown', and the
    # AMD/NVIDIA/Intel-first encoder ordering in Get-GpuEncoderCandidates never
    # applied. They also have no perf counters and no LUID, so they only ever show
    # as empty rows in the monitoring page and the config GPU dropdown.
    # Real GPUs (integrated and discrete alike) are always on the PCI bus; the
    # unfiltered list is kept as a fallback so a VM with only a synthetic adapter
    # (Hyper-V VMBUS, VMware SVGA) still reports something.
    $allControllers = $controllers
    $physical = @($controllers | Where-Object { $_.PNPDeviceID -like 'PCI\*' })
    if ($physical.Count -gt 0) { $controllers = $physical }

    try {
        Write-Log ("Get-GpuInfo: {0} adapter(s) found, {1} on PCI: {2} | DXGI LUIDs: {3}" -f `
            $allControllers.Count, $physical.Count, (($controllers | ForEach-Object { $_.Name }) -join ', '), `
            (($gpuLuidMap.Keys | ForEach-Object { "$_=$($gpuLuidMap[$_])" }) -join ', ')) -Level DEBUG
    } catch {}

    # Collect perf counter maps keyed by LUID string
    $engineMap = _GetEngineMap
    $mapMemUse = @{}
    try {
        $memUseSamples = (Get-Counter -Counter '\GPU Adapter Memory(*)\Dedicated Usage' -ErrorAction Stop).CounterSamples
        foreach ($s in $memUseSamples) {
            if ($s.InstanceName -match 'luid_(0x[0-9a-f]+_0x[0-9a-f]+)') { $mapMemUse[$Matches[1]] = $s.CookedValue }
        }
    } catch { }

    # On some machines (observed: AMD iGPU queried through a Remote Desktop session)
    # the LUID CreateDXGIFactory reports for the real GPU does not match the LUID
    # dxgkrnl assigns for the same adapter's GPU Engine / GPU Adapter Memory perf
    # counters, even though the adapter name matches and the software "Microsoft
    # Basic Render Driver" adapter's LUID matches fine between the two APIs. When
    # there is exactly one physical GPU there is no ambiguity to resolve via LUID at
    # all, so sum every counter instance directly (excluding the Basic Render Driver,
    # whose LUID can still be identified reliably) instead of depending on the join.
    $singleGpuMode = ($controllers.Count -eq 1)
    if ($singleGpuMode) {
        $excludeLuid    = $gpuLuidMap['Microsoft Basic Render Driver']
        $aggEngines     = @{}
        $aggMemUse      = 0.0
        $haveAggMemUse  = $false
        foreach ($luidKv in $engineMap.GetEnumerator()) {
            if ($luidKv.Key -eq $excludeLuid) { continue }
            foreach ($e in $luidKv.Value.GetEnumerator()) {
                if (-not $aggEngines.ContainsKey($e.Key)) { $aggEngines[$e.Key] = 0.0 }
                $aggEngines[$e.Key] += $e.Value
            }
        }
        foreach ($kv in $mapMemUse.GetEnumerator()) { if ($kv.Key -ne $excludeLuid) { $aggMemUse += $kv.Value; $haveAggMemUse = $true } }
    }

    $results = @()
    for ($i = 0; $i -lt $controllers.Count; $i++) {
        $ctrl      = $controllers[$i]
        $gpuName   = ($ctrl.Name -replace '\s+', ' ').Trim()
        # Prefer the registry 64-bit QWORD; fall back to the capped 32-bit AdapterRAM
        $vramBytes = if ($regVramMap.ContainsKey($gpuName)) { $regVramMap[$gpuName] } else { [double]$ctrl.AdapterRAM }
        $vramGB    = [Math]::Round($vramBytes / 1GB, 2)

        $load3D = $null; $loadEnc = $null; $loadDec = $null; $loadVideo = $null; $loadUtil = $null
        $vramUsedGB = $null; $vramFreeGB = $null; $vramUsedPct = $null; $vramFreePct = $null

        if ($singleGpuMode) {
            # Only one real adapter exists, so the aggregated (LUID-independent) engine
            # buckets computed above are unambiguously this GPU's data.
            $st = _GetEngineStats $aggEngines
            $load3D    = [int][Math]::Min(100, [Math]::Round($st.Load3D))
            $loadEnc   = [int][Math]::Min(100, [Math]::Round($st.Encode))
            $loadDec   = [int][Math]::Min(100, [Math]::Round($st.Decode))
            $loadVideo = [int][Math]::Min(100, [Math]::Round($st.Video))
            $loadUtil  = [int][Math]::Min(100, [Math]::Round($st.Utilization))

            if ($haveAggMemUse) {
                $usedBytes   = $aggMemUse
                $vramUsedGB  = [Math]::Round($usedBytes / 1GB, 2)
                $vramFreeGB  = if ($vramBytes -gt 0) { [Math]::Round(($vramBytes - $usedBytes) / 1GB, 2) } else { $null }
                $vramUsedPct = if ($vramBytes -gt 0) { [int][Math]::Round($usedBytes / $vramBytes * 100) } else { $null }
                $vramFreePct = if ($null -ne $vramUsedPct) { 100 - $vramUsedPct } else { $null }
            }
        } else {
            # Resolve this GPU's LUID via DXGI, then look up its counter data
            $luid = $gpuLuidMap[$gpuName]
            if ($luid) {
                $st = _GetEngineStats $engineMap[$luid]
                $load3D    = [int][Math]::Min(100, [Math]::Round($st.Load3D))
                $loadEnc   = [int][Math]::Min(100, [Math]::Round($st.Encode))
                $loadDec   = [int][Math]::Min(100, [Math]::Round($st.Decode))
                $loadVideo = [int][Math]::Min(100, [Math]::Round($st.Video))
                $loadUtil  = [int][Math]::Min(100, [Math]::Round($st.Utilization))

                if ($mapMemUse.ContainsKey($luid)) {
                    $usedBytes   = $mapMemUse[$luid]
                    $vramUsedGB  = [Math]::Round($usedBytes / 1GB, 2)
                    # Always use physical VRAM capacity for percentage — Total Committed is virtual
                    # committed memory (much smaller than card capacity) and gives wrong results.
                    $vramFreeGB  = if ($vramBytes -gt 0) { [Math]::Round(($vramBytes - $usedBytes) / 1GB, 2) } else { $null }
                    $vramUsedPct = if ($vramBytes -gt 0) { [int][Math]::Round($usedBytes / $vramBytes * 100) } else { $null }
                    $vramFreePct = if ($null -ne $vramUsedPct) { 100 - $vramUsedPct } else { $null }
                }
            }
        }

        $results += [PSCustomObject]@{
            Index             = $i
            Model             = $gpuName
            DedicatedVramGB   = $vramGB
            Load3DPercent     = $load3D
            EncodePercent     = $loadEnc
            DecodePercent     = $loadDec
            VideoPercent      = $loadVideo
            UtilizationPercent = $loadUtil
            VramUsedGB        = $vramUsedGB
            VramFreeGB        = $vramFreeGB
            VramUsedPercent   = $vramUsedPct
            VramFreePercent   = $vramFreePct
        }
    }
    # Release CIM handles on Win32_VideoController instances
    foreach ($c in $allControllers) { if ($c) { $c.Dispose() } }
    return $results
}


# Returns aggregated CPU % and RAM for groups of processes by executable name.
# Uses a two-snapshot delta on Get-Process.CPU (same formula as Task Manager).
# One entry is always returned per name, even when no instances are running.
function Get-AppWorkload {
    param(
        [string[]]$ProcessNames = @('scrcpy', 'ffmpeg', 'powershell', 'pwsh'),
        [int]$SampleMs = 500
    )

    # Logical core count for CPU% normalisation; fall back to 1 on failure
    $logicalCores = 1
    $cpuProcs = $null
    try {
        $cpuProcs = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop)
        $logicalCores = [int]($cpuProcs | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
        if ($logicalCores -lt 1) { $logicalCores = 1 }
        foreach ($cp in $cpuProcs) { if ($cp) { $cp.Dispose() } }
    } catch { }

    # Snapshot helper: returns @{ pid = @{ CPU=[double]; MemMB=[double] } } for one name
    function _Snap {
        param([string]$Name)
        $map = @{}
        try {
            $procs = @(Get-Process -Name $Name -ErrorAction SilentlyContinue)
            foreach ($p in $procs) {
                $map[[int]$p.Id] = @{
                    CPU   = [double]$p.CPU
                    MemMB = [Math]::Round($p.WorkingSet64 / 1MB, 1)
                }
            }
        } catch { }
        return $map
    }

    # Take first snapshot for all names at once
    $snap1 = @{}
    foreach ($n in $ProcessNames) { $snap1[$n] = _Snap $n }
    $t1 = [DateTime]::UtcNow

    Start-Sleep -Milliseconds $SampleMs

    $elapsed = ([DateTime]::UtcNow - $t1).TotalSeconds
    if ($elapsed -le 0) { $elapsed = $SampleMs / 1000.0 }

    # Take second snapshot and compute results
    $results = @()
    foreach ($n in $ProcessNames) {
        $s2 = _Snap $n
        $s1 = $snap1[$n]

        $deltaCpu = 0.0
        $memMB    = 0.0
        foreach ($procId in $s2.Keys) {
            $memMB += $s2[$procId].MemMB
            # Only PIDs present in both snapshots contribute to CPU delta
            if ($s1.ContainsKey($procId)) {
                $d = $s2[$procId].CPU - $s1[$procId].CPU
                if ($d -gt 0) { $deltaCpu += $d }
            }
        }

        $cpuPct  = [Math]::Round($deltaCpu / $elapsed / $logicalCores * 100, 1)
        $maxPct  = [double]($s2.Count * 100)
        if ($cpuPct -gt $maxPct -and $maxPct -gt 0) { $cpuPct = $maxPct }

        $results += [PSCustomObject]@{
            ProcessName   = $n
            Count         = $s2.Count
            TotalCpuPct   = $cpuPct
            TotalMemoryMB = [Math]::Round($memMB, 1)
        }
    }
    return $results
}


function Get-RecordingDriveInfo {
    if ([string]::IsNullOrEmpty($global:scrcpyRecordFolder)) { return $null }

    # Extract drive letter (first char when second char is ':')
    $driveLetter = $null
    if ($global:scrcpyRecordFolder.Length -ge 2 -and $global:scrcpyRecordFolder[1] -eq ':') {
        $driveLetter = $global:scrcpyRecordFolder[0].ToString().ToUpper()
    }
    if (-not $driveLetter) { return $null }

    # Space data via Get-PSDrive (no WMI, PS-native)
    try {
        $psDrive = Get-PSDrive -Name $driveLetter -ErrorAction Stop
        $freeBytes  = $psDrive.Free
        $usedBytes  = $psDrive.Used
        $totalBytes = $freeBytes + $usedBytes
        $totalGB    = [Math]::Round($totalBytes / 1GB, 1)
        $usedGB     = [Math]::Round($usedBytes  / 1GB, 1)
        $freeGB     = [Math]::Round($freeBytes  / 1GB, 1)
        $usedPct    = if ($totalBytes -gt 0) { [int]([Math]::Round($usedBytes / $totalBytes * 100)) } else { 0 }
        $freePct    = 100 - $usedPct
    } catch {
        Write-Log ("Get-RecordingDriveInfo: failed to read drive {0}: {1}" -f $driveLetter, $_) -Level WARNING
        return $null
    }

    # Drive type detection via Storage module (Win8+).
    # Result is cached per drive letter - drive type never changes at runtime.
    # This avoids StorageWMI cold-starting on every monitoring cycle (~75s),
    # which was the cause of WmiPrvSE.exe running at 13% CPU continuously.
    $driveType = "Unknown"
    $speedLabel = $null

    if ($script:DriveTypeCache.ContainsKey($driveLetter)) {
        $driveType  = $script:DriveTypeCache[$driveLetter].DriveType
        $speedLabel = $script:DriveTypeCache[$driveLetter].SpeedGbps
    } else {
        try {
            $partition = Get-Partition -DriveLetter $driveLetter -ErrorAction Stop
            $disk      = Get-Disk -Number $partition.DiskNumber -ErrorAction Stop
            $physDisk  = Get-PhysicalDisk | Where-Object { $_.DeviceId -eq $disk.Number.ToString() } | Select-Object -First 1
            $busType   = if ($disk.BusType) { $disk.BusType.ToString() } else { '' }

            if ($busType -eq 'NVMe') {
                $driveType = "NVMe"
                $speedLabel = "~32 Gbps"
            } elseif ($physDisk -and $physDisk.MediaType -eq 'SSD') {
                $driveType = "SSD"
                $speedLabel = if ($busType -eq 'SATA') { "~6 Gbps" } else { $null }
            } elseif ($physDisk -and $physDisk.MediaType -eq 'HDD') {
                $driveType = "HDD"
            } elseif ($busType -eq 'USB') {
                $driveType = if ($physDisk -and $physDisk.MediaType -eq 'SSD') { "USB SSD" } else { "USB" }
            }

            $script:DriveTypeCache[$driveLetter] = @{ DriveType = $driveType; SpeedGbps = $speedLabel }
        } catch {
            # Storage module unavailable - leave DriveType as Unknown, do not cache so next cycle retries
        }
    }

    $minFree = if ($null -ne $global:scrcpyRecordMinFreeSpaceGB) { [int]$global:scrcpyRecordMinFreeSpaceGB } else { 5 }
    $isLow   = $freeGB -lt $minFree

    return [PSCustomObject]@{
        DriveLetter  = $driveLetter
        RecordFolder = $global:scrcpyRecordFolder
        TotalGB      = $totalGB
        UsedGB       = $usedGB
        FreeGB       = $freeGB
        UsedPercent  = $usedPct
        FreePercent  = $freePct
        DriveType    = $driveType
        SpeedGbps    = $speedLabel
        IsLow        = $isLow
        MinFreeGB    = $minFree
    }
}


function Update-ComputerMonitoring {
    # Skip if file is recent enough and no force-refresh flag file present.
    # The throttle interval is adaptive: when CPU pressure is high, slow the
    # snapshot down so the monitor itself stops adding load (saves WMI + perf-
    # counter calls). See Get-AdaptiveMonitorInterval for thresholds.
    $flagFile = Join-Path -Path $global:ScriptPath -ChildPath "data\computer_monitoring_forcerefresh.flag"
    $forceRefresh = Test-Path -LiteralPath $flagFile
    $needsRefresh = $forceRefresh
    if (-not $needsRefresh) {
        if (-not (Test-Path -LiteralPath $global:computerMonitoringFilePath)) {
            $needsRefresh = $true
        } else {
            $threshold = Get-AdaptiveMonitorInterval
            $age = (Get-Date) - (Get-Item -LiteralPath $global:computerMonitoringFilePath).LastWriteTime
            if ($age.TotalSeconds -ge $threshold) {
                $needsRefresh = $true
            }
        }
    }

    if (-not $needsRefresh) {
        Write-Log $msg.ComputerMonitoringSkipped -Level DEBUG
        return
    }

    # Remove flag file before collecting so a new request during collection is not lost
    if ($forceRefresh) {
        Remove-Item -LiteralPath $flagFile -Force -ErrorAction SilentlyContinue
    }

    $cpu       = Get-CpuInfo
    $ram       = Get-RamInfo
    # @() is mandatory: PowerShell unrolls a single-element array on return, and
    # ConvertTo-Json then writes "GPU": {...} instead of "GPU": [{...}]. The web UI
    # tests d.GPU.length, which is undefined on an object, so a machine with exactly
    # one GPU rendered no GPU card at all until the array was forced here.
    $gpu       = @(Get-GpuInfo)
    $workload  = @(Get-AppWorkload -ProcessNames @("scrcpy", "ffmpeg", "powershell"))
    $scrcpyRow = $workload | Where-Object { $_.ProcessName -eq "scrcpy" }
    $recDrive  = Get-RecordingDriveInfo

    $snapshot = [PSCustomObject]@{
        Timestamp      = [datetime]::Now.ToString("yyyy-MM-ddTHH:mm:ss")
        CPU            = $cpu
        RAM            = $ram
        GPU            = $gpu
        AppWorkload    = $workload
        ScrcpyCount    = if ($scrcpyRow) { [int]$scrcpyRow.Count } else { 0 }
        RecordingDrive = $recDrive
    }

    $json = $snapshot | ConvertTo-Json -Depth 5
    Write-FileWithoutBom -Path $global:computerMonitoringFilePath -Content $json

    Write-Log $msg.ComputerMonitoringUpdated -Level DEBUG

    # Auto-disable recording on all headsets when drive space drops below threshold
    if ($recDrive -and $recDrive.IsLow) {
        try {
            $rows    = Get-KnownHeadsets
            $changed = $false
            foreach ($h in $rows) {
                if (ConvertTo-BoolField $h.Record) {
                    $h.Record = 'False'
                    $changed  = $true
                    Write-Log ("Recording auto-disabled on {0} - drive {1}: only {2} GB free (min {3} GB)" -f $h.Name, $recDrive.DriveLetter, $recDrive.FreeGB, $recDrive.MinFreeGB) -Level WARNING
                }
            }
            if ($changed) { Save-Headsets -headsets $rows }
        } catch {
            Write-Log ("Update-ComputerMonitoring: failed to auto-disable recording: {0}" -f $_) -Level WARNING
        }
    }
}


###############################################################
# Port-availability helpers
# Used by Resolve-PortConflict (console_manager.ps1) and the
# startup orchestrator Confirm-AppPortsAvailable.
###############################################################


# Prompt for a port number on the console, validate it is within 1024-65535,
# loop until valid. Empty input returns -Default.
# Moved from welcome.ps1 so it can be reused from any module without circular deps.
function Read-ValidPort {
    param([string]$Label, [int]$Default)
    while ($true) {
        Write-Host "  $Label [default: $Default]: " -ForegroundColor White -NoNewline
        $raw = Read-Host
        if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
        $val = 0
        if ([int]::TryParse($raw, [ref]$val) -and $val -ge 1024 -and $val -le 65535) {
            return $val
        }
        Write-Host "  Invalid. Enter a number between 1024 and 65535." -ForegroundColor Red
    }
}


# Returns $true when no local socket is listening on $Port for the given
# protocol(s). Uses Get-NetTCPConnection / Get-NetUDPEndpoint with
# SilentlyContinue so it never throws on Win10 standard-user contexts.
function Test-LocalPortFree {
    param(
        [Parameter(Mandatory=$true)][int]$Port,
        [ValidateSet('TCP','UDP','Both')]
        [string]$Protocol = 'TCP'
    )
    if ($Protocol -in @('TCP','Both')) {
        $tcp = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
        if ($tcp) { return $false }
    }
    if ($Protocol -in @('UDP','Both')) {
        $udp = Get-NetUDPEndpoint -LocalPort $Port -ErrorAction SilentlyContinue
        if ($udp) { return $false }
    }
    return $true
}


# Returns @{Pid; ProcessName; ProcessPath; Port; Protocol} for the process
# that owns the listening socket on $Port, or $null when the port is free.
# Path may be empty for system processes when access is denied.
# Parse `netsh http show servicestate view=session` and return the userspace
# PID that registered a URL for -Port on HTTP.sys. Returns $null when nothing
# active is bound to that port. Locale-independent: the netsh output uses
# the ASCII markers "ID:" (process attachment) and "HTTP://...:<port>/"
# regardless of Windows display language.
#
# Note: the output has two kinds of blocks that reference a port URL:
#   1. URL group reservations (no process attached) - MUST be skipped.
#   2. Request queue sessions (PID + attached URLs) - the answer we want.
# We track the last-seen PID and only return it when its FOLLOWING URL list
# contains the target port. Reservation-only blocks never set a PID, so
# their URLs (encountered first in the output) fall through harmlessly.
function Get-HttpSysPortOwnerPid {
    param([Parameter(Mandatory=$true)][int]$Port)
    try {
        $lines = & netsh http show servicestate view=session 2>$null
    } catch { return $null }
    if (-not $lines) { return $null }

    $currentPid  = $null
    $portPattern = ':' + $Port + '/'
    foreach ($raw in $lines) {
        $line = "$raw"
        # PID markers observed across Windows versions / locales:
        #   "ID: 12345, image: <path>"   (Win10/11, all locales)
        #   "PID : 12345"                (older builds)
        #   "process ID is: 12345"       (English long-form)
        if ($line -match '^\s*ID\s*:\s*(\d+)' `
                -or $line -match '\bPID\s*:\s*(\d+)' `
                -or $line -match 'process ID is[:\s]+(\d+)') {
            $currentPid = [int]$Matches[1]
            continue
        }
        if ($currentPid -and $line -match '^\s*https?://' -and $line -like "*$portPattern*") {
            return $currentPid
        }
    }
    return $null
}

function Get-LocalPortOwner {
    param(
        [Parameter(Mandatory=$true)][int]$Port,
        [ValidateSet('TCP','UDP','Both')]
        [string]$Protocol = 'TCP'
    )
    $owningPid = $null
    $proto     = $null
    if ($Protocol -in @('TCP','Both')) {
        $tcp = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($tcp) {
            $owningPid = [int]$tcp.OwningProcess
            $proto     = 'TCP'
        }
    }
    if (-not $owningPid -and $Protocol -in @('UDP','Both')) {
        $udp = Get-NetUDPEndpoint -LocalPort $Port -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($udp) {
            $owningPid = [int]$udp.OwningProcess
            $proto     = 'UDP'
        }
    }

    # HTTP.sys reserved ports (e.g. HttpListener behind a URL ACL) report the
    # System kernel PID 4 instead of the userspace listener. Ask http.sys who
    # actually registered the URL. Same fallback if the query returned nothing.
    if ((-not $owningPid -or $owningPid -eq 4) -and $Protocol -in @('TCP','Both')) {
        $httpPid = Get-HttpSysPortOwnerPid -Port $Port
        if ($httpPid) {
            $owningPid = $httpPid
            $proto     = 'TCP'
        }
    }

    if (-not $owningPid) { return $null }

    $procName = $null
    $procPath = $null
    try {
        $proc = Get-Process -Id $owningPid -ErrorAction Stop
        $procName = $proc.ProcessName
        try { $procPath = $proc.Path } catch { $procPath = $null }
    } catch {
        $procName = "<unknown>"
        $procPath = $null
    }
    return @{
        Pid         = $owningPid
        ProcessName = $procName
        ProcessPath = $procPath
        Port        = $Port
        Protocol    = $proto
    }
}


# Walks $Pool (typically a service's pre-defined port range) and returns the
# first port that is currently free. -SkipPort lets the caller exclude the
# already-conflicting port (the candidate must be different from it).
# Returns $null when the entire pool is in use.
function Find-NextFreePortInPool {
    param(
        [Parameter(Mandatory=$true)][int[]]$Pool,
        [int]$SkipPort = 0,
        [ValidateSet('TCP','UDP','Both')]
        [string]$Protocol = 'TCP'
    )
    foreach ($p in $Pool) {
        if ($p -eq $SkipPort) { continue }
        if (Test-LocalPortFree -Port $p -Protocol $Protocol) { return [int]$p }
    }
    return $null
}


# -------------------------------------------------------------------
# GPU encoder resolution and adaptive monitoring interval
# Used by the ffmpeg restream path and the VRMonitor slow path.
# -------------------------------------------------------------------

# Builds the per-encoder low-latency argument list used for the mediamtx RTSP push.
# Lives here (not in scrcpy_launcher.ps1) so Test-FfmpegEncoder probes the EXACT
# configuration the stream will run with. Keeping them in two places is what let the
# h264_amf keyframe bug ship: the probe only ever tried a bare "-c:v h264_amf", which
# works fine, while the stream added "-usage ultralowlatency", which does not.
#
# -bf 0 and -g $Gop are required on EVERY arm: mediamtx WebRTC/WHEP rejects H.264
# streams containing B-frames ("WebRTC doesn't support H264 streams with B-frames"
# closes the session). qsv/amf/mf emit B-frames by default; nvenc and libx264 already
# disable them via tune presets but explicit is safer. A short GOP (= framerate)
# ensures new WHEP subscribers receive a keyframe within ~1s of joining.
#
# Per-encoder low-latency tails disable async pipelining / lookahead so frames flow
# through with minimal in-encoder queuing. qsv defaults to async_depth=4 (~130 ms at
# 30 fps); nvenc has an implicit -delay; the libx264 fallback uses sliced threading to
# avoid frame-level latency.
function Get-StreamEncoderArgs {
    param(
        [Parameter(Mandatory)][string]$EncoderName,
        [Parameter(Mandatory)][string]$Bitrate,
        [Parameter(Mandatory)][string]$Gop
    )
    $bw  = $Bitrate
    $gop = $Gop
    switch ($EncoderName) {
        'h264_nvenc' { @('-c:v','h264_nvenc','-preset','p1','-tune','ll','-rc','cbr','-b:v',$bw,'-maxrate',$bw,'-bufsize',$bw,'-bf','0','-g',$gop,'-delay','0','-rc-lookahead','0') }
        'h264_qsv'   { @('-c:v','h264_qsv','-preset','veryfast','-b:v',$bw,'-maxrate',$bw,'-bufsize',$bw,'-bf','0','-g',$gop,'-async_depth','1','-look_ahead','0') }
        # h264_amf must NOT use -usage ultralowlatency: on AMF the usage preset is
        # applied inside AMFComponent::Init and overwrites IDR_PERIOD, so -g (and
        # -header_spacing / -forced_idr / -force_key_frames) are all silently ignored -
        # the encoder then emits exactly ONE IDR + one SPS/PPS at startup and nothing
        # but P-frames afterwards. Any WHEP viewer that opens the page after that first
        # frame never receives a keyframe and shows a permanent black screen (verified
        # on Radeon 780M / driver 32.0.21020.1007: 90 frames -> 1 IDR with
        # ultralowlatency, 3 IDR + 3 SPS/PPS with the args below). hevc_amf on the same
        # hardware honours -g even with ultralowlatency, which is why h265 looked fine
        # while h264 was black.
        # "-usage transcoding -latency 1" keeps AMF's low-latency mode (no B-frames, no
        # lookahead - measured identical throughput) while leaving IDR_PERIOD under our
        # control. -header_spacing repeats SPS/PPS on every keyframe.
        'h264_amf'   { @('-c:v','h264_amf','-usage','transcoding','-latency','1','-b:v',$bw,'-maxrate',$bw,'-bufsize',$bw,'-bf','0','-g',$gop,'-header_spacing',$gop,'-forced_idr','1','-quality','speed','-rc','cbr','-async_depth','1') }
        'h264_mf'    { @('-c:v','h264_mf','-b:v',$bw,'-bf','0','-g',$gop,'-rc_mode','CBR') }
        'hevc_nvenc' { @('-c:v','hevc_nvenc','-preset','p1','-tune','ll','-rc','cbr','-b:v',$bw,'-maxrate',$bw,'-bufsize',$bw,'-bf','0','-g',$gop,'-delay','0','-rc-lookahead','0','-tag:v','hvc1') }
        'hevc_qsv'   { @('-c:v','hevc_qsv','-preset','veryfast','-b:v',$bw,'-maxrate',$bw,'-bufsize',$bw,'-bf','0','-g',$gop,'-async_depth','1','-look_ahead','0','-tag:v','hvc1') }
        # hevc_amf honours -g under ultralowlatency on every driver tested here, but it
        # gets the same explicit keyframe/header args as h264_amf so a future driver
        # cannot reintroduce the same silent black-screen failure on this arm.
        'hevc_amf'   { @('-c:v','hevc_amf','-usage','transcoding','-latency','1','-b:v',$bw,'-maxrate',$bw,'-bufsize',$bw,'-bf','0','-g',$gop,'-header_spacing',$gop,'-forced_idr','1','-quality','speed','-rc','cbr','-async_depth','1','-tag:v','hvc1') }
        'hevc_mf'    { @('-c:v','hevc_mf','-b:v',$bw,'-bf','0','-g',$gop,'-rc_mode','CBR','-tag:v','hvc1') }
        'libx265'    { @('-c:v','libx265','-preset','ultrafast','-tune','zerolatency','-b:v',$bw,'-maxrate',$bw,'-bufsize',$bw,'-bf','0','-g',$gop,'-x265-params','force-cfr=1','-tag:v','hvc1','-threads','4') }
        default      { @('-c:v','libx264','-preset','ultrafast','-tune','zerolatency','-b:v',$bw,'-maxrate',$bw,'-bufsize',$bw,'-bf','0','-g',$gop,'-x264-params','nal-hrd=cbr:force-cfr=1:sliced-threads=1','-threads','4') }
    }
}

# Probe a single ffmpeg encoder in two stages:
#  Stage 1 - open check: does the encoder session even open and accept a frame?
#            (1-frame smoke test against a black source, discarded to -f null -)
#  Stage 2 - output check: run the REAL streaming configuration (via
#            Get-StreamEncoderArgs) over a few GOPs of a non-black synthetic pattern,
#            decode the result back, and verify two things:
#              a) the frames did not come back black - some GPU/driver stacks accept
#                 the session and exit 0 but silently emit black/corrupt frames (seen
#                 with h264_amf on some AMD Z1 Extreme / Radeon 780M driver builds,
#                 while hevc_amf on the SAME hardware works fine). Stage 1 alone
#                 cannot catch this since its source is already black.
#              b) the encoder actually honours -g and emits periodic keyframes. An
#                 encoder that emits a single IDR at startup looks perfectly healthy
#                 on disk but leaves every WHEP viewer that joins later on a black
#                 page forever, because WebRTC cannot start decoding without one.
# Returns @{Ok; Reason} - Reason is 'open-failed', 'black-output' or 'no-keyframes'
# when Ok=$false, $null when Ok=$true.
function Test-FfmpegEncoder {
    param(
        [Parameter(Mandatory)] [string] $Encoder,
        [string[]] $ExtraArgs = @()
    )
    if (-not (Test-Path -LiteralPath $global:ffmpegFilePath)) { return @{ Ok = $false; Reason = 'open-failed' } }

    $openArgs = @('-hide_banner','-loglevel','error','-f','lavfi','-i','color=c=black:s=320x240:r=10:d=0.1')
    $openArgs += $ExtraArgs
    $openArgs += @('-c:v',$Encoder,'-frames:v','1','-f','null','-')
    try {
        $null = & $global:ffmpegFilePath @openArgs 2>&1
        if ($LASTEXITCODE -ne 0) { return @{ Ok = $false; Reason = 'open-failed' } }
    } catch {
        return @{ Ok = $false; Reason = 'open-failed' }
    }

    # 3 s at 10 fps with -g 10 -> 30 frames, 3 expected keyframes. Deliberately short:
    # this runs on every scrcpy (re)start before the stream can come up.
    $probeGop = 10
    $probeSrc = 'testsrc2=size=320x240:rate={0}:duration=3' -f $probeGop
    $tmpFile  = Join-Path $env:TEMP ("vrhm_encprobe_{0}.mkv" -f ([guid]::NewGuid().ToString('N')))
    try {
        $encArgs = @('-hide_banner','-loglevel','error','-f','lavfi','-i',$probeSrc)
        $encArgs += $ExtraArgs
        $encArgs += (Get-StreamEncoderArgs -EncoderName $Encoder -Bitrate '2M' -Gop ([string]$probeGop))
        $encArgs += @('-y',$tmpFile)
        $null = & $global:ffmpegFilePath @encArgs 2>&1
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $tmpFile)) { return @{ Ok = $false; Reason = 'open-failed' } }

        # One decode pass yields both checks: blackframe reports black frames, showinfo
        # reports the picture type of every frame.
        $checkArgs = @('-hide_banner','-loglevel','info','-i',$tmpFile,'-vf','blackframe=98:32,showinfo','-f','null','-')
        $checkOut = & $global:ffmpegFilePath @checkArgs 2>&1
        $blackFrames = 0
        $keyFrames   = 0
        foreach ($line in $checkOut) {
            if ($line -match 'blackframe.*pblack:') { $blackFrames++ }
            if ($line -match 'showinfo.*type:I')    { $keyFrames++ }
        }
        # ~30 encoded frames; treat as broken when nearly all come back black.
        if ($blackFrames -ge 24) { return @{ Ok = $false; Reason = 'black-output' } }
        # 3 keyframes expected; require at least 2 so a one-IDR-only encoder is rejected
        # while slightly different GOP placement still passes.
        if ($keyFrames -lt 2) { return @{ Ok = $false; Reason = 'no-keyframes' } }
        return @{ Ok = $true; Reason = $null }
    } catch {
        return @{ Ok = $false; Reason = 'black-output' }
    } finally {
        if (Test-Path -LiteralPath $tmpFile) { Remove-Item -LiteralPath $tmpFile -Force -ErrorAction SilentlyContinue }
    }
}

# Return the vendor tag for a Get-GpuInfo entry.
function Get-GpuVendor {
    param([Parameter(Mandatory)] $Gpu)
    $m = $Gpu.Model
    if     ($m -match '(?i)nvidia|geforce|quadro|rtx|gtx') { return 'NVIDIA' }
    elseif ($m -match '(?i)intel')                         { return 'Intel' }
    elseif ($m -match '(?i)amd|radeon')                    { return 'AMD' }
    else                                                   { return 'Unknown' }
}

# Build the priority list of GPU encoders ordered by the selected GPU's vendor.
# Returns an array of @{Name; ExtraArgs; Vendor} (libx264 is always last).
#
# Important: ffmpeg's `-gpu` (nvenc) and `-init_hw_device qsv=hw:N` flags use
# vendor-local enumeration (Nth NVIDIA / Intel device), NOT the system-wide
# index. We translate $GpuIndex (system-wide, from Get-GpuInfo) to a vendor-
# local index, and omit the flag entirely when only one device of that vendor
# is present - it's both unnecessary and rejected by some driver builds.
function Get-GpuEncoderCandidates {
    param([int]$GpuIndex = 0, [string]$Codec = 'h264')
    $gpus = @(); try { $gpus = @(Get-GpuInfo) } catch { $gpus = @() }
    $selected = $null
    if ($gpus.Count -gt 0) {
        if ($GpuIndex -ge 0 -and $GpuIndex -lt $gpus.Count) { $selected = $gpus[$GpuIndex] }
        else { $selected = $gpus[0] }
    }
    $vendor = if ($selected) { Get-GpuVendor -Gpu $selected } else { 'Unknown' }

    # Per-vendor device counts and vendor-local index of the selected GPU
    function _LocalIndex { param($gpus,$vendor,$selected)
        $count = 0; $idx = -1
        for ($i=0; $i -lt $gpus.Count; $i++) {
            if ((Get-GpuVendor -Gpu $gpus[$i]) -eq $vendor) {
                if ($selected -and $gpus[$i].Index -eq $selected.Index) { $idx = $count }
                $count++
            }
        }
        return @{ Count=$count; Local=$idx }
    }
    $nv = _LocalIndex $gpus 'NVIDIA' $selected
    $it = _LocalIndex $gpus 'Intel'  $selected

    $nvencArgs = @()
    if ($vendor -eq 'NVIDIA' -and $nv.Count -gt 1 -and $nv.Local -ge 0) { $nvencArgs = @('-gpu',"$($nv.Local)") }
    $qsvArgs = @()
    if ($vendor -eq 'Intel' -and $it.Count -gt 1 -and $it.Local -ge 0) { $qsvArgs = @('-init_hw_device',"qsv=hw:$($it.Local)",'-filter_hw_device','hw') }

    $isHevc = ($Codec -eq 'h265')
    $nvencName = if ($isHevc) { 'hevc_nvenc' } else { 'h264_nvenc' }
    $qsvName   = if ($isHevc) { 'hevc_qsv' }   else { 'h264_qsv' }
    $amfName   = if ($isHevc) { 'hevc_amf' }   else { 'h264_amf' }
    $mfName    = if ($isHevc) { 'hevc_mf' }    else { 'h264_mf' }
    $x264Name  = if ($isHevc) { 'libx265' }    else { 'libx264' }

    $nvenc = @{ Name=$nvencName; Vendor='NVIDIA'; ExtraArgs=$nvencArgs; Codec=$Codec }
    $qsv   = @{ Name=$qsvName;   Vendor='Intel';  ExtraArgs=$qsvArgs;   Codec=$Codec }
    $amf   = @{ Name=$amfName;   Vendor='AMD';    ExtraArgs=@();        Codec=$Codec }
    $mf    = @{ Name=$mfName;    Vendor='Any';    ExtraArgs=@();        Codec=$Codec }
    $x264  = @{ Name=$x264Name;  Vendor='CPU';    ExtraArgs=@();        Codec=$Codec }

    switch ($vendor) {
        'NVIDIA' { return @($nvenc,$qsv,$amf,$mf,$x264) }
        'Intel'  { return @($qsv,$nvenc,$amf,$mf,$x264) }
        'AMD'    { return @($amf,$nvenc,$qsv,$mf,$x264) }
        default  { return @($nvenc,$qsv,$amf,$mf,$x264) }
    }
}

# Resolve the best GPU encoder once per session. Cached in $global:GpuEncoder.
# Pass -Force to re-probe (e.g. after the operator changed GPU_Index at runtime).
# Returns @{Name; ExtraArgs; Vendor} - never $null (libx264 is the guaranteed last resort).
function Get-GpuEncoder {
    param([switch]$Force)
    $codec = if ($global:mediamtxCodec) { $global:mediamtxCodec } else { 'h264' }
    if (-not $Force -and $null -ne $global:GpuEncoder -and $global:GpuEncoder.Codec -eq $codec) { return $global:GpuEncoder }

    $x264Name = if ($codec -eq 'h265') { 'libx265' } else { 'libx264' }

    # GPU acceleration disabled -> always CPU software encoder
    if (-not $global:GPU_Acceleration) {
        $global:GpuEncoder = @{ Name=$x264Name; Vendor='CPU'; ExtraArgs=@(); Codec=$codec }
        return $global:GpuEncoder
    }

    # Enumerate encoders actually built into the bundled ffmpeg
    $available = @()
    try {
        $out = & $global:ffmpegFilePath -hide_banner -encoders 2>&1
        foreach ($line in $out) {
            if ($line -match '^\s*V[\.A-Z]+\s+(\S+)\s+') { $available += $Matches[1] }
        }
    } catch { }

    $candidates = Get-GpuEncoderCandidates -GpuIndex $global:GPU_Index -Codec $codec
    foreach ($c in $candidates) {
        if ($c.Name -eq $x264Name) {
            # No probe needed - the software encoder is always present in the bundled ffmpeg.
            $global:GpuEncoder = $c
            try { Write-Log ("GpuEncoder resolved: {0} (vendor {1}) - fallback" -f $c.Name, $c.Vendor) -Level INFO } catch {}
            return $c
        }
        if ($available -notcontains $c.Name) { continue }
        $probe = Test-FfmpegEncoder -Encoder $c.Name -ExtraArgs $c.ExtraArgs
        if ($probe.Ok) {
            $global:GpuEncoder = $c
            try { Write-Log ("GpuEncoder resolved: {0} (vendor {1}) GpuIndex={2}" -f $c.Name, $c.Vendor, $global:GPU_Index) -Level SUCCESS } catch {}
            return $c
        } else {
            $reasonText = switch ($probe.Reason) {
                'black-output' { 'produced black output' }
                'no-keyframes' { 'ignored -g and emitted no periodic keyframes (WHEP viewers would see a black page)' }
                default         { 'failed to open' }
            }
            try { Write-Log ("GpuEncoder probe failed for {0} ({1}), trying next" -f $c.Name, $reasonText) -Level DEBUG } catch {}
        }
    }
    # Should never reach here (the software encoder is in the list and returned unconditionally above).
    $global:GpuEncoder = @{ Name=$x264Name; Vendor='CPU'; ExtraArgs=@(); Codec=$codec }
    return $global:GpuEncoder
}

# -------------------------------------------------------------------
# Cross-process lock (data\vqa.lock)
# The web server process and the VRMonitor background job can both call
# VQA apply/restore, and the web server's /api/config/save handler also
# uses this lock around its own mediamtx/scrcpy restart sequence. Lives
# here (not in video_quality_automation.ps1) so it is always loaded even
# when VideoQualityAutomation.enabled is false and that module is skipped.
# Always release via Exit-VqaLock in a finally block.
# -------------------------------------------------------------------

function Enter-VqaLock {
    param([int]$TimeoutMs = 3000)
    $lockPath = Join-Path $global:ScriptPath 'data\vqa.lock'
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        try {
            return [System.IO.FileStream]::new(
                $lockPath,
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::None)
        } catch [System.IO.IOException] {
            Start-Sleep -Milliseconds 100
        }
    }
    return $null
}

function Exit-VqaLock {
    param($Stream)
    if ($Stream) {
        try { $Stream.Dispose() } catch { }
    }
}

# -------------------------------------------------------------------
# Load-aware monitoring throttle (single source of truth)
#
# Get-LoadTier classifies the latest CPU snapshot into three levels;
# Get-LoadMultiplier converts that into 1 / 2 / 5; every adaptive interval
# in the app (Update-ComputerMonitoring throttle, browser polling, VQR
# slow-path tick gating) reads from these two helpers.
#
# Reuses the existing VQA CPU thresholds so the operator does not have to
# maintain a second set of values. When VQA is disabled, or Adaptive_Monitoring
# is disabled, or there is no snapshot to read, the tier collapses to 'idle'
# (multiplier 1) and every interval reverts to its configured base.
# -------------------------------------------------------------------

function Get-LoadTier {
    if (-not $global:AdaptiveMonitoring_Enabled) { return 'idle' }
    if (-not $global:VQA_Enabled)                { return 'idle' }
    if (-not (Test-Path -LiteralPath $global:computerMonitoringFilePath)) { return 'idle' }
    try {
        $snap = Get-Content -LiteralPath $global:computerMonitoringFilePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch { return 'idle' }
    $cpu = $null
    if     ($null -ne $snap.CPU.LoadPercent) { $cpu = [int]$snap.CPU.LoadPercent }
    elseif ($null -ne $snap.Cpu.LoadPercent) { $cpu = [int]$snap.Cpu.LoadPercent }
    elseif ($null -ne $snap.CpuLoadPercent)  { $cpu = [int]$snap.CpuLoadPercent }
    if ($null -eq $cpu) { return 'idle' }
    if ($cpu -ge [int]$global:VQA_CpuMaxThreshold)        { return 'max' }
    if ($cpu -ge [int]$global:VQA_CpuMitigationThreshold) { return 'mitigation' }
    return 'idle'
}

function Get-LoadMultiplier {
    switch (Get-LoadTier) {
        'max'        { return 5 }
        'mitigation' { return 2 }
        default      { return 1 }
    }
}

# Returns the slow-path interval (seconds) for the VRMonitor's
# Update-ComputerMonitoring throttle. Always >= base; high CPU LENGTHENS the
# interval (so the monitor stops adding to the load it is measuring).
# Clamped at 600 s to avoid runaway intervals on long-running max-tier load.
function Get-AdaptiveMonitorInterval {
    $base = if ($null -ne $global:ComputerMonitoring_refresh_timer_sec) { [int]$global:ComputerMonitoring_refresh_timer_sec } else { 60 }
    $m    = Get-LoadMultiplier
    return [Math]::Min(600, $base * $m)
}

# Returns the installed ffmpeg version string (e.g. "7.0.2"), or $null if the
# exe is missing or the output cannot be parsed. Runs "ffmpeg -version" and
# reads the first line ("ffmpeg version 7.0.2-full_build-www.gyan.dev ...").
function Get-FfmpegVersion {
    param([string]$FfmpegPath = $global:ffmpegFilePath)
    if (-not $FfmpegPath -or -not (Test-Path -LiteralPath $FfmpegPath)) { return $null }
    try {
        $out = & $FfmpegPath -version 2>&1
        $first = $out | Select-Object -First 1
        # Gyan builds report "ffmpeg version 9.0.1-essentials_build-www.gyan.dev ...".
        # Extract just the numeric version so it compares equal to the bare
        # X.Y.Z string Get-LatestFfmpegVersion parses from the release asset name.
        if ($first -match 'ffmpeg version\s+(\d+(?:\.\d+){1,2})') { return $Matches[1] }
        if ($first -match 'ffmpeg version\s+(\S+)') { return $Matches[1] }
        return $null
    } catch {
        return $null
    }
}

# Queries the GyanD/codexffmpeg GitHub releases API for the latest available
# build. Returns @{Version; DownloadUrl; AssetName} or $null on network/parse
# failure. Never called automatically (only on operator-triggered "check for
# update") to avoid hitting GitHub on every page load.
function Get-LatestFfmpegVersion {
    try {
        $apiUrl = "https://api.github.com/repos/GyanD/codexffmpeg/releases/latest"
        $headers = @{ 'User-Agent' = 'VR-Headset-Manager' }
        $release = Invoke-RestMethod -Uri $apiUrl -Headers $headers -TimeoutSec 15
        $asset = $release.assets | Where-Object { $_.name -like "*essentials_build-www.zip" } | Select-Object -First 1
        if (-not $asset) {
            $asset = $release.assets | Where-Object { $_.name -like "*.zip" } | Select-Object -First 1
        }
        if (-not $asset) { return $null }
        $version = $release.tag_name
        if ($asset.name -match '(\d+\.\d+(\.\d+)?)') { $version = $Matches[1] }
        return @{ Version = $version; DownloadUrl = $asset.browser_download_url; AssetName = $asset.name }
    } catch {
        return $null
    }
}

# Downloads and installs the latest ffmpeg build to a NEW versioned folder
# "<SourcesFolder>\ffmpeg\ffmpeg-<version>\ffmpeg.exe" - the previously installed version's
# folder is left untouched on disk (no in-place upgrade; config.ffmpeg.folder is what selects
# the active one), same convention as Update-MediaMtxBinary/Update-ScrcpyBinary.
# No-ops (Success=true) if that version's folder already exists.
# Shared implementation used by the first-run welcome wizard (Invoke-FfmpegDownload in
# welcome.ps1) and the web UI update endpoint - same GitHub release, same
# BITS-with-WebClient-fallback download, same zip extraction logic.
# Returns @{Success; Version; Folder (relative to SourcesFolder); Error}.
function Update-FfmpegBinary {
    param([string]$SourcesFolder = (Join-Path $global:ScriptPath "sources"))
    try {
        $latest = Get-LatestFfmpegVersion
        if (-not $latest) {
            return @{ Success = $false; Version = $null; Folder = $null; Error = "Could not query latest ffmpeg release from GitHub." }
        }
        $parentFolder = Join-Path $SourcesFolder "ffmpeg"
        $destFolder   = Join-Path $parentFolder ("ffmpeg-{0}" -f $latest.Version)
        $relFolder    = Join-Path "ffmpeg" (Split-Path -Path $destFolder -Leaf)
        $destExe      = Join-Path $destFolder "ffmpeg.exe"

        if (Test-Path -LiteralPath $destExe) {
            return @{ Success = $true; Version = $latest.Version; Folder = $relFolder; Error = $null }
        }

        $zipPath = Join-Path $env:TEMP "vrm_ffmpeg_download.zip"
        $bitsOk = $false
        try {
            $bits = Get-Service -Name BITS -ErrorAction Stop
            if ($bits.Status -eq 'Running' -or $bits.StartType -ne 'Disabled') {
                Start-BitsTransfer -Source $latest.DownloadUrl -Destination $zipPath -Description "Downloading ffmpeg..." -ErrorAction Stop
                $bitsOk = $true
            }
        } catch { }
        if (-not $bitsOk) {
            $wc = [System.Net.WebClient]::new()
            $wc.Headers.Add('User-Agent', 'VR-Headset-Manager')
            $wc.DownloadFile($latest.DownloadUrl, $zipPath)
            $wc.Dispose()
        }

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
        $entry = $zip.Entries | Where-Object { $_.FullName -like "*/bin/ffmpeg.exe" } | Select-Object -First 1
        if (-not $entry) {
            $zip.Dispose()
            Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
            return @{ Success = $false; Version = $null; Folder = $null; Error = "Could not find bin\ffmpeg.exe in the downloaded archive." }
        }
        if (-not (Test-Path -LiteralPath $destFolder)) {
            New-Item -ItemType Directory -Path $destFolder | Out-Null
        }
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $destExe, $true)

        # Best-effort: the same gyan.dev zip normally also ships bin/ffprobe.exe.
        # Not every build variant includes it, so a miss here must not fail the
        # ffmpeg update itself - callers that need ffprobe (e.g. the non-regression
        # harness) tolerate its absence.
        try {
            $probeEntry = $zip.Entries | Where-Object { $_.FullName -like "*/bin/ffprobe.exe" } | Select-Object -First 1
            if ($probeEntry) {
                $destProbe = Join-Path $destFolder "ffprobe.exe"
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($probeEntry, $destProbe, $true)
            }
        } catch { }

        $zip.Dispose()
        Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue

        if (-not (Test-Path -LiteralPath $destExe)) {
            return @{ Success = $false; Version = $null; Folder = $null; Error = "Downloaded archive did not contain ffmpeg.exe." }
        }
        $newVersion = Get-FfmpegVersion -FfmpegPath $destExe
        return @{ Success = $true; Version = $newVersion; Folder = $relFolder; Error = $null }
    } catch {
        return @{ Success = $false; Version = $null; Folder = $null; Error = $_.Exception.Message }
    }
}

# Returns the installed mediamtx version string (e.g. "1.17.1"), or $null if
# unparsable. mediamtx binaries are shipped one-per-version-folder (no shared
# in-place upgrade), so the version is read from the folder name itself
# (e.g. "mediamtx_v1.17.1_windows_amd64") rather than by invoking the exe.
function Get-MediaMtxVersion {
    param([string]$MediaMtxFolder = $global:mediamtxFolder)
    if (-not $MediaMtxFolder) { return $null }
    $leaf = Split-Path -Path $MediaMtxFolder -Leaf
    if ($leaf -match 'v(\d+(?:\.\d+){1,2})') { return $Matches[1] }
    return $null
}

# Queries the bluenviron/mediamtx GitHub releases API for the latest available
# Windows amd64 build. Returns @{Version; DownloadUrl; AssetName} or $null on
# network/parse failure. Only called on operator-triggered "check for update".
function Get-LatestMediaMtxVersion {
    try {
        $apiUrl = "https://api.github.com/repos/bluenviron/mediamtx/releases/latest"
        $headers = @{ 'User-Agent' = 'VR-Headset-Manager' }
        $release = Invoke-RestMethod -Uri $apiUrl -Headers $headers -TimeoutSec 15
        $asset = $release.assets | Where-Object { $_.name -like "*windows_amd64.zip" } | Select-Object -First 1
        if (-not $asset) { return $null }
        $version = $release.tag_name -replace '^v', ''
        if ($asset.name -match 'v?(\d+(?:\.\d+){1,2})') { $version = $Matches[1] }
        return @{ Version = $version; DownloadUrl = $asset.browser_download_url; AssetName = $asset.name }
    } catch {
        return $null
    }
}

# Downloads and installs the latest mediamtx build to a NEW versioned folder
# "<SourcesFolder>\MediaMTX\mediamtx_v<version>_windows_amd64\" - the existing
# installed version's folder is left untouched on disk (mediamtx has no
# in-place upgrade; config.mediamtx.folder is what selects the active one).
# No-ops (returns Success=true) if that version's folder already exists.
# Returns @{Success; Version; Folder (relative to SourcesFolder); Error}.
function Update-MediaMtxBinary {
    param([string]$SourcesFolder = (Join-Path $global:ScriptPath "sources"))
    try {
        $latest = Get-LatestMediaMtxVersion
        if (-not $latest) {
            return @{ Success = $false; Version = $null; Folder = $null; Error = "Could not query latest mediamtx release from GitHub." }
        }
        $parentFolder = Join-Path $SourcesFolder "MediaMTX"
        $destFolder   = Join-Path $parentFolder ("mediamtx_v{0}_windows_amd64" -f $latest.Version)
        $relFolder    = Join-Path "MediaMTX" (Split-Path -Path $destFolder -Leaf)

        if (Test-Path -LiteralPath (Join-Path $destFolder "mediamtx.exe")) {
            return @{ Success = $true; Version = $latest.Version; Folder = $relFolder; Error = $null }
        }

        $zipPath = Join-Path $env:TEMP "vrm_mediamtx_download.zip"
        $bitsOk = $false
        try {
            $bits = Get-Service -Name BITS -ErrorAction Stop
            if ($bits.Status -eq 'Running' -or $bits.StartType -ne 'Disabled') {
                Start-BitsTransfer -Source $latest.DownloadUrl -Destination $zipPath -Description "Downloading mediamtx..." -ErrorAction Stop
                $bitsOk = $true
            }
        } catch { }
        if (-not $bitsOk) {
            $wc = [System.Net.WebClient]::new()
            $wc.Headers.Add('User-Agent', 'VR-Headset-Manager')
            $wc.DownloadFile($latest.DownloadUrl, $zipPath)
            $wc.Dispose()
        }

        if (-not (Test-Path -LiteralPath $parentFolder)) {
            New-Item -ItemType Directory -Path $parentFolder | Out-Null
        }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        # destFolder must not exist yet for ExtractToDirectory - guaranteed by the
        # early-return check above.
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $destFolder)
        Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue

        if (-not (Test-Path -LiteralPath (Join-Path $destFolder "mediamtx.exe"))) {
            return @{ Success = $false; Version = $null; Folder = $null; Error = "Downloaded archive did not contain mediamtx.exe." }
        }
        return @{ Success = $true; Version = $latest.Version; Folder = $relFolder; Error = $null }
    } catch {
        return @{ Success = $false; Version = $null; Folder = $null; Error = $_.Exception.Message }
    }
}

# Enumerates all installed version folders of a bundled binary under
# "<SourcesFolder>\<ParentFolder>\" (Update-*Binary never deletes an old version folder on
# update, so multiple can coexist). Shared body for Get-MediaMtxInstalledVersions,
# Get-ScrcpyInstalledVersions and Get-FfmpegInstalledVersions - only the parent folder name,
# exe file name, and version regex differ between binaries.
# -VersionPattern must contain exactly one capture group for the version string (matched
# against the folder name). Returns [PSCustomObject[]] of @{Version; RelativeFolder; IsActive},
# sorted by version descending. Folders without a parsable version or without the expected exe
# are skipped.
function Get-InstalledBinaryVersions {
    param(
        [Parameter(Mandatory = $true)][string]$ParentFolder,
        [Parameter(Mandatory = $true)][string]$ExeName,
        [Parameter(Mandatory = $true)][string]$VersionPattern,
        [string]$ActiveFolder,
        [string]$SourcesFolder = (Join-Path $global:ScriptPath "sources")
    )
    $parentPath = Join-Path $SourcesFolder $ParentFolder
    if (-not (Test-Path -LiteralPath $parentPath)) { return @() }
    $results = @()
    Get-ChildItem -LiteralPath $parentPath -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        if (-not (Test-Path -LiteralPath (Join-Path $_.FullName $ExeName))) { return }
        if ($_.Name -notmatch $VersionPattern) { return }
        $relFolder = Join-Path $ParentFolder $_.Name
        $isActive = $ActiveFolder -and ((Split-Path -Path $ActiveFolder -Leaf) -eq $_.Name)
        $results += [PSCustomObject]@{ Version = $Matches[1]; RelativeFolder = $relFolder; IsActive = [bool]$isActive }
    }
    return @($results | Sort-Object -Property { [version]$_.Version } -Descending)
}

# Enumerates all installed mediamtx version folders under "<SourcesFolder>\MediaMTX\".
# Thin wrapper over Get-InstalledBinaryVersions - see that function for details.
function Get-MediaMtxInstalledVersions {
    param([string]$SourcesFolder = (Join-Path $global:ScriptPath "sources"))
    return Get-InstalledBinaryVersions -ParentFolder "MediaMTX" -ExeName "mediamtx.exe" `
        -VersionPattern 'v(\d+(?:\.\d+){1,2})' -ActiveFolder $global:mediamtxFolder -SourcesFolder $SourcesFolder
}

# Reads templates\config\config.json and sets one or more dotted-path values (e.g.
# @{ 'mediamtx.folder' = 'MediaMTX\mediamtx_v1.21.0_windows_amd64' }), writing back via
# Write-FileWithoutBom. Used to keep the fresh-install template pointed at the latest bundled
# binary version whenever a real update (not a rollback) is applied - see Set-BinaryFolderConfig.
# Missing intermediate objects along a dotted path are created. Throws on read/parse/write
# failure - callers should catch and log, since template sync is a nice-to-have and should never
# fail the underlying config.json write it accompanies.
function Set-ConfigTemplateFields {
    param([Parameter(Mandatory = $true)][hashtable]$Fields)
    $tplFile = Join-Path $global:ScriptPath "templates\config\config.json"
    $raw = Get-Content -LiteralPath $tplFile -Raw -Encoding UTF8
    $tpl = $raw | ConvertFrom-Json
    foreach ($path in $Fields.Keys) {
        $parts = $path -split '\.'
        $node = $tpl
        for ($i = 0; $i -lt $parts.Count - 1; $i++) {
            if (-not $node.($parts[$i])) {
                $node | Add-Member -NotePropertyName $parts[$i] -NotePropertyValue ([PSCustomObject]@{}) -Force
            }
            $node = $node.($parts[$i])
        }
        $leaf = $parts[-1]
        if ($node.PSObject.Properties.Name -contains $leaf) {
            $node.$leaf = $Fields[$path]
        } else {
            $node | Add-Member -NotePropertyName $leaf -NotePropertyValue $Fields[$path] -Force
        }
    }
    ($tpl | ConvertTo-Json -Depth 20) | Write-FileWithoutBom -Path $tplFile
}

# Persists $RelativeFolder to every dotted config path in -ConfigPaths (e.g.
# @('mediamtx.folder'), or @('scrcpy.folder','ADB.folder') for scrcpy's bundled adb.exe) inside
# config.json, and re-runs Get-Config so the corresponding $global: binary path variables pick
# up the new binary immediately - same refresh pattern used by /api/config/save. Shared body for
# Set-MediaMtxFolderConfig, Set-ScrcpyAdbFolderConfig and Set-FfmpegFolderConfig.
# When -UpdateTemplate is passed, also mirrors the same paths into
# templates\config\config.json via Set-ConfigTemplateFields (used for real GitHub updates, so
# fresh installs default to the latest known-good version) - failures there are logged as
# WARNING and do not fail the call, since the live config.json write already succeeded.
# -UpdateTemplate is intentionally omitted for version-switch/rollback callers: rolling back to
# an older already-installed version is a per-instance choice, not a new baseline.
function Set-BinaryFolderConfig {
    param(
        [Parameter(Mandatory = $true)][string[]]$ConfigPaths,
        [Parameter(Mandatory = $true)][string]$RelativeFolder,
        [switch]$UpdateTemplate
    )
    $cfgFile = Join-Path $global:ScriptPath "config\config.json"
    $raw = Get-Content -LiteralPath $cfgFile -Raw -Encoding UTF8
    $cfg = $raw | ConvertFrom-Json
    foreach ($path in $ConfigPaths) {
        $parts = $path -split '\.'
        $node = $cfg
        for ($i = 0; $i -lt $parts.Count - 1; $i++) {
            if (-not $node.($parts[$i])) {
                $node | Add-Member -NotePropertyName $parts[$i] -NotePropertyValue ([PSCustomObject]@{}) -Force
            }
            $node = $node.($parts[$i])
        }
        $leaf = $parts[-1]
        if ($node.PSObject.Properties.Name -contains $leaf) {
            $node.$leaf = $RelativeFolder
        } else {
            $node | Add-Member -NotePropertyName $leaf -NotePropertyValue $RelativeFolder -Force
        }
    }
    ($cfg | ConvertTo-Json -Depth 20) | Write-FileWithoutBom -Path $cfgFile
    $null = Get-Config -ConfigFilePath $cfgFile

    if ($UpdateTemplate) {
        try {
            $fields = @{}
            foreach ($path in $ConfigPaths) { $fields[$path] = $RelativeFolder }
            Set-ConfigTemplateFields -Fields $fields
        } catch {
            Write-Log ("Set-BinaryFolderConfig: failed to sync templates\config\config.json: " + $_.Exception.Message) -Level WARNING
        }
    }
}

# Persists a new mediamtx.folder value to config.json (path relative to
# sources\, e.g. "MediaMTX\mediamtx_v1.18.0_windows_amd64") and re-runs
# Get-Config so $global:mediamtxFolder / $global:mediamtxFilePath pick up the
# new binary immediately - same refresh pattern used by /api/config/save.
# Thin wrapper over Set-BinaryFolderConfig - see that function for -UpdateTemplate details.
function Set-MediaMtxFolderConfig {
    param([Parameter(Mandatory = $true)][string]$RelativeFolder, [switch]$UpdateTemplate)
    Set-BinaryFolderConfig -ConfigPaths @('mediamtx.folder') -RelativeFolder $RelativeFolder -UpdateTemplate:$UpdateTemplate
}

# Returns the installed scrcpy version string (e.g. "3.3.4"), or $null if
# unparsable. Like mediamtx, scrcpy is shipped one folder per version, so the
# version is read from the folder name (e.g. "scrcpy-win64-v3.3.4_patchedNoFlickering")
# rather than by invoking the exe.
function Get-ScrcpyVersion {
    param([string]$ScrcpyFolder = $global:scrcpyFolder)
    if (-not $ScrcpyFolder) { return $null }
    $leaf = Split-Path -Path $ScrcpyFolder -Leaf
    if ($leaf -match 'v(\d+(?:\.\d+){1,2})') { return $Matches[1] }
    return $null
}

# Queries the official Genymobile/scrcpy GitHub releases API for the latest
# available Windows 64-bit build. Returns @{Version; DownloadUrl; AssetName}
# or $null on network/parse failure. Only called on operator-triggered
# "check for update". NOTE: this is the STOCK scrcpy build, not the
# "patchedNoFlickering" variant this project currently ships - there is no
# public source for that patch, so updating replaces it with the official build.
function Get-LatestScrcpyVersion {
    try {
        $apiUrl = "https://api.github.com/repos/Genymobile/scrcpy/releases/latest"
        $headers = @{ 'User-Agent' = 'VR-Headset-Manager' }
        $release = Invoke-RestMethod -Uri $apiUrl -Headers $headers -TimeoutSec 15
        $asset = $release.assets | Where-Object { $_.name -like "*win64*.zip" } | Select-Object -First 1
        if (-not $asset) { return $null }
        $version = $release.tag_name -replace '^v', ''
        if ($asset.name -match 'v?(\d+(?:\.\d+){1,2})') { $version = $Matches[1] }
        return @{ Version = $version; DownloadUrl = $asset.browser_download_url; AssetName = $asset.name }
    } catch {
        return $null
    }
}

# Downloads and installs the latest scrcpy build (which also bundles adb.exe)
# to a NEW folder "<SourcesFolder>\scrcpy\scrcpy-win64-v<version>\". As part of
# consolidating all scrcpy installs under one root, the CURRENTLY active
# folder (config.scrcpy.folder, wherever it currently lives - e.g. a legacy
# top-level "sources\scrcpy-win64-v3.3.4_patchedNoFlickering\") is moved
# (not copied - content preserved, nothing deleted) into "<SourcesFolder>\scrcpy\"
# too, if it is not already there. Migration is best-effort and does not fail
# the update if it errors, since the newly downloaded version is already usable.
# Returns @{Success; Version; Folder (relative to SourcesFolder); Error}.
function Update-ScrcpyBinary {
    param([string]$SourcesFolder = (Join-Path $global:ScriptPath "sources"))
    try {
        $latest = Get-LatestScrcpyVersion
        if (-not $latest) {
            return @{ Success = $false; Version = $null; Folder = $null; Error = "Could not query latest scrcpy release from GitHub." }
        }
        $parentFolder = Join-Path $SourcesFolder "scrcpy"
        $destFolder   = Join-Path $parentFolder ("scrcpy-win64-v{0}" -f $latest.Version)
        $relFolder    = Join-Path "scrcpy" (Split-Path -Path $destFolder -Leaf)

        if (-not (Test-Path -LiteralPath (Join-Path $destFolder "scrcpy.exe"))) {
            $zipPath = Join-Path $env:TEMP "vrm_scrcpy_download.zip"
            $bitsOk = $false
            try {
                $bits = Get-Service -Name BITS -ErrorAction Stop
                if ($bits.Status -eq 'Running' -or $bits.StartType -ne 'Disabled') {
                    Start-BitsTransfer -Source $latest.DownloadUrl -Destination $zipPath -Description "Downloading scrcpy..." -ErrorAction Stop
                    $bitsOk = $true
                }
            } catch { }
            if (-not $bitsOk) {
                $wc = [System.Net.WebClient]::new()
                $wc.Headers.Add('User-Agent', 'VR-Headset-Manager')
                $wc.DownloadFile($latest.DownloadUrl, $zipPath)
                $wc.Dispose()
            }

            if (-not (Test-Path -LiteralPath $parentFolder)) {
                New-Item -ItemType Directory -Path $parentFolder | Out-Null
            }
            if (Test-Path -LiteralPath $destFolder) {
                Remove-Item -LiteralPath $destFolder -Recurse -Force -ErrorAction SilentlyContinue
            }
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $destFolder)
            Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue

            if (-not (Test-Path -LiteralPath (Join-Path $destFolder "scrcpy.exe"))) {
                return @{ Success = $false; Version = $null; Folder = $null; Error = "Downloaded archive did not contain scrcpy.exe." }
            }
        }

        # Consolidate: move the currently-active scrcpy folder into sources\scrcpy\
        # if it lives elsewhere (e.g. a legacy top-level install). Best-effort.
        try {
            $currentFolder = $global:scrcpyFolder
            if ($currentFolder -and (Test-Path -LiteralPath $currentFolder -PathType Container)) {
                $currentParent = Split-Path -Path $currentFolder -Parent
                if ($currentParent -ne $parentFolder) {
                    $leaf = Split-Path -Path $currentFolder -Leaf
                    $migratedPath = Join-Path $parentFolder $leaf
                    if (-not (Test-Path -LiteralPath $migratedPath)) {
                        if (-not (Test-Path -LiteralPath $parentFolder)) {
                            New-Item -ItemType Directory -Path $parentFolder | Out-Null
                        }
                        Move-Item -LiteralPath $currentFolder -Destination $migratedPath -Force
                    }
                }
            }
        } catch { }

        return @{ Success = $true; Version = $latest.Version; Folder = $relFolder; Error = $null }
    } catch {
        return @{ Success = $false; Version = $null; Folder = $null; Error = $_.Exception.Message }
    }
}

# Enumerates all installed scrcpy version folders under "<SourcesFolder>\scrcpy\".
# Thin wrapper over Get-InstalledBinaryVersions - see that function for details.
function Get-ScrcpyInstalledVersions {
    param([string]$SourcesFolder = (Join-Path $global:ScriptPath "sources"))
    return Get-InstalledBinaryVersions -ParentFolder "scrcpy" -ExeName "scrcpy.exe" `
        -VersionPattern 'v(\d+(?:\.\d+){1,2})' -ActiveFolder $global:scrcpyFolder -SourcesFolder $SourcesFolder
}

# Persists a new folder value to BOTH config.scrcpy.folder and config.ADB.folder
# (the scrcpy release bundles adb.exe, so they always point at the same folder -
# see templates\config\config.json where both keys already share one value) and
# re-runs Get-Config so $global:scrcpyFolder/$global:scrcpyFilePath and
# $global:adbFolder/$global:adbPath all pick up the new binaries immediately.
# Thin wrapper over Set-BinaryFolderConfig - see that function for -UpdateTemplate details.
function Set-ScrcpyAdbFolderConfig {
    param([Parameter(Mandatory = $true)][string]$RelativeFolder, [switch]$UpdateTemplate)
    Set-BinaryFolderConfig -ConfigPaths @('scrcpy.folder', 'ADB.folder') -RelativeFolder $RelativeFolder -UpdateTemplate:$UpdateTemplate
}

# Enumerates all installed ffmpeg version folders under "<SourcesFolder>\ffmpeg\".
# Thin wrapper over Get-InstalledBinaryVersions - see that function for details.
function Get-FfmpegInstalledVersions {
    param([string]$SourcesFolder = (Join-Path $global:ScriptPath "sources"))
    return Get-InstalledBinaryVersions -ParentFolder "ffmpeg" -ExeName "ffmpeg.exe" `
        -VersionPattern 'ffmpeg-(\d+(?:\.\d+){1,2})' -ActiveFolder $global:ffmpegFolder -SourcesFolder $SourcesFolder
}

# Persists a new ffmpeg.folder value to config.json (path relative to sources\, e.g.
# "ffmpeg\ffmpeg-9.0.1") and re-runs Get-Config so $global:ffmpegFilePath picks up the new
# binary immediately. Thin wrapper over Set-BinaryFolderConfig - see that function for
# -UpdateTemplate details.
function Set-FfmpegFolderConfig {
    param([Parameter(Mandatory = $true)][string]$RelativeFolder, [switch]$UpdateTemplate)
    Set-BinaryFolderConfig -ConfigPaths @('ffmpeg.folder') -RelativeFolder $RelativeFolder -UpdateTemplate:$UpdateTemplate
}
