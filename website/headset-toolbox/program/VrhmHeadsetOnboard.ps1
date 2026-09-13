<#
.SYNOPSIS
    Headset Toolbox - onboards a USB-connected Meta Quest / Pico headset onto a
    VR HEADSET MANAGER server.

.DESCRIPTION
    Dot-sourced by Start-VrhmToolbox.ps1. For each headset plugged in over USB:
      1. Read its serial number, brand and model.
      2. Switch it into WiFi ADB mode (adb tcpip <port>) and read its WiFi IP.
      3. Confirm the WiFi ADB session actually comes up (adb connect).
      4. Register it with the server (add, or update the IP of a known serial).
      5. Optionally ask the SERVER to move it onto one of the WiFi networks the
         server knows - the password never leaves the server, and the push is
         refused when the headset's own radio cannot see that SSID.
      6. Optionally install the WiFi ADB helper APK, downloaded from the server.

    adb.exe is NOT shipped inside the toolbox binary - it is downloaded from the
    server (GET /api/adb-tools) on first use and kept next to the scripts for
    later offline runs. That is why this whole section is unavailable when adb
    has never been downloaded and no server can be reached.

.NOTES
    Ported from the former website\headset-toolbox\Enable-HeadsetWifiAdb.ps1.
    Depends on VrhmServerDiscovery.ps1 being dot-sourced first.
#>

$script:VrhmToolFolder   = ""
$script:VrhmAdbPort      = 5555
$script:AdbServerStopped = $false

function Set-VrhmHeadsetContext {
    <#
    .SYNOPSIS
    Tells this file where the extracted tool folder is (adb.exe lives there) and
    which TCP port to use for WiFi ADB.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ToolFolder,
        [int]$AdbPort = 5555
    )
    $script:VrhmToolFolder = $ToolFolder
    if ($AdbPort -gt 0) { $script:VrhmAdbPort = $AdbPort }
}

function Get-VrhmAdbPath {
    <#
    .SYNOPSIS
    Full path of the local adb.exe, or $null when it has not been downloaded yet.
    #>
    if (-not $script:VrhmToolFolder) { return $null }
    $candidate = Join-Path $script:VrhmToolFolder 'adb.exe'
    if (Test-Path -LiteralPath $candidate) { return $candidate }
    return $null
}

