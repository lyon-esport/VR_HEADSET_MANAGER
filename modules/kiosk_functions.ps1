#################
# KIOSK SCREENS - CHROME DEVTOOLS PROTOCOL (CDP) FUNCTIONS
#################

function Write-KioskLog {
    <#
    .SYNOPSIS
    Writes one kiosk-specific server-side log line to logs\<COMPUTERNAME>\kiosk_<date>.log.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        [ValidateSet('DEBUG', 'INFO', 'SUCCESS', 'WARNING', 'ERROR')]
        [string]$Level = 'INFO'
    )

    try {
        $folder = $global:logFolder
        if (-not $folder) {
            $computer = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { 'UNKNOWN' }
            $folder = Join-Path $global:ScriptPath (Join-Path 'logs' $computer)
        }
        if (-not (Test-Path -LiteralPath $folder)) {
            [System.IO.Directory]::CreateDirectory($folder) | Out-Null
        }

        $path = Join-Path $folder ("kiosk_{0}.log" -f (Get-Date -Format 'yyyy-MM-dd'))
        $line = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
        $content = $line + [Environment]::NewLine

        if (-not (Test-Path -LiteralPath $path)) {
            if (Get-Command Write-FileWithoutBom -ErrorAction SilentlyContinue) {
                Write-FileWithoutBom -Path $path -Content $content
            } else {
                $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
                [System.IO.File]::WriteAllText($path, $content, $utf8NoBom)
            }
        } else {
            $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
            [System.IO.File]::AppendAllText($path, $content, $utf8NoBom)
        }
    } catch {
        try { Write-Log "Write-KioskLog failed: $($_.Exception.Message)" -Level DEBUG } catch { }
    }
}

function Get-CdpInfo {
    <#
    .SYNOPSIS
    Calls GET http://<IP>:<Port>/json/version on a kiosk PC running Chrome with
    remote debugging enabled. Returns the parsed JSON object (Browser,
    webSocketDebuggerUrl, etc.) or $null if unreachable.
    .PARAMETER IP
    Kiosk PC IP address.
    .PARAMETER Port
    Chrome remote debugging port (default 9222).
    .PARAMETER TimeoutSec
    Request timeout in seconds (default 2).
    #>
    param(
        [Parameter(Mandatory)]
        [string]$IP,
        [int]$Port       = 9222,
        [int]$TimeoutSec = 2
    )
    try {
        $url  = "http://${IP}:${Port}/json/version"
        $resp = Invoke-RestMethod -Uri $url -Method GET -TimeoutSec $TimeoutSec -ErrorAction Stop
        return $resp
    } catch {
        Write-Log "Get-CdpInfo: unreachable at ${IP}:${Port} - $($_.Exception.Message)" -Level DEBUG
        return $null
    }
}


function Get-CdpTabs {
    <#
    .SYNOPSIS
    Calls GET http://<IP>:<Port>/json/list and returns the array of open Chrome
    tabs (id, type, url, webSocketDebuggerUrl), or @() if unreachable.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$IP,
        [int]$Port       = 9222,
        [int]$TimeoutSec = 2
    )
    try {
        $url  = "http://${IP}:${Port}/json/list"
        $resp = Invoke-RestMethod -Uri $url -Method GET -TimeoutSec $TimeoutSec -ErrorAction Stop
        if ($resp) { return @($resp) }
        return @()
    } catch {
        Write-Log "Get-CdpTabs: unreachable at ${IP}:${Port} - $($_.Exception.Message)" -Level DEBUG
        return @()
    }
}


