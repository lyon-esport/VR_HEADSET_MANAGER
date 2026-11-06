<#
.SYNOPSIS
  Measures what the VRHM Companion app costs (headset CPU, WiFi traffic) and what the
  server PC spends on adb processes, sampled over a few minutes. Standalone: not auto-loaded.

.DESCRIPTION
  One CSV row per headset per sample. Run it before and after a change with a different -Label
  ('baseline', 'v2') and compare the averages.

  Columns and what they REALLY measure:
   timestamp          Local time of the sample (ISO 8601).
   label              Free text from -Label.
   device             adb device id (ip:port or serial) used for the shell call.
   headset_id/name    From GET /api/headsets-status when the device could be matched by IP, else empty.
   brand              ro.product.brand read from the headset.
   companion_running  1 when `pidof com.vrheadsetmanager.companion` returned a pid, else 0.
   companion_cpu_pct  CPU of the companion process over the interval since the previous sample, as a
                      percentage of ONE core (100 = one full core; can exceed 100 on multi-core use).
                      method "proc_stat": (utime+stime delta)/CLK_TCK divided by the delta of the
                      headset /proc/uptime. method "top": single `top -b -n 1 -p <pid>` %CPU reading
                      (instantaneous-ish, since top's start, less precise). Empty when neither works
                      (SELinux may hide /proc/<pid> of another uid from the shell).
   cpu_method         proc_stat | top | none.
   wifi_rx_bytes /
   wifi_tx_bytes      Delta of the WHOLE wlan0 interface counters (/proc/net/dev) over the interval.
                      This is all traffic of the headset (video apps included), not only the companion's.
                      Per-uid companion traffic is not collected (xt_qtaguid is gone on recent Android).
   pc_adb_spawns      Number of NEW adb.exe processes seen on THIS PC during the sampling wait
                      (polled every ~1 s, so a process living under ~1 s may be missed). Same value on
                      every device row of a sample. This script's own adb calls run after the wait
                      window and are not counted, but adb calls from the VRHM app are (that is the point).
   push_seen          1/0: companion_fresh from the API at sample time (a fresh telemetry push exists).
                      It does NOT count pushes.
   push_count         Pushes the route handled for this headset in the interval (delta of the cumulative
                      push_count in /api/headsets-status; after a web server restart the first delta is the raw value).
   push_bytes         Request bytes of those pushes (delta of push_bytes).
   push_handler_ms    Handler time of the last push (last_push_handler_ms).
   push_latency_ms    Round trip the app measured on its previous push (companion_rtt_ms; telemetry v2 apps only).

  Limits: the first sample is only a baseline (not written). Counter resets (reboot) give empty deltas.
  Every adb call has a hard timeout; an offline headset yields empty values, never an exception.
#>
[CmdletBinding()]
param(
    [int]$Minutes = 5,
    [int]$SampleSec = 10,
    [string[]]$Device,
    [string]$OutFile,
    [string]$Label = ''
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$pkg  = 'com.vrheadsetmanager.companion'
if ($SampleSec -lt 3) { $SampleSec = 3 }
if ($Minutes -lt 1)   { $Minutes = 1 }

# --- config: adb path and web port -------------------------------------------------------
$cfgPath = Join-Path $root 'config\config.json'
if (-not (Test-Path -LiteralPath $cfgPath)) { Write-Host "config\config.json not found." ; exit 2 }
$cfg = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
$adb = Join-Path (Join-Path $root 'sources') (Join-Path ([string]$cfg.ADB.folder) 'adb.exe')
if (-not (Test-Path -LiteralPath $adb)) { Write-Host "adb.exe not found at $adb" ; exit 2 }
$port = 8080
if ($cfg.WebServer -and $cfg.WebServer.port) { $port = [int]$cfg.WebServer.port }
$apiBase = "http://127.0.0.1:$port"

if (-not $OutFile) {
    $OutFile = Join-Path $root ('scripts\nonRegressionTests\reports\companion_load_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.csv')
}
$outDir = Split-Path -Parent $OutFile
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }

# --- helpers -----------------------------------------------------------------------------
function Invoke-AdbHard {
    param([string[]]$Arguments, [int]$TimeoutMs = 8000)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $adb
    $psi.Arguments = ($Arguments | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    try {
        [void]$p.Start()
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit($TimeoutMs)) {
            try { $p.Kill() } catch {}
            return @{ Ok = $false; Out = ''; TimedOut = $true }
        }
        [void]$outTask.Wait(2000)
        return @{ Ok = ($p.ExitCode -eq 0); Out = [string]$outTask.Result; TimedOut = $false }
    } catch {
        return @{ Ok = $false; Out = ''; TimedOut = $false }
    } finally {
        try { $p.Dispose() } catch {}
    }
}

function Get-ApiHeadsets {
    try {
        $r = Invoke-RestMethod -Uri "$apiBase/api/headsets-status" -TimeoutSec 5 -ErrorAction Stop
        if ($r -and $r.headsets) { return @($r.headsets) }
        return @($r)
    } catch { return @() }
}

function Get-AdbDeviceList {
    $r = Invoke-AdbHard -Arguments @('devices') -TimeoutMs 8000
    $list = @()
    foreach ($l in ($r.Out -split "`r?`n")) {
        if ($l -match '^(\S+)\s+device\s*$') { $list += $Matches[1] }
    }
    return $list
}

$shellScript = 'pid=$(pidof ' + $pkg + ' | cut -d" " -f1); echo "PID=$pid"; echo "CLK=$(getconf CLK_TCK 2>/dev/null)"; ' +
    'echo "UP=$(cut -d" " -f1 /proc/uptime)"; echo "BRAND=$(getprop ro.product.brand)"; ' +
    'if [ -n "$pid" ]; then echo "STAT=$(cat /proc/$pid/stat 2>/dev/null)"; echo "TOPBEGIN"; top -b -n 1 -p $pid 2>/dev/null | tail -n 3; echo "TOPEND"; fi; ' +
    'grep wlan0 /proc/net/dev'

function Read-DeviceSample {
    param([string]$Dev)
    $r = Invoke-AdbHard -Arguments @('-s', $Dev, 'shell', $shellScript) -TimeoutMs 10000
    $s = @{ Ok = $false; Pid = ''; Clk = 100.0; Up = $null; Ticks = $null; Brand = ''; TopCpu = $null; Rx = $null; Tx = $null }
    if (-not $r.Ok -or -not $r.Out) { return $s }
    $s.Ok = $true
    $inTop = $false; $topLines = @()
    foreach ($line in ($r.Out -split "`r?`n")) {
        $t = $line.Trim()
        if ($t -eq 'TOPBEGIN') { $inTop = $true; continue }
        if ($t -eq 'TOPEND')   { $inTop = $false; continue }
        if ($inTop) { $topLines += $t; continue }
        if ($t -match '^PID=(\d*)')   { $s.Pid = $Matches[1] }
        elseif ($t -match '^CLK=(\d+)') { $s.Clk = [double]$Matches[1] }
        elseif ($t -match '^UP=([\d.]+)') { $s.Up = [double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture) }
        elseif ($t -match '^BRAND=(.*)') { $s.Brand = $Matches[1] }
        elseif ($t -match '^STAT=(.+)') {
            $st = $Matches[1]
            $i = $st.LastIndexOf(')')
            if ($i -gt 0) {
                $f = $st.Substring($i + 1).Trim() -split '\s+'
                if ($f.Count -gt 12) { $s.Ticks = [double]$f[11] + [double]$f[12] }
            }
        }
        elseif ($t -match '^\s*wlan0:\s*(.+)') {
            $f = $Matches[1] -split '\s+'
            if ($f.Count -ge 9) { $s.Rx = [double]$f[0]; $s.Tx = [double]$f[8] }
        }
    }
    # top fallback: find %CPU column in header, then the pid line
    if ($null -eq $s.Ticks -and $topLines.Count -ge 2 -and $s.Pid) {
        $hdr = $topLines | Where-Object { $_ -match '%CPU' } | Select-Object -First 1
        $row = $topLines | Where-Object { $_ -match ('^\s*' + $s.Pid + '\s') } | Select-Object -First 1
        if ($hdr -and $row) {
            $h = ($hdr.Trim() -split '\s+'); $v = ($row.Trim() -split '\s+')
            $idx = [Array]::IndexOf($h, '%CPU')
            if ($idx -ge 0 -and $idx -lt $v.Count) {
                $d = 0.0
                if ([double]::TryParse($v[$idx], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { $s.TopCpu = $d }
            }
        }
    }
    return $s
}

# --- device list -------------------------------------------------------------------------
$api = Get-ApiHeadsets
$devices = @()
if ($Device -and $Device.Count -gt 0) {
    # -File invocations pass "a,b" as one string: split on commas too.
    $devices = @($Device | ForEach-Object { $_ -split ',' } | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() })
} else {
    $adbList = Get-AdbDeviceList
    foreach ($h in $api) {
        if (-not $h.adb -or -not $h.ip_address) { continue }
        $cand = $null
        if ([int]$h.adb_port -gt 0) { $cand = "$($h.ip_address):$($h.adb_port)" }
        if ($cand -and ($adbList -contains $cand)) { $devices += $cand; continue }
        $m = $adbList | Where-Object { $_ -like ($h.ip_address + ':*') } | Select-Object -First 1
        if ($m) { $devices += $m }
        elseif ($cand) { $devices += $cand }
    }
    $devices = @($devices | Select-Object -Unique)
}
if ($devices.Count -eq 0) { Write-Host "No online headset found (adb devices / API). Nothing measured."; exit 3 }

function Find-ApiHeadset {
    param([string]$Dev, $List)
    $ip = ($Dev -split ':')[0]
    return ($List | Where-Object { $_.ip_address -eq $ip } | Select-Object -First 1)
}

# --- sampling ----------------------------------------------------------------------------
$seenAdb = @{}
foreach ($p in @(Get-Process -Name adb -ErrorAction SilentlyContinue)) { $seenAdb[$p.Id] = $true }

$prev = @{}
foreach ($d in $devices) { $prev[$d] = Read-DeviceSample -Dev $d }

$cols = 'timestamp','label','device','headset_id','name','brand','companion_running','companion_cpu_pct','cpu_method','wifi_rx_bytes','wifi_tx_bytes','pc_adb_spawns','push_seen','push_count','push_bytes','push_handler_ms','push_latency_ms'
$prevPush = @{}
$rows = New-Object System.Collections.ArrayList
$n = [Math]::Max(1, [int][Math]::Floor($Minutes * 60 / $SampleSec))
Write-Host "Measuring $($devices.Count) device(s): $($devices -join ', ') - $n samples every $SampleSec s. Output: $OutFile"

for ($i = 1; $i -le $n; $i++) {
    # wait window: poll adb.exe creations at ~1 s
    $spawns = 0
    $end = (Get-Date).AddSeconds($SampleSec)
    while ((Get-Date) -lt $end) {
        foreach ($p in @(Get-Process -Name adb -ErrorAction SilentlyContinue)) {
            if (-not $seenAdb.ContainsKey($p.Id)) { $seenAdb[$p.Id] = $true; $spawns++ }
        }
        $left = ($end - (Get-Date)).TotalMilliseconds
        if ($left -gt 0) { Start-Sleep -Milliseconds ([int][Math]::Min(1000, $left)) }
    }
    $api = Get-ApiHeadsets
    foreach ($d in $devices) {
        $cur = Read-DeviceSample -Dev $d
        $pr = $prev[$d]
        $cpu = ''; $method = 'none'; $rx = ''; $tx = ''
        $running = if ($cur.Ok -and $cur.Pid) { 1 } elseif ($cur.Ok) { 0 } else { '' }
        if ($cur.Ok -and $pr.Ok) {
            if ($null -ne $cur.Ticks -and $null -ne $pr.Ticks -and $null -ne $cur.Up -and $null -ne $pr.Up -and $cur.Pid -eq $pr.Pid) {
                $dUp = $cur.Up - $pr.Up
                if ($dUp -gt 0) {
                    $cpu = [Math]::Round((($cur.Ticks - $pr.Ticks) / $cur.Clk) / $dUp * 100, 2)
                    $method = 'proc_stat'
                }
            } elseif ($null -ne $cur.TopCpu) {
                $cpu = $cur.TopCpu; $method = 'top'
            }
            if ($null -ne $cur.Rx -and $null -ne $pr.Rx -and $cur.Rx -ge $pr.Rx -and $cur.Tx -ge $pr.Tx) {
                $rx = [long]($cur.Rx - $pr.Rx); $tx = [long]($cur.Tx - $pr.Tx)
            }
        }
        if ($cpu -ne '') { $cpu = ([double]$cpu).ToString('0.##', [Globalization.CultureInfo]::InvariantCulture) }
        $h = Find-ApiHeadset -Dev $d -List $api
        $brand = if ($cur.Brand) { $cur.Brand } elseif ($pr.Brand) { $pr.Brand } else { '' }
        $fresh = if ($h) { if ($h.companion_fresh) { 1 } else { 0 } } else { '' }
        $pc = ''; $pb = ''; $phm = ''; $plat = ''
        if ($h -and $null -ne $h.push_count) {
            $cc = [int64]$h.push_count; $cb = [int64]$h.push_bytes
            $pp = $prevPush[$d]
            if ($pp -and $cc -ge $pp.Count) { $pc = $cc - $pp.Count; $pb = $cb - $pp.Bytes } else { $pc = $cc; $pb = $cb }
            $prevPush[$d] = @{ Count = $cc; Bytes = $cb }
            $phm = $h.last_push_handler_ms
            if ($null -ne $h.companion_rtt_ms) { $plat = $h.companion_rtt_ms }
        }
        $row = [ordered]@{
            timestamp = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'); label = $Label; device = $d
            headset_id = if ($h) { $h.id } else { '' }; name = if ($h) { $h.name } else { '' }
            brand = $brand; companion_running = $running; companion_cpu_pct = $cpu; cpu_method = $method
            wifi_rx_bytes = $rx; wifi_tx_bytes = $tx; pc_adb_spawns = $spawns
            push_seen = $fresh; push_count = $pc; push_bytes = $pb; push_handler_ms = $phm; push_latency_ms = $plat
        }
        [void]$rows.Add([pscustomobject]$row)
        Write-Host ("[{0}/{1}] {2} running={3} cpu={4}% ({5}) rx={6} tx={7} adbSpawns={8} pushSeen={9}" -f $i, $n, $d, $running, $cpu, $method, $rx, $tx, $spawns, $fresh)
        if ($cur.Ok) { $prev[$d] = $cur }
    }
}

# --- write CSV (UTF-8 no BOM) -------------------------------------------------------------
$csv = ($rows | Select-Object $cols | ConvertTo-Csv -NoTypeInformation) -join "`r`n"
[System.IO.File]::WriteAllText($OutFile, $csv + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
Write-Host "CSV written: $OutFile ($($rows.Count) rows)"

# --- summary -----------------------------------------------------------------------------
Write-Host "--- Summary (label '$Label') ---"
foreach ($g in ($rows | Group-Object device)) {
    $cpuV = @($g.Group | Where-Object { "$($_.companion_cpu_pct)" -ne '' } | ForEach-Object { [double]$_.companion_cpu_pct })
    $rxV  = @($g.Group | Where-Object { "$($_.wifi_rx_bytes)" -ne '' } | ForEach-Object { [double]$_.wifi_rx_bytes })
    $txV  = @($g.Group | Where-Object { "$($_.wifi_tx_bytes)" -ne '' } | ForEach-Object { [double]$_.wifi_tx_bytes })
    $spV  = @($g.Group | ForEach-Object { [double]$_.pc_adb_spawns })
    $cpuS = if ($cpuV.Count) { $m = $cpuV | Measure-Object -Average -Maximum; '{0:N2}/{1:N2}' -f $m.Average, $m.Maximum } else { 'n/a' }
    $rxS  = if ($rxV.Count)  { $m = $rxV  | Measure-Object -Average -Maximum; '{0:N0}/{1:N0}' -f $m.Average, $m.Maximum } else { 'n/a' }
    $txS  = if ($txV.Count)  { $m = $txV  | Measure-Object -Average -Maximum; '{0:N0}/{1:N0}' -f $m.Average, $m.Maximum } else { 'n/a' }
    $m2 = $spV | Measure-Object -Average -Maximum
    Write-Host ("{0}: cpu% avg/max {1} | rx B avg/max {2} | tx B avg/max {3} | pc adb spawns avg/max {4:N2}/{5:N0}" -f $g.Name, $cpuS, $rxS, $txS, $m2.Average, $m2.Maximum)
}
