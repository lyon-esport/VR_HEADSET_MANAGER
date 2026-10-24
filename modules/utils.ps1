
###############################################################
# utils.ps1 - core cross-cutting helpers used by multiple modules.
# Domain helpers live in their own files since S9-1: wifi_store.ps1,
# hardware_monitoring.ps1, port_tools.ps1, gpu_encoding.ps1, binary_updates.ps1.
# A context that loads modules BY NAME (runspaces, welcome.ps1, test scripts)
# must load the file holding the functions it calls, not only this one.
# Auto-loaded by scripts_init.ps1.
# ASCII only (no em dashes, no curly quotes, no accents).
###############################################################


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
# Resolves a translation key through $global:msg, following a dotted path so
# nested groups work: 'Database.AssemblyNotFound' reads $msg.Database.AssemblyNotFound.
# Nesting is not cosmetic - Import-PowerShellDataFile caps a single hashtable
# literal at 500 pairs and both locales sit near that limit, so new features
# group their strings under one top-level key (CLAUDE.md, translations).
# Returns $Fallback (default: the key itself) when the key does not resolve, so
# a missing translation degrades to something readable instead of an empty
# string that would make Write-Log throw.
# Example: Get-MessageString -Key 'Database.AssemblyNotFound'
function Get-MessageString {
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [string]$Fallback = ''
    )
    if (-not $Fallback) { $Fallback = $Key }
    if (-not $global:msg) { return $Fallback }

    $node = $global:msg
    foreach ($part in $Key.Split('.')) {
        if ($null -eq $node) { return $Fallback }
        if ($node -is [hashtable]) {
            if (-not $node.ContainsKey($part)) { return $Fallback }
            $node = $node[$part]
        } else {
            $prop = $node.PSObject.Properties[$part]
            if (-not $prop) { return $Fallback }
            $node = $prop.Value
        }
    }
    if ($null -eq $node -or "$node" -eq '') { return $Fallback }
    return [string]$node
}


