# vrhm_import.ps1 - import of a previous installation into this one (ADR-0041, spec S11).
#
# Two phases so a MAJOR update can start on a clean database:
#   phase 1  Import-PreviousInstallConfig : pure JSON/file work, runs in main.ps1 BEFORE the welcome
#            wizard (no module needed, no database). Items: recording, crops, wifi + implicit settings.
#   phase 2  Import-PreviousInstallData   : after the database is open (scripts_init.ps1, Main role).
#            Items: headsets, profiles, kiosks, apps. The OLD database is read through
#            Invoke-DbExternalQuery (read-only, separate connection, named queries import.*).
# Import-PreviousInstall runs both on demand for a manual import into a running install.
# Everything that fails is reported, never fatal. Functions only: nothing runs at dot-source time.

function Get-ImportItemIds {
    <#
    .SYNOPSIS
        The import item ids (fixed contract with the UI checkboxes). 'settings' is implicit, never listed.
    .EXAMPLE
        Get-ImportItemIds
    #>
    return @('headsets', 'profiles', 'crops', 'recording', 'kiosks', 'apps', 'wifi')
}

function Write-ImportLog {
    param([string]$Message, [string]$Level = 'INFO')
    try {
        if (Get-Command -Name Write-Log -ErrorAction SilentlyContinue) { Write-Log $Message -Level $Level }
        else { Write-Host ("[{0}] {1}" -f $Level, $Message) }
    } catch { }
}

function Read-ImportJson {
    # Parsed JSON file (UTF-8, BOM tolerated) or $null.
    param([string]$Path)
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        $obj = $raw.TrimStart([char]0xFEFF) | ConvertFrom-Json
        return $obj
    } catch { return $null }
}