function Invoke-CdpNavigate {
    <#
    .SYNOPSIS
    Navigates the active page tab of a kiosk's Chrome instance to a given URL via
    the CDP WebSocket API (Page.navigate). Returns @{Success; Error}.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$IP,
        [int]$Port       = 9222,
        [Parameter(Mandatory)]
        [string]$Url,
        [int]$TimeoutSec = 5
    )

    $tabs = Get-CdpTabs -IP $IP -Port $Port -TimeoutSec $TimeoutSec
    if (-not $tabs -or $tabs.Count -eq 0) {
        # Distinguish "kiosk unreachable / not a CDP endpoint" from "reachable but no page tab",
        # since the two need very different troubleshooting (bad IP/hostname vs. Chrome state).
        $cdpInfo = Get-CdpInfo -IP $IP -Port $Port -TimeoutSec $TimeoutSec
        if (-not $cdpInfo) {
            return @{ Success = $false; Error = "Cannot reach Chrome debug endpoint at ${IP}:${Port} - check the kiosk's IP address and that Chrome remote debugging is running" }
        }
    }
    $tab = $tabs | Where-Object { $_.type -eq 'page' } | Select-Object -First 1
    if (-not $tab) {
        return @{ Success = $false; Error = "No page tab found on kiosk" }
    }

    $ws  = $null
    $cts = $null
    try {
        $ws  = [System.Net.WebSockets.ClientWebSocket]::new()
        $cts = [System.Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($TimeoutSec))

        try {
            $ws.ConnectAsync([Uri]$tab.webSocketDebuggerUrl, $cts.Token).GetAwaiter().GetResult() | Out-Null
        } catch {
            return @{ Success = $false; Error = "WebSocket connect failed: $($_.Exception.Message)" }
        }

        try {
            $payload = @{ id = 1; method = "Page.navigate"; params = @{ url = $Url } } | ConvertTo-Json -Compress
            $bytes   = [System.Text.Encoding]::UTF8.GetBytes($payload)
            $ws.SendAsync([System.ArraySegment[byte]]::new($bytes), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token).GetAwaiter().GetResult() | Out-Null

            # Read and validate the matching CDP response. Page.navigate can fail
            # while the WebSocket send still succeeds, so check the JSON error node.
            try {
                $buffer = New-Object byte[] 8192
                $cdpResponse = $null
                while (-not $cdpResponse) {
                    $builder = [System.Text.StringBuilder]::new()
                    do {
                        $segment = [System.ArraySegment[byte]]::new($buffer)
                        $receive = $ws.ReceiveAsync($segment, $cts.Token).GetAwaiter().GetResult()
                        if ($receive.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
                            return @{ Success = $false; Error = "Chrome closed the WebSocket before confirming navigation" }
                        }
                        if ($receive.Count -gt 0) {
                            [void]$builder.Append([System.Text.Encoding]::UTF8.GetString($buffer, 0, $receive.Count))
                        }
                    } until ($receive.EndOfMessage)

                    $responseText = $builder.ToString()
                    if (-not $responseText) {
                        continue
                    }

                    try {
                        $candidateResponse = $responseText | ConvertFrom-Json
                    } catch {
                        return @{ Success = $false; Error = "Chrome returned an invalid CDP response: $responseText" }
                    }

                    if ($candidateResponse.id -eq 1) {
                        $cdpResponse = $candidateResponse
                    }
                }
                if ($cdpResponse.error) {
                    $code = $cdpResponse.error.code
                    $message = $cdpResponse.error.message
                    return @{ Success = $false; Error = "Chrome rejected navigation ($code): $message" }
                }
            } catch {
                return @{ Success = $false; Error = "CDP response read failed: $($_.Exception.Message)" }
            }

            Write-KioskLog "navigate ip=$IP port=$Port result=success url=$Url" -Level SUCCESS
            return @{ Success = $true }
        } catch {
            Write-KioskLog "navigate ip=$IP port=$Port result=failed error=$($_.Exception.Message)" -Level ERROR
            return @{ Success = $false; Error = "Navigate send failed: $($_.Exception.Message)" }
        }
    } catch {
        return @{ Success = $false; Error = $_.Exception.Message }
    } finally {
        try {
            if ($ws -and $ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
                $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "done", [System.Threading.CancellationToken]::None).GetAwaiter().GetResult() | Out-Null
            }
        } catch { }
        if ($ws)  { try { $ws.Dispose() }  catch { } }
        if ($cts) { try { $cts.Dispose() } catch { } }
    }
}


function Close-KioskBrowser {
    <#
    .SYNOPSIS
    Closes the whole Chrome browser process on a kiosk PC via the CDP
    WebSocket API (Browser.close), using the browser-level webSocketDebuggerUrl
    from Get-CdpInfo (not a per-tab one). Returns @{Success; Error}. The
    kiosk launcher script does not auto-restart Chrome, so the operator must
    relaunch it manually on the kiosk device afterwards.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$IP,
        [int]$Port       = 9222,
        [int]$TimeoutSec = 5
    )

    $cdpInfo = Get-CdpInfo -IP $IP -Port $Port -TimeoutSec $TimeoutSec
    if (-not $cdpInfo -or -not $cdpInfo.webSocketDebuggerUrl) {
        return @{ Success = $false; Error = "Cannot reach Chrome debug endpoint at ${IP}:${Port} - check the kiosk's IP address and that Chrome remote debugging is running" }
    }

    $ws  = $null
    $cts = $null
    try {
        $ws  = [System.Net.WebSockets.ClientWebSocket]::new()
        $cts = [System.Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($TimeoutSec))

        try {
            $ws.ConnectAsync([Uri]$cdpInfo.webSocketDebuggerUrl, $cts.Token).GetAwaiter().GetResult() | Out-Null
        } catch {
            return @{ Success = $false; Error = "WebSocket connect failed: $($_.Exception.Message)" }
        }

        try {
            $payload = @{ id = 1; method = "Browser.close" } | ConvertTo-Json -Compress
            $bytes   = [System.Text.Encoding]::UTF8.GetBytes($payload)
            $ws.SendAsync([System.ArraySegment[byte]]::new($bytes), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token).GetAwaiter().GetResult() | Out-Null
            # No response read: Browser.close tears down the browser (and this socket)
            # immediately, so waiting for a reply here would just time out.
            return @{ Success = $true }
        } catch {
            return @{ Success = $false; Error = "Browser.close send failed: $($_.Exception.Message)" }
        }
    } catch {
        return @{ Success = $false; Error = $_.Exception.Message }
    } finally {
        try {
            if ($ws -and $ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
                $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "done", [System.Threading.CancellationToken]::None).GetAwaiter().GetResult() | Out-Null
            }
        } catch { }
        if ($ws)  { try { $ws.Dispose() }  catch { } }
        if ($cts) { try { $cts.Dispose() } catch { } }
    }
}