function Test-RequiredBinaries {
    $candidates = @(
        [PSCustomObject]@{ ExeName = 'adb.exe';    Path = $global:adbPath;        MessageKey = 'ADBExecutableNotFound' }
        [PSCustomObject]@{ ExeName = 'scrcpy.exe'; Path = $global:scrcpyFilePath; MessageKey = 'Scrcpy.NotFound' }
        # The database engine. Both files are mandatory and must stay together:
        # System.Data.SQLite.dll is the managed assembly, x64\SQLite.Interop.dll
        # the native engine it P/Invokes. Missing either one means no persistence
        # at all, so this is worth failing loudly at startup rather than at the
        # first query.
        [PSCustomObject]@{ ExeName = 'System.Data.SQLite.dll'; Path = $global:databaseAssemblyPath; MessageKey = 'Database.AssemblyNotFound' }
        [PSCustomObject]@{ ExeName = 'SQLite.Interop.dll';     Path = $global:databaseInteropPath;  MessageKey = 'Database.InteropNotFound' }
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


# Repairs a string that was UTF-8 text mis-decoded as Windows-1252 (mojibake), e.g. a "Videos" folder name that arrives as "Vid" + two garbage characters + "os"
# instead of "Videos". Re-encodes as Windows-1252 bytes, then strictly re-decodes those bytes as
# UTF-8; if that succeeds and differs from the input, the fix is accepted and the loop repeats
# (capped at 3 passes) so a double mis-decode (text decoded twice) also unwinds in one call. A string that
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


# Get-HeadsetDataPath was removed here. It built data\<safe>_<suffix>.csv for the
# per-headset app caches. Those are tables now (ADR-0017), and the helper had no
# caller even before that.


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

# Path of a background-job progress/cancel file under <ScriptPath>\data\jobs\ (S6-6).
# Creates the folder on demand. Fixed names in %TEMP% were shared by two installs on one PC.
# Example: Get-JobFilePath -Name 'vrm_benchmark.json'
function Get-JobFilePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )
    $dir = Join-Path -Path $global:ScriptPath -ChildPath 'data\jobs'
    if (-not (Test-Path -LiteralPath $dir)) {
        try { New-Item -ItemType Directory -Path $dir -Force | Out-Null } catch { }
    }
    return (Join-Path -Path $dir -ChildPath $Name)
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
    # Another process (web server, VRMonitor, the registry save regenerating pages) can hold
    # the same file for a few milliseconds - seen when a new headset's [monitoring].html was
    # created by two writers at once. A sharing violation is retried briefly; any other
    # error, or the last attempt, is thrown as before.
    for ($attempt = 1; $attempt -le 4; $attempt++) {
        try {
            [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
            return
        } catch [System.IO.IOException] {
            if ($attempt -eq 4 -or $_.Exception -is [System.IO.FileNotFoundException] -or $_.Exception -is [System.IO.DirectoryNotFoundException]) { throw }
            Start-Sleep -Milliseconds (50 * $attempt)
        }
    }
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


# Prompt for a port number on the console, validate it is within -Min..65535
# (default Min 1024; the web server prompts pass 1 so port 80 can be chosen),
# loop until valid. Empty input returns -Default.
# Moved from welcome.ps1 so it can be reused from any module without circular deps.
function Read-ValidPort {
    param([string]$Label, [int]$Default, [int]$Min = 1024)
    while ($true) {
        Write-Host "  $Label [default: $Default]: " -ForegroundColor White -NoNewline
        $raw = Read-Host
        if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
        $val = 0
        if ([int]::TryParse($raw, [ref]$val) -and $val -ge $Min -and $val -le 65535) {
            return $val
        }
        Write-Host "  Invalid. Enter a number between $Min and 65535." -ForegroundColor Red
    }
}

# -------------------------------------------------------------------
# Cross-process lock (data\vqa.lock)
# The web server process and the VRMonitor background job can both call
# VQA apply/restore, and the web server's /api/config/save handler also
# uses this lock around its own mediamtx/scrcpy restart sequence. Lives
# here (not in video_quality_automation.ps1) so it is always loaded even
# when VideoQualityAutomation.enabled is false and that module is skipped.
# Always release via Exit-VqaLock in a finally block.
#
# Re-entrant per runspace: a caller that already holds the lock (e.g. the
# web server's binary update around Set-BinaryFolderConfig, or a VQA apply)
# and then reaches Write-ConfigJson gets the SAME stream back with a depth
# count, instead of waiting on its own FileShare.None handle until timeout.
# Exit-VqaLock only closes the file when the outermost holder releases it.
# State is per runspace ($global: is per runspace), so two runspaces of one
# process still exclude each other through the file itself.
# -------------------------------------------------------------------

function Enter-VqaLock {
    param([int]$TimeoutMs = 3000)
    $held = $global:VqaLockHeld
    if ($held -and $held.Stream) {
        $held.Depth++
        return $held.Stream
    }
    $lockPath = Join-Path $global:ScriptPath 'data\vqa.lock'
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        try {
            $stream = [System.IO.FileStream]::new(
                $lockPath,
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::None)
            $global:VqaLockHeld = @{ Stream = $stream; Depth = 1 }
            return $stream
        } catch [System.IO.IOException] {
            Start-Sleep -Milliseconds 100
        }
    }
    return $null
}

function Exit-VqaLock {
    param($Stream)
    if (-not $Stream) { return }
    $held = $global:VqaLockHeld
    if ($held -and [object]::ReferenceEquals($held.Stream, $Stream)) {
        $held.Depth--
        if ($held.Depth -gt 0) { return }
        $global:VqaLockHeld = $null
    }
    try { $Stream.Dispose() } catch { }
}

# -------------------------------------------------------------------
# Write-ConfigJson: THE writer for config\config.json (and, with -Path, its
# template). Every config write in the app goes through it.
#   - serialises -Object with ConvertTo-Json -Depth (keep each caller's depth),
#   - writes <path>.<id>.tmp as UTF-8 without BOM, then swaps it in with
#     File.Replace, so a reader (VRMonitor every slow tick, runspaces, the web
#     server) sees either the old file or the new one, never an empty or
#     truncated one; Move when the target does not exist yet,
#   - holds Enter-VqaLock (re-entrant) for the write. A writer doing a
#     read-modify-write takes Enter-VqaLock itself around the read, so the
#     whole cycle is serialised against the other processes.
# When the lock cannot be taken within -LockTimeoutMs the write still happens
# (atomically) and a WARNING is logged: refusing would lose an operator's
# change while a long restart holds the lock.
# Throws when the write itself fails (same contract as Write-FileWithoutBom).
# Example: Write-ConfigJson -Object $cfg -Depth 20
# -------------------------------------------------------------------
function Write-ConfigJson {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [string]$Path,
        [int]$Depth = 20,
        [int]$LockTimeoutMs = 5000
    )
    if ([string]::IsNullOrWhiteSpace($Path)) {
        $Path = Join-Path -Path $global:ScriptPath -ChildPath 'config\config.json'
    }
    if ($Object -is [string]) {
        $json = $Object
    } else {
        $json = $Object | ConvertTo-Json -Depth $Depth
    }
    if ([string]::IsNullOrWhiteSpace($json)) { throw "Write-ConfigJson: refusing to write an empty document to '$Path'" }

    $lock = Enter-VqaLock -TimeoutMs $LockTimeoutMs
    if (-not $lock) {
        try { Write-Log ("Write-ConfigJson: lock not acquired within {0} ms, writing '{1}' without it" -f $LockTimeoutMs, $Path) -Level WARNING } catch { }
    }
    try {
        # Unique temp name: a writer that went ahead without the lock must not share it.
        $tmp = '{0}.{1}.tmp' -f $Path, ([guid]::NewGuid().ToString('N').Substring(0, 8))
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText($tmp, $json, $utf8NoBom)
        for ($attempt = 1; $attempt -le 10; $attempt++) {
            try {
                if ([System.IO.File]::Exists($Path)) {
                    # [NullString]::Value, not $null: PowerShell passes $null to a [string]
                    # parameter as '', which File.Replace rejects as an invalid backup path.
                    [System.IO.File]::Replace($tmp, $Path, [NullString]::Value)
                } else {
                    [System.IO.File]::Move($tmp, $Path)
                }
                return
            } catch [System.IO.IOException] {
                # A reader holding the file open without delete sharing blocks the swap
                # for a few milliseconds; retry, then give up with the original error.
                if ($attempt -eq 10) { throw }
                Start-Sleep -Milliseconds (20 * $attempt)
            } catch [System.UnauthorizedAccessException] {
                if ($attempt -eq 10) { throw }
                Start-Sleep -Milliseconds (20 * $attempt)
            }
        }
    } finally {
        if ($tmp -and [System.IO.File]::Exists($tmp)) {
            try { [System.IO.File]::Delete($tmp) } catch { }
        }
        if ($lock) { Exit-VqaLock -Stream $lock }
    }
}

