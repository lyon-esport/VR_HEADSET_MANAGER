###############################################################
# adb_apps.ps1
# Headset apps: app catalogue, installed-app cache, launch/uninstall,
# pending updates, icons, online name resolution (Update-AppCacheOnline).
# Split out of adb_functions.ps1 (S9-2). Auto-loaded by scripts_init.ps1.
# Translations are loaded centrally in scripts_init.ps1 into $global:msg.
# ASCII only (no em dashes, no curly quotes, no accents).
###############################################################


# Resolves a Quest package name to its display name, icon URL, and local icon path.
# Checks data/app_names.csv first; on cache miss fetches from:
#   https://github.com/threethan/MetaMetadata (updates daily, covers all Meta Store + SideQuest apps)
# Icons are downloaded to website/assets/app_icons/ and served directly by the web server.
# Unknown packages are cached with DisplayName = PackageName and empty IconUrl so the
# network is never hit more than once per package.
function Get-AppDisplayName {
    param (
        [Parameter(Mandatory=$true)]
        [string]$PackageName
    )

    $appInfo = Get-AppInfo -PackageName $PackageName -searchOnline $true

    return $appInfo
}


function Invoke-HeadsetApp {
    <#
    .SYNOPSIS
    Launches an application on a VR headset via ADB over WiFi.

    .DESCRIPTION
    Accepts either a PackageName or a DisplayName.
    - If a DisplayName is supplied, it is resolved to a PackageName via the
      app_names.csv cache (and updated if the app is not yet listed).
    - Verifies the app is installed on the headset before launching.
    - Returns $true on success, $false on any failure.

    .PARAMETER headsetIP
    IP address of the headset.

    .PARAMETER PackageName
    Android package name (e.g. "com.myapp.vr"). Takes priority over DisplayName.

    .PARAMETER DisplayName
    Human-readable app name as listed in app_names.csv (e.g. "SKYBOX VR Video Player").

    .PARAMETER AdbPort
    ADB TCP port (default: global adbPort_default).

    .EXAMPLE
    Invoke-HeadsetApp -headsetIP "192.168.1.100" -PackageName "com.myapp.vr"
    Invoke-HeadsetApp -headsetIP "192.168.1.100" -DisplayName "SKYBOX VR Video Player"
    #>
    param (
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$Device,
        [string]$PackageName  = '',
        [string]$DisplayName  = '',
        [string]$adb          = $global:adbPath
    )
    if (-not $Device) { Write-Log ($msg.AdbWifiConnectFailed -f 'unknown', 'no device') -Level ERROR; return $false }
    $DeviceId = $Device.DeviceId

    # 1. Resolve PackageName from DisplayName if not provided directly
    if (-not $PackageName) {
        if (-not $DisplayName) {
            Write-Log ($msg.ErrorOccurred -f "Either PackageName or DisplayName must be provided.") -Level ERROR
            return $false
        }

        # Search the catalogue by display name. Still a scan rather than a query:
        # display_name is not unique and has no index, and "first match wins" is
        # the behaviour this has always had.
        $match = @(Invoke-DbQuery -Name 'catalog.list') |
                 Where-Object { $_.DisplayName -eq $DisplayName } |
                 Select-Object -First 1

        if ($match) {
            $PackageName = $match.PackageName
            Write-Log ($msg.AppDisplayNameResolved -f $PackageName, $DisplayName) -Level DEBUG
        } else {
            Write-Log ($msg.AppDisplayNameNotFound -f $DisplayName) -Level ERROR
            return $false
        }
    } else {
        # Ensure the package is listed in app_names.csv (triggers cache update if needed)
        Get-AppDisplayName -PackageName $PackageName | Out-Null
    }

    # 2. Device already connected - no Connect-AdbWifi needed

    # 3. Verify the app is installed on the headset
    $installed = Invoke-AdbCmd -Device $Device -Command "shell pm list packages $PackageName" -adb $adb
    if ($installed -eq $false -or -not ($installed -match [regex]::Escape("package:$PackageName"))) {
        Write-Log ($msg.ErrorOccurred -f "App '$PackageName' is not installed on $DeviceId.") -Level ERROR
        return $false
    }

    # 4. Launch the app
    try {
        Write-Log ($msg.HeadsetDetected -f $PackageName, $DeviceId) -Level INFO
        # Meta Home (vrshell) is a system launcher - monkey cannot inject into it; use HOME intent
        if ($PackageName -eq 'com.oculus.vrshell') {
            $launchOutput = Invoke-AdbCmd -Device $Device -Command "shell am start -a android.intent.action.MAIN -c android.intent.category.HOME" -adb $adb
            if ($launchOutput -eq $false -or ($launchOutput -match "error|Error|Exception")) {
                Write-Log ($msg.ErrorOccurred -f "Failed to launch Meta Home: $launchOutput") -Level ERROR
                return $false
            }
            return $true
        }
        $launchOutput = Invoke-AdbCmd -Device $Device -Command "shell monkey -p $PackageName -c android.intent.category.LAUNCHER 1" -adb $adb
        if ($launchOutput -eq $false -or ($launchOutput -match "error|Error|Exception")) {
            Write-Log ($msg.ErrorOccurred -f "Failed to launch '$PackageName': $launchOutput") -Level ERROR
            return $false
        }
        return $true
    }
    catch {
        Write-Log ($msg.ErrorOccurred -f $_) -Level ERROR
        return $false
    }
}


