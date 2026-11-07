<#
.SYNOPSIS
  Probe a (Pico) headset for the VRHM Companion app: what it can read, what is granted,
  what survives a reboot. Evidence-gathering only. Failures are data: exit code is always 0.
.EXAMPLE
  .\scripts\Probe-PicoCompanion.ps1 -Serial 1WMHH8242N0366 -HeadsetId 4 -Install -Reboot
#>
param(
    [Parameter(Mandatory = $true)][string]$Serial,
    [Parameter(Mandatory = $true)][int]$HeadsetId,
    [string]$ServerUrl = '',
    [switch]$Install,
    [switch]$Reboot,
    [string]$OutDir = '',
    [string]$Package = '',
    [int]$SettleSec = 60
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# ---------- config ----------
$cfg = $null
try {
    $cfgPath = Join-Path $root 'config\config.json'
    if (Test-Path -LiteralPath $cfgPath) {
        $cfg = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
} catch { $cfg = $null }

if (-not $ServerUrl) {
    $port = 8080
    try { if ($cfg -and $cfg.WebServer -and $cfg.WebServer.port) { $port = [int]$cfg.WebServer.port } } catch {}
    $ServerUrl = "http://localhost:$port"
}
$ServerUrl = $ServerUrl.TrimEnd('/')
if (-not $Package) {
    $Package = 'com.vrheadsetmanager.companion'
    try { if ($cfg -and $cfg.apk -and $cfg.apk.companionPackageName) { $Package = [string]$cfg.apk.companionPackageName } } catch {}
}
if (-not $OutDir) { $OutDir = Join-Path $root 'docs\improvement_plan\companion-hardening' }
if (-not (Test-Path -LiteralPath $OutDir)) {
    try { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null } catch {}
}

# ---------- adb path ----------
$adb = $null
try {
    if ($cfg -and $cfg.ADB -and $cfg.ADB.folder) {
        $c = Join-Path (Join-Path $root 'sources') (Join-Path ([string]$cfg.ADB.folder) 'adb.exe')
        if (Test-Path -LiteralPath $c) { $adb = $c }
    }
} catch {}
if (-not $adb) {
    try {
        $f = Get-ChildItem -LiteralPath (Join-Path $root 'sources\scrcpy') -Recurse -Filter adb.exe -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($f) { $adb = $f.FullName }
    } catch {}
}

# ---------- helpers ----------
$script:CmdLog = New-Object System.Collections.ArrayList

function ConvertTo-AdbArg {
    param([string]$a)
    if ($null -eq $a -or $a -eq '') { return '""' }
    if ($a -notmatch '[\s"|&;<>()$*?]') { return $a }
    return '"' + ($a -replace '"', '\"') + '"'
}

function Invoke-AdbSafe {
    param([string[]]$AdbArgs, [int]$TimeoutSec = 20)
    $res = [ordered]@{ Cmd = ('adb ' + ($AdbArgs -join ' ')); Exit = $null; Out = ''; TimedOut = $false; Error = '' }
    try {
        if (-not $adb) { throw 'adb.exe not found' }
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $adb
        $psi.Arguments = (($AdbArgs | ForEach-Object { ConvertTo-AdbArg $_ }) -join ' ')
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
        $p = [System.Diagnostics.Process]::Start($psi)
        $tOut = $p.StandardOutput.ReadToEndAsync()
        $tErr = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit($TimeoutSec * 1000)) {
            $res.TimedOut = $true
            try { $p.Kill() } catch {}
        }
        $o = ''; $e = ''
        if ($tOut.Wait(2000)) { $o = $tOut.Result }
        if ($tErr.Wait(2000)) { $e = $tErr.Result }
        if ($p.HasExited) { $res.Exit = $p.ExitCode }
        $res.Out = (($o + $(if ($e) { "`n[stderr] " + $e } else { '' })).Trim())
        if ($res.TimedOut) { $res.Out = ($res.Out + "`n[timeout after ${TimeoutSec}s]").Trim() }
    } catch {
        $res.Error = $_.Exception.Message
        $res.Out = '[error] ' + $_.Exception.Message
    }
    [void]$script:CmdLog.Add([pscustomobject]@{ Cmd = $res.Cmd; Exit = $res.Exit; TimedOut = $res.TimedOut; Out = $res.Out })
    return [pscustomobject]$res
}

function Invoke-Sh {
    param([string]$Script, [int]$TimeoutSec = 20, [string]$Target = $Serial)
    return (Invoke-AdbSafe -AdbArgs @('-s', $Target, 'shell', $Script) -TimeoutSec $TimeoutSec)
}

function Invoke-Api {
    param([string]$Method = 'GET', [string]$Path, $Body = $null, [int]$TimeoutSec = 10)
    $r = [ordered]@{ Path = "$Method $Path"; Ok = $false; Data = $null; Error = '' }
    try {
        $p = @{ Uri = ($ServerUrl + $Path); Method = $Method; TimeoutSec = $TimeoutSec; ErrorAction = 'Stop' }
        if ($null -ne $Body) {
            $p.Body = [System.Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Compress))
            $p.ContentType = 'application/json; charset=utf-8'
        }
        $r.Data = Invoke-RestMethod @p
        $r.Ok = $true
    } catch { $r.Error = $_.Exception.Message }
    return [pscustomobject]$r
}

