###############################################################
# companion_api.ps1
# HTTP API of the VRHM Companion app running on the headset.
# Split out of adb_functions.ps1 (S9-2). Auto-loaded by scripts_init.ps1.
# Translations are loaded centrally in scripts_init.ps1 into $global:msg.
# ASCII only (no em dashes, no curly quotes, no accents).
###############################################################


function Get-CompanionInfo {
    <#
    .SYNOPSIS
    Calls GET http://<IP>:<CompanionPort>/info on the VRHM Companion app running on the headset.
    Returns the parsed JSON object, or $null if the companion is unreachable.
    .PARAMETER IP
    Headset IP address.
    .PARAMETER CompanionPort
    HTTP port the companion listens on (default 8765).
    .PARAMETER TimeoutSec
    Request timeout in seconds (default 2).
    #>
    param(
        [Parameter(Mandatory)]
        [string]$IP,
        [int]$CompanionPort = 8765,
        [int]$TimeoutSec    = 2
    )
    try {
        $url  = "http://${IP}:${CompanionPort}/info"
        $resp = Invoke-RestMethod -Uri $url -Method GET -TimeoutSec $TimeoutSec -ErrorAction Stop
        return $resp
    } catch {
        Write-Log "Get-CompanionInfo $IP :${CompanionPort} unreachable: $_" -Level DEBUG
        return $null
    }
}


function Set-CompanionAutoAdb {
    <#
    .SYNOPSIS
    POSTs {"auto_adb_wifi": <bool>} to the companion app running on the headset.
    Returns $true on success, $false on failure (companion not installed or unreachable).
    .PARAMETER IP
    Headset IP address.
    .PARAMETER Enabled
    Whether to enable auto-ADB-WiFi on next boot.
    .PARAMETER CompanionPort
    HTTP port the companion listens on (default 8765).
    #>
    param(
        [Parameter(Mandatory)]
        [string]$IP,
        [Parameter(Mandatory)]
        [bool]$Enabled,
        [int]$CompanionPort = 8765
    )
    try {
        $body = ConvertTo-Json -Compress @{ auto_adb_wifi = $Enabled }
        $url  = "http://${IP}:${CompanionPort}/settings"
        $resp = Invoke-RestMethod -Uri $url -Method POST -Body $body `
                    -ContentType "application/json" -TimeoutSec 3 -ErrorAction Stop
        if ($resp.ok) {
            Write-Log "Set-CompanionAutoAdb $IP -> auto_adb_wifi=$Enabled" -Level DEBUG
            return $true
        }
        Write-Log "Set-CompanionAutoAdb $IP returned ok=false" -Level WARNING
        return $false
    } catch {
        Write-Log "Set-CompanionAutoAdb $IP failed: $_" -Level WARNING
        return $false
    }
}


function Set-HeadsetBrightnessCompanion {
    <#
    .SYNOPSIS
    Sets screen brightness (0-100%) via the companion app HTTP API.
    Faster than ADB round-trip. Falls back gracefully if companion is unreachable.
    Returns $true on success.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$IP,
        [Parameter(Mandatory)]
        [ValidateRange(0, 100)]
        [int]$Percent,
        [int]$CompanionPort = 8765
    )
    try {
        $body = ConvertTo-Json -Compress @{ brightness = $Percent }
        $url  = "http://${IP}:${CompanionPort}/settings"
        $resp = Invoke-RestMethod -Uri $url -Method POST -Body $body `
                    -ContentType "application/json" -TimeoutSec 3 -ErrorAction Stop
        return [bool]$resp.ok
    } catch {
        Write-Log "Set-HeadsetBrightnessCompanion $IP failed: $_" -Level DEBUG
        return $false
    }
}
