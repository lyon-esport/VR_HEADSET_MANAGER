# VR Headset Manager - console rendering kit (ASCII only).
#
# Small drawing helpers shared by the console screens (console_manager.ps1): the framed
# banner, coloured one-line segments, the tile grid of the main screen, the common sub-menu
# layout and a single-key reader. Every character drawn is plain ASCII (CLAUDE.md rule 1),
# so the screens look the same in any console, font and code page.
#
# Auto-loaded by scripts_init.ps1's module glob. Functions only - nothing runs at dot-source.

function Get-UiWidth {
    <#
    .SYNOPSIS
    Usable console width: the window width minus one column (writing the last column makes
    the console wrap on its own), 80 when the width cannot be read.
    .EXAMPLE
    $w = Get-UiWidth
    #>
    $w = 0
    try { $w = [int]$Host.UI.RawUI.WindowSize.Width } catch { $w = 0 }
    if ($w -lt 40) { $w = 81 }
    return ($w - 1)
}

function Format-UiCell {
    <#
    .SYNOPSIS
    Pads or cuts a value to exactly -Width characters ('-' for $null/blank when -Dash).
    .EXAMPLE
    Format-UiCell -Text 'Q3 RED' -Width 12
    #>
    param([AllowNull()] $Text, [int]$Width, [switch]$Dash, [switch]$Right)
    $s = if ($null -eq $Text) { '' } else { [string]$Text }
    if ($Dash -and -not $s.Trim()) { $s = '-' }
    if ($Width -le 0) { return '' }
    if ($s.Length -gt $Width) { return $s.Substring(0, $Width) }
    if ($Right) { return $s.PadLeft($Width) }
    return $s.PadRight($Width)
}

function New-UiSegment {
    <#
    .SYNOPSIS
    One coloured piece of a line: @{ Text; Fg; Bg; Link }. $null colours keep the console
    default. -Link (a URL) makes the text clickable where the terminal supports hyperlinks
    (see Test-UiHyperlinkSupport); elsewhere it is plain text.
    .EXAMPLE
    New-UiSegment -Text 'http://10.0.0.5:8080' -Fg Cyan -Link 'http://10.0.0.5:8080'
    #>
    param([AllowNull()] [string]$Text = '', [AllowNull()] $Fg = $null, [AllowNull()] $Bg = $null, [string]$Link = '')
    return @{ Text = [string]$Text; Fg = $Fg; Bg = $Bg; Link = $Link }
}

function Test-UiHyperlinkSupport {
    <#
    .SYNOPSIS
    $true when the console understands OSC 8 hyperlinks: Windows Terminal ($env:WT_SESSION)
    or the VS Code terminal. The legacy console window (conhost) does not, and would print
    the escape sequence as garbage, so links are only emitted there. Memoised per process.
    .EXAMPLE
    if (Test-UiHyperlinkSupport) { 'links on' }
    #>
    if ($null -eq $script:UiHyperlinks) {
        $script:UiHyperlinks = [bool]($env:WT_SESSION -or $env:TERM_PROGRAM -eq 'vscode')
    }
    return $script:UiHyperlinks
}