function Install-VrhmAdbTools {
    <#
    .SYNOPSIS
    Downloads adb.exe + its two DLLs from the server and unpacks them next to
    the toolbox scripts. Returns the adb path, or $null on failure.

    .DESCRIPTION
    The server serves the exact adb build it runs itself (GET /api/adb-tools),
    so the toolbox never drifts from the version the headsets are managed with.
    Downloaded once - a later run reuses the local copy and works offline.

    .EXAMPLE
    $adb = Install-VrhmAdbTools -ServerUrl 'http://192.168.1.37:8080'
    #>
    param([Parameter(Mandatory = $true)][string]$ServerUrl)

    $existing = Get-VrhmAdbPath
    if ($existing) { return $existing }

    if (-not $ServerUrl) { return $null }

    $zipPath = Join-Path $env:TEMP ("vrhm_adb_tools_{0}.zip" -f ([guid]::NewGuid().ToString('N')))
    try {
        Write-Host "Downloading adb from the VR HEADSET MANAGER server..." -ForegroundColor Cyan
        Invoke-WebRequest -Uri ("{0}/api/adb-tools" -f $ServerUrl.TrimEnd('/')) `
                          -OutFile $zipPath -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop

        if (-not (Test-Path -LiteralPath $script:VrhmToolFolder)) {
            New-Item -ItemType Directory -Path $script:VrhmToolFolder -Force | Out-Null
        }
        Expand-Archive -LiteralPath $zipPath -DestinationPath $script:VrhmToolFolder -Force -ErrorAction Stop
        Write-Host "adb installed in $($script:VrhmToolFolder)." -ForegroundColor Green
    } catch {
        Write-Host "Could not download adb from the server: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    } finally {
        if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue }
    }

    return (Get-VrhmAdbPath)
}

function Stop-VrhmAdbServer {
    <#
    .SYNOPSIS
    Kills the adb server this toolbox started. Idempotent - safe to call from
    Ctrl+C, from the menu and from the exit handler all at once.
    #>
    if ($script:AdbServerStopped) { return }
    $adb = Get-VrhmAdbPath
    if (-not $adb) { return }
    $script:AdbServerStopped = $true
    try { & $adb kill-server 2>$null | Out-Null } catch { }
}

function Invoke-AdbLine {
    <#
    .SYNOPSIS
    Runs "adb -s <serial> <args>" and returns trimmed stdout as a single string.
    Returns an empty string on a non-zero exit code.

    .DESCRIPTION
    The local $ErrorActionPreference is NOT cosmetic. In Windows PowerShell 5.1 a
    native command writing to stderr surfaces as an ErrorRecord, so a caller whose
    preference is Stop turns any ordinary adb failure - "error: closed" while the
    transport re-enumerates, "device not found" between polls - into a terminating
    error that aborts the whole headset. Failure is reported through the exit code
    here, never through an exception.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Serial,
        [Parameter(Mandatory = $true)][string]$Arguments
    )
    $ErrorActionPreference = 'Continue'
    $adb = Get-VrhmAdbPath
    if (-not $adb) { return '' }
    $argList = @('-s', $Serial) + ($Arguments -split '\s+')
    $out = & $adb @argList 2>$null
    if ($LASTEXITCODE -ne 0) { return '' }
    return (($out -join "`n").Trim())
}

function Get-UsbHeadsetLines {
    <#
    .SYNOPSIS
    The "adb devices" lines for authorized, USB-connected devices (no ":" in the
    identifier - that would be a WiFi ADB connection).
    #>
    $ErrorActionPreference = 'Continue'   # see Invoke-AdbLine
    $adb = Get-VrhmAdbPath
    if (-not $adb) { return @() }
    $script:AdbServerStopped = $false
    $devicesOutput = & $adb devices 2>$null
    return @($devicesOutput | Where-Object { $_ -match "`tdevice$" -and $_ -notmatch ':' })
}

function Wait-ForUsbHeadset {
    <#
    .SYNOPSIS
    Blocks, polling every 2 seconds, until a USB-connected headset is found.
    Returns its serial number, or $null when the operator pressed a key to go
    back to the menu.
    #>
    $dots = 0
    while ($true) {
        $line = Get-UsbHeadsetLines | Select-Object -First 1
        if ($line) {
            Write-Host ""
            return ($line -split "`t")[0].Trim()
        }
        # Only Escape or 0 leaves. Any other keypress is ignored, so a technician
        # brushing the keyboard while plugging a headset in does not silently
        # drop out of the waiting loop.
        if (Test-BackKeyPressed) {
            Write-Host ""
            return $null
        }
        $dots = ($dots % 3) + 1
        Write-Host -NoNewline ("`rWaiting for a USB-connected headset" + ('.' * $dots) + '   (Escape or 0 to go back)   ')
        Start-Sleep -Seconds 2
    }
}

function Test-BackKeyPressed {
    <#
    .SYNOPSIS
    $true when Escape or 0 is waiting in the keyboard buffer. Drains anything
    else, so an unrelated keypress neither accumulates nor triggers an action.

    .DESCRIPTION
    Read-Host cannot see Escape - it only returns on Enter - so every "press
    Escape to go back" in this tool reads raw keys instead.
    #>
    $pressed = $false
    while ([Console]::KeyAvailable) {
        $key = [Console]::ReadKey($true)
        if ($key.Key -eq 'Escape' -or $key.KeyChar -eq '0') { $pressed = $true }
    }
    return $pressed
}

function Test-UsbHeadsetPresent {
    <#
    .SYNOPSIS
    $true while the given serial is still cabled over USB.
    #>
    param([Parameter(Mandatory = $true)][string]$Serial)
    return [bool](Get-UsbHeadsetLines | Where-Object { ($_ -split "`t")[0].Trim() -eq $Serial })
}

function Get-HeadsetWifiIp {
    <#
    .SYNOPSIS
    Polls the headset's wlan0 IP address, retrying while the USB transport is
    away.

    .DESCRIPTION
    This is called right after "adb tcpip", which RE-ENUMERATES the USB transport
    - measured at about ten seconds on a Quest 3. Every adb call in that window
    fails with "error: closed" or "device not found", which is normal and not a
    reason to give up. 30 attempts at 1s leaves ample margin over that outage.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Serial,
        [int]$MaxAttempts = 30,
        [int]$DelaySeconds = 1
    )
    for ($i = 0; $i -lt $MaxAttempts; $i++) {
        $ipOutput = Invoke-AdbLine -Serial $Serial -Arguments 'shell ip -f inet addr show wlan0'
        if ($ipOutput -match 'inet\s+(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})/') {
            if ($i -gt 0) { Write-Host "" }
            return $Matches[1]
        }
        if ($i -eq 2) {
            Write-Host -NoNewline "  (the USB link restarts for a few seconds after enabling WiFi ADB - waiting"
        } elseif ($i -gt 2) {
            Write-Host -NoNewline "."
        }
        Start-Sleep -Seconds $DelaySeconds
    }
    if ($MaxAttempts -gt 3) { Write-Host "" }
    return ''
}

