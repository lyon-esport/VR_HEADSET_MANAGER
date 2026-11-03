# release_include.ps1 - release include/exclude matcher (pure, no logging, no state).
# Shared by scripts\Create-ZipRelease.ps1 (dot-sourced standalone) and the update code, so a
# release zip and a dev-mode update select files with the SAME rules. Functions only.

function ConvertTo-ReleasePatternRegex {
    <#
    .SYNOPSIS
        One .releaseinclude pattern to a regex over a backslash-separated relative path.
    .EXAMPLE
        ConvertTo-ReleasePatternRegex -Pattern '/modules/'
    #>
    param([string]$Pattern)
    $p = $Pattern.Replace('/', '\')
    if ($p.StartsWith('\')) { $p = $p.Substring(1) }
    # Folder pattern: ends with \ or \* => everything under that prefix
    if ($p.EndsWith('\') -or $p.EndsWith('\*')) {
        $prefix = $p.TrimEnd('*').TrimEnd('\')
        return '^' + [regex]::Escape($prefix) + '(\\.+|$)'
    }
    # File pattern: * and ? do not cross a path separator
    $escaped = [regex]::Escape($p)
    $regexStr = $escaped.Replace('\*', '[^\\]*').Replace('\?', '[^\\]')
    return '^' + $regexStr + '$'
}

function Read-ReleaseIncludeRules {
    <#
    .SYNOPSIS
        Parses the text of scripts\.releaseinclude into compiled rule lists.
    .DESCRIPTION
        Lines without ! include, lines with ! exclude (exclusions win). '#' comments and blank lines ignored.
    .EXAMPLE
        $rules = Read-ReleaseIncludeRules -Text (Get-Content -LiteralPath $p -Raw -Encoding UTF8)
    #>
    param([string]$Text)
    $inc = [System.Collections.Generic.List[string]]::new()
    $exc = [System.Collections.Generic.List[string]]::new()
    foreach ($rawLine in ([string]$Text -split "\r?\n")) {
        $line = $rawLine.Trim()
        if ($line -eq '' -or $line.StartsWith('#')) { continue }
        if ($line.StartsWith('!')) {
            $exc.Add((ConvertTo-ReleasePatternRegex -Pattern $line.Substring(1))) | Out-Null
        } else {
            $inc.Add((ConvertTo-ReleasePatternRegex -Pattern $line)) | Out-Null
        }
    }
    return @{ Include = @($inc); Exclude = @($exc) }
}

function Test-ReleaseIncludePath {
    <#
    .SYNOPSIS
        True when a project-relative path belongs in a release (or a dev-mode update).
    .DESCRIPTION
        Hard refusals first (scripts\, root dot-folders/files, sources\ffmpeg*), then the include
        patterns, then the exclusions (highest priority). Accepts / or \ separators.
    .EXAMPLE
        Test-ReleaseIncludePath -Path 'modules/utils.ps1' -Rules $rules
    #>
    param(
        [string]$Path,
        [hashtable]$Rules
    )
    $rel = ([string]$Path).Replace('/', '\').TrimStart('\')
    if ($rel -eq '') { return $false }

    if ($rel.StartsWith('scripts\') -or $rel -eq 'scripts') { return $false }
    $topSegment = ($rel -split '\\')[0]
    if ($topSegment.StartsWith('.')) { return $false }
    # ffmpeg is never shipped, whatever .releaseinclude says
    if ($rel -match '^sources\\ffmpeg') { return $false }

    $included = $false
    foreach ($rx in $Rules.Include) {
        if ($rel -match $rx) { $included = $true; break }
    }
    if (-not $included) { return $false }
    foreach ($rx in $Rules.Exclude) {
        if ($rel -match $rx) { return $false }
    }
    return $true
}
