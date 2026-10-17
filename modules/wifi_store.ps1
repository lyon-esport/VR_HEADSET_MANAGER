###############################################################
# wifi_store.ps1
# WiFi store and this PC's WLAN profiles: the DPAPI-encrypted
# data\wifi_networks.dat (Get/Save-WifiNetworks) and the netsh WLAN
# profile readers behind Get-ComputerWifiInfo. Split out of utils.ps1 (S9-1).
# Auto-loaded by scripts_init.ps1.
# ASCII only (no em dashes, no curly quotes, no accents).
###############################################################


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
        $encrypted = Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop
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
        Write-Log ($msg.Wifi.NetworksFileCorrupt) -Level WARNING
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
    Write-Log ($msg.Wifi.NetworksSaved -f $Networks.Count) -Level DEBUG
}


# Returns the names of all WLAN profiles saved on this computer (these are the
# real SSIDs, unlike the Windows NetworkList profile names returned by
# Get-NetConnectionProfile which can carry a " 2" / " 3" dedup suffix).
#
# Parsing note: the labels printed by netsh are localized (FR Windows prints
# "Profil Tous les utilisateurs"), so this parser NEVER matches on label text.
# It splits each line at the FIRST colon and keeps the remainder, which makes it
# locale-independent and safe for SSIDs that themselves contain a colon.
# Works without admin rights and without location services.
# Returns @() on any failure.
function Get-WlanProfileName {
    $names = @()
    try {
        $lines = & netsh wlan show profiles 2>$null
        if (-not $lines) { return @() }
        foreach ($line in $lines) {
            $idx = ([string]$line).IndexOf(':')
            if ($idx -lt 0) { continue }
            $value = ([string]$line).Substring($idx + 1).Trim()
            if (-not $value) { continue }
            # Skip placeholders such as <None> / <Aucun>
            if ($value.StartsWith('<') -and $value.EndsWith('>')) { continue }
            if ($names -notcontains $value) { $names += $value }
        }
    } catch { return @() }
    return $names
}


# Returns the plain-text pre-shared key of a saved WLAN profile, or $null when
# the profile is unknown, open (no key), or the key cannot be read.
#
# Why not `netsh wlan export ... key=clear`: netsh only writes the key in clear
# text when the caller is a local administrator; otherwise the exported XML
# carries a DPAPI-encrypted keyMaterial that we cannot decrypt. The interactive
# `netsh wlan show profile ... key=clear` form DOES return the clear key without
# elevation, so this uses that instead.
#
# The label printed for that line is localized ("Contenu de la cle" on FR
# Windows), so instead of matching label text this runs the command twice - once
# without key=clear, once with - and keeps the single extra line the second run
# produces. That line is the key by construction, whatever the display language.
function Get-WlanProfileKey {
    param([string]$ProfileName)
    if ([string]::IsNullOrWhiteSpace($ProfileName)) { return $null }
    try {
        $masked = @(& netsh wlan show profile ('name="{0}"' -f $ProfileName) 2>$null)
        $clear  = @(& netsh wlan show profile ('name="{0}"' -f $ProfileName) key=clear 2>$null)
        if ($masked.Count -eq 0 -or $clear.Count -eq 0) { return $null }

        $extra = Compare-Object -ReferenceObject $masked -DifferenceObject $clear |
                 Where-Object { $_.SideIndicator -eq '=>' }
        foreach ($line in $extra) {
            $text = [string]$line.InputObject
            $idx  = $text.IndexOf(':')
            if ($idx -lt 0) { continue }
            $value = $text.Substring($idx + 1).Trim()
            if ($value) { return $value }
        }
        return $null
    } catch { return $null }
}


