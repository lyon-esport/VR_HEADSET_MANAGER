#Requires -Version 5.1
<#
.SYNOPSIS
    HTTP client for the VR HEADSET MANAGER non-regression test harness.

.DESCRIPTION
    Dot-sourced by scripts\Invoke-NonRegressionTests.ps1.

    Deliberately models the web server's ACTUAL response conventions rather
    than its intended ones, because roughly half of web_server.ps1's handlers
    hand-build byte arrays instead of calling Send-JsonResponse:

      - bare JSON arrays with no envelope    /api/headsets, /api/installedapps, /api/logs
      - objects with no 'ok' field           /api/headset-status, /api/appinfo, /api/foregroundapp
      - 'status' instead of 'ok'             /api/resolve-app-names, /api/update-app-versions
      - logical FAILURES returned as HTTP 200 /api/addheadset, /api/connectwifi,
                                              /api/recording low-disk guard
      - meaningful non-2xx codes             400, 403, 404, 409 (lock), 410 (deprecated),
                                              502 (upstream), 503

    Consequently Invoke-VrmApi NEVER throws on a non-2xx status: it returns the
    status code and body so a test can assert on them. Only transport failures
    (server down, timeout) set .Error.

    ASCII only (CLAUDE.md rule 1).
#>

$script:VrmApiBase    = 'http://127.0.0.1:8080'
$script:VrmApiTimeout = 30

function Set-VrmApiBase {
    <#
    .SYNOPSIS
        Points the client at the sandbox web server.
    .EXAMPLE
        Set-VrmApiBase -Port 8080
    #>
    param(
        [Parameter(Mandatory = $true)][int]$Port,
        [string]$HostName = '127.0.0.1'
    )
    $script:VrmApiBase = "http://{0}:{1}" -f $HostName, $Port
    return $script:VrmApiBase
}

function Get-VrmApiBase {
    return $script:VrmApiBase
}

function Invoke-VrmApi {
    <#
    .SYNOPSIS
        Calls one endpoint and returns a structured result. Never throws on an
        HTTP error status - the status is data, not an exception.

    .DESCRIPTION
        Returns a PSCustomObject:
          StatusCode  [int]    HTTP status, or 0 when the request never completed
          Raw         [string] response body as text
          Json        [object] parsed body, or $null when not valid JSON
          Ok          [bool]   $true when StatusCode is 2xx
          JsonOk      [bool]   $true when the body has ok:true (see the caveats
                               in the file header - many endpoints have no 'ok')
          Error       [string] transport error, '' when the request completed
          ContentType [string]
          Elapsed     [TimeSpan]

    .EXAMPLE
        $r = Invoke-VrmApi -Path '/api/headsets'
        Assert-True $r.Ok 'GET /api/headsets should return 2xx'
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [ValidateSet('GET', 'POST', 'OPTIONS')][string]$Method = 'GET',
        $Body = $null,
        [int]$TimeoutSec = 0,
        [hashtable]$Headers = $null
    )

    if ($TimeoutSec -le 0) { $TimeoutSec = $script:VrmApiTimeout }
    $uri = $script:VrmApiBase + $Path

    $result = [PSCustomObject]@{
        Path        = $Path
        Method      = $Method
        StatusCode  = 0
        Raw         = ''
        Json        = $null
        Ok          = $false
        JsonOk      = $false
        Error       = ''
        ContentType = ''
        Elapsed     = [TimeSpan]::Zero
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $params = @{
            Uri             = $uri
            Method          = $Method
            TimeoutSec      = $TimeoutSec
            UseBasicParsing = $true
            ErrorAction     = 'Stop'
        }
        if ($Headers) { $params['Headers'] = $Headers }

        if ($null -ne $Body) {
            if ($Body -is [string]) {
                $params['Body'] = [System.Text.Encoding]::UTF8.GetBytes($Body)
            }
            elseif ($Body -is [byte[]]) {
                $params['Body'] = $Body
            }
            else {
                $params['Body'] = [System.Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 20 -Compress))
            }
            $params['ContentType'] = 'application/json; charset=utf-8'
        }

        $response = Invoke-WebRequest @params
        $result.StatusCode  = [int]$response.StatusCode
        $result.Raw         = $response.Content
        $result.ContentType = [string]$response.Headers['Content-Type']
    }
    catch [System.Net.WebException] {
        # Meaningful non-2xx: read the status and body off the response.
        $webResponse = $_.Exception.Response
        if ($null -ne $webResponse) {
            try {
                $result.StatusCode  = [int]$webResponse.StatusCode
                $result.ContentType = [string]$webResponse.ContentType
                $stream = $webResponse.GetResponseStream()
                $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
                $result.Raw = $reader.ReadToEnd()
                $reader.Close()
            }
            catch {
                $result.Error = $_.Exception.Message
            }
        }
        else {
            $result.Error = $_.Exception.Message
        }
    }
    catch {
        $result.Error = $_.Exception.Message
    }
    finally {
        $sw.Stop()
        $result.Elapsed = $sw.Elapsed
    }

    $result.Ok = ($result.StatusCode -ge 200 -and $result.StatusCode -lt 300)

    if ($result.Raw) {
        try {
            $result.Json = $result.Raw | ConvertFrom-Json
            if ($null -ne $result.Json -and
                ($result.Json.PSObject.Properties.Name -contains 'ok')) {
                $result.JsonOk = [bool]$result.Json.ok
            }
        }
        catch {
            $result.Json = $null
        }
    }

    return $result
}

