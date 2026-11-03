# vrhm_update.ps1 - application self-update (ADR-0041).
# Functions only: nothing runs at dot-source time. Auto-loaded by scripts_init.ps1's module glob.
# Section S1 (version grammar): ConvertTo-AppVersion, Compare-AppVersion, Test-AppVersionUpdatable,
# Get-AppInstalledManifest, Get-AppVersionInfo. Later tasks append further sections below.

function ConvertTo-AppVersion {
    <#
    .SYNOPSIS
        Parses a version text into @{Ok;Text;Kind;Year;Month;Rc;Minor;Patch;Dev;Base;Core}. Never throws.
    .EXAMPLE
        (ConvertTo-AppVersion -Text 'V2026-11.RC1.2+dev.abc1234').Core   # 2026-11.RC1.2
    #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Text)

    $result = [pscustomobject]@{
        Ok = $false; Text = ''; Kind = 'Legacy'; Year = 0; Month = 0; Rc = 0
        Minor = 0; Patch = 0; Dev = ''; Base = ''; Core = ''
    }
    try {
        if ($null -eq $Text) { return $result }
        $t = $Text.Trim()
        $result.Text = $t
        if ($t -ceq 'DEVELOPPMENT-VERSION') {
            $result.Kind = 'DevTree'
            return $result
        }
        if ($t -match '^[Vv](?=\d)') { $t = $t.Substring(1) }

        $rx = '^(\d{4})-(\d{2})\.RC(\d+)(?:\.(\d+)(?:\.(\d+))?)?(?:\+dev\.([0-9a-f]{7,40}))?$'
        $m = [regex]::Match($t, $rx, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($m.Success) {
            $result.Kind = 'Release'
            $result.Ok = $true
            $result.Year = [int]$m.Groups[1].Value
            $result.Month = [int]$m.Groups[2].Value
            $result.Rc = [int]$m.Groups[3].Value
            if ($m.Groups[4].Success) { $result.Minor = [int]$m.Groups[4].Value }
            if ($m.Groups[5].Success) { $result.Patch = [int]$m.Groups[5].Value }
            if ($m.Groups[6].Success) { $result.Dev = $m.Groups[6].Value.ToLowerInvariant() }
            $result.Base = ('{0}-{1}.RC{2}' -f $m.Groups[1].Value, $m.Groups[2].Value, $result.Rc)
            $core = $result.Base
            if ($m.Groups[4].Success) {
                $core += ('.{0}' -f $result.Minor)
                if ($m.Groups[5].Success) { $core += ('.{0}' -f $result.Patch) }
            }
            $result.Core = $core
            return $result
        }

        $mt = [regex]::Match($t, '^(\d{4})-(\d{2})\.TEST(\d*)$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($mt.Success) {
            $result.Kind = 'Test'
            $result.Ok = $true
            $result.Year = [int]$mt.Groups[1].Value
            $result.Month = [int]$mt.Groups[2].Value
            $n = 1
            if ($mt.Groups[3].Value -ne '') { $n = [int]$mt.Groups[3].Value }
            $result.Rc = $n
            return $result
        }
    } catch { }
    return $result
}

function Compare-AppVersion {
    <#
    .SYNOPSIS
        Compares two versions (strings or ConvertTo-AppVersion objects): -1, 0 or 1.
        Test and DevTree versions are never ordered against anything (0).
    .EXAMPLE
        Compare-AppVersion -A '2026-11.RC1.2' -B '2026-11.RC1.10'   # -1
    #>
    [CmdletBinding()]
    param($A, $B)

    $pa = $A; $pb = $B
    if ($A -isnot [pscustomobject] -or $null -eq $A.PSObject.Properties['Kind']) { $pa = ConvertTo-AppVersion -Text ([string]$A) }
    if ($B -isnot [pscustomobject] -or $null -eq $B.PSObject.Properties['Kind']) { $pb = ConvertTo-AppVersion -Text ([string]$B) }

    if ($pa.Kind -eq 'Test' -or $pa.Kind -eq 'DevTree' -or $pb.Kind -eq 'Test' -or $pb.Kind -eq 'DevTree') { return 0 }
    if ($pa.Kind -eq 'Release' -and $pb.Kind -ne 'Release') { return 1 }
    if ($pa.Kind -ne 'Release' -and $pb.Kind -eq 'Release') { return -1 }
    if ($pa.Kind -ne 'Release') { return 0 }

    foreach ($f in 'Year', 'Month', 'Rc', 'Minor', 'Patch') {
        if ($pa.$f -lt $pb.$f) { return -1 }
        if ($pa.$f -gt $pb.$f) { return 1 }
    }
    $da = ($pa.Dev -ne ''); $db = ($pb.Dev -ne '')
    if ($da -and -not $db) { return 1 }
    if ($db -and -not $da) { return -1 }
    return 0
}

function Test-AppVersionUpdatable {
    <#
    .SYNOPSIS
        $true only for a Release version (the only kind the updater may replace).
    .EXAMPLE
        Test-AppVersionUpdatable -Version '2026-11.RC1'   # True
    #>
    [CmdletBinding()]
    param($Version)

    try {
        $p = $Version
        if ($Version -isnot [pscustomobject] -or $null -eq $Version.PSObject.Properties['Kind']) { $p = ConvertTo-AppVersion -Text ([string]$Version) }
        return ($p.Kind -eq 'Release')
    } catch { return $false }
}

function Get-AppInstalledManifest {
    <#
    .SYNOPSIS
        Manifest of what is installed: data\update\installed.json, else release.json at the install root.
        Parsed object or $null; never throws.
    .EXAMPLE
        $m = Get-AppInstalledManifest; if ($m) { $m.version }
    #>
    [CmdletBinding()]
    param([string]$Root = $global:ScriptPath)

    try {
        if ([string]::IsNullOrWhiteSpace($Root)) { return $null }
        $candidates = @(
            (Join-Path (Join-Path (Join-Path $Root 'data') 'update') 'installed.json'),
            (Join-Path $Root 'release.json')
        )
        foreach ($path in $candidates) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
            try {
                $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
                if ([string]::IsNullOrWhiteSpace($raw)) { continue }
                $obj = $raw | ConvertFrom-Json
                if ($null -ne $obj) { return $obj }
            } catch { continue }
        }
    } catch { }
    return $null
}

function Get-AppVersionInfo {
    <#
    .SYNOPSIS
        @{Version;Parsed;DevTree;Updatable;Installed;Commit} for the install at -Root (version.txt).
    .EXAMPLE
        (Get-AppVersionInfo).Updatable
    #>
    [CmdletBinding()]
    param([string]$Root = $global:ScriptPath)

    $version = ''
    try {
        if (-not [string]::IsNullOrWhiteSpace($Root)) {
            $vf = Join-Path $Root 'version.txt'
            if (Test-Path -LiteralPath $vf -PathType Leaf) {
                $version = ([string](Get-Content -LiteralPath $vf -Raw -Encoding UTF8)).Trim()
            }
        }
    } catch { $version = '' }

    $parsed = ConvertTo-AppVersion -Text $version
    $installed = Get-AppInstalledManifest -Root $Root
    $commit = ''
    if ($null -ne $installed -and $null -ne $installed.PSObject.Properties['commit'] -and $installed.commit) {
        $commit = [string]$installed.commit
    }
    return [pscustomobject]@{
        Version   = $version
        Parsed    = $parsed
        DevTree   = ($parsed.Kind -eq 'DevTree')
        Updatable = (Test-AppVersionUpdatable -Version $parsed)
        Installed = $installed
        Commit    = $commit
    }
}

# ------------------------------------------------------------------ S4/S5/S7: catalog, path, staging

function Write-UpdateLog {
    # Write-Log when the full app is loaded, silent when the module is dot-sourced alone (unit script).
    param([string]$Message, [string]$Level = 'INFO')
    try {
        if (Get-Command -Name Write-Log -ErrorAction SilentlyContinue) { Write-Log $Message -Level $Level }
    } catch { }
}

function Get-UpdateSetting {
    <#
    .SYNOPSIS
        Value of one Update_* setting (global set by Get-Config) with the shipped default and floor applied.
    .EXAMPLE
        Get-UpdateSetting -Name catalog_cache_min   # 10
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('github_repo', 'dev_branch', 'health_timeout_sec', 'catalog_cache_min')][string]$Name)

    switch ($Name) {
        'github_repo' {
            $v = [string](Get-Variable -Name 'Update_github_repo' -Scope Global -ValueOnly -ErrorAction SilentlyContinue)
            if ($v -match '^[\w.-]+/[\w.-]+$') { return $v }
            return 'lyon-esport/VR_HEADSET_MANAGER'
        }
        'dev_branch' {
            $v = [string](Get-Variable -Name 'Update_dev_branch' -Scope Global -ValueOnly -ErrorAction SilentlyContinue)
            if ($v -match '^[\w./-]+$') { return $v }
            return 'main'
        }
        'health_timeout_sec' {
            $v = Get-Variable -Name 'Update_health_timeout_sec' -Scope Global -ValueOnly -ErrorAction SilentlyContinue
            if ($null -eq $v) { return 300 }
            return [Math]::Max(60, [int]$v)
        }
        'catalog_cache_min' {
            $v = Get-Variable -Name 'Update_catalog_cache_min' -Scope Global -ValueOnly -ErrorAction SilentlyContinue
            if ($null -eq $v) { return 10 }
            return [Math]::Max(1, [int]$v)
        }
    }
}

function Get-AppUpdateDataPath {
    <#
    .SYNOPSIS
        Path of data\update (or a child via -Child), optionally created.
    .EXAMPLE
        Get-AppUpdateDataPath -Child 'dl' -Create
    #>
    [CmdletBinding()]
    param([string]$Root = $global:ScriptPath, [string]$Child = '', [switch]$Create)

    $p = Join-Path (Join-Path $Root 'data') 'update'
    if ($Child) { $p = Join-Path $p $Child }
    if ($Create -and -not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    return $p
}

function Write-UpdateTextFile {
    # UTF-8 without BOM; Write-FileWithoutBom when available.
    param([string]$Path, [string]$Content)
    $dir = Split-Path -Path $Path -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if (Get-Command -Name Write-FileWithoutBom -ErrorAction SilentlyContinue) {
        Write-FileWithoutBom -Path $Path -Content $Content
    } else {
        [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
    }
}

function Read-UpdateJsonFile {
    # Parsed JSON file or $null (missing / corrupt). Never throws.
    param([string]$Path)
    # The updater rewrites job.json / state.json while the app polls them: a sharing violation is
    # retried silently (-ErrorAction Stop, otherwise Get-Content's IOException is non-terminating
    # and printed instead of caught).
    for ($i = 0; $i -lt 5; $i++) {
        try {
            if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
            $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop
            if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
            return ($raw.TrimStart([char]0xFEFF) | ConvertFrom-Json)
        } catch [System.IO.IOException] {
            Start-Sleep -Milliseconds 100
        } catch { return $null }
    }
    return $null
}

function Get-UpdateFileSha256 {
    <#
    .SYNOPSIS
        Lower-case hex SHA-256 of a file, streamed. $null when unreadable.
    .EXAMPLE
        Get-UpdateFileSha256 -Path $zip
    #>
    [CmdletBinding()]
    param([string]$Path)
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        try { $bytes = $sha.ComputeHash($fs) } finally { $fs.Dispose(); $sha.Dispose() }
        return ([System.BitConverter]::ToString($bytes).Replace('-', '').ToLowerInvariant())
    } catch { return $null }
}

function Write-AppUpdateProgress {
    # Progress JSON {status,step,percent,message,hops,current}; never throws, nothing when -File is empty.
    param([string]$File, [string]$Status = 'running', [string]$Step = '', [int]$Percent = 0, [string]$Message = '', $Hops = @(), [string]$Current = '')
    if ([string]::IsNullOrWhiteSpace($File)) { return }
    try {
        $o = [ordered]@{ status = $Status; step = $Step; percent = $Percent; message = $Message; hops = @($Hops); current = $Current }
        Write-UpdateTextFile -Path $File -Content ($o | ConvertTo-Json -Compress)
    } catch { }
}

function Test-AppUpdateProtectedPath {
    <#
    .SYNOPSIS
        $true for a relative path the updater must never copy over, delete or back up (spec S8).
    .EXAMPLE
        Test-AppUpdateProtectedPath -Path 'config/config.json'   # True
    #>
    [CmdletBinding()]
    param([string]$Path)

    $p = ($Path -replace '\\', '/').TrimStart('/').ToLowerInvariant()
    if ($p -eq '') { return $false }
    foreach ($pre in 'data/', 'config/', 'logs/', 'website/generated/', 'website/timer/', 'website/assets/app_icons/', '.git/', '.dev/', 'scripts/') {
        if ($p.StartsWith($pre)) { return $true }
    }
    if ($p -match '^sources/ffmpeg') { return $true }
    if ($p -eq 'website/monitor.html') { return $true }
    if ($p -match '^website/[^/]*\[[^/]*\][^/]*\.html$') { return $true }
    return $false
}

function Save-UpdateDownload {
    <#
    .SYNOPSIS
        Downloads -Url to -OutFile (BITS when the service is not disabled, else WebClient). Returns @{Ok;Error}.
    .EXAMPLE
        Save-UpdateDownload -Url $r.ZipUrl -OutFile (Join-Path $dl 'x.zip')
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)][string]$OutFile)

    try {
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
        $dir = Split-Path -Path $OutFile -Parent
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        if (Test-Path -LiteralPath $OutFile) { Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue }
        $bitsOk = $false
        try {
            $bits = Get-Service -Name BITS -ErrorAction Stop
            if ($bits.Status -eq 'Running' -or $bits.StartType -ne 'Disabled') {
                Start-BitsTransfer -Source $Url -Destination $OutFile -Description 'Downloading VRHM update...' -ErrorAction Stop
                $bitsOk = $true
            }
        } catch { $bitsOk = $false }
        if (-not $bitsOk) {
            $wc = [System.Net.WebClient]::new()
            try {
                $wc.Headers.Add('User-Agent', 'VR-Headset-Manager')
                $wc.DownloadFile($Url, $OutFile)
            } finally { $wc.Dispose() }
        }
        if (-not (Test-Path -LiteralPath $OutFile -PathType Leaf)) { return @{ Ok = $false; Error = 'Download produced no file.' } }
        return @{ Ok = $true; Error = $null }
    } catch {
        if (Test-Path -LiteralPath $OutFile) { Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue }
        return @{ Ok = $false; Error = $_.Exception.Message }
    }
}