function Get-HeadsetInstalledApps {
    <#
    .SYNOPSIS
    Returns an array of all installed applications on a VR headset via ADB over WiFi.

    .DESCRIPTION
    Queries the headset with "pm list packages" and returns an array of PSCustomObjects
    with PackageName, DisplayName and IconUrl.
    - Known packages are resolved instantly from the local app_names.csv cache.
    - When -ResolveMissing is specified, packages absent from the cache are looked up
      online via the MetaMetadata repository and app_names.csv is updated accordingly.
      Requires an active internet connection; unknown apps that are not found online
      are stored with DisplayName = PackageName and IconUrl = "" so the network is
      never hit more than once per package.

    .PARAMETER headsetIP
    IP address of the headset.

    .PARAMETER ThirdPartyOnly
    When specified, only returns user-installed (non-system) packages (-3 flag).

    .PARAMETER ResolveMissing
    When specified, fetches metadata for packages not yet in app_names.csv and
    updates the cache file. Requires internet access.

    .PARAMETER AdbPort
    ADB TCP port (default: global adbPort_default).

    .EXAMPLE

    Get-HeadsetInstalledApps -device $Device -ThirdPartyOnly
    Get-HeadsetInstalledApps -device $Device -ThirdPartyOnly -ResolveMissing
    #>
    param (
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$Device,
        [switch]$ThirdPartyOnly = $true,
        [switch]$ResolveMissing = $false,
        [string]$adb    = $global:adbPath
    )
    if (-not $Device) { return @() }
    $DeviceId = $Device.DeviceId

    try {
        $pmArgs = if ($ThirdPartyOnly) { 'list packages -3' } else { 'list packages' }
        $rawLines = Invoke-AdbCmd -Device $Device -Command "shell pm $pmArgs" -adb $adb

        if (-not $rawLines) {
            Write-Log ($msg.ErrorOccurred -f "No packages returned from $DeviceId") -Level WARNING
            return @()
        }
        # Collect all package names first
        $packages = foreach ($line in $rawLines) {
            if ($line -match '^package:(.+)$') { $Matches[1].Trim() }
        }

        # Load the catalogue into a hashtable for fast lookup
        $cache = Get-AppCatalogMap

        # Resolve missing packages online if requested

        if ($ResolveMissing) {
            $missing = @($packages | Where-Object { -not $cache.ContainsKey($_) })
            if ($missing.Count -gt 0) {
                Write-Log ($msg.AppDisplayNameNotFound -f "$($missing.Count) unknown packages - fetching online...") -Level INFO
                foreach ($pkg in $missing) {
                    # Get-AppDisplayName fetches metadata and updates app_names.csv automatically
                    $entry = Get-AppInfo -PackageName $pkg -searchOnline $true
                    $cache[$pkg] = $entry
                }
            }
        }

        # When returning all packages, determine which are third-party with a second ADB call
        $thirdPartySet = @{}
        if (-not $ThirdPartyOnly) {
            $tp = Invoke-AdbCmd -Device $Device -Command "shell pm list packages -3" -adb $adb
            foreach ($line in $tp) {
                if ($line -match '^package:(.+)$') { $thirdPartySet[$Matches[1].Trim()] = $true }
            }
        }

        # Persist new packages and always sync ThirdParty from live ADB result.
        # Only rows that actually differ are upserted; the whole-catalogue rewrite
        # this used to do is what made concurrent callers lose each other's work.
        $catalogBatch = @()
        foreach ($pkg in $packages) {
            $pkgIsThirdParty = if ($ThirdPartyOnly) { $true } elseif ($thirdPartySet.ContainsKey($pkg)) { $true } else { $false }
            $entry = $cache[$pkg]
            if (-not $entry) {
                $shortName = if ($pkg.StartsWith('com.')) { $pkg.Substring(4) } else { $pkg }
                $entry = [PSCustomObject]@{ PackageName=$pkg; DisplayName=$shortName; IconUrl=''; LocalIconPath=''; ThirdParty=$pkgIsThirdParty; LatestVersion='' }
                $cache[$pkg] = $entry
            } else {
                # ThirdParty comes back from the view as 'True'/'False', so compare
                # through ConvertTo-DbBool rather than string-matching a bool.
                $cached = [string]$entry.ThirdParty
                if ($cached -ne '' -and (ConvertTo-DbBool $cached) -eq (ConvertTo-DbBool $pkgIsThirdParty)) { continue }
                $entry | Add-Member -MemberType NoteProperty -Name ThirdParty -Value $pkgIsThirdParty -Force
            }
            $catalogBatch += @{
                package_name    = $pkg
                display_name    = [string]$entry.DisplayName
                icon_url        = [string]$entry.IconUrl
                local_icon_path = [string]$entry.LocalIconPath
                third_party     = (ConvertTo-DbBool $pkgIsThirdParty)
                latest_version  = [string]$entry.LatestVersion
            }
        }
        if ($catalogBatch.Count -gt 0) {
            Invoke-DbBatch -Name 'catalog.upsert' -Rows $catalogBatch | Out-Null
            Write-Log ($msg.AppDisplayNameNotFound -f "app catalogue updated with ThirdParty/new packages") -Level DEBUG
        }

        $apps = foreach ($pkg in $packages) {
            $entry = if ($cache.ContainsKey($pkg)) { $cache[$pkg] } else { $null }
            [PSCustomObject]@{
                PackageName   = $pkg
                DisplayName   = if ($entry -and $entry.DisplayName -and $entry.DisplayName -ne $pkg) { $entry.DisplayName } else { $pkg }
                IconUrl       = if ($entry) { $entry.IconUrl }       else { '' }
                LocalIconPath = if ($entry) { $entry.LocalIconPath } else { '' }
                Version       = if ($entry) { $entry.Version }       else { '' }
                ThirdParty    = if ($ThirdPartyOnly) { $true } else { $thirdPartySet.ContainsKey($pkg) }
            }
        }

        # reorder apps alphabetically by DisplayName for better UX
        $apps = $apps | Sort-Object DisplayName

        
        Write-Log ($msg.HeadsetDetected -f "$($apps.Count) apps", $DeviceId) -Level INFO
        return $apps

    }
    catch {
        Write-Log ($msg.ErrorOccurred -f $_) -Level ERROR
        return @()
    }
}


function Resolve-LocalAppIcon {
    <#
    .SYNOPSIS
    Resolves an app icon from local storage, copying from sources if needed.
    Returns the web-relative path (/assets/app_icons/<file>) or $null.
    Priority: 1) already in app_icons, 2) in templates\website\assets\app_icons, 3) $null (go online).
    #>
    param(
        [string]$PackageName,
        [string]$IconCacheDir = $(Join-Path $global:ScriptPath "website\assets\app_icons"),
        [switch]$SourcesOnly
    )

    # 1. templates\website\assets\app_icons has highest priority (operator choice overrides web cache).
    #    Longest-prefix match: exact package name wins over shorter prefixes.
    #    e.g. com.android.png matches com.android.* but com.android.server.telecom.png wins for that package.
    #    The matched file is copied under its original stem name (shared, no per-package duplication).
    $sourcesDir = Join-Path $global:ScriptPath "templates\website\assets\app_icons"
    $sourceFile = $null
    $destExt    = $null
    if (Test-Path -LiteralPath $sourcesDir) {
        $bestLen = -1
        foreach ($ext in @('.webp', '.png', '.jpg')) {
            Get-ChildItem -LiteralPath $sourcesDir -Filter "*$ext" | ForEach-Object {
                $stem = $_.BaseName
                if ($PackageName -eq $stem -or $PackageName -like "$stem.*") {
                    if ($stem.Length -gt $bestLen) {
                        $bestLen    = $stem.Length
                        $sourceFile = $_.FullName
                        $destExt    = $ext
                    }
                }
            }
        }
    }
    if ($sourceFile) {
        if (-not (Test-Path -LiteralPath $IconCacheDir)) {
            New-Item -ItemType Directory -Path $IconCacheDir -Force | Out-Null
        }
        $bestStem = [System.IO.Path]::GetFileNameWithoutExtension($sourceFile)
        $destName = "$bestStem$destExt"
        $destPath = Join-Path $IconCacheDir $destName

        # Copy only when the cached file is missing or stale. This function runs on every poll of
        # every headset, so it used to re-copy the SAME icon (com.oculus.png is the foreground app
        # of nearly every Quest) several times a minute - and with two headsets two poll runspaces
        # copied it at the same instant, one failing with "file in use by another process" and
        # losing that poll cycle's foreground-app lookup. A copy keeps the source's timestamp, so
        # "same size and not older than the source" means the cache is already current.
        $needCopy = $true
        try {
            if (Test-Path -LiteralPath $destPath) {
                $src = Get-Item -LiteralPath $sourceFile
                $dst = Get-Item -LiteralPath $destPath
                if ($dst.Length -eq $src.Length -and $dst.LastWriteTimeUtc -ge $src.LastWriteTimeUtc) { $needCopy = $false }
            }
        } catch { $needCopy = $true }

        if ($needCopy) {
            try {
                Copy-Item -LiteralPath $sourceFile -Destination $destPath -Force -ErrorAction Stop
            } catch {
                # Another runspace is writing the same icon right now. That is not a failure: the file
                # is being put in place by an identical copy, so only give up if it still is not there.
                if (-not (Test-Path -LiteralPath $destPath)) { throw }
            }
        }
        return "/assets/app_icons/$destName"
    }

    # 2. Already cached in app_icons? Prefer .webp over .png. Skipped when SourcesOnly.
    if (-not $SourcesOnly) {
        foreach ($ext in @('.webp', '.png', '.jpg')) {
            $candidate = Join-Path $IconCacheDir "$PackageName$ext"
            if (Test-Path -LiteralPath $candidate) {
                return "/assets/app_icons/$PackageName$ext"
            }
        }
    }

    return $null
}


