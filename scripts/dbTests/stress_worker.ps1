#Requires -Version 5.1
<#
.SYNOPSIS
    One worker PROCESS for the concurrency layer. Not part of the application.

.DESCRIPTION
    Launched by Test-DbConcurrency.ps1, several at a time, against one sandbox
    database. Each worker opens its OWN connection - the application's rule is
    one connection per process and per runspace - and hammers the database in
    the shape of a real writer for -Seconds, then writes a JSON result file.

    The point is not throughput. It is that concurrent writers from separate
    processes never corrupt the file and never surface an error to the caller:
    WAL plus BEGIN IMMEDIATE plus the retry wrapper are supposed to make
    SQLITE_BUSY invisible. This is the only test that can prove it, because a
    single process cannot produce the contention.

    ASCII only.
#>
param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$Repo,
    [Parameter(Mandatory = $true)][ValidateSet('status', 'catalog', 'reader')][string]$Role,
    [Parameter(Mandatory = $true)][int]$Seconds,
    [Parameter(Mandatory = $true)][string]$ResultPath
)

$ErrorActionPreference = 'Stop'

$result = [ordered]@{
    Role       = $Role
    Operations = 0
    Errors     = 0
    FirstError = ''
    Started    = (Get-Date).ToString('o')
    Ended      = ''
}

function Save-Result {
    param($Data)
    try {
        $json = ($Data | ConvertTo-Json -Depth 4)
        [System.IO.File]::WriteAllText($ResultPath, $json, (New-Object System.Text.UTF8Encoding $false))
    } catch { }
}

try {
    # Same globals New-TempDatabaseRoot sets, rebuilt here because a new process
    # inherits none of them.
    $global:ScriptPath              = $Root
    $global:databaseFolder          = Join-Path $Repo 'sources\sqlite\System.Data.SQLite-1.0.119'
    $global:databaseAssemblyPath    = Join-Path $global:databaseFolder 'System.Data.SQLite.dll'
    $global:databaseInteropPath     = Join-Path (Join-Path $global:databaseFolder 'x64') 'SQLite.Interop.dll'
    $global:databaseFilePath        = Join-Path (Join-Path $Root 'data') 'vrhm.db'
    $global:databaseBusyTimeoutMs   = 5000
    $global:databaseRetryMax        = 6
    $global:databaseIntegrityCheck  = 'quick'
    $global:databaseBackupKeep      = 3
    $global:databaseBackupOnStartup = $false
    $global:debugLevelToConsole     = 'NONE'
    $global:debugLevelToFile        = 'NONE'
    $global:logFile                 = Join-Path (Join-Path $Root 'logs') ("stress_{0}.log" -f $Role)

    . (Join-Path $Repo 'modules\logging.ps1')
    . (Join-Path $Repo 'modules\database.ps1')

    # Worker, not Main: a worker asserts the schema instead of migrating it, so
    # several starting at once cannot race each other through a migration.
    Initialize-Database -Role Worker | Out-Null

    $headsetIds = @(Invoke-DbQuery -Name 'headsets.list' | ForEach-Object { [int]$_.ID })
    $deadline   = (Get-Date).AddSeconds($Seconds)
    $round      = 0

    while ((Get-Date) -lt $deadline) {
        $round++
        try {
            switch ($Role) {
                'status' {
                    # The monitor fast path: every headset, one batch, ~2 Hz.
                    $rows = @()
                    foreach ($id in $headsetIds) {
                        $rows += @{
                            ID = $id; Ping = 1; ADBWifi = 1
                            Battery = [string](20 + ($round % 60))
                            Charging = '-'; ChargingWattage = '-'; Temp = '-'
                            BatteryControllerLeft = '-'; BatteryControllerRight = '-'
                            PowerState = '-'; TimeRemainingMin = '-'
                            SCRCPY = '-'; RunningApp = '-'; RunningAppIcon = ''
                        }
                    }
                    Invoke-DbBatch -Name 'status.upsert' -Rows $rows | Out-Null
                    $result.Operations++
                    Start-Sleep -Milliseconds 500
                }
                'catalog' {
                    # The app-resolve job: a large catalogue batch, then a full
                    # installed-apps replace for one headset.
                    $batch = @()
                    for ($i = 0; $i -lt 200; $i++) {
                        $batch += @{
                            package_name    = ("com.stress.pkg{0}" -f $i)
                            display_name    = ("Stress App {0} r{1}" -f $i, $round)
                            icon_url        = ''
                            local_icon_path = ''
                            third_party     = 1
                            latest_version  = [string]$round
                        }
                    }
                    Invoke-DbBatch -Name 'catalog.upsert' -Rows $batch | Out-Null
                    $result.Operations++

                    if ($headsetIds.Count -gt 0) {
                        $target = $headsetIds[$round % $headsetIds.Count]
                        $apps = @()
                        for ($i = 0; $i -lt 120; $i++) {
                            $apps += @{
                                headset_id = $target; package_name = ("com.stress.pkg{0}" -f $i)
                                version = [string]$round; pending_version = ''; store_version = ''
                                size_bytes = [int64]($i * 1024)
                            }
                        }
                        $appsToWrite = $apps
                        Invoke-DbTransaction -Script {
                            Invoke-DbNonQuery -Name 'installed.delete_for_headset' -Parameters @{ headset_id = $target } | Out-Null
                            foreach ($a in $appsToWrite) { Invoke-DbNonQuery -Name 'installed.insert' -Parameters $a | Out-Null }
                        } | Out-Null
                        $result.Operations++
                    }
                    Start-Sleep -Milliseconds 150
                }
                'reader' {
                    # The web server: read a lot, and drive the deliver-once
                    # command queue, which is the one DELETE ... RETURNING path.
                    @(Invoke-DbQuery -Name 'status.list')   | Out-Null
                    @(Invoke-DbQuery -Name 'headsets.list') | Out-Null
                    @(Invoke-DbQuery -Name 'status.merged') | Out-Null
                    Get-DbTableVersion -Name 'headset_status' | Out-Null
                    $result.Operations++

                    if (($round % 2) -eq 0) {
                        # nonce is an INTEGER column and must be given an
                        # integer, exactly as Add-KioskCommand does. The PID
                        # keeps it unique across the concurrent workers.
                        $now = [datetimeoffset]::UtcNow
                        Invoke-DbNonQuery -Name 'kiosk_commands.insert' -Parameters @{
                            ip_address = '10.9.9.9'
                            cmd        = 'reboot'
                            nonce      = [int64]($now.ToUnixTimeMilliseconds() * 100000 + $PID % 100000)
                            delay_sec  = 0
                            queued_at  = $now.ToString('o')
                            queued_unix = [int64]$now.ToUnixTimeSeconds()
                        } | Out-Null
                        @(Invoke-DbQuery -Name 'kiosk_commands.claim' -Parameters @{ ip_address = '10.9.9.9' }) | Out-Null
                        $result.Operations++
                    }
                    Start-Sleep -Milliseconds 100
                }
            }
        }
        catch {
            $result.Errors++
            if (-not $result.FirstError) { $result.FirstError = $_.Exception.Message }
        }
    }

    try { Close-DbConnection -Checkpoint } catch { }
}
catch {
    $result.Errors++
    if (-not $result.FirstError) { $result.FirstError = ("fatal: " + $_.Exception.Message) }
}

$result.Ended = (Get-Date).ToString('o')
Save-Result -Data $result
