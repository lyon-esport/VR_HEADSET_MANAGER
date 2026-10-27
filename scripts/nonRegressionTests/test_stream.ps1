#Requires -Version 5.1
<#
.SYNOPSIS
    Headset selection and live stream-health helpers for the VR HEADSET MANAGER
    non-regression harness. Dot-sourced by scripts\Invoke-NonRegressionTests.ps1.

.DESCRIPTION
    Sections 50 (scrcpy lifecycle) and 60 (streaming matrix) are the only ones
    that need real hardware, and they share all of the plumbing below.

    Two things are worth knowing before reading further:

      - There is NO "start scrcpy for this headset" endpoint. The app starts
        scrcpy indirectly: setting scrcpy_AutoRestart = True makes the VRMonitor
        loop's Watch-ScrcpyProcesses launch it on its next slow pass. So every
        "start streaming" here is a POST /api/autorestart followed by a poll.

      - Watch-ScrcpyProcesses refuses to launch until Get-KnownHeadsetInfos has
        reported ADBWifi = true for that headset. That is why Wait-NrtHeadsetAdb
        exists and must be awaited before expecting any scrcpy process.

    The sandbox registry starts empty, so these sections import ONE headset from
    the operator's dev registry (reachability-probed first) rather than hardcoding
    an address - no real IP ever lands in a committed test file.

    ASCII only (CLAUDE.md rule 1).
#>

# ---------------------------------------------------------------------------
# Headset discovery and selection
# ---------------------------------------------------------------------------

function Get-NrtDevHeadsets {
    <#
    .SYNOPSIS
        Reads the operator's real headset registry from the DEV folder.

    .DESCRIPTION
        The sandbox registry is deliberately empty, so the candidate list has to
        come from somewhere else. The dev folder's known_headsets.csv is the
        operator's own list and is never written to by the harness.

    .EXAMPLE
        $candidates = Get-NrtDevHeadsets -DevRoot $devRoot
    #>
    param([Parameter(Mandatory = $true)][string]$DevRoot)

    # The registry lives in the dev database now (ADR-0017). known_headsets.csv is only the
    # operator's optional export, so it is as old as the last export: a real run found it five
    # weeks stale, missing a headset and holding addresses from another network, which made the
    # harness skip a headset that was sitting right there. Read the database first.
    try {
        $dbRows = @(Get-SandboxDbRows -TargetRoot $DevRoot -Sql 'SELECT ID, Name, IPAddress, Model, Brand, SerialNumber, ScrcpyProfile FROM v_headsets ORDER BY SortOrder;')
        $dbRows = @($dbRows | Where-Object { $_.IPAddress })
        if ($dbRows.Count -gt 0) { return $dbRows }
    } catch { }

    # Fallback for a dev folder with no readable database: the CSV export.
    $csv = Join-Path $DevRoot 'data\known_headsets.csv'
    if (-not (Test-Path -LiteralPath $csv)) { return @() }

    try {
        return @(Import-Csv -LiteralPath $csv -Encoding UTF8 | Where-Object { $_.IPAddress })
    }
    catch {
        return @()
    }
}

function Test-NrtHeadsetReachable {
    <#
    .SYNOPSIS
        Returns $true when the headset answers ping AND has the ADB port open.

    .DESCRIPTION
        Both checks matter: ping alone passes for a headset that is awake but has
        wireless ADB switched off, and scrcpy cannot attach to that.

    .EXAMPLE
        if (Test-NrtHeadsetReachable -IPAddress '10.0.0.5' -AdbPort 5555) { ... }
    #>
    param(
        [Parameter(Mandatory = $true)][string]$IPAddress,
        [int]$AdbPort = 5555,
        [int]$TimeoutMs = 1500,
        # When a serial is given the headset is identified, not just the address: classic OR TLS
        # is accepted and the answering device must report this serial (Find-NrtHeadsetEndpoint).
        # Without a serial this is the old ping + classic-port probe (identity is NOT verified).
        [string]$Serial = ''
    )

    if ($Serial) {
        return [bool](Find-NrtHeadsetEndpoint -IPAddress $IPAddress -Serial $Serial -AdbPort $AdbPort -TimeoutMs $TimeoutMs).Ok
    }

    $ping = $false
    try { $ping = Test-Connection -ComputerName $IPAddress -Count 1 -Quiet -ErrorAction SilentlyContinue } catch { }
    if (-not $ping) { return $false }

    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        return $client.ConnectAsync($IPAddress, $AdbPort).Wait($TimeoutMs)
    }
    catch { return $false }
    finally { if ($client) { try { $client.Close() } catch { } } }
}

# ---------------------------------------------------------------------------
# Mode-aware, serial-verified reachability (classic 5555 OR ADB over TLS)
#
# The app picks whichever WiFi ADB mode answers, so the tests do not care about the mode. The
# harness used to probe the classic port only, which skipped every hardware test for a headset
# that is reachable over TLS. Several headsets share the lab network and the mDNS address of a TLS
# service is unreliable (it is derived from a host name devices share), so identity is the SERIAL:
# a headset counts as reachable only when an endpoint answers adb and reports ro.serialno equal to
# the registry serial.
# ---------------------------------------------------------------------------

function Get-NrtAdbPath {
    <#
    .SYNOPSIS
        The release's own adb.exe (sandbox config, else the shipped template), or '' when not found.
    .EXAMPLE
        $adb = Get-NrtAdbPath
    #>
    param([string]$TargetRoot = '')
    if ($script:NrtAdbPathMemo -and (Test-Path -LiteralPath $script:NrtAdbPathMemo)) { return $script:NrtAdbPathMemo }
    if (-not $TargetRoot -and $global:TestRun) { $TargetRoot = [string]$global:TestRun.TargetRoot }
    if (-not $TargetRoot) { return '' }
    try {
        $paths   = Get-SandboxPaths -TargetRoot $TargetRoot
        $cfgPath = if (Test-Path -LiteralPath $paths.ConfigFile) { $paths.ConfigFile } else { $paths.TemplateConfig }
        $cfg     = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $adb     = Join-Path (Join-Path $paths.SourcesFolder ([string]$cfg.ADB.folder)) 'adb.exe'
        if (Test-Path -LiteralPath $adb) { $script:NrtAdbPathMemo = $adb; return $adb }
    } catch { }
    return ''
}

function Invoke-NrtAdb {
    <#
    .SYNOPSIS
        Runs the release's adb.exe with a hard time limit. Returns @{Ok;ExitCode;Out}. Never throws
        (the harness runs with ErrorActionPreference Stop, so adb's stderr must not leak).
    .EXAMPLE
        $r = Invoke-NrtAdb -Arguments @('-s', '10.0.0.5:5555', 'shell', 'getprop', 'ro.serialno')
    #>
    param([Parameter(Mandatory = $true)][string[]]$Arguments, [int]$TimeoutMs = 8000)
    $adb = Get-NrtAdbPath
    if (-not $adb) { return @{ Ok = $false; ExitCode = -1; Out = '' } }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $adb
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow = $true
    $psi.Arguments = (@($Arguments | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } })) -join ' '
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    try {
        [void]$p.Start()
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit($TimeoutMs)) { try { $p.Kill() } catch { }; return @{ Ok = $false; ExitCode = -2; Out = '' } }
        $null = $errTask.Result
        return @{ Ok = ($p.ExitCode -eq 0); ExitCode = $p.ExitCode; Out = [string]$outTask.Result }
    }
    catch { return @{ Ok = $false; ExitCode = -1; Out = '' } }
    finally { try { $p.Dispose() } catch { } }
}