function Write-ImportText {
    # UTF-8 without BOM, parent folder created.
    param([string]$Path, [string]$Content, [switch]$Config)
    $dir = Split-Path -Path $Path -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if ($Config -and (Get-Command -Name Write-ConfigJson -ErrorAction SilentlyContinue)) {
        Write-ConfigJson -Object $Content -Path $Path
    } else {
        [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
    }
}

function Get-ImportJsonPath {
    <#
    .SYNOPSIS
        Reads a dotted path from a parsed JSON object. Returns @{Found;Value}.
    .EXAMPLE
        (Get-ImportJsonPath -Object $cfg -Path 'scrcpy.recordFolder').Value
    #>
    param($Object, [string]$Path)
    $cur = $Object
    foreach ($seg in ($Path -split '\.')) {
        if ($null -eq $cur -or $cur -isnot [System.Management.Automation.PSCustomObject]) { return @{ Found = $false; Value = $null } }
        $p = $cur.PSObject.Properties[$seg]
        if ($null -eq $p) { return @{ Found = $false; Value = $null } }
        $cur = $p.Value
    }
    return @{ Found = $true; Value = $cur }
}

function Set-ImportJsonPath {
    <#
    .SYNOPSIS
        Sets a dotted path on a parsed JSON object, creating the intermediate objects.
    .EXAMPLE
        Set-ImportJsonPath -Object $cfg -Path 'Recordings.rescan_interval_min' -Value 5
    #>
    param($Object, [string]$Path, $Value)
    $segs = @($Path -split '\.')
    $cur = $Object
    for ($i = 0; $i -lt $segs.Count - 1; $i++) {
        $p = $cur.PSObject.Properties[$segs[$i]]
        if ($null -eq $p -or $p.Value -isnot [System.Management.Automation.PSCustomObject]) {
            $cur | Add-Member -NotePropertyName $segs[$i] -NotePropertyValue ([PSCustomObject]@{}) -Force
            $p = $cur.PSObject.Properties[$segs[$i]]
        }
        $cur = $p.Value
    }
    $cur | Add-Member -NotePropertyName $segs[-1] -NotePropertyValue $Value -Force
}

function New-ImportItemResult {
    param([bool]$Ok = $true, [int]$Count = 0, [string]$Message = '')
    return @{ ok = $Ok; count = $Count; message = $Message }
}

function Copy-ImportConfigSettings {
    <#
    .SYNOPSIS
        Pure: copies the selected parts of an OLD parsed config onto a NEW parsed config (in place).
        Always applied: language, WebServer.port, mediamtx ports, Performance, Update. Per item:
        recording (scrcpy.recordFolder, recordMinFreeSpaceGB, Recordings), crops (views, eye_merge,
        eye_merge_ipd, ipd of every model present in BOTH configs). Returns the per-item results.
    .EXAMPLE
        $res = Copy-ImportConfigSettings -Old $old -New $new -Items @('recording', 'crops')
    #>
    param($Old, $New, [string[]]$Items = @())
    $res = [ordered]@{}

    $n = 0
    foreach ($path in 'language', 'WebServer.port', 'mediamtx.rtsp_port', 'mediamtx.hls_port', 'mediamtx.webrtc_port', 'mediamtx.api_port', 'Performance', 'Update') {
        $g = Get-ImportJsonPath -Object $Old -Path $path
        if ($g.Found -and $null -ne $g.Value) { Set-ImportJsonPath -Object $New -Path $path -Value $g.Value; $n++ }
    }
    $res['settings'] = New-ImportItemResult -Count $n -Message ('{0} setting(s) applied' -f $n)

    if ($Items -contains 'recording') {
        $n = 0
        foreach ($path in 'scrcpy.recordFolder', 'scrcpy.recordMinFreeSpaceGB', 'Recordings') {
            $g = Get-ImportJsonPath -Object $Old -Path $path
            if ($g.Found -and $null -ne $g.Value) { Set-ImportJsonPath -Object $New -Path $path -Value $g.Value; $n++ }
        }
        $res['recording'] = New-ImportItemResult -Count $n -Message $(if ($n -gt 0) { 'recording settings copied' } else { 'not present in the previous configuration' })
    }

    if ($Items -contains 'crops') {
        $oldP = (Get-ImportJsonPath -Object $Old -Path 'scrcpy.parameters').Value
        $newP = (Get-ImportJsonPath -Object $New -Path 'scrcpy.parameters').Value
        $models = 0; $skipped = @()
        if ($oldP -is [System.Management.Automation.PSCustomObject] -and $newP -is [System.Management.Automation.PSCustomObject]) {
            foreach ($mp in @($oldP.PSObject.Properties)) {
                $nm = $newP.PSObject.Properties[$mp.Name]
                if ($null -eq $nm) { $skipped += $mp.Name; continue }
                $copied = $false
                foreach ($key in 'views', 'eye_merge', 'eye_merge_ipd', 'ipd') {
                    $ov = $mp.Value.PSObject.Properties[$key]
                    if ($null -ne $ov -and $null -ne $ov.Value) {
                        $nm.Value | Add-Member -NotePropertyName $key -NotePropertyValue $ov.Value -Force
                        $copied = $true
                    }
                }
                if ($copied) { $models++ }
            }
        }
        $msgText = '{0} model(s) copied' -f $models
        if ($skipped.Count -gt 0) { $msgText += '; skipped (not in this version): ' + ($skipped -join ', ') }
        $res['crops'] = New-ImportItemResult -Count $models -Message $msgText
    }
    return $res
}

function Import-PreviousInstallConfig {
    <#
    .SYNOPSIS
        Phase 1 of the import (no module, no database needed). Without -Merge: copies
        templates\config\config.json to config\config.json then applies the old settings (main.ps1
        calls it before the welcome wizard). With -Merge (manual import into a running install): applies
        them onto the existing config.json. Also copies data\wifi_networks.dat when 'wifi' is selected
        (DPAPI: only readable by the same Windows user). Returns @{Ok;Error;Items}; the per-item results
        are also stored in data\update\import_report_config.json for phase 2.
    .EXAMPLE
        $r = Import-PreviousInstallConfig -From 'D:\old\VR_HEADSET_MANAGER' -Items @('recording', 'crops')
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$From,
        [string[]]$Items = @(),
        [string]$Root = $global:ScriptPath,
        [switch]$Merge
    )
    try {
        $cfgPath = Join-Path (Join-Path $Root 'config') 'config.json'
        $oldCfg = Read-ImportJson -Path (Join-Path (Join-Path $From 'config') 'config.json')
        if ($null -eq $oldCfg) { return @{ Ok = $false; Error = 'The previous configuration (config\config.json) could not be read.'; Items = @{} } }

        if ($Merge) { $newCfg = Read-ImportJson -Path $cfgPath }
        else { $newCfg = Read-ImportJson -Path (Join-Path (Join-Path (Join-Path $Root 'templates') 'config') 'config.json') }
        if ($null -eq $newCfg) { return @{ Ok = $false; Error = 'The target configuration could not be read.'; Items = @{} } }

        $res = Copy-ImportConfigSettings -Old $oldCfg -New $newCfg -Items $Items

        if ($Items -contains 'wifi') {
            $srcWifi = Join-Path (Join-Path $From 'data') 'wifi_networks.dat'
            $dstWifi = Join-Path (Join-Path $Root 'data') 'wifi_networks.dat'
            if (-not (Test-Path -LiteralPath $srcWifi -PathType Leaf)) { $res['wifi'] = New-ImportItemResult -Message 'no WiFi store in the previous installation' }
            elseif ($Merge -and (Test-Path -LiteralPath $dstWifi)) { $res['wifi'] = New-ImportItemResult -Message 'a WiFi store already exists here, kept unchanged' }
            else {
                $dd = Split-Path -Path $dstWifi -Parent
                if (-not (Test-Path -LiteralPath $dd)) { New-Item -ItemType Directory -Path $dd -Force | Out-Null }
                Copy-Item -LiteralPath $srcWifi -Destination $dstWifi -Force
                $res['wifi'] = New-ImportItemResult -Count 1 -Message 'WiFi store copied (readable only by the same Windows user)'
            }
        }

        $json = $newCfg | ConvertTo-Json -Depth 20
        Write-ImportText -Path $cfgPath -Content $json -Config
        if ($Merge -and (Get-Command -Name Get-Config -ErrorAction SilentlyContinue)) { try { Get-Config | Out-Null } catch { } }

        $repDir = Join-Path (Join-Path $Root 'data') 'update'
        Write-ImportText -Path (Join-Path $repDir 'import_report_config.json') -Content (($res | ConvertTo-Json -Depth 5))
        foreach ($k in $res.Keys) { Write-ImportLog ("Import (config): {0}: {1}" -f $k, $res[$k].message) 'INFO' }
        return @{ Ok = $true; Error = $null; Items = $res }
    } catch {
        Write-ImportLog ("Import (config) failed: {0}" -f $_.Exception.Message) 'ERROR'
        return @{ Ok = $false; Error = $_.Exception.Message; Items = @{} }
    }
}