function Get-KioskReachability {
    <#
    .SYNOPSIS
    Cheap reachability poll for a kiosk PC: ICMP ping + CDP TCP port check, plus
    (when the debug port is open) the URL actually showing on the kiosk's tab
    right now - this is ground truth for what's on screen, independent of
    whatever VRHM last attempted to push (which goes stale the moment the
    kiosk PC or Chrome itself restarts back to a blank tab).
    Returns @{Reachable; LatencyMs; CdpOpen; CurrentUrl}. CurrentUrl is $null
    when the debug port isn't reachable (kiosk PC down, or Chrome not running
    in debug mode) - in that case the caller has no way to know what's on
    screen and should not assume anything.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$IP,
        [int]$Port = 9222
    )

    $ping = New-Object System.Net.NetworkInformation.Ping
    try {
        $reply      = $ping.Send($IP, 400)
        $reachable  = $reply.Status -eq 'Success'
        $latencyMs  = if ($reachable) { $reply.RoundtripTime } else { $null }
    } catch {
        $reachable = $false
        $latencyMs = $null
    } finally {
        $ping.Dispose()
    }

    $cdpOpen    = $false
    $currentUrl = $null
    if ($reachable) {
        # A raw TCP connect is not enough here: when the kiosk needed the
        # netsh portproxy workaround (Chrome ignores --remote-debugging-address
        # and only binds loopback), the portproxy rule is a kernel-level relay
        # that keeps accepting TCP connections even after Chrome itself has
        # exited - a plain Test-Port would keep reporting CdpOpen=true against
        # a dead browser. Only a real CDP HTTP response proves the debug
        # endpoint is actually alive right now.
        $cdpOpen = $null -ne (Get-CdpInfo -IP $IP -Port $Port -TimeoutSec 2)
        if ($cdpOpen) {
            $tabs = Get-CdpTabs -IP $IP -Port $Port -TimeoutSec 2
            $tab  = $tabs | Where-Object { $_.type -eq 'page' } | Select-Object -First 1
            if ($tab) { $currentUrl = $tab.url }
        }
    }

    return @{ Reachable = $reachable; LatencyMs = $latencyMs; CdpOpen = $cdpOpen; CurrentUrl = $currentUrl }
}


function Resolve-LocalhostReplacement {
    <#
    .SYNOPSIS
    Detects whether a URL points at localhost/127.0.0.1 (would resolve to the
    kiosk PC itself, not this VRHM host) and suggests a LAN IP replacement.
    Returns @{NeedsReplacement; SuggestedIP; SuggestedUrl; OriginalUrl} or
    @{NeedsReplacement=$false}.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Url
    )

    try {
        $uri = [Uri]$Url
    } catch {
        return @{ NeedsReplacement = $false }
    }

    if ($uri.Host -notin @('localhost', '127.0.0.1')) {
        return @{ NeedsReplacement = $false }
    }

    $networks = @(Get-PrivateNetworks)
    if (-not $networks -or $networks.Count -eq 0) {
        return @{ NeedsReplacement = $false }
    }

    $chosen = $networks | Where-Object { $_.HasDefaultGateway } | Select-Object -First 1
    if (-not $chosen) { $chosen = $networks | Where-Object { $_.InterfaceAlias -match '(?i)ethernet' } | Select-Object -First 1 }
    if (-not $chosen) { $chosen = $networks | Select-Object -First 1 }
    $chosenIP = $chosen.IPAddress

    $suggestedUri = [UriBuilder]$uri
    $suggestedUri.Host = $chosenIP

    return @{
        NeedsReplacement = $true
        SuggestedIP      = $chosenIP
        SuggestedUrl     = $suggestedUri.Uri.AbsoluteUri
        OriginalUrl      = $Url
    }
}


function Invoke-KioskScan {
    <#
    .SYNOPSIS
    Scans a CIDR range for open kiosk CDP ports and confirms each open port is
    really a Chrome DevTools endpoint. Returns an array of
    @{IPAddress; Browser; AlreadyKnown; Advanced; Hostname; OSVersion;
    InterfaceType; AgentVersion}.
    The agent fields are populated from the kiosk agent cache (data\kiosks_agent.json)
    for kiosks running the advanced launcher (Start-KioskAgent.*), which report
    themselves to this server; they stay $null for basic (v1) kiosks.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$CIDR,
        [int]$Port    = 9222,
        [int]$Timeout = 300
    )

    $openPorts = Test-PortForCidr -CIDR $CIDR -Port $Port -Timeout $Timeout
    $results   = @()

    if (-not $openPorts) { return $results }

    $knownIPs = @((Get-KnownKiosks).IPAddress)

    foreach ($device in $openPorts) {
        $ip      = $device.IPAddress
        $cdpInfo = Get-CdpInfo -IP $ip -Port $Port
        if (-not $cdpInfo) { continue }

        $agent = Get-KioskAgentInfo -IPAddress $ip

        $results += [PSCustomObject]@{
            IPAddress     = $ip
            Browser       = $cdpInfo.Browser
            AlreadyKnown  = ($knownIPs -contains $ip)
            Advanced      = ($null -ne $agent)
            Hostname      = if ($agent) { $agent.Hostname }      else { $null }
            OSVersion     = if ($agent) { $agent.OS }            else { $null }
            InterfaceType = if ($agent) { $agent.InterfaceType } else { $null }
            AgentVersion  = if ($agent) { $agent.AgentVersion }  else { $null }
        }
    }

    return $results
}