function ConvertFrom-NrtMdnsServices {
    <#
    .SYNOPSIS
        Parses `adb mdns services` into @(@{Serial;Ip;Port}) for the _adb-tls-connect lines. The
        instance name is adb-<serial>-<random>, so the serial comes from the name, not from the
        (unreliable) address. Pure; @() on empty input.
    .EXAMPLE
        ConvertFrom-NrtMdnsServices -Text "adb-2G0YC5ZG1W00ZJ-XUIVEi`t_adb-tls-connect._tcp`t192.168.1.243:45539"
    #>
    param([string]$Text)
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($line in @(([string]$Text) -split "`r?`n")) {
        if ($line -match '^\s*adb-(?<s>.+)-(?<r>[^-\s]+)\s+_adb-tls-connect\._tcp\.?\s+(?<ip>\d{1,3}(?:\.\d{1,3}){3}):(?<p>\d+)') {
            $serial = $Matches['s']; $ip = $Matches['ip']; $port = [int]$Matches['p']
            if (-not ($out | Where-Object { $_.Serial -eq $serial -and $_.Ip -eq $ip -and $_.Port -eq $port })) {
                $out.Add([PSCustomObject]@{ Serial = $serial; Ip = $ip; Port = $port })
            }
        }
    }
    return $out.ToArray()
}

function Get-NrtTlsServices {
    <#
    .SYNOPSIS
        The headsets advertising ADB over TLS right now (one `adb mdns services`, memoised 2 s).
    .EXAMPLE
        @(Get-NrtTlsServices) | Where-Object Serial -eq '2G0YC5ZG1W00ZJ'
    #>
    if ($script:NrtTlsMemo -and ((Get-Date) - $script:NrtTlsMemoAt).TotalSeconds -lt 2) { return $script:NrtTlsMemo }
    $r = Invoke-NrtAdb -Arguments @('mdns', 'services') -TimeoutMs 8000
    $svc = @(ConvertFrom-NrtMdnsServices -Text $r.Out)
    $script:NrtTlsMemo = $svc
    $script:NrtTlsMemoAt = Get-Date
    return $svc
}

function Test-NrtAdbSerial {
    <#
    .SYNOPSIS
        $true when adb connected to -Target ("ip:port") reports ro.serialno equal to -Serial.
    .EXAMPLE
        Test-NrtAdbSerial -Target '10.0.0.5:5555' -Serial '2G0YC5ZG1W00ZJ'
    #>
    param([Parameter(Mandatory = $true)][string]$Target, [Parameter(Mandatory = $true)][string]$Serial)
    [void](Invoke-NrtAdb -Arguments @('connect', $Target) -TimeoutMs 8000)
    $r = Invoke-NrtAdb -Arguments @('-s', $Target, 'shell', 'getprop', 'ro.serialno') -TimeoutMs 8000
    if (-not $r.Ok) { return $false }
    return (([string]$r.Out).Trim() -ieq $Serial.Trim())
}

function Find-NrtHeadsetEndpoint {
    <#
    .SYNOPSIS
        Finds how a headset can be reached over WiFi ADB, verified by serial. Returns
        @{Ok;Mode (Classic|TLS);Target (ip:port);Serial;Verified;Reason}.

    .DESCRIPTION
        1. classic: the registry address on the classic port, accepted only when ADB there reports
           this serial (a different headset on that address is "serial mismatch", never reachable);
        2. TLS: every _adb-tls-connect service whose instance name carries this serial, tried on the
           registry address and on the address mDNS reports, accepted only on a serial match.
        An empty -Serial cannot be verified: only the classic port is probed and the result says so.

    .EXAMPLE
        $e = Find-NrtHeadsetEndpoint -IPAddress '10.0.0.5' -Serial '2G0YC5ZG1W00ZJ'
        if ($e.Ok) { "{0} at {1}" -f $e.Mode, $e.Target }
    #>
    param(
        [Parameter(Mandatory = $true)][string]$IPAddress,
        [string]$Serial = '',
        [int]$AdbPort = 5555,
        [int]$TimeoutMs = 1500
    )
    $res = { param($ok, $mode, $target, $verified, $reason) [PSCustomObject]@{ Ok = $ok; Mode = $mode; Target = $target; Serial = $Serial; Verified = $verified; Reason = $reason } }

    $classicOpen = $false
    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $classicOpen = [bool]$client.ConnectAsync($IPAddress, $AdbPort).Wait($TimeoutMs)
    } catch { $classicOpen = $false } finally { if ($client) { try { $client.Close() } catch { } } }

    if (-not $Serial) {
        if ($classicOpen) { return (& $res $true 'Classic' ("{0}:{1}" -f $IPAddress, $AdbPort) $false 'serial unknown, identity not verified') }
        return (& $res $false '' '' $false 'classic port closed and no serial to look for a TLS service')
    }

    $mismatch = $false
    if ($classicOpen) {
        $t = "{0}:{1}" -f $IPAddress, $AdbPort
        if (Test-NrtAdbSerial -Target $t -Serial $Serial) { return (& $res $true 'Classic' $t $true 'serial verified') }
        $mismatch = $true
    }
    foreach ($s in @(Get-NrtTlsServices | Where-Object { $_.Serial -ieq $Serial })) {
        foreach ($ip in @($IPAddress, $s.Ip | Select-Object -Unique)) {
            $t = "{0}:{1}" -f $ip, $s.Port
            if (Test-NrtAdbSerial -Target $t -Serial $Serial) { return (& $res $true 'TLS' $t $true 'serial verified') }
        }
    }
    # 3. USB: the serial itself is the adb id of a cabled headset (no ':' and not an mDNS 'adb-' id).
    $dev = Invoke-NrtAdb -Arguments @('devices') -TimeoutMs 6000
    foreach ($line in @(([string]$dev.Out) -split "`r?`n")) {
        if ($line -match '^(?<id>[^\s:]+)\s+device\b' -and $Matches['id'] -ieq $Serial.Trim() -and $Matches['id'] -notlike 'adb-*') {
            return (& $res $true 'USB' $Serial.Trim() $true 'serial verified (cabled)')
        }
    }
    if ($mismatch) { return (& $res $false '' '' $false 'another device answers on the classic port (serial mismatch)') }
    return (& $res $false '' '' $false 'no classic answer, no TLS service and no USB link for this serial')
}