function Get-AppInfo {
    <#
    .SYNOPSIS
    Retrieves display name and icon URL for a given Android package name, using a local cache and online lookup.
    .DESCRIPTION
    Checks a local CSV cache file for the package information first. If not found or incomplete,
    optionally searches online via the MetaMetadata GitHub repository and updates the cache.
    Returns a PSCustomObject with PackageName, DisplayName, IconUrl, and LocalIconPath (if icon downloaded).
    Update the cache file with any new information found online to minimize future lookups.
    .PARAMETER PackageName
    The Android package name to look up (e.g. "com.myapp.vr").
    .PARAMETER IconCacheDir
    Directory to store downloaded icons (default: "website\assets\app_icons" under the script path).
    .PARAMETER searchOnline
    If set, performs an online search for missing packages and updates the cache (default: $true).
    .EXAMPLE
    Get-AppInfo -PackageName "com.myapp.vr"
    Get-AppInfo -PackageName "com.cosmorama.tabletroopers"
    Get-AppInfo -PackageName "com.mrf.pixeltoys.cabin" -searchOnline $true
       #>

    param (
        [Parameter(Mandatory=$true)]
        [string]$PackageName,
        [string]$IconCacheDir = $(Join-Path $global:ScriptPath "website\assets\app_icons"),
        [bool]$searchOnline = $false,
        [switch]$ForceOnline = $false
    )

    # genreate package name without com. on the beginning without using match
    if ($PackageName.StartsWith("com.")) {
        $PackageName_short = $PackageName.Substring(4)
    } else {
        $PackageName_short = $PackageName
    }
    
    $appInfos = [PSCustomObject]@{
                PackageName = $PackageName
                DisplayName = $PackageName_short
                IconUrl     = ""
                LocalIconPath = ""
                }
                

    # 1. Check the catalogue first.
    #
    # This used to load the WHOLE known_apps.csv and, on any change, write the
    # whole thing back. Get-AppInfo runs in every per-headset monitoring runspace
    # on every poll, so with N headsets that was N processes rewriting one file
    # with no lock - the last writer won and the others' resolutions vanished
    # silently. One row in, one row out removes the hazard entirely.
    #
    # The hashtable shape is kept so the rest of the function reads unchanged; it
    # simply never holds more than this one package.
    $cache = @{}
    try {
        foreach ($row in @(Invoke-DbQuery -Name 'catalog.get' -Parameters @{ package_name = $PackageName })) {
            $cache[[string]$row.PackageName] = $row
        }
    }
    catch {
        Write-Log ("Get-AppInfo: catalogue read failed for {0} - {1}" -f $PackageName, $_.Exception.Message) -Level DEBUG
    }
    # If the cache contains the package with all info let's return it !
    # But first, always check templates\website\assets\app_icons - operator-supplied icons take priority
    # and must be copied to app_icons even on early-return paths.
    if ($cache.ContainsKey($PackageName) -and $cache[$PackageName].DisplayName -and ($cache[$PackageName].DisplayName -ne $PackageName_short)) {
        $localResolved = Resolve-LocalAppIcon -PackageName $PackageName -IconCacheDir $IconCacheDir
        if ($localResolved -and $cache[$PackageName].LocalIconPath -ne $localResolved) {
            $cache[$PackageName].LocalIconPath = $localResolved
            Save-AppCatalogEntry -Entry $cache[$PackageName]
        }
        return $cache[$PackageName]
    }
    # fill the display name with cached value if already known, it may be added before of set manually by the user.
    if ($cache[$PackageName].DisplayName -and $PackageName_short -in $cache[$PackageName].DisplayName) {
        $appInfos.DisplayName = $cache[$PackageName].DisplayName
    }

    # Resolve from local storage before going online.
    # SourcesOnly when ForceOnline: skip app_icons cache, but still honour templates\website\assets\app_icons.
    $localResolved = Resolve-LocalAppIcon -PackageName $PackageName -IconCacheDir $IconCacheDir -SourcesOnly:$ForceOnline
    if ($localResolved) {
        $appInfos.LocalIconPath = $localResolved
    }

    # Let's search online !
    if ($searchOnline) {
        $baseUrl = "https://raw.githubusercontent.com/threethan/MetaMetadata/main/data"
        $folders = @('common', 'oculus', 'oculus_public', 'oculusdb', 'sidequest')
    
        
        foreach ($folder in $folders) {
            $url = "$baseUrl/$folder/$PackageName.json"
            write-log ($msg.AppDisplayNameResolved -f $appInfos.DisplayName, "Online lookup on $url") -Level DEBUG
            $response = $null
            $icon = ""
            try {
                $response = Invoke-RestMethod -Uri $url -TimeoutSec 8 -ErrorAction Stop
                $icon = ""
                if ($response.square) { $icon = $response.square }
                elseif ($response.icon) { $icon = $response.icon }
                elseif ($response.landscape) { $icon = $response.landscape }
                elseif ($response.portrait) { $icon = $response.portrait }
                elseif ($response.hero) { $icon = $response.hero }
                elseif ($response.logo) { $icon = $response.logo }
            } catch {
                # Not found in this folder, try next
            }
            if ($response.name) {$appInfos.DisplayName = $response.name}
            if ($icon) {
                $appInfos.IconUrl = $icon
                break
            }
        }
    
        # Download icon locally so the web UI can display it without hitting remote URLs
        if ($appInfos.IconUrl -and ($appInfos.LocalIconPath -eq '' -or $ForceOnline)) {
            if (-not (Test-Path -LiteralPath $IconCacheDir)) {
                New-Item -ItemType Directory -Path $IconCacheDir -Force | Out-Null
            }

            # Derive extension from the remote URL; default to .png
            $ext = '.png'
            if ($appInfos.IconUrl -match '\.([a-zA-Z]{2,4})(?:[?#]|$)') {
                $ext = '.' + $Matches[1].ToLower()
            }
            $iconFileName = "$PackageName$ext"
            $iconFile     = Join-Path $IconCacheDir $iconFileName

            if (-not (Test-Path -LiteralPath $iconFile) -or $ForceOnline) {
                try {
                    Invoke-WebRequest -Uri $appInfos.IconUrl -OutFile $iconFile -TimeoutSec 10 -ErrorAction Stop
                    Write-Log ($msg.AppDisplayNameResolved -f "Icon saved", $iconFileName) -Level DEBUG
                } catch {
                    Write-Log ($msg.AppDisplayNameNotFound -f "Icon download failed: $PackageName") -Level DEBUG
                    $iconFileName = ""
                }
            }

            if ($iconFileName -ne "") {
                # Prefer .webp: if we downloaded .png but .webp already exists, use webp and drop png
                $webpFile = Join-Path $IconCacheDir "$PackageName.webp"
                $pngFile  = Join-Path $IconCacheDir "$PackageName.png"
                if ((Test-Path -LiteralPath $webpFile) -and (Test-Path -LiteralPath $pngFile)) {
                    Remove-Item -LiteralPath $pngFile -Force -ErrorAction SilentlyContinue
                    $appInfos.LocalIconPath = "/assets/app_icons/$PackageName.webp"
                } else {
                    $appInfos.LocalIconPath = "/assets/app_icons/$iconFileName"
                }
            }
        }
    }


    if (($appInfos.DisplayName -ne $cache[$PackageName].DisplayName) -and ($PackageName_short -eq $appInfos.DisplayName)){
        $appInfos.DisplayName = $cache[$PackageName].DisplayName
    }

    # Final fallback: no per-package icon resolved (MetaMetadata miss, no operator
    # override, no cached image). Point LocalIconPath at the shared generic
    # Android icon shipped under templates\website\assets\app_icons\android.png.
    # Applies to both Pico and Meta unknowns.
    if ([string]::IsNullOrWhiteSpace($appInfos.LocalIconPath)) {
        $defaultSrc = Join-Path $global:ScriptPath "templates\website\assets\app_icons\android.png"
        if (Test-Path -LiteralPath $defaultSrc) {
            $defaultDest = Join-Path $IconCacheDir "android.png"
            if (-not (Test-Path -LiteralPath $IconCacheDir)) {
                New-Item -ItemType Directory -Path $IconCacheDir -Force | Out-Null
            }
            if (-not (Test-Path -LiteralPath $defaultDest)) {
                Copy-Item -LiteralPath $defaultSrc -Destination $defaultDest -Force
            }
            $appInfos.LocalIconPath = "/assets/app_icons/android.png"
        }
    }

    # Update cache file if we got new info
    $changed = (-not $cache.ContainsKey($PackageName)) -or
               ($appInfos.DisplayName -ne $cache[$PackageName].DisplayName) -or
               ($appInfos.IconUrl -ne $cache[$PackageName].IconUrl) -or
               ($appInfos.LocalIconPath -ne $cache[$PackageName].LocalIconPath)
    if ($changed) {
        # Preserve ThirdParty and LatestVersion from the existing row: this
        # function resolves display metadata only and must not clear columns it
        # knows nothing about. catalog.upsert overwrites every column it is given.
        $existingTp     = if ($cache.ContainsKey($PackageName)) { $cache[$PackageName].ThirdParty }    else { $null }
        $existingLatest = if ($cache.ContainsKey($PackageName)) { $cache[$PackageName].LatestVersion } else { '' }
        $appInfos | Add-Member -MemberType NoteProperty -Name ThirdParty    -Value $existingTp     -Force
        $appInfos | Add-Member -MemberType NoteProperty -Name LatestVersion -Value $existingLatest -Force
        $cache[$PackageName] = $appInfos
        Save-AppCatalogEntry -Entry $appInfos
    }
    return $appInfos
}


<#
.SYNOPSIS
    Write one catalogue entry, from a row carrying the legacy column names.
.DESCRIPTION
    The single write point for app_catalog outside the batch paths. Takes the
    PascalCase shape every caller in this module already builds (PackageName,
    DisplayName, IconUrl, LocalIconPath, ThirdParty, LatestVersion) and maps it to
    the snake_case parameters of catalog.upsert.

    ThirdParty defaults to true when absent, matching Get-AppInfoFromKnownApps and
    the legacy importer, so a row is never silently reclassified as a system app.
.EXAMPLE
    Save-AppCatalogEntry -Entry $appInfos
#>
function Save-AppCatalogEntry {
    param (
        [Parameter(Mandatory = $true)]$Entry
    )

    if (-not $Entry -or -not $Entry.PackageName) { return }

    $thirdParty = 1
    if ($Entry.PSObject.Properties['ThirdParty'] -and "$($Entry.ThirdParty)" -ne '') {
        $thirdParty = ConvertTo-DbBool $Entry.ThirdParty -Default $true
    }
    $latest = ''
    if ($Entry.PSObject.Properties['LatestVersion']) { $latest = [string]$Entry.LatestVersion }

    try {
        Invoke-DbNonQuery -Name 'catalog.upsert' -Parameters @{
            package_name    = [string]$Entry.PackageName
            display_name    = [string]$Entry.DisplayName
            icon_url        = [string]$Entry.IconUrl
            local_icon_path = [string]$Entry.LocalIconPath
            third_party     = $thirdParty
            latest_version  = $latest
        } | Out-Null
    }
    catch {
        Write-Log ("Save-AppCatalogEntry failed for {0} - {1}" -f $Entry.PackageName, $_.Exception.Message) -Level WARNING
    }
}


