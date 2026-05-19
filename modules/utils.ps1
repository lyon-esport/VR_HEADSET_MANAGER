
###############################################################
# utils.ps1 - cross-cutting helpers used by multiple modules.
# Auto-loaded by scripts_init.ps1.
# ASCII only (no em dashes, no curly quotes, no accents).
###############################################################


# Parse a CSV/JSON field that may be the string "True"/"False" or a real
# boolean and return a real [bool]. Empty/null returns $false.
# Use this everywhere instead of comparing $row.Field -eq $True/$False.
function ConvertTo-BoolField {
    param(
        [Parameter(ValueFromPipeline = $true)]
        $Value,
        [bool]$Default = $false
    )
    process {
        if ($null -eq $Value) { return $Default }
        if ($Value -is [bool]) { return $Value }
        $s = ([string]$Value).Trim()
        if ($s.Length -eq 0) { return $Default }
        return [string]::Equals($s, 'True', [System.StringComparison]::OrdinalIgnoreCase)
    }
}


# Build the path of a per-headset data CSV (data/<safe>_<suffix>.csv).
# Suffix examples: 'favorite_apps', 'installed_apps'.
function Get-HeadsetDataPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [string]$Suffix
    )
    $safe = $Name -replace ' ', '_'
    $file = "{0}_{1}.csv" -f $safe, $Suffix
    return (Join-Path -Path $global:ScriptPath -ChildPath (Join-Path -Path 'data' -ChildPath $file))
}


# Build the path of a per-headset website file (website/<safe>[<kind>].html).
# Kind examples: 'monitoring', 'video'.
function Get-HeadsetSitePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [string]$Kind
    )
    $safe = $Name -replace ' ', '_'
    $file = "{0}[{1}].html" -f $safe, $Kind
    return (Join-Path -Path $global:ScriptPath -ChildPath (Join-Path -Path 'website' -ChildPath $file))
}


# Write text to a file as UTF-8 WITHOUT BOM.
# .ps1 files in this project must not have a BOM (CLAUDE.md rule 1).
# Many web/HTML/YAML outputs also need this.
function Write-FileWithoutBom {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [AllowEmptyString()]
        [string]$Content
    )
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}


# Print "<prefix> N..." on a single line, counting down once per second.
# Used by headsets_dashboard.ps1 and any "wait then refresh" loop.
function Wait-WithCountdown {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Seconds,
        [string]$Prefix = 'Refreshing in'
    )
    if ($Seconds -le 0) { return }
    for ($i = $Seconds; $i -ge 1; $i--) {
        Write-Host -NoNewline ("`r{0} {1}s ..." -f $Prefix, $i)
        Start-Sleep -Seconds 1
    }
    Write-Host -NoNewline ("`r" + (' ' * ($Prefix.Length + 12)) + "`r")
}


# Validate that a constructed file path stays under the project root.
# Returns the resolved absolute path on success, or $null if it would escape.
# Use this for any web-route handler that builds a path from request input.
function Test-RequestPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [string]$Root = $global:ScriptPath
    )
    if (-not $Root) { return $null }
    try {
        $resolved = [System.IO.Path]::GetFullPath($Path)
    } catch {
        return $null
    }
    $rootFull = [System.IO.Path]::GetFullPath($Root)
    $sep      = [System.IO.Path]::DirectorySeparatorChar
    if (-not $rootFull.EndsWith($sep)) { $rootFull = $rootFull + $sep }
    if ($resolved.Equals($rootFull.TrimEnd($sep), [System.StringComparison]::OrdinalIgnoreCase) -or
        $resolved.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $resolved
    }
    return $null
}


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
        $encrypted = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
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
        Write-Log ($msg.WifiNetworksFileCorrupt) -Level WARNING
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
    Write-Log ($msg.WifiNetworksSaved -f $Networks.Count) -Level DEBUG
}