function Wait-NrtCandidatesReachable {
    <#
    .SYNOPSIS
        Grace-window poll: re-probes -Candidates every ~2s for -TimeoutSec and
        returns whichever ones answer ping + ADB port before the window closes.

    .DESCRIPTION
        Used right after the operator confirms a physical action ("plugged it
        in"), since WiFi ADB can take a few seconds to come back after
        power-on / USB-plug - a single immediate re-probe would often still
        see the headset as down and force a needless extra prompt round-trip.

    .EXAMPLE
        $reachable = Wait-NrtCandidatesReachable -Candidates $candidates -AdbPort 5555 -TimeoutSec 20
    #>
    param(
        [Parameter(Mandatory = $true)]$Candidates,
        [int]$AdbPort = 5555,
        [int]$TimeoutSec = 20
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ($true) {
        $reachable = @($Candidates | Where-Object { Test-NrtHeadsetReachable -IPAddress $_.IPAddress -AdbPort $AdbPort -Serial ([string]$_.SerialNumber) })
        if ($reachable.Count -gt 0) { return $reachable }
        if ((Get-Date) -ge $deadline) { return @() }
        Start-Sleep -Seconds 2
    }
}

function Invoke-NrtShutdownHeadsets {
    <#
    .SYNOPSIS
        Powers off every headset adb can reach (end of an unattended run, -ShutdownHeadsetsAtEnd).
        Returns @(@{Serial;Model;Target;Ok;Detail}).

    .DESCRIPTION
        The sandbox registry is empty at the end of a run, so the app's /api/shutdown-all would
        reach nothing: the harness drives adb itself, with the release's own adb.exe (from the
        sandbox config, else the template). One `adb devices` listing; each transport is
        identified by ro.serialno so a headset seen both on USB and WiFi is powered off ONCE
        (USB preferred); only Quest / Pico devices are touched (a phone on the bench is left
        alone). `reboot -p` per headset with a 15 s cap. Must run BEFORE the app is stopped:
        the app's shutdown ends this install's adb server. Never throws.

    .EXAMPLE
        Invoke-NrtShutdownHeadsets -TargetRoot $target
    #>
    param([Parameter(Mandatory = $true)][string]$TargetRoot)

    $out = New-Object System.Collections.Generic.List[object]
    # The harness runs with 'Stop': adb's stderr ("daemon not running; starting now") would
    # become a terminating error. This runs after the app stopped its adb server.
    $ErrorActionPreference = 'Continue'
    try {
        $paths = Get-SandboxPaths -TargetRoot $TargetRoot
        $cfgPath = if (Test-Path -LiteralPath $paths.ConfigFile) { $paths.ConfigFile } else { $paths.TemplateConfig }
        $cfg = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $adb = Join-Path (Join-Path $paths.SourcesFolder ([string]$cfg.ADB.folder)) 'adb.exe'
        if (-not (Test-Path -LiteralPath $adb)) {
            $out.Add([PSCustomObject]@{ Serial = ''; Model = ''; Target = ''; Ok = $false; Detail = "adb.exe not found: $adb" })
            return $out.ToArray()
        }
        & $adb start-server 2>&1 | Out-Null
        $ids = @(& $adb devices 2>$null | Where-Object { $_ -match '^(\S+)\s+device$' } | ForEach-Object { ($_ -split '\s+')[0] })
        $bySerial = @{}
        foreach ($id in $ids) {
            $serial = ([string](& $adb -s $id shell getprop ro.serialno 2>$null | Select-Object -First 1)).Trim()
            $model  = ([string](& $adb -s $id shell getprop ro.product.model 2>$null | Select-Object -First 1)).Trim()
            $brand  = ([string](& $adb -s $id shell getprop ro.product.brand 2>$null | Select-Object -First 1)).Trim()
            if (-not $serial) { continue }
            if (("{0} {1}" -f $brand, $model) -notmatch '(?i)quest|oculus|meta|pico') { continue }
            $isUsb = ($id -notmatch ':')
            if (-not $bySerial.ContainsKey($serial) -or ($isUsb -and $bySerial[$serial].Target -match ':')) {
                $bySerial[$serial] = @{ Target = $id; Model = $model }
            }
        }
        foreach ($serial in $bySerial.Keys) {
            $t = $bySerial[$serial]
            $ok = $false; $detail = ''
            try {
                $p = Start-Process -FilePath $adb -ArgumentList @('-s', $t.Target, 'shell', 'reboot', '-p') -PassThru -WindowStyle Hidden
                if ($p.WaitForExit(15000)) { $ok = $true; $detail = 'power-off sent' }
                else { try { $p.Kill() } catch { }; $detail = 'timeout' }
            } catch { $detail = $_.Exception.Message }
            $out.Add([PSCustomObject]@{ Serial = $serial; Model = $t.Model; Target = $t.Target; Ok = $ok; Detail = $detail })
        }
    } catch {
        $out.Add([PSCustomObject]@{ Serial = ''; Model = ''; Target = ''; Ok = $false; Detail = $_.Exception.Message })
    }
    return $out.ToArray()
}

function Invoke-NrtEnableUsbWifiAdb {
    <#
    .SYNOPSIS
        Bridges a USB-connected headset onto WiFi ADB via POST /api/enablewifiadb.
        Returns @{ Ip; Model; Port } on success, $null otherwise (including when
        nothing is on USB - this is a safe, harmless no-op in that case).

    .DESCRIPTION
        Plugging a headset into USB does NOT by itself make it answer on its
        WiFi IP:port - that only happens once wireless ADB (tcpip mode) is
        enabled, and a headset that went to sleep drops that mode. The app's
        own automatic USB onboarding (Invoke-UsbHeadsetActions, run every
        VRMonitor cycle) only re-enables it for a headset already present in
        THAT app instance's known_headsets.csv - which is empty in the sandbox
        at this point, since sections 50/60 only add the headset once one is
        resolved (the exact chicken-and-egg this helper breaks). This calls the
        same underlying action (Enable-AdbTcpIp, via the public API an operator
        would use in the web UI) directly, independent of any registry match.

    .EXAMPLE
        $bridged = Invoke-NrtEnableUsbWifiAdb
        if ($bridged) { Write-Host ("USB bridge: {0} -> {1}" -f $bridged.Model, $bridged.Ip) }
    #>
    try {
        $r = Invoke-VrmApi -Path '/api/enablewifiadb' -Method POST -TimeoutSec 20
        if ($r.Ok -and $r.Json -and $r.Json.ok -and $r.Json.ip) {
            return @{ Ip = [string]$r.Json.ip; Model = [string]$r.Json.model; Port = $r.Json.port }
        }
    }
    catch { }
    return $null
}

function Resolve-NrtTestHeadset {
    <#
    .SYNOPSIS
        Picks the headset sections 50/60 will drive, or returns $null.

    .DESCRIPTION
        Order of precedence:
          1. -HeadsetName on the command line wins outright (still probed)
          2. otherwise every dev-registry headset is probed, and:
               - exactly one reachable  -> used
               - several reachable      -> operator picks in Manual mode,
                                           first one in Auto/Unattended
               - none reachable         -> see below

        When nothing answers ping + ADB port, Invoke-NrtEnableUsbWifiAdb is
        tried first, silently: a headset can be sitting right there on USB
        with WiFi ADB simply not (yet) re-enabled since it went to sleep, and
        this resolves that without ever bothering the operator (a harmless
        no-op when nothing is on USB).

        If that does not help and the dev registry is NOT empty (this
        operator's machine legitimately has headsets configured, so this
        looks like "unplugged right now" rather than "no hardware ever"), and
        the run is not -Unattended, the operator is asked via
        Wait-OperatorAction to connect the headset (power/USB if it went to
        sleep, same WiFi network). Each confirmation re-tries the USB bridge
        and then the probe after a grace window (Wait-NrtCandidatesReachable).
        This repeats - re-asking each time - until either a headset becomes
        reachable or the operator chooses [S] to skip.

        A dev registry with zero rows, or an -Unattended run, never prompts:
        $null comes back immediately and the caller SKIPs. That is deliberate
        - a machine with no headset configured at all (CI, another dev's
        box) must stay green and silent.

    .EXAMPLE
        $headset = Resolve-NrtTestHeadset -DevRoot $devRoot -AdbPort 5555
        if (-not $headset) { Skip-Test 'no reachable headset' }
    #>
    param(
        [Parameter(Mandatory = $true)][string]$DevRoot,
        [int]$AdbPort = 5555
    )

    # -NoHeadset: nothing is connected, so do not probe, bridge USB or prompt.
    if ($global:TestRun -and $global:TestRun.NoHeadset) { return $null }

    $candidates = @(Get-NrtDevHeadsets -DevRoot $DevRoot)
    if ($candidates.Count -eq 0) { return $null }

    $requested = ''
    if ($global:TestRun -and $global:TestRun.HeadsetName) { $requested = $global:TestRun.HeadsetName }

    if ($requested) {
        $match = $candidates | Where-Object { $_.Name -eq $requested } | Select-Object -First 1
        if (-not $match) { return $null }
        $pool = @($match)
    }
    else {
        $pool = $candidates
    }

    # Mode-aware and serial-verified: classic OR TLS, and the answering device must carry the
    # registry serial (several headsets share the network). A row with no serial falls back to
    # the old classic-port probe.
    $reachable = @($pool | Where-Object { Test-NrtHeadsetReachable -IPAddress $_.IPAddress -AdbPort $AdbPort -Serial ([string]$_.SerialNumber) })

    # Silent pre-check: a headset can already be sitting on USB (or was just
    # plugged in a moment ago) with its WiFi ADB not (yet) enabled. Bridging it
    # here can resolve reachability without ever bothering the operator - the
    # call is a harmless no-op when nothing is on USB.
    if ($reachable.Count -eq 0) {
        $bridged = Invoke-NrtEnableUsbWifiAdb
        if ($bridged) {
            Write-Host ("  USB bridge: {0} is now on WiFi ADB at {1}:{2}" -f $bridged.Model, $bridged.Ip, $bridged.Port) -ForegroundColor DarkGray
            $reachable = @($pool | Where-Object { Test-NrtHeadsetReachable -IPAddress $_.IPAddress -AdbPort $AdbPort -Serial ([string]$_.SerialNumber) })
        }
    }

    $unattended = ($global:TestRun -and $global:TestRun.Unattended)
    $firstPrompt = $true
    while ($reachable.Count -eq 0 -and -not $unattended) {
        $names = ($pool | ForEach-Object { "$($_.Name) ($($_.IPAddress))" }) -join ', '
        if ($firstPrompt) {
            $message = "No headset answered ping + ADB port $AdbPort. Connect it - plug in USB power/cable if it went to sleep, and make sure it is on the same WiFi network - then press Enter to retry."
        } else {
            $message = "Still not reachable. Keep checking the connection (USB power, WiFi) and press Enter to retry."
        }
        $firstPrompt = $false

        $confirmed = Wait-OperatorAction -Message $message -Hint ("candidate(s): {0}" -f $names)
        if (-not $confirmed) { return $null }

        # Re-attempt the USB bridge every round: the operator may have just
        # plugged the cable in response to this very prompt.
        $bridged = Invoke-NrtEnableUsbWifiAdb
        if ($bridged) {
            Write-Host ("  USB bridge: {0} is now on WiFi ADB at {1}:{2}" -f $bridged.Model, $bridged.Ip, $bridged.Port) -ForegroundColor DarkGray
        }

        $reachable = @(Wait-NrtCandidatesReachable -Candidates $pool -AdbPort $AdbPort -TimeoutSec 20)
    }

    if ($reachable.Count -eq 0) { return $null }
    if ($reachable.Count -eq 1) { return (Add-NrtReachNote -Headset $reachable[0] -AdbPort $AdbPort) }

    $interactive = $true
    if ($global:TestRun -and $global:TestRun.Unattended) { $interactive = $false }
    if ($global:TestRun -and $global:TestRun.Mode -eq 'Auto') { $interactive = $false }

    if (-not $interactive) { return (Add-NrtReachNote -Headset $reachable[0] -AdbPort $AdbPort) }

    $picked = Select-TestHeadset -Candidates @($reachable | ForEach-Object { $_.Name })
    return (Add-NrtReachNote -Headset ($reachable | Where-Object { $_.Name -eq $picked } | Select-Object -First 1) -AdbPort $AdbPort)
}

function Add-NrtReachNote {
    <#
    .SYNOPSIS
        Stamps the chosen headset row with how it was reached (ReachMode Classic|TLS, ReachTarget
        ip:port, ReachVerified) and prints one line, so a report shows which headset and which WiFi
        ADB mode a hardware section ran on. Returns the row.
    .EXAMPLE
        $row = Add-NrtReachNote -Headset $row
    #>
    param($Headset, [int]$AdbPort = 5555)
    if (-not $Headset) { return $Headset }
    $e = Find-NrtHeadsetEndpoint -IPAddress ([string]$Headset.IPAddress) -Serial ([string]$Headset.SerialNumber) -AdbPort $AdbPort
    Add-Member -InputObject $Headset -NotePropertyName ReachMode     -NotePropertyValue ([string]$e.Mode)     -Force
    Add-Member -InputObject $Headset -NotePropertyName ReachTarget   -NotePropertyValue ([string]$e.Target)   -Force
    Add-Member -InputObject $Headset -NotePropertyName ReachVerified -NotePropertyValue ([bool]$e.Verified)   -Force
    Write-Host ("  Test headset: {0} (serial {1}) reached over {2} at {3}{4}" -f $Headset.Name, $Headset.SerialNumber, $(if ($e.Mode) { $e.Mode } else { '?' }), $e.Target, $(if ($e.Verified) { ', identity verified' } else { ', identity NOT verified' })) -ForegroundColor DarkGray
    return $Headset
}

function ConvertTo-NrtSafeName {
    <#
    .SYNOPSIS
        Mirrors the app's Convert-Displayname: spaces become underscores.
        This is the scrcpy window title and the per-headset file-name stem.
    #>
    param([Parameter(Mandatory = $true)][string]$Name)
    return ($Name -replace ' ', '_')
}

function ConvertTo-NrtStreamPath {
    <#
    .SYNOPSIS
        Mirrors the app's ConvertTo-RestreamPathName: safe name, lowercased.
        This is the mediamtx path a headset publishes to.
    #>
    param([Parameter(Mandatory = $true)][string]$Name)
    return (ConvertTo-NrtSafeName -Name $Name).ToLower()
}

# ---------------------------------------------------------------------------
# Sandbox registry helpers
# ---------------------------------------------------------------------------

function Add-NrtSandboxHeadset {
    <#
    .SYNOPSIS
        Imports one real headset into the sandbox registry through the public API.

    .EXAMPLE
        Add-NrtSandboxHeadset -Headset $headset
    #>
    param([Parameter(Mandatory = $true)]$Headset)

    $body = @{
        name         = $Headset.Name
        ip           = $Headset.IPAddress
        model        = $Headset.Model
        serialNumber = $Headset.SerialNumber
    }
    $r = Invoke-VrmApi -Path '/api/addheadset' -Method POST -Body $body
    return $r
}

function Get-NrtSandboxHeadset {
    <#
    .SYNOPSIS
        Returns the SANDBOX's registry row for a headset (via /api/headsets), or $null.

    .DESCRIPTION
        Use this - not the dev-registry row - whenever a test asserts against
        what the app is actually configured to do. /api/addheadset assigns its
        own DEFAULT scrcpy profile and ignores any profile in the request, so the
        two registries disagree the moment a headset is imported.

    .EXAMPLE
        $row = Get-NrtSandboxHeadset -Name 'Q3 RED'
        Assert-Equal $row.ScrcpyProfile $observedProfile 'cmdline profile'
    #>
    param([Parameter(Mandatory = $true)][string]$Name)

    $r = Invoke-VrmApi -Path '/api/headsets'
    if (-not $r.Ok -or -not $r.Json) { return $null }
    return (@($r.Json) | Where-Object { $_.Name -eq $Name } | Select-Object -First 1)
}

function Set-NrtScrcpyProfile {
    <#
    .SYNOPSIS
        Sets a headset's scrcpy profile in the sandbox registry.

    .EXAMPLE
        Set-NrtScrcpyProfile -Name 'Q3 RED' -Profile 'max-R-N-60-5'
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Profile
    )

    $safe = ConvertTo-NrtSafeName -Name $Name
    return (Invoke-VrmApi -Path '/api/updateprofile' -Method POST -Body @{ name = $safe; profile = $Profile })
}

