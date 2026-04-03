<#
.SYNOPSIS
    Modifies scrcpy_AutoRestart or Record for a headset entry in known_headsets.csv.

.DESCRIPTION
    Standalone script intended to be called by an external process (e.g. StreamDeck key press).
    Identifies the target headset by ID or Name, then sets or toggles the specified field.

.PARAMETER ID
    Numeric ID of the headset as stored in the CSV.

.PARAMETER Name
    Name of the headset as stored in the CSV (case-insensitive).

.PARAMETER Field
    The field to modify. Accepted values: AutoRestart, Record.

.PARAMETER Value
    The value to set. Accepted values: True, False, Toggle (default: Toggle).

.EXAMPLE
    .\Edit-Headset.ps1 -ID 2 -Field AutoRestart -Value Toggle
    .\Edit-Headset.ps1 -Name "Q3 BLUE" -Field Record -Value True
    .\Edit-Headset.ps1 -ID 1 -Field AutoRestart
#>

param (
    [int]    $ID    = -1,
    [string] $Name  = "",

    [Parameter(Mandatory = $true)]
    [ValidateSet("AutoRestart", "Record")]
    [string] $Field,

    [ValidateSet("True", "False", "Toggle")]
    [string] $Value = "Toggle"
)

# ---------------------------------------------------------------------------
# Path to the known_headsets.csv file - adjust if needed
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

# Map friendly field name to CSV column name
$CsvColumn = switch ($Field) {
    "AutoRestart" { "scrcpy_AutoRestart" }
    "Record"      { "Record" }
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
$target = $null

if ($ID -ne -1) {
    $target = $headsets | Where-Object { $_.ID -eq $ID }
} else {
    $target = $headsets | Where-Object { $_.Name -ieq $Name }
}

if ($null -eq $target) {
    $selector = if ($ID -ne -1) { "ID=$ID" } else { "Name='$Name'" }
    Write-Error "No headset found matching $selector."
    exit 1
}

# ---------------------------------------------------------------------------
# Resolve new value
# ---------------------------------------------------------------------------
$currentValue = $target.$CsvColumn

if ($Value -eq "Toggle") {
    $newValue = if ($currentValue -ieq "True") { "False" } else { "True" }
} else {
    $newValue = $Value
}

# ---------------------------------------------------------------------------
# Apply change
# ---------------------------------------------------------------------------
$target.$CsvColumn = $newValue

# ---------------------------------------------------------------------------
# Save CSV (preserve column order identical to original)
# ---------------------------------------------------------------------------
$headsets | Export-Csv -Path $KnownHeadsetsFilePath -NoTypeInformation -Encoding UTF8

Write-Host "[$($target.ID)] $($target.Name) - $CsvColumn : $currentValue -> $newValue"