function Invoke-PreviousInstallConfigStartup {
    <#
    .SYNOPSIS
        main.ps1 hook, before the welcome wizard: when data\update\import_from.json exists and
        config\config.json does not, runs phase 1 and makes sure data\update\chain.json carries the
        remaining hops. Returns $true when a config was created. Never throws.
    .EXAMPLE
        if (Invoke-PreviousInstallConfigStartup) { 'config imported' }
    #>
    param([string]$Root = $global:ScriptPath)
    try {
        $imp = Read-ImportJson -Path (Join-Path (Join-Path (Join-Path $Root 'data') 'update') 'import_from.json')
        if ($null -eq $imp -or -not $imp.from) { return $false }
        if (Test-Path -LiteralPath (Join-Path (Join-Path $Root 'config') 'config.json')) { return $false }
        $items = @()
        if ($imp.PSObject.Properties['items'] -and $imp.items) { $items = @($imp.items) }
        $r = Import-PreviousInstallConfig -From ([string]$imp.from) -Items $items -Root $Root
        if (-not $r.Ok) { Write-Host ("Import of the previous configuration failed: " + $r.Error) -ForegroundColor Yellow; return $false }
        $chainFile = Join-Path (Join-Path (Join-Path $Root 'data') 'update') 'chain.json'
        $hops = @()
        if ($imp.PSObject.Properties['chain'] -and $imp.chain) { $hops = @($imp.chain) }
        if ($hops.Count -gt 0 -and -not (Test-Path -LiteralPath $chainFile)) {
            $target = ''
            if ($imp.PSObject.Properties['target']) { $target = [string]$imp.target }
            $c = [ordered]@{ target = $target; hops = $hops; importItems = $items }
            Write-ImportText -Path $chainFile -Content ($c | ConvertTo-Json -Depth 5)
        }
        return $true
    } catch { return $false }
}