function Get-HeadsetCurrentSsid {
    <#
    .SYNOPSIS
    The SSID the headset is currently connected to, or '' when unknown.
    #>
    param([Parameter(Mandatory = $true)][string]$Serial)

    $status = Invoke-AdbLine -Serial $Serial -Arguments 'shell cmd wifi status'
    if ($status -match '\bssid="([^"]+)"')      { return $Matches[1] }
    if ($status -match '\bSSID:\s*"([^"]+)"')   { return $Matches[1] }

    $dump = Invoke-AdbLine -Serial $Serial -Arguments 'shell dumpsys wifi'
    if ($dump -match '\bSSID:\s+"([^"]+)"')     { return $Matches[1] }
    return ''
}

function Get-KnownHeadsetBySerial {
    <#
    .SYNOPSIS
    Looks this serial up in the server's known headsets (GET /api/headsets).
    Returns the matching entry, or $null.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Serial,
        [Parameter(Mandatory = $true)][string]$ServerUrl
    )
    try {
        $headsets = Invoke-RestMethod -Uri ("{0}/api/headsets" -f $ServerUrl.TrimEnd('/')) -Method Get -TimeoutSec 10
    } catch {
        return $null
    }
    if (-not $headsets) { return $null }
    return @($headsets) | Where-Object { $_.SerialNumber -eq $Serial } | Select-Object -First 1
}