#################
# CLASSIC WIFI ADB PORT (ADR-0034)
# Lives here because every process and runspace that talks to adb loads utils.ps1,
# including the network scanner and the poll runspaces.
#################
function Get-ClassicAdbPort {
    <#
    .SYNOPSIS
    The port of the classic WiFi ADB mode ("adb tcpip <port>"): config ADB.adbPort_default.

    .DESCRIPTION
    The ONE place a missing or out-of-range value falls back to adb's own default (5555), so
    no caller carries a literal port of its own (S10-3). Get-Config already clamps the value;
    this guard covers a runspace or job that never ran it. Never throws.

    .EXAMPLE
    $port = Get-ClassicAdbPort    # 5555 with the default config
    #>
    $p = 0
    try { if ($null -ne $global:adbPort_default) { $p = [int]$global:adbPort_default } } catch { $p = 0 }
    if ($p -lt 1 -or $p -gt 65535) { $p = 5555 }
    return $p
}

#################
# UNKNOWN / PLACEHOLDER IP ADDRESSES
# Lives here rather than in headsets_manager.ps1 because the per-headset VRMonitor
# runspaces import utils.ps1 but not headsets_manager.ps1, and the reachability stage
# must be able to skip a row whose address is unknown.
#################
# Test-UnknownIp -IPAddress "127.0.0.2"   -> $true
function Test-UnknownIp {
    <#
    .SYNOPSIS
    Returns $true when an IPAddress field does not point at a real, reachable headset.
    .DESCRIPTION
    A headset row whose address was taken over by another headset is not deleted - its
    IPAddress is released to a loopback placeholder (127.0.0.x, see Get-NextUnknownIp).
    Loopback stays a valid IPv4 so nothing that parses or joins on IP breaks, and it is
    unique per row so the IP-duplicate guards keep working, but it never designates a
    headset. Every poll/scrcpy/runspace path must skip such a row instead of generating
    network traffic for it.

    Empty / whitespace is also reported as unknown so legacy blank rows are handled
    identically without a separate check at every call site.
    .EXAMPLE
    if (Test-UnknownIp $headset.IPAddress) { continue }
    #>
    param (
        [string]$IPAddress
    )

    if ([string]::IsNullOrWhiteSpace($IPAddress)) { return $true }
    return ($IPAddress.Trim() -match '^127\.')
} # OK

# Test-ScrcpyCommandLineTarget -CommandLine $cl -IPAddress '192.168.1.24'   -> $false for "-s 192.168.1.244:5555"
function Test-ScrcpyCommandLineTarget {
    <#
    .SYNOPSIS
    $true when a scrcpy command line targets this headset: EXACT -s ip[:port], -s serial or
    --window-title value.
    .DESCRIPTION
    The single matching rule behind Get-ScrcpyProcess (scrcpy_launcher.ps1) and the stage 1
    scan of the poll runspaces (which load utils.ps1 but not scrcpy_launcher.ps1). It used to
    be a substring search, so 192.168.1.24 matched "-s 192.168.1.244:5555" and Q3_RED matched
    "--window-title=Q3_RED2" (or any record path holding the name). Each value must now be the
    whole argument: IP with any port, serial, title, optionally double-quoted.
    Case-insensitive; blank keys (and a serial of '-') are ignored. Never throws.
    .EXAMPLE
    Test-ScrcpyCommandLineTarget -CommandLine $cmdLine -IPAddress $h.IPAddress -Serial $h.SerialNumber -DisplayName 'Q3_RED'
    #>
    param(
        [string]$CommandLine,
        [string]$IPAddress   = '',
        [string]$Serial      = '',
        [string]$DisplayName = ''
    )
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $false }
    try {
        $end = '(?=\x22|\s|$)'
        $ip  = ([string]$IPAddress).Trim()
        if ($ip -and $CommandLine -match ('(?:^|\s)-s\s+\x22?' + [regex]::Escape($ip) + '(?::\d+)?' + $end)) { return $true }
        $sn  = ([string]$Serial).Trim()
        if ($sn -and $sn -ne '-' -and $CommandLine -match ('(?:^|\s)-s\s+\x22?' + [regex]::Escape($sn) + $end)) { return $true }
        $dn  = ([string]$DisplayName).Trim()
        if ($dn -and $CommandLine -match ('(?:^|\s)--window-title(?:=|\s+)\x22?' + [regex]::Escape($dn) + $end)) { return $true }
    } catch { }
    return $false
}

# Get-NextUnknownIp -Rows $headsets   -> "127.0.0.2"
function Get-NextUnknownIp {
    <#
    .SYNOPSIS
    Returns the lowest 127.0.0.N placeholder address (N in 2..254) not already used by
    any row in -Rows.
    .DESCRIPTION
    127.0.0.1 is skipped - it is the real loopback and a local ADB server listens there.
    Uniqueness matters because Add-Headset and the web routes reject duplicate IPs, so
    two released rows must not collide.
    .EXAMPLE
    $row.IPAddress = Get-NextUnknownIp -Rows $rows
    #>
    param (
        [array]$Rows = @()
    )

    $used = @{}
    foreach ($row in $Rows) {
        if ($row -and $row.IPAddress) { $used[[string]$row.IPAddress.Trim()] = $true }
    }

    for ($n = 2; $n -le 254; $n++) {
        $candidate = "127.0.0.$n"
        if (-not $used.ContainsKey($candidate)) { return $candidate }
    }

    Write-Log $msg.Discovery.UnknownIpPoolEmpty -Level ERROR
    return "127.0.0.254"
} # OK
