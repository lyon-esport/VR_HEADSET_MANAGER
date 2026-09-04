<#
    Build-AppIcon.ps1

    One-time (re-runnable) dev tool. Draws the VR Headset Manager brand mark
    (same shapes as website\assets\favicon.svg) at 16/32/48/256 px, assembles
    them into sources\graph_assets\VR_HEADSET_MANAGER.ico, then compiles
    sources\graph_assets\LauncherStub.cs into START_VR_HEADSET_MANAGER.exe at
    the project root with that icon embedded (via csc.exe /win32icon).

    Not dot-sourced by scripts_init.ps1. Run manually from the project root:
        powershell -File scripts\Build-AppIcon.ps1
#>

param(
    [int[]]$IconSizes = @(16, 32, 48, 256)
)

$ErrorActionPreference = "Stop"

$projectRoot = Split-Path $PSScriptRoot -Parent
$graphAssetsDir = Join-Path $projectRoot "sources\graph_assets"
$icoPath = Join-Path $graphAssetsDir "VR_HEADSET_MANAGER.ico"
$stubSourcePath = Join-Path $graphAssetsDir "LauncherStub.cs"
$exeOutputPath = Join-Path $projectRoot "START_VR_HEADSET_MANAGER.exe"

if (-not (Test-Path -LiteralPath $graphAssetsDir)) {
    New-Item -ItemType Directory -Path $graphAssetsDir -Force | Out-Null
}
if (-not (Test-Path -LiteralPath $stubSourcePath)) {
    throw "Launcher stub source not found: $stubSourcePath"
}

Add-Type -AssemblyName System.Drawing

function New-RoundedRectPath {
    param([float]$X, [float]$Y, [float]$Width, [float]$Height, [float]$Radius)

    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $Radius * 2
    $path.AddArc($X, $Y, $d, $d, 180, 90)
    $path.AddArc($X + $Width - $d, $Y, $d, $d, 270, 90)
    $path.AddArc($X + $Width - $d, $Y + $Height - $d, $d, $d, 0, 90)
    $path.AddArc($X, $Y + $Height - $d, $d, $d, 90, 90)
    $path.CloseFigure()
    return $path
}

function New-FaviconBitmap {
    param([int]$Size)

    $bmp = New-Object System.Drawing.Bitmap($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)

    $scale = $Size / 64.0
    $darkColor = [System.Drawing.Color]::FromArgb(255, 0x16, 0x16, 0x16)
    $blueColor = [System.Drawing.Color]::FromArgb(255, 0x25, 0x63, 0xeb)

    $darkBrush = New-Object System.Drawing.SolidBrush($darkColor)
    $whiteBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
    $strokeWidth = [Math]::Max(1.0, 5 * $scale)
    $bluePen = New-Object System.Drawing.Pen($blueColor, $strokeWidth)

    # Badge: x=5 y=5 w=54 h=54 rx=11
    $badgePath = New-RoundedRectPath -X (5 * $scale) -Y (5 * $scale) -Width (54 * $scale) -Height (54 * $scale) -Radius (11 * $scale)
    $g.FillPath($darkBrush, $badgePath)
    $g.DrawPath($bluePen, $badgePath)

    # White bar: x=14 y=23 w=36 h=19 rx=9
    $barPath = New-RoundedRectPath -X (14 * $scale) -Y (23 * $scale) -Width (36 * $scale) -Height (19 * $scale) -Radius (9 * $scale)
    $g.FillPath($whiteBrush, $barPath)

    # Dark circle: cx=32 cy=43 r=6
    $r = 6 * $scale
    $cx = 32 * $scale
    $cy = 43 * $scale
    $g.FillEllipse($darkBrush, $cx - $r, $cy - $r, $r * 2, $r * 2)

    $badgePath.Dispose()
    $barPath.Dispose()
    $darkBrush.Dispose()
    $bluePen.Dispose()
    $whiteBrush.Dispose()
    $g.Dispose()

    return $bmp
}

function New-IcoFile {
    param([int[]]$Sizes, [string]$OutputPath)

    $images = @()
    foreach ($s in $Sizes) {
        $bmp = New-FaviconBitmap -Size $s
        $ms = New-Object System.IO.MemoryStream
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $images += [PSCustomObject]@{ Size = $s; Bytes = $ms.ToArray() }
        $ms.Dispose()
        $bmp.Dispose()
    }

    $headerSize = 6
    $entrySize = 16
    $offset = $headerSize + ($entrySize * $images.Count)

    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)

    $bw.Write([UInt16]0)              # reserved
    $bw.Write([UInt16]1)              # type = icon
    $bw.Write([UInt16]$images.Count)  # image count

    foreach ($img in $images) {
        $wByte = if ($img.Size -ge 256) { 0 } else { $img.Size }
        $bw.Write([Byte]$wByte)       # width (0 = 256)
        $bw.Write([Byte]$wByte)       # height (0 = 256)
        $bw.Write([Byte]0)            # color count
        $bw.Write([Byte]0)            # reserved
        $bw.Write([UInt16]1)          # color planes
        $bw.Write([UInt16]32)         # bits per pixel
        $bw.Write([UInt32]$img.Bytes.Length)
        $bw.Write([UInt32]$offset)
        $offset += $img.Bytes.Length
    }

    foreach ($img in $images) {
        $bw.Write($img.Bytes)
    }

    $bw.Flush()
    [System.IO.File]::WriteAllBytes($OutputPath, $ms.ToArray())
    $bw.Dispose()
    $ms.Dispose()
}

Write-Host "Generating icon at sizes: $($IconSizes -join ', ')"
New-IcoFile -Sizes $IconSizes -OutputPath $icoPath
Write-Host "Icon written to: $icoPath"

$cscCandidates = @(
    "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
    "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"
)
$csc = $cscCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $csc) {
    throw "csc.exe (C# compiler) not found. Expected under Microsoft.NET\Framework(64)\v4.0.30319."
}

Write-Host "Compiling launcher stub with: $csc"
$cscArgs = @(
    "/nologo",
    "/target:exe",
    "/win32icon:`"$icoPath`"",
    "/out:`"$exeOutputPath`"",
    "`"$stubSourcePath`""
)
$proc = Start-Process -FilePath $csc -ArgumentList $cscArgs -NoNewWindow -Wait -PassThru
if ($proc.ExitCode -ne 0) {
    throw "csc.exe compilation failed with exit code $($proc.ExitCode)"
}

Write-Host "Launcher built: $exeOutputPath"
