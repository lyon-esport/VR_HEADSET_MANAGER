###############################################################
# hardware_monitoring.ps1
# Hardware monitoring: CPU / RAM / GPU / process workload / recording
# drive samplers, Update-ComputerMonitoring and the load tiers
# (Get-LoadTier / Get-LoadMultiplier / Get-AdaptiveMonitorInterval).
# Split out of utils.ps1 (S9-1). Loaded by the computer monitoring runspace.
# Auto-loaded by scripts_init.ps1.
# ASCII only (no em dashes, no curly quotes, no accents).
###############################################################

# Drive type cache for Get-RecordingDriveInfo.
# Keyed by drive letter; value: @{DriveType; SpeedGbps}.
# Drive type (NVMe/SSD/HDD) never changes at runtime, so we query StorageWMI once and cache.
$script:DriveTypeCache = @{}


# Returns CPU model, physical/logical core counts, and current load percentage.
# Model/core counts come from Win32_Processor (static metadata). LoadPercent is
# sampled from Win32_PerfFormattedData_PerfOS_Processor (instance "_Total")
# once per second for 5 seconds and averaged - Win32_Processor.LoadPercentage
# is a single stale/noisy WMI sample and is not accurate enough on its own.
# Get-Counter is avoided here because its counter paths are locale-localized
# (e.g. "Processeur" on FR Windows) and fail on non-English systems; the WMI
# class name is not localized.
# -Sampler (New-ComputerMonitorSampler, S3-2): no sleep at all. The model and core counts
# are read once and kept in the sampler; LoadPercent is the GetSystemTimes delta since the
# previous call with the same sampler (the computer monitor runspace takes that baseline
# a few seconds before each sample). Without a previous reading it falls back to ONE CIM
# sample. Same return shape either way.
# Returns $null on failure.
function Get-CpuInfo {
    param([hashtable]$Sampler)

    if ($Sampler) {
        try {
            if (-not $Sampler.Cpu.Static) {
                $sp = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop)
                if ($sp.Count -eq 0) { return $null }
                $Sampler.Cpu.Static = @{
                    Model         = ($sp[0].Name -replace '\s+', ' ').Trim()
                    PhysicalCores = ($sp | Measure-Object -Property NumberOfCores -Sum).Sum
                    LogicalCores  = ($sp | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
                }
                foreach ($p in $sp) { if ($p) { $p.Dispose() } }
            }
            $nowTimes = $null
            if (Initialize-CpuTimesType) { $nowTimes = [VrhmCpuTimes]::Read() }
            $load = Get-CpuTimesPercent -From $Sampler.Cpu.Prev -To $nowTimes
            if ($null -ne $nowTimes) { $Sampler.Cpu.Prev = $nowTimes }
            if ($null -eq $load) {
                $load = (Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop).PercentProcessorTime
            }
            return [PSCustomObject]@{
                Model         = $Sampler.Cpu.Static.Model
                PhysicalCores = $Sampler.Cpu.Static.PhysicalCores
                LogicalCores  = $Sampler.Cpu.Static.LogicalCores
                LoadPercent   = [int][Math]::Round([double]$load)
            }
        } catch {
            return $null
        }
    }

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


# Compiles the VrhmCpuTimes GetSystemTimes wrapper once per process (locale-independent,
# unlike Get-Counter). Shared by the computer monitor sampler and the stream benchmark
# (Initialize-StreamBenchmarkCpuType delegates here). $true when the type is available.
function Initialize-CpuTimesType {
    if ('VrhmCpuTimes' -as [type]) { return $true }
    try {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class VrhmCpuTimes {
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetSystemTimes(out long idle, out long kernel, out long user);
    public static long[] Read() {
        long i, k, u;
        if (!GetSystemTimes(out i, out k, out u)) { return null; }
        return new long[] { i, k, u };
    }
}
'@ -ErrorAction Stop
        return $true
    } catch {
        try { Write-Log ("CPU time helper unavailable: " + $_.Exception.Message) -Level WARNING } catch { }
        return $false
    }
}


# Whole-PC CPU % between two [VrhmCpuTimes]::Read() snapshots (kernel time includes idle),
# rounded to 0.1. $null when either snapshot is missing or the interval is empty.
function Get-CpuTimesPercent {
    param($From, $To)
    if (-not $From -or -not $To) { return $null }
    $idle  = [double]($To[0] - $From[0])
    $total = [double](($To[1] - $From[1]) + ($To[2] - $From[2]))
    if ($total -le 0) { return $null }
    return [Math]::Round([Math]::Max(0.0, [Math]::Min(100.0, (1 - $idle / $total) * 100)), 1)
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

# Reduces one adapter's engine hashtable ([engine type] = summed %) to the figures we report.
# Shared by Get-GpuInfo and Measure-StreamBenchmarkSample so both apply the same vendor rules.
# Engine type names are vendor specific - measured on real hardware:
#   AMD 780M : 3d, copy, compute 0/1, timer 0, security 1, high priority 3d/compute,
#              video jpeg 0, "video codec 0"  <- ONE unified VCN engine, encode AND decode
#   NVIDIA   : 3d, copy, videodecode, videoencode, jpeg_decode_0, ofa_0, security, vr
#   Intel    : 3d, copy, legacyoverlay, videodecode, videoprocessing
# AMD exposes no videoencode/videodecode at all, so Encode/Decode stay 0 there and
# Video is the only field carrying the real (often dominant) transcode load.
# Returns @{Load3D;Encode;Decode;Video;Utilization} (raw sums, not clipped).
function Get-GpuEngineStats {
    param([hashtable]$Engines)
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


# Sums the engine buckets of every LUID of an engine map ([luid][engine type] = %), except
# -ExcludeLuid (the Microsoft Basic Render Driver). Used when exactly one physical GPU
# exists: on some machines (observed: AMD iGPU queried through a Remote Desktop session)
# the LUID DXGI reports for the real GPU does not match the LUID of its perf counters, so
# the counters cannot be joined to the adapter - and with one GPU there is nothing to join.
function Merge-GpuEngineMap {
    param([hashtable]$EngineMap, [string]$ExcludeLuid)
    $agg = @{}
    if (-not $EngineMap) { return $agg }
    foreach ($luidKv in $EngineMap.GetEnumerator()) {
        if ($ExcludeLuid -and $luidKv.Key -eq $ExcludeLuid) { continue }
        foreach ($e in $luidKv.Value.GetEnumerator()) {
            if (-not $agg.ContainsKey($e.Key)) { $agg[$e.Key] = 0.0 }
            $agg[$e.Key] += $e.Value
        }
    }
    return $agg
}


# Engine map [luid][engine type] = summed % over the interval between two raw reads of the
# "GPU Engine" counter category (PerformanceCounterCategory.ReadCategory()['Utilization
# Percentage']). An instance born or gone during the interval is skipped. Shared by the
# computer monitor sampler (Get-GpuInfo -Sampler) and Measure-StreamBenchmarkSample.
function Get-GpuEngineDeltaMap {
    param($Previous, $Current)
    $map = @{}
    if (-not $Previous -or -not $Current) { return $map }
    foreach ($name in @($Current.Keys)) {
        $b = $Current[$name]; $a = $Previous[$name]
        if (-not $a -or -not $b) { continue }
        if ($name -notmatch 'luid_(0x[0-9a-f]+_0x[0-9a-f]+).*engtype_(.+)$') { continue }
        $luid = $Matches[1]; $eng = $Matches[2].Trim().ToLower()
        $v = 0.0; try { $v = [System.Diagnostics.CounterSample]::Calculate($a.Sample, $b.Sample) } catch { }
        if (-not $map.ContainsKey($luid))       { $map[$luid] = @{} }
        if (-not $map[$luid].ContainsKey($eng)) { $map[$luid][$eng] = 0.0 }
        $map[$luid][$eng] += $v
    }
    return $map
}


# The physical GPUs of this PC, without any perf counter: @{ Gpus = @(@{Index;Model;
# VramBytes;Luid}); Single; ExcludeLuid }, or $null when Win32_VideoController fails or
# reports no adapter (WARNING logged). Index is the position after the PCI filter, i.e.
# the index Get-GpuInfo reports and Performance.GPU_Index refers to. Shared by Get-GpuInfo,
# New-ComputerMonitorSampler (read once) and New-StreamBenchmarkSampler.
function Get-GpuLayout {
    # Build a lookup: GPU DriverDesc -> real VRAM bytes (64-bit QWORD from registry).
    # Win32_VideoController.AdapterRAM is a 32-bit field capped at ~4 GB; the registry
    # stores the full value. Falls back to AdapterRAM when the registry key is absent.
    $regVramMap = @{}
    try {
        $regBase = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
        Get-ChildItem -LiteralPath $regBase -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -match '^\d{4}$' } |
            ForEach-Object {
                $p   = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
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
        return $null
    }
    if ($controllers.Count -eq 0) {
        try { Write-Log "Get-GpuInfo: Win32_VideoController returned no adapter." -Level WARNING } catch {}
        return $null
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

    $gpus = @(for ($i = 0; $i -lt $controllers.Count; $i++) {
        $ctrl    = $controllers[$i]
        $gpuName = ($ctrl.Name -replace '\s+', ' ').Trim()
        # Prefer the registry 64-bit QWORD; fall back to the capped 32-bit AdapterRAM
        $vramBytes = if ($regVramMap.ContainsKey($gpuName)) { $regVramMap[$gpuName] } else { [double]$ctrl.AdapterRAM }
        @{ Index = $i; Model = $gpuName; VramBytes = $vramBytes; Luid = $gpuLuidMap[$gpuName] }
    })
    # Release CIM handles on Win32_VideoController instances
    foreach ($c in $allControllers) { if ($c) { $c.Dispose() } }

    return @{
        Gpus        = $gpus
        Single      = ($gpus.Count -eq 1)
        ExcludeLuid = $gpuLuidMap['Microsoft Basic Render Driver']
    }
}


# Returns an array of GPU info objects (one per adapter).
# Per-GPU: model, dedicated VRAM (GB), 3D/encode/decode/video utilization (%),
# overall utilization (%), VRAM used/free (GB and %). Utilization fields are $null
# when perf counters are unavailable (old Windows, Hyper-V, missing provider).
# VideoPercent covers every video engine whatever the vendor calls it, because AMD
# exposes one unified "video codec" engine instead of videoencode/videodecode -
# on AMD it is the ONLY field carrying transcode load. UtilizationPercent is the
# busiest engine (what Task Manager shows as the headline GPU figure).
# -Sampler (New-ComputerMonitorSampler, S3-2): the adapter layout is read once and kept,
# and the counters come from the sampler's persistent PerformanceCounterCategory readers
# (~10 ms instead of 2-8 s of Get-Counter) as a delta since the previous call with that
# sampler. Without -Sampler (web /api/gpu-list, welcome, benchmark fallback) it works
# standalone exactly as before.
# Returns @() if no GPU is found; never returns $null.
function Get-GpuInfo {
    param([hashtable]$Sampler)

    # Counter instance names embed the adapter LUID:
    #   GPU Engine:         pid_NNNN_luid_0xHH_0xLL_phys_0_eng_N_engtype_3D
    #   GPU Adapter Memory: luid_0xHH_0xLL_phys_0
    # phys_N is always 0 per-adapter (not a global GPU index), so we key maps by LUID string.
    #
    # One pass over every GPU Engine instance, bucketed as [luid][engine type] = summed %
    # across all processes. A single Get-Counter call covers every engine type, which is
    # both cheaper than one call per type and required because the interesting engine
    # names differ per vendor (see Get-GpuEngineStats).
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

    $layout = $null
    if ($Sampler -and $Sampler.Gpu.Layout) { $layout = $Sampler.Gpu.Layout }
    else {
        $layout = Get-GpuLayout
        if ($Sampler -and $layout) { $Sampler.Gpu.Layout = $layout }
    }
    if (-not $layout -or $layout.Gpus.Count -eq 0) { return @() }

    # Collect perf counter maps keyed by LUID string
    $engineMap = $null
    $mapMemUse = @{}
    if ($Sampler -and $Sampler.Gpu.Engine) {
        try {
            $curUtil   = $Sampler.Gpu.Engine.ReadCategory()['Utilization Percentage']
            $engineMap = Get-GpuEngineDeltaMap -Previous $Sampler.Gpu.PrevUtil -Current $curUtil
            $Sampler.Gpu.PrevUtil = $curUtil
        } catch { $engineMap = @{} }
    } else {
        $engineMap = _GetEngineMap
    }
    if ($Sampler -and $Sampler.Gpu.Memory) {
        try {
            $md = $Sampler.Gpu.Memory.ReadCategory()['Dedicated Usage']
            foreach ($k in @($md.Keys)) { if ($k -match 'luid_(0x[0-9a-f]+_0x[0-9a-f]+)') { $mapMemUse[$Matches[1]] = [double]$md[$k].RawValue } }
        } catch { }
    } else {
        try {
            $memUseSamples = (Get-Counter -Counter '\GPU Adapter Memory(*)\Dedicated Usage' -ErrorAction Stop).CounterSamples
            foreach ($s in $memUseSamples) {
                if ($s.InstanceName -match 'luid_(0x[0-9a-f]+_0x[0-9a-f]+)') { $mapMemUse[$Matches[1]] = $s.CookedValue }
            }
        } catch { }
    }

    # Exactly one physical GPU: no LUID join at all (see Merge-GpuEngineMap); sum every
    # counter instance except the Basic Render Driver, whose LUID still matches reliably.
    $singleGpuMode = [bool]$layout.Single
    if ($singleGpuMode) {
        $excludeLuid   = $layout.ExcludeLuid
        $aggEngines    = Merge-GpuEngineMap -EngineMap $engineMap -ExcludeLuid $excludeLuid
        $aggMemUse     = 0.0
        $haveAggMemUse = $false
        foreach ($kv in $mapMemUse.GetEnumerator()) { if ($kv.Key -ne $excludeLuid) { $aggMemUse += $kv.Value; $haveAggMemUse = $true } }
    }

    $results = @()
    foreach ($g in $layout.Gpus) {
        $gpuName   = $g.Model
        $vramBytes = [double]$g.VramBytes
        $vramGB    = [Math]::Round($vramBytes / 1GB, 2)

        $load3D = $null; $loadEnc = $null; $loadDec = $null; $loadVideo = $null; $loadUtil = $null
        $vramUsedGB = $null; $vramFreeGB = $null; $vramUsedPct = $null; $vramFreePct = $null

        $st = $null; $usedBytes = $null
        if ($singleGpuMode) {
            # Only one real adapter exists, so the aggregated (LUID-independent) engine
            # buckets computed above are unambiguously this GPU's data.
            $st = Get-GpuEngineStats $aggEngines
            if ($haveAggMemUse) { $usedBytes = $aggMemUse }
        } elseif ($g.Luid) {
            # Resolve this GPU's LUID via DXGI, then look up its counter data
            $st = Get-GpuEngineStats $engineMap[$g.Luid]
            if ($mapMemUse.ContainsKey($g.Luid)) { $usedBytes = $mapMemUse[$g.Luid] }
        }
        if ($st) {
            $load3D    = [int][Math]::Min(100, [Math]::Round($st.Load3D))
            $loadEnc   = [int][Math]::Min(100, [Math]::Round($st.Encode))
            $loadDec   = [int][Math]::Min(100, [Math]::Round($st.Decode))
            $loadVideo = [int][Math]::Min(100, [Math]::Round($st.Video))
            $loadUtil  = [int][Math]::Min(100, [Math]::Round($st.Utilization))
        }
        if ($null -ne $usedBytes) {
            $vramUsedGB  = [Math]::Round($usedBytes / 1GB, 2)
            # Always use physical VRAM capacity for percentage - Total Committed is virtual
            # committed memory (much smaller than card capacity) and gives wrong results.
            $vramFreeGB  = if ($vramBytes -gt 0) { [Math]::Round(($vramBytes - $usedBytes) / 1GB, 2) } else { $null }
            $vramUsedPct = if ($vramBytes -gt 0) { [int][Math]::Round($usedBytes / $vramBytes * 100) } else { $null }
            $vramFreePct = if ($null -ne $vramUsedPct) { 100 - $vramUsedPct } else { $null }
        }

        $results += [PSCustomObject]@{
            Index             = $g.Index
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
    return $results
}


# Returns aggregated CPU % and RAM for groups of processes by executable name.
# Uses a two-snapshot delta on Get-Process.CPU (same formula as Task Manager).
# One entry is always returned per name, even when no instances are running.
# -Sampler (New-ComputerMonitorSampler, S3-2): no sleep. The first snapshot is the one the
# previous call with the same sampler kept, so the delta covers the interval since then
# (the computer monitor runspace takes that baseline a few seconds before each sample).
# A name with no previous snapshot reports 0 % CPU for that call.
function Get-AppWorkload {
    param(
        [string[]]$ProcessNames = @('scrcpy', 'ffmpeg', 'powershell', 'pwsh'),
        [int]$SampleMs = 500,
        [hashtable]$Sampler
    )

    # Logical core count for CPU% normalisation; fall back to 1 on failure
    $logicalCores = 1
    if ($Sampler) {
        $logicalCores = [Math]::Max(1, [Environment]::ProcessorCount)
    } else {
        $cpuProcs = $null
        try {
            $cpuProcs = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop)
            $logicalCores = [int]($cpuProcs | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
            if ($logicalCores -lt 1) { $logicalCores = 1 }
            foreach ($cp in $cpuProcs) { if ($cp) { $cp.Dispose() } }
        } catch { }
    }

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

    if ($Sampler) {
        # First snapshot = the one kept by the previous call (may be missing for a name)
        $snap1 = if ($Sampler.Work.Prev) { $Sampler.Work.Prev } else { @{} }
        $t1    = $Sampler.Work.PrevAt
    } else {
        # Take first snapshot for all names at once
        $snap1 = @{}
        foreach ($n in $ProcessNames) { $snap1[$n] = _Snap $n }
        $t1 = [DateTime]::UtcNow

        Start-Sleep -Milliseconds $SampleMs
    }

    $t2 = [DateTime]::UtcNow
    $elapsed = if ($t1) { ($t2 - $t1).TotalSeconds } else { 0 }
    if ($elapsed -le 0 -and -not $Sampler) { $elapsed = $SampleMs / 1000.0 }

    # Take second snapshot and compute results
    $results = @()
    $snap2All = @{}
    foreach ($n in $ProcessNames) {
        $s2 = _Snap $n
        $snap2All[$n] = $s2
        $s1 = if ($snap1.ContainsKey($n)) { $snap1[$n] } else { @{} }

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

        $cpuPct = 0.0
        if ($elapsed -gt 0) { $cpuPct = [Math]::Round($deltaCpu / $elapsed / $logicalCores * 100, 1) }
        $maxPct  = [double]($s2.Count * 100)
        if ($cpuPct -gt $maxPct -and $maxPct -gt 0) { $cpuPct = $maxPct }

        $results += [PSCustomObject]@{
            ProcessName   = $n
            Count         = $s2.Count
            TotalCpuPct   = $cpuPct
            TotalMemoryMB = [Math]::Round($memMB, 1)
        }
    }
    if ($Sampler) {
        $Sampler.Work.Prev   = $snap2All
        $Sampler.Work.PrevAt = $t2
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


# Builds the stateful sampler the computer monitor runspace keeps for its whole life (S3-2):
# the GPU adapter layout (read once), persistent readers of the "GPU Engine" and "GPU
# Adapter Memory" counter categories, and the previous CPU-times / per-process readings.
# The first ReadCategory of "GPU Engine" is the slow one (several seconds on a machine with
# hundreds of engine instances); it is paid here, once, inside the runspace. Afterwards
# Get-CpuInfo / Get-GpuInfo / Get-AppWorkload -Sampler read in milliseconds with no sleep,
# each as a delta since the previous call - the baseline (Reset-ComputerMonitorBaseline).
# Either counter category may be unavailable ($null); Get-GpuInfo then falls back to
# Get-Counter for that part, so a locale or driver without them still reports.
# Example: $s = New-ComputerMonitorSampler; Start-Sleep 5; Update-ComputerMonitoring -Sampler $s -Force
function New-ComputerMonitorSampler {
    param([string[]]$ProcessNames = @('scrcpy', 'ffmpeg', 'powershell'))
    $s = @{
        ProcessNames = $ProcessNames
        BaselineAt   = $null
        Cpu          = @{ Static = $null; Prev = $null }
        Gpu          = @{ Layout = $null; Engine = $null; Memory = $null; PrevUtil = $null }
        Work         = @{ Prev = $null; PrevAt = $null }
    }
    [void](Initialize-CpuTimesType)
    try { $s.Gpu.Layout = Get-GpuLayout } catch { }
    try {
        $s.Gpu.Engine = [System.Diagnostics.PerformanceCounterCategory]::new('GPU Engine')
        [void]$s.Gpu.Engine.ReadCategory()   # the slow first read, here rather than in a sample
    } catch { $s.Gpu.Engine = $null }
    try {
        $s.Gpu.Memory = [System.Diagnostics.PerformanceCounterCategory]::new('GPU Adapter Memory')
        [void]$s.Gpu.Memory.ReadCategory()
    } catch { $s.Gpu.Memory = $null }
    Reset-ComputerMonitorBaseline -Sampler $s
    return $s
}


# Takes the "previous" readings of a computer monitor sampler now: CPU times, GPU engine
# counters and per-process CPU. The next Update-ComputerMonitoring -Sampler then measures
# the interval since this call. The runspace calls it a few seconds before each sample, so
# a process started minutes ago but after the last sample (a new ffmpeg) is still counted -
# a per-PID delta over the whole refresh interval would miss it. Cheap: no sleep, no CIM.
# Example: Reset-ComputerMonitorBaseline -Sampler $s
function Reset-ComputerMonitorBaseline {
    param([Parameter(Mandatory = $true)][hashtable]$Sampler)
    try { [void](Get-CpuInfo -Sampler $Sampler) } catch { }
    try { [void](Get-GpuInfo -Sampler $Sampler) } catch { }
    try { [void](Get-AppWorkload -Sampler $Sampler -ProcessNames $Sampler.ProcessNames) } catch { }
    $Sampler.BaselineAt = [DateTime]::UtcNow
}


# Turns recording off on every headset when the recording drive is below its free-space
# minimum (a REGISTRY write: Get-KnownHeadsets + Save-Headsets, which also regenerates the
# overlays). Called by the VRMonitor main loop when the computer monitor runspace publishes
# a low drive in $sharedState['_recording_drive_low'], so registry writes keep happening in
# one place; the runspace does not even load headsets_manager.ps1. Returns the number of
# headsets changed. Never throws.
# Example: Disable-RecordingOnLowDisk -RecordingDrive (Get-RecordingDriveInfo)
function Disable-RecordingOnLowDisk {
    param($RecordingDrive)
    if (-not $RecordingDrive -or -not $RecordingDrive.IsLow) { return 0 }
    $count = 0
    try {
        $rows = Get-KnownHeadsets
        foreach ($h in $rows) {
            if (ConvertTo-BoolField $h.Record) {
                $h.Record = 'False'
                $count++
                Write-Log ("Recording auto-disabled on {0} - drive {1}: only {2} GB free (min {3} GB)" -f $h.Name, $RecordingDrive.DriveLetter, $RecordingDrive.FreeGB, $RecordingDrive.MinFreeGB) -Level WARNING
            }
        }
        if ($count -gt 0) { Save-Headsets -headsets $rows }
    } catch {
        Write-Log ("Update-ComputerMonitoring: failed to auto-disable recording: {0}" -f $_) -Level WARNING
    }
    return $count
}


# Collects the CPU/RAM/GPU/AppWorkload/RecordingDrive snapshot and writes it to the app_kv
# row 'computer_monitoring' (shape unchanged: the web pages, VRMonitor and VQA read it).
# Since S3-2 it runs in the computer monitor runspace (Start-ComputerMonitorRunspace), never
# on the VRMonitor thread, with a -Sampler so nothing sleeps. Returns the snapshot it wrote,
# or $null when it skipped.
#   -Sampler        New-ComputerMonitorSampler; omitted = the standalone, sleeping samplers.
#   -Force          the caller owns the schedule (the runspace): no age check.
#   -NoRegistryWrite  do not auto-disable recording here on a low drive; the caller publishes
#                   the drive (RecordingDrive.IsLow of the returned snapshot) and the main
#                   loop applies Disable-RecordingOnLowDisk, keeping registry writes in one
#                   place. Without it the old in-place behaviour is kept for other callers.
function Update-ComputerMonitoring {
    param(
        [hashtable]$Sampler,
        [switch]$Force,
        [switch]$NoRegistryWrite
    )
    # Skip if file is recent enough and no force-refresh flag file present.
    # The throttle interval is adaptive: when CPU pressure is high, slow the
    # snapshot down so the monitor itself stops adding load (saves WMI + perf-
    # counter calls). See Get-AdaptiveMonitorInterval for thresholds.
    $flagFile = Join-Path -Path $global:ScriptPath -ChildPath "data\computer_monitoring_forcerefresh.flag"
    $forceRefresh = Test-Path -LiteralPath $flagFile
    $needsRefresh = $forceRefresh -or $Force
    if (-not $needsRefresh) {
        # Age comes from the snapshot's own Timestamp rather than a file
        # mtime now that this lives in the database. An unreadable or
        # unparsable timestamp means refresh, which is the safe direction.
        $previous = $null
        try { $previous = Get-DbKeyValue -Key 'computer_monitoring' } catch { }
        if ($null -eq $previous -or -not $previous.Timestamp) {
            $needsRefresh = $true
        } else {
            $threshold = Get-AdaptiveMonitorInterval
            $lastWrite = [datetime]::MinValue
            if ([datetime]::TryParse([string]$previous.Timestamp, [ref]$lastWrite)) {
                $age = (Get-Date) - $lastWrite
                if ($age.TotalSeconds -ge $threshold) { $needsRefresh = $true }
            } else {
                $needsRefresh = $true
            }
        }
    }

    if (-not $needsRefresh) {
        Write-Log $msg.ComputerMonitoringSkipped -Level DEBUG
        return $null
    }

    # Remove flag file before collecting so a new request during collection is not lost
    if ($forceRefresh) {
        Remove-Item -LiteralPath $flagFile -Force -ErrorAction SilentlyContinue
    }

    $cpu       = Get-CpuInfo -Sampler $Sampler
    $ram       = Get-RamInfo
    # @() is mandatory: PowerShell unrolls a single-element array on return, and
    # ConvertTo-Json then writes "GPU": {...} instead of "GPU": [{...}]. The web UI
    # tests d.GPU.length, which is undefined on an object, so a machine with exactly
    # one GPU rendered no GPU card at all until the array was forced here.
    $gpu       = @(Get-GpuInfo -Sampler $Sampler)
    $workload  = @(Get-AppWorkload -ProcessNames @("scrcpy", "ffmpeg", "powershell") -Sampler $Sampler)
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

    Set-DbKeyValue -Key 'computer_monitoring' -Value $snapshot -Depth 5

    Write-Log $msg.ComputerMonitoringUpdated -Level DEBUG

    # Auto-disable recording on all headsets when drive space drops below threshold
    if (-not $NoRegistryWrite) { [void](Disable-RecordingOnLowDisk -RecordingDrive $recDrive) }
    return $snapshot
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

$script:LoadTierCpuMemo = $null   # @{At=<TickCount ms>; Cpu=<int|$null>}

function Get-LoadTier {
    if (-not $global:AdaptiveMonitoring_Enabled) { return 'idle' }
    if (-not $global:VQA_Enabled)                { return 'idle' }
    # The snapshot is parsed at most once per second per process: this is polled by
    # every page (1 s in the video wall's fast mode) and by the monitoring loops.
    $cpu = $null
    $memo = $script:LoadTierCpuMemo
    $nowMs = [Environment]::TickCount
    $age = if ($memo) { [int]($nowMs - $memo.At) } else { -1 }
    if ($memo -and $age -ge 0 -and $age -lt 1000) {
        $cpu = $memo.Cpu
    }
    else {
        $snap = $null
        try { $snap = Get-DbKeyValue -Key 'computer_monitoring' } catch { return 'idle' }
        if ($null -eq $snap) { return 'idle' }
        if     ($null -ne $snap.CPU.LoadPercent) { $cpu = [int]$snap.CPU.LoadPercent }
        elseif ($null -ne $snap.Cpu.LoadPercent) { $cpu = [int]$snap.Cpu.LoadPercent }
        elseif ($null -ne $snap.CpuLoadPercent)  { $cpu = [int]$snap.CpuLoadPercent }
        $script:LoadTierCpuMemo = @{ At = $nowMs; Cpu = $cpu }
    }
    if ($null -eq $cpu) { return 'idle' }
    if ($cpu -ge [int]$global:VQA_CpuMaxThreshold)        { return 'max' }
    if ($cpu -ge [int]$global:VQA_CpuMitigationThreshold) { return 'mitigation' }
    return 'idle'
}

function Get-LoadMultiplier {
    # -Tier: a tier the caller already computed, so the snapshot is not read twice
    # (/api/load-tier needs both the tier and the multiplier).
    param([string]$Tier)
    if (-not $Tier) { $Tier = Get-LoadTier }
    switch ($Tier) {
        'max'        { return 5 }
        'mitigation' { return 2 }
        default      { return 1 }
    }
}

# Returns the interval (seconds) between two computer monitoring snapshots (the
# computer monitoring runspace, S3-2, and Update-ComputerMonitoring's own age check).
# Always >= base; high CPU LENGTHENS the interval (so the monitor stops adding to the
# load it is measuring).
# Clamped at 600 s to avoid runaway intervals on long-running max-tier load.
function Get-AdaptiveMonitorInterval {
    $base = if ($null -ne $global:ComputerMonitoring_refresh_timer_sec) { [int]$global:ComputerMonitoring_refresh_timer_sec } else { 60 }
    $m    = Get-LoadMultiplier
    return [Math]::Min(600, $base * $m)
}