function Set-NrtAutoRestart {
    <#
    .SYNOPSIS
        Enables or disables scrcpy auto-restart, which is how the app is told to
        start or stop streaming a headset.

    .EXAMPLE
        Set-NrtAutoRestart -Name 'Q3 RED' -Enabled $true
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][bool]$Enabled
    )

    $safe = ConvertTo-NrtSafeName -Name $Name
    return (Invoke-VrmApi -Path '/api/autorestart' -Method POST -Body @{ name = $safe; value = $Enabled })
}

function Wait-NrtHeadsetAdb {
    <#
    .SYNOPSIS
        Waits until VRMonitor reports ADBWifi = true for a headset.

    .DESCRIPTION
        Watch-ScrcpyProcesses will not launch scrcpy before this is true, so
        every streaming test has to await it first. Reads the app's own live
        status file (semicolon-delimited, per CLAUDE.md).

    .EXAMPLE
        Assert-True (Wait-NrtHeadsetAdb -TargetRoot $target -Name 'Q3 RED' -TimeoutSec 90) 'ADB never came up'
    #>
    param(
        [Parameter(Mandatory = $true)][string]$TargetRoot,
        [Parameter(Mandatory = $true)][string]$Name,
        [int]$TimeoutSec = 90
    )

    $paths    = Get-SandboxPaths -TargetRoot $TargetRoot
    $deadline = (Get-Date).AddSeconds($TimeoutSec)

    while ((Get-Date) -lt $deadline) {
        $row = Get-SandboxHeadsetInfoRow -TargetRoot $TargetRoot -Name $Name
        if ($row -and ("$($row.ADBWifi)" -match '^(True|true|1)$')) { return $true }
        Start-Sleep -Milliseconds 1000
    }
    return $false
}