#################
# KIOSK AGENT - REPORT CACHE AND COMMAND QUEUE
#
# The advanced kiosk launcher (website\kiosk-launcher\Start-KioskAgent.ps1 /
# Start-KioskAgent-Linux.sh) never listens on a port. It only makes outbound
# calls: to its own loopback CDP port, and to this server's
# POST /api/kiosks/agent-report endpoint every few seconds. That request
# carries the kiosk's hardware/OS/link info (cached here by Save-KioskAgentReport)
# and its response carries any pending operator command (queued here by
# Add-KioskCommand, drained by Get-PendingKioskCommand).
#
# Commands are stored one-file-per-command rather than in a shared JSON list:
# both the console (main.ps1 process) and the web server (separate process)
# queue commands, and an atomic file create needs no cross-process lock.
#################

function Get-KioskLauncherPackagePath {
    <#
    .SYNOPSIS
    Returns the path of the generated kiosk setup zip. It lives under
    website\generated\ (which the release build excludes and the web server serves
    through its transparent generated\ fallback), so the URL is
    /kiosk-launcher/VRHM-Kiosk-Setup.zip - right next to the individual script
    download links.
    #>
    return (Join-Path $global:ScriptPath "website\generated\kiosk-launcher\VRHM-Kiosk-Setup.zip")
}


