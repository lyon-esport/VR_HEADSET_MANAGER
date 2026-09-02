#Requires -Version 5.1
<#
.SYNOPSIS
    Section 80 - Apps manager: installed-apps listing, foreground app, and (with
    -AllowDestructive) a real install/uninstall round trip.

.DESCRIPTION
    Dot-sourced by scripts\Invoke-NonRegressionTests.ps1 inside a section
    context.

    NEEDS HARDWARE - a reachable headset (ping + ADB port), same resolution as
    sections 50/60 via Resolve-NrtTestHeadset. SKIPs the whole section (never
    FAILs) when nothing is reachable or the run is -Unattended.

    Read-only checks (installed apps list, foreground app) always run once a
    headset is registered and ADB is up. The install/uninstall round trip is
    gated behind -AllowDestructive AND a USB-connected device (POST
    /api/installadbwifiapk only ever targets whatever is on USB right now, per
    its own implementation) - it uses the bundled "ADB Wireless activator" APK
    as its subject, exactly as the -AllowDestructive doc comment on the entry
    script promises, and always ends with the APK re-installed (the state a
    WiFi-ADB headset needs to keep working across reboots), whatever state it
    started in.

    ASCII only (CLAUDE.md rule 1).
#>

$target     = $global:TestRun.TargetRoot
$devRoot    = $global:TestRun.DevRoot
$appUp      = Confirm-SandboxApp -TargetRoot $target -DevRoot $devRoot
$ports      = Get-NrtSandboxPorts -TargetRoot $target
$nrtHeadset = Resolve-NrtTestHeadset -DevRoot $devRoot -AdbPort $ports.Adb
$nrtSafeName = ''
if ($nrtHeadset) { $nrtSafeName = ConvertTo-NrtSafeName -Name $nrtHeadset.Name }

function Assert-Nrt80HeadsetAvailable {
    if (-not $nrtHeadset) {
        Skip-Test 'no reachable headset in the dev registry (ping + ADB port) - pass -HeadsetName to force one'
    }
}

function Register-Nrt80Headset {
    $existing = Invoke-VrmApi -Path '/api/headsets'
    $already  = $false
    if ($existing.Json) { $already = @($existing.Json | Where-Object { $_.Name -eq $nrtHeadset.Name }).Count -gt 0 }
    if (-not $already) {
        $add = Add-NrtSandboxHeadset -Headset $nrtHeadset
        if (-not $add.Ok) { return $false }
    }
    return (Wait-NrtHeadsetAdb -TargetRoot $target -Name $nrtHeadset.Name -TimeoutSec 90)
}

function Get-Nrt80InstalledApps {
    param([switch]$Refresh)
    $path = "/api/installedapps?name={0}&includeSystem=1" -f $nrtSafeName
    if ($Refresh) { $path += '&refresh=1' }
    return (Invoke-VrmApi -Path $path -TimeoutSec 60)
}

Invoke-RegressionTest -Name 'A real headset is available for apps tests' -Test {
    Assert-Nrt80HeadsetAvailable
    Assert-True (Register-Nrt80Headset) ("VRMonitor never reported ADBWifi for '{0}'" -f $nrtHeadset.Name)
    Add-TestEvidence ("headset: {0}  model {1}" -f $nrtHeadset.Name, $nrtHeadset.Model)
}

Invoke-RegressionTest -Name 'App is running' -Test {
    Assert-True $appUp 'the sandbox app is not running'
}

# ---------------------------------------------------------------------------
# Read-only
# ---------------------------------------------------------------------------

Invoke-RegressionTest -Name 'Installed apps list returns real data' -Test {
    Assert-Nrt80HeadsetAvailable

    $r = Get-Nrt80InstalledApps -Refresh
    Assert-True $r.Ok ('GET /api/installedapps returned HTTP ' + $r.StatusCode)
    Assert-NotNull $r.Json 'installedapps body'

    $apps = @($r.Json)
    Add-TestEvidence ("{0} app(s) reported" -f $apps.Count)
    Assert-True ($apps.Count -gt 0) 'a real headset must report at least one installed app'

    foreach ($a in ($apps | Select-Object -First 3)) {
        Add-TestEvidence ("{0} -> '{1}'" -f $a.package, $a.displayName)
        Assert-NotNull $a.package 'app.package'
        Assert-Match $a.package '^[\w\.]+$' 'package name shape'
    }
}

Invoke-RegressionTest -Name 'Apps resolve to display names via known_apps.csv' -Test {
    Assert-Nrt80HeadsetAvailable

    $r = Get-Nrt80InstalledApps
    Assert-True $r.Ok ('GET /api/installedapps returned HTTP ' + $r.StatusCode)
    $apps = @($r.Json)
    if ($apps.Count -eq 0) { Skip-Test 'no installed apps to resolve' }

    $withDisplayName = @($apps | Where-Object { $_.displayName -and $_.displayName -ne $_.package })
    Add-TestEvidence ("{0} of {1} app(s) have a resolved display name" -f $withDisplayName.Count, $apps.Count)
}