# ---------------------------------------------------------------------------
# scrcpy process helpers
# ---------------------------------------------------------------------------

function Get-NrtScrcpyProcess {
    <#
    .SYNOPSIS
        Finds the scrcpy process for one headset, restricted to binaries that
        live under the TARGET release folder.

    .DESCRIPTION
        The path restriction is the point: it proves the RELEASE's scrcpy is what
        is running, and stops a stray scrcpy launched from the dev folder (or by
        the operator's own session) from making a test pass.

        Matches the app's own Get-ScrcpyProcess strategy - window title first,
        command line as the fallback for windows on inactive virtual desktops.

    .EXAMPLE
        $p = Get-NrtScrcpyProcess -TargetRoot $target -Name 'Q3 RED' -IPAddress '10.0.0.5'
    #>
    param(
        [Parameter(Mandatory = $true)][string]$TargetRoot,
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$IPAddress = ''
    )

    $safe  = ConvertTo-NrtSafeName -Name $Name
    $root  = [System.IO.Path]::GetFullPath($TargetRoot).TrimEnd('\')
    $procs = @(Get-Process -Name 'scrcpy' -ErrorAction SilentlyContinue | Where-Object {
        $p = ''
        try { $p = $_.Path } catch { }
        $p -and $p.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)
    })
    if ($procs.Count -eq 0) { return $null }

    $byTitle = $procs | Where-Object { $_.MainWindowTitle -eq $safe } | Select-Object -First 1
    if ($byTitle) { return $byTitle }

    foreach ($proc in $procs) {
        $cmdLine = ''
        try {
            $cim = Get-CimInstance Win32_Process -Filter ("ProcessId = {0}" -f $proc.Id) -ErrorAction SilentlyContinue
            if ($cim) { $cmdLine = [string]$cim.CommandLine }
        }
        catch { }
        if (-not $cmdLine) { continue }
        if ($IPAddress -and $cmdLine -match [regex]::Escape($IPAddress)) { return $proc }
        if ($cmdLine -match [regex]::Escape($safe)) { return $proc }
    }
    return $null
}

function Get-NrtProcessCommandLine {
    <#
    .SYNOPSIS
        Returns a process's full command line, or '' when it cannot be read.
    #>
    param([Parameter(Mandatory = $true)][int]$ProcessId)

    try {
        $cim = Get-CimInstance Win32_Process -Filter ("ProcessId = {0}" -f $ProcessId) -ErrorAction SilentlyContinue
        if ($cim) { return [string]$cim.CommandLine }
    }
    catch { }
    return ''
}

function Wait-NrtScrcpy {
    <#
    .SYNOPSIS
        Waits for a headset's scrcpy process to appear (-Running) or disappear
        (-Running:$false). Returns the process object, or $null on timeout.

    .EXAMPLE
        $proc = Wait-NrtScrcpy -TargetRoot $target -Name 'Q3 RED' -IPAddress $ip -Running $true -TimeoutSec 90
    #>
    param(
        [Parameter(Mandatory = $true)][string]$TargetRoot,
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$IPAddress = '',
        [bool]$Running = $true,
        [int]$TimeoutSec = 90
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $proc = Get-NrtScrcpyProcess -TargetRoot $TargetRoot -Name $Name -IPAddress $IPAddress
        if ($Running -and $proc) { return $proc }
        if ((-not $Running) -and (-not $proc)) { return $null }
        Start-Sleep -Milliseconds 1000
    }

    if ($Running) { return $null }
    return (Get-NrtScrcpyProcess -TargetRoot $TargetRoot -Name $Name -IPAddress $IPAddress)
}

# ---------------------------------------------------------------------------
# mediamtx stream health
# ---------------------------------------------------------------------------

function Get-NrtMediaMtxPaths {
    <#
    .SYNOPSIS
        GET /v3/paths/list against the sandbox mediamtx API. Returns the items
        array, or @() when mediamtx is unreachable.

    .EXAMPLE
        $paths = Get-NrtMediaMtxPaths -ApiPort 9997
    #>
    param(
        [int]$ApiPort = 9997,
        [int]$TimeoutSec = 5
    )

    try {
        $resp = Invoke-RestMethod -Uri ("http://127.0.0.1:{0}/v3/paths/list" -f $ApiPort) `
                                  -Method GET -TimeoutSec $TimeoutSec -ErrorAction Stop
        if ($resp -and $resp.items) { return @($resp.items) }
        return @()
    }
    catch { return @() }
}

function Get-NrtMediaMtxPath {
    <#
    .SYNOPSIS
        Returns the single mediamtx path entry for a headset, or $null.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$PathName,
        [int]$ApiPort = 9997
    )
    return (Get-NrtMediaMtxPaths -ApiPort $ApiPort | Where-Object { $_.name -eq $PathName } | Select-Object -First 1)
}

function Wait-NrtStreamReady {
    <#
    .SYNOPSIS
        Waits for a mediamtx path to exist and report ready = true.

    .EXAMPLE
        Assert-True (Wait-NrtStreamReady -PathName 'q3_red' -ApiPort 9997 -TimeoutSec 60) 'stream never became ready'
    #>
    param(
        [Parameter(Mandatory = $true)][string]$PathName,
        [int]$ApiPort = 9997,
        [int]$TimeoutSec = 60
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $p = Get-NrtMediaMtxPath -PathName $PathName -ApiPort $ApiPort
        if ($p -and $p.ready) { return $true }
        Start-Sleep -Milliseconds 1000
    }
    return $false
}

function Test-NrtStreamStable {
    <#
    .SYNOPSIS
        The core streaming assertion: N seconds of genuinely flowing video.

    .DESCRIPTION
        Samples /v3/paths/list once a second for -Seconds and requires all of:
          - the path exists in every sample
          - ready = true in every sample (no flap / republish mid-window)
          - bytesReceived never goes backwards
          - at most -AllowedStalls intervals show no growth (mediamtx updates its
            counters lazily, so demanding growth in every single interval is
            flaky; demanding it in nearly all of them is not)
          - average throughput >= -MinKbps, which separates a live video stream
            from a path that is merely open and dribbling keepalives

        Returns a result object rather than throwing, so the caller decides the
        verdict and can attach the numbers as evidence:
          @{ Stable; Reason; Samples; Seconds; TotalBytes; AvgKbps; Stalls;
             ReadyAlways; FirstBytes; LastBytes }

    .EXAMPLE
        $s = Test-NrtStreamStable -PathName 'q3_red' -ApiPort 9997 -Seconds 15
        Assert-True $s.Stable $s.Reason
    #>
    param(
        [Parameter(Mandatory = $true)][string]$PathName,
        [int]$ApiPort = 9997,
        [int]$Seconds = 15,
        [int]$AllowedStalls = 1,
        [int]$MinKbps = 100
    )

    $samples     = @()
    $readyAlways = $true
    $missing     = $false

    for ($i = 0; $i -lt $Seconds; $i++) {
        $p = Get-NrtMediaMtxPath -PathName $PathName -ApiPort $ApiPort
        if (-not $p) {
            $missing = $true
            $samples += [PSCustomObject]@{ At = Get-Date; Bytes = -1; Ready = $false }
        }
        else {
            if (-not $p.ready) { $readyAlways = $false }
            $bytes = 0
            if ($null -ne $p.bytesReceived) { $bytes = [int64]$p.bytesReceived }
            $samples += [PSCustomObject]@{ At = Get-Date; Bytes = $bytes; Ready = [bool]$p.ready }
        }
        if ($i -lt ($Seconds - 1)) { Start-Sleep -Milliseconds 1000 }
    }

    $result = [PSCustomObject]@{
        Stable      = $false
        Reason      = ''
        Samples     = $samples.Count
        Seconds     = $Seconds
        TotalBytes  = 0
        AvgKbps     = 0
        Stalls      = 0
        ReadyAlways = $readyAlways
        FirstBytes  = 0
        LastBytes   = 0
    }

    if ($missing) {
        $result.Reason = ("mediamtx path '{0}' disappeared during the {1}s window" -f $PathName, $Seconds)
        return $result
    }
    if (-not $readyAlways) {
        $result.Reason = ("mediamtx path '{0}' was not ready for the whole {1}s window" -f $PathName, $Seconds)
        return $result
    }

    $result.FirstBytes = $samples[0].Bytes
    $result.LastBytes  = $samples[-1].Bytes
    $result.TotalBytes = $result.LastBytes - $result.FirstBytes

    $stalls = 0
    for ($i = 1; $i -lt $samples.Count; $i++) {
        $delta = $samples[$i].Bytes - $samples[$i - 1].Bytes
        if ($delta -lt 0) {
            $result.Reason = ("bytesReceived went backwards ({0} -> {1}) - the stream was republished mid-window" -f $samples[$i - 1].Bytes, $samples[$i].Bytes)
            return $result
        }
        if ($delta -eq 0) { $stalls++ }
    }
    $result.Stalls = $stalls

    $elapsed = ($samples[-1].At - $samples[0].At).TotalSeconds
    if ($elapsed -le 0) { $elapsed = 1 }
    $result.AvgKbps = [int](($result.TotalBytes * 8) / 1000 / $elapsed)

    if ($stalls -gt $AllowedStalls) {
        $result.Reason = ("stream stalled in {0} of {1} intervals (max allowed {2})" -f $stalls, ($samples.Count - 1), $AllowedStalls)
        return $result
    }
    if ($result.AvgKbps -lt $MinKbps) {
        $result.Reason = ("throughput {0} kbps is below the {1} kbps floor - path is open but not carrying video" -f $result.AvgKbps, $MinKbps)
        return $result
    }

    $result.Stable = $true
    $result.Reason = ("{0}s stable: {1} kbps, {2} bytes, {3} stall(s)" -f $Seconds, $result.AvgKbps, $result.TotalBytes, $stalls)
    return $result
}

function Get-NrtFfmpegPaths {
    <#
    .SYNOPSIS
        Resolves the sandbox's ffmpeg.exe and, if present, ffprobe.exe - the
        same folder Initialize-SandboxConfig seeds ffmpeg.exe into.

    .DESCRIPTION
        ffprobe.exe is not guaranteed to exist: only Update-FfmpegBinary
        extracts it (best-effort, since not every build variant ships it), so
        an ffmpeg folder copied in from an older download may not have it yet.
        Returns FfprobePath = $null in that case so callers can SKIP the
        content-verification check rather than fail.

    .EXAMPLE
        $ff = Get-NrtFfmpegPaths -TargetRoot $target
        if ($ff.FfprobePath) { & $ff.FfprobePath -version }
    #>
    param([Parameter(Mandatory = $true)][string]$TargetRoot)

    $paths  = Get-SandboxPaths -TargetRoot $TargetRoot
    $config = Read-JsonFileUtf8 -Path $paths.ConfigFile

    $ffmpegFolder = 'ffmpeg'
    if ($config -and $config.ffmpeg -and $config.ffmpeg.folder) { $ffmpegFolder = $config.ffmpeg.folder }

    $out = @{ FfmpegPath = $null; FfprobePath = $null }
    $ffmpegExe  = Join-Path (Join-Path $paths.SourcesFolder $ffmpegFolder) 'ffmpeg.exe'
    $ffprobeExe = Join-Path (Join-Path $paths.SourcesFolder $ffmpegFolder) 'ffprobe.exe'
    if (Test-Path -LiteralPath $ffmpegExe)  { $out.FfmpegPath  = $ffmpegExe }
    if (Test-Path -LiteralPath $ffprobeExe) { $out.FfprobePath = $ffprobeExe }
    return $out
}

function Test-NrtStreamContent {
    <#
    .SYNOPSIS
        Verifies the ACTUAL negotiated codec/resolution/fps of a live stream
        via ffprobe, rather than trusting mediamtx's byte counters alone.

    .DESCRIPTION
        Test-NrtStreamStable proves bytes are flowing; it cannot tell a valid
        H.264/HEVC bitstream from throughput-floor-clearing garbage pushed
        through the pipe at a steady rate. This runs ffprobe against the live
        RTSP url and parses the first video stream's codec/width/height/fps.

        Returns @{ Ok; Reason; Codec; Width; Height; Fps; RawJson } rather than
        throwing. Ok=$false with an informative Reason when ffprobe.exe is not
        available (see Get-NrtFfmpegPaths) - callers SKIP rather than fail.

    .EXAMPLE
        $c = Test-NrtStreamContent -FfprobePath $ff.FfprobePath -StreamUrl $rtspUrl -ExpectedCodec 'h264' -TargetFps 60
        Assert-True $c.Ok $c.Reason
    #>
    param(
        [string]$FfprobePath,
        [Parameter(Mandatory = $true)][string]$StreamUrl,
        # Empty when the caller cannot know the codec in advance (passthrough
        # mode ships the headset's own native codec, which varies by device) -
        # resolution/fps are still checked, just not codec equality.
        [string]$ExpectedCodec = '',
        [int]$TargetFps = 0
    )

    $result = [PSCustomObject]@{ Ok = $false; Reason = ''; Codec = ''; Width = 0; Height = 0; Fps = 0.0; RawJson = '' }

    if (-not $FfprobePath) {
        $result.Reason = 'ffprobe.exe not bundled next to ffmpeg.exe - re-run the ffmpeg update to pick it up, or copy it manually'
        return $result
    }

    $ffArgs = @('-v', 'quiet', '-print_format', 'json', '-show_streams', '-rtsp_transport', 'tcp', $StreamUrl)
    $output = ''
    try {
        $output = (& $FfprobePath @ffArgs 2>$null) -join "`n"
    }
    catch {
        $result.Reason = ("ffprobe failed to run: {0}" -f $_.Exception.Message)
        return $result
    }
    $result.RawJson = $output

    $parsed = $null
    try { $parsed = $output | ConvertFrom-Json } catch { }
    if (-not $parsed -or -not $parsed.streams) {
        $result.Reason = 'ffprobe returned no parseable stream information'
        return $result
    }

    $video = @($parsed.streams | Where-Object { $_.codec_type -eq 'video' } | Select-Object -First 1)
    if ($video.Count -eq 0) {
        $result.Reason = 'ffprobe reported no video stream'
        return $result
    }
    $v = $video[0]

    $result.Codec  = [string]$v.codec_name
    $result.Width  = [int]$v.width
    $result.Height = [int]$v.height
    $fpsVal = 0.0
    if ($v.r_frame_rate -and $v.r_frame_rate -match '^(\d+)/(\d+)$' -and [int]$Matches[2] -ne 0) {
        $fpsVal = [double]$Matches[1] / [double]$Matches[2]
    }
    $result.Fps = $fpsVal

    if ($ExpectedCodec) {
        # h265/hevc naming differs between the app's config value and ffprobe's codec_name.
        $codecMap = @{ h264 = 'h264'; h265 = 'hevc'; hevc = 'hevc' }
        $expected = $ExpectedCodec
        if ($codecMap.ContainsKey($ExpectedCodec)) { $expected = $codecMap[$ExpectedCodec] }

        if ($result.Codec -ne $expected) {
            $result.Reason = ("ffprobe reports codec '{0}', expected '{1}'" -f $result.Codec, $expected)
            return $result
        }
    }
    if ($result.Width -le 0 -or $result.Height -le 0) {
        $result.Reason = ("ffprobe reports implausible resolution {0}x{1}" -f $result.Width, $result.Height)
        return $result
    }
    if ($TargetFps -gt 0) {
        $tolerance = [math]::Max(3, $TargetFps * 0.2)
        if ([math]::Abs($result.Fps - $TargetFps) -gt $tolerance) {
            $result.Reason = ("ffprobe reports {0:N1} fps, expected close to {1}" -f $result.Fps, $TargetFps)
            return $result
        }
    }

    $result.Ok = $true
    $result.Reason = ("{0} {1}x{2} @ {3:N1}fps" -f $result.Codec, $result.Width, $result.Height, $result.Fps)
    return $result
}

function Save-NrtStreamFrame {
    <#
    .SYNOPSIS
        Grabs one JPEG frame from a live stream via the bundled ffmpeg - the
        visual proof a byte counter or ffprobe metadata check cannot provide.

    .DESCRIPTION
        Returns @{ Ok; Reason; Path; SizeBytes }. Never throws; a failed grab
        is reported through Ok=$false so the caller decides severity.

    .EXAMPLE
        $shot = Save-NrtStreamFrame -FfmpegPath $ff.FfmpegPath -StreamUrl $rtspUrl -OutPath $jpg
    #>
    param(
        [Parameter(Mandatory = $true)][string]$FfmpegPath,
        [Parameter(Mandatory = $true)][string]$StreamUrl,
        [Parameter(Mandatory = $true)][string]$OutPath,
        [int]$TimeoutSec = 20
    )

    $result = [PSCustomObject]@{ Ok = $false; Reason = ''; Path = $OutPath; SizeBytes = 0 }

    if (Test-Path -LiteralPath $OutPath) { Remove-Item -LiteralPath $OutPath -Force -ErrorAction SilentlyContinue }
    $destFolder = Split-Path -Parent $OutPath
    if (-not (Test-Path -LiteralPath $destFolder)) { New-Item -ItemType Directory -Path $destFolder -Force | Out-Null }

    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        $ffArgs = @('-y', '-rtsp_transport', 'tcp', '-i', $StreamUrl, '-frames:v', '1', '-q:v', '2', $OutPath)
        $proc = Start-Process -FilePath $FfmpegPath -ArgumentList $ffArgs -NoNewWindow -PassThru -RedirectStandardError $errFile
        if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
            try { $proc.Kill() } catch { }
            $result.Reason = ("ffmpeg frame grab timed out after {0}s" -f $TimeoutSec)
            return $result
        }
    }
    catch {
        $result.Reason = ("ffmpeg frame grab failed to start: {0}" -f $_.Exception.Message)
        return $result
    }
    finally {
        Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
    }

    if (-not (Test-Path -LiteralPath $OutPath)) {
        $result.Reason = 'ffmpeg produced no output file'
        return $result
    }

    $size = (Get-Item -LiteralPath $OutPath).Length
    $result.SizeBytes = $size
    if ($size -le 0) {
        $result.Reason = 'ffmpeg produced an empty file'
        return $result
    }

    $result.Ok = $true
    $result.Reason = ("{0} bytes" -f $size)
    return $result
}