function New-KioskLauncherPackage {
    <#
    .SYNOPSIS
    Builds the ready-to-use kiosk setup zip: the launcher scripts plus two .cmd
    files that request administrator rights and start PowerShell with the right
    parameters. Regenerated at every app startup so the server URL baked into the
    advanced .cmd is always current - a DHCP lease change on the server would
    otherwise leave every previously downloaded zip pointing at the wrong address.

    Zip contents:
      Start-Kiosk-ADVANCED.cmd  -> Start-KioskAgent.ps1 -ServerUrl <this server>
                                   (accepts an IP/URL argument to override)
      Start-Kiosk-BASIC.cmd     -> Start-KioskChrome.ps1 (the original launcher,
                                   casting only, kept as the proven fallback)
      Start-KioskAgent.ps1      -> advanced launcher + agent
      Start-KioskChrome.ps1     -> basic launcher
      README-KioskChrome.md     -> operator guide

    Returns the zip path on success, $null on failure. Never throws: a missing zip
    only costs the operator a convenience download.
    .EXAMPLE
    New-KioskLauncherPackage
    New-KioskLauncherPackage -ServerUrl "http://192.168.1.37:8080"
    #>
    param(
        [string]$ServerUrl = (Get-ServerLanUrl),
        [string]$OutputPath = (Get-KioskLauncherPackagePath)
    )

    $sourceFolder = Join-Path $global:ScriptPath "website\kiosk-launcher"
    if (-not (Test-Path -LiteralPath $sourceFolder)) {
        Write-Log "New-KioskLauncherPackage: launcher folder not found at $sourceFolder" -Level WARNING
        return $null
    }

    # Without a LAN address there is nothing meaningful to bake in. Still build the
    # package - the basic .cmd works regardless, and the advanced one can be given
    # the address by hand.
    if (-not $ServerUrl) {
        Write-Log "New-KioskLauncherPackage: no LAN address available; the advanced .cmd will require the server URL as an argument." -Level WARNING
    }

    $port      = if ($global:WebServer_port) { $global:WebServer_port } else { 8080 }
    $stamp     = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $staging   = Join-Path $env:TEMP ("vrhm_kiosk_pkg_" + [guid]::NewGuid().ToString('N'))

    try {
        New-Item -ItemType Directory -Path $staging -Force -ErrorAction Stop | Out-Null

        # ---- Copy the launcher scripts and the guide ----
        $toCopy = @('Start-KioskAgent.ps1', 'Start-KioskChrome.ps1', 'README-KioskChrome.md')
        foreach ($name in $toCopy) {
            $src = Join-Path $sourceFolder $name
            if (Test-Path -LiteralPath $src) {
                Copy-Item -LiteralPath $src -Destination (Join-Path $staging $name) -Force -ErrorAction Stop
            } else {
                Write-Log "New-KioskLauncherPackage: '$name' missing from $sourceFolder - not included in the package." -Level WARNING
            }
        }

        # ---- Generate the two .cmd launchers ----
        # Batch files are written with CRLF and pure ASCII: some Windows shells
        # mis-handle LF-only .cmd files, and a stray non-ASCII byte here would be
        # decoded with the console codepage.
        $bakedUrl = if ($ServerUrl) { $ServerUrl } else { "" }

        $advancedLines = @(
            '@echo off'
            'REM ==========================================================='
            'REM  VR HEADSET MANAGER - Kiosk screen setup (ADVANCED)'
            'REM'
            "REM  Generated by VR HEADSET MANAGER on $stamp"
            "REM  Server address baked in below: $bakedUrl"
            'REM'
            'REM  Double-click to run. It asks for administrator rights, then'
            'REM  launches the kiosk browser and the reporting agent.'
            'REM'
            'REM  To point it at a different server, pass the IP or URL:'
            'REM      Start-Kiosk-ADVANCED.cmd 192.168.1.50'
            "REM      Start-Kiosk-ADVANCED.cmd http://192.168.1.50:$port"
            'REM ==========================================================='
            'setlocal EnableExtensions'
            ''
            "set `"SERVER_URL=$bakedUrl`""
            'if not "%~1"=="" set "SERVER_URL=%~1"'
            ''
            'if "%SERVER_URL%"=="" goto :nourl'
            ''
            'REM Accept a bare IP as well as a full URL.'
            'echo.%SERVER_URL% | findstr /B /I /C:"http" >nul'
            "if errorlevel 1 set `"SERVER_URL=http://%SERVER_URL%:$port`""
            ''
            'REM Re-launch this file elevated if it is not already.'
            'net session >nul 2>&1'
            'if errorlevel 1 ('
            '    echo Requesting administrator rights...'
            '    powershell -NoProfile -Command "Start-Process -FilePath ''%~f0'' -ArgumentList ''%SERVER_URL%'' -Verb RunAs"'
            '    exit /b'
            ')'
            ''
            'echo Starting the kiosk agent against %SERVER_URL% ...'
            'REM Launched detached, in its own console, so this .cmd (and the cmd.exe'
            'REM batch job it runs) exits immediately instead of staying the parent for'
            'REM the agent''s whole lifetime - otherwise Ctrl+C in the agent window would'
            'REM hit cmd.exe''s own "Terminate batch job (Y/N)?" prompt instead of the'
            'REM agent''s own clean-stop handling.'
            'start "VR Headset Manager - Kiosk Agent" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-KioskAgent.ps1" -ServerUrl "%SERVER_URL%"'
            'exit /b'
            ''
            ':nourl'
            'echo.'
            'echo No server address is configured in this file.'
            'echo Re-download the package from VR HEADSET MANAGER, or pass the address:'
            'echo     Start-Kiosk-ADVANCED.cmd 192.168.1.50'
            'echo.'
            'pause'
        )

        $basicLines = @(
            '@echo off'
            'REM ==========================================================='
            'REM  VR HEADSET MANAGER - Kiosk screen setup (BASIC)'
            'REM'
            "REM  Generated by VR HEADSET MANAGER on $stamp"
            'REM'
            'REM  Runs the original launcher: opens the firewall and starts the'
            'REM  browser in kiosk mode, nothing else. No reporting, no remote'
            'REM  power control. Use this if the advanced one gives you trouble.'
            'REM ==========================================================='
            'setlocal EnableExtensions'
            ''
            'net session >nul 2>&1'
            'if errorlevel 1 ('
            '    echo Requesting administrator rights...'
            '    powershell -NoProfile -Command "Start-Process -FilePath ''%~f0'' -Verb RunAs"'
            '    exit /b'
            ')'
            ''
            'echo Starting the kiosk browser (basic mode) ...'
            'REM Launched detached, in its own console, so this .cmd exits immediately'
            'REM instead of staying the parent for the browser''s whole lifetime - see the'
            'REM ADVANCED script for why (cmd.exe''s own "Terminate batch job" prompt).'
            'start "VR Headset Manager - Kiosk Browser" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-KioskChrome.ps1"'
            'exit /b'
        )

        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText((Join-Path $staging 'Start-Kiosk-ADVANCED.cmd'), (($advancedLines -join "`r`n") + "`r`n"), $utf8NoBom)
        [System.IO.File]::WriteAllText((Join-Path $staging 'Start-Kiosk-BASIC.cmd'),    (($basicLines    -join "`r`n") + "`r`n"), $utf8NoBom)

        # ---- Zip it ----
        $outFolder = Split-Path -Parent $OutputPath
        if (-not (Test-Path -LiteralPath $outFolder)) {
            New-Item -ItemType Directory -Path $outFolder -Force -ErrorAction Stop | Out-Null
        }
        if (Test-Path -LiteralPath $OutputPath) {
            Remove-Item -LiteralPath $OutputPath -Force -ErrorAction Stop
        }

        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        [System.IO.Compression.ZipFile]::CreateFromDirectory($staging, $OutputPath)

        Write-Log "New-KioskLauncherPackage: kiosk setup package rebuilt for $bakedUrl -> $OutputPath" -Level INFO
        return $OutputPath
    } catch {
        Write-Log "New-KioskLauncherPackage: failed to build the kiosk setup package - $($_.Exception.Message)" -Level WARNING
        return $null
    } finally {
        if (Test-Path -LiteralPath $staging) {
            Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}


function Get-ServerLanUrl {
    <#
    .SYNOPSIS
    Returns this server's LAN base URL ("http://192.168.1.37:8080") - the address a
    kiosk on the same network must use to reach us. Prefers the interface holding the
    default route, then an Ethernet-named interface, mirroring Resolve-LocalhostReplacement.
    Get-PrivateNetworks already excludes virtual/hypervisor adapters (Hyper-V, WSL, VMware,
    VPN), so a private-range IP on one of those (e.g. a Hyper-V "vEthernet (...)" switch)
    is never picked in place of the real LAN adapter. Returns $null when no private network
    is available.
    .EXAMPLE
    $url = Get-ServerLanUrl        # -> http://192.168.1.37:8080
    #>
    param(
        [int]$Port = $global:WebServer_port
    )

    $networks = @(Get-PrivateNetworks)
    if (-not $networks -or $networks.Count -eq 0) { return $null }

    $chosen = $networks | Where-Object { $_.HasDefaultGateway } | Select-Object -First 1
    if (-not $chosen) { $chosen = $networks | Where-Object { $_.InterfaceAlias -match '(?i)ethernet' } | Select-Object -First 1 }
    if (-not $chosen) { $chosen = $networks | Select-Object -First 1 }
    if (-not $chosen -or -not $chosen.IPAddress) { return $null }

    return ("http://{0}:{1}" -f $chosen.IPAddress, $Port)
}


function Get-KioskAgentReportPath {
    <#
    .SYNOPSIS
    Returns the path of data\kiosks_agent.json - the cache of the latest report
    received from each advanced kiosk. Written only by the web server's
    agent-report endpoint, so it never races the VRMonitor-owned
    data\kiosks_status.json.
    #>
    return (Join-Path $global:ScriptPath "data\kiosks_agent.json")
}


function Get-KioskCommandFolder {
    <#
    .SYNOPSIS
    Returns the path of data\kiosk_commands\ - the pending-command queue drained
    by advanced kiosks on their next report. Created on demand.
    #>
    $folder = Join-Path $global:ScriptPath "data\kiosk_commands"
    if (-not (Test-Path -LiteralPath $folder)) {
        try {
            New-Item -ItemType Directory -Path $folder -Force -ErrorAction Stop | Out-Null
        } catch {
            Write-Log "Get-KioskCommandFolder: could not create $folder - $($_.Exception.Message)" -Level ERROR
        }
    }
    return $folder
}


function ConvertTo-KioskIpToken {
    <#
    .SYNOPSIS
    Sanitises an IP address into a filename-safe token for the command queue.
    Guards against a malformed CSV value turning into a path traversal.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$IPAddress
    )
    return ($IPAddress -replace '[^0-9A-Za-z\.]', '-')
}


function Get-TruncatedText {
    <#
    .SYNOPSIS
    Returns a string capped at -Max characters ($null passes through). Used to
    bound every string field of an agent report before it is persisted - that
    payload arrives over the network from an unauthenticated LAN device.
    #>
    param(
        $Value,
        [int]$Max = 200
    )
    if ($null -eq $Value) { return $null }
    $s = [string]$Value
    if ($s.Length -gt $Max) { return $s.Substring(0, $Max) }
    return $s
}


function Save-KioskAgentReport {
    <#
    .SYNOPSIS
    Merges one agent report into data\kiosks_agent.json, keyed by IP address.
    The caller (the web server endpoint) MUST pass the IP taken from the request's
    remote endpoint, never one taken from the request body.
    .EXAMPLE
    Save-KioskAgentReport -IPAddress "192.168.1.93" -Report $parsedBody
    #>
    param(
        [Parameter(Mandatory)]
        [string]$IPAddress,
        [Parameter(Mandatory)]
        $Report
    )

    $entry = [PSCustomObject]@{
        IPAddress          = $IPAddress
        MachineId          = Get-TruncatedText $Report.machineId 100
        Hostname           = Get-TruncatedText $Report.hostname 100
        OS                 = Get-TruncatedText $Report.os 150
        OSFamily           = Get-TruncatedText $Report.osFamily 30
        InterfaceType      = Get-TruncatedText $Report.interfaceType 30
        InterfaceName      = Get-TruncatedText $Report.interfaceName 100
        LinkSpeedMbps      = if ($null -ne $Report.linkSpeedMbps) { [int]$Report.linkSpeedMbps } else { $null }
        Browser            = Get-TruncatedText $Report.browser 100
        BrowserRunning     = [bool]$Report.browserRunning
        CdpPort            = if ($null -ne $Report.cdpPort) { [int]$Report.cdpPort } else { $null }
        CurrentUrl         = Get-TruncatedText $Report.currentUrl 500
        UptimeSec          = if ($null -ne $Report.uptimeSec) { [int64]$Report.uptimeSec } else { $null }
        AutoRestartBrowser = [bool]$Report.autoRestartBrowser
        AgentVersion       = Get-TruncatedText $Report.version 20
        LastAck            = if ($Report.ack) { Get-TruncatedText ("{0}/{1}/{2}" -f $Report.ack.cmd, $Report.ack.nonce, $Report.ack.result) 100 } else { $null }
        LastReportAt       = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    }

    $path = Get-KioskAgentReportPath
    $all  = @()
    if (Test-Path -LiteralPath $path) {
        try {
            $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
            if ($raw) {
                # Assign, THEN wrap. ConvertFrom-Json emits a JSON array as a single
                # non-enumerated pipeline item, so "@(ConvertFrom-Json ...)" collapses
                # every entry into one object whose properties are arrays - which only
                # shows up once a second kiosk reports.
                $parsed = ConvertFrom-Json $raw
                $all    = @($parsed)
            }
        } catch {
            Write-Log "Save-KioskAgentReport: could not parse $path, starting fresh - $($_.Exception.Message)" -Level WARNING
            $all = @()
        }
    }

    $previous = $all | Where-Object { $_ -and $_.IPAddress -eq $IPAddress } | Select-Object -First 1
    $all = @($all | Where-Object { $_ -and $_.IPAddress -ne $IPAddress })
    $all += $entry

    try {
        Write-FileWithoutBom -Path $path -Content ($all | ConvertTo-Json -Depth 5)
        if (-not $previous) {
            Write-KioskLog "agent report new ip=$IPAddress host=$($entry.Hostname) browserRunning=$($entry.BrowserRunning) url=$($entry.CurrentUrl)" -Level INFO
        } elseif ($previous.CurrentUrl -ne $entry.CurrentUrl -or $previous.BrowserRunning -ne $entry.BrowserRunning -or $previous.AgentVersion -ne $entry.AgentVersion) {
            Write-KioskLog "agent report changed ip=$IPAddress host=$($entry.Hostname) browserRunning=$($entry.BrowserRunning) url=$($entry.CurrentUrl)" -Level INFO
        }
    } catch {
        Write-Log "Save-KioskAgentReport: failed to write $path - $($_.Exception.Message)" -Level WARNING
        Write-KioskLog "agent report write failed ip=$IPAddress error=$($_.Exception.Message)" -Level WARNING
        return $false
    }
    return $true
}


function Get-KioskAgentReports {
    <#
    .SYNOPSIS
    Returns EVERY cached agent report, each with an added IsStale flag, or @() when
    no kiosk has ever reported.
    Use this instead of calling Get-KioskAgentInfo in a loop: /api/kiosks is polled
    every 4s by the browser, and a per-kiosk call would re-read and re-parse the
    whole cache file once per kiosk on every poll.
    .PARAMETER StaleAfterSec
    A report older than this is flagged IsStale (default 30 - about 6 missed reports
    at the default 5s interval).
    #>
    param(
        [int]$StaleAfterSec = 30
    )

    $path = Get-KioskAgentReportPath
    if (-not (Test-Path -LiteralPath $path)) { return @() }

    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        if (-not $raw) { return @() }
        # Assign, THEN wrap - see the note in Save-KioskAgentReport.
        $parsed = ConvertFrom-Json $raw
        $all    = @($parsed)
    } catch {
        Write-Log "Get-KioskAgentReports: could not parse $path - $($_.Exception.Message)" -Level DEBUG
        return @()
    }

    $now = Get-Date
    foreach ($entry in $all) {
        if (-not $entry) { continue }
        $isStale = $true
        if ($entry.LastReportAt) {
            try {
                $last    = [datetime]::ParseExact([string]$entry.LastReportAt, 'yyyy-MM-dd HH:mm:ss', $null)
                $isStale = ($now - $last).TotalSeconds -gt $StaleAfterSec
            } catch {
                $isStale = $true
            }
        }
        Add-Member -InputObject $entry -NotePropertyName 'IsStale' -NotePropertyValue $isStale -Force
    }

    return $all
}