function Get-AppReleaseManifest {
    <#
    .SYNOPSIS
        release.json read from <single top folder>/release.json inside a zip (\ or / separators), or $null.
        Adds ZipPath and Source='zip'.
    .EXAMPLE
        $m = Get-AppReleaseManifest -ZipPath 'C:\x\VR_HEADSET_MANAGER.v2026-11.RC1.zip'
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ZipPath)

    $zip = $null
    try {
        if (-not (Test-Path -LiteralPath $ZipPath -PathType Leaf)) { return $null }
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
        $hit = $null
        foreach ($e in $zip.Entries) {
            $n = $e.FullName -replace '\\', '/'
            if ($n -match '^[^/]+/release\.json$') { $hit = $e; break }
        }
        if ($null -eq $hit) { return $null }
        $sr = New-Object System.IO.StreamReader($hit.Open(), (New-Object System.Text.UTF8Encoding($false)), $true)
        try { $raw = $sr.ReadToEnd() } finally { $sr.Dispose() }
        $m = $raw.TrimStart([char]0xFEFF) | ConvertFrom-Json
        if ($null -eq $m) { return $null }
        $m | Add-Member -NotePropertyName ZipPath -NotePropertyValue $ZipPath -Force
        $m | Add-Member -NotePropertyName Source -NotePropertyValue 'zip' -Force
        return $m
    } catch { return $null }
    finally { if ($null -ne $zip) { $zip.Dispose() } }
}

