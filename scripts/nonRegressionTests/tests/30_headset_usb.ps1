#Requires -Version 5.1
<#
.SYNOPSIS
    Section 30 - USB onboarding: detection, WiFi-ADB bridging, and IP self-heal
    by serial number.

.DESCRIPTION
    Dot-sourced by scripts\Invoke-NonRegressionTests.ps1 inside a section
    context.

    NEEDS HARDWARE - a headset connected over USB with "Allow USB debugging"
    already accepted (or accepted when prompted on the device). SKIPs the
    whole section (never FAILs) when nothing is found and the run is
    -Unattended, mirroring how sections 50/60 stay green with no headset
    configured.

    GET /api/usbdeviceinfo is answered from a persistent background probe job
    (web_server.ps1) that refreshes every ~3s, not synchronously - every read
    here polls rather than expecting an instant answer.

    What this proves, in order:
      - a USB-connected headset is detected with real serial/model/SSID data
      - enabling WiFi ADB (Enable-AdbTcpIp, via the same endpoint the web UI
        button calls) actually results in the headset answering on that IP,
        not just an HTTP 200
      - Invoke-UsbHeadsetActions heals a stale IP in the registry by matching
        the device's serial number the next time it is seen on USB

    ASCII only (CLAUDE.md rule 1).
#>

$target = $global:TestRun.TargetRoot
$appUp  = Confirm-SandboxApp -TargetRoot $target

$nrtName = 'NRT_UsbOnboard'

function Get-Nrt30UsbInfo {
    $r = Invoke-VrmApi -Path '/api/usbdeviceinfo'
    if ($r.Ok -and $r.Json) { return $r.Json }
    return $null
}

function Wait-Nrt30UsbInfo {
    param([int]$TimeoutSec = 20, [bool]$WantFound = $true)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $last = $null
    while ((Get-Date) -lt $deadline) {
        $last = Get-Nrt30UsbInfo
        if ($last -and [bool]$last.found -eq $WantFound) { return $last }
        Start-Sleep -Milliseconds 1000
    }
    return $last
}

# Silent pre-check first - a headset can already be sitting on USB from a
# previous section (50/60 use Invoke-NrtEnableUsbWifiAdb, which needs USB).
$nrtUsb = Wait-Nrt30UsbInfo -TimeoutSec 6

$unattended = ($global:TestRun -and $global:TestRun.Unattended)
if (-not ($nrtUsb -and $nrtUsb.found) -and -not $unattended) {
    $confirmed = Wait-OperatorAction `
        -Message 'Connect a headset over USB and accept the "Allow USB debugging" prompt on the device, then press Enter.' `
        -Hint 'This section tests USB onboarding: WiFi-ADB bridging and IP self-heal by serial number.'
    if ($confirmed) {
        $nrtUsb = Wait-Nrt30UsbInfo -TimeoutSec 30
    }
}

function Assert-Nrt30UsbAvailable {
    if (-not ($nrtUsb -and $nrtUsb.found)) {
        Skip-Test 'no USB-connected headset detected (GET /api/usbdeviceinfo found=false)'
    }
}

Invoke-RegressionTest -Name 'App is running' -Test {
    Assert-True $appUp 'the sandbox app is not running'
}

Invoke-RegressionTest -Name 'A USB-connected headset is detected' -Test {
    Assert-Nrt30UsbAvailable
    Add-TestEvidence ("model: {0}  brand: {1}" -f $nrtUsb.model, $nrtUsb.brand)
    Add-TestEvidence ("serial: {0}" -f $nrtUsb.serialNumber)
    Add-TestEvidence ("ssid: {0}  expected: {1}  match: {2}" -f $nrtUsb.ssid, $nrtUsb.expectedSsid, $nrtUsb.ssidMatch)
}

Invoke-RegressionTest -Name 'USB device details include a real serial number and model' -Test {
    Assert-Nrt30UsbAvailable
    Assert-NotNull $nrtUsb.serialNumber 'usbdeviceinfo.serialNumber'
    Assert-NotNull $nrtUsb.model 'usbdeviceinfo.model'
    Add-TestEvidence ("wifiAdbOpen={0} apkInstalled={1} alreadyRegistered={2}" -f $nrtUsb.wifiAdbOpen, $nrtUsb.apkInstalled, $nrtUsb.alreadyRegistered)
}

