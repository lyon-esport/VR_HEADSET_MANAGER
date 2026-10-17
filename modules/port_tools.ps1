###############################################################
# port_tools.ps1
# Local port tools: free-port test, port owner lookup, pool walk.
# Split out of utils.ps1 (S9-1).
# Auto-loaded by scripts_init.ps1.
# ASCII only (no em dashes, no curly quotes, no accents).
###############################################################


###############################################################
# Port-availability helpers
# Used by Resolve-PortConflict (console_manager.ps1) and the
# startup orchestrator Confirm-AppPortsAvailable.
###############################################################


# Returns $true when no local socket is listening on $Port for the given
# protocol(s). Uses Get-NetTCPConnection / Get-NetUDPEndpoint with
# SilentlyContinue so it never throws on Win10 standard-user contexts.
function Test-LocalPortFree {
    param(
        [Parameter(Mandatory=$true)][int]$Port,
        [ValidateSet('TCP','UDP','Both')]
        [string]$Protocol = 'TCP'
    )
    if ($Protocol -in @('TCP','Both')) {
        $tcp = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
        if ($tcp) { return $false }
    }
    if ($Protocol -in @('UDP','Both')) {
        $udp = Get-NetUDPEndpoint -LocalPort $Port -ErrorAction SilentlyContinue
        if ($udp) { return $false }
    }
    return $true
}


# Returns @{Pid; ProcessName; ProcessPath; Port; Protocol} for the process
# that owns the listening socket on $Port, or $null when the port is free.
# Path may be empty for system processes when access is denied.
# Parse `netsh http show servicestate view=session` and return the userspace
# PID that registered a URL for -Port on HTTP.sys. Returns $null when nothing
# active is bound to that port. Locale-independent: the netsh output uses
# the ASCII markers "ID:" (process attachment) and "HTTP://...:<port>/"
# regardless of Windows display language.
#
# Note: the output has two kinds of blocks that reference a port URL:
#   1. URL group reservations (no process attached) - MUST be skipped.
#   2. Request queue sessions (PID + attached URLs) - the answer we want.
# We track the last-seen PID and only return it when its FOLLOWING URL list
# contains the target port. Reservation-only blocks never set a PID, so
# their URLs (encountered first in the output) fall through harmlessly.
function Get-HttpSysPortOwnerPid {
    param([Parameter(Mandatory=$true)][int]$Port)
    try {
        $lines = & netsh http show servicestate view=session 2>$null
    } catch { return $null }
    if (-not $lines) { return $null }

    $currentPid  = $null
    $portPattern = ':' + $Port + '/'
    foreach ($raw in $lines) {
        $line = "$raw"
        # PID markers observed across Windows versions / locales:
        #   "ID: 12345, image: <path>"   (Win10/11, all locales)
        #   "PID : 12345"                (older builds)
        #   "process ID is: 12345"       (English long-form)
        if ($line -match '^\s*ID\s*:\s*(\d+)' `
                -or $line -match '\bPID\s*:\s*(\d+)' `
                -or $line -match 'process ID is[:\s]+(\d+)') {
            $currentPid = [int]$Matches[1]
            continue
        }
        if ($currentPid -and $line -match '^\s*https?://' -and $line -like "*$portPattern*") {
            return $currentPid
        }
    }
    return $null
}

function Get-LocalPortOwner {
    param(
        [Parameter(Mandatory=$true)][int]$Port,
        [ValidateSet('TCP','UDP','Both')]
        [string]$Protocol = 'TCP'
    )
    $owningPid = $null
    $proto     = $null
    if ($Protocol -in @('TCP','Both')) {
        $tcp = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($tcp) {
            $owningPid = [int]$tcp.OwningProcess
            $proto     = 'TCP'
        }
    }
    if (-not $owningPid -and $Protocol -in @('UDP','Both')) {
        $udp = Get-NetUDPEndpoint -LocalPort $Port -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($udp) {
            $owningPid = [int]$udp.OwningProcess
            $proto     = 'UDP'
        }
    }

    # HTTP.sys reserved ports (e.g. HttpListener behind a URL ACL) report the
    # System kernel PID 4 instead of the userspace listener. Ask http.sys who
    # actually registered the URL. Same fallback if the query returned nothing.
    if ((-not $owningPid -or $owningPid -eq 4) -and $Protocol -in @('TCP','Both')) {
        $httpPid = Get-HttpSysPortOwnerPid -Port $Port
        if ($httpPid) {
            $owningPid = $httpPid
            $proto     = 'TCP'
        }
    }

    if (-not $owningPid) { return $null }

    $procName = $null
    $procPath = $null
    try {
        $proc = Get-Process -Id $owningPid -ErrorAction Stop
        $procName = $proc.ProcessName
        try { $procPath = $proc.Path } catch { $procPath = $null }
    } catch {
        $procName = "<unknown>"
        $procPath = $null
    }
    return @{
        Pid         = $owningPid
        ProcessName = $procName
        ProcessPath = $procPath
        Port        = $Port
        Protocol    = $proto
    }
}


# Walks $Pool (typically a service's pre-defined port range) and returns the
# first port that is currently free. -SkipPort lets the caller exclude the
# already-conflicting port (the candidate must be different from it).
# Returns $null when the entire pool is in use.
function Find-NextFreePortInPool {
    param(
        [Parameter(Mandatory=$true)][int[]]$Pool,
        [int]$SkipPort = 0,
        [ValidateSet('TCP','UDP','Both')]
        [string]$Protocol = 'TCP'
    )
    foreach ($p in $Pool) {
        if ($p -eq $SkipPort) { continue }
        if (Test-LocalPortFree -Port $p -Protocol $Protocol) { return [int]$p }
    }
    return $null
}