function Test-NrtFrameNotBlack {
    <#
    .SYNOPSIS
        Reuses the app's own blackframe-filter pattern (Test-FfmpegEncoder in
        utils.ps1) to flag a captured frame that is suspiciously all-black.

    .DESCRIPTION
        A loading screen, a sleeping headset, or a broken encoder can all
        produce a technically-valid, steadily-flowing stream that both
        Test-NrtStreamStable and Test-NrtStreamContent would pass while the
        picture itself is blank. Returns $true when the frame is NOT flagged
        black. A dark-but-legitimate scene can occasionally trip this, so
        callers should Write-TestWarning rather than hard-fail on $false.

    .EXAMPLE
        if (-not (Test-NrtFrameNotBlack -FfmpegPath $ff.FfmpegPath -JpgPath $jpg)) {
            Write-TestWarning 'captured frame looks black'
        }
    #>
    param(
        [Parameter(Mandatory = $true)][string]$FfmpegPath,
        [Parameter(Mandatory = $true)][string]$JpgPath,
        [int]$TimeoutSec = 15
    )

    if (-not (Test-Path -LiteralPath $JpgPath)) { return $true }

    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        $ffArgs = @('-y', '-i', $JpgPath, '-vf', 'blackframe=98:32', '-f', 'null', '-')
        $proc = Start-Process -FilePath $FfmpegPath -ArgumentList $ffArgs -NoNewWindow -PassThru -RedirectStandardError $errFile
        if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
            try { $proc.Kill() } catch { }
            return $true
        }
        $stderr = ''
        try { $stderr = Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue } catch { }
        if (-not $stderr) { return $true }
        return ($stderr -notmatch 'blackframe.*pblack:')
    }
    catch {
        return $true
    }
    finally {
        Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-NrtSandboxPorts {
    <#
    .SYNOPSIS
        Reads the sandbox config and returns the ports the tests need.

    .EXAMPLE
        $ports = Get-NrtSandboxPorts -TargetRoot $target
        Get-NrtMediaMtxPaths -ApiPort $ports.MediaMtxApi
    #>
    param([Parameter(Mandatory = $true)][string]$TargetRoot)

    $paths  = Get-SandboxPaths -TargetRoot $TargetRoot
    $config = $null
    try { $config = Read-JsonFileUtf8 -Path $paths.ConfigFile } catch { }

    $out = @{ MediaMtxApi = 9997; Rtsp = 8554; Hls = 8888; WebRtc = 8889; Adb = 5555; ReEncode = $true; Codec = 'h264' }
    if ($config -and $config.mediamtx) {
        if ($config.mediamtx.api_port)    { $out.MediaMtxApi = [int]$config.mediamtx.api_port }
        if ($config.mediamtx.rtsp_port)   { $out.Rtsp        = [int]$config.mediamtx.rtsp_port }
        if ($config.mediamtx.hls_port)    { $out.Hls         = [int]$config.mediamtx.hls_port }
        if ($config.mediamtx.webrtc_port) { $out.WebRtc      = [int]$config.mediamtx.webrtc_port }
        if ($null -ne $config.mediamtx.reencode_in_ffmpeg) { $out.ReEncode = [bool]$config.mediamtx.reencode_in_ffmpeg }
        if ($config.mediamtx.codec)       { $out.Codec       = [string]$config.mediamtx.codec }
    }
    if ($config -and $config.ADB -and $config.ADB.port) { $out.Adb = [int]$config.ADB.port }
    return $out
}

function Start-NrtHeadsetStream {
    <#
    .SYNOPSIS
        Brings one headset all the way up: registered, ADB seen, scrcpy running.
        Returns @{ Ok; Reason; Process }.

    .DESCRIPTION
        Shared by sections 50 and 60 so the multi-step bring-up sequence -
        add, wait for ADB, enable autorestart, wait for the process - is written
        once. Does not assert; the caller turns Ok/Reason into a verdict.

    .EXAMPLE
        $up = Start-NrtHeadsetStream -TargetRoot $target -Headset $headset
        Assert-True $up.Ok $up.Reason
    #>
    param(
        [Parameter(Mandatory = $true)][string]$TargetRoot,
        [Parameter(Mandatory = $true)]$Headset,
        [int]$AdbTimeoutSec = 90,
        [int]$ScrcpyTimeoutSec = 90
    )

    $out = @{ Ok = $false; Reason = ''; Process = $null }

    $existing = Invoke-VrmApi -Path '/api/headsets'
    $already  = $false
    if ($existing.Json) {
        $already = @($existing.Json | Where-Object { $_.Name -eq $Headset.Name }).Count -gt 0
    }
    if (-not $already) {
        $add = Add-NrtSandboxHeadset -Headset $Headset
        if (-not $add.Ok) {
            $out.Reason = ("could not register the headset: HTTP {0}" -f $add.StatusCode)
            return $out
        }

        # /api/addheadset ignores any profile in the request and assigns its own
        # default, so carry the operator's real profile across explicitly. Without
        # this the tests would exercise a profile nobody actually uses.
        # BUT only when the profile's VIEW exists in the sandbox config. Views are config
        # (scrcpy.parameters.<Model>.views); the sandbox runs on the shipped template, so
        # a view the operator created in the dev config (e.g. with the visual view editor)
        # does not exist here. The app then falls back to 'fullscreen' with no crop and,
        # on the template's uncapped max_size, streams the full native frame - which the
        # hardware H.264 encoders cannot open. That made section 60 test an accident of
        # the dev registry instead of the release. Keep the sandbox default in that case.
        if ($Headset.ScrcpyProfile) {
            $view = ([string]$Headset.ScrcpyProfile) -replace '-[LRM]-[DN]-\d+-\d+$', ''
            $carry = $true
            if ($view -ne [string]$Headset.ScrcpyProfile) {
                $sbCfg = Read-JsonFileUtf8 -Path (Get-SandboxPaths -TargetRoot $TargetRoot).ConfigFile
                $views = $null
                if ($sbCfg -and $Headset.Model -and $sbCfg.scrcpy.parameters.($Headset.Model)) {
                    $views = $sbCfg.scrcpy.parameters.($Headset.Model).views
                }
                $known = @()
                if ($views) { $known = @($views.PSObject.Properties.Name) }
                if (-not (@($known | Where-Object { $_ -ieq $view }).Count)) { $carry = $false }
            }
            if ($carry) {
                Set-NrtScrcpyProfile -Name $Headset.Name -Profile $Headset.ScrcpyProfile | Out-Null
            } elseif (Get-Command Add-TestEvidence -ErrorAction SilentlyContinue) {
                Add-TestEvidence ("profile '{0}' NOT carried over: view '{1}' does not exist for model '{2}' in the release config - the release default profile is used instead" -f $Headset.ScrcpyProfile, $view, $Headset.Model)
            }
        }
    }

    if (-not (Wait-NrtHeadsetAdb -TargetRoot $TargetRoot -Name $Headset.Name -TimeoutSec $AdbTimeoutSec)) {
        $out.Reason = ("VRMonitor never reported ADBWifi for '{0}' within {1}s" -f $Headset.Name, $AdbTimeoutSec)
        return $out
    }

    $r = Set-NrtAutoRestart -Name $Headset.Name -Enabled $true
    if (-not $r.Ok) {
        $out.Reason = ("POST /api/autorestart returned HTTP {0}" -f $r.StatusCode)
        return $out
    }

    $proc = Wait-NrtScrcpy -TargetRoot $TargetRoot -Name $Headset.Name -IPAddress $Headset.IPAddress `
                           -Running $true -TimeoutSec $ScrcpyTimeoutSec
    if (-not $proc) {
        $out.Reason = ("scrcpy did not start for '{0}' within {1}s of enabling auto-restart" -f $Headset.Name, $ScrcpyTimeoutSec)
        return $out
    }

    $out.Ok      = $true
    $out.Process = $proc
    $out.Reason  = ("scrcpy PID {0}" -f $proc.Id)
    return $out
}

function Stop-NrtHeadsetStream {
    <#
    .SYNOPSIS
        Tears one headset back down: auto-restart off, scrcpy stopped.
        Best-effort - never throws, so it is safe in a teardown test.

    .EXAMPLE
        Stop-NrtHeadsetStream -TargetRoot $target -Headset $headset
    #>
    param(
        [Parameter(Mandatory = $true)][string]$TargetRoot,
        [Parameter(Mandatory = $true)]$Headset,
        [int]$TimeoutSec = 45,
        [int]$Attempts = 3
    )

    $safe = ConvertTo-NrtSafeName -Name $Headset.Name

    # Retried on purpose. A watchdog relaunch already in flight when the stop
    # lands will finish AFTER it, bringing the pipeline straight back up - the
    # app logs "Pipe pipeline up" seconds after "Scrcpy stopped". One stop is
    # therefore not reliably a stop; keep going until it stays down.
    for ($i = 0; $i -lt $Attempts; $i++) {
        try { Set-NrtAutoRestart -Name $Headset.Name -Enabled $false | Out-Null } catch { }
        try { Invoke-VrmApi -Path '/api/stop-scrcpy' -Method POST -Body @{ name = $safe } | Out-Null } catch { }

        $still = Wait-NrtScrcpy -TargetRoot $TargetRoot -Name $Headset.Name -IPAddress $Headset.IPAddress `
                                -Running $false -TimeoutSec $TimeoutSec
        if ($null -ne $still) { continue }

        # Settle window: catch a relaunch that was mid-flight when we stopped.
        Start-Sleep -Seconds 8
        $late = Get-NrtScrcpyProcess -TargetRoot $TargetRoot -Name $Headset.Name -IPAddress $Headset.IPAddress
        if (-not $late) { return $true }
    }
    return $false
}

