
###############################################################
# utils.ps1 - cross-cutting helpers used by multiple modules.
# Auto-loaded by scripts_init.ps1.
# ASCII only (no em dashes, no curly quotes, no accents).
###############################################################


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
    }
}


# Returns RAM generation (DDR3/DDR4/DDR5...), speed, total/used/free capacity.
# Uses Win32_PhysicalMemory for DIMM metadata and Win32_OperatingSystem for live usage.
# Returns $null on failure.
function Get-RamInfo {
    $ddrMap = @{ 20 = 'DDR'; 21 = 'DDR2'; 24 = 'DDR3'; 26 = 'DDR4'; 34 = 'DDR5' }
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
    try {
        $logicalCores = [int](Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop |
                              Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
        if ($logicalCores -lt 1) { $logicalCores = 1 }
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


function Update-ComputerMonitoring {
    # Skip if file is recent enough and no force-refresh flag file present
    $flagFile = Join-Path -Path $global:ScriptPath -ChildPath "data\computer_monitoring_forcerefresh.flag"
    $forceRefresh = Test-Path -LiteralPath $flagFile
    $needsRefresh = $forceRefresh
    if (-not $needsRefresh) {
        if (-not (Test-Path -LiteralPath $global:computerMonitoringFilePath)) {
            $needsRefresh = $true
        } else {
            $age = (Get-Date) - (Get-Item -LiteralPath $global:computerMonitoringFilePath).LastWriteTime
            if ($age.TotalSeconds -ge $global:ComputerMonitoring_refresh_timer_sec) {
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

    $snapshot = [PSCustomObject]@{
        Timestamp   = [datetime]::Now.ToString("yyyy-MM-ddTHH:mm:ss")
        CPU         = $cpu
        RAM         = $ram
        GPU         = $gpu
        AppWorkload = $workload
        ScrcpyCount = if ($scrcpyRow) { [int]$scrcpyRow.Count } else { 0 }
    }

    $json = $snapshot | ConvertTo-Json -Depth 5
    Write-FileWithoutBom -Path $global:computerMonitoringFilePath -Content $json

    Write-Log $msg.ComputerMonitoringUpdated -Level DEBUG
}