function Find-RowById {
    param($Data, [int]$Id)
    try {
        $cands = New-Object System.Collections.ArrayList
        if ($null -eq $Data) { return $null }
        $list = $Data
        foreach ($k in @('headsets', 'rows', 'data', 'items')) {
            if ($Data.PSObject.Properties.Name -contains $k) { $list = $Data.$k; break }
        }
        if ($list -is [System.Array]) { foreach ($x in $list) { [void]$cands.Add($x) } }
        elseif ($list -is [System.Management.Automation.PSCustomObject]) {
            foreach ($pr in $list.PSObject.Properties) { [void]$cands.Add($pr.Value) }
        } else { [void]$cands.Add($list) }
        foreach ($x in $cands) {
            if ($null -eq $x) { continue }
            foreach ($n in @('id', 'ID', 'Id')) {
                if ($x.PSObject.Properties.Name -contains $n -and "$($x.$n)" -eq "$Id") { return $x }
            }
        }
    } catch {}
    return $null
}

function Get-RegistryRow { $a = Invoke-Api -Path '/api/headsets'; if ($a.Ok) { return (Find-RowById -Data $a.Data -Id $HeadsetId) }; return $null }
function Get-StatusRow { $a = Invoke-Api -Path '/api/headsets-status'; if ($a.Ok) { return (Find-RowById -Data $a.Data -Id $HeadsetId) }; return $null }

function Get-Lines {
    param([string]$Text, [string]$Pattern, [int]$Max = 200)
    if (-not $Text) { return @() }
    return @(($Text -split "`r?`n") | Where-Object { $_ -match $Pattern } | Select-Object -First $Max)
}

function Get-Snapshot {
    param([string]$Label)
    $s = [ordered]@{ Label = $Label; At = (Get-Date).ToString('o') }
    $s.adb_wifi_enabled = (Invoke-Sh 'settings get global adb_wifi_enabled').Out
    $s.service_adb_tcp_port = (Invoke-Sh 'getprop service.adb.tcp.port').Out
    $s.persist_adb_tcp_port = (Invoke-Sh 'getprop persist.adb.tcp.port').Out
    $s.listening_5555 = (Invoke-Sh 'ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null').Out
    $s.listening_5555_lines = @(Get-Lines -Text $s.listening_5555 -Pattern '5555')
    $svc = (Invoke-Sh "dumpsys activity services $Package").Out
    $s.companion_services_running = (($svc -match 'ServiceRecord') -and ($svc -notmatch '(?i)no services'))
    $s.companion_services_head = @(($svc -split "`r?`n") | Select-Object -First 25)
    $s.accessibility_enabled = (Invoke-Sh 'settings get secure accessibility_enabled').Out
    $s.enabled_accessibility_services = (Invoke-Sh 'settings get secure enabled_accessibility_services').Out
    $s.accessibility_bound_lines = @(Get-Lines -Text (Invoke-Sh 'dumpsys accessibility' -TimeoutSec 30).Out -Pattern ([regex]::Escape($Package)) -Max 30)
    $row = Get-StatusRow
    $s.status_companion_age_ms = $(if ($row) { $row.companion_age_ms } else { $null })
    $s.status_companion_fresh = $(if ($row) { $row.companion_fresh } else { $null })
    return $s
}