# Returns the WiFi network this computer is currently connected to, as
# @{ Ssid; ProfileName; InterfaceAlias; Password }, or $null when no wireless
# adapter is up.
#
# Why this is not a one-liner: Get-NetConnectionProfile exposes no SSID at all.
# Its .Name is the Windows NetworkList profile name, and Windows appends
# " 2" / " 3" / " 4" to it whenever a duplicate network-list entry is created
# (adapter re-enumeration, dock/undock, network category change). Returning that
# name yields values like "MyWifi 4" that match no WLAN profile, which also
# breaks the password lookup below.
#
# Resolution order for the WLAN profile name (first source that answers wins):
#   1. netsh wlan show interfaces - authoritative, but on Windows 11 it needs
#      location services enabled AND elevation; it fails silently otherwise, so
#      it can never be the only source.
#   2. Reconcile Get-NetConnectionProfile().Name against the saved WLAN profile
#      list (exact match, then trailing " <digits>" stripped, then longest
#      prefix). Works unprivileged with location services off.
#   3. Raw Get-NetConnectionProfile().Name as a last resort.
#
# The SSID and the password then both come from a single `netsh wlan export`
# XML: its <SSIDConfig><SSID><name> node is the authoritative SSID and both
# nodes are locale-independent.
function Get-ComputerWifiInfo {
    $adapter = Get-NetAdapter | Where-Object {
        ($_.PhysicalMediaType -eq 'Native 802.11' -or $_.PhysicalMediaType -eq 'Wireless LAN') -and
        $_.Status -eq 'Up'
    } | Select-Object -First 1
    if (-not $adapter) { return $null }

    $profileName = $null

    # Source 1: authoritative when the OS allows it. The ^\s*SSID anchor is what
    # keeps the BSSID line from matching.
    try {
        $ifLines = & netsh wlan show interfaces 2>$null
        if ($ifLines) {
            foreach ($line in $ifLines) {
                if ([string]$line -match '^\s*SSID\s*:\s*(.+?)\s*$') { $profileName = $Matches[1]; break }
            }
        }
    } catch {}

    # Source 2: reconcile the NetworkList name against the saved WLAN profiles.
    $netProfile = Get-NetConnectionProfile -InterfaceAlias $adapter.InterfaceAlias -ErrorAction SilentlyContinue
    $connName   = if ($netProfile) { [string]$netProfile.Name } else { $null }

    if (-not $profileName -and $connName) {
        $saved = @(Get-WlanProfileName)
        if ($saved -contains $connName) {
            $profileName = $connName
        } elseif ($connName -match '^(.*?)\s+\d+$' -and $saved -contains $Matches[1]) {
            # "MyWifi 4" -> "MyWifi". Keep the string derived from the Windows API
            # rather than the netsh one: netsh output goes through the console OEM
            # codepage and can mangle accented SSIDs.
            $profileName = $Matches[1]
        } else {
            $profileName = $saved |
                Where-Object { $_ -and $connName.StartsWith($_) } |
                Sort-Object -Property Length -Descending |
                Select-Object -First 1
        }
    }

    # Source 3: last resort - today's behaviour, still better than nothing.
    if (-not $profileName) { $profileName = $connName }
    if (-not $profileName) { return $null }

    $ssid = $profileName

    # The profile name is normally the SSID, but it can be renamed. Export the
    # profile to get the authoritative SSID from the XML - <SSIDConfig><SSID>
    # <name> is locale-independent. Export into a fresh unique folder: netsh
    # names the file "<InterfaceAlias>-<ProfileName>.xml", so guessing the
    # filename breaks on a renamed adapter ("Wi-Fi 2") or on sanitized
    # characters, and a dedicated folder rules out picking up a stale export.
    # The key in this XML is unusable unless we are admin - the password comes
    # from Get-WlanProfileKey instead - so a failure here is not fatal.
    $tmpDir = Join-Path $env:TEMP ("vrhm_wlan_" + [guid]::NewGuid().ToString('N'))
    try {
        # New-Item has no -LiteralPath in PS 5.1; this API is literal by nature.
        [System.IO.Directory]::CreateDirectory($tmpDir) | Out-Null
        & netsh wlan export profile ('name="{0}"' -f $profileName) ('folder="{0}"' -f $tmpDir) 2>$null | Out-Null
        $xmlFile = Get-ChildItem -LiteralPath $tmpDir -Filter '*.xml' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($xmlFile) {
            [xml]$xml = Get-Content -LiteralPath $xmlFile.FullName -Raw -Encoding UTF8
            $xmlSsid = $xml.WLANProfile.SSIDConfig.SSID.name
            if ($xmlSsid) { $ssid = [string]$xmlSsid }
        }
    } catch {
        # Enterprise profile, export blocked, unreadable XML: keep the resolved
        # profile name as the SSID.
    } finally {
        try { Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue } catch {}
    }

    $wifiPassword = Get-WlanProfileKey -ProfileName $profileName

    return [PSCustomObject]@{
        Ssid           = $ssid
        ProfileName    = $profileName
        InterfaceAlias = $adapter.InterfaceAlias
        Password       = $wifiPassword
    }
}