function Invoke-VrhmServerWifiPush {
    <#
    .SYNOPSIS
    Asks the SERVER to move this headset onto one of the WiFi networks it knows.

    .DESCRIPTION
    The WiFi password is never sent to this PC and never typed here: the server
    holds it in its encrypted store and performs the push over its own ADB
    connection to the headset. The server scans from the HEADSET's own radio
    first and refuses to push an SSID the headset cannot see (a 6 GHz-only
    network on an older headset, typically) - in that case the headset is left
    on its current network and the reachable alternatives are offered instead.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Serial,
        [Parameter(Mandatory = $true)][string]$ServerUrl,
        [string]$CurrentSsid = ''
    )

    $base = $ServerUrl.TrimEnd('/')

    try {
        # Assign first, THEN filter - never @(Invoke-RestMethod ...) directly.
        # A server with no WiFi networks answers with an empty JSON array, which
        # Invoke-RestMethod hands back as $null, and @($null) is a ONE-element
        # array holding $null - not an empty one. That is what printed a phantom
        # "[1]" with a blank name and offered to push it.
        $raw = Invoke-RestMethod -Uri "$base/api/wifi-networks" -Method Get -TimeoutSec 10
    } catch {
        Write-Host "Could not read the WiFi networks from the server: $($_.Exception.Message)" -ForegroundColor Yellow
        return
    }

    $networks = @($raw | Where-Object { $_ -and $_.ssid })

    if ($networks.Count -eq 0) {
        Write-Host ""
        Write-Host "This VR HEADSET MANAGER server has no WiFi network registered, so there is nothing to push." -ForegroundColor Yellow
        Write-Host "Add one on the server first (Configuration -> WiFi networks), then run this again." -ForegroundColor DarkGray
        Write-Host "The headset stays on '$CurrentSsid'." -ForegroundColor DarkGray
        return
    }

    $preferred = @($networks | Where-Object { $_.preferred }) | Select-Object -First 1
    $defaultIndex = 1
    Write-Host ""
    if ($CurrentSsid) {
        Write-Host "The headset is currently on WiFi network '$CurrentSsid'."
    }
    Write-Host "WiFi networks known to the server:"
    for ($i = 0; $i -lt $networks.Count; $i++) {
        $mark = ""
        if ($preferred -and $networks[$i].ssid -eq $preferred.ssid) {
            $mark = "  (preferred)"
            $defaultIndex = $i + 1
        }
        Write-Host ("  [{0}] {1}{2}" -f ($i + 1), $networks[$i].ssid, $mark)
    }
    Write-Host "  [S] Skip - leave the headset on its current network"
    Write-Host ""

    $answer = Read-Host "Push which network to the headset? [$defaultIndex]"
    if ($answer -match '^(?i)s') { return }
    $index = $defaultIndex
    if ($answer) {
        $parsedIndex = 0
        if (-not ([int]::TryParse($answer, [ref]$parsedIndex)) -or $parsedIndex -lt 1 -or $parsedIndex -gt $networks.Count) {
            Write-Host "Not a valid choice - skipping the WiFi step." -ForegroundColor Yellow
            return
        }
        $index = $parsedIndex
    }
    $ssid = [string]$networks[$index - 1].ssid

    Write-Host "Asking the server to push '$ssid' to the headset..." -ForegroundColor Cyan
    $payload = @{ serialNumber = $Serial; ssid = $ssid } | ConvertTo-Json -Compress
    try {
        $result = Invoke-RestMethod -Uri "$base/api/headsets/push-wifi" -Method Post `
                                    -ContentType 'application/json; charset=utf-8' `
                                    -Body $payload -TimeoutSec 90
    } catch {
        Write-Host "The server could not be reached for the WiFi push: $($_.Exception.Message)" -ForegroundColor Red
        return
    }

    if ($result.ok -and $result.pushed) {
        Write-Host "The headset was moved to '$ssid'." -ForegroundColor Green
        return
    }

    if ($result.visible -eq $false) {
        Write-Host "The headset cannot see '$ssid' - nothing was pushed, it stays on its current network." -ForegroundColor Yellow
        # Same $null-wrapping trap as the network list above: filter, do not just
        # wrap - an absent visibleKnown would otherwise print one blank bullet.
        $alternatives = @($result.visibleKnown | Where-Object { $_ })
        if ($alternatives.Count -gt 0) {
            Write-Host "Networks the headset CAN see and the server knows the password for:" -ForegroundColor Yellow
            foreach ($alt in $alternatives) { Write-Host "  - $alt" }
            $retry = Read-Host "Push one of these instead? Type the exact name, or leave empty to skip"
            if ($retry -and ($alternatives -contains $retry)) {
                $payload2 = @{ serialNumber = $Serial; ssid = $retry } | ConvertTo-Json -Compress
                try {
                    $result2 = Invoke-RestMethod -Uri "$base/api/headsets/push-wifi" -Method Post `
                                                 -ContentType 'application/json; charset=utf-8' `
                                                 -Body $payload2 -TimeoutSec 90
                    if ($result2.ok -and $result2.pushed) {
                        Write-Host "The headset was moved to '$retry'." -ForegroundColor Green
                    } else {
                        Write-Host "Push refused: $($result2.error)" -ForegroundColor Red
                    }
                } catch {
                    Write-Host "The server could not be reached: $($_.Exception.Message)" -ForegroundColor Red
                }
            }
        }
        return
    }

    Write-Host "WiFi push did not succeed: $($result.error)" -ForegroundColor Red
}

