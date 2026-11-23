# Generates the static PNG icons of the VRHM Stream Deck plugin (action list icons, default
# key images, category and plugin icons). Run once after changing a glyph; the PNGs are
# committed. Key images shown at run time are SVG drawn by the plugin itself (src\render.ts).
# Usage: powershell -NoProfile -File StreamDeck\tools\New-VrhmPluginIcons.ps1

param(
    [string]$PluginDir = (Join-Path (Split-Path -Parent $PSScriptRoot) 'vrhm-plugin\com.lyonesport.vrhm.sdPlugin')
)

Add-Type -AssemblyName System.Drawing

function New-Icon {
    param([string]$Path, [int]$Size, [string]$Text, [string]$Bg, [switch]$Transparent)
    $bmp = New-Object System.Drawing.Bitmap $Size, $Size
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.TextRenderingHint = 'AntiAliasGridFit'
    $g.Clear([System.Drawing.Color]::Transparent)
    if (-not $Transparent) {
        $r = [int]($Size * 0.18)
        $gp = New-Object System.Drawing.Drawing2D.GraphicsPath
        $gp.AddArc(0, 0, 2 * $r, 2 * $r, 180, 90)
        $gp.AddArc($Size - 2 * $r - 1, 0, 2 * $r, 2 * $r, 270, 90)
        $gp.AddArc($Size - 2 * $r - 1, $Size - 2 * $r - 1, 2 * $r, 2 * $r, 0, 90)
        $gp.AddArc(0, $Size - 2 * $r - 1, 2 * $r, 2 * $r, 90, 90)
        $gp.CloseFigure()
        $brush = New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml($Bg))
        $g.FillPath($brush, $gp)
    }
    $fontSize = [single]($Size * (0.62 / [Math]::Max(1, [Math]::Sqrt($Text.Length))))
    $font = New-Object System.Drawing.Font 'Segoe UI', $fontSize, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
    $fmt = New-Object System.Drawing.StringFormat
    $fmt.Alignment = 'Center'; $fmt.LineAlignment = 'Center'
    $g.DrawString($Text, $font, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF 0, 0, $Size, $Size), $fmt)
    $dir = Split-Path -Parent $Path
    if (-not [System.IO.Directory]::Exists($dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
    $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
}

$imgs = Join-Path $PluginDir 'imgs'
$actions = @(
    @{ Name = 'headset'; Text = 'VR'; Bg = '#21804a' },
    @{ Name = 'command'; Text = '>';  Bg = '#1f5fa8' },
    @{ Name = 'timer';   Text = 'T';  Bg = '#b7791f' },
    @{ Name = 'app';     Text = 'A';  Bg = '#5a3fa8' },
    @{ Name = 'kiosk';   Text = 'K';  Bg = '#3a3f47' },
    @{ Name = 'view';    Text = 'V';  Bg = '#1f5fa8' },
    @{ Name = 'setting'; Text = 'S';  Bg = '#3a3f47' }
)
foreach ($a in $actions) {
    $d = Join-Path $imgs ('actions\' + $a.Name)
    New-Icon -Path (Join-Path $d 'icon.png')    -Size 20  -Text $a.Text -Bg $a.Bg -Transparent
    New-Icon -Path (Join-Path $d 'icon@2x.png') -Size 40  -Text $a.Text -Bg $a.Bg -Transparent
    New-Icon -Path (Join-Path $d 'key.png')     -Size 72  -Text $a.Text -Bg $a.Bg
    New-Icon -Path (Join-Path $d 'key@2x.png')  -Size 144 -Text $a.Text -Bg $a.Bg
}
New-Icon -Path (Join-Path $imgs 'plugin\category-icon.png')    -Size 28  -Text 'VR' -Bg '#003366' -Transparent
New-Icon -Path (Join-Path $imgs 'plugin\category-icon@2x.png') -Size 56  -Text 'VR' -Bg '#003366' -Transparent
New-Icon -Path (Join-Path $imgs 'plugin\marketplace.png')      -Size 288 -Text 'VRHM' -Bg '#003366'
New-Icon -Path (Join-Path $imgs 'plugin\marketplace@2x.png')   -Size 576 -Text 'VRHM' -Bg '#003366'
Write-Host "Icons written under $imgs"