# ---------------------------------------------------------------------------
# Bridging to WiFi ADB
# ---------------------------------------------------------------------------

Invoke-RegressionTest -Name 'Enabling WiFi ADB bridges the headset onto the network' -Test {
    Assert-Nrt30UsbAvailable

    $r = Invoke-VrmApi -Path '/api/enablewifiadb' -Method POST -TimeoutSec 30
    Assert-True $r.Ok ('POST /api/enablewifiadb returned HTTP ' + $r.StatusCode)
    Assert-NotNull $r.Json 'enablewifiadb response body'
    Add-TestEvidence ("response: ok={0} ip={1} port={2}" -f $r.Json.ok, $r.Json.ip, $r.Json.port)
    Assert-True ([bool]$r.Json.ok) 'Enable-AdbTcpIp reported failure'
    Assert-NotNull $r.Json.ip 'a WiFi IP for the bridged headset'

    # Not just an HTTP 200 - the headset must actually answer on that IP:port.
    $reachable = $false
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline -and -not $reachable) {
        $reachable = Test-NrtHeadsetReachable -IPAddress ([string]$r.Json.ip) -AdbPort ([int]$r.Json.port)
        if (-not $reachable) { Start-Sleep -Milliseconds 1000 }
    }
    Add-TestEvidence ("reachable at {0}:{1} = {2}" -f $r.Json.ip, $r.Json.port, $reachable)
    Assert-True $reachable 'the headset must answer ping + the ADB port after being bridged onto WiFi'
}

# ---------------------------------------------------------------------------
# IP self-heal by serial number
# ---------------------------------------------------------------------------

Invoke-RegressionTest -Name 'A stale registered IP is healed by serial number over USB' -Test {
    Assert-Nrt30UsbAvailable

    Invoke-VrmApi -Path '/api/removeheadset' -Method POST -Body @{ name = $nrtName } | Out-Null

    $staleIp = '192.0.2.99'
    try {
        $add = Invoke-VrmApi -Path '/api/addheadset' -Method POST -Body @{
            name = $nrtName; ip = $staleIp; model = $nrtUsb.model; serialNumber = $nrtUsb.serialNumber
        }
        Assert-VrmOk -Result $add -Label 'register with a deliberately wrong IP'

        $config = Read-JsonFileUtf8 -Path (Get-SandboxPaths -TargetRoot $target).ConfigFile
        $refreshSec = 5
        if ($config -and $config.VRMonitor -and $config.VRMonitor.refresh_timer) {
            $refreshSec = [int]$config.VRMonitor.refresh_timer
        }
        $waitSec = $refreshSec + 20
        Add-TestEvidence ("registered '{0}' with stale IP {1}, waiting up to {2}s for Invoke-UsbHeadsetActions to heal it" -f $nrtName, $staleIp, $waitSec)

        $paths = Get-SandboxPaths -TargetRoot $target
        $deadline = (Get-Date).AddSeconds($waitSec)
        $healed = $false
        $observedIp = $staleIp
        while ((Get-Date) -lt $deadline -and -not $healed) {
            try {
                $row = @(Import-Csv -LiteralPath $paths.KnownHeadsets -Encoding UTF8) | Where-Object { $_.Name -eq $nrtName } | Select-Object -First 1
                if ($row) {
                    $observedIp = $row.IPAddress
                    if ($observedIp -ne $staleIp -and $observedIp -eq $nrtUsb.ip) { $healed = $true }
                }
            }
            catch { }
            if (-not $healed) { Start-Sleep -Milliseconds 1500 }
        }

        Add-TestEvidence ("IPAddress column: {0} -> {1}" -f $staleIp, $observedIp)
        Assert-True $healed ("known_headsets.csv IPAddress for '{0}' must self-heal from '{1}' to the real WiFi IP '{2}'" -f $nrtName, $staleIp, $nrtUsb.ip)
    }
    finally {
        Invoke-VrmApi -Path '/api/removeheadset' -Method POST -Body @{ name = $nrtName } | Out-Null
    }
}
