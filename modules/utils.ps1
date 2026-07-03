
###############################################################
# utils.ps1 - cross-cutting helpers used by multiple modules.
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


# Returns $true if the internet is reachable, $false only if BOTH probes fail.
# Probe 1: ICMP ping to 8.8.8.8 (Google public DNS - no DNS lookup needed).
# Probe 2: DNS resolution of 'dns.google' (proves DNS is working end-to-end).
# Internet is considered UP if at least one probe succeeds.
function Get-ComputerWifiSSID {
    $adapter = Get-NetAdapter | Where-Object {
        ($_.PhysicalMediaType -eq 'Native 802.11' -or $_.PhysicalMediaType -eq 'Wireless LAN') -and
        $_.Status -eq 'Up'
    } | Select-Object -First 1
    if (-not $adapter) { return $null }
    $netProfile = Get-NetConnectionProfile -InterfaceAlias $adapter.InterfaceAlias -ErrorAction SilentlyContinue
    if ($netProfile) { return $netProfile.Name }
    return $null
}

function Get-ComputerWifiPassword {
    param([string]$SSID)
    if ([string]::IsNullOrWhiteSpace($SSID)) { return $null }
    try {
        $tmpDir = $env:TEMP
        & netsh wlan export profile name=$SSID folder=$tmpDir key=clear 2>$null | Out-Null
        $xmlFile = Get-ChildItem -LiteralPath $tmpDir -Filter "Wi-Fi-$SSID.xml" -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $xmlFile) { return $null }
        [xml]$xml = Get-Content -LiteralPath $xmlFile.FullName -Encoding UTF8
        Remove-Item -LiteralPath $xmlFile.FullName -Force -ErrorAction SilentlyContinue
        return $xml.WLANProfile.MSM.security.sharedKey.keyMaterial
    } catch { return $null }
}

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
# Uses Win32_Processor; averages LoadPercentage across all sockets.
# Returns $null on failure.
function Get-CpuInfo {
    $procs = $null
    try {
        $procs = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop)
        if ($procs.Count -eq 0) { return $null }
        $load = [int][Math]::Round(($procs | Measure-Object -Property LoadPercentage -Average).Average)
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
# Per-GPU: model, dedicated VRAM (GB), 3D/encode/decode utilization (%),
# VRAM used/free (GB and %). Utilization fields are $null when perf counters
# are unavailable (old Windows, Hyper-V, missing provider).
# Returns @() if no GPU is found; never returns $null.
function Get-GpuInfo {
    # Counter instance names embed the adapter LUID:
    #   GPU Engine:         pid_NNNN_luid_0xHH_0xLL_phys_0_eng_N_engtype_3D
    #   GPU Adapter Memory: luid_0xHH_0xLL_phys_0
    # phys_N is always 0 per-adapter (not a global GPU index), so we key maps by LUID string.
    function _SumCounterByLuid {
        param([string]$CounterPath)
        $map = @{}
        try {
            $samples = (Get-Counter -Counter $CounterPath -ErrorAction Stop).CounterSamples
            foreach ($s in $samples) {
                if ($s.InstanceName -match 'luid_(0x[0-9a-f]+_0x[0-9a-f]+)') {
                    $luid = $Matches[1]
                    if (-not $map.ContainsKey($luid)) { $map[$luid] = 0.0 }
                    $map[$luid] += $s.CookedValue
                }
            }
        } catch { }
        return $map
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
        return @()
    }
    if ($controllers.Count -eq 0) { return @() }

    # Collect perf counter maps keyed by LUID string
    $map3D     = _SumCounterByLuid '\GPU Engine(*engtype_3D*)\Utilization Percentage'
    $mapEnc    = _SumCounterByLuid '\GPU Engine(*engtype_VideoEncode*)\Utilization Percentage'
    $mapDec    = _SumCounterByLuid '\GPU Engine(*engtype_VideoDecode*)\Utilization Percentage'
    $mapMemUse = @{}
    try {
        $memUseSamples = (Get-Counter -Counter '\GPU Adapter Memory(*)\Dedicated Usage' -ErrorAction Stop).CounterSamples
        foreach ($s in $memUseSamples) {
            if ($s.InstanceName -match 'luid_(0x[0-9a-f]+_0x[0-9a-f]+)') { $mapMemUse[$Matches[1]] = $s.CookedValue }
        }
    } catch { }

    $results = @()
    for ($i = 0; $i -lt $controllers.Count; $i++) {
        $ctrl      = $controllers[$i]
        $gpuName   = ($ctrl.Name -replace '\s+', ' ').Trim()
        # Prefer the registry 64-bit QWORD; fall back to the capped 32-bit AdapterRAM
        $vramBytes = if ($regVramMap.ContainsKey($gpuName)) { $regVramMap[$gpuName] } else { [double]$ctrl.AdapterRAM }
        $vramGB    = [Math]::Round($vramBytes / 1GB, 2)

        $load3D = $null; $loadEnc = $null; $loadDec = $null
        $vramUsedGB = $null; $vramFreeGB = $null; $vramUsedPct = $null; $vramFreePct = $null

        # Resolve this GPU's LUID via DXGI, then look up its counter data
        $luid = $gpuLuidMap[$gpuName]
        if ($luid) {
            $load3D  = [int][Math]::Min(100, [Math]::Round($map3D[$luid]))
            $loadEnc = [int][Math]::Min(100, [Math]::Round($mapEnc[$luid]))
            $loadDec = [int][Math]::Min(100, [Math]::Round($mapDec[$luid]))

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

        $results += [PSCustomObject]@{
            Index           = $i
            Model           = $gpuName
            DedicatedVramGB = $vramGB
            Load3DPercent   = $load3D
            EncodePercent   = $loadEnc
            DecodePercent   = $loadDec
            VramUsedGB      = $vramUsedGB
            VramFreeGB      = $vramFreeGB
            VramUsedPercent = $vramUsedPct
            VramFreePercent = $vramFreePct
        }
    }
    # Release CIM handles on Win32_VideoController instances
    foreach ($c in $controllers) { if ($c) { $c.Dispose() } }
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

    # Drive type detection via Storage module (Win8+)
    $driveType = "Unknown"
    $speedLabel = $null
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
    } catch {
        # Storage module may be unavailable - silently fall back to Unknown
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
    $gpu       = Get-GpuInfo
    $workload  = Get-AppWorkload -ProcessNames @("scrcpy", "ffmpeg", "powershell")
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

# Probe a single ffmpeg encoder with a 1-frame smoke test.
# Returns $true when the encoder accepted the test input (i.e. the GPU/driver
# stack is functional), $false otherwise. Stdout/stderr are discarded.
function Test-FfmpegEncoder {
    param(
        [Parameter(Mandatory)] [string] $Encoder,
        [string[]] $ExtraArgs = @()
    )
    if (-not (Test-Path -LiteralPath $global:ffmpegFilePath)) { return $false }
    $ffArgs = @('-hide_banner','-loglevel','error','-f','lavfi','-i','color=c=black:s=320x240:r=10:d=0.1')
    $ffArgs += $ExtraArgs
    $ffArgs += @('-c:v',$Encoder,'-frames:v','1','-f','null','-')
    try {
        $null = & $global:ffmpegFilePath @ffArgs 2>&1
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
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
    param([int]$GpuIndex = 0)
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

    $nvenc = @{ Name='h264_nvenc'; Vendor='NVIDIA'; ExtraArgs=$nvencArgs }
    $qsv   = @{ Name='h264_qsv';   Vendor='Intel';  ExtraArgs=$qsvArgs }
    $amf   = @{ Name='h264_amf';   Vendor='AMD';    ExtraArgs=@() }
    $mf    = @{ Name='h264_mf';    Vendor='Any';    ExtraArgs=@() }
    $x264  = @{ Name='libx264';    Vendor='CPU';    ExtraArgs=@() }

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
    if (-not $Force -and $null -ne $global:GpuEncoder) { return $global:GpuEncoder }

    # GPU acceleration disabled -> always libx264
    if (-not $global:GPU_Acceleration) {
        $global:GpuEncoder = @{ Name='libx264'; Vendor='CPU'; ExtraArgs=@() }
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

    $candidates = Get-GpuEncoderCandidates -GpuIndex $global:GPU_Index
    foreach ($c in $candidates) {
        if ($c.Name -eq 'libx264') {
            # No probe needed - libx264 is always present in the bundled ffmpeg.
            $global:GpuEncoder = $c
            try { Write-Log ("GpuEncoder resolved: {0} (vendor {1}) - fallback" -f $c.Name, $c.Vendor) -Level INFO } catch {}
            return $c
        }
        if ($available -notcontains $c.Name) { continue }
        if (Test-FfmpegEncoder -Encoder $c.Name -ExtraArgs $c.ExtraArgs) {
            $global:GpuEncoder = $c
            try { Write-Log ("GpuEncoder resolved: {0} (vendor {1}) GpuIndex={2}" -f $c.Name, $c.Vendor, $global:GPU_Index) -Level SUCCESS } catch {}
            return $c
        } else {
            try { Write-Log ("GpuEncoder probe failed for {0}, trying next" -f $c.Name) -Level DEBUG } catch {}
        }
    }
    # Should never reach here (libx264 is in the list and returned unconditionally above).
    $global:GpuEncoder = @{ Name='libx264'; Vendor='CPU'; ExtraArgs=@() }
    return $global:GpuEncoder
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
