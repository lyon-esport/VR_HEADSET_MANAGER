<#
.SYNOPSIS
Read-only performance snapshot of a running VR HEADSET MANAGER install (S0-1).

.DESCRIPTION
Classifies every process belonging to this install by role (main, vrmonitor, webserver,
pipe_bridge, timer_job, job, scrcpy, ffmpeg, mediamtx, adb ...), samples working set,
private bytes and CPU every 2 s, counts adb.exe spawns (every 250 ms, a LOWER BOUND:
a process shorter than the poll interval is missed), reports WmiPrvSE CPU seconds and,
optionally, HTTP requests counted in a web log. Writes a JSON report and prints a table.
Never starts, stops or modifies anything. Standalone: loads no project module.

.EXAMPLE
.\scripts\Measure-AppPerf.ps1 -DurationSec 60 -Label before

.EXAMPLE
.\scripts\Measure-AppPerf.ps1 -DurationSec 60 -Label after -Compare .\scripts\perf_reports\perf_20261013_101500.json

.EXAMPLE
.\scripts\Measure-AppPerf.ps1 -Compare old.json -CompareTo new.json   # no sampling
#>
[CmdletBinding()]
param(
    [int]$DurationSec = 60,
    [string]$OutFile,
    [string]$Label = '',
    [string]$WebLogPath,
    [string]$Compare,
    [string]$CompareTo
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$utf8NoBom = New-Object System.Text.UTF8Encoding $false

function Read-Report {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Report not found: $Path" }
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Show-Comparison {
    param($Old, $New)
    Write-Host ''
    Write-Host ("Compare: [{0}] {1}  ->  [{2}] {3}" -f $Old.label, $Old.timestamp, $New.label, $New.timestamp)
    $names = @(@($Old.roles | ForEach-Object { $_.role }) + @($New.roles | ForEach-Object { $_.role }) | Select-Object -Unique)
    $rows = foreach ($n in $names) {
        $o = @($Old.roles | Where-Object { $_.role -eq $n })[0]
        $w = @($New.roles | Where-Object { $_.role -eq $n })[0]
        $oc = 0; $nc = 0; $ow = 0.0; $nw = 0.0; $ocpu = 0.0; $ncpu = 0.0
        if ($o) { $oc = $o.count; $ow = $o.avgWsMB; $ocpu = $o.cpuPct }
        if ($w) { $nc = $w.count; $nw = $w.avgWsMB; $ncpu = $w.cpuPct }
        [PSCustomObject]@{
            Role     = $n
            CountOld = $oc; CountNew = $nc; CountDelta = $nc - $oc
            WsOldMB  = $ow; WsNewMB = $nw; WsDeltaMB = [Math]::Round($nw - $ow, 1)
            CpuOld   = $ocpu; CpuNew = $ncpu; CpuDelta = [Math]::Round($ncpu - $ocpu, 2)
        }
    }
    $rows | Format-Table -AutoSize | Out-String | Write-Host
    $line = '{0,-22} old={1,-10} new={2,-10} delta={3}'
    Write-Host ($line -f 'PC CPU avg %', $Old.pcCpuAvg, $New.pcCpuAvg, [Math]::Round([double]$New.pcCpuAvg - [double]$Old.pcCpuAvg, 1))
    Write-Host ($line -f 'adb spawns/min (>=)', $Old.adbSpawnsPerMin, $New.adbSpawnsPerMin, [Math]::Round([double]$New.adbSpawnsPerMin - [double]$Old.adbSpawnsPerMin, 1))
    Write-Host ($line -f 'WmiPrvSE CPU s', $Old.wmiPrvSeCpuSec, $New.wmiPrvSeCpuSec, [Math]::Round([double]$New.wmiPrvSeCpuSec - [double]$Old.wmiPrvSeCpuSec, 2))
    if ($null -ne $Old.httpRequestsPerMin -and $null -ne $New.httpRequestsPerMin) {
        Write-Host ($line -f 'HTTP req/min', $Old.httpRequestsPerMin, $New.httpRequestsPerMin, [Math]::Round([double]$New.httpRequestsPerMin - [double]$Old.httpRequestsPerMin, 1))
    }
}

# Compare-only mode: two files, no sampling.
if ($Compare -and $CompareTo) {
    Show-Comparison -Old (Read-Report $Compare) -New (Read-Report $CompareTo)
    return
}

if ($DurationSec -lt 4) { $DurationSec = 4 }

if (-not ('VrhmPerfCpuTimes' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class VrhmPerfCpuTimes {
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetSystemTimes(out long idle, out long kernel, out long user);
    public static long[] Read() {
        long i, k, u;
        if (!GetSystemTimes(out i, out k, out u)) { return null; }
        return new long[] { i, k, u };
    }
}
'@
}

function Get-LineCount {
    param([string]$Path)
    $n = 0
    $fs = $null; $sr = $null
    try {
        $fs = New-Object System.IO.FileStream($Path, 'Open', 'Read', 'ReadWrite')
        $sr = New-Object System.IO.StreamReader($fs)
        while ($null -ne $sr.ReadLine()) { $n++ }
    } finally {
        if ($sr) { $sr.Dispose() } elseif ($fs) { $fs.Dispose() }
    }
    return $n
}

function Get-InstallProcessMap {
    # ONE CIM call; returns pid -> role for every process belonging to this install.
    $cim = @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name, ExecutablePath, CommandLine, CreationDate)
    $sources = Join-Path $root 'sources'
    $map = @{}
    $ps = @()
    $mainPid = 0
    foreach ($p in $cim) {
        $cl = [string]$p.CommandLine
        $exe = [string]$p.ExecutablePath
        $nm = ([string]$p.Name).ToLowerInvariant()
        $underSources = $exe -and $exe.StartsWith($sources, [StringComparison]::OrdinalIgnoreCase)
        if ($underSources) {
            switch ($nm) {
                'scrcpy.exe'   { $map[[int]$p.ProcessId] = 'scrcpy' }
                'ffmpeg.exe'   { $map[[int]$p.ProcessId] = 'ffmpeg' }
                'mediamtx.exe' { $map[[int]$p.ProcessId] = 'mediamtx' }
                'adb.exe'      { $map[[int]$p.ProcessId] = 'adb' }
                default        { $map[[int]$p.ProcessId] = 'other' }
            }
            continue
        }
        if ($nm -in @('powershell.exe', 'pwsh.exe')) { $ps += $p }
    }
    # script-named PowerShell hosts first
    foreach ($p in $ps) {
        $cl = [string]$p.CommandLine
        $id = [int]$p.ProcessId
        if ($cl -match 'web_server\.ps1') { $map[$id] = 'webserver' }
        elseif ($cl -match 'headsets_dashboard\.ps1') { $map[$id] = 'dashboard' }
        elseif ($cl -match 'reaper\.ps1') { $map[$id] = 'reaper' }
        elseif ($cl -match 'mdns_responder') { $map[$id] = 'mdns' }
        elseif ($cl -match 'main\.ps1' -and ($cl.IndexOf($root, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or $cl -match 'VR_HEADSET_MANAGER')) {
            $map[$id] = 'main'
            if ($mainPid -eq 0) { $mainPid = $id }
        }
    }
    if ($mainPid -eq 0) { $mainPid = @($map.GetEnumerator() | Where-Object { $_.Value -eq 'main' } | ForEach-Object { $_.Key })[0] }
    # children of main: jobs
    $jobs = @()
    foreach ($p in $ps) {
        $id = [int]$p.ProcessId
        if ($map.ContainsKey($id)) { continue }
        if ($mainPid -and [int]$p.ParentProcessId -eq $mainPid) {
            $cl = [string]$p.CommandLine
            if ($cl -match 'vrm_') { $map[$id] = 'pipe_bridge' }
            elseif ($cl -match 'timer') { $map[$id] = 'timer_job' }
            else { $jobs += $p }
        }
    }
    # the oldest remaining job is the VRMonitor
    $jobs = @($jobs | Sort-Object CreationDate)
    for ($i = 0; $i -lt $jobs.Count; $i++) {
        $map[[int]$jobs[$i].ProcessId] = $(if ($i -eq 0) { 'vrmonitor' } else { 'job' })
    }
    return $map
}

$startMap = Get-InstallProcessMap
if ($startMap.Count -eq 0) {
    Write-Host 'No process of this install found (is the app running?). Nothing to measure.'
    exit 1
}
Write-Host ("Measuring {0} s, {1} install processes at start. Root: {2}" -f $DurationSec, $startMap.Count, $root)

$cores = [Environment]::ProcessorCount
$names = @('powershell', 'pwsh', 'scrcpy', 'ffmpeg', 'mediamtx', 'adb')
$samples = New-Object System.Collections.ArrayList     # each: hashtable pid -> @(ws, priv)
$cpuFirst = @{}; $cpuLast = @{}; $nameOf = @{}
$wmiFirst = @{}; $wmiLast = @{}
$adbPids = @{}
$pcCpu = @()
$cpuPrev = [VrhmPerfCpuTimes]::Read()

$httpBefore = $null
if ($WebLogPath) {
    if (Test-Path -LiteralPath $WebLogPath) { $httpBefore = Get-LineCount -Path $WebLogPath }
    else { Write-Host "WebLogPath not found, HTTP rate skipped." }
} else {
    Write-Host 'HTTP rate skipped: no -WebLogPath (the web server does not log requests).'
}

$sw = [Diagnostics.Stopwatch]::StartNew()
$tick = 0
while ($sw.Elapsed.TotalSeconds -lt $DurationSec) {
    foreach ($a in @(Get-Process -Name adb -ErrorAction SilentlyContinue)) { $adbPids[[int]$a.Id] = $true }
    if (($tick % 8) -eq 0) {
        $snap = @{}
        foreach ($p in @(Get-Process -Name $names -ErrorAction SilentlyContinue)) {
            $id = [int]$p.Id
            try {
                $snap[$id] = @([double]$p.WorkingSet64, [double]$p.PrivateMemorySize64)
                $cpu = [double]$p.TotalProcessorTime.TotalSeconds
                if (-not $cpuFirst.ContainsKey($id)) { $cpuFirst[$id] = $cpu }
                $cpuLast[$id] = $cpu
                $nameOf[$id] = $p.ProcessName.ToLowerInvariant()
            } catch { }
        }
        [void]$samples.Add($snap)
        foreach ($p in @(Get-Process -Name WmiPrvSE -ErrorAction SilentlyContinue)) {
            try {
                $c = [double]$p.TotalProcessorTime.TotalSeconds
                if (-not $wmiFirst.ContainsKey([int]$p.Id)) { $wmiFirst[[int]$p.Id] = $c }
                $wmiLast[[int]$p.Id] = $c
            } catch { }
        }
        $now = [VrhmPerfCpuTimes]::Read()
        if ($cpuPrev -and $now) {
            $idle = [double]($now[0] - $cpuPrev[0])
            $tot = [double](($now[1] - $cpuPrev[1]) + ($now[2] - $cpuPrev[2]))
            if ($tot -gt 0) { $pcCpu += [Math]::Max(0.0, [Math]::Min(100.0, (1 - $idle / $tot) * 100)) }
        }
        $cpuPrev = $now
    }
    $tick++
    Start-Sleep -Milliseconds 250
}
$elapsed = $sw.Elapsed.TotalSeconds

$endMap = Get-InstallProcessMap
$httpRate = $null
if ($null -ne $httpBefore) {
    $after = Get-LineCount -Path $WebLogPath
    $httpRate = [Math]::Round(($after - $httpBefore) * 60.0 / $elapsed, 1)
}

# Merge role maps (end wins for pids seen only there), fall back to name for non-PowerShell.
$roleOf = @{}
foreach ($k in $startMap.Keys) { $roleOf[$k] = $startMap[$k] }
foreach ($k in $endMap.Keys) { if (-not $roleOf.ContainsKey($k)) { $roleOf[$k] = $endMap[$k] } }

function Get-RoleOfPid {
    param([int]$Id)
    if ($roleOf.ContainsKey($Id)) { return $roleOf[$Id] }
    $n = $nameOf[$Id]
    if ($n -in @('scrcpy', 'ffmpeg', 'mediamtx', 'adb')) { return $n }
    return $null
}

$roleStats = @{}
foreach ($id in $nameOf.Keys) {
    $r = Get-RoleOfPid -Id $id
    if (-not $r) { continue }
    if (-not $roleStats.ContainsKey($r)) { $roleStats[$r] = @{ Pids = @{}; Cpu = 0.0 } }
    $roleStats[$r].Pids[$id] = $true
    $roleStats[$r].Cpu += ($cpuLast[$id] - $cpuFirst[$id])
}

$mb = 1MB
$roles = @()
foreach ($r in ($roleStats.Keys | Sort-Object)) {
    $wsSums = @(); $privSums = @(); $counts = @()
    foreach ($s in $samples) {
        $ws = 0.0; $pv = 0.0; $c = 0
        foreach ($id in $roleStats[$r].Pids.Keys) {
            if ($s.ContainsKey($id)) { $ws += $s[$id][0]; $pv += $s[$id][1]; $c++ }
        }
        $wsSums += $ws; $privSums += $pv; $counts += $c
    }
    if ($wsSums.Count -eq 0) { continue }
    $roles += [PSCustomObject]@{
        role      = $r
        count     = [int](($counts | Measure-Object -Maximum).Maximum)
        avgWsMB   = [Math]::Round((($wsSums | Measure-Object -Average).Average) / $mb, 1)
        peakWsMB  = [Math]::Round((($wsSums | Measure-Object -Maximum).Maximum) / $mb, 1)
        avgPrivMB = [Math]::Round((($privSums | Measure-Object -Average).Average) / $mb, 1)
        cpuPct    = [Math]::Round($roleStats[$r].Cpu / $elapsed / $cores * 100, 2)
    }
}

if ($roles.Count -eq 0) {
    Write-Host 'No sample matched an install role. Nothing to report.'
    exit 1
}

$wmiSec = 0.0
foreach ($id in $wmiLast.Keys) { $wmiSec += ($wmiLast[$id] - $wmiFirst[$id]) }
$pcAvg = 0.0
if ($pcCpu.Count -gt 0) { $pcAvg = [Math]::Round((($pcCpu | Measure-Object -Average).Average), 1) }

$report = [ordered]@{
    label              = $Label
    host               = $env:COMPUTERNAME
    timestamp          = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    root               = $root
    durationSec        = [Math]::Round($elapsed, 1)
    samples            = $samples.Count
    logicalCores       = $cores
    pcCpuAvg           = $pcAvg
    adbSpawnsPerMin    = [Math]::Round($adbPids.Count * 60.0 / $elapsed, 1)
    adbSpawnsNote      = 'lower bound: polled every 250 ms, short-lived adb.exe can be missed; also counts adb.exe outside this install'
    wmiPrvSeCpuSec     = [Math]::Round($wmiSec, 2)
    httpRequestsPerMin = $httpRate
    roles              = $roles
}

if (-not $OutFile) {
    $OutFile = Join-Path $root ('scripts\perf_reports\perf_{0}.json' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
}
$dir = Split-Path -Parent $OutFile
if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
[System.IO.File]::WriteAllText($OutFile, ($report | ConvertTo-Json -Depth 5), $utf8NoBom)

Write-Host ''
Write-Host ("Perf snapshot [{0}] {1} s, {2} samples" -f $Label, $report.durationSec, $report.samples)
$roles | Format-Table role, count, avgWsMB, peakWsMB, avgPrivMB, cpuPct -AutoSize | Out-String | Write-Host
Write-Host ("PC CPU avg           : {0} %" -f $report.pcCpuAvg)
Write-Host ("adb.exe spawns/min   : {0} (lower bound)" -f $report.adbSpawnsPerMin)
Write-Host ("WmiPrvSE CPU seconds : {0}" -f $report.wmiPrvSeCpuSec)
if ($null -ne $httpRate) { Write-Host ("HTTP requests/min    : {0}" -f $httpRate) }
Write-Host ("Report: {0}" -f $OutFile)

if ($Compare) {
    Show-Comparison -Old (Read-Report $Compare) -New (Read-Report $OutFile)
}