function Get-VrhmWifiAdbApkInfo {
    <#
    .SYNOPSIS
    What the server's WiFi ADB APK is - package name, file name, size - without
    downloading it. $null when the server does not offer it (an older server has
    no such endpoint).

    .EXAMPLE
    $info = Get-VrhmWifiAdbApkInfo -ServerUrl 'http://192.168.1.37:8080'
    #>
    param([Parameter(Mandatory = $true)][string]$ServerUrl)

    try {
        $info = Invoke-RestMethod -Uri ("{0}/api/adb-wifi-apk/info" -f $ServerUrl.TrimEnd('/')) -Method Get -TimeoutSec 10
        if ($info -and $info.ok) { return $info }
    } catch { }
    return $null
}

function Test-HeadsetAppInstalled {
    <#
    .SYNOPSIS
    $true when the given package is installed on the headset, $false when it is
    not, $null when the question could not be answered (adb unavailable, the
    transport away, or no package name to look for).

    .DESCRIPTION
    $null is deliberately distinct from $false: "I could not ask" must not be
    reported to the operator as "it is not installed".
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Serial,
        [string]$PackageName
    )

    if (-not $PackageName) { return $null }

    # "pm list packages <filter>" does a substring match, so the exact name is
    # confirmed against the returned lines rather than trusted from the exit code.
    $out = Invoke-AdbLine -Serial $Serial -Arguments "shell pm list packages $PackageName"
    if (-not $out) {
        # Tell an empty answer ("not installed") apart from a dead transport by
        # asking something that always answers when adb is healthy.
        $probe = Invoke-AdbLine -Serial $Serial -Arguments 'shell echo ok'
        if ($probe -ne 'ok') { return $null }
        return $false
    }

    foreach ($line in ($out -split "`n")) {
        if ($line.Trim() -eq "package:$PackageName") { return $true }
    }
    return $false
}