function Write-UiSegments {
    <#
    .SYNOPSIS
    Writes one line made of coloured segments, cut at -Width. -Pad fills the rest of the line
    with spaces (in -PadBg), which is what lets a redraw in place erase the previous content.
    .EXAMPLE
    Write-UiSegments -Segments @((New-UiSegment 'OK ' Green), (New-UiSegment 'ready')) -Pad
    #>
    param(
        [array]$Segments = @(),
        [int]$Width = 0,
        [switch]$Pad,
        [AllowNull()] $PadBg = $null,
        [switch]$NoNewline
    )
    if ($Width -le 0) { $Width = Get-UiWidth }
    $used = 0
    foreach ($seg in $Segments) {
        if ($null -eq $seg) { continue }
        $text = [string]$seg.Text
        if (-not $text) { continue }
        $room = $Width - $used
        if ($room -le 0) { break }
        if ($text.Length -gt $room) { $text = $text.Substring(0, $room) }
        $p = @{ Object = $text; NoNewline = $true }
        if ($seg.Fg) { $p.ForegroundColor = $seg.Fg }
        if ($seg.Bg) { $p.BackgroundColor = $seg.Bg }
        # OSC 8 hyperlink: ESC ] 8 ; ; URL ESC \ text ESC ] 8 ; ; ESC \  (takes no columns).
        $link = if ($seg.Link -and (Test-UiHyperlinkSupport)) { [string]$seg.Link } else { '' }
        $esc = [char]27
        if ($link) { Write-Host ($esc + ']8;;' + $link + $esc + '\') -NoNewline }
        Write-Host @p
        if ($link) { Write-Host ($esc + ']8;;' + $esc + '\') -NoNewline }
        $used += $text.Length
    }
    if ($Pad -and $used -lt $Width) {
        $p = @{ Object = (' ' * ($Width - $used)); NoNewline = $true }
        if ($PadBg) { $p.BackgroundColor = $PadBg }
        Write-Host @p
    }
    if (-not $NoNewline) { Write-Host '' }
}

function Write-UiBanner {
    <#
    .SYNOPSIS
    A framed block: +====+ top and bottom, each row "| <segments> |" on a solid background.
    -Rows is an array of segment arrays (one per line). Returns the number of lines written.
    .EXAMPLE
    Write-UiBanner -Rows @(,@((New-UiSegment 'TITLE' White))) -Bg DarkBlue
    #>
    param(
        [array]$Rows = @(),
        [AllowNull()] $Fg = 'White',
        [AllowNull()] $Bg = 'DarkBlue',
        [int]$Width = 0
    )
    if ($Width -le 0) { $Width = Get-UiWidth }
    $inner = $Width - 4
    $edge  = '+' + ('=' * ($Width - 2)) + '+'
    Write-UiSegments -Segments @(New-UiSegment $edge $Fg $Bg) -Width $Width
    $count = 1
    foreach ($row in $Rows) {
        $segs = @(New-UiSegment '| ' $Fg $Bg)
        $len = 0
        foreach ($s in @($row)) {
            if ($null -eq $s) { continue }
            $t = [string]$s.Text
            if ($len + $t.Length -gt $inner) { $t = $t.Substring(0, [Math]::Max(0, $inner - $len)) }
            if (-not $t) { continue }
            $segs += New-UiSegment $t $(if ($s.Fg) { $s.Fg } else { $Fg }) $Bg ([string]$s.Link)
            $len += $t.Length
        }
        if ($len -lt $inner) { $segs += New-UiSegment (' ' * ($inner - $len)) $Fg $Bg }
        $segs += New-UiSegment ' |' $Fg $Bg
        Write-UiSegments -Segments $segs -Width $Width
        $count++
    }
    Write-UiSegments -Segments @(New-UiSegment $edge $Fg $Bg) -Width $Width
    return ($count + 1)
}

function Write-UiTiles {
    <#
    .SYNOPSIS
    The boxed tile grid: one box per group (+- TITLE ---+), items "K  Label  badge" inside.
    Groups wrap to the next row when the console is too narrow. -Groups is an array of
    @{ Title; Color; Items = @(@{ Key; Label; Badge }) }. Returns the number of lines written.
    .EXAMPLE
    Write-UiTiles -Groups @(@{ Title = 'SYSTEM'; Color = 'Gray'; Items = @(@{ Key = 'C'; Label = 'Config' }) })
    #>
    param(
        [array]$Groups = @(),
        [int]$Width = 0,
        [int]$MaxTileWidth = 26,
        [int]$MinTileWidth = 18
    )
    if ($Width -le 0) { $Width = Get-UiWidth }
    $groups = @($Groups | Where-Object { $_ -and @($_.Items).Count -gt 0 })
    if ($groups.Count -eq 0) { return 0 }

    # Widest tile that fits every group on one row, else as many as fit at the minimum width.
    $perRow = $groups.Count
    $tileW  = [Math]::Floor(($Width - 1) / $perRow) - 1
    while ($tileW -lt $MinTileWidth -and $perRow -gt 1) {
        $perRow--
        $tileW = [Math]::Floor(($Width - 1) / $perRow) - 1
    }
    $tileW = [int][Math]::Max(10, [Math]::Min($MaxTileWidth, $tileW))
    $inner = $tileW - 2
    $lines = 0

    for ($start = 0; $start -lt $groups.Count; $start += $perRow) {
        $rowGroups = @($groups[$start..([Math]::Min($groups.Count, $start + $perRow) - 1)])
        $height = ($rowGroups | ForEach-Object { @($_.Items).Count } | Measure-Object -Maximum).Maximum

        # Top edge with the title.
        $segs = @(New-UiSegment ' ')
        foreach ($g in $rowGroups) {
            $title = '+- ' + [string]$g.Title + ' '
            if ($title.Length -gt $tileW - 1) { $title = $title.Substring(0, $tileW - 1) }
            $segs += New-UiSegment ($title + ('-' * ($tileW - 1 - $title.Length)) + '+') $g.Color
            $segs += New-UiSegment ' '
        }
        Write-UiSegments -Segments $segs -Width $Width; $lines++

        for ($r = 0; $r -lt $height; $r++) {
            $segs = @(New-UiSegment ' ')
            foreach ($g in $rowGroups) {
                $items = @($g.Items)
                $segs += New-UiSegment '|' $g.Color
                if ($r -lt $items.Count) {
                    $it    = $items[$r]
                    $key   = Format-UiCell -Text ([string]$it.Key) -Width 3
                    $badge = if ($it.Badge) { ' ' + [string]$it.Badge } else { '' }
                    $label = Format-UiCell -Text ([string]$it.Label) -Width ([Math]::Max(0, $inner - 1 - 3 - $badge.Length))
                    $segs += New-UiSegment ' ' $null
                    $segs += New-UiSegment $key 'Yellow'
                    $segs += New-UiSegment $label 'White'
                    if ($badge) { $segs += New-UiSegment $badge 'Cyan' }
                } else {
                    $segs += New-UiSegment (' ' * $inner)
                }
                $segs += New-UiSegment '|' $g.Color
                $segs += New-UiSegment ' '
            }
            Write-UiSegments -Segments $segs -Width $Width; $lines++
        }

        $segs = @(New-UiSegment ' ')
        foreach ($g in $rowGroups) {
            $segs += New-UiSegment ('+' + ('-' * ($tileW - 2)) + '+') $g.Color
            $segs += New-UiSegment ' '
        }
        Write-UiSegments -Segments $segs -Width $Width; $lines++
    }
    return $lines
}

function Write-UiTitle {
    <#
    .SYNOPSIS
    The title bar of a sub-screen: a framed banner with the title, and an optional second
    line (breadcrumb or context) in a dimmer colour.
    .EXAMPLE
    Write-UiTitle -Title 'SERVICES' -Subtitle 'VRHM > Services'
    #>
    param([string]$Title, [string]$Subtitle = '', [AllowNull()] $Bg = 'DarkCyan')
    $rows = @(, @(New-UiSegment $Title 'White'))
    if ($Subtitle) { $rows += , @(New-UiSegment $Subtitle 'Gray') }
    [void](Write-UiBanner -Rows $rows -Fg 'White' -Bg $Bg)
}

function Write-UiMenu {
    <#
    .SYNOPSIS
    The common sub-menu layout: title bar, then one row per item "  K  Label   value", then
    a footer. -Items: @(@{ Key; Label; Value; ValueColor; Color; Separator }) - a Separator
    item prints a blank line or a section caption. Keys are drawn in yellow.
    .EXAMPLE
    Write-UiMenu -Title 'SERVICES' -Items @(@{ Key = '1'; Label = 'Restart the web server' })
    #>
    param(
        [string]$Title,
        [string]$Subtitle = '',
        [array]$Items = @(),
        [string]$Footer = '',
        [AllowNull()] $Bg = 'DarkCyan',
        [switch]$NoClear
    )
    if (-not $NoClear) { Clear-Host }
    Write-UiTitle -Title $Title -Subtitle $Subtitle -Bg $Bg
    Write-Host ''
    $labelW = 4
    foreach ($it in $Items) { if ($it -and -not $it.Separator -and $it.Label -and ([string]$it.Label).Length -gt $labelW) { $labelW = ([string]$it.Label).Length } }
    $labelW = [Math]::Min($labelW, 46)
    foreach ($it in $Items) {
        if (-not $it) { continue }
        if ($it.Separator) {
            if ($it.Label) { Write-Host ('  ' + [string]$it.Label) -ForegroundColor DarkGray } else { Write-Host '' }
            continue
        }
        $segs = @(
            (New-UiSegment '   '),
            (New-UiSegment (Format-UiCell -Text ([string]$it.Key) -Width 4) 'Yellow'),
            (New-UiSegment (Format-UiCell -Text ([string]$it.Label) -Width $labelW) $(if ($it.Color) { $it.Color } else { 'White' }))
        )
        if ($null -ne $it.Value -and [string]$it.Value -ne '') {
            $segs += New-UiSegment '  '
            $segs += New-UiSegment ([string]$it.Value) $(if ($it.ValueColor) { $it.ValueColor } else { 'Cyan' })
        }
        Write-UiSegments -Segments $segs
    }
    Write-Host ''
    if ($Footer) { Write-Host ('  ' + $Footer) -ForegroundColor DarkGray }
}

function Write-UiMessage {
    <#
    .SYNOPSIS
    One status line with a coloured tag: ok [OK] green, warn [!!] yellow, err [XX] red,
    info [..] cyan.
    .EXAMPLE
    Write-UiMessage -Text 'Saved.' -Kind ok
    #>
    param([string]$Text, [ValidateSet('ok', 'warn', 'err', 'info')] [string]$Kind = 'info')
    $tag, $color = switch ($Kind) {
        'ok'   { '[OK]', 'Green' }
        'warn' { '[!!]', 'Yellow' }
        'err'  { '[XX]', 'Red' }
        default { '[..]', 'Cyan' }
    }
    Write-Host ('  ' + $tag + ' ') -ForegroundColor $color -NoNewline
    Write-Host $Text
}

function Read-UiKey {
    <#
    .SYNOPSIS
    Waits for ONE key and returns it as a normalised string: '0'..'9', 'A'..'Z', '?', 'ESC',
    'ENTER', 'BACKSPACE', 'F1'..'F12', or the character itself. While waiting it runs -OnIdle
    about once a second and -OnTick every -TickSec seconds (0 = never), e.g. to redraw a status
    card in place. Falls back to the first character of a Read-Host line when the input is
    redirected.
    .EXAMPLE
    $k = Read-UiKey -OnIdle { Invoke-VRMonitorSupervision }
    #>
    param(
        [scriptblock]$OnIdle = $null,
        [scriptblock]$OnTick = $null,
        [int]$TickSec = 0
    )
    $canPoll = $true
    try { $null = [Console]::KeyAvailable } catch { $canPoll = $false }
    if (-not $canPoll) {
        $line = [string](Read-Host)
        if (-not $line) { return 'ENTER' }
        return $line.Trim().Substring(0, 1).ToUpperInvariant()
    }
    $nextIdle = Get-Date
    $nextTick = if ($TickSec -gt 0 -and $OnTick) { (Get-Date).AddSeconds($TickSec) } else { [datetime]::MaxValue }
    while (-not [Console]::KeyAvailable) {
        $now = Get-Date
        if ($OnIdle -and $now -ge $nextIdle) {
            try { & $OnIdle } catch { }
            $nextIdle = $now.AddMilliseconds(1000)
        }
        if ($now -ge $nextTick) {
            try { & $OnTick } catch { }
            $nextTick = (Get-Date).AddSeconds($TickSec)
        }
        Start-Sleep -Milliseconds 100
    }
    $k = [Console]::ReadKey($true)
    if ($k.Key -ge [ConsoleKey]::F1 -and $k.Key -le [ConsoleKey]::F12) {
        return ('F' + ([int]$k.Key - [int][ConsoleKey]::F1 + 1))
    }
    if ($k.Key -eq [ConsoleKey]::Escape) { return 'ESC' }
    if ($k.Key -eq [ConsoleKey]::Enter -or [int]$k.KeyChar -eq 13) { return 'ENTER' }
    if ($k.Key -eq [ConsoleKey]::Backspace) { return 'BACKSPACE' }
    if ([int]$k.KeyChar -ge 32) { return ([string]$k.KeyChar).ToUpperInvariant() }
    return ''
}

function Wait-UiKey {
    <#
    .SYNOPSIS
    "Press any key to continue" - prints the prompt and waits for one key.
    .EXAMPLE
    Wait-UiKey
    #>
    param([string]$Prompt = '')
    if (-not $Prompt) { $Prompt = if ($msg -and $msg.Console) { $msg.Console.PressAnyKey } else { 'Press any key to continue...' } }
    Write-Host ''
    Write-Host ('  ' + $Prompt) -ForegroundColor DarkGray -NoNewline
    [void](Read-UiKey)
    Write-Host ''
}