# ---------- report state ----------
$R = [ordered]@{}
$R.meta = [ordered]@{
    Started = (Get-Date).ToString('o'); Serial = $Serial; HeadsetId = $HeadsetId; ServerUrl = $ServerUrl
    Package = $Package; Adb = $adb; Install = [bool]$Install; Reboot = [bool]$Reboot; SettleSec = $SettleSec
}

# ---------- 1 identity ----------
$id = [ordered]@{}
foreach ($pr in @('ro.product.brand', 'ro.product.manufacturer', 'ro.product.model', 'ro.build.version.release', 'ro.build.version.sdk', 'ro.build.display.id', 'ro.serialno')) {
    $id[$pr] = (Invoke-Sh "getprop $pr").Out
}
$regApi = Invoke-Api -Path '/api/headsets'
$id.registry_api_ok = $regApi.Ok
$id.registry_api_error = $regApi.Error
$regRow = $null
if ($regApi.Ok) { $regRow = Find-RowById -Data $regApi.Data -Id $HeadsetId }
$id.registry_row = $regRow
$R.identity = $id

$regName = $null
$regIp = $null
if ($regRow) {
    foreach ($n in @('Name', 'name')) { if ($regRow.PSObject.Properties.Name -contains $n) { $regName = [string]$regRow.$n; break } }
    foreach ($n in @('IPAddress', 'ipAddress', 'ip', 'IP')) { if ($regRow.PSObject.Properties.Name -contains $n) { $regIp = [string]$regRow.$n; break } }
}

# ---------- 2 install ----------
if ($Install) {
    $inst = [ordered]@{}
    $ir = Invoke-Api -Method 'POST' -Path '/api/installvrhmcompanion' -Body @{ id = $HeadsetId } -TimeoutSec 180
    $inst.route_ok = $ir.Ok
    $inst.route_error = $ir.Error
    $inst.route_answer = $ir.Data
    $pk = (Invoke-Sh "dumpsys package $Package" -TimeoutSec 30).Out
    $inst.versionName = @(Get-Lines -Text $pk -Pattern 'versionName=' -Max 3)
    $inst.versionCode = @(Get-Lines -Text $pk -Pattern 'versionCode=' -Max 3)
    $R.install = $inst
}

# ---------- 3 grants ----------
$gr = [ordered]@{}
$pkgDump = (Invoke-Sh "dumpsys package $Package" -TimeoutSec 30).Out
$gr.granted_permission_lines = @(Get-Lines -Text $pkgDump -Pattern 'WRITE_SECURE_SETTINGS|POST_NOTIFICATIONS|PACKAGE_USAGE_STATS|GET_USAGE_STATS')
$gr.appops_GET_USAGE_STATS = (Invoke-Sh "appops get $Package GET_USAGE_STATS").Out
$gr.enabled_accessibility_services = (Invoke-Sh 'settings get secure enabled_accessibility_services').Out
$gr.accessibility_enabled = (Invoke-Sh 'settings get secure accessibility_enabled').Out
$gr.accessibility_package_lines = @(Get-Lines -Text (Invoke-Sh 'dumpsys accessibility' -TimeoutSec 30).Out -Pattern ([regex]::Escape($Package)) -Max 40)
$gr.adb_wifi_enabled = (Invoke-Sh 'settings get global adb_wifi_enabled').Out
$gr.service_adb_tcp_port = (Invoke-Sh 'getprop service.adb.tcp.port').Out
$gr.persist_adb_tcp_port = (Invoke-Sh 'getprop persist.adb.tcp.port').Out
$R.grants = $gr