function Expand-AppUpdateZip {
    <#
    .SYNOPSIS
        Extracts a release zip into -Destination, flattening one shared top folder (\ or /), guarded against
        path traversal. Returns the number of files written; throws on error.
    .EXAMPLE
        Expand-AppUpdateZip -ZipPath $zip -Destination $stage
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ZipPath, [Parameter(Mandatory)][string]$Destination)

    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $destFull = [System.IO.Path]::GetFullPath($Destination).TrimEnd('\') + '\'
    $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    $count = 0
    try {
        $files = @($zip.Entries | Where-Object { $_.FullName -notmatch '[\\/]$' })
        $strip = ''
        if ($files.Count -gt 0) {
            $firsts = @($files | ForEach-Object { ($_.FullName -replace '\\', '/').Split('/')[0] } | Select-Object -Unique)
            $allDeep = (@($files | Where-Object { ($_.FullName -replace '\\', '/') -notmatch '/' }).Count -eq 0)
            if ($firsts.Count -eq 1 -and $allDeep) { $strip = $firsts[0] + '/' }
        }
        if (-not (Test-Path -LiteralPath $Destination)) { New-Item -ItemType Directory -Path $Destination -Force | Out-Null }
        foreach ($e in $files) {
            $rel = $e.FullName -replace '\\', '/'
            if ($strip -and $rel.StartsWith($strip)) { $rel = $rel.Substring($strip.Length) }
            if ($rel -eq '') { continue }
            $target = [System.IO.Path]::GetFullPath((Join-Path $Destination ($rel -replace '/', '\')))
            if (-not $target.StartsWith($destFull, [System.StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe path in archive: $($e.FullName)" }
            $tdir = Split-Path -Path $target -Parent
            if (-not (Test-Path -LiteralPath $tdir)) { New-Item -ItemType Directory -Path $tdir -Force | Out-Null }
            $in = $e.Open()
            try {
                $out = [System.IO.File]::Create($target)
                try { $in.CopyTo($out) } finally { $out.Dispose() }
            } finally { $in.Dispose() }
            $count++
        }
    } finally { $zip.Dispose() }
    return $count
}

function Get-AppUpdateCatalog {
    <#
    .SYNOPSIS
        GitHub releases of Update.github_repo as @{Ok;Error;FetchedAt;Releases}, memoised catalog_cache_min.
        A release without release.json is kept with Type '' and Updatable $false (Reason NoManifest).
    .EXAMPLE
        $c = Get-AppUpdateCatalog -Force; $c.Releases | Select-Object Version, Type, Reason
    #>
    [CmdletBinding()]
    param([switch]$Force)

    $memo = $script:AppUpdateCatalogMemo
    if (-not $Force -and $null -ne $memo) {
        $age = ((Get-Date) - $memo.FetchedAt).TotalMinutes
        if ($age -lt (Get-UpdateSetting -Name catalog_cache_min)) { return $memo }
    }
    try {
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
        $repo = Get-UpdateSetting -Name github_repo
        $headers = @{ 'User-Agent' = 'VR-Headset-Manager'; 'Accept' = 'application/vnd.github+json' }
        # PS 5.1: Invoke-RestMethod emits a JSON array as ONE Object[]; @(...) would wrap it again and
        # the loop would see a single array element (whose .draft is a truthy array). Assign first.
        $resp = Invoke-RestMethod -Uri ("https://api.github.com/repos/{0}/releases?per_page=100" -f $repo) -Headers $headers -TimeoutSec 15
        $raw = @($resp | ForEach-Object { $_ })
        $list = New-Object System.Collections.ArrayList
        foreach ($rel in $raw) {
            if ($null -eq $rel -or $rel.draft) { continue }
            $assets = @($rel.assets)
            $mAsset = $assets | Where-Object { $_.name -eq 'release.json' } | Select-Object -First 1
            $manifest = $null
            if ($mAsset) {
                try {
                    $wc = [System.Net.WebClient]::new()
                    try {
                        $wc.Headers.Add('User-Agent', 'VR-Headset-Manager')
                        $wc.Encoding = [System.Text.Encoding]::UTF8
                        $txt = $wc.DownloadString([string]$mAsset.browser_download_url)
                    } finally { $wc.Dispose() }
                    $manifest = $txt.TrimStart([char]0xFEFF) | ConvertFrom-Json
                } catch { $manifest = $null }
            }
            $tag = ([string]$rel.tag_name) -replace '^[Vv](?=\d)', ''
            $r = @{
                Version = $tag; Type = ''; Base = ''; MinUpgradeFrom = ''; Prerelease = [bool]$rel.prerelease
                PublishedAt = [string]$rel.published_at; Title = [string]$rel.name; Notes = [string]$rel.body
                ZipUrl = ''; ZipName = ''; ZipSha256 = ''; ZipSize = 0; Breaking = @(); Manifest = $manifest
                Updatable = $false; Reason = 'NoManifest'; Source = 'github'
            }
            if ($manifest) {
                if ($manifest.version) { $r.Version = [string]$manifest.version }
                $r.Type = [string]$manifest.type
                $r.Base = [string]$manifest.base
                $r.MinUpgradeFrom = [string]$manifest.minUpgradeFrom
                if ($manifest.PSObject.Properties['breaking']) { $r.Breaking = @($manifest.breaking) }
                if ($manifest.PSObject.Properties['zipSha256']) { $r.ZipSha256 = [string]$manifest.zipSha256 }
                if ($manifest.PSObject.Properties['zipSize']) { $r.ZipSize = [int64]$manifest.zipSize }
                $zName = ''
                if ($manifest.PSObject.Properties['zipName']) { $zName = [string]$manifest.zipName }
                $zAsset = $null
                if ($zName) { $zAsset = $assets | Where-Object { $_.name -eq $zName } | Select-Object -First 1 }
                if (-not $zAsset) { $zAsset = $assets | Where-Object { $_.name -like '*.zip' } | Select-Object -First 1 }
                if ($zAsset) {
                    $r.ZipUrl = [string]$zAsset.browser_download_url
                    $r.ZipName = [string]$zAsset.name
                    if (-not $r.ZipSize) { $r.ZipSize = [int64]$zAsset.size }
                }
                if (($r.Type -notin 'major', 'minor') -or -not (Test-AppVersionUpdatable -Version $r.Version)) { $r.Reason = 'BadManifest' }
                elseif (-not $r.ZipUrl) { $r.Reason = 'NoZip' }
                else { $r.Updatable = $true; $r.Reason = '' }
            }
            [void]$list.Add($r)
        }
        $res = @{ Ok = $true; Error = $null; FetchedAt = (Get-Date); Releases = @($list.ToArray()) }
        $script:AppUpdateCatalogMemo = $res
        return $res
    } catch {
        Write-UpdateLog ("Update catalog failed: {0}" -f $_.Exception.Message) 'WARNING'
        return @{ Ok = $false; Error = $_.Exception.Message; FetchedAt = (Get-Date); Releases = @() }
    }
}

function Get-AppUpdatePath {
    <#
    .SYNOPSIS
        Pure. Shortest chain of updatable releases leading From -> To: @{Ok;Hops;Reason;Needs}.
        Reasons: Same, Older, NoRoute (+Needs), NotUpdatable. -FromBase = base of the installed line
        (default: the base parsed from -From).
    .EXAMPLE
        Get-AppUpdatePath -From '2026-11.RC1' -To '2026-11.RC1.2' -Releases $rels
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$From, [Parameter(Mandatory)][string]$To, $Releases = @(), [string]$FromBase = '')

    $res = @{ Ok = $false; Hops = @(); Reason = ''; Needs = '' }
    $fp = ConvertTo-AppVersion -Text $From
    $tp = ConvertTo-AppVersion -Text $To
    if ($fp.Kind -ne 'Release' -or $tp.Kind -ne 'Release') { $res.Reason = 'NotUpdatable'; return $res }
    $c = Compare-AppVersion -A $fp -B $tp
    if ($c -eq 0) { $res.Reason = 'Same'; return $res }
    if ($c -gt 0) { $res.Reason = 'Older'; return $res }

    $nodes = New-Object System.Collections.ArrayList
    $baseFrom = $FromBase
    if (-not $baseFrom) { $baseFrom = $fp.Base }
    [void]$nodes.Add(@{ Version = $From; Core = $fp.Core; Base = $baseFrom; Type = ''; Min = '' })
    $seen = @{ $fp.Core = $true }
    $targetIdx = -1
    foreach ($r in @($Releases)) {
        if ($null -eq $r -or -not $r.Updatable) { continue }
        $vp = ConvertTo-AppVersion -Text ([string]$r.Version)
        if ($vp.Kind -ne 'Release') { continue }
        if ((Compare-AppVersion -A $vp -B $fp) -le 0) { continue }
        if ((Compare-AppVersion -A $vp -B $tp) -gt 0) { continue }
        if ($seen.ContainsKey($vp.Core)) { continue }
        $seen[$vp.Core] = $true
        $b = [string]$r.Base
        if (-not $b) { $b = $vp.Base }
        [void]$nodes.Add(@{ Version = [string]$r.Version; Core = $vp.Core; Base = $b; Type = [string]$r.Type; Min = [string]$r.MinUpgradeFrom })
        if ($vp.Core -eq $tp.Core) { $targetIdx = $nodes.Count - 1 }
    }
    if ($targetIdx -lt 0) { $res.Reason = 'NotUpdatable'; return $res }

    $n = $nodes.Count
    $edge = @{}
    for ($i = 0; $i -lt $n; $i++) { $edge[$i] = New-Object System.Collections.ArrayList }
    for ($x = 0; $x -lt $n; $x++) {
        for ($y = 1; $y -lt $n; $y++) {
            if ($x -eq $y) { continue }
            $nx = $nodes[$x]; $ny = $nodes[$y]
            if ((Compare-AppVersion -A $ny.Version -B $nx.Version) -ne 1) { continue }
            if ($ny.Min -and (Compare-AppVersion -A $ny.Min -B $nx.Core) -gt 0) { continue }
            if ($ny.Type -ne 'major' -and $ny.Base -ne $nx.Base) { continue }
            [void]$edge[$x].Add($y)
        }
    }
    $dist = @{}
    for ($i = 0; $i -lt $n; $i++) { $dist[$i] = -1 }
    $dist[0] = 0
    $q = New-Object System.Collections.Queue
    $q.Enqueue(0)
    while ($q.Count -gt 0) {
        $u = $q.Dequeue()
        foreach ($v in $edge[$u]) {
            if ($dist[$v] -lt 0) { $dist[$v] = $dist[$u] + 1; $q.Enqueue($v) }
        }
    }
    if ($dist[$targetIdx] -lt 0) {
        $res.Reason = 'NoRoute'
        $tm = $nodes[$targetIdx].Min
        if ($tm -and (Compare-AppVersion -A $tm -B $fp.Core) -gt 0) { $res.Needs = $tm }
        return $res
    }
    # enumerate every shortest path (graphs are tiny), keep the best by the tie-break rules
    $paths = New-Object System.Collections.ArrayList
    $stack = New-Object System.Collections.ArrayList
    $walk = $null
    $walk = {
        param($u)
        [void]$stack.Add($u)
        if ($u -eq $targetIdx) { [void]$paths.Add(@($stack.ToArray())) }
        else {
            foreach ($v in $edge[$u]) {
                if ($dist[$v] -eq ($dist[$u] + 1) -and $dist[$v] -le $dist[$targetIdx] -and $paths.Count -lt 500) { & $walk $v }
            }
        }
        $stack.RemoveAt($stack.Count - 1)
    }
    & $walk 0
    $best = $null
    foreach ($p in $paths) {
        if ($null -eq $best) { $best = $p; continue }
        $majA = @($p | Where-Object { $nodes[$_].Type -eq 'major' }).Count
        $majB = @($best | Where-Object { $nodes[$_].Type -eq 'major' }).Count
        if ($majA -lt $majB) { $best = $p; continue }
        if ($majA -gt $majB) { continue }
        for ($k = 1; $k -lt $p.Count; $k++) {
            $cc = Compare-AppVersion -A $nodes[$p[$k]].Version -B $nodes[$best[$k]].Version
            if ($cc -gt 0) { $best = $p; break }
            if ($cc -lt 0) { break }
        }
    }
    $res.Ok = $true
    $res.Hops = @($best | Select-Object -Skip 1 | ForEach-Object { $nodes[$_].Version })
    return $res
}

function Merge-AppUpdateZipReleases {
    # Adds the manifests of local zips to a release list (zip preferred for download on the same version).
    param($Releases = @(), [string[]]$ZipPaths = @())
    $list = New-Object System.Collections.ArrayList
    foreach ($r in @($Releases)) { [void]$list.Add($r) }
    foreach ($zp in @($ZipPaths)) {
        if (-not $zp) { continue }
        $m = Get-AppReleaseManifest -ZipPath $zp
        if ($null -eq $m -or -not $m.version) { continue }
        $vp = ConvertTo-AppVersion -Text ([string]$m.version)
        $zr = @{
            Version = [string]$m.version; Type = [string]$m.type; Base = [string]$m.base; MinUpgradeFrom = [string]$m.minUpgradeFrom
            Prerelease = $false; PublishedAt = [string]$m.createdAt; Title = [string]$m.version; Notes = [string]$m.notes
            ZipUrl = ''; ZipName = (Split-Path -Path $zp -Leaf); ZipSha256 = ''; ZipSize = 0
            Breaking = @($m.breaking); Manifest = $m; Updatable = ($vp.Kind -eq 'Release' -and (([string]$m.type) -in 'major', 'minor'))
            Reason = ''; Source = 'zip'; ZipPath = $zp
        }
        if (-not $zr.Updatable) { $zr.Reason = 'BadManifest' }
        $idx = -1
        for ($i = 0; $i -lt $list.Count; $i++) { if ([string]$list[$i].Version -eq $zr.Version) { $idx = $i; break } }
        if ($idx -ge 0) {
            $g = $list[$idx]
            $g['ZipPath'] = $zp; $g['Source'] = 'zip'
            if (-not $g.Manifest) { $g['Manifest'] = $m }
            if (-not $g.Updatable) { $g['Type'] = $zr.Type; $g['Base'] = $zr.Base; $g['MinUpgradeFrom'] = $zr.MinUpgradeFrom; $g['Updatable'] = $zr.Updatable; $g['Reason'] = $zr.Reason }
        } else { [void]$list.Add($zr) }
    }
    return @($list.ToArray())
}

function Get-AppUpdateOptions {
    <#
    .SYNOPSIS
        What the UI offers: installed info, releases newer than installed (with Newer/Reachable/Hops/Reason/
        Needs/Kind/Warning) and the Dev mode availability. -ZipPaths merges local zip manifests.
    .EXAMPLE
        $o = Get-AppUpdateOptions -Force; $o.Releases | Where-Object Reachable
    #>
    [CmdletBinding()]
    param([switch]$Force, [string[]]$ZipPaths = @(), [string]$Root = $global:ScriptPath, $Releases = $null)

    $info = Get-AppVersionInfo -Root $Root
    if ($null -ne $Releases) { $cat = @{ Ok = $true; Error = $null; Releases = @($Releases) } }
    else { $cat = Get-AppUpdateCatalog -Force:$Force }
    $rels = Merge-AppUpdateZipReleases -Releases @($cat.Releases) -ZipPaths $ZipPaths
    $fromBase = ''
    if ($info.Installed -and $info.Installed.PSObject.Properties['base'] -and $info.Installed.base) { $fromBase = [string]$info.Installed.base }
    $out = New-Object System.Collections.ArrayList
    foreach ($r in $rels) {
        if ((Compare-AppVersion -A $r.Version -B $info.Version) -ne 1) { continue }
        $x = @{}
        foreach ($k in @($r.Keys)) { $x[$k] = $r[$k] }
        $x.Newer = $true; $x.Reachable = $false; $x.Hops = @(); $x.Needs = ''
        $x.Kind = [string]$r.Type
        $x.Warning = $(if ($r.Prerelease) { 'prerelease' } else { '' })
        if (-not $r.Updatable) { $x.Reason = $r.Reason }
        elseif (-not $info.Updatable) { $x.Reason = 'NotUpdatable' }
        else {
            $p = Get-AppUpdatePath -From $info.Version -To $r.Version -Releases $rels -FromBase $fromBase
            $x.Reachable = [bool]$p.Ok; $x.Hops = @($p.Hops); $x.Reason = $p.Reason; $x.Needs = $p.Needs
        }
        [void]$out.Add($x)
    }
    $sorted = @($out.ToArray() | Sort-Object -Descending -Property @{ Expression = {
                $v = ConvertTo-AppVersion -Text $_.Version
                [double]($v.Year * 1e10 + $v.Month * 1e8 + $v.Rc * 1e6 + $v.Minor * 1e3 + $v.Patch)
            } })

    $dev = @{ Available = $false; Reason = ''; Branch = (Get-UpdateSetting -Name dev_branch) }
    if ($info.DevTree) { $dev.Reason = 'DevTree' }
    elseif (-not $info.Updatable) { $dev.Reason = 'NotUpdatable' }
    elseif (-not $cat.Ok) { $dev.Reason = 'Offline' }
    elseif (-not $info.Commit) { $dev.Reason = 'NoCommit' }
    else {
        $highest = $null
        foreach ($r in $rels) {
            $vp = ConvertTo-AppVersion -Text ([string]$r.Version)
            if ($vp.Kind -ne 'Release') { continue }
            if ($null -eq $highest -or (Compare-AppVersion -A $vp -B $highest) -gt 0) { $highest = $vp }
        }
        if ($null -ne $highest -and (Compare-AppVersion -A $highest.Core -B $info.Parsed.Core) -gt 0) { $dev.Reason = 'NewerRelease' }
        else { $dev.Available = $true }
    }
    return @{ Ok = [bool]$cat.Ok; Error = $cat.Error; Installed = $info; Releases = $sorted; Dev = $dev }
}

function Get-AppUpdateState {
    <#
    .SYNOPSIS
        Last job state: @{Pending (job.json or $null); State (state.json or $null); Phase}. Never throws.
    .EXAMPLE
        (Get-AppUpdateState).Phase
    #>
    [CmdletBinding()]
    param([string]$Root = $global:ScriptPath)

    $res = @{ Pending = $null; State = $null; Phase = '' }
    try {
        $dir = Get-AppUpdateDataPath -Root $Root
        $res.Pending = Read-UpdateJsonFile -Path (Join-Path $dir 'job.json')
        $res.State = Read-UpdateJsonFile -Path (Join-Path $dir 'state.json')
        if ($res.Pending -and $res.Pending.phase) { $res.Phase = [string]$res.Pending.phase }
        elseif ($res.State -and $res.State.phase) { $res.Phase = [string]$res.State.phase }
    } catch { }
    return $res
}

function ConvertTo-AppFileMap {
    # files of a manifest (array of {path,sha256,size} or object map path -> {sha256,size}) as path -> @{Sha;Size}.
    param($Files)
    $map = @{}
    if ($null -eq $Files) { return $map }
    if ($Files -is [System.Array]) {
        foreach ($f in $Files) { if ($f.path) { $map[($f.path -replace '\\', '/')] = @{ Sha = ([string]$f.sha256).ToLowerInvariant(); Size = [int64]$f.size } } }
    } else {
        foreach ($p in $Files.PSObject.Properties) { $map[($p.Name -replace '\\', '/')] = @{ Sha = ([string]$p.Value.sha256).ToLowerInvariant(); Size = [int64]$p.Value.size } }
    }
    return $map
}

function Test-AppRecordingActive {
    # $true when a headset has Record on AND a running capture. Best-effort: false when the registry is not loaded.
    try {
        if (-not (Get-Command -Name Get-HeadsetInfosMerged -ErrorAction SilentlyContinue)) { return $false }
        foreach ($h in @(Get-HeadsetInfosMerged)) {
            $rec = (([string]$h.Record) -in '1', 'True')
            $cap = (([string]$h.SCRCPY) -in 'OK', '1', 'True')
            if ($rec -and $cap) { return $true }
        }
    } catch { }
    return $false
}

function Get-UpdateRawText {
    <#
    .SYNOPSIS
        Text of a URL as UTF-8 (no BOM). $null on any failure.
    .EXAMPLE
        Get-UpdateRawText -Url 'https://raw.githubusercontent.com/o/r/main/scripts/.releaseinclude'
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Url)
    try {
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
        $wc = [System.Net.WebClient]::new()
        try {
            $wc.Headers.Add('User-Agent', 'VR-Headset-Manager')
            $wc.Encoding = [System.Text.Encoding]::UTF8
            return ([string]$wc.DownloadString($Url)).TrimStart([char]0xFEFF)
        } finally { $wc.Dispose() }
    } catch { return $null }
}

function Get-UpdateRawUrl {
    # raw.githubusercontent.com URL of a repository path at a commit; each segment URL-encoded.
    param([string]$Repo, [string]$Sha, [string]$Path)
    $segs = @(($Path -replace '\\', '/').Split('/') | ForEach-Object { [uri]::EscapeDataString($_) })
    return ('https://raw.githubusercontent.com/{0}/{1}/{2}' -f $Repo, $Sha, ($segs -join '/'))
}

function Get-JsonKeyPath {
    <#
    .SYNOPSIS
        Recursive key paths of a parsed JSON value: objects descend, arrays and scalars are leaves.
    .EXAMPLE
        Get-JsonKeyPath -Value ('{"a":{"b":1}}' | ConvertFrom-Json)   # a, a.b
    #>
    [CmdletBinding()]
    param($Value, [string]$Prefix = '')
    $out = New-Object System.Collections.ArrayList
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        foreach ($p in $Value.PSObject.Properties) {
            $k = $(if ($Prefix) { $Prefix + '.' + $p.Name } else { $p.Name })
            [void]$out.Add($k)
            foreach ($c in @(Get-JsonKeyPath -Value $p.Value -Prefix $k)) { [void]$out.Add($c) }
        }
    }
    return @($out.ToArray())
}

function Test-AppDevDiffGuard {
    <#
    .SYNOPSIS
        Pure guard of a dev-mode diff (spec S10) -> @{Blocked;BlockReasons;Warnings}.
        -Files: objects with Path, Status, PreviousPath. Templates are JSON text (empty = skip key check).
    .EXAMPLE
        Test-AppDevDiffGuard -Files $diff.Files -OldTemplateJson $a -NewTemplateJson $b -InstalledDbSchema 9
    #>
    [CmdletBinding()]
    param($Files, [string]$OldTemplateJson = '', [string]$NewTemplateJson = '', [int]$InstalledDbSchema = 0)

    $block = New-Object System.Collections.ArrayList
    $warn = New-Object System.Collections.ArrayList
    $prefix = 'Major change on the branch: wait for the next release.'
    foreach ($f in @($Files)) {
        $st = [string]$f.Status
        $paths = @([string]$f.Path)
        if ($f.PreviousPath) { $paths += [string]$f.PreviousPath }
        foreach ($p0 in $paths) {
            $p = ($p0 -replace '\\', '/')
            $m = [regex]::Match($p, '^modules/db/schema/(\d+)_[^/]*\.sql$')
            if ($m.Success) {
                $n = [int]$m.Groups[1].Value
                if ($st -eq 'added') { [void]$warn.Add("New database migration: $p") }
                elseif ($n -le $InstalledDbSchema) { [void]$block.Add("$prefix Applied database migration changed: $p ($st)") }
            }
            if ($p -eq 'modules/updater.ps1') { [void]$block.Add("$prefix The updater itself changed: $p") }
            if ($p.StartsWith('sources/') -and $st -ne 'removed') { [void]$warn.Add("Binary or source folder file: $p") }
            if ($p -eq 'main.ps1' -or $p -eq 'modules/scripts_init.ps1') { [void]$warn.Add("Startup file changed: $p (restart needed)") }
        }
    }
    if ($OldTemplateJson -and $NewTemplateJson) {
        try {
            $old = $OldTemplateJson | ConvertFrom-Json
            $new = $NewTemplateJson | ConvertFrom-Json
            $ok = @(Get-JsonKeyPath -Value $old)
            $nk = @(Get-JsonKeyPath -Value $new)
            $oh = @{}; foreach ($k in $ok) { $oh[$k] = $true }
            $nh = @{}; foreach ($k in $nk) { $nh[$k] = $true }
            $gone = @($ok | Where-Object { -not $nh.ContainsKey($_) })
            $added = @($nk | Where-Object { -not $oh.ContainsKey($_) })
            if ($gone.Count -gt 0) {
                $show = ($gone | Select-Object -First 5) -join ', '
                [void]$block.Add("$prefix Config key(s) removed or renamed: $show" + $(if ($gone.Count -gt 5) { " (+$($gone.Count - 5) more)" } else { '' }))
            }
            if ($added.Count -gt 0) {
                $show = ($added | Select-Object -First 5) -join ', '
                [void]$warn.Add("New config key(s): $show" + $(if ($added.Count -gt 5) { " (+$($added.Count - 5) more)" } else { '' }))
            }
        } catch {
            [void]$block.Add("$prefix Config template could not be compared: " + $_.Exception.Message)
        }
    }
    return @{ Blocked = ($block.Count -gt 0); BlockReasons = @($block.ToArray()); Warnings = @($warn.ToArray()) }
}

function Get-AppDevDiff {
    <#
    .SYNOPSIS
        Dev-mode diff (spec S10): installed commit -> dev branch head via the GitHub compare API, filtered
        by the release include rules at ToCommit, with local-edit detection and the major-change guard.
        -Releases is passed to Get-AppUpdateOptions (tests).
    .EXAMPLE
        $d = Get-AppDevDiff; if ($d.Ok -and $d.Available -and -not $d.Blocked) { $d.Counts }
    #>
    [CmdletBinding()]
    param([string]$Root = $global:ScriptPath, $Releases = $null)

    $res = @{
        Ok = $false; Available = $false; Reason = ''; Error = $null; FromCommit = ''; ToCommit = ''; AheadBy = 0
        Files = @(); Blocked = $false; BlockReasons = @(); Warnings = @()
        Counts = @{ Changed = 0; Added = 0; Removed = 0; Ignored = 0 }; LocalEdits = @()
    }
    try {
        $opt = $(if ($null -ne $Releases) { Get-AppUpdateOptions -Root $Root -Releases $Releases } else { Get-AppUpdateOptions -Root $Root })
        $info = $opt.Installed
        $res.FromCommit = [string]$info.Commit
        if (-not $opt.Dev.Available) {
            $res.Ok = $true; $res.Reason = [string]$opt.Dev.Reason
            if (-not $res.Reason) { $res.Reason = 'NotAvailable' }
            return $res
        }
        $repo = Get-UpdateSetting -Name github_repo
        $branch = Get-UpdateSetting -Name dev_branch
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
        $headers = @{ 'User-Agent' = 'VR-Headset-Manager'; 'Accept' = 'application/vnd.github+json' }
        $base = "https://api.github.com/repos/$repo/compare/$($info.Commit)...$branch"
        # ONE call. GitHub paginates the COMMITS of a compare, not its files (at most 300 files, all
        # on the first page): asking for page 2 would return the same files again. 300 files means
        # the list may be truncated; more than 250 commits means the last listed commit is not the
        # branch head - both are too big for dev mode.
        $cmp = Invoke-RestMethod -Uri ($base + '?per_page=250') -Headers $headers -TimeoutSec 20
        $raw = New-Object System.Collections.ArrayList
        foreach ($g in @($cmp.files | ForEach-Object { $_ })) { [void]$raw.Add($g) }
        $res.AheadBy = [int]$cmp.ahead_by
        $commits = @($cmp.commits | ForEach-Object { $_ })
        if ($raw.Count -ge 300 -or $res.AheadBy -gt $commits.Count) {
            $res.Reason = 'TooManyChanges'; $res.Error = 'Too many changes for dev mode: wait for the next release.'
            return $res
        }
        if ($commits.Count -gt 0) { $res.ToCommit = [string]$commits[$commits.Count - 1].sha }
        if ($cmp.status -eq 'identical' -or $cmp.status -eq 'behind' -or $res.AheadBy -eq 0 -or -not $res.ToCommit) {
            if (-not $res.ToCommit) { $res.ToCommit = [string]$info.Commit }
            $res.Ok = $true; $res.Available = $true; $res.Reason = 'UpToDate'
            return $res
        }

        $rulesTxt = Get-UpdateRawText -Url (Get-UpdateRawUrl -Repo $repo -Sha $res.ToCommit -Path 'scripts/.releaseinclude')
        if ([string]::IsNullOrWhiteSpace($rulesTxt)) { $res.Reason = 'RulesUnavailable'; $res.Error = 'Could not fetch scripts/.releaseinclude.'; return $res }
        $rules = Read-ReleaseIncludeRules -Text $rulesTxt
        $oldTpl = Get-UpdateRawText -Url (Get-UpdateRawUrl -Repo $repo -Sha $res.FromCommit -Path 'templates/config/config.json')
        $newTpl = Get-UpdateRawText -Url (Get-UpdateRawUrl -Repo $repo -Sha $res.ToCommit -Path 'templates/config/config.json')
        if ($null -eq $oldTpl -or $null -eq $newTpl) { $res.Reason = 'TemplateUnavailable'; $res.Error = 'Could not fetch templates/config/config.json.'; return $res }

        $instFiles = ConvertTo-AppFileMap -Files $(if ($info.Installed) { $info.Installed.files } else { $null })
        $files = New-Object System.Collections.ArrayList
        $edits = New-Object System.Collections.ArrayList
        $cnt = @{ Changed = 0; Added = 0; Removed = 0; Ignored = 0 }
        foreach ($f in $raw) {
            $st = [string]$f.status
            if ($st -eq 'changed') { $st = 'modified' }
            if ($st -eq 'copied') { $st = 'added' }
            $path = ([string]$f.filename -replace '\\', '/')
            $prev = $(if ($f.previous_filename) { ([string]$f.previous_filename -replace '\\', '/') } else { '' })
            $included = [bool](Test-ReleaseIncludePath -Path $path -Rules $rules)
            $lp = $(if ($st -eq 'renamed') { $prev } else { $path })
            $local = $false
            $lf = Join-Path $Root ($lp -replace '/', '\')
            if (Test-Path -LiteralPath $lf -PathType Leaf) {
                $sha = Get-UpdateFileSha256 -Path $lf
                if ($instFiles.ContainsKey($lp)) { $local = ($sha -ne $instFiles[$lp].Sha) } else { $local = $true }
            }
            if ($included -and $local) { [void]$edits.Add($lp) }
            if (-not $included) { $cnt.Ignored++ }
            else {
                switch ($st) { 'added' { $cnt.Added++ } 'removed' { $cnt.Removed++ } default { $cnt.Changed++ } }
            }
            [void]$files.Add(@{ Path = $path; Status = $st; PreviousPath = $prev; LocalModified = $local; Included = $included })
        }
        $dbs = 0
        if ($info.Installed -and $info.Installed.PSObject.Properties['dbSchema'] -and $null -ne $info.Installed.dbSchema) { $dbs = [int]$info.Installed.dbSchema }
        $g = Test-AppDevDiffGuard -Files @($files.ToArray()) -OldTemplateJson $oldTpl -NewTemplateJson $newTpl -InstalledDbSchema $dbs
        $res.Files = @($files.ToArray() | Sort-Object { -not $_.LocalModified }, { $_.Path })
        $res.Counts = $cnt
        $res.LocalEdits = @($edits.ToArray() | Sort-Object)
        $res.Blocked = [bool]$g.Blocked; $res.BlockReasons = @($g.BlockReasons); $res.Warnings = @($g.Warnings)
        $res.Ok = $true; $res.Available = $true
        return $res
    } catch {
        $res.Ok = $false; $res.Reason = 'Error'; $res.Error = $_.Exception.Message
        Write-UpdateLog ("Dev diff failed: {0}" -f $_.Exception.Message) 'WARNING'
        return $res
    }
}

function Start-AppDevUpdate {
    <#
    .SYNOPSIS
        Stages a dev-mode update (spec S10): downloads the included changed files raw at ToCommit into
        data\update\stage\dev_<sha7>\ and writes job.json (mode dev). Called by Start-AppUpdate -Target dev.
        Returns the Start-AppUpdate result shape with Mode 'inplace'.
    .EXAMPLE
        $r = Start-AppDevUpdate -Root $global:ScriptPath -ProgressFile $pf
    #>
    [CmdletBinding()]
    param([string]$Root = $global:ScriptPath, $Releases = $null, [string]$ProgressFile = '')

    $fail = { param($reason, $err) return @{ Ok = $false; Mode = ''; Reason = $reason; Error = $err; Hops = @(); JobId = ''; Copy = @(); Delete = @() } }
    $stageDir = $null
    try {
        Write-AppUpdateProgress -File $ProgressFile -Step 'resolve' -Percent 5 -Message 'Comparing with the branch'
        $d = Get-AppDevDiff -Root $Root -Releases $Releases
        if (-not $d.Ok) { return (& $fail $(if ($d.Reason) { $d.Reason } else { 'Error' }) $d.Error) }
        if (-not $d.Available) { return (& $fail $(if ($d.Reason) { $d.Reason } else { 'DevUnavailable' }) 'Dev mode is not available.') }
        if ($d.Reason -eq 'UpToDate') { return (& $fail 'UpToDate' 'Already at the branch head.') }
        if ($d.Blocked) { return (& $fail 'DevBlocked' (@($d.BlockReasons) -join ' | ')) }

        $info = Get-AppVersionInfo -Root $Root
        $dataDir = Get-AppUpdateDataPath -Root $Root -Create
        $repo = Get-UpdateSetting -Name github_repo
        $sha7 = $d.ToCommit.Substring(0, 7)
        $stageDir = Get-AppUpdateDataPath -Root $Root -Child ('stage\dev_' + $sha7)
        if (Test-Path -LiteralPath $stageDir) { Remove-Item -LiteralPath $stageDir -Recurse -Force -ErrorAction SilentlyContinue }
        New-Item -ItemType Directory -Path $stageDir -Force | Out-Null

        $copy = New-Object System.Collections.ArrayList
        $delete = New-Object System.Collections.ArrayList
        $newMap = @{}
        $maxSchema = 0
        if ($info.Installed -and $info.Installed.PSObject.Properties['dbSchema'] -and $null -ne $info.Installed.dbSchema) { $maxSchema = [int]$info.Installed.dbSchema }
        $todo = @($d.Files | Where-Object { $_.Included })
        $i = 0
        foreach ($f in $todo) {
            $i++
            $path = [string]$f.Path
            if ($f.Status -eq 'removed') {
                if (-not (Test-AppUpdateProtectedPath -Path $path)) { [void]$delete.Add($path) }
                continue
            }
            if ($f.Status -eq 'renamed' -and $f.PreviousPath -and -not (Test-AppUpdateProtectedPath -Path $f.PreviousPath)) { [void]$delete.Add([string]$f.PreviousPath) }
            if (Test-AppUpdateProtectedPath -Path $path) { continue }
            Write-AppUpdateProgress -File $ProgressFile -Step 'download' -Percent (10 + [int](75 * $i / [Math]::Max(1, $todo.Count))) -Message ("Downloading {0}" -f $path)
            $out = Join-Path $stageDir ($path -replace '/', '\')
            $dl = Save-UpdateDownload -Url (Get-UpdateRawUrl -Repo $repo -Sha $d.ToCommit -Path $path) -OutFile $out
            if (-not $dl.Ok) { throw ("Download failed for {0}: {1}" -f $path, $dl.Error) }
            $len = (Get-Item -LiteralPath $out).Length
            $newMap[$path] = @{ Sha = (Get-UpdateFileSha256 -Path $out); Size = [int64]$len }
            [void]$copy.Add($path)
            $mm = [regex]::Match($path, '^modules/db/schema/(\d+)_')
            if ($mm.Success -and [int]$mm.Groups[1].Value -gt $maxSchema) { $maxSchema = [int]$mm.Groups[1].Value }
        }

        $oldMap = ConvertTo-AppFileMap -Files $(if ($info.Installed) { $info.Installed.files } else { $null })
        foreach ($k in @($delete)) { if ($oldMap.ContainsKey($k)) { $oldMap.Remove($k) } }
        foreach ($k in @($newMap.Keys)) { $oldMap[$k] = $newMap[$k] }
        $filesObj = [ordered]@{}
        foreach ($k in ($oldMap.Keys | Sort-Object)) { $filesObj[$k] = [ordered]@{ sha256 = $oldMap[$k].Sha; size = $oldMap[$k].Size } }
        $core = $info.Parsed.Core
        if (-not $core) { $core = $info.Version }
        $newVersion = $core + '+dev.' + $sha7
        $im = $info.Installed
        $manifest = [ordered]@{
            version = $newVersion; commit = $d.ToCommit
            base = $(if ($im -and $im.PSObject.Properties['base']) { [string]$im.base } else { '' })
            type = $(if ($im -and $im.PSObject.Properties['type']) { [string]$im.type } else { '' })
            dbSchema = $maxSchema; files = $filesObj
        }

        $mainPid = 0
        try {
            $mp = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop |
                    Where-Object { $_.CommandLine -like '*main.ps1*' -and $_.CommandLine -like ('*' + $Root + '*') } | Sort-Object CreationDate)
            if ($mp.Count -gt 0) { $mainPid = [int]$mp[0].ProcessId }
        } catch { $mainPid = 0 }

        $jobId = [guid]::NewGuid().ToString()
        $createdAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        $job = [ordered]@{
            jobId = $jobId; mode = 'dev'; fromVersion = $info.Version; toVersion = $newVersion
            toCommit = $d.ToCommit; installRoot = $Root; stageRoot = $stageDir
            copy = @($copy.ToArray()); delete = @($delete.ToArray()); manifest = $manifest; mainPid = $mainPid
            healthTimeoutSec = (Get-UpdateSetting -Name health_timeout_sec); createdAt = $createdAt; phase = 'staged'
            versionText = $newVersion
        }
        Write-UpdateTextFile -Path (Join-Path $dataDir 'state.json') -Content (([ordered]@{ jobId = $jobId; phase = 'staged'; fromVersion = $info.Version; toVersion = $newVersion; at = $createdAt }) | ConvertTo-Json -Depth 3)
        Write-UpdateTextFile -Path (Join-Path $dataDir 'job.json') -Content ($job | ConvertTo-Json -Depth 8)
        Write-AppUpdateProgress -File $ProgressFile -Status 'staged' -Step 'staged' -Percent 100 -Message 'Update staged'
        Write-UpdateLog ("Dev update staged: {0} -> {1} ({2} copy, {3} delete)" -f $info.Version, $newVersion, $copy.Count, $delete.Count) 'INFO'
        return @{ Ok = $true; Mode = 'inplace'; Reason = ''; Error = $null; Hops = @($newVersion); JobId = $jobId; Copy = @($copy.ToArray()); Delete = @($delete.ToArray()) }
    } catch {
        if ($stageDir -and (Test-Path -LiteralPath $stageDir)) { Remove-Item -LiteralPath $stageDir -Recurse -Force -ErrorAction SilentlyContinue }
        Write-AppUpdateProgress -File $ProgressFile -Status 'error' -Step 'error' -Message $_.Exception.Message
        Write-UpdateLog ("Dev update staging failed: {0}" -f $_.Exception.Message) 'ERROR'
        return (& $fail 'Error' $_.Exception.Message)
    }
}

function Start-AppUpdate {
    <#
    .SYNOPSIS
        Stages an update (spec S7): resolves hops, downloads/verifies, extracts hop 1 to data\update\stage\<v>\,
        writes chain.json and job.json. Does not restart. Returns @{Ok;Mode;Reason;Error;Hops;JobId;Copy;Delete}.
        -ZipPaths: local zips (their manifests join the release list). -Releases: skip the catalog (tests).
    .EXAMPLE
        $r = Start-AppUpdate -Target '2026-11.RC1.2' -ProgressFile $pf
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Target,
        [string[]]$TempIds = @(),
        [string[]]$ZipPaths = @(),
        [string[]]$ImportItems = @(),
        $Releases = $null,
        [string]$ProgressFile = '',
        [string]$Root = $global:ScriptPath,
        [switch]$Force
    )

    $fail = { param($reason, $err) return @{ Ok = $false; Mode = ''; Reason = $reason; Error = $err; Hops = @(); JobId = ''; Copy = @(); Delete = @() } }
    $stageDir = $null
    try {
        $info = Get-AppVersionInfo -Root $Root
        if ($info.DevTree) { return (& $fail 'DevTree' 'A development tree cannot be updated.') }
        if ($info.Parsed.Kind -eq 'Test') { return (& $fail 'TestVersion' 'A test build cannot be updated.') }
        if (-not $info.Updatable) { return (& $fail 'NotUpdatable' ('Installed version is not an updatable release: ' + $info.Version)) }
        $dataDir = Get-AppUpdateDataPath -Root $Root -Create
        if (Test-Path -LiteralPath (Join-Path $dataDir 'job.json')) { return (& $fail 'JobPending' 'Another update job is pending.') }
        if (-not $Force -and (Test-AppRecordingActive)) { return (& $fail 'RecordingActive' 'A recording is active.') }
        if ($Target -eq 'dev') { return (Start-AppDevUpdate -Root $Root -Releases $Releases -ProgressFile $ProgressFile) }

        $zips = New-Object System.Collections.ArrayList
        foreach ($z in @($ZipPaths)) { if ($z) { [void]$zips.Add($z) } }
        foreach ($id in @($TempIds)) { if ($id -match '^[\w-]+$') { [void]$zips.Add((Join-Path $dataDir ("upload_{0}.zip" -f $id))) } }

        Write-AppUpdateProgress -File $ProgressFile -Step 'resolve' -Percent 2 -Message 'Resolving update path'
        $rels = $Releases
        if ($null -eq $rels) {
            $cat = Get-AppUpdateCatalog
            $rels = @($cat.Releases)
            if (-not $cat.Ok -and $zips.Count -eq 0) { return (& $fail 'Offline' $cat.Error) }
        }
        $rels = Merge-AppUpdateZipReleases -Releases @($rels) -ZipPaths @($zips.ToArray())
        $fromBase = ''
        if ($info.Installed -and $info.Installed.PSObject.Properties['base'] -and $info.Installed.base) { $fromBase = [string]$info.Installed.base }
        $path = Get-AppUpdatePath -From $info.Version -To $Target -Releases $rels -FromBase $fromBase
        if (-not $path.Ok) { return (& $fail $path.Reason ("No update path to {0} ({1})." -f $Target, $path.Reason)) }
        $hops = @($path.Hops)
        $hopRel = @{}
        foreach ($h in $hops) { $hopRel[$h] = @($rels | Where-Object { $_.Version -eq $h })[0] }
        $first = $hopRel[$hops[0]]
        if ([string]$first.Type -eq 'major' -and -not (Get-Command -Name Install-AppMajorRelease -ErrorAction SilentlyContinue)) {
            return (& $fail 'MajorNotImplemented' 'Major updates are not implemented yet.')
        }

        # download + verify every hop zip
        $dl = Get-AppUpdateDataPath -Root $Root -Child 'dl' -Create
        $i = 0
        foreach ($h in $hops) {
            $r = $hopRel[$h]
            $pct = 5 + [int](40 * $i / $hops.Count)
            if ($r.ZipPath -and (Test-Path -LiteralPath $r.ZipPath -PathType Leaf)) { $zipFile = $r.ZipPath }
            else {
                $zipFile = Join-Path $dl ("{0}.zip" -f ($h -replace '[^\w.+-]', '_'))
                Write-AppUpdateProgress -File $ProgressFile -Step 'download' -Percent $pct -Message ("Downloading {0}" -f $h) -Hops $hops -Current $h
                $d = Save-UpdateDownload -Url $r.ZipUrl -OutFile $zipFile
                if (-not $d.Ok) { return (& $fail 'DownloadFailed' $d.Error) }
            }
            if ($r.ZipSha256) {
                $got = Get-UpdateFileSha256 -Path $zipFile
                if ($got -ne ([string]$r.ZipSha256).ToLowerInvariant()) { return (& $fail 'ZipHashMismatch' ("SHA-256 mismatch for {0}." -f $h)) }
            }
            $r['LocalZip'] = $zipFile
            $i++
        }

        # extract hop 1 and verify its files
        $v1 = $hops[0]
        $stageDir = Get-AppUpdateDataPath -Root $Root -Child (Join-Path 'stage' ($v1 -replace '[^\w.+-]', '_'))
        if (Test-Path -LiteralPath $stageDir) { Remove-Item -LiteralPath $stageDir -Recurse -Force -ErrorAction SilentlyContinue }
        Write-AppUpdateProgress -File $ProgressFile -Step 'extract' -Percent 50 -Message ("Extracting {0}" -f $v1) -Hops $hops -Current $v1
        [void](Expand-AppUpdateZip -ZipPath $first.LocalZip -Destination $stageDir)
        $newManifest = Read-UpdateJsonFile -Path (Join-Path $stageDir 'release.json')
        if ($null -eq $newManifest) { throw 'Package has no release.json.' }
        $newFiles = ConvertTo-AppFileMap -Files $newManifest.files
        $n = 0
        foreach ($k in @($newFiles.Keys)) {
            $n++
            if (($n % 200) -eq 0) { Write-AppUpdateProgress -File $ProgressFile -Step 'verify' -Percent (60 + [int](25 * $n / $newFiles.Count)) -Message 'Verifying files' -Hops $hops -Current $v1 }
            $fp = Join-Path $stageDir ($k -replace '/', '\')
            $sha = Get-UpdateFileSha256 -Path $fp
            if ($sha -ne $newFiles[$k].Sha) {
                Remove-Item -LiteralPath $stageDir -Recurse -Force -ErrorAction SilentlyContinue
                return (& $fail 'FileHashMismatch' ("Hash mismatch on {0}." -f $k))
            }
        }

        # copy / delete lists against the installed manifest
        Write-AppUpdateProgress -File $ProgressFile -Step 'plan' -Percent 90 -Message 'Preparing the job' -Hops $hops -Current $v1
        $oldSrc = $null
        if ($info.Installed) { $oldSrc = $info.Installed.files }
        $oldFiles = ConvertTo-AppFileMap -Files $oldSrc
        $copy = New-Object System.Collections.ArrayList
        $delete = New-Object System.Collections.ArrayList
        $dropped = 0
        foreach ($k in ($newFiles.Keys | Sort-Object)) {
            if (Test-AppUpdateProtectedPath -Path $k) { $dropped++; continue }
            $differs = $true
            if ($oldFiles.ContainsKey($k) -and $oldFiles[$k].Sha -eq $newFiles[$k].Sha -and (Test-Path -LiteralPath (Join-Path $Root ($k -replace '/', '\')) -PathType Leaf)) { $differs = $false }
            if ($differs) { [void]$copy.Add($k) }
        }
        if (Test-Path -LiteralPath (Join-Path $stageDir 'release.json')) { [void]$copy.Add('release.json') }
        foreach ($k in ($oldFiles.Keys | Sort-Object)) {
            if ($newFiles.ContainsKey($k)) { continue }
            if (Test-AppUpdateProtectedPath -Path $k) { $dropped++; continue }
            [void]$delete.Add($k)
        }
        if ($dropped -gt 0) { Write-UpdateLog ("Update: {0} protected path(s) excluded from the job." -f $dropped) 'INFO' }

        $filesObj = [ordered]@{}
        foreach ($k in ($newFiles.Keys | Sort-Object)) { $filesObj[$k] = [ordered]@{ sha256 = $newFiles[$k].Sha; size = $newFiles[$k].Size } }
        $instManifest = [ordered]@{
            version = [string]$newManifest.version; commit = [string]$newManifest.commit; base = [string]$newManifest.base
            type = [string]$newManifest.type; dbSchema = $newManifest.dbSchema; files = $filesObj
        }

        $remaining = @($hops | Select-Object -Skip 1)
        $jobId = [guid]::NewGuid().ToString()
        Write-UpdateTextFile -Path (Join-Path $dataDir 'chain.json') -Content (([ordered]@{ target = $Target; hops = $remaining; importItems = @($ImportItems) }) | ConvertTo-Json -Depth 5)

        if ([string]$first.Type -eq 'major') {
            $mj = Install-AppMajorRelease -StageRoot $stageDir -Manifest $newManifest -ImportItems $ImportItems -Root $Root -FromVersion $info.Version
            return @{ Ok = [bool]$mj.Ok; Mode = 'major'; Reason = ''; Error = $mj.Error; Hops = $hops; JobId = $jobId; Copy = @(); Delete = @() }
        }

        $mainPid = 0
        try {
            $mp = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop |
                    Where-Object { $_.CommandLine -like '*main.ps1*' -and $_.CommandLine -like ('*' + $Root + '*') } | Sort-Object CreationDate)
            if ($mp.Count -gt 0) { $mainPid = [int]$mp[0].ProcessId }
        } catch { $mainPid = 0 }

        $createdAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        $job = [ordered]@{
            jobId = $jobId; mode = 'inplace'; fromVersion = $info.Version; toVersion = [string]$newManifest.version
            toCommit = [string]$newManifest.commit; installRoot = $Root; stageRoot = $stageDir
            copy = @($copy.ToArray()); delete = @($delete.ToArray()); manifest = $instManifest; mainPid = $mainPid
            healthTimeoutSec = (Get-UpdateSetting -Name health_timeout_sec); createdAt = $createdAt; phase = 'staged'
        }
        Write-UpdateTextFile -Path (Join-Path $dataDir 'state.json') -Content (([ordered]@{ jobId = $jobId; phase = 'staged'; fromVersion = $info.Version; toVersion = [string]$newManifest.version; at = $createdAt }) | ConvertTo-Json -Depth 3)
        Write-UpdateTextFile -Path (Join-Path $dataDir 'job.json') -Content ($job | ConvertTo-Json -Depth 8)
        Write-AppUpdateProgress -File $ProgressFile -Status 'staged' -Step 'staged' -Percent 100 -Message 'Update staged' -Hops $hops -Current $v1
        Write-UpdateLog ("Update staged: {0} -> {1} ({2} copy, {3} delete)" -f $info.Version, $newManifest.version, $copy.Count, $delete.Count) 'INFO'
        return @{ Ok = $true; Mode = 'inplace'; Reason = ''; Error = $null; Hops = $hops; JobId = $jobId; Copy = @($copy.ToArray()); Delete = @($delete.ToArray()) }
    } catch {
        if ($stageDir -and (Test-Path -LiteralPath $stageDir)) { Remove-Item -LiteralPath $stageDir -Recurse -Force -ErrorAction SilentlyContinue }
        Write-AppUpdateProgress -File $ProgressFile -Status 'error' -Step 'error' -Message $_.Exception.Message
        Write-UpdateLog ("Update staging failed: {0}" -f $_.Exception.Message) 'ERROR'
        return (& $fail 'Error' $_.Exception.Message)
    }
}

# ---------------------------------------------------------------------------------------------
# S7 restart / S8 health handshake (T7)
# ---------------------------------------------------------------------------------------------

function Get-AppMajorTargetRoot {
    <#
    .SYNOPSIS
        Pure: the install root of a MAJOR release. When the parent folder of -Root is named
        VR_HEADSET_MANAGER.v*, the new root is <grandparent>\VR_HEADSET_MANAGER.v<version>\VR_HEADSET_MANAGER,
        else <parent>\VR_HEADSET_MANAGER.v<version>\VR_HEADSET_MANAGER.
    .EXAMPLE
        Get-AppMajorTargetRoot -Root 'D:\apps\VR_HEADSET_MANAGER.v2026-11.RC1\VR_HEADSET_MANAGER' -Version '2027-01.RC1'
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Version)
    $parent = Split-Path -Path $Root.TrimEnd('\') -Parent
    $base = $parent
    if ((Split-Path -Path $parent -Leaf) -like 'VR_HEADSET_MANAGER.v*') { $base = Split-Path -Path $parent -Parent }
    $safe = ($Version -replace '[^\w.+-]', '_')
    return (Join-Path (Join-Path $base ('VR_HEADSET_MANAGER.v' + $safe)) 'VR_HEADSET_MANAGER')
}

function Install-AppMajorRelease {
    <#
    .SYNOPSIS
        Installs a MAJOR release as a NEW folder next to the running one (spec S11). Copies the staged
        tree and the sources\ffmpeg* folders, writes <new>\data\update\import_from.json (from, fromVersion,
        items, chain = remaining hops, target), <new>\data\update\chain.json + state.json (so the chain
        continues after the first start) and the OLD root's data\update\job.json (mode major, phase
        staged) for Invoke-AppUpdateRestart. Starts and stops nothing. Refuses a non-empty target.
        Returns @{Ok;Mode='major';NewRoot;Error}.
    .EXAMPLE
        $r = Install-AppMajorRelease -StageRoot $stage -Manifest $manifest -ImportItems @('headsets', 'crops')
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StageRoot,
        [Parameter(Mandatory)]$Manifest,
        [string[]]$ImportItems = @(),
        [string]$Root = $global:ScriptPath,
        [string]$FromVersion = ''
    )
    $fail = { param($e) return @{ Ok = $false; Mode = 'major'; NewRoot = ''; Error = $e } }
    try {
        if (-not (Test-Path -LiteralPath $StageRoot -PathType Container)) { return (& $fail 'The staged package is missing.') }
        $ver = [string]$Manifest.version
        if (-not $ver) { return (& $fail 'The package manifest has no version.') }
        if (-not $FromVersion) {
            try { $FromVersion = [string](Get-AppVersionInfo -Root $Root).Version } catch { $FromVersion = '' }
        }
        $newRoot = Get-AppMajorTargetRoot -Root $Root -Version $ver
        if ((Test-Path -LiteralPath $newRoot) -and @(Get-ChildItem -LiteralPath $newRoot -Force -ErrorAction SilentlyContinue).Count -gt 0) {
            return (& $fail ("The target folder already exists and is not empty: {0}" -f $newRoot))
        }
        New-Item -ItemType Directory -Path $newRoot -Force | Out-Null
        foreach ($c in @(Get-ChildItem -LiteralPath $StageRoot -Force)) {
            Copy-Item -LiteralPath $c.FullName -Destination $newRoot -Recurse -Force
        }
        # ffmpeg is never shipped: carry the installed folders over so the new version starts without a download.
        $oldSources = Join-Path $Root 'sources'
        if (Test-Path -LiteralPath $oldSources -PathType Container) {
            foreach ($d in @(Get-ChildItem -LiteralPath $oldSources -Directory -Filter 'ffmpeg*' -ErrorAction SilentlyContinue)) {
                $dst = Join-Path (Join-Path $newRoot 'sources') $d.Name
                if (-not (Test-Path -LiteralPath $dst)) {
                    New-Item -ItemType Directory -Path (Split-Path -Path $dst -Parent) -Force | Out-Null
                    Copy-Item -LiteralPath $d.FullName -Destination $dst -Recurse -Force
                }
            }
        }

        # remaining hops come from the chain Start-AppUpdate wrote in the OLD root
        $hops = @(); $target = $ver
        $chain = Read-UpdateJsonFile -Path (Join-Path (Get-AppUpdateDataPath -Root $Root) 'chain.json')
        if ($chain) {
            if ($chain.PSObject.Properties['hops']) { $hops = @($chain.hops) }
            if ($chain.PSObject.Properties['target'] -and $chain.target) { $target = [string]$chain.target }
        }
        $newUpd = Get-AppUpdateDataPath -Root $newRoot -Create
        $createdAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        $imp = [ordered]@{ from = $Root; fromVersion = $FromVersion; items = @($ImportItems); chain = @($hops); target = $target }
        Write-UpdateTextFile -Path (Join-Path $newUpd 'import_from.json') -Content ($imp | ConvertTo-Json -Depth 5)
        if ($hops.Count -gt 0) {
            Write-UpdateTextFile -Path (Join-Path $newUpd 'chain.json') -Content (([ordered]@{ target = $target; hops = @($hops); importItems = @($ImportItems) }) | ConvertTo-Json -Depth 5)
            # Resume-AppUpdateChain only continues after a 'healthy' state of the running version.
            Write-UpdateTextFile -Path (Join-Path $newUpd 'state.json') -Content (([ordered]@{ jobId = ''; phase = 'healthy'; fromVersion = $FromVersion; toVersion = $ver; at = $createdAt; message = 'Installed as a new folder' }) | ConvertTo-Json -Depth 3)
        }

        $oldDir = Get-AppUpdateDataPath -Root $Root -Create
        $job = [ordered]@{
            jobId = [guid]::NewGuid().ToString(); mode = 'major'; fromVersion = $FromVersion; toVersion = $ver
            installRoot = $Root; newRoot = $newRoot; phase = 'staged'; createdAt = $createdAt
        }
        Write-UpdateTextFile -Path (Join-Path $oldDir 'job.json') -Content ($job | ConvertTo-Json -Depth 4)
        Write-UpdateLog ("Major update staged: {0} -> {1} in {2}" -f $FromVersion, $ver, $newRoot) 'INFO'
        return @{ Ok = $true; Mode = 'major'; NewRoot = $newRoot; Error = $null }
    } catch {
        Write-UpdateLog ("Major update install failed: {0}" -f $_.Exception.Message) 'ERROR'
        return (& $fail $_.Exception.Message)
    }
}

function Update-AppShortcuts {
    <#
    .SYNOPSIS
        Best effort: rewrites the .lnk files (target, arguments, start folder) that point under -OldRoot
        so they point to the same relative path under -NewRoot. Default folders: Desktop and Start menu
        (user and common). Returns the list of changed shortcut paths. Never throws.
    .EXAMPLE
        Update-AppShortcuts -OldRoot 'D:\a\VR_HEADSET_MANAGER' -NewRoot 'D:\b\VR_HEADSET_MANAGER'
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$OldRoot, [Parameter(Mandatory)][string]$NewRoot, [string[]]$Folders = @())
    $changed = @()
    try {
        if ($Folders.Count -eq 0) {
            $Folders = @(
                [Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('CommonDesktopDirectory'),
                [Environment]::GetFolderPath('StartMenu'), [Environment]::GetFolderPath('CommonStartMenu')
            ) | Where-Object { $_ }
        }
        $shell = New-Object -ComObject WScript.Shell
        $old = $OldRoot.TrimEnd('\'); $new = $NewRoot.TrimEnd('\')
        $rx = [regex]::Escape($old)
        $rep = $new.Replace('$', '$$')
        foreach ($f in $Folders) {
            if (-not (Test-Path -LiteralPath $f -PathType Container)) { continue }
            foreach ($lnk in @(Get-ChildItem -LiteralPath $f -Filter '*.lnk' -File -Recurse -ErrorAction SilentlyContinue)) {
                try {
                    $s = $shell.CreateShortcut($lnk.FullName)
                    $t = [string]$s.TargetPath; $a = [string]$s.Arguments; $w = [string]$s.WorkingDirectory
                    $hit = $t.StartsWith($old, [StringComparison]::OrdinalIgnoreCase) -or ($a.IndexOf($old, [StringComparison]::OrdinalIgnoreCase) -ge 0) -or $w.StartsWith($old, [StringComparison]::OrdinalIgnoreCase)
                    if (-not $hit) { continue }
                    if ($t.StartsWith($old, [StringComparison]::OrdinalIgnoreCase)) { $s.TargetPath = $new + $t.Substring($old.Length) }
                    if ($a) { $s.Arguments = [regex]::Replace($a, $rx, $rep, 'IgnoreCase') }
                    if ($w.StartsWith($old, [StringComparison]::OrdinalIgnoreCase)) { $s.WorkingDirectory = $new + $w.Substring($old.Length) }
                    $s.Save()
                    $changed += $lnk.FullName
                    Write-UpdateLog ("Update: shortcut {0} now points to {1}" -f $lnk.FullName, $new) 'INFO'
                } catch { Write-UpdateLog ("Update: shortcut {0} not changed: {1}" -f $lnk.FullName, $_.Exception.Message) 'WARNING' }
            }
        }
    } catch { Write-UpdateLog ("Update: shortcut update skipped: {0}" -f $_.Exception.Message) 'WARNING' }
    return $changed
}

function Invoke-AppUpdateRestart {
    <#
    .SYNOPSIS
        Hands a staged in-place job (data\update\job.json, phase staged) to the standalone updater:
        copies modules\updater.ps1 to data\update\updater.ps1, starts it as its own process, then stops
        the application (-Via Console: Invoke-AppShutdown in this process; -Via Web: asks main.ps1 to
        shut down through Send-AppCommandToMain). The updater waits for every process of this install
        to exit, applies the job and starts main.ps1 again. Returns @{Ok;Error}.
    .EXAMPLE
        $r = Start-AppUpdate -Target '2026-11.RC1.2'; if ($r.Ok -and $r.Mode -eq 'inplace') { Invoke-AppUpdateRestart -Via Console }
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('Auto', 'Console', 'Web')][string]$Via = 'Auto',
        [string]$Root = $global:ScriptPath,
        [switch]$NoShutdown
    )
    try {
        $dir = Get-AppUpdateDataPath -Root $Root
        $jobFile = Join-Path $dir 'job.json'
        $job = Read-UpdateJsonFile -Path $jobFile
        if ($null -eq $job) { return @{ Ok = $false; Error = 'No staged update job.' } }
        if ([string]$job.phase -notin @('staged', 'launching')) { return @{ Ok = $false; Error = ('Update job is in phase ' + $job.phase) } }

        if ($Via -eq 'Auto') {
            if (Get-Command -Name Send-AppCommandToMain -ErrorAction SilentlyContinue) { $Via = 'Web' } else { $Via = 'Console' }
        }
        if ([string]$job.mode -eq 'major') {
            # MAJOR: no updater. The new folder's main.ps1 waits for this process to exit, then starts.
            $newRoot = [string]$job.newRoot
            $newMain = Join-Path $newRoot 'main.ps1'
            if (-not $newRoot -or -not (Test-Path -LiteralPath $newMain -PathType Leaf)) { return @{ Ok = $false; Error = 'The new installation (main.ps1) was not found.' } }
            $oldMainPid = 0
            if ($Via -eq 'Web') {
                if (Get-Command -Name Get-MainProcessList -ErrorAction SilentlyContinue) {
                    $mp = @(Get-MainProcessList)
                    if ($mp.Count -gt 0) { $oldMainPid = [uint32]$mp[0].ProcessId }
                }
                if ($oldMainPid -eq 0 -and $job.PSObject.Properties['mainPid'] -and $job.mainPid) { $oldMainPid = [uint32]$job.mainPid }
                if ($oldMainPid -eq 0 -and -not $NoShutdown) { return @{ Ok = $false; Error = 'Main process not found; stop the application to finish the update.' } }
            } else { $oldMainPid = [uint32]$PID }
            $job.phase = 'switched'
            Write-UpdateTextFile -Path $jobFile -Content ($job | ConvertTo-Json -Depth 8)
            Write-UpdateLog ("Update: switching to {0} ({1} -> {2}, via {3})" -f $newRoot, $job.fromVersion, $job.toVersion, $Via) 'INFO'
            [void](Update-AppShortcuts -OldRoot $Root -NewRoot $newRoot)
            Start-Process cmd.exe -WorkingDirectory $newRoot -ArgumentList @(
                '/c', 'start', '"VR HEADSET MANAGER"', 'powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass',
                '-File', ('"{0}"' -f $newMain), '-WaitForPid', [string]$oldMainPid
            ) -WindowStyle Hidden
            if ($NoShutdown) { return @{ Ok = $true; Error = $null } }
            if ($Via -eq 'Web') {
                if (-not (Send-AppCommandToMain -Command 'shutdown' -MainPid $oldMainPid -InjectText '0')) {
                    return @{ Ok = $false; Error = 'Could not reach main.ps1; stop the application to finish the update.' }
                }
            } else {
                if (Get-Command -Name Invoke-AppShutdown -ErrorAction SilentlyContinue) { Invoke-AppShutdown }
            }
            return @{ Ok = $true; Error = $null }
        }

        $src =Join-Path (Join-Path $Root 'modules') 'updater.ps1'
        if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { return @{ Ok = $false; Error = 'modules\updater.ps1 is missing.' } }
        $exe = Join-Path $dir 'updater.ps1'
        Copy-Item -LiteralPath $src -Destination $exe -Force

        $job.phase = 'launching'
        Write-UpdateTextFile -Path $jobFile -Content ($job | ConvertTo-Json -Depth 8)

        Write-UpdateLog ("Update: starting the updater for {0} -> {1} (via {2})" -f $job.fromVersion, $job.toVersion, $Via) 'INFO'
        # cmd 'start': the updater gets its own console and is not a child of a process it waits for.
        Start-Process cmd.exe -ArgumentList @(
            '/c', 'start', '"VRHM updater"', 'powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass',
            '-File', ('"{0}"' -f $exe), '-JobFile', ('"{0}"' -f $jobFile)
        ) -WindowStyle Hidden
        if ($NoShutdown) { return @{ Ok = $true; Error = $null } }

        if ($Via -eq 'Web') {
            $mainPid = 0
            if (Get-Command -Name Get-MainProcessList -ErrorAction SilentlyContinue) {
                $mp = @(Get-MainProcessList)
                if ($mp.Count -gt 0) { $mainPid = [uint32]$mp[0].ProcessId }
            }
            if ($mainPid -eq 0 -and $job.mainPid) { $mainPid = [uint32]$job.mainPid }
            if ($mainPid -eq 0) { return @{ Ok = $false; Error = 'Main process not found; stop the application to finish the update.' } }
            if (-not (Send-AppCommandToMain -Command 'shutdown' -MainPid $mainPid -InjectText '0')) {
                return @{ Ok = $false; Error = 'Could not reach main.ps1; stop the application to finish the update.' }
            }
        } else {
            if (Get-Command -Name Invoke-AppShutdown -ErrorAction SilentlyContinue) { Invoke-AppShutdown }
        }
        return @{ Ok = $true; Error = $null }
    } catch {
        Write-UpdateLog ("Update restart failed: {0}" -f $_.Exception.Message) 'ERROR'
        return @{ Ok = $false; Error = $_.Exception.Message }
    }
}

function Complete-AppUpdateStartup {
    <#
    .SYNOPSIS
        Called by main.ps1 just before the main menu. When an updater is waiting for this version
        (job.json phase relaunched), writes data\update\started.ok with the job id so the updater
        marks the update healthy instead of rolling back. Returns $true when the stamp was written.
    .EXAMPLE
        Complete-AppUpdateStartup
    #>
    [CmdletBinding()]
    param([string]$Root = $global:ScriptPath)
    try {
        $dir = Get-AppUpdateDataPath -Root $Root
        $job = Read-UpdateJsonFile -Path (Join-Path $dir 'job.json')
        if ($null -eq $job -or [string]$job.phase -ne 'relaunched') { return $false }
        Write-UpdateTextFile -Path (Join-Path $dir 'started.ok') -Content ([string]$job.jobId)
        Write-UpdateLog ("Update: version {0} started, health stamp written for job {1}" -f $job.toVersion, $job.jobId) 'SUCCESS'
        return $true
    } catch { return $false }
}
# ---------------------------------------------------------------------------------------------
# S9 first-start upgrade steps / chain resume (T8)
# ---------------------------------------------------------------------------------------------

function Merge-ConfigTemplate {
    <#
    .SYNOPSIS
        Pure. Adds every key of -Template missing in -Config (recursively into objects present on both
        sides). Never changes an existing value; arrays and scalars are untouched; a config value that is
        not an object where the template has one is kept. Existing scrcpy.parameters.<Model> subtrees are
        not descended into (a whole missing model is added). Returns @{Config; Added=@('a.b.c')}.
    .EXAMPLE
        $r = Merge-ConfigTemplate -Config $cfg -Template $tpl; $r.Added
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)]$Template)

    $added = New-Object System.Collections.ArrayList
    $walk = {
        param($c, $t, [string]$prefix)
        foreach ($p in @($t.PSObject.Properties)) {
            $path = if ($prefix) { $prefix + '.' + $p.Name } else { $p.Name }
            $cp = $c.PSObject.Properties[$p.Name]
            if ($null -eq $cp) {
                $c | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value
                [void]$added.Add($path)
                continue
            }
            if ($path -match '^scrcpy\.parameters\.[^.]+$') { continue }
            $tv = $p.Value; $cv = $cp.Value
            if ($tv -is [System.Management.Automation.PSCustomObject] -and $cv -is [System.Management.Automation.PSCustomObject]) {
                & $walk $cv $tv $path
            }
        }
    }
    & $walk $Config $Template ''
    return @{ Config = $Config; Added = @($added.ToArray()) }
}

function Get-UpgradeFolderVersion {
    # Version text of a binary folder name through the existing parsers (regex fallback), or $null.
    param([ValidateSet('scrcpy', 'mediamtx')][string]$Binary, [string]$Folder)
    if ([string]::IsNullOrWhiteSpace($Folder)) { return $null }
    if ($Binary -eq 'scrcpy' -and (Get-Command -Name Get-ScrcpyVersion -ErrorAction SilentlyContinue)) { return (Get-ScrcpyVersion -ScrcpyFolder $Folder) }
    if ($Binary -eq 'mediamtx' -and (Get-Command -Name Get-MediaMtxVersion -ErrorAction SilentlyContinue)) { return (Get-MediaMtxVersion -MediaMtxFolder $Folder) }
    $leaf = Split-Path -Path $Folder -Leaf
    if ($leaf -match 'v(\d+(?:\.\d+){1,2})') { return $Matches[1] }
    return $null
}

function Invoke-AppUpgradeSteps {
    <#
    .SYNOPSIS
        First start after an update (spec S9): merges new template config keys, switches pinned
        scrcpy/ADB and mediamtx folders to the template's newer ones, runs modules\upgrade\<v>.ps1 steps
        (lastVersion < v <= current core, version order) and records data\update\applied.json.
        Cheap no-op when lastVersion = current core; dev tree / test build: nothing; first install: only
        records the version. Never throws. Returns @{Ran;Added;Switched;Steps;Error}.
        -ConfigPath / -TemplatePath / -NoReload let tests inject files and skip Get-Config.
    .EXAMPLE
        $r = Invoke-AppUpgradeSteps; if ($r.Ran) { $r.Added }
    #>
    [CmdletBinding()]
    param(
        [string]$Root = $global:ScriptPath,
        [string]$ConfigPath = '',
        [string]$TemplatePath = '',
        [switch]$NoReload
    )

    $res = @{ Ran = $false; Added = @(); Switched = @(); Steps = @(); Error = $null }
    try {
        $info = Get-AppVersionInfo -Root $Root
        if ($info.DevTree -or $info.Parsed.Kind -ne 'Release') { return $res }
        $core = [string]$info.Parsed.Core
        $dataDir = Get-AppUpdateDataPath -Root $Root -Create
        $appliedFile = Join-Path $dataDir 'applied.json'
        $applied = Read-UpdateJsonFile -Path $appliedFile
        $last = ''
        if ($applied -and $applied.PSObject.Properties['lastVersion']) { $last = [string]$applied.lastVersion }
        $stepNames = @()
        if ($applied -and $applied.PSObject.Properties['steps']) { $stepNames = @($applied.steps) }

        $save = {
            param($names)
            Write-UpdateTextFile -Path $appliedFile -Content (([ordered]@{ lastVersion = $core; steps = @($names) }) | ConvertTo-Json -Depth 4)
        }

        if ($last -ne '' -and (Compare-AppVersion -A $last -B $core) -eq 0) { return $res }
        $installedFile = Join-Path $dataDir 'installed.json'
        if ($last -eq '' -and -not (Test-Path -LiteralPath $installedFile -PathType Leaf)) {
            & $save @()
            return $res
        }
        $res.Ran = $true

        # 1. config merge
        if (-not $ConfigPath) { $ConfigPath = if ($global:ConfigFilePath) { [string]$global:ConfigFilePath } else { Join-Path (Join-Path $Root 'config') 'config.json' } }
        if (-not $TemplatePath) { $TemplatePath = Join-Path (Join-Path (Join-Path $Root 'templates') 'config') 'config.json' }
        $cfg = Read-UpdateJsonFile -Path $ConfigPath
        $tpl = Read-UpdateJsonFile -Path $TemplatePath
        if ($null -ne $cfg -and $null -ne $tpl) {
            $lock = $null
            if (Get-Command -Name Enter-VqaLock -ErrorAction SilentlyContinue) { $lock = Enter-VqaLock }
            try {
                $cfg = Read-UpdateJsonFile -Path $ConfigPath
                $m = Merge-ConfigTemplate -Config $cfg -Template $tpl
                $res.Added = @($m.Added)
                if ($res.Added.Count -gt 0) {
                    if ((Get-Command -Name Write-ConfigJson -ErrorAction SilentlyContinue) -and $ConfigPath -eq [string]$global:ConfigFilePath) {
                        Write-ConfigJson -Object $m.Config -Depth 20
                    } else {
                        Write-UpdateTextFile -Path $ConfigPath -Content ($m.Config | ConvertTo-Json -Depth 20)
                    }
                    Write-UpdateLog ("Upgrade: added {0} config key(s): {1}" -f $res.Added.Count, ($res.Added -join ', ')) 'INFO'
                }
            } finally {
                if ($lock -and (Get-Command -Name Exit-VqaLock -ErrorAction SilentlyContinue)) { Exit-VqaLock -Stream $lock }
            }
            if (-not $NoReload -and $res.Added.Count -gt 0 -and (Get-Command -Name Get-Config -ErrorAction SilentlyContinue)) { Get-Config | Out-Null }

            # 2. pinned binaries (never ffmpeg)
            $pins = @(
                @{ Name = 'scrcpy'; Exe = 'scrcpy.exe'; Get = { param($o) $o.scrcpy.folder }; Set = 'Set-ScrcpyAdbFolderConfig' },
                @{ Name = 'mediamtx'; Exe = 'mediamtx.exe'; Get = { param($o) $o.mediamtx.folder }; Set = 'Set-MediaMtxFolderConfig' }
            )
            foreach ($pin in $pins) {
                try {
                    $cf = [string](& $pin.Get $cfg); $tf = [string](& $pin.Get $tpl)
                    if (-not $cf -or -not $tf -or $cf -eq $tf) { continue }
                    if (-not (Test-Path -LiteralPath (Join-Path (Join-Path (Join-Path $Root 'sources') $tf) $pin.Exe) -PathType Leaf)) { continue }
                    $cv = Get-UpgradeFolderVersion -Binary $pin.Name -Folder $cf
                    $tv = Get-UpgradeFolderVersion -Binary $pin.Name -Folder $tf
                    if (-not $tv) { continue }
                    if ($cv -and ([version]$tv) -le ([version]$cv)) { continue }
                    if (Get-Command -Name $pin.Set -ErrorAction SilentlyContinue) {
                        & $pin.Set -RelativeFolder $tf
                        $res.Switched += $pin.Name
                        Write-UpdateLog ("Upgrade: {0} folder switched to {1}" -f $pin.Name, $tf) 'INFO'
                    }
                } catch { Write-UpdateLog ("Upgrade: {0} folder switch failed: {1}" -f $pin.Name, $_.Exception.Message) 'WARNING' }
            }
        }

        # 3. upgrade step files
        $upDir = Join-Path (Join-Path $Root 'modules') 'upgrade'
        $cands = New-Object System.Collections.ArrayList
        if (Test-Path -LiteralPath $upDir -PathType Container) {
            foreach ($f in @(Get-ChildItem -LiteralPath $upDir -Filter '*.ps1' -File)) {
                $v = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
                $pv = ConvertTo-AppVersion -Text $v
                if ($pv.Kind -ne 'Release') { continue }
                if ($last -ne '' -and (Compare-AppVersion -A $v -B $last) -le 0) { continue }
                if ((Compare-AppVersion -A $v -B $core) -gt 0) { continue }
                [void]$cands.Add(@{ Version = $v; Path = $f.FullName })
            }
        }
        $sorted = @($cands.ToArray())
        for ($i = 1; $i -lt $sorted.Count; $i++) {
            $x = $sorted[$i]; $j = $i - 1
            while ($j -ge 0 -and (Compare-AppVersion -A $sorted[$j].Version -B $x.Version) -gt 0) { $sorted[$j + 1] = $sorted[$j]; $j-- }
            $sorted[$j + 1] = $x
        }
        $done = New-Object System.Collections.ArrayList
        foreach ($n in $stepNames) { [void]$done.Add([string]$n) }
        $failed = $false
        foreach ($s in $sorted) {
            try {
                . $s.Path
                Invoke-UpgradeStep
                [void]$done.Add([string]$s.Version)
                $res.Steps += $s.Version
                Write-UpdateLog ("Upgrade: step {0} done" -f $s.Version) 'INFO'
            } catch {
                $res.Error = $_.Exception.Message
                Write-UpdateLog ("Upgrade: step {0} failed: {1}" -f $s.Version, $_.Exception.Message) 'ERROR'
                $failed = $true
            } finally {
                Remove-Item -LiteralPath 'function:Invoke-UpgradeStep' -ErrorAction SilentlyContinue
            }
            if ($failed) { break }
        }

        # 4. record (a failure keeps lastVersion so the failed step is retried next start)
        if (-not $failed) { & $save @($done.ToArray()) }
    } catch {
        $res.Error = $_.Exception.Message
        Write-UpdateLog ("Upgrade steps failed: {0}" -f $_.Exception.Message) 'ERROR'
    }
    return $res
}

function Resume-AppUpdateChain {
    <#
    .SYNOPSIS
        Called by main.ps1 after Complete-AppUpdateStartup. When data\update\chain.json still lists hops,
        waits for the updater to mark the previous hop healthy, then stages the next one with
        Start-AppUpdate and restarts (in-place). No hops left: deletes chain.json. Never throws.
    .EXAMPLE
        Resume-AppUpdateChain -WaitSec 15
    #>
    [CmdletBinding()]
    param([string]$Root = $global:ScriptPath, [int]$WaitSec = 15)
    try {
        $dir = Get-AppUpdateDataPath -Root $Root
        $chainFile = Join-Path $dir 'chain.json'
        $chain = Read-UpdateJsonFile -Path $chainFile
        if ($null -eq $chain) { return }
        $hops = @()
        if ($chain.PSObject.Properties['hops']) { $hops = @($chain.hops) }
        if ($hops.Count -eq 0) {
            Remove-Item -LiteralPath $chainFile -Force -ErrorAction SilentlyContinue
            Clear-AppUpdateLeftovers -Root $Root -WaitSec $WaitSec
            return
        }

        $jobFile = Join-Path $dir 'job.json'
        $deadline = (Get-Date).AddSeconds($WaitSec)
        while ((Test-Path -LiteralPath $jobFile) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
        if (Test-Path -LiteralPath $jobFile) { Write-UpdateLog 'Update chain: updater still running, chain left for the next start.' 'WARNING'; return }

        $state = Read-UpdateJsonFile -Path (Join-Path $dir 'state.json')
        if ($null -eq $state -or [string]$state.phase -ne 'healthy') { return }
        $info = Get-AppVersionInfo -Root $Root
        if ((Compare-AppVersion -A $info.Version -B ([string]$state.toVersion)) -ne 0) { return }

        $items = @()
        if ($chain.PSObject.Properties['importItems']) { $items = @($chain.importItems) }
        Write-UpdateLog ("Update chain: continuing to {0} ({1} hop(s) left)" -f $chain.target, $hops.Count) 'INFO'
        # Offline chains: the uploaded / downloaded zips of the remaining hops are still in data\update.
        $localZips = @(Get-ChildItem -LiteralPath $dir -Filter 'upload_*.zip' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
        $dlDir = Join-Path $dir 'dl'
        if (Test-Path -LiteralPath $dlDir) { $localZips += @(Get-ChildItem -LiteralPath $dlDir -Filter '*.zip' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }) }
        $r = Start-AppUpdate -Target ([string]$chain.target) -ImportItems $items -ZipPaths $localZips -Root $Root -Force
        if (-not $r.Ok) {
            Write-UpdateLog ("Update chain: next hop failed ({0}): {1}" -f $r.Reason, $r.Error) 'ERROR'
            Remove-Item -LiteralPath $chainFile -Force -ErrorAction SilentlyContinue
            return
        }
        if ($r.Mode -eq 'inplace') {
            $rs = Invoke-AppUpdateRestart -Via Console -Root $Root
            if (-not $rs.Ok) {
                Write-UpdateLog ("Update chain: restart failed: {0}" -f $rs.Error) 'ERROR'
                Remove-Item -LiteralPath $chainFile -Force -ErrorAction SilentlyContinue
            }
        }
    } catch {
        Write-UpdateLog ("Update chain resume failed: {0}" -f $_.Exception.Message) 'ERROR'
        try { Remove-Item -LiteralPath (Join-Path (Get-AppUpdateDataPath -Root $Root) 'chain.json') -Force -ErrorAction SilentlyContinue } catch { }
    }
}

function Clear-AppUpdateLeftovers {
    <#
    .SYNOPSIS
        Removes what a finished update leaves in data\update: uploaded zips (upload_*.zip), downloaded
        zips (dl\), stage\ folders and started.ok. Waits up to -WaitSec for the updater to delete
        job.json first and does nothing while a job is pending. Keeps state.json, installed.json,
        applied.json and the backups. Never throws. Returns the number of items removed.
    .EXAMPLE
        Clear-AppUpdateLeftovers
    #>
    [CmdletBinding()]
    param([string]$Root = $global:ScriptPath, [int]$WaitSec = 15)
    $n = 0
    try {
        $dir = Get-AppUpdateDataPath -Root $Root
        if (-not (Test-Path -LiteralPath $dir)) { return 0 }
        $jobFile = Join-Path $dir 'job.json'
        $deadline = (Get-Date).AddSeconds($WaitSec)
        while ((Test-Path -LiteralPath $jobFile) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
        if (Test-Path -LiteralPath $jobFile) { return 0 }
        $items = @()
        $items += @(Get-ChildItem -LiteralPath $dir -Filter 'upload_*.zip' -File -ErrorAction SilentlyContinue)
        foreach ($sub in 'dl', 'stage') {
            $p = Join-Path $dir $sub
            if (Test-Path -LiteralPath $p) { $items += @(Get-ChildItem -LiteralPath $p -Force -ErrorAction SilentlyContinue) }
        }
        $ok = Join-Path $dir 'started.ok'
        if (Test-Path -LiteralPath $ok) { $items += @(Get-Item -LiteralPath $ok) }
        foreach ($it in $items) {
            try { Remove-Item -LiteralPath $it.FullName -Recurse -Force -ErrorAction Stop; $n++ } catch { }
        }
        if ($n -gt 0) { Write-UpdateLog ("Update: {0} leftover item(s) removed from data\update" -f $n) 'INFO' }
    } catch { }
    return $n
}