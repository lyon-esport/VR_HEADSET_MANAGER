#Requires -Version 5.1
<#
.SYNOPSIS
    Layer (a) - static checks over the source tree. No database is opened.

.DESCRIPTION
    Dot-sourced by Invoke-DbTests.ps1 inside a section context.

    These checks defend the architectural boundaries the whole migration
    rests on. They are cheap, they need no hardware and no running app, and
    each one catches a mistake that would otherwise surface as a subtle
    runtime bug months later:

      * SQLite types leaking out of database.ps1 means a second connection
        model appears somewhere, which is how a native handle ends up shared
        across runspaces.
      * Raw -Sql outside database.ps1 means SQL text spreading through the
        codebase, defeating the prepared-statement cache and the named-query
        inventory.
      * A named query referenced but missing only fails when that code path
        runs, which may be a rare operator action.

    ASCII only.
#>

$repoRoot = Get-DbTestRepoRoot
$modules  = Join-Path -Path $repoRoot -ChildPath 'modules'
$dbModule = Join-Path -Path $modules  -ChildPath 'database.ps1'

# Every .ps1 that ships or runs, except the data-access module itself and
# these database tests (which legitimately talk about SQLite).
function Get-DbStaticSourceFile {
    $files = New-Object System.Collections.Generic.List[object]
    $files.Add((Get-Item -LiteralPath (Join-Path $repoRoot 'main.ps1'))) | Out-Null
    foreach ($f in (Get-ChildItem -LiteralPath $modules -Filter '*.ps1' -Recurse)) {
        if ($f.FullName -eq $dbModule) { continue }
        $files.Add($f) | Out-Null
    }
    return $files
}

function Get-DbStaticCodeText {
    <#
    .SYNOPSIS
        File text with comments removed, so a doc-comment example is never
        mistaken for a real call site.
    .DESCRIPTION
        The .EXAMPLE blocks in database.ps1 legitimately name queries that a
        later sub-task will add. Scanning raw text counted those as
        references and reported them missing.
    #>
    param([Parameter(Mandatory = $true)][string]$Path)
    $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $text = [regex]::Replace($text, '(?s)<#.*?#>', '')          # block comments
    $text = [regex]::Replace($text, '(?m)^\s*#.*$', '')          # whole-line comments
    return $text
}

Invoke-RegressionTest -Name 'modules\database.ps1 and the SQL tree exist' -Test {
    Assert-FileExists $dbModule 'modules\database.ps1'
    $schemaFolder = Join-Path -Path (Join-Path $modules 'db') -ChildPath 'schema'
    $queryFolder  = Join-Path -Path (Join-Path $modules 'db') -ChildPath 'queries'
    Assert-True (Test-Path -LiteralPath $schemaFolder) 'modules\db\schema exists'
    Assert-True (Test-Path -LiteralPath $queryFolder)  'modules\db\queries exists'
    $schema = @(Get-ChildItem -LiteralPath $schemaFolder -Filter '*.sql')
    $query  = @(Get-ChildItem -LiteralPath $queryFolder  -Filter '*.sql')
    Add-TestEvidence ("{0} schema file(s), {1} named query file(s)" -f $schema.Count, $query.Count)
    Assert-True ($schema.Count -ge 1) 'at least one schema migration'
    Assert-True ($query.Count  -ge 1) 'at least one named query'
}

Invoke-RegressionTest -Name 'SQLite types appear only in modules\database.ps1' -Test {
    # Matches TYPE usage only. The bare string "System.Data.SQLite-1.0.119"
    # is the vendored folder name and legitimately appears in the config
    # loader as a default path, so the pattern requires a type context:
    # a [System.Data.SQLite...] literal, or one of the class names.
    $pattern = '\[System\.Data\.SQLite|System\.Data\.SQLite\.SQLite|SQLiteConnection|SQLiteCommand|SQLiteTransaction|SQLiteParameter|SQLiteDataReader|SQLiteException'
    $offenders = New-Object System.Collections.Generic.List[string]
    foreach ($file in (Get-DbStaticSourceFile)) {
        $hits = @(Select-String -LiteralPath $file.FullName -Pattern $pattern -ErrorAction SilentlyContinue)
        foreach ($hit in $hits) {
            $offenders.Add(("{0}:{1}: {2}" -f $file.FullName.Substring($repoRoot.Length + 1), $hit.LineNumber, $hit.Line.Trim())) | Out-Null
        }
    }
    foreach ($o in $offenders) { Add-TestEvidence $o }
    Assert-True ($offenders.Count -eq 0) `
        'no module outside database.ps1 may reference a SQLite type - route the call through Invoke-Db*'
}

Invoke-RegressionTest -Name 'raw -Sql is used only inside modules\database.ps1' -Test {
    $offenders = New-Object System.Collections.Generic.List[string]
    foreach ($file in (Get-DbStaticSourceFile)) {
        $hits = @(Select-String -LiteralPath $file.FullName -Pattern '-Sql\s' -ErrorAction SilentlyContinue)
        foreach ($hit in $hits) {
            $offenders.Add(("{0}:{1}" -f $file.FullName.Substring($repoRoot.Length + 1), $hit.LineNumber)) | Out-Null
        }
    }
    foreach ($o in $offenders) { Add-TestEvidence $o }
    Assert-True ($offenders.Count -eq 0) `
        'raw SQL belongs in modules\db\queries as a named query, not at a call site'
}

Invoke-RegressionTest -Name 'every referenced named query exists on disk' -Test {
    $queryFolder = Join-Path -Path (Join-Path $modules 'db') -ChildPath 'queries'
    $referenced  = New-Object System.Collections.Generic.List[string]

    $searchFiles = @(Get-DbStaticSourceFile) + @(Get-Item -LiteralPath $dbModule)
    foreach ($file in $searchFiles) {
        $text = Get-DbStaticCodeText -Path $file.FullName
        foreach ($m in [regex]::Matches($text, "-Name\s+'([a-z0-9_]+\.[a-z0-9_]+)'")) {
            $referenced.Add($m.Groups[1].Value) | Out-Null
        }
        foreach ($m in [regex]::Matches($text, '-Name\s+"([a-z0-9_]+\.[a-z0-9_]+)"')) {
            $referenced.Add($m.Groups[1].Value) | Out-Null
        }
    }

    $distinct = @($referenced | Sort-Object -Unique)
    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($name in $distinct) {
        $path = Join-Path -Path $queryFolder -ChildPath ("{0}.sql" -f $name)
        if (-not (Test-Path -LiteralPath $path)) { $missing.Add($name) | Out-Null }
    }
    Add-TestEvidence ("{0} distinct named quer(y/ies) referenced: {1}" -f $distinct.Count, ($distinct -join ', '))
    foreach ($m in $missing) { Add-TestEvidence ("missing: {0}.sql" -f $m) }
    Assert-True ($missing.Count -eq 0) 'every -Name reference resolves to a .sql file'
}

Invoke-RegressionTest -Name 'no named query file is orphaned' -Test {
    $queryFolder = Join-Path -Path (Join-Path $modules 'db') -ChildPath 'queries'
    $onDisk = @(Get-ChildItem -LiteralPath $queryFolder -Filter '*.sql' | ForEach-Object { $_.BaseName })

    $allText = New-Object System.Text.StringBuilder
    foreach ($file in (@(Get-DbStaticSourceFile) + @(Get-Item -LiteralPath $dbModule))) {
        [void]$allText.AppendLine((Get-DbStaticCodeText -Path $file.FullName))
    }
    $haystack = $allText.ToString()

    $orphans = @($onDisk | Where-Object { $haystack -notmatch [regex]::Escape($_) })
    foreach ($o in $orphans) { Add-TestEvidence ("orphan: {0}.sql" -f $o) }
    # An orphan is a warning, not a failure: a query may legitimately land one
    # sub-task before its caller does.
    if ($orphans.Count -gt 0) {
        Write-TestWarning ("{0} named query file(s) are not referenced by any caller yet" -f $orphans.Count)
    }
    Assert-True $true 'orphan scan completed'
}

Invoke-RegressionTest -Name 'schema migrations are numbered contiguously from 001' -Test {
    $schemaFolder = Join-Path -Path (Join-Path $modules 'db') -ChildPath 'schema'
    $files = @(Get-ChildItem -LiteralPath $schemaFolder -Filter '*.sql' | Sort-Object Name)

    $bad = @($files | Where-Object { $_.Name -notmatch '^\d{3}_[a-z0-9_]+\.sql$' })
    foreach ($b in $bad) { Add-TestEvidence ("bad name: {0}" -f $b.Name) }
    Assert-True ($bad.Count -eq 0) 'schema files are named NNN_lower_snake.sql'

    $numbers = @($files | ForEach-Object { [int]($_.Name.Substring(0, 3)) })
    Add-TestEvidence ("versions: {0}" -f ($numbers -join ', '))
    # @() around Sort-Object: with a single migration it returns a scalar,
    # which has no .Count in StrictMode.
    $unique = @($numbers | Sort-Object -Unique)
    Assert-True ($unique.Count -eq $numbers.Count) 'no duplicate migration number'
    for ($i = 0; $i -lt $numbers.Count; $i++) {
        Assert-Equal ($i + 1) $numbers[$i] ("migration number at position {0}" -f $i)
    }
}

Invoke-RegressionTest -Name 'database sources are ASCII only' -Test {
    $targets = New-Object System.Collections.Generic.List[object]
    $targets.Add((Get-Item -LiteralPath $dbModule)) | Out-Null
    foreach ($f in (Get-ChildItem -LiteralPath (Join-Path $modules 'db') -Filter '*.sql' -Recurse)) {
        $targets.Add($f) | Out-Null
    }
    foreach ($f in (Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1')) {
        $targets.Add($f) | Out-Null
    }

    $offenders = New-Object System.Collections.Generic.List[string]
    foreach ($f in $targets) {
        $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
        for ($i = 0; $i -lt $bytes.Length; $i++) {
            if ($bytes[$i] -gt 127) {
                $offenders.Add(("{0} (byte {1} = 0x{2:X2})" -f $f.Name, $i, $bytes[$i])) | Out-Null
                break
            }
        }
    }
    foreach ($o in $offenders) { Add-TestEvidence $o }
    Add-TestEvidence ("{0} file(s) scanned" -f $targets.Count)
    Assert-True ($offenders.Count -eq 0) 'non-ASCII byte found - see CLAUDE.md rule 1 / ADR-0007'
}

Invoke-RegressionTest -Name 'database.ps1 parses without error' -Test {
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($dbModule, [ref]$null, [ref]$errors) | Out-Null
    $count = if ($errors) { $errors.Count } else { 0 }
    foreach ($e in $errors) { Add-TestEvidence $e.Message }
    Assert-Equal 0 $count 'parse errors in modules\database.ps1'
}

Invoke-RegressionTest -Name 'sources\sqlite is present and listed in .releaseinclude' -Test {
    $asm = Join-Path -Path $repoRoot -ChildPath (Join-Path 'sources' (Join-Path 'sqlite' (Join-Path 'System.Data.SQLite-1.0.119' 'System.Data.SQLite.dll')))
    $int = Join-Path -Path $repoRoot -ChildPath (Join-Path 'sources' (Join-Path 'sqlite' (Join-Path 'System.Data.SQLite-1.0.119' (Join-Path 'x64' 'SQLite.Interop.dll'))))
    Assert-FileExists $asm 'System.Data.SQLite.dll'
    Assert-FileExists $int 'x64\SQLite.Interop.dll'

    $manifest = Join-Path -Path (Join-Path $repoRoot 'scripts') -ChildPath '.releaseinclude'
    $lines = @(Get-Content -LiteralPath $manifest -Encoding UTF8)
    $hit = @($lines | Where-Object { $_.Trim() -eq '/sources/sqlite/System.Data.SQLite-1.0.119/' })
    Add-TestEvidence ("manifest lines matching the sqlite folder: {0}" -f $hit.Count)
    Assert-True ($hit.Count -eq 1) 'the sqlite folder must be listed in scripts\.releaseinclude or it will not ship'
}

Invoke-RegressionTest -Name 'the database config block exists in the shipped template' -Test {
    $template = Join-Path -Path $repoRoot -ChildPath (Join-Path 'templates' (Join-Path 'config' 'config.json'))
    $json = (Get-Content -LiteralPath $template -Raw -Encoding UTF8 | ConvertFrom-Json)
    Assert-NotNull $json.database 'templates\config\config.json database block'
    foreach ($key in @('folder', 'file', 'busy_timeout_ms', 'retry_max', 'integrity_check', 'backup')) {
        Assert-True ($json.database.PSObject.Properties.Name -contains $key) ("database.{0} present in the template" -f $key)
    }
    Add-TestEvidence ("template database.folder = {0}" -f $json.database.folder)
}