function Wait-NrtHeadsetRebooted {
    <#
    .SYNOPSIS
        After a reboot request, waits for the headset to go DOWN and then come BACK (ping + ADB
        port). Returns @{ Back; Down; ElapsedSec } and never hangs: -TimeoutSec bounds the whole wait.

    .DESCRIPTION
        Phase 1 proves the reboot really happened (reachable -> unreachable, max -DownTimeoutSec),
        so a pre-reboot reading is never mistaken for a post-reboot one. Phase 2 waits for the
        headset to answer again. Back=$false means the headset did not return in time (for example
        because wireless ADB is not persistent across a reboot and no cable lets the app re-enable it).

    .EXAMPLE
        $r = Wait-NrtHeadsetRebooted -IPAddress '10.0.0.5' -AdbPort 5555 -TimeoutSec 240
    #>
    param(
        [Parameter(Mandatory = $true)][string]$IPAddress,
        [int]$AdbPort = 5555,
        [int]$TimeoutSec = 240,
        [int]$DownTimeoutSec = 60,
        # The headset's serial: "down" and "back" are then judged on THIS headset answering adb in
        # either WiFi mode on whatever port it has (the TLS port changes at every boot), so another
        # headset on the network going up or down cannot satisfy the wait.
        [string]$Serial = ''
    )

    $start    = Get-Date
    $deadline = $start.AddSeconds($TimeoutSec)
    $down     = $false

    $downDeadline = $start.AddSeconds($DownTimeoutSec)
    while ((Get-Date) -lt $downDeadline) {
        if (-not (Test-NrtHeadsetReachable -IPAddress $IPAddress -AdbPort $AdbPort -TimeoutMs 1000 -Serial $Serial)) { $down = $true; break }
        Start-Sleep -Seconds 2
    }

    $back = $false
    while ((Get-Date) -lt $deadline) {
        if (Test-NrtHeadsetReachable -IPAddress $IPAddress -AdbPort $AdbPort -TimeoutMs 1500 -Serial $Serial) { $back = $true; break }
        Start-Sleep -Seconds 3
    }
    return @{ Back = $back; Down = $down; ElapsedSec = [int]((Get-Date) - $start).TotalSeconds }
}