function Test-ImportProfileView {
    <#
    .SYNOPSIS
        Pure. Decides the scrcpy profile a headset keeps after an import. Returns @{Profile;Kept;Reason}:
        the profile unchanged when its view exists under -Parameters.<Model>.views, else the same profile
        with the model default view (first view flagged default, else the first one, else 'square').
    .EXAMPLE
        Test-ImportProfileView -Profile 'max-R-N-45-20' -Model 'Quest 3' -Parameters $global:scrcpyParameters
    #>
    param([string]$Profile, [string]$Model, $Parameters)
    # $global:scrcpyParameters is a one-element ARRAY after Update-EyeMergeParameters reloads it.
    if ($Parameters -is [System.Array]) { $Parameters = @($Parameters)[0] }
    $parts = @(([string]$Profile) -split '-')
    if ($parts.Count -eq 4 -and $parts[0] -in @('L', 'R', 'M')) { $parts = @('portrait') + $parts }
    $views = $null
    if ($Parameters -and $Model) {
        $mp = $Parameters.PSObject.Properties[$Model]
        if ($mp -and $mp.Value -and $mp.Value.PSObject.Properties['views']) { $views = $mp.Value.views }
    }
    $names = @()
    if ($views) { $names = @($views.PSObject.Properties | ForEach-Object { $_.Name }) }
    $default = 'square'
    if ($names.Count -gt 0) {
        $default = $names[0]
        foreach ($nm in $names) { if ($views.$nm.PSObject.Properties['default'] -and $views.$nm.default -eq $true) { $default = $nm; break } }
    }
    if ($parts.Count -ne 5) { return @{ Profile = ($default + '-R-N-45-20'); Kept = $false; Reason = 'unreadable profile' } }
    if ($names -contains $parts[0]) { return @{ Profile = ($parts -join '-'); Kept = $true; Reason = '' } }
    $parts[0] = $default
    return @{ Profile = ($parts -join '-'); Kept = $false; Reason = ('view not available for this model, reset to ' + $default) }
}

function ConvertTo-ImportHeadsetRow {
    # Old headsets table row (snake_case columns) -> registry row shape; a missing column = default.
    param($Row)
    $get = { param($n, $d) $p = $Row.PSObject.Properties[$n]; if ($p -and $null -ne $p.Value) { return $p.Value } return $d }
    return [PSCustomObject]@{
        ID                 = [int](& $get 'id' 0)
        Name               = [string](& $get 'name' '')
        IPAddress          = [string](& $get 'ip_address' '')
        scrcpy_AutoRestart = $(if ((ConvertTo-DbBool (& $get 'scrcpy_auto_restart' 1) -Default $true) -eq 1) { 'True' } else { 'False' })
        Record             = $(if ((ConvertTo-DbBool (& $get 'record' 0)) -eq 1) { 'True' } else { 'False' })
        ScrcpyProfile      = [string](& $get 'scrcpy_profile' '')
        Brand              = [string](& $get 'brand' '')
        Model              = [string](& $get 'model' '')
        SerialNumber       = [string](& $get 'serial_number' '')
    }
}

function Import-PreviousInstallData {
    <#
    .SYNOPSIS
        Phase 2 of the import: needs the database open (Main role). Reads the OLD data\vrhm.db through
        Invoke-DbExternalQuery (read-only). Items: headsets (rows not conflicting by serial, address or
        name with the registry; the old ID is kept when free), profiles (kept when the view exists in
        the new config for the model, else reset to the model default view; without 'profiles' every
        imported headset gets the default one), kiosks, apps (catalogue, favourites, app icons).
        Deletes import_from.json afterwards and stores app_kv 'update_import_report'. Returns @{Ok;Error;Items}.
    .EXAMPLE
        $r = Import-PreviousInstallData -From 'D:\old\VR_HEADSET_MANAGER' -Items @('headsets', 'profiles')
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$From,
        [string[]]$Items = @(),
        [string]$Root = $global:ScriptPath,
        [string]$FromVersion = '',
        [switch]$KeepMarker
    )
    $res = [ordered]@{}
    $oldDb = Join-Path (Join-Path $From 'data') 'vrhm.db'
    try {
        # carry over the phase 1 results
        $p1 = Read-ImportJson -Path (Join-Path (Join-Path (Join-Path $Root 'data') 'update') 'import_report_config.json')
        if ($p1) { foreach ($pr in $p1.PSObject.Properties) { $res[$pr.Name] = @{ ok = [bool]$pr.Value.ok; count = [int]$pr.Value.count; message = [string]$pr.Value.message } } }

        $needDb = @('headsets', 'profiles', 'kiosks', 'apps') | Where-Object { $Items -contains $_ }
        $oldHeadsets = @(); $dbOk = $true
        if (@($needDb).Count -gt 0) {
            if (-not (Test-Path -LiteralPath $oldDb -PathType Leaf)) {
                $dbOk = $false
                foreach ($i in $needDb) { $res[$i] = New-ImportItemResult -Ok $false -Message 'previous database (data\vrhm.db) not found' }
            } else {
                $oldHeadsets = @(Invoke-DbExternalQuery -DatabasePath $oldDb -Name 'import.headsets')
                $e = Get-DbExternalLastError
                if ($e) { $dbOk = $false; foreach ($i in $needDb) { $res[$i] = New-ImportItemResult -Ok $false -Message ('previous database unreadable: ' + $e) } }
            }
        }

        # ---- headsets (+ profiles)
        if ($dbOk -and (($Items -contains 'headsets') -or ($Items -contains 'profiles'))) {
            try {
                $existing = @(Get-KnownHeadsets)
                $usedIds = @{}; $serials = @{}; $ips = @{}; $names = @{}
                foreach ($h in $existing) {
                    $usedIds[[string]$h.ID] = $true
                    if ($h.SerialNumber) { $serials[([string]$h.SerialNumber).ToLowerInvariant()] = $true }
                    $ips[[string]$h.IPAddress] = $true
                    $names[([string]$h.Name).ToLowerInvariant()] = $true
                }
                $maxId = 0
                foreach ($k in $usedIds.Keys) { $v = 0; if ([int]::TryParse($k, [ref]$v) -and $v -gt $maxId) { $maxId = $v } }
                foreach ($oh in $oldHeadsets) { if ([int]$oh.id -gt $maxId) { $maxId = [int]$oh.id } }
                # Views of the NEW config, read from disk: the config phase just wrote it, and
                # $global:scrcpyParameters may still hold the config this process loaded before.
                $importParams = $global:scrcpyParameters
                try {
                    $newCfgPath = Join-Path (Join-Path $Root 'config') 'config.json'
                    if (Test-Path -LiteralPath $newCfgPath) {
                        $newCfg = (Get-Content -LiteralPath $newCfgPath -Raw -Encoding UTF8).TrimStart([char]0xFEFF) | ConvertFrom-Json
                        if ($newCfg.scrcpy -and $newCfg.scrcpy.parameters) { $importParams = $newCfg.scrcpy.parameters }
                    }
                } catch { }
                $added = New-Object System.Collections.ArrayList
                $resetNotes = @(); $skipped = 0
                if ($Items -contains 'headsets') {
                    foreach ($oh in $oldHeadsets) {
                        $row = ConvertTo-ImportHeadsetRow -Row $oh
                        $ser = $row.SerialNumber.ToLowerInvariant()
                        if (($ser -and $serials.ContainsKey($ser)) -or $ips.ContainsKey($row.IPAddress) -or $names.ContainsKey($row.Name.ToLowerInvariant())) { $skipped++; continue }
                        if ($usedIds.ContainsKey([string]$row.ID) -or $row.ID -le 0) { $maxId++; $row.ID = $maxId }
                        $pf = Test-ImportProfileView -Profile $row.ScrcpyProfile -Model $row.Model -Parameters $importParams
                        if ($Items -contains 'profiles') {
                            $row.ScrcpyProfile = $pf.Profile
                            if (-not $pf.Kept) { $resetNotes += ('{0}: {1}' -f $row.Name, $pf.Reason) }
                        } else {
                            $d = Test-ImportProfileView -Profile '' -Model $row.Model -Parameters $importParams
                            $row.ScrcpyProfile = $d.Profile
                        }
                        $usedIds[[string]$row.ID] = $true; $ips[$row.IPAddress] = $true; $names[$row.Name.ToLowerInvariant()] = $true
                        if ($ser) { $serials[$ser] = $true }
                        [void]$added.Add($row)
                    }
                    if ($added.Count -gt 0) { Save-Headsets -headsets @(@($existing) + @($added.ToArray())) }
                    $m = '{0} headset(s) imported' -f $added.Count
                    if ($skipped -gt 0) { $m += '; {0} already present' -f $skipped }
                    $res['headsets'] = New-ImportItemResult -Count $added.Count -Message $m
                }
                if ($Items -contains 'profiles') {
                    $m = '{0} profile(s) kept' -f ($added.Count - $resetNotes.Count)
                    if ($resetNotes.Count -gt 0) { $m += '; reset: ' + ($resetNotes -join ' | ') }
                    $res['profiles'] = New-ImportItemResult -Count ($added.Count - $resetNotes.Count) -Message $m
                }
            } catch {
                foreach ($i in 'headsets', 'profiles') { if ($Items -contains $i) { $res[$i] = New-ImportItemResult -Ok $false -Message $_.Exception.Message } }
            }
        }

        # ---- kiosks
        if ($dbOk -and ($Items -contains 'kiosks')) {
            try {
                $ok = @(Invoke-DbExternalQuery -DatabasePath $oldDb -Name 'import.kiosks')
                $e = Get-DbExternalLastError
                if ($e) { throw $e }
                $have = @{}
                foreach ($k in @(Get-KnownKiosks)) { $have[[string]$k.IPAddress] = $true }
                $n = 0
                foreach ($ok1 in $ok) {
                    $ip = [string]$ok1.ip_address
                    if (-not $ip -or $have.ContainsKey($ip)) { continue }
                    $port = 9222; $pp = $ok1.PSObject.Properties['port']; if ($pp -and $null -ne $pp.Value) { $port = [int]$pp.Value }
                    Add-Kiosk -IPAddress $ip -Name ([string]$ok1.name) -Port $port
                    $have[$ip] = $true; $n++
                }
                $res['kiosks'] = New-ImportItemResult -Count $n -Message ('{0} kiosk(s) imported' -f $n)
            } catch { $res['kiosks'] = New-ImportItemResult -Ok $false -Message $_.Exception.Message }
        }

        # ---- apps
        if ($dbOk -and ($Items -contains 'apps')) {
            try {
                $cat = @(Invoke-DbExternalQuery -DatabasePath $oldDb -Name 'import.app_catalog')
                $e = Get-DbExternalLastError; if ($e) { throw $e }
                $nc = 0
                foreach ($c in $cat) {
                    $g = { param($n) $p = $c.PSObject.Properties[$n]; if ($p -and $null -ne $p.Value) { return [string]$p.Value } return '' }
                    Save-AppCatalogEntry -Entry ([PSCustomObject]@{
                        PackageName = (& $g 'package_name'); DisplayName = (& $g 'display_name'); IconUrl = (& $g 'icon_url')
                        LocalIconPath = (& $g 'local_icon_path'); ThirdParty = $(if ((ConvertTo-DbBool $c.third_party -Default $true) -eq 1) { 'True' } else { 'False' })
                        LatestVersion = (& $g 'latest_version') })
                    $nc++
                }
                $fav = @(Invoke-DbExternalQuery -DatabasePath $oldDb -Name 'import.headset_favorite_apps')
                $e = Get-DbExternalLastError; if ($e) { throw $e }
                $oldById = @{}
                foreach ($oh in $oldHeadsets) { $oldById[[string]$oh.id] = $oh }
                $newRows = @(Get-KnownHeadsets)
                $nf = 0
                foreach ($grp in ($fav | Group-Object -Property headset_id)) {
                    $oh = $oldById[[string]$grp.Name]
                    if ($null -eq $oh) { continue }
                    $target = $null
                    if ($oh.serial_number) { $target = @($newRows | Where-Object { $_.SerialNumber -and [string]$_.SerialNumber -eq [string]$oh.serial_number })[0] }
                    if ($null -eq $target) { $target = @($newRows | Where-Object { [string]$_.Name -eq [string]$oh.name })[0] }
                    if ($null -eq $target) { continue }
                    $list = @($grp.Group | Sort-Object { [int]$_.sort_order } | ForEach-Object { [PSCustomObject]@{ PackageName = [string]$_.package_name; DisplayName = [string]$_.display_name } })
                    Save-FavoriteApps -favorites $list -headsetName ([string]$target.Name)
                    $nf += $list.Count
                }
                $ni = 0
                $srcIcons = Join-Path (Join-Path (Join-Path $From 'website') 'assets') 'app_icons'
                if (Test-Path -LiteralPath $srcIcons -PathType Container) {
                    $dstIcons = Join-Path (Join-Path (Join-Path $Root 'website') 'assets') 'app_icons'
                    if (-not (Test-Path -LiteralPath $dstIcons)) { New-Item -ItemType Directory -Path $dstIcons -Force | Out-Null }
                    foreach ($f in @(Get-ChildItem -LiteralPath $srcIcons -File -ErrorAction SilentlyContinue)) {
                        $dst = Join-Path $dstIcons $f.Name
                        if (-not (Test-Path -LiteralPath $dst)) { Copy-Item -LiteralPath $f.FullName -Destination $dst -Force; $ni++ }
                    }
                }
                $res['apps'] = New-ImportItemResult -Count $nc -Message ('{0} catalogue entries, {1} favourite(s), {2} icon(s)' -f $nc, $nf, $ni)
            } catch { $res['apps'] = New-ImportItemResult -Ok $false -Message $_.Exception.Message }
        }

        foreach ($k in $res.Keys) { Write-ImportLog ("Import: {0}: {1}{2}" -f $k, $res[$k].message, $(if (-not $res[$k].ok) { ' (FAILED)' } else { '' })) $(if ($res[$k].ok) { 'INFO' } else { 'WARNING' }) }

        $report = [ordered]@{ at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); from = $From; fromVersion = $FromVersion; items = $res }
        if (Get-Command -Name Set-DbKeyValue -ErrorAction SilentlyContinue) { try { Set-DbKeyValue -Key 'update_import_report' -Value $report } catch { Write-ImportLog ("Import: report not stored: " + $_.Exception.Message) 'WARNING' } }
        if (-not $KeepMarker) {
            $upd = Join-Path (Join-Path $Root 'data') 'update'
            foreach ($f in 'import_from.json', 'import_report_config.json') { Remove-Item -LiteralPath (Join-Path $upd $f) -Force -ErrorAction SilentlyContinue }
        }
        return @{ Ok = $true; Error = $null; Items = $res; Report = ($report | ConvertTo-Json -Depth 6 -Compress) }
    } catch {
        Write-ImportLog ("Import (data) failed: {0}" -f $_.Exception.Message) 'ERROR'
        return @{ Ok = $false; Error = $_.Exception.Message; Items = $res; Report = '' }
    }
}

function Invoke-PreviousInstallDataStartup {
    <#
    .SYNOPSIS
        scripts_init.ps1 hook (Main role, database open, next to Invoke-AppUpgradeSteps): when
        data\update\import_from.json exists, runs phase 2 with its items. Never throws.
    .EXAMPLE
        Invoke-PreviousInstallDataStartup
    #>
    param([string]$Root = $global:ScriptPath)
    try {
        $imp = Read-ImportJson -Path (Join-Path (Join-Path (Join-Path $Root 'data') 'update') 'import_from.json')
        if ($null -eq $imp -or -not $imp.from) { return $null }
        $items = @()
        if ($imp.PSObject.Properties['items'] -and $imp.items) { $items = @($imp.items) }
        $fv = ''
        if ($imp.PSObject.Properties['fromVersion']) { $fv = [string]$imp.fromVersion }
        return (Import-PreviousInstallData -From ([string]$imp.from) -Items $items -Root $Root -FromVersion $fv)
    } catch {
        Write-ImportLog ("Import (startup) failed: {0}" -f $_.Exception.Message) 'ERROR'
        return $null
    }
}

function Import-PreviousInstall {
    <#
    .SYNOPSIS
        Console / manual entry: imports the selected items from a previous installation folder into the
        RUNNING install (config merged into the existing config.json, then the data phase). Returns
        @{Ok;Error;Report} (Report = JSON text of the per-item results).
    .EXAMPLE
        $r = Import-PreviousInstall -Path 'D:\old\VR_HEADSET_MANAGER' -Items @('headsets', 'profiles')
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [string[]]$Items = @(), [string]$Root = $global:ScriptPath)
    $Path = $Path.Trim().Trim('"')
    if (-not (Test-Path -LiteralPath (Join-Path (Join-Path $Path 'config') 'config.json') -PathType Leaf) -and
        -not (Test-Path -LiteralPath (Join-Path (Join-Path $Path 'data') 'vrhm.db') -PathType Leaf)) {
        return @{ Ok = $false; Error = 'This folder is not a VR HEADSET MANAGER installation (no config\config.json and no data\vrhm.db).'; Report = '' }
    }
    $fv = ''
    try { $vf = Join-Path $Path 'version.txt'; if (Test-Path -LiteralPath $vf) { $fv = (Get-Content -LiteralPath $vf -Raw -Encoding UTF8).Trim() } } catch { }
    $cfgItems = @($Items | Where-Object { $_ -in @('recording', 'crops', 'wifi') })
    $r1 = Import-PreviousInstallConfig -From $Path -Items $cfgItems -Root $Root -Merge
    if (-not $r1.Ok) { return @{ Ok = $false; Error = $r1.Error; Report = '' } }
    $r2 = Import-PreviousInstallData -From $Path -Items $Items -Root $Root -FromVersion $fv
    return @{ Ok = [bool]$r2.Ok; Error = $r2.Error; Report = $r2.Report }
}