Invoke-RegressionTest -Name 'Foreground app reports a plausible package' -Test {
    Assert-Nrt80HeadsetAvailable

    $r = Invoke-VrmApi -Path ("/api/foregroundapp?name={0}" -f $nrtSafeName) -TimeoutSec 20
    Assert-True $r.Ok ('GET /api/foregroundapp returned HTTP ' + $r.StatusCode)
    Assert-NotNull $r.Json 'foregroundapp body'
    Assert-True ($r.Json.PSObject.Properties.Name -contains 'package') 'foregroundapp.package field'

    Add-TestEvidence ("package: '{0}'  displayName: '{1}'" -f $r.Json.package, $r.Json.displayName)
    if ($r.Json.package) {
        Assert-Match ([string]$r.Json.package) '^[\w\.]+$' 'foreground package name shape'
    }
    else {
        Write-TestWarning 'headset reported no foreground app (asleep, or between apps) - package/display checks skipped'
    }
}

# ---------------------------------------------------------------------------
# Install / uninstall round trip - destructive, USB required
# ---------------------------------------------------------------------------

Invoke-RegressionTest -Name 'Install and uninstall the wireless-ADB-activator APK (USB required)' -Test {
    Assert-Nrt80HeadsetAvailable
    if (-not $global:TestRun.AllowDestructive) {
        Skip-Test 'destructive install/uninstall test requires -AllowDestructive'
    }

    $usb = Invoke-VrmApi -Path '/api/usbdeviceinfo'
    if (-not ($usb.Ok -and $usb.Json -and $usb.Json.found)) {
        Skip-Test 'no USB-connected headset - plug the test headset into USB for this destructive check (POST /api/installadbwifiapk only targets USB)'
    }
    Add-TestEvidence ("USB device: model={0} serial={1} - assumed to be the same unit as '{2}'" -f $usb.Json.model, $usb.Json.serialNumber, $nrtHeadset.Name)

    $pkg = Invoke-InTargetModules -TargetRoot $target -Body { $global:ADBWirelessActivatorPackageName }
    Assert-NotNull $pkg 'global:ADBWirelessActivatorPackageName'
    Add-TestEvidence ("package under test: {0}" -f $pkg)

    $before = Get-Nrt80InstalledApps -Refresh
    $wasPresent = @($before.Json | Where-Object { $_.package -eq $pkg }).Count -gt 0
    Add-TestEvidence ("present before this test: {0}" -f $wasPresent)

    try {
        if ($wasPresent) {
            $uninstall = Invoke-VrmApi -Path '/api/uninstallapp' -Method POST -Body @{ name = $nrtSafeName; package = $pkg } -TimeoutSec 30
            Assert-VrmOk -Result $uninstall -Label 'uninstall before the round trip'

            $afterUninstall = Get-Nrt80InstalledApps -Refresh
            $stillThere = @($afterUninstall.Json | Where-Object { $_.package -eq $pkg }).Count -gt 0
            Add-TestEvidence ("present after uninstall: {0}" -f $stillThere)
            Assert-False $stillThere ("'{0}' must be gone from /api/installedapps after uninstall" -f $pkg)
        }

        # Install-OculusWirelessAdbApk (behind this endpoint) installs OR
        # reinstalls, so this step also covers the "was already present" case.
        $install = Invoke-VrmApi -Path '/api/installadbwifiapk' -Method POST -TimeoutSec 60
        Assert-True $install.Ok ('POST /api/installadbwifiapk returned HTTP ' + $install.StatusCode)
        Add-TestEvidence ("install response: ok={0} model={1} ip={2}" -f $install.Json.ok, $install.Json.model, $install.Json.ip)
        Assert-True ([bool]$install.Json.ok) 'Install-OculusWirelessAdbApk reported failure'

        $afterInstall = Get-Nrt80InstalledApps -Refresh
        $nowPresent = @($afterInstall.Json | Where-Object { $_.package -eq $pkg }).Count -gt 0
        Add-TestEvidence ("present after install: {0}" -f $nowPresent)
        Assert-True $nowPresent ("'{0}' must appear in /api/installedapps after a successful install" -f $pkg)
    }
    catch {
        # Leave the activator installed even on failure - it is what keeps this
        # headset's WiFi ADB working across reboots, and repairing on error
        # matters more here than on the happy path.
        Invoke-VrmApi -Path '/api/installadbwifiapk' -Method POST -TimeoutSec 60 | Out-Null
        throw
    }
}
