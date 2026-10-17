# VR Headset Manager - web routes: static (S9-3).
#
# Route handlers for the static file fall-through (conditional GET, streaming, traversal guard).
# Dot-sourced by ..\web_routes.ps1 on both lanes (accept loop and slow-lane worker, ADR-0019);
# functions only. Each handler is reached through $script:RouteTable / $script:RoutePrefixes
# in web_routes.ps1, owns $response.Close() and leaves with `return`, never `continue`.
# The lane of a route is decided in web_routes.ps1 ($script:SlowRoutes / $script:PriorityRoutes),
# not here: moving a handler between files never changes its lane.

function Invoke-RouteStaticFile {
    # Fallback: every request no route claimed is a file under website\ (or a data\ CSV).
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    $staticHeadersSent = $false
    $staticAborted     = $false
    try {
        # Resolve URL path to a file.
        # /data/*.csv  -> served from <ScriptPath>\data\  (read-only CSV export)
        # everything else -> served from <ScriptPath>\website\
        $urlPath = [Uri]::UnescapeDataString($request.Url.LocalPath).TrimStart('/').Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        if ([string]::IsNullOrEmpty($urlPath)) { $urlPath = 'video_monitor.html' }

        if ($urlPath.StartsWith("data" + [System.IO.Path]::DirectorySeparatorChar)) {
            # The data folder is no longer web-readable. It used to serve
            # .csv/.json straight off disk, which is how the monitoring and
            # VQA pages read their state; both now go through an API that
            # returns the same shape from the database. Refusing the whole
            # prefix keeps a stale legacy_* copy from being served too.
            $response.StatusCode = 403
            Close-HttpResponse -Response $response
            return
        } else {
            $resolvedFile    = [System.IO.Path]::GetFullPath((Join-Path $websitePath $urlPath))
            $resolvedBase    = [System.IO.Path]::GetFullPath($websitePath)
            # Prevent path traversal outside websitePath
            if (-not $resolvedFile.StartsWith($resolvedBase)) {
                $response.StatusCode = 403
                Close-HttpResponse -Response $response
                return
            }
            # Transparent fallback: if not found at website root, try website/generated/
            if (-not [System.IO.File]::Exists($resolvedFile)) {
                $generatedBase = [System.IO.Path]::GetFullPath((Join-Path $websitePath "generated"))
                $fallback      = [System.IO.Path]::GetFullPath((Join-Path $generatedBase $urlPath))
                if ($fallback.StartsWith($generatedBase) -and [System.IO.File]::Exists($fallback)) {
                    $resolvedFile = $fallback
                }
            }
        }

        if ([System.IO.File]::Exists($resolvedFile)) {
            $ext      = [System.IO.Path]::GetExtension($resolvedFile).ToLower()
            $mime     = if ($mimeTypes.ContainsKey($ext)) { $mimeTypes[$ext] } else { 'application/octet-stream' }
            $fileInfo = New-Object System.IO.FileInfo($resolvedFile)
            # HTTP dates have no sub-second part: truncate, or every conditional request misses.
            $mtimeRaw = $fileInfo.LastWriteTimeUtc
            # [DateTime]::new, NOT New-Object DateTime(a - b, kind): New-Object parses its
            # arguments in command mode, where the comma binds tighter than the minus, so
            # that form subtracted an array and every static file answered 500 (TEST9).
            $mtime    = [DateTime]::new($mtimeRaw.Ticks - ($mtimeRaw.Ticks % [TimeSpan]::TicksPerSecond), [DateTimeKind]::Utc)
            $lastMod  = $mtime.ToString('R', [System.Globalization.CultureInfo]::InvariantCulture)

            # Cache lifetime: generated pages and HTML always revalidate; bundled
            # assets that practically never change may be reused without asking.
            $generatedRoot = [System.IO.Path]::GetFullPath((Join-Path $websitePath 'generated')) + [System.IO.Path]::DirectorySeparatorChar
            $assetsRoot    = [System.IO.Path]::GetFullPath((Join-Path $websitePath 'assets')) + [System.IO.Path]::DirectorySeparatorChar
            $cacheControl  = 'no-cache'
            if (-not $resolvedFile.StartsWith($generatedRoot, [System.StringComparison]::OrdinalIgnoreCase) -and
                $resolvedFile.StartsWith($assetsRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                $sep = [System.IO.Path]::DirectorySeparatorChar
                if ($resolvedFile.StartsWith($assetsRoot + 'app_icons' + $sep, [System.StringComparison]::OrdinalIgnoreCase) -or
                    $resolvedFile.StartsWith($assetsRoot + 'vendor' + $sep, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $cacheControl = 'public, max-age=86400'
                } elseif ($ext -eq '.js' -or $ext -eq '.css') {
                    $cacheControl = 'public, max-age=300'
                }
            }

            $notModified = $false
            $ims = $request.Headers['If-Modified-Since']
            if ($ims) {
                $imsDate = [DateTime]::MinValue
                if ([DateTime]::TryParseExact($ims.Trim(), 'r', [System.Globalization.CultureInfo]::InvariantCulture,
                        [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$imsDate)) {
                    if ($mtime -le $imsDate) { $notModified = $true }
                }
            }

            if ($notModified) {
                $response.StatusCode = 304
                $response.Headers.Add('Last-Modified', $lastMod)
                $response.Headers.Add('Cache-Control', $cacheControl)
                $staticHeadersSent = $true
            } elseif ($fileInfo.Length -gt 1MB) {
                $response.StatusCode        = 200
                $response.ContentType       = $mime
                $response.ContentLength64   = $fileInfo.Length
                $response.Headers.Add('Last-Modified', $lastMod)
                $response.Headers.Add('Cache-Control', $cacheControl)
                $staticHeadersSent = $true
                $fs = [System.IO.File]::Open($resolvedFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
                try { $fs.CopyTo($response.OutputStream, 81920) } finally { $fs.Dispose() }
            } else {
                $bytes = [System.IO.File]::ReadAllBytes($resolvedFile)
                $response.StatusCode        = 200
                $response.ContentType       = $mime
                $response.ContentLength64   = $bytes.Length
                $response.Headers.Add('Last-Modified', $lastMod)
                $response.Headers.Add('Cache-Control', $cacheControl)
                $staticHeadersSent = $true
                $response.OutputStream.Write($bytes, 0, $bytes.Length)
            }
        } else {
            $response.StatusCode = 404
            $msg404 = [System.Text.Encoding]::UTF8.GetBytes("404 Not Found: $urlPath")
            $response.ContentType     = 'text/plain; charset=utf-8'
            $response.ContentLength64 = $msg404.Length
            $staticHeadersSent = $true
            $response.OutputStream.Write($msg404, 0, $msg404.Length)
        }
    } catch {
        # Once the body write has started the headers are on the wire and setting
        # StatusCode throws (client abort mid-transfer): drop the connection instead.
        $staticLine = "Web server: static file failed (/" + $request.Url.LocalPath.TrimStart('/') + "): " + $_.Exception.Message
        if (Test-HttpClientAbort -Exception $_.Exception) {
            Write-Log $staticLine -Level DEBUG
        } else {
            Write-Log $staticLine -Level WARNING
        }
        if ($staticHeadersSent) {
            $staticAborted = $true
            try { $response.Abort() } catch {}
        } else {
            try { $response.StatusCode = 500 } catch {}
        }
    } finally {
        if (-not $staticAborted) { Close-HttpResponse -Response $response }
    }
}