# ---------- 4 shell sources ----------
$sh = [ordered]@{}
$sh.dumpsys_battery = (Invoke-Sh 'dumpsys battery').Out
$sh.power_supply = (Invoke-Sh 'for d in /sys/class/power_supply/*; do echo "== $d"; for f in current_now voltage_now status; do echo "-- $f"; cat $d/$f 2>&1; done; done' -TimeoutSec 25).Out
$sh.thermalservice_head = @(((Invoke-Sh 'dumpsys thermalservice' -TimeoutSec 30).Out -split "`r?`n") | Select-Object -First 80)
$sh.foreground = (Invoke-Sh "dumpsys activity activities | grep -E 'mResumedActivity|topResumedActivity'" -TimeoutSec 30).Out
$dl = (Invoke-Sh 'dumpsys -l' -TimeoutSec 25).Out
$sh.dumpsys_list_candidates = (Invoke-Sh "dumpsys -l | grep -iE 'pvr|pico|controller|remote|input'" -TimeoutSec 25).Out
$sh.getprop_controller = (Invoke-Sh "getprop | grep -iE 'controller|handle|joystick'" -TimeoutSec 25).Out
$svcNames = @(($dl -split "`r?`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '(?i)controller' -and $_ -match '^[A-Za-z0-9_.\-]+$' } | Select-Object -First 5)
$sh.controller_service_names = $svcNames
$cs = [ordered]@{}
foreach ($sn in $svcNames) {
    $cs[$sn] = @(((Invoke-Sh "dumpsys $sn" -TimeoutSec 25).Out -split "`r?`n") | Select-Object -First 40)
}
$sh.controller_service_dumps = $cs
$R.shell_sources = $sh

# ---------- 5 app side ----------
$app = [ordered]@{}
if ($SettleSec -gt 0) { Start-Sleep -Seconds $SettleSec }
$app.status_row = Get-StatusRow
$hs = $null
if ($regName) {
    $hs = Invoke-Api -Path ('/api/headset-settings?name=' + [uri]::EscapeDataString($regName)) -TimeoutSec 30
}
$app.settings_name = $regName
$app.settings_ok = $(if ($hs) { $hs.Ok } else { $false })
$app.settings_error = $(if ($hs) { $hs.Error } else { 'registry name not found' })
$app.settings_answer = $(if ($hs) { $hs.Data } else { $null })
$lc = (Invoke-Sh 'logcat -d -v time' -TimeoutSec 60).Out
$pkgEsc = [regex]::Escape($Package)
$app.logcat_matches = @(($lc -split "`r?`n") | Where-Object { $_ -match $pkgEsc -or $_ -match 'VRHM' -or ($_ -match 'avc' -and $_ -match $pkgEsc) } | Select-Object -Last 200)
$R.app_side = $app

# ---------- 6 reboot ----------
if ($Reboot) {
    $rb = [ordered]@{}
    $rb.before = Get-Snapshot -Label 'before'
    $rb.reboot_cmd = (Invoke-AdbSafe -AdbArgs @('-s', $Serial, 'reboot') -TimeoutSec 20).Out
    Start-Sleep -Seconds 8
    $t0 = Get-Date
    $up = $false
    $polls = 0
    while (((Get-Date) - $t0).TotalSeconds -lt 240) {
        $polls++
        $st = (Invoke-AdbSafe -AdbArgs @('-s', $Serial, 'get-state') -TimeoutSec 8).Out
        if ($st -match '^device$' -or $st -eq 'device') {
            $bc = (Invoke-Sh 'getprop sys.boot_completed' -TimeoutSec 8).Out
            if ($bc -eq '1') { $up = $true; break }
        }
        Start-Sleep -Seconds 3
    }
    $rb.boot_completed = $up
    $rb.boot_wait_sec = [int]((Get-Date) - $t0).TotalSeconds
    $rb.boot_polls = $polls
    Start-Sleep -Seconds 90
    $rb.after = Get-Snapshot -Label 'after'
    $wifi = [ordered]@{ ip = $regIp }
    if ($regIp) {
        $wifi.connect = (Invoke-AdbSafe -AdbArgs @('connect', "${regIp}:5555") -TimeoutSec 20).Out
        $wifi.serialno_over_wifi = (Invoke-Sh 'getprop ro.serialno' -Target "${regIp}:5555").Out
        $wifi.serial_matches = ($wifi.serialno_over_wifi -eq $Serial)
    } else {
        $wifi.connect = 'no registry IP'
    }
    $rb.classic_wifi_test = $wifi
    $rb.status_row_after = Get-StatusRow
    $R.reboot = $rb
}

$R.meta.Finished = (Get-Date).ToString('o')
$R.command_log = @($script:CmdLog)

# ---------- write outputs ----------
function ConvertTo-ReadableText {
    param($Value, [int]$Indent = 0)
    $pad = ' ' * $Indent
    $out = New-Object System.Collections.ArrayList
    if ($null -eq $Value) { [void]$out.Add($pad + '(null)'); return $out }
    if ($Value -is [string]) {
        foreach ($l in ($Value -split "`r?`n")) { [void]$out.Add($pad + $l) }
        return $out
    }
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($k in $Value.Keys) {
            $v = $Value[$k]
            if ($v -is [string] -and $v -notmatch "`n") { [void]$out.Add("$pad${k}: $v") }
            elseif ($null -eq $v -or $v -is [bool] -or $v -is [int] -or $v -is [long] -or $v -is [double]) { [void]$out.Add("$pad${k}: $v") }
            else { [void]$out.Add("$pad${k}:"); foreach ($l in (ConvertTo-ReadableText -Value $v -Indent ($Indent + 2))) { [void]$out.Add($l) } }
        }
        return $out
    }
    if ($Value -is [System.Array]) {
        foreach ($i in $Value) { foreach ($l in (ConvertTo-ReadableText -Value $i -Indent $Indent)) { [void]$out.Add($l) } }
        return $out
    }
    try { foreach ($l in (($Value | ConvertTo-Json -Depth 6) -split "`r?`n")) { [void]$out.Add($pad + $l) } }
    catch { [void]$out.Add($pad + [string]$Value) }
    return $out
}

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$jsonPath = Join-Path $OutDir "pico-probe-$stamp.json"
$txtPath = Join-Path $OutDir "pico-probe-$stamp.txt"

try {
    [System.IO.File]::WriteAllText($jsonPath, ($R | ConvertTo-Json -Depth 8), $utf8NoBom)
} catch { Write-Host "JSON write failed: $($_.Exception.Message)" }

try {
    $sb = New-Object System.Text.StringBuilder
    foreach ($k in $R.Keys) {
        if ($k -eq 'command_log') { continue }
        [void]$sb.AppendLine('==================== ' + $k.ToUpper() + ' ====================')
        foreach ($l in (ConvertTo-ReadableText -Value $R[$k] -Indent 0)) { [void]$sb.AppendLine([string]$l) }
        [void]$sb.AppendLine('')
    }
    [void]$sb.AppendLine('==================== COMMAND LOG ====================')
    foreach ($c in $R.command_log) {
        [void]$sb.AppendLine("> $($c.Cmd)   [exit=$($c.Exit) timeout=$($c.TimedOut)]")
        foreach ($l in ([string]$c.Out -split "`r?`n" | Select-Object -First 30)) { [void]$sb.AppendLine('    ' + $l) }
    }
    [System.IO.File]::WriteAllText($txtPath, $sb.ToString(), $utf8NoBom)
} catch { Write-Host "TXT write failed: $($_.Exception.Message)" }

Write-Host "JSON: $jsonPath"
Write-Host "TXT : $txtPath"
exit 0
