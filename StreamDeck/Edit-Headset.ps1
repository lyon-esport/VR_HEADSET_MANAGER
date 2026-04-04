<#
.SYNOPSIS
    Modifies headset settings in known_headsets.csv, including scrcpy profile parameters.

.DESCRIPTION
    Standalone script intended to be called by an external process (e.g. StreamDeck key press).
    Identifies the target headset by ID or Name, then sets or toggles the specified field.

    Fields AutoRestart and Record accept: True / False / Toggle
    Fields Eye and Audio accept:          Toggle / L or R (Eye) / D or N (Audio)
    Fields FPS and Bitrate accept:        a positive integer value

.PARAMETER ID
    Numeric ID of the headset as stored in the CSV.

.PARAMETER Name
    Name of the headset as stored in the CSV (case-insensitive).

.PARAMETER Field
    The field to modify.
    Accepted values: AutoRestart, Record, Eye, Audio, FPS, Bitrate

.PARAMETER Value
    The value to apply.
      AutoRestart / Record : True | False | Toggle  (default: Toggle)
      Eye                  : L | R | Toggle          (default: Toggle)
      Audio                : D | N | Toggle          (default: Toggle)
      FPS                  : positive integer
      Bitrate              : positive integer (Mbps)

.EXAMPLE
    .\Edit-Headset.ps1 -ID 2 -Field AutoRestart -Value Toggle
    .\Edit-Headset.ps1 -Name "Q3 BLUE" -Field Record -Value True
    .\Edit-Headset.ps1 -ID 1 -Field Eye -Value Toggle
    .\Edit-Headset.ps1 -ID 1 -Field Eye -Value L
    .\Edit-Headset.ps1 -ID 2 -Field Audio -Value D
    .\Edit-Headset.ps1 -ID 2 -Field FPS -Value 30
    .\Edit-Headset.ps1 -ID 2 -Field Bitrate -Value 20
#>

param (
    [int]    $ID    = -1,
    [string] $Name  = "",

    [Parameter(Mandatory = $true)]
    [ValidateSet("AutoRestart", "Record", "Eye", "Audio", "FPS", "Bitrate")]
    [string] $Field,

    [string] $Value = "Toggle"
)

# ---------------------------------------------------------------------------
# Path to the known_headsets.csv file
# ---------------------------------------------------------------------------
$KnownHeadsetsFilePath = Join-Path $PSScriptRoot "..\data\known_headsets.csv"

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
if ($ID -eq -1 -and $Name -eq "") {
    Write-Error "You must provide either -ID or -Name to identify the headset."
    exit 1
}

if (-not (Test-Path $KnownHeadsetsFilePath)) {
    Write-Error "CSV file not found: $KnownHeadsetsFilePath"
    exit 1
}

# ---------------------------------------------------------------------------
# Load CSV
# ---------------------------------------------------------------------------
$headsets = @(Import-Csv -Path $KnownHeadsetsFilePath -Delimiter ",")

if ($headsets.Count -eq 0) {
    Write-Error "No headsets found in CSV."
    exit 1
}

# ---------------------------------------------------------------------------
# Find target headset
# ---------------------------------------------------------------------------
$target = if ($ID -ne -1) {
    $headsets | Where-Object { $_.ID -eq $ID }
} else {
    $headsets | Where-Object { $_.Name -ieq $Name }
}

if ($null -eq $target) {
    $selector = if ($ID -ne -1) { "ID=$ID" } else { "Name='$Name'" }
    Write-Error "No headset found matching $selector."
    exit 1
}

# ---------------------------------------------------------------------------
# Apply change
# ---------------------------------------------------------------------------
$Value = $Value.Trim()

switch ($Field) {

    # --- Boolean fields -----------------------------------------------------
    { $_ -in @("AutoRestart", "Record") } {
        $CsvColumn = if ($Field -eq "AutoRestart") { "scrcpy_AutoRestart" } else { "Record" }
        $currentValue = $target.$CsvColumn
        $newValue = switch ($Value.ToLower()) {
            "toggle" { if ($currentValue -ieq "True") { "False" } else { "True" } }
            "true"   { "True" }
            "false"  { "False" }
            default  {
                Write-Error "Invalid value '$Value' for field '$Field'. Use True, False or Toggle."
                exit 1
            }
        }
        $target.$CsvColumn = $newValue
        Write-Host "[$($target.ID)] $($target.Name) - $CsvColumn : $currentValue -> $newValue"
    }

    # --- Profile fields (Eye, Audio, FPS, Bitrate) --------------------------
    { $_ -in @("Eye", "Audio", "FPS", "Bitrate") } {
        $rawProfile = if ($target.ScrcpyProfile) { $target.ScrcpyProfile } else { "R-N-45-20" }
        $parts = $rawProfile -split '-'
        if ($parts.Count -ne 4) { $parts = @('R','N','45','20') }

        $oldProfile = $rawProfile
        $v = $Value.ToUpper()

        switch ($Field) {
            "Eye" {
                $current = $parts[0]
                $parts[0] = switch ($v) {
                    "TOGGLE" { if ($current -eq 'L') { 'R' } else { 'L' } }
                    "L"      { 'L' }
                    "R"      { 'R' }
                    default  { Write-Error "Invalid value '$Value' for Eye. Use L, R or Toggle." ; exit 1 }
                }
            }
            "Audio" {
                $current = $parts[1]
                $parts[1] = switch ($v) {
                    "TOGGLE" { if ($current -eq 'D') { 'N' } else { 'D' } }
                    "D"      { 'D' }
                    "N"      { 'N' }
                    default  { Write-Error "Invalid value '$Value' for Audio. Use D, N or Toggle." ; exit 1 }
                }
            }
            "FPS" {
                if ($Value -notmatch '^\d+$' -or [int]$Value -le 0) {
                    Write-Error "Invalid value '$Value' for FPS. Must be a positive integer."
                    exit 1
                }
                $parts[2] = $Value
            }
            "Bitrate" {
                if ($Value -notmatch '^\d+$' -or [int]$Value -le 0) {
                    Write-Error "Invalid value '$Value' for Bitrate. Must be a positive integer (Mbps)."
                    exit 1
                }
                $parts[3] = $Value
            }
        }

        $newProfile = $parts -join '-'
        $target.ScrcpyProfile = $newProfile
        Write-Host "[$($target.ID)] $($target.Name) - ScrcpyProfile : $oldProfile -> $newProfile"
    }
}

# ---------------------------------------------------------------------------
# Save CSV (preserve column order identical to original)
# ---------------------------------------------------------------------------
$headsets | Export-Csv -Path $KnownHeadsetsFilePath -NoTypeInformation -Encoding UTF8