function Get-KioskAgentInfo {
    <#
    .SYNOPSIS
    Returns the cached agent report for one kiosk IP, with an added IsStale flag,
    or $null when that kiosk has never reported (i.e. it runs the basic v1 launcher,
    or was started without -ServerUrl).
    For more than one kiosk at a time, call Get-KioskAgentReports once instead.
    .EXAMPLE
    $agent = Get-KioskAgentInfo -IPAddress "192.168.1.93"
    if ($agent -and -not $agent.IsStale) { "Advanced kiosk: $($agent.Hostname)" }
    #>
    param(
        [Parameter(Mandatory)]
        [string]$IPAddress,
        [int]$StaleAfterSec = 30
    )

    $all   = @(Get-KioskAgentReports -StaleAfterSec $StaleAfterSec)
    $entry = $all | Where-Object { $_ -and $_.IPAddress -eq $IPAddress } | Select-Object -First 1
    if (-not $entry) { return $null }
    return $entry
}


function Add-KioskCommand {
    <#
    .SYNOPSIS
    Queues one command for an advanced kiosk. The kiosk picks it up on its next
    report. Returns the nonce, or $null on failure.
    .PARAMETER Cmd
    reboot | shutdown | browser-restart | agent-stop
    .EXAMPLE
    Add-KioskCommand -IPAddress "192.168.1.93" -Cmd "reboot"
    #>
    param(
        [Parameter(Mandatory)]
        [string]$IPAddress,
        [Parameter(Mandatory)]
        [ValidateSet('reboot', 'shutdown', 'browser-restart', 'agent-stop')]
        [string]$Cmd,
        [int]$DelaySec = 5
    )

    $folder = Get-KioskCommandFolder
    $nonce  = [int64]([datetimeoffset]::UtcNow.ToUnixTimeMilliseconds())
    $token  = ConvertTo-KioskIpToken -IPAddress $IPAddress
    $file   = Join-Path $folder ("{0}_{1}.json" -f $token, $nonce)

    $payload = [PSCustomObject]@{
        cmd       = $Cmd
        nonce     = $nonce
        delaySec  = $DelaySec
        ip        = $IPAddress
        queuedAt  = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    }

    try {
        Write-FileWithoutBom -Path $file -Content ($payload | ConvertTo-Json -Compress)
        Write-Log "Add-KioskCommand: queued '$Cmd' for kiosk $IPAddress (nonce $nonce)." -Level INFO
        Write-KioskLog "command queued ip=$IPAddress cmd=$Cmd nonce=$nonce delaySec=$DelaySec" -Level INFO
        return $nonce
    } catch {
        Write-Log "Add-KioskCommand: failed to queue '$Cmd' for $IPAddress - $($_.Exception.Message)" -Level ERROR
        Write-KioskLog "command queue failed ip=$IPAddress cmd=$Cmd error=$($_.Exception.Message)" -Level ERROR
        return $null
    }
}


function Get-PendingKioskCommand {
    <#
    .SYNOPSIS
    Returns the oldest pending command for a kiosk and DELETES it (deliver-once),
    or $null when the queue is empty. Commands older than -MaxAgeSec are discarded
    without being delivered: a reboot queued while a kiosk was powered off must not
    fire the moment it comes back an hour later.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$IPAddress,
        [int]$MaxAgeSec = 300
    )

    $folder = Get-KioskCommandFolder
    if (-not (Test-Path -LiteralPath $folder)) { return $null }

    $token = ConvertTo-KioskIpToken -IPAddress $IPAddress
    $files = @(Get-ChildItem -LiteralPath $folder -Filter ("{0}_*.json" -f $token) -File -ErrorAction SilentlyContinue |
                Sort-Object Name)

    foreach ($file in $files) {
        $cmdObj = $null
        try {
            $raw = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
            if ($raw) { $cmdObj = ConvertFrom-Json $raw }
        } catch {
            Write-Log "Get-PendingKioskCommand: unreadable command file $($file.Name), dropping it." -Level WARNING
        }

        # Deliver-once: the file goes away whether or not it parsed.
        try { Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop } catch { }

        if (-not $cmdObj) { continue }

        $ageSec = ((Get-Date) - $file.LastWriteTime).TotalSeconds
        if ($ageSec -gt $MaxAgeSec) {
            Write-Log "Get-PendingKioskCommand: discarded stale '$($cmdObj.cmd)' for $IPAddress (queued $([int]$ageSec)s ago)." -Level WARNING
            continue
        }

        Write-Log "Get-PendingKioskCommand: delivering '$($cmdObj.cmd)' to kiosk $IPAddress (nonce $($cmdObj.nonce))." -Level INFO
        Write-KioskLog "command delivered ip=$IPAddress cmd=$($cmdObj.cmd) nonce=$($cmdObj.nonce)" -Level INFO
        return $cmdObj
    }

    return $null
}


function Invoke-KioskPowerAction {
    <#
    .SYNOPSIS
    Orders a power action on a kiosk screen. Preferred path: queue the command for
    the kiosk's agent to collect on its next report (works even when Chrome is
    closed). Fallback for a kiosk with no live agent: push the kiosk_command.html
    sentinel page over CDP - the advanced launcher watches its own loopback CDP for
    that URL, and picking it up also teaches it this server's address.
    Returns @{Success; Method; Error; Nonce}.
    .PARAMETER Action
    reboot | shutdown | browser-restart | agent-stop
    .EXAMPLE
    Invoke-KioskPowerAction -IPAddress "192.168.1.93" -Port 9222 -Action reboot
    #>
    param(
        [Parameter(Mandatory)]
        [string]$IPAddress,
        [int]$Port = 9222,
        [Parameter(Mandatory)]
        [ValidateSet('reboot', 'shutdown', 'browser-restart', 'agent-stop')]
        [string]$Action,
        [int]$DelaySec = 5
    )

    $agent = Get-KioskAgentInfo -IPAddress $IPAddress

    if ($agent -and -not $agent.IsStale) {
        $nonce = Add-KioskCommand -IPAddress $IPAddress -Cmd $Action -DelaySec $DelaySec
        if ($null -eq $nonce) {
            return @{ Success = $false; Method = 'agent'; Error = "Could not queue the command"; Nonce = $null }
        }
        return @{ Success = $true; Method = 'agent'; Error = $null; Nonce = $nonce }
    }

    # ---- Fallback: CDP sentinel page ----
    $serverUrl = Get-ServerLanUrl
    if (-not $serverUrl) {
        return @{ Success = $false; Method = 'sentinel'; Error = "No agent report from this kiosk, and no local LAN address to build the fallback command URL"; Nonce = $null }
    }

    $nonce = [int64]([datetimeoffset]::UtcNow.ToUnixTimeMilliseconds())
    $url   = "{0}/kiosk_command.html?cmd={1}&nonce={2}&delay={3}" -f $serverUrl, $Action, $nonce, $DelaySec

    $navResult = Invoke-CdpNavigate -IP $IPAddress -Port $Port -Url $url
    if ($navResult.Success) {
        Write-Log "Invoke-KioskPowerAction: pushed '$Action' sentinel to kiosk $IPAddress (nonce $nonce)." -Level INFO
        return @{ Success = $true; Method = 'sentinel'; Error = $null; Nonce = $nonce }
    }

    return @{ Success = $false; Method = 'sentinel'; Error = $navResult.Error; Nonce = $null }
}
