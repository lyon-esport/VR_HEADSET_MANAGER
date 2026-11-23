# Generates the template profiles bundled with the VRHM Stream Deck plugin, for a 15-key
# Stream Deck (5 columns x 3 rows, DeviceType 0, e.g. MK.2):
#   vrhm-main    : one column per headset - row 1 status, row 2 recording, row 3 timer
#   vrhm-headset : config page of the selected headset
#   vrhm-apps    : favourite apps of the selected headset (14 slots + back)
#   vrhm-kiosks  : kiosk screens (14 slots + back)
#   vrhm-views   : capture profile of the selected headset (eyes + views)
#   vrhm-settings: settings of the selected headset (guardian, double tap, keep awake...)
# Format = the zipped "<UUID>.sdProfile/manifest.json" layout Stream Deck imports from a
# plugin (same as Elgato's own tutorial plugin). Keys are "column,row".
# Usage: powershell -NoProfile -File StreamDeck\tools\New-VrhmProfiles.ps1

param(
    [string]$PluginDir = (Join-Path (Split-Path -Parent $PSScriptRoot) 'vrhm-plugin\com.lyonesport.vrhm.sdPlugin'),
    [string]$DeviceModel = '20GBA9901'
)

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$P = 'com.lyonesport.vrhm'

function New-Key {
    param([string]$Uuid, [string]$Name, [hashtable]$Settings)
    [ordered]@{
        Name     = $Name
        Settings = $Settings
        State    = 0
        States   = @([ordered]@{ FFamily = ''; FSize = ''; FStyle = ''; FUnderline = ''; Image = ''; Title = ''; TitleAlignment = ''; TitleColor = ''; TitleShow = '' })
        UUID     = $Uuid
    }
}
function Cmd([string]$Command, [string]$Target = 'selected') {
    New-Key -Uuid "$P.command" -Name 'Headset command' -Settings @{ command = $Command; target = $Target }
}

function Save-Profile {
    param([string]$FileName, [string]$Name, [hashtable]$Keys, [string]$ProfileUuid)
    $manifest = [ordered]@{
        Actions               = $Keys
        DeviceModel           = $DeviceModel
        InstalledByPluginUUID = $P
        Name                  = $Name
        PreconfiguredName     = $Name
        Version               = '1.0'
    }
    $json = $manifest | ConvertTo-Json -Depth 10 -Compress
    $dir = Join-Path $PluginDir 'profiles'
    if (-not [System.IO.Directory]::Exists($dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
    $out = Join-Path $dir ($FileName + '.streamDeckProfile')
    if ([System.IO.File]::Exists($out)) { [System.IO.File]::Delete($out) }
    $zip = [System.IO.Compression.ZipFile]::Open($out, 'Create')
    try {
        $entry = $zip.CreateEntry("$ProfileUuid.sdProfile/manifest.json")
        $w = New-Object System.IO.StreamWriter($entry.Open(), (New-Object System.Text.UTF8Encoding($false)))
        $w.Write($json); $w.Dispose()
    } finally { $zip.Dispose() }
    Write-Host "Wrote $out"
}

# --- main page: one column per headset ----------------------------------------------------
$main = @{}
for ($c = 0; $c -lt 5; $c++) {
    $slot = "slot:$($c + 1)"
    $main["$c,0"] = New-Key -Uuid "$P.headset" -Name 'Headset status' -Settings @{ target = $slot; onPress = 'config' }
    $main["$c,1"] = New-Key -Uuid "$P.command" -Name 'Headset command' -Settings @{ command = 'record'; target = $slot }
    $main["$c,2"] = New-Key -Uuid "$P.timer"   -Name 'Headset timer'   -Settings @{ target = $slot }
}
Save-Profile -FileName 'vrhm-main' -Name 'VRHM Main' -Keys $main -ProfileUuid '6F1C2A10-7D3B-4C55-9A61-0E2B5F7A1001'

# --- headset page --------------------------------------------------------------------------
$hs = @{
    '0,0' = Cmd 'home'
    '1,0' = Cmd 'info'
    '2,0' = Cmd 'resetui'
    '3,0' = Cmd 'apps'
    '4,0' = Cmd 'closeapp'
    '0,1' = Cmd 'voldown'
    '1,1' = Cmd 'volup'
    '2,1' = Cmd 'brightdown'
    '3,1' = Cmd 'brightup'
    '4,1' = Cmd 'capture'
    '0,2' = Cmd 'settings'
    '1,2' = Cmd 'size'
    '2,2' = Cmd 'kiosks'
    '3,2' = Cmd 'reboot'
    '4,2' = Cmd 'shutdown'
}
Save-Profile -FileName 'vrhm-headset' -Name 'VRHM Headset' -Keys $hs -ProfileUuid '6F1C2A10-7D3B-4C55-9A61-0E2B5F7A1002'

# --- slot pages ----------------------------------------------------------------------------
foreach ($pg in @(
        @{ File = 'vrhm-apps';   Name = 'VRHM Apps';   Uuid = "$P.app";   Label = 'Favourite app slot'; Id = '6F1C2A10-7D3B-4C55-9A61-0E2B5F7A1003' },
        @{ File = 'vrhm-kiosks'; Name = 'VRHM Kiosks'; Uuid = "$P.kiosk"; Label = 'Kiosk slot';         Id = '6F1C2A10-7D3B-4C55-9A61-0E2B5F7A1004' })) {
    $keys = @{ '0,0' = Cmd 'headsetpage' }
    $i = 1
    for ($r = 0; $r -lt 3; $r++) {
        for ($c = 0; $c -lt 5; $c++) {
            if ($r -eq 0 -and $c -eq 0) { continue }
            $keys["$c,$r"] = New-Key -Uuid $pg.Uuid -Name $pg.Label -Settings @{ index = $i }
            $i++
        }
    }
    Save-Profile -FileName $pg.File -Name $pg.Name -Keys $keys -ProfileUuid $pg.Id
}

# --- screen profile page: row 1 back + eye L / R / merged, rows 2-3 view slots 1..10 ---------
function ViewKey([hashtable]$Settings) { New-Key -Uuid "$P.view" -Name 'Screen profile slot' -Settings $Settings }
$views = @{
    '0,0' = Cmd 'headsetpage'
    '1,0' = ViewKey @{ kind = 'eye'; eye = 'L' }
    '2,0' = ViewKey @{ kind = 'eye'; eye = 'R' }
    '3,0' = ViewKey @{ kind = 'eye'; eye = 'M' }
}
# top row = eyes only; views fill rows 2 and 3 (slots 1..10)
$i = 1
for ($r = 1; $r -lt 3; $r++) {
    for ($c = 0; $c -lt 5; $c++) {
        $views["$c,$r"] = ViewKey @{ kind = 'view'; index = $i }
        $i++
    }
}
Save-Profile -FileName 'vrhm-views' -Name 'VRHM Capture Profile' -Keys $views -ProfileUuid '6F1C2A10-7D3B-4C55-9A61-0E2B5F7A1005'

# --- settings page: back + one key per headset setting ---------------------------------------
function SetKey([string]$Key) { New-Key -Uuid "$P.setting" -Name 'Headset setting' -Settings @{ key = $Key } }
$set = @{
    '0,0' = Cmd 'headsetpage'
    '1,0' = SetKey 'guardian'
    '2,0' = SetKey 'guardianSetup'
    '3,0' = SetKey 'doubleTap'
    '4,0' = SetKey 'wideMotion'
    '0,1' = SetKey 'keepAwake'
    '1,1' = SetKey 'sharpening'
    '2,1' = SetKey 'refreshRate'
    '3,1' = SetKey 'updates'
    '4,1' = SetKey 'reapply'
    '0,2' = SetKey 'reload'
}
Save-Profile -FileName 'vrhm-settings' -Name 'VRHM Settings' -Keys $set -ProfileUuid '6F1C2A10-7D3B-4C55-9A61-0E2B5F7A1006'