function Install-VrhmWifiAdbApk {
    <#
    .SYNOPSIS
    Downloads the WiFi ADB helper APK from the server and installs it on the
    headset. The APK is never bundled in the toolbox binary - it always comes
    from the server, so it stays in step with what the server ships.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Serial,
        [Parameter(Mandatory = $true)][string]$ServerUrl
    )

    $ErrorActionPreference = 'Continue'   # see Invoke-AdbLine
    $adb = Get-VrhmAdbPath
    if (-not $adb) { return }

    $apkPath = Join-Path $env:TEMP ("vrhm_adb_wifi_{0}.apk" -f ([guid]::NewGuid().ToString('N')))
    try {
        Write-Host "Downloading the WiFi ADB app from the server..." -ForegroundColor Cyan
        Invoke-WebRequest -Uri ("{0}/api/adb-wifi-apk" -f $ServerUrl.TrimEnd('/')) `
                          -OutFile $apkPath -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
    } catch {
        Write-Host "Could not download the APK from the server: $($_.Exception.Message)" -ForegroundColor Red
        if (Test-Path -LiteralPath $apkPath) { Remove-Item -LiteralPath $apkPath -Force -ErrorAction SilentlyContinue }
        return
    }

    try {
        Write-Host "Installing it on the headset..." -ForegroundColor Cyan
        $out = & $adb -s $Serial install -r $apkPath 2>&1
        if ($LASTEXITCODE -eq 0 -and ($out -join ' ') -match '(?i)success') {
            Write-Host "WiFi ADB app installed." -ForegroundColor Green
        } else {
            Write-Host "Install failed: $(($out -join ' ').Trim())" -ForegroundColor Red
        }
    } catch {
        Write-Host "Install failed: $($_.Exception.Message)" -ForegroundColor Red
    } finally {
        if (Test-Path -LiteralPath $apkPath) { Remove-Item -LiteralPath $apkPath -Force -ErrorAction SilentlyContinue }
    }
}

function Invoke-HeadsetRegistration {
    <#
    .SYNOPSIS
    The DEFAULT work for one already-detected USB serial, and nothing more:
    read the identity, enable WiFi ADB, confirm it, and register the headset
    with the server.

    .DESCRIPTION
    Deliberately no prompts beyond the display name. Enabling WiFi ADB is the one
    thing a technician always wants; changing the WiFi network and installing the
    helper app are occasional, so they live in the menu that follows instead of
    being asked about on every single headset.

    Returns a hashtable describing the headset on success, $null on failure.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Serial,
        [Parameter(Mandatory = $true)][string]$ServerUrl
    )

    $ErrorActionPreference = 'Continue'   # see Invoke-AdbLine - this function calls adb directly too
    $adb      = Get-VrhmAdbPath
    $adbPort  = $script:VrhmAdbPort

    Write-Host "USB headset detected (serial: $Serial)." -ForegroundColor Green

    $manufacturer = Invoke-AdbLine -Serial $Serial -Arguments 'shell getprop ro.product.manufacturer'
    $model = ''
    if ($manufacturer -match '(?i)pico') {
        $model = Invoke-AdbLine -Serial $Serial -Arguments 'shell getprop pxr.vendorhw.product.model'
        if (-not $model) { $model = Invoke-AdbLine -Serial $Serial -Arguments 'shell getprop sys.pxr.product.name' }
        if (-not $model) { $model = Invoke-AdbLine -Serial $Serial -Arguments 'shell getprop ro.product.model' }
    } else {
        $model = Invoke-AdbLine -Serial $Serial -Arguments 'shell getprop ro.product.model'
    }
    if (-not $model) { $model = 'Unknown model' }
    Write-Host "Model: $model"

    $currentSsid = Get-HeadsetCurrentSsid -Serial $Serial
    if ($currentSsid) { Write-Host "Connected to WiFi network: $currentSsid" }

    Write-Host "Enabling WiFi ADB (tcpip $adbPort)..."
    Invoke-AdbLine -Serial $Serial -Arguments "tcpip $adbPort" | Out-Null

    Write-Host "Checking the headset's WiFi IP address..."
    $ip = Get-HeadsetWifiIp -Serial $Serial

    if (-not $ip) {
        Write-Host "Could not read the headset's WiFi IP address." -ForegroundColor Red
        Write-Host "Make sure the headset is connected to a WiFi network, then try again." -ForegroundColor Red
        return
    }

    Write-Host "WiFi IP: $ip" -ForegroundColor Green
    Write-Host "Confirming the WiFi ADB session..."
    & $adb connect "${ip}:${adbPort}" 2>$null | Out-Null
    Start-Sleep -Seconds 1
    $connected = & $adb devices 2>$null | Where-Object { $_ -match ("^" + [regex]::Escape("${ip}:${adbPort}") + "\s+device$") }
    if (-not $connected) {
        Write-Host "WiFi ADB did not come up on ${ip}:${adbPort} yet. It may need a few more seconds - the headset will still be registered with the IP found." -ForegroundColor Yellow
    } else {
        Write-Host "WiFi ADB confirmed on ${ip}:${adbPort}." -ForegroundColor Green
    }

    $known = Get-KnownHeadsetBySerial -Serial $Serial -ServerUrl $ServerUrl
    if ($known) {
        Write-Host "Headset already known to VR HEADSET MANAGER as '$($known.Name)' - only its IP address will be updated."
        $nameInput = $known.Name
    } else {
        $defaultName = if ($model -and $model -ne 'Unknown model') { $model } else { "Headset $Serial" }
        $nameInput = Read-Host "Headset display name [$defaultName]"
        if (-not $nameInput) { $nameInput = $defaultName }
    }

    $payload = @{
        serialNumber = $Serial
        ip           = $ip
        name         = $nameInput
        model        = $model
    } | ConvertTo-Json -Compress

    Write-Host "Registering with the VR HEADSET MANAGER server ($ServerUrl)..."
    try {
        $response = Invoke-RestMethod -Uri ("{0}/api/headsets/register-by-serial" -f $ServerUrl.TrimEnd('/')) `
                                       -Method Post -ContentType 'application/json; charset=utf-8' `
                                       -Body $payload -TimeoutSec 10
    } catch {
        Write-Host "Could not reach the VR HEADSET MANAGER server at $ServerUrl." -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
        return
    }

    if (-not $response.ok) {
        Write-Host "Server rejected the request: $($response.error)" -ForegroundColor Red
        return
    }

    if ($response.action -eq 'added') {
        Write-Host "Headset '$($response.name)' added to VR HEADSET MANAGER (ID $($response.id))." -ForegroundColor Green
    } else {
        # Set-HeadsetBySerial on the server keys on the serial, so a headset that
        # moved to a new address is corrected here rather than duplicated.
        Write-Host "Headset '$($response.name)' already known - IP address updated (ID $($response.id))." -ForegroundColor Green
    }

    return @{
        Ok           = $true
        Serial       = $Serial
        Name         = [string]$response.name
        Ip           = $ip
        Model        = $model
        Manufacturer = $manufacturer
        CurrentSsid  = $currentSsid
    }
}

function Test-IsMetaHeadset {
    <#
    .SYNOPSIS
    $true for a Meta/Oculus headset. The WiFi ADB helper app is a Quest app and
    does nothing on a Pico or any other brand, so it is not offered there.
    #>
    param([string]$Manufacturer, [string]$Model)
    return [bool](("$Manufacturer $Model") -match '(?i)oculus|meta|quest')
}

function Invoke-HeadsetApkStep {
    <#
    .SYNOPSIS
    The "install the wireless ADB app" action. Reports why it cannot run rather
    than failing silently.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Serial,
        [Parameter(Mandatory = $true)][string]$ServerUrl,
        [object]$ApkInfo
    )

    if ($ApkInfo -and -not $ApkInfo.available) {
        Write-Host "This server does not ship the WiFi ADB app, so it cannot be installed from here." -ForegroundColor Yellow
        return
    }

    $installed = Test-HeadsetAppInstalled -Serial $Serial -PackageName $(if ($ApkInfo) { $ApkInfo.packageName } else { $null })
    if ($installed -eq $true) {
        Write-Host "The WiFi ADB app is already installed on this headset ($($ApkInfo.packageName)) - nothing to do." -ForegroundColor Green
        return
    }

    Install-VrhmWifiAdbApk -Serial $Serial -ServerUrl $ServerUrl
}

function Show-HeadsetActionMenu {
    <#
    .SYNOPSIS
    The per-headset menu shown once WiFi ADB is on and the headset is registered.

    .DESCRIPTION
    Returns 'menu' when the operator asked to go back to the main menu, or
    'disconnected' when the headset was unplugged. The menu does not block on
    Read-Host: it polls the keyboard AND the USB transport, so unplugging a
    headset moves straight on to waiting for the next one, which is how a
    technician actually works through a shelf of them.

    .EXAMPLE
    $outcome = Show-HeadsetActionMenu -Headset $reg -ServerUrl $url
    #>
    param(
        [Parameter(Mandatory = $true)][hashtable]$Headset,
        [Parameter(Mandatory = $true)][string]$ServerUrl
    )

    $isMeta  = Test-IsMetaHeadset -Manufacturer $Headset.Manufacturer -Model $Headset.Model
    $apkInfo = if ($isMeta) { Get-VrhmWifiAdbApkInfo -ServerUrl $ServerUrl } else { $null }

    $redraw = $true
    $lastPresenceCheck = Get-Date

    while ($true) {
        if ($redraw) {
            $redraw = $false
            Write-Host ""
            Write-Host ("--- {0} ({1}) - {2} ---" -f $Headset.Name, $Headset.Model, $Headset.Ip) -ForegroundColor Cyan
            $ssidText = if ($Headset.CurrentSsid) { $Headset.CurrentSsid } else { "unknown" }
            Write-Host ("  [1] Update WiFi network        (currently on: {0})" -f $ssidText)
            if ($isMeta) {
                Write-Host "  [2] Install wireless ADB app"
            } else {
                Write-Host "  [2] Install wireless ADB app   - not available on this brand" -ForegroundColor DarkGray
            }
            Write-Host "  [0] Back to the main menu      (or press Escape)"
            Write-Host ""
            Write-Host "  Unplug the headset to move on to the next one." -ForegroundColor DarkGray
            Write-Host "  Ctrl + C closes the toolbox." -ForegroundColor DarkGray
            Write-Host ""
            Write-Host -NoNewline "Choice: "
        }

        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            $char = $key.KeyChar

            if ($key.Key -eq 'Escape' -or $char -eq '0') {
                Write-Host "0"
                return 'menu'
            }

            switch ($char) {
                '1' {
                    Write-Host "1"
                    # Re-read the SSID rather than trusting the one captured at
                    # registration: a previous push in this same session may have
                    # already moved the headset somewhere else.
                    $Headset.CurrentSsid = Get-HeadsetCurrentSsid -Serial $Headset.Serial
                    Invoke-VrhmServerWifiPush -Serial $Headset.Serial -ServerUrl $ServerUrl -CurrentSsid $Headset.CurrentSsid
                    $Headset.CurrentSsid = Get-HeadsetCurrentSsid -Serial $Headset.Serial
                    $redraw = $true
                }
                '2' {
                    Write-Host "2"
                    if ($isMeta) {
                        Invoke-HeadsetApkStep -Serial $Headset.Serial -ServerUrl $ServerUrl -ApkInfo $apkInfo
                    } else {
                        Write-Host "The wireless ADB app is a Meta Quest app - it does nothing on this headset." -ForegroundColor Yellow
                    }
                    $redraw = $true
                }
                default { }
            }
            continue
        }

        # Poll the cable every couple of seconds, not every tick: each check is an
        # "adb devices" process.
        if (((Get-Date) - $lastPresenceCheck).TotalSeconds -ge 2) {
            $lastPresenceCheck = Get-Date
            if (-not (Test-UsbHeadsetPresent -Serial $Headset.Serial)) {
                Write-Host ""
                Write-Host "Headset unplugged." -ForegroundColor DarkGray
                return 'disconnected'
            }
        }

        Start-Sleep -Milliseconds 200
    }
}

function Invoke-VrhmHeadsetOnboarding {
    <#
    .SYNOPSIS
    The Headset Toolbox menu entry: waits for a headset over USB, onboards it,
    offers the per-headset actions, then goes back to waiting when it is
    unplugged - continuously, until Escape or 0 returns to the main menu.

    .EXAMPLE
    Invoke-VrhmHeadsetOnboarding -ServerUrl 'http://192.168.1.37:8080'
    #>
    param([Parameter(Mandatory = $true)][string]$ServerUrl)

    $adb = Get-VrhmAdbPath
    if (-not $adb) {
        $adb = Install-VrhmAdbTools -ServerUrl $ServerUrl
    }
    if (-not $adb) {
        Write-Host "adb is not available, so headsets cannot be managed from this PC." -ForegroundColor Red
        Write-Host "Connect to a VR HEADSET MANAGER server once, so adb can be downloaded." -ForegroundColor Red
        return
    }

    Write-Host ""
    Write-Host "=== Headset Toolbox ===" -ForegroundColor Cyan
    Write-Host "Plug a headset in over USB - WiFi ADB is enabled and the headset registered automatically." -ForegroundColor DarkGray
    Write-Host "Escape or 0 goes back to the main menu, Ctrl + C closes the toolbox." -ForegroundColor DarkGray
    Write-Host ""

    while ($true) {
        $serial = Wait-ForUsbHeadset
        if (-not $serial) { return }

        $registered = $null
        try {
            $registered = Invoke-HeadsetRegistration -Serial $serial -ServerUrl $ServerUrl
        } catch {
            Write-Host "Unexpected error while processing this headset: $($_.Exception.Message)" -ForegroundColor Red
        }

        if ($registered -and $registered.Ok) {
            $outcome = Show-HeadsetActionMenu -Headset $registered -ServerUrl $ServerUrl
            if ($outcome -eq 'menu') { return }
            # 'disconnected' - fall through and wait for the next headset.
        } else {
            # Nothing more can be done with this one; wait for it to be unplugged
            # so the next plug-in is a genuinely new event rather than this same
            # serial being picked up again immediately.
            Write-Host ""
            Write-Host "Unplug this headset to continue, or press Escape / 0 to go back to the main menu..." -ForegroundColor DarkGray
            while (Test-UsbHeadsetPresent -Serial $serial) {
                if (Test-BackKeyPressed) { Write-Host ""; return }
                Start-Sleep -Seconds 2
            }
        }

        Write-Host ""
    }
}