function Update-AppCacheOnline {
    param(
        [string]$ProgressFile = '',
        [int]$MaxThreads = 12,
        [switch]$ForceOnline = $false
    )

    # The selection stays in PowerShell rather than becoming a WHERE clause: it
    # compares DisplayName against the com.-stripped package name, which SQL
    # cannot express as cheaply, and keeping it here means the filter that decides
    # what to re-fetch from the network is unchanged by this migration.
    $rows = @(Invoke-DbQuery -Name 'catalog.list')
    $toResolve = if ($ForceOnline) { $rows } else {
        @($rows | Where-Object {
            [string]::IsNullOrWhiteSpace($_.DisplayName) -or
            $_.DisplayName -eq ($_.PackageName -replace '^com\.','') -or
            [string]::IsNullOrWhiteSpace($_.IconUrl) -or
            (-not $_.PSObject.Properties['LatestVersion']) -or [string]::IsNullOrWhiteSpace($_.LatestVersion)
        })
    }
    $total = $toResolve.Count

    if ($total -eq 0) {
        Write-Log "Update-AppCacheOnline: nothing to resolve" -Level INFO
        if ($ProgressFile) { [System.IO.File]::WriteAllText($ProgressFile, '{"status":"done","done":0,"total":0}') }
        return
    }

    # Phase 1: parallel HTTP lookups via RunspacePool
    $metaScriptBlock = {
        param([string]$PackageName)
        $folders = @('common', 'oculus', 'oculus_public', 'oculusdb', 'sidequest')
        $base    = 'https://raw.githubusercontent.com/threethan/MetaMetadata/main/data'
        $result  = [PSCustomObject]@{ PackageName = $PackageName; DisplayName = ''; IconUrl = ''; LatestVersion = '' }
        foreach ($f in $folders) {
            try {
                $r    = Invoke-RestMethod -Uri "$base/$f/$PackageName.json" -TimeoutSec 8 -ErrorAction Stop
                $icon = if     ($r.square)    { $r.square }
                        elseif ($r.icon)      { $r.icon }
                        elseif ($r.landscape) { $r.landscape }
                        elseif ($r.portrait)  { $r.portrait }
                        elseif ($r.hero)      { $r.hero }
                        elseif ($r.logo)      { $r.logo }
                        else                  { '' }
                if ($r.name) { $result.DisplayName = $r.name }
                if ($f -eq 'oculus') {
                    try {
                        $lv = $r.data.node.liveChannel.nodes[0].latest_supported_binary.version
                        if ($lv) { $result.LatestVersion = $lv }
                    } catch {}
                }
                if ($icon)   { $result.IconUrl = $icon; break }
                if ($r.name) { break }
            } catch {}
        }
        # oculus folder is the only source for liveChannel version; always fetch it when not yet obtained
        if (-not $result.LatestVersion) {
            try {
                $ro = Invoke-RestMethod -Uri "$base/oculus/$PackageName.json" -TimeoutSec 8 -ErrorAction Stop
                $lv = $ro.data.node.liveChannel.nodes[0].latest_supported_binary.version
                if ($lv) { $result.LatestVersion = $lv }
            } catch {}
        }
        return $result
    }

    $pool = [runspacefactory]::CreateRunspacePool(1, $MaxThreads)
    $pool.Open()

    $runspaces = foreach ($row in $toResolve) {
        $ps = [powershell]::Create().AddScript($metaScriptBlock).AddArgument($row.PackageName)
        $ps.RunspacePool = $pool
        [PSCustomObject]@{ PS = $ps; AR = $ps.BeginInvoke(); Pkg = $row.PackageName; Collected = $false }
    }

    $httpResults = @{}
    $done = 0
    do {
        foreach ($rs in ($runspaces | Where-Object { $_.AR.IsCompleted -and -not $_.Collected })) {
            try {
                $res = $rs.PS.EndInvoke($rs.AR)
                if ($res) { $httpResults[$res.PackageName] = $res }
            } catch {}
            $rs.PS.Dispose()
            $rs.Collected = $true
            $done++
            if ($ProgressFile -and ($done % 5 -eq 0 -or $done -eq $total)) {
                try { [System.IO.File]::WriteAllText($ProgressFile,
                    "{`"status`":`"running`",`"done`":$done,`"total`":$total}") } catch {}
            }
        }
        if (($runspaces | Where-Object { -not $_.Collected }).Count -gt 0) {
            Start-Sleep -Milliseconds 300
        }
    } while (($runspaces | Where-Object { -not $_.Collected }).Count -gt 0)

    $pool.Close()
    $pool.Dispose()

    # Phase 2: serial icon downloads, then one batched catalogue write.
    #
    # $dirty records WHICH packages actually changed. The CSV version only needed
    # a single $changed flag because it rewrote the entire file either way; a
    # batch of upserts should carry only the rows that moved.
    $cache = Get-AppCatalogMap
    $dirty = @{}
    $IconCacheDir = Join-Path $global:ScriptPath "website\assets\app_icons"
    if (-not (Test-Path -LiteralPath $IconCacheDir)) {
        New-Item -ItemType Directory -Path $IconCacheDir -Force | Out-Null
    }

    $changed = $false
    foreach ($pkg in $httpResults.Keys) {
        $r = $httpResults[$pkg]
        if (-not $r.DisplayName -and -not $r.IconUrl -and -not $r.LatestVersion) { continue }
        $entry = if ($cache.ContainsKey($pkg)) { $cache[$pkg] } else { $null }
        if (-not $entry) { continue }

        $localPath = ''
        # SourcesOnly when ForceOnline: still honour templates\website\assets\app_icons but skip app_icons cache.
        $localPath = Resolve-LocalAppIcon -PackageName $pkg -IconCacheDir $IconCacheDir -SourcesOnly:$ForceOnline
        if (-not $localPath -and $r.IconUrl) {
            $ext = '.png'
            if ($r.IconUrl -match '\.([a-zA-Z]{2,4})(?:[?#]|$)') { $ext = '.' + $Matches[1].ToLower() }
            $iconFile = Join-Path $IconCacheDir "$pkg$ext"
            if (-not (Test-Path -LiteralPath $iconFile) -or $ForceOnline) {
                try {
                    Invoke-WebRequest -Uri $r.IconUrl -OutFile $iconFile -TimeoutSec 10 -ErrorAction Stop
                } catch { $iconFile = '' }
            }
            if ($iconFile -and (Test-Path -LiteralPath $iconFile)) {
                # Prefer .webp: if both exist after download, drop .png
                $webpFile = Join-Path $IconCacheDir "$pkg.webp"
                $pngFile  = Join-Path $IconCacheDir "$pkg.png"
                if ((Test-Path -LiteralPath $webpFile) -and (Test-Path -LiteralPath $pngFile)) {
                    Remove-Item -LiteralPath $pngFile -Force -ErrorAction SilentlyContinue
                    $localPath = "/assets/app_icons/$pkg.webp"
                } else {
                    $localPath = "/assets/app_icons/$pkg$ext"
                }
            }
        }

        if ($r.DisplayName)    { $entry.DisplayName  = $r.DisplayName }
        if ($r.IconUrl)        { $entry.IconUrl       = $r.IconUrl }
        if ($localPath)        { $entry.LocalIconPath = $localPath }
        if ($r.LatestVersion) {
            if ($entry.PSObject.Properties['LatestVersion']) { $entry.LatestVersion = $r.LatestVersion }
            else { $entry | Add-Member -MemberType NoteProperty -Name LatestVersion -Value $r.LatestVersion -Force }
        }
        $changed = $true
        $dirty[$pkg] = $true
    }

    # Phase 3: sync operator icons from templates\website\assets\app_icons for ALL packages in cache.
    # Runs regardless of $toResolve so fully-resolved packages are also covered.
    $sourcesDir = Join-Path $global:ScriptPath "templates\website\assets\app_icons"
    if (Test-Path -LiteralPath $sourcesDir) {
        foreach ($pkg in $cache.Keys) {
            $localPath = Resolve-LocalAppIcon -PackageName $pkg -IconCacheDir $IconCacheDir -SourcesOnly
            if ($localPath -and $cache[$pkg].LocalIconPath -ne $localPath) {
                $cache[$pkg].LocalIconPath = $localPath
                $changed = $true
                $dirty[$pkg] = $true
            }
        }
    }

    # Phase 4: ensure every cache entry has a LocalIconPath. Packages that miss
    # MetaMetadata AND have no operator override get the shared generic Android icon.
    $defaultSrc  = Join-Path $global:ScriptPath "templates\website\assets\app_icons\android.png"
    $defaultDest = Join-Path $IconCacheDir "android.png"
    if (Test-Path -LiteralPath $defaultSrc) {
        if (-not (Test-Path -LiteralPath $defaultDest)) {
            Copy-Item -LiteralPath $defaultSrc -Destination $defaultDest -Force
        }
        foreach ($pkg in $cache.Keys) {
            if ([string]::IsNullOrWhiteSpace($cache[$pkg].LocalIconPath)) {
                $cache[$pkg].LocalIconPath = "/assets/app_icons/android.png"
                $changed = $true
                $dirty[$pkg] = $true
            }
        }
    }

    if ($changed -and $dirty.Count -gt 0) {
        # One transaction for the lot. This runs in the resolve job, a separate
        # process from the console and the monitor, so the batch is exactly the
        # kind of write the WAL journal and the retry wrapper exist to serialise.
        $batch = @()
        foreach ($pkg in $dirty.Keys) {
            $entry = $cache[$pkg]
            if (-not $entry) { continue }
            $thirdParty = 1
            if ($entry.PSObject.Properties['ThirdParty'] -and "$($entry.ThirdParty)" -ne '') {
                $thirdParty = ConvertTo-DbBool $entry.ThirdParty -Default $true
            }
            $batch += @{
                package_name    = [string]$pkg
                display_name    = [string]$entry.DisplayName
                icon_url        = [string]$entry.IconUrl
                local_icon_path = [string]$entry.LocalIconPath
                third_party     = $thirdParty
                latest_version  = [string]$entry.LatestVersion
            }
        }
        if ($batch.Count -gt 0) {
            Invoke-DbBatch -Name 'catalog.upsert' -Rows $batch | Out-Null
        }
    }

    Write-Log "Update-AppCacheOnline: resolved $done / $total packages" -Level INFO
    if ($ProgressFile) {
        [System.IO.File]::WriteAllText($ProgressFile,
            "{`"status`":`"done`",`"done`":$done,`"total`":$total}")
    }
}


# Get-InstalledAppsCachePath was removed here. The per-headset installed-app
# cache is the headset_installed_apps table, keyed on the permanent headset id,
# and the legacy importer names the file it reads directly rather than through a
# helper - so nothing called this.


<#
.SYNOPSIS
    The whole app catalogue as a hashtable keyed on package name.
.DESCRIPTION
    Replaces the "Import-Csv the whole known_apps.csv into a hashtable" idiom that
    appeared in half a dozen functions. Rows carry the legacy column names
    (PackageName / DisplayName / IconUrl / LocalIconPath / ThirdParty /
    LatestVersion) because they come through v_app_catalog, so callers that used
    to read CSV rows need no other change.

    Returns an empty hashtable rather than throwing when the database is
    unreachable, matching how a missing CSV used to behave.
.EXAMPLE
    $catalog = Get-AppCatalogMap
    $catalog['com.oculus.browser'].DisplayName
#>
function Get-AppCatalogMap {
    $map = @{}
    try {
        foreach ($row in @(Invoke-DbQuery -Name 'catalog.list')) {
            if ($row.PackageName) { $map[[string]$row.PackageName] = $row }
        }
    }
    catch {
        Write-Log ("Get-AppCatalogMap failed - " + $_.Exception.Message) -Level ERROR
    }
    return $map
}


<#
.SYNOPSIS
    One headset's cached installed apps, with catalogue metadata joined in.
.DESCRIPTION
    The database replacement for reading data\<Name>_installed_apps.csv. Rows
    carry the lean cache columns (PackageName, Version, PendingVersion,
    StoreVersion, SizeBytes) plus DisplayName, IconUrl, LocalIconPath and
    ThirdParty resolved from the catalogue.

    -ThirdPartyOnly filters out the built-in packages, which is what callers that
    only want launchable apps want.
.EXAMPLE
    $apps = Get-HeadsetInstalledAppsCached -headsetName 'Q3 RED' -ThirdPartyOnly
#>
function Get-HeadsetInstalledAppsCached {
    param (
        [string]$headsetName,
        [switch]$ThirdPartyOnly
    )

    $headsetId = Resolve-HeadsetIdByName -Name $headsetName
    if ($headsetId -le 0) { return @() }

    try {
        $rows = @(Invoke-DbQuery -Name 'installed.list_joined' -Parameters @{ headset_id = $headsetId })
    }
    catch {
        Write-Log ("Get-HeadsetInstalledAppsCached failed for '{0}' - {1}" -f $headsetName, $_.Exception.Message) -Level ERROR
        return @()
    }

    if ($ThirdPartyOnly) {
        $rows = @($rows | Where-Object { ConvertTo-BoolField $_.ThirdParty })
    }
    return $rows
}


function Initialize-AppNamesCache {
    <#
    .SYNOPSIS
    Seeds the app catalogue from templates\data\known_apps.csv when it is empty.

    .DESCRIPTION
    The catalogue is a table now, but the seed stays a shipped, human-readable
    file - it carries the pre-filled OS app names a fresh install needs.

    No-ops when the catalogue already holds rows, so it is safe to call on every
    startup: an operator's edits are never overwritten by the template.

    .EXAMPLE
    Initialize-AppNamesCache
    #>
    try {
        $existing = Invoke-DbScalar -Name 'catalog.count'
        if ($null -ne $existing -and [int]$existing -gt 0) { return }
    }
    catch {
        Write-Log ("Initialize-AppNamesCache: could not read the catalogue - " + $_.Exception.Message) -Level WARNING
        return
    }

    $templatePath = Join-Path $global:ScriptPath "templates\data\known_apps.csv"
    if (-not (Test-Path -LiteralPath $templatePath)) {
        Write-Log "App cache template not found, catalogue left empty" -Level WARNING
        return
    }

    try {
        $batch = @()
        foreach ($r in @(Import-Csv -LiteralPath $templatePath -Delimiter "," -Encoding UTF8)) {
            if (-not $r.PackageName) { continue }
            # The shipped template predates the ThirdParty column on some rows and
            # may still carry the older Type = third-party/built-in spelling, the
            # same two shapes the legacy importer handles.
            $thirdParty = 1
            if ($r.PSObject.Properties['ThirdParty'] -and "$($r.ThirdParty)" -ne '') {
                $thirdParty = ConvertTo-DbBool $r.ThirdParty
            } elseif ($r.PSObject.Properties['Type'] -and "$($r.Type)" -ne '') {
                $thirdParty = if ("$($r.Type)" -eq 'third-party') { 1 } else { 0 }
            }
            $batch += @{
                package_name    = [string]$r.PackageName
                display_name    = [string]$(if ($r.PSObject.Properties['DisplayName'])   { $r.DisplayName }   else { '' })
                icon_url        = [string]$(if ($r.PSObject.Properties['IconUrl'])       { $r.IconUrl }       else { '' })
                local_icon_path = [string]$(if ($r.PSObject.Properties['LocalIconPath']) { $r.LocalIconPath } else { '' })
                third_party     = $thirdParty
                latest_version  = [string]$(if ($r.PSObject.Properties['LatestVersion']) { $r.LatestVersion } else { '' })
            }
        }
        if ($batch.Count -gt 0) {
            Invoke-DbBatch -Name 'catalog.upsert' -Rows $batch | Out-Null
            Write-Log ("App catalogue seeded from template ({0} entries)" -f $batch.Count) -Level INFO
        }
    }
    catch {
        Write-Log ("Initialize-AppNamesCache failed - " + $_.Exception.Message) -Level ERROR
    }
}


function Clear-AppNamesCache {
    <#
    .SYNOPSIS
    Archives known_apps.csv and wipes the app_icons cache folder.

    .DESCRIPTION
    - Empties the app_catalog table and re-seeds it from the shipped template.
    - Deletes all files in website\assets\app_icons\ except those that originated
      from templates\website\assets\app_icons (operator-supplied icons are never deleted).
    Returns $true on success, $false on failure.

    The timestamped known_apps_old_<stamp>.csv archive the CSV era wrote is gone:
    there is no file to rename, and the whole point of the operation is to discard
    resolved metadata that turned out wrong. Backup-Database covers the case where
    the operator wants the previous contents back.

    .EXAMPLE
    Clear-AppNamesCache
    #>
    try {
        # Clear and re-seed in one transaction: a reader must never see the
        # catalogue empty, which is exactly what the window between the two used
        # to look like when this renamed a file and wrote a new one.
        Invoke-DbTransaction -Script {
            Invoke-DbNonQuery -Name 'catalog.clear' | Out-Null
            Initialize-AppNamesCache
        } | Out-Null
        Write-Log "App catalogue cleared and re-seeded from template" -Level INFO

        # Wipe app_icons cache - preserve files that came from templates\website\assets\app_icons
        $iconCacheDir = Join-Path $global:ScriptPath "website\assets\app_icons"
        $sourcesDir   = Join-Path $global:ScriptPath "templates\website\assets\app_icons"
        if (Test-Path -LiteralPath $iconCacheDir) {
            $sourceNames = @{}
            if (Test-Path -LiteralPath $sourcesDir) {
                Get-ChildItem -LiteralPath $sourcesDir -File | ForEach-Object { $sourceNames[$_.Name] = $true }
            }
            Get-ChildItem -LiteralPath $iconCacheDir -File |
                Where-Object { -not $sourceNames.ContainsKey($_.Name) } |
                Remove-Item -Force -ErrorAction SilentlyContinue
            Write-Log "App icons cache cleared (operator icons preserved)" -Level INFO
        }

        return $true
    } catch {
        Write-Log ($msg.ErrorOccurred -f $_) -Level ERROR
        return $false
    }
}


function Get-AppInfoFromKnownApps {
    <#
    .SYNOPSIS
    Enriches a list of package names with metadata from the app catalogue.
    Returns PackageName, DisplayName, IconUrl, LocalIconPath, ThirdParty for each package.
    Missing packages get safe defaults (DisplayName=PackageName, empty icons, ThirdParty=$true).

    Reads the whole catalogue once rather than one query per package: the list is
    typically most of the catalogue anyway, and a per-package query would defeat
    the prepared-statement cache for no gain.
    #>
    param([string[]]$PackageNames)
    $cache = Get-AppCatalogMap
    return @($PackageNames | ForEach-Object {
        $pkg   = $_
        $entry = $cache[$pkg]
        [PSCustomObject]@{
            PackageName   = $pkg
            DisplayName   = if ($entry -and $entry.DisplayName -and $entry.DisplayName -ne $pkg) { $entry.DisplayName } else { $pkg }
            IconUrl       = if ($entry) { $entry.IconUrl }       else { '' }
            LocalIconPath = if ($entry) { $entry.LocalIconPath } else { '' }
            ThirdParty    = if ($entry) { ConvertTo-ThirdPartyBool $entry } else { $true }
        }
    })
}


function Update-InstalledAppsCache {
    param (
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$Device,
        [string]$headsetName,
        # Permanent headset id, when the caller already has it. The VRMonitor poll
        # runspace MUST pass it: it does not import headsets_manager.ps1, so
        # Resolve-HeadsetIdByName does not exist there and the name lookup threw on
        # every cycle - the monitor never refreshed any installed-apps list.
        [int]$HeadsetId = 0,
        [switch]$ResolveMissing,
        [string]$adb = $global:adbPath
    )

    try {
        # The cache is keyed on the permanent headset id now, not on a filename
        # built from the display name. No id means no row to attach to, so there
        # is nothing useful to do - and silently writing under a wrong id would be
        # worse than skipping.
        $headsetId = if ($HeadsetId -gt 0) { $HeadsetId } else { Resolve-HeadsetIdByName -Name $headsetName }
        if ($headsetId -le 0) {
            Write-Log ("Update-InstalledAppsCache: no headset named '{0}'" -f $headsetName) -Level DEBUG
            return
        }

        # Fetch third-party packages from headset
        $rawOutput = Invoke-AdbCmd -Device $Device -Command "shell pm list packages -3" -adb $adb
        if ($rawOutput -eq $false) { return }
        $packages  = @($rawOutput | ForEach-Object { ($_ -replace '^package:', '').Trim() } | Where-Object { $_ -match '^[a-zA-Z]' } | Sort-Object)

        # Fetch all packages to discover built-in apps
        $allRaw      = Invoke-AdbCmd -Device $Device -Command "shell pm list packages" -adb $adb
        if ($allRaw -eq $false) { return }
        $allPkgs     = @($allRaw | ForEach-Object { ($_ -replace '^package:', '').Trim() } | Where-Object { $_ -match '^[a-zA-Z]' })

        if ($allPkgs.Count -eq 0) { return }
        $thirdSet    = @{}; foreach ($p in $packages) { $thirdSet[$p] = $true }
        $builtInPkgs = @($allPkgs | Where-Object { -not $thirdSet.ContainsKey($_) })

        # Load the current catalogue
        $appNames = Get-AppCatalogMap

        # Persist new/updated entries for both third-party and built-in packages.
        # Only the rows that actually change are written. The CSV era had to
        # rewrite the whole file for a single new package, and with one runspace
        # per headset doing that concurrently the last writer silently won.
        $catalogBatch = @()
        foreach ($group in @(
            @{ Packages = $packages;     ThirdParty = 1 },
            @{ Packages = $builtInPkgs;  ThirdParty = 0 }
        )) {
            foreach ($pkg in $group.Packages) {
                $entry = $appNames[$pkg]
                if ($entry) {
                    # Known package: the only thing worth fixing is a row whose
                    # third_party flag was never set (pre-ThirdParty-column data).
                    if ($null -ne $entry.ThirdParty -and "$($entry.ThirdParty)" -ne '') { continue }
                    $catalogBatch += @{
                        package_name    = $pkg
                        display_name    = [string]$entry.DisplayName
                        icon_url        = [string]$entry.IconUrl
                        local_icon_path = [string]$entry.LocalIconPath
                        third_party     = $group.ThirdParty
                        latest_version  = [string]$entry.LatestVersion
                    }
                } else {
                    $shortName = if ($pkg.StartsWith('com.')) { $pkg.Substring(4) } else { $pkg }
                    $catalogBatch += @{
                        package_name    = $pkg
                        display_name    = $shortName
                        icon_url        = ''
                        local_icon_path = ''
                        third_party     = $group.ThirdParty
                        latest_version  = ''
                    }
                }
            }
        }
        if ($catalogBatch.Count -gt 0) {
            Invoke-DbBatch -Name 'catalog.upsert' -Rows $catalogBatch | Out-Null
            Write-Log ("App catalogue: {0} new/typed packages" -f $catalogBatch.Count) -Level DEBUG
        }

        # When -ResolveMissing: fetch online metadata for packages not yet fully resolved
        if ($ResolveMissing) {
            foreach ($pkg in $packages) {
                $cached = $appNames[$pkg]
                $needsResolve = (-not $cached) -or (-not $cached.DisplayName) -or ($cached.DisplayName -eq $pkg) -or (-not $cached.IconUrl)
                if ($needsResolve) {
                    Get-AppInfo -PackageName $pkg -searchOnline $true | Out-Null
                }
            }
        }

        # Reload the catalogue (Get-AppInfo above may have resolved entries)
        if ($ResolveMissing) {
            $appNames = Get-AppCatalogMap
        }

        # Fetch version names for all installed packages in a single ADB call
        # Format: "Package [com.pkg] (hash):" then "    versionName=x.y.z"
        $versions   = @{}
        $currentPkg = $null
        foreach ($line in (Invoke-AdbCmd -Device $Device -Command "shell dumpsys package packages" -TimeoutSeconds 60 -adb $adb)) {
            if ($line -match '^\s{2}Package \[([^\]]+)\]') {
                $currentPkg = $Matches[1]
            } elseif ($currentPkg -and $line -match '^\s+versionName=(\S+)') {
                $versions[$currentPkg] = $Matches[1]
                $currentPkg = $null
            }
        }

        # Fetch staged update versions (extra ADB call only when staged sessions exist)
        $pendingVersions = @{}
        $stagingLines = Invoke-AdbCmd -Device $Device -Command "shell cmd package list staged-sessions" -adb $adb -SilentOnFail
        if ($stagingLines -ne $false -and @($stagingLines).Count -gt 0) {
            $stgPkgMap = @{}
            foreach ($sLine in $stagingLines) {
                if ($sLine -match 'session (\d+):(\S+)') { $stgPkgMap[$Matches[1]] = $Matches[2] }
                elseif ($sLine -match 'Session\[(\d+)\].*packageName=([^,\s}]+)') { $stgPkgMap[$Matches[1]] = $Matches[2] }
            }
            if ($stgPkgMap.Count -gt 0) {
                $stgDump = Invoke-AdbCmd -Device $Device -Command "shell dumpsys package stagingsessions" -TimeoutSeconds 30 -adb $adb
                if ($stgDump -ne $false) {
                    $curId = $null; $curVer = $null
                    foreach ($sdLine in $stgDump) {
                        if ($sdLine -match '^\s*Session ID:\s*(\d+)') {
                            if ($curId -and $curVer -and $stgPkgMap.ContainsKey($curId)) { $pendingVersions[$stgPkgMap[$curId]] = $curVer }
                            $curId = $Matches[1]; $curVer = $null
                        } elseif ($curId -and $sdLine -match '^\s*versionName\s*=\s*(\S+)') { $curVer = $Matches[1] }
                    }
                    if ($curId -and $curVer -and $stgPkgMap.ContainsKey($curId)) { $pendingVersions[$stgPkgMap[$curId]] = $curVer }
                }
            }
        }

        # Latest store versions for cross-reference, from the catalogue already in
        # hand rather than a third read of the same data.
        $storeVersionMap = @{}
        foreach ($key in $appNames.Keys) {
            $latest = $appNames[$key].LatestVersion
            if ($latest) { $storeVersionMap[$key] = $latest }
        }

        # Fetch per-package storage sizes (single ADB call)
        $storageSizes = Get-HeadsetAppStorageSizes -Device $Device -adb $adb

        # Build new rows (all packages - third-party and built-in; lean schema)
        $allPkgsSorted = @($allPkgs | Sort-Object)
        $newRows = @($allPkgsSorted | ForEach-Object {
            $pkg  = $_
            $ver  = if ($versions.ContainsKey($pkg))        { $versions[$pkg] }        else { '' }
            $pver = if ($pendingVersions.ContainsKey($pkg)) { $pendingVersions[$pkg] } else { '' }
            $sver = if ($storeVersionMap.ContainsKey($pkg) -and $storeVersionMap[$pkg] -and $storeVersionMap[$pkg] -ne $ver) { $storeVersionMap[$pkg] } else { '' }
            $sz   = if ($storageSizes.ContainsKey($pkg))    { $storageSizes[$pkg] }    else { 0 }
            @{
                headset_id      = $headsetId
                package_name    = $pkg
                version         = [string]$ver
                pending_version = [string]$pver
                store_version   = [string]$sver
                size_bytes      = [int64]$sz
            }
        })

        # The whole change-detection block that used to sit here is gone. It
        # existed to avoid rewriting an entire CSV for an unchanged app list, and
        # to force a rewrite when the file's columns were stale. Neither applies:
        # the columns are the table's, and replacing the rows costs one
        # transaction whether or not they differ - cheaper than the comparison
        # read it was avoiding.
        #
        # Clear-then-insert in ONE transaction, so an uninstall is expressed by
        # absence (what rewriting the file gave for free) and no reader ever sees
        # a partially-refreshed app list.
        # Invoke-DbBatch, not a per-row loop: it binds the statement once and
        # reuses it, which is roughly ten times faster over a few hundred apps.
        # Nested inside the transaction below, it joins that transaction rather
        # than opening its own.
        $rowsToSave = $newRows
        Invoke-DbTransaction -Script {
            Invoke-DbNonQuery -Name 'installed.delete_for_headset' -Parameters @{ headset_id = $headsetId } | Out-Null
            Invoke-DbBatch -Name 'installed.insert' -Rows $rowsToSave | Out-Null
        } | Out-Null
        Write-Log ($msg.InstalledAppsCacheUpdated -f $headsetName, $allPkgsSorted.Count) -Level DEBUG
    }
    catch {
        Write-Log ($msg.InstalledAppsCacheFailed -f $headsetName, $_) -Level DEBUG
    }
}


function Get-HeadsetPendingAppUpdates {
    # Returns staged update sessions as @{PackageName;CurrentVersion;PendingVersion;SessionId}.
    # Returns empty array when none found - never throws or returns $false for the no-updates case.
    param (
        [Parameter(Mandatory=$true)] $Device,
        [string]$headsetName,
        [string]$adb = $global:adbPath
    )

    Write-Log ($msg.AppUpdateChecking -f $Device.DeviceId) -Level DEBUG

    # Session ID -> package name
    $sessionLines = Invoke-AdbCmd -Device $Device -Command "shell cmd package list staged-sessions" -adb $adb -SilentOnFail
    if ($sessionLines -eq $false -or @($sessionLines).Count -eq 0) {
        Write-Log ($msg.AppUpdateNoPending -f $Device.DeviceId) -Level DEBUG
        return ,@()
    }
    $sessionPkgMap = @{}
    foreach ($line in $sessionLines) {
        if ($line -match 'session (\d+):(\S+)') {
            $sessionPkgMap[$Matches[1]] = $Matches[2]
        } elseif ($line -match 'Session\[(\d+)\].*packageName=([^,\s}]+)') {
            $sessionPkgMap[$Matches[1]] = $Matches[2]
        }
    }
    if ($sessionPkgMap.Count -eq 0) {
        Write-Log ($msg.AppUpdateNoPending -f $Device.DeviceId) -Level DEBUG
        return ,@()
    }

    # Session ID -> pending versionName from staged sessions dump
    $sessionVersionMap = @{}
    $dumpLines = Invoke-AdbCmd -Device $Device -Command "shell dumpsys package stagingsessions" -TimeoutSeconds 30 -adb $adb
    if ($dumpLines -ne $false) {
        $curId = $null; $curVer = $null
        foreach ($dLine in $dumpLines) {
            if ($dLine -match '^\s*Session ID:\s*(\d+)') {
                if ($curId -and $curVer) { $sessionVersionMap[$curId] = $curVer }
                $curId = $Matches[1]; $curVer = $null
            } elseif ($curId -and $dLine -match '^\s*versionName\s*=\s*(\S+)') {
                $curVer = $Matches[1]
            }
        }
        if ($curId -and $curVer) { $sessionVersionMap[$curId] = $curVer }
    }

    # Current versions from the installed-apps cache (avoids extra ADB round-trip)
    $csvVersionMap = @{}
    if ($headsetName) {
        $headsetId = Resolve-HeadsetIdByName -Name $headsetName
        if ($headsetId -gt 0) {
            try {
                foreach ($row in @(Invoke-DbQuery -Name 'installed.list' -Parameters @{ headset_id = $headsetId })) {
                    if ($row.PackageName) { $csvVersionMap[[string]$row.PackageName] = $row.Version }
                }
            }
            catch {
                Write-Log ("Get-HeadsetPendingAppUpdates: installed-apps read failed - " + $_.Exception.Message) -Level DEBUG
            }
        }
    }

    # Build results
    $results = @()
    foreach ($sessionId in $sessionPkgMap.Keys) {
        $pkg            = $sessionPkgMap[$sessionId]
        $pendingVersion = if ($sessionVersionMap.ContainsKey($sessionId)) { $sessionVersionMap[$sessionId] } else { '' }
        if (-not $pendingVersion) { continue }

        $currentVersion = ''
        if ($csvVersionMap.ContainsKey($pkg)) {
            $currentVersion = $csvVersionMap[$pkg]
        } else {
            $fb = Invoke-AdbCmd -Device $Device -Command "shell dumpsys package $pkg" -adb $adb
            if ($fb -ne $false) {
                $vLine = @($fb) | Where-Object { $_ -match '^\s+versionName=(\S+)' } | Select-Object -First 1
                if ($vLine -match '^\s+versionName=(\S+)') { $currentVersion = $Matches[1] }
            }
        }
        $results += [PSCustomObject]@{
            PackageName    = $pkg
            CurrentVersion = $currentVersion
            PendingVersion = $pendingVersion
            SessionId      = $sessionId
        }
    }

    $count = $results.Count
    if ($count -gt 0) {
        Write-Log ($msg.AppUpdateFound -f $count, $Device.DeviceId) -Level INFO
    } else {
        Write-Log ($msg.AppUpdateNoPending -f $Device.DeviceId) -Level DEBUG
    }
    return ,$results
}


function Start-HeadsetAppUpdate {
    # Commits a staged package update via: cmd package commit-staged-session <sessionId>.
    # Pass -SessionId from Get-HeadsetPendingAppUpdates to skip session discovery.
    # Returns $true on success, $false on failure or no staged session found.
    param (
        [Parameter(Mandatory=$true)] $Device,
        [Parameter(Mandatory=$true)] [string]$PackageName,
        [string]$headsetName,
        [string]$SessionId,
        [string]$adb = $global:adbPath
    )

    if (-not $SessionId) {
        $pending = Get-HeadsetPendingAppUpdates -Device $Device -headsetName $headsetName -adb $adb
        $match   = @($pending) | Where-Object { $_.PackageName -eq $PackageName } | Select-Object -First 1
        if (-not $match) {
            Write-Log ($msg.AppUpdateNotFound -f $PackageName, $Device.DeviceId) -Level WARNING
            return $false
        }
        $SessionId = $match.SessionId
    }

    Write-Log ($msg.AppUpdateStarting -f $PackageName, $Device.DeviceId) -Level INFO
    $out = Invoke-AdbCmd -Device $Device -Command "shell cmd package commit-staged-session $SessionId" -adb $adb
    if ($out -eq $false) {
        Write-Log ($msg.AppUpdateFailed -f $PackageName, $Device.DeviceId) -Level ERROR
        return $false
    }
    $outStr = ($out -join ' ').Trim().ToLower()
    if ($outStr -match 'error|failed|exception' -and $outStr -notmatch 'success') {
        Write-Log ($msg.AppUpdateFailed -f $PackageName, $Device.DeviceId) -Level ERROR
        return $false
    }
    Write-Log ($msg.AppUpdateSuccess -f $PackageName, $Device.DeviceId) -Level SUCCESS
    return $true
}


function Uninstall-HeadsetApp {
    <#
    .SYNOPSIS
    Uninstalls a third-party application from a VR headset via ADB.
    .DESCRIPTION
    Uses Get-HeadsetInstalledApps to verify the package is a third-party app before uninstalling.
    Returns $false with a warning if the app is not found or is a system package.
    #>
    param (
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$Device,
        [Parameter(Mandatory=$true)]
        [string]$PackageName,
        [string]$adb = $global:adbPath
    )
    if (-not $Device) { Write-Log ($msg.AdbWifiConnectFailed -f 'unknown', 'no device') -Level ERROR; return $false }
    $DeviceId = $Device.DeviceId

    try {
        # Check third-party apps only
        $thirdPartyApps = Get-HeadsetInstalledApps -Device $Device -ThirdPartyOnly -adb $adb
        $isThirdParty   = [bool]($thirdPartyApps.PackageName | Where-Object { $_ -eq $PackageName })

        if (-not $isThirdParty) {
            # Distinguish: system app vs not installed at all
            $allApps  = Get-HeadsetInstalledApps -Device $Device -ThirdPartyOnly:$false -adb $adb
            $isSystem = [bool]($allApps.PackageName | Where-Object { $_ -eq $PackageName })

            if ($isSystem) {
                Write-Log ($msg.AppNotThirdParty -f $PackageName, $DeviceId) -Level WARNING
            } else {
                Write-Log ($msg.AppNotFound -f $PackageName, $DeviceId) -Level WARNING
            }
            return $false
        }

        Write-Log ($msg.AppUninstalling -f $PackageName, $DeviceId) -Level INFO
        $output = Invoke-AdbCmd -Device $Device -Command "shell pm uninstall $PackageName" -adb $adb
        if ($output -isnot [bool] -and ($output -match "^Success")) {
            Write-Log ($msg.AppUninstallSuccess -f $PackageName, $DeviceId) -Level SUCCESS
            return $true
        } else {
            Write-Log ($msg.AppUninstallFailed -f $PackageName, $DeviceId, ($output -join ' ')) -Level ERROR
            return $false
        }
    }
    catch {
        Write-Log ($msg.ErrorOccurred -f $_) -Level ERROR
        return $false
    }
}


function Get-HeadsetAppStorageSizes {
    # Returns hashtable {PackageName -> SizeBytes (long)} using a single dumpsys diskstats call.
    # Sizes are APK+data bytes reported by Android; negative or zero values are excluded.
    param (
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$Device,
        [string]$adb = $global:adbPath
    )
    if (-not $Device) { return @{} }
    try {
        $raw = Invoke-AdbCmd -Device $Device -Command "shell dumpsys diskstats" -TimeoutSeconds 30 -adb $adb
        if (-not $raw) { return @{} }
        $text = ($raw -join "`n")
        $pkgMatch  = [regex]::Match($text, 'Package Names: \[(.+?)\]')
        $sizeMatch = [regex]::Match($text, 'App Sizes: \[(.+?)\]')
        if (-not $pkgMatch.Success -or -not $sizeMatch.Success) { return @{} }
        $pkgs  = $pkgMatch.Groups[1].Value  -split ',' | ForEach-Object { $_.Trim().Trim('"') }
        $sizes = $sizeMatch.Groups[1].Value -split ','
        $result = @{}
        for ($i = 0; $i -lt $pkgs.Count -and $i -lt $sizes.Count; $i++) {
            $sz = [long]0
            if ([long]::TryParse($sizes[$i].Trim(), [ref]$sz) -and $sz -gt 0) {
                $result[$pkgs[$i]] = $sz
            }
        }
        Write-Log "Get-HeadsetAppStorageSizes: $($result.Count) packages with size data" -Level DEBUG
        return $result
    }
    catch {
        Write-Log "Get-HeadsetAppStorageSizes failed: $_" -Level WARNING
        return @{}
    }
}