function Assert-VrmOk {
    <#
    .SYNOPSIS
        Asserts a call returned 2xx AND, when the endpoint uses the ok
        envelope, that ok is true. Attaches the body as evidence on failure.

    .EXAMPLE
        $r = Invoke-VrmApi -Path '/api/recording' -Method POST -Body @{ name='Q3_RED'; value=$true }
        Assert-VrmOk -Result $r -Label 'enable recording'
    #>
    param(
        [Parameter(Mandatory = $true)]$Result,
        [Parameter(Mandatory = $true)][string]$Label,
        [switch]$RequireOkField
    )

    if ($Result.Error) {
        throw ("{0}: {1} {2} failed to connect - {3}" -f $Label, $Result.Method, $Result.Path, $Result.Error)
    }
    if (-not $Result.Ok) {
        Add-TestEvidence ("body: " + (Get-VrmApiExcerpt $Result.Raw))
        throw ("{0}: {1} {2} returned HTTP {3}" -f $Label, $Result.Method, $Result.Path, $Result.StatusCode)
    }

    $hasOkField = ($null -ne $Result.Json -and $Result.Json.PSObject.Properties.Name -contains 'ok')
    if ($hasOkField -and -not $Result.JsonOk) {
        $reason = ''
        if ($Result.Json.PSObject.Properties.Name -contains 'error') { $reason = [string]$Result.Json.error }
        Add-TestEvidence ("body: " + (Get-VrmApiExcerpt $Result.Raw))
        throw ("{0}: {1} {2} returned ok:false - {3}" -f $Label, $Result.Method, $Result.Path, $reason)
    }
    if ($RequireOkField -and -not $hasOkField) {
        throw ("{0}: {1} {2} response has no 'ok' field" -f $Label, $Result.Method, $Result.Path)
    }
}

function Get-VrmApiExcerpt {
    <#
    .SYNOPSIS
        Trims a response body down to something readable in a report.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Raw, [int]$MaxLength = 300)

    if (-not $Raw) { return '(empty)' }
    $flat = ($Raw -replace '\s+', ' ').Trim()
    if ($flat.Length -le $MaxLength) { return $flat }
    return ($flat.Substring(0, $MaxLength) + '...')
}

function Get-VrmPage {
    <#
    .SYNOPSIS
        Fetches a non-API URL (an HTML page or a static asset) and returns
        StatusCode / ContentType / Body / Length / Error.

    .EXAMPLE
        $p = Get-VrmPage -Path '/video_monitor.html'
        Assert-Equal 200 $p.StatusCode 'video_monitor.html status'
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$TimeoutSec = 20
    )

    $result = Invoke-VrmApi -Path $Path -Method GET -TimeoutSec $TimeoutSec
    return [PSCustomObject]@{
        Path        = $Path
        StatusCode  = $result.StatusCode
        ContentType = $result.ContentType
        Body        = $result.Raw
        Length      = $(if ($result.Raw) { $result.Raw.Length } else { 0 })
        Error       = $result.Error
    }
}

function Assert-VrmPageServed {
    <#
    .SYNOPSIS
        Asserts a page returns 200, is non-trivial in size, is the expected
        content type, and does not contain a server-side error trace.

    .EXAMPLE
        Assert-VrmPageServed -Path '/help.html' -MustContain '<html'
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$MustContain = '',
        [string]$ExpectContentType = 'text/html',
        [int]$MinLength = 200
    )

    $page = Get-VrmPage -Path $Path
    if ($page.Error) { throw ("{0}: request failed - {1}" -f $Path, $page.Error) }

    Add-TestEvidence ("{0} -> HTTP {1}, {2} bytes, {3}" -f $Path, $page.StatusCode, $page.Length, $page.ContentType)

    if ($page.StatusCode -ne 200) {
        throw ("{0}: expected HTTP 200, got {1}" -f $Path, $page.StatusCode)
    }
    if ($page.Length -lt $MinLength) {
        throw ("{0}: served only {1} bytes, expected at least {2}" -f $Path, $page.Length, $MinLength)
    }
    if ($ExpectContentType -and $page.ContentType -notlike "*$ExpectContentType*") {
        throw ("{0}: expected content type '{1}', got '{2}'" -f $Path, $ExpectContentType, $page.ContentType)
    }
    if ($MustContain -and $page.Body -notlike "*$MustContain*") {
        throw ("{0}: body does not contain '{1}'" -f $Path, $MustContain)
    }
    foreach ($trace in @('System.Management.Automation', 'Exception calling', 'ParserError')) {
        if ($page.Body -like "*$trace*") {
            throw ("{0}: body contains a server-side error trace ('{1}')" -f $Path, $trace)
        }
    }

    return $page
}

function Wait-VrmApiCondition {
    <#
    .SYNOPSIS
        Polls an endpoint until -Until returns true, or the timeout expires.
        Returns the last result; the caller asserts on it.

    .EXAMPLE
        $r = Wait-VrmApiCondition -Path '/api/foregroundapp?name=Q3_RED' -TimeoutSec 20 -Until {
            param($res) $res.Json.package -eq 'com.oculus.vrshell'
        }
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][scriptblock]$Until,
        [ValidateSet('GET', 'POST')][string]$Method = 'GET',
        $Body = $null,
        [int]$TimeoutSec = 20,
        [int]$PollMs = 1000
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $last = $null
    while ((Get-Date) -lt $deadline) {
        $last = Invoke-VrmApi -Path $Path -Method $Method -Body $Body
        try {
            if (& $Until $last) { return $last }
        }
        catch { }
        Start-Sleep -Milliseconds $PollMs
    }
    return $last
}

function Get-VrmHeadsets {
    <#
    .SYNOPSIS
        GET /api/headsets as an array. Returns @() rather than $null so callers
        can always use .Count (the endpoint returns a bare JSON array).
    #>
    $r = Invoke-VrmApi -Path '/api/headsets'
    if (-not $r.Ok -or $null -eq $r.Json) { return @() }
    return @($r.Json)
}

function ConvertTo-VrmSafeName {
    <#
    .SYNOPSIS
        Mirrors the app's Convert-Displayname: spaces become underscores. Used
        to build generated page names such as 'Q3_RED[monitoring].html'.
    #>
    param([Parameter(Mandatory = $true)][string]$Name)
    return ($Name -replace ' ', '_')
}
