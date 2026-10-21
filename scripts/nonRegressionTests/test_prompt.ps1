#Requires -Version 5.1
<#
.SYNOPSIS
    Operator interaction for the VR HEADSET MANAGER non-regression test harness.

.DESCRIPTION
    Dot-sourced by scripts\Invoke-NonRegressionTests.ps1. Provides:
      - Get-OperatorVerdict   : Manual-mode verdict override after each test
      - Confirm-TestStep      : yes/no question, auto-answers in Auto mode
      - Wait-OperatorAction   : blocking "do this physical thing" prompt
      - Read-OperatorObservation : "look and tell me" prompt -> Yes / No / Skip
      - Read-TestMenuChoice   : single-choice menu reader for the launch screen

    The distinction that matters: Confirm-TestStep is advisory and is skipped
    in Auto mode, while Wait-OperatorAction is for things no software can do
    (plug in a USB cable) and therefore prompts in BOTH modes - the operator
    can still decline, which turns into a SKIP rather than a FAIL.

    ASCII only (CLAUDE.md rule 1).
#>

function Read-TestMenuChoice {
    <#
    .SYNOPSIS
        Prompts for one choice from a set of accepted tokens, looping until
        the input is valid. Empty input returns -Default.

    .EXAMPLE
        Read-TestMenuChoice -Prompt '  Select mode' -Accept @('1','2','3') -Default '1'
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        # AllowEmptyString is required: callers legitimately pass '' as one of
        # the accepted tokens (Enter = accept default, e.g. Wait-OperatorAction's
        # @('', 'S')). Without it, PowerShell's mandatory-parameter validation
        # rejects the whole array the moment any element is an empty string
        # ("Cannot bind argument to parameter 'Accept' because it is an empty
        # string"), aborting the caller before Read-Host is even reached.
        [Parameter(Mandatory = $true)][AllowEmptyString()][string[]]$Accept,
        [string]$Default = ''
    )

    while ($true) {
        $raw = Read-Host $Prompt
        if ($null -eq $raw) { $raw = '' }
        $raw = $raw.Trim().ToUpper()

        if ($raw -eq '' -and $Default -ne '') { return $Default }
        if ($Accept -contains $raw) { return $raw }

        Write-Host ("  Invalid choice. Expected one of: {0}" -f ($Accept -join ', ')) -ForegroundColor Yellow
    }
}

function Confirm-TestStep {
    <#
    .SYNOPSIS
        Yes/no confirmation. In Auto mode returns -AutoAnswer without asking,
        so the same test code works in both modes.

    .EXAMPLE
        if (-not (Confirm-TestStep -Message 'Restart the web server now?')) { Skip-Test 'operator declined' }
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [bool]$AutoAnswer = $true
    )

    if ($global:TestRun.Mode -eq 'Auto') { return $AutoAnswer }

    $choice = Read-TestMenuChoice -Prompt ("  {0} [Y/N]" -f $Message) -Accept @('Y', 'N') -Default 'Y'
    return ($choice -eq 'Y')
}

function Wait-OperatorAction {
    <#
    .SYNOPSIS
        Asks the operator to perform a physical action and waits. Prompts in
        BOTH Auto and Manual mode - this is for things software cannot do.

    .DESCRIPTION
        Returns $true when the operator confirms the action is done, $false
        when they decline. Callers should turn $false into Skip-Test, never
        into a failure: declining to plug in a headset is not a regression.

    .EXAMPLE
        if (-not (Wait-OperatorAction -Message 'Plug the headset in over USB and accept the ADB dialog')) {
            Skip-Test 'operator declined the USB step'
        }
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$Hint = ''
    )

    if ($global:TestRun -and $global:TestRun.NoHeadset) {
        Write-Host '  -NoHeadset: operator action skipped.' -ForegroundColor DarkGray
        return $false
    }

    Write-Host ''
    Write-Host '  +---------------------------------------------------------------+' -ForegroundColor Yellow
    Write-Host '  | OPERATOR ACTION REQUIRED                                      |' -ForegroundColor Yellow
    Write-Host '  +---------------------------------------------------------------+' -ForegroundColor Yellow
    Write-Host ("  {0}" -f $Message) -ForegroundColor White
    if ($Hint) { Write-Host ("  {0}" -f $Hint) -ForegroundColor DarkGray }
    Write-Host ''

    $choice = Read-TestMenuChoice -Prompt '  [Enter] done   [S] skip this test' -Accept @('', 'S') -Default ''
    if ($choice -eq 'S') {
        Write-Host '  Skipped by operator.' -ForegroundColor DarkGray
        return $false
    }
    return $true
}

function Read-OperatorObservation {
    <#
    .SYNOPSIS
        Asks the operator to LOOK at something and report what they see.
        Returns 'Yes', 'No' or 'Skip'. Prompts in BOTH Auto and Manual mode.

    .DESCRIPTION
        Wait-OperatorAction is for "do this physical thing, then press Enter" and can
        only answer done or skip, so it cannot express "I looked and it is NOT there".
        This one is for questions about what is visible on a headset or a screen.

        There is deliberately NO default on Enter: an observation that a stray keypress
        can confirm is worthless, so the prompt keeps asking until the operator types
        Y, N or S.

        The caller decides what the answers mean. Typically:
          Skip -> Skip-Test (not a regression, the operator could not check)
          No   -> a FAIL, via an assertion
          Yes  -> carry on

    .EXAMPLE
        $answer = Read-OperatorObservation -Message "Is the notification listed on headset 'Q3 RED'?"
        if ($answer -eq 'Skip') { Skip-Test 'operator skipped' }
        Assert-Equal 'Yes' $answer 'the notification is listed'
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$Hint = ''
    )

    if ($global:TestRun -and $global:TestRun.NoHeadset) {
        Write-Host '  -NoHeadset: operator observation skipped.' -ForegroundColor DarkGray
        return 'Skip'
    }

    Write-Host ''
    Write-Host '  +---------------------------------------------------------------+' -ForegroundColor Yellow
    Write-Host '  | OPERATOR OBSERVATION REQUIRED                                 |' -ForegroundColor Yellow
    Write-Host '  +---------------------------------------------------------------+' -ForegroundColor Yellow
    Write-Host ("  {0}" -f $Message) -ForegroundColor White
    if ($Hint) { Write-Host ("  {0}" -f $Hint) -ForegroundColor DarkGray }
    Write-Host ''

    $choice = Read-TestMenuChoice -Prompt '  [Y] yes, it works   [N] no, it does NOT   [S] skip this test' -Accept @('Y', 'N', 'S')
    switch ($choice) {
        'Y' { return 'Yes' }
        'N' { return 'No' }
        default { Write-Host '  Skipped by operator.' -ForegroundColor DarkGray; return 'Skip' }
    }
}

function Get-OperatorVerdict {
    <#
    .SYNOPSIS
        Manual-mode verdict override, called by Invoke-RegressionTest after
        each test. Returns PASS / FAIL / SKIP / RETRY.

    .DESCRIPTION
        The harness verdict is offered as the default: pressing Enter accepts
        whatever the automated assertions decided. [A] switches the rest of the
        run to Automatic mode, which is the escape hatch when the operator has
        seen enough and wants the remainder to run unattended.
    #>
    param([Parameter(Mandatory = $true)]$Result)

    Write-Host ("        [Enter] accept {0}   [F] fail   [S] skip   [R] retry   [A] switch to Automatic" -f $Result.Status) -ForegroundColor DarkCyan
    $choice = Read-TestMenuChoice -Prompt '        verdict' -Accept @('', 'F', 'S', 'R', 'A') -Default ''

    switch ($choice) {
        'F' { return 'FAIL' }
        'S' { return 'SKIP' }
        'R' { return 'RETRY' }
        'A' {
            $global:TestRun.Mode = 'Auto'
            Write-Host '        Switched to Automatic mode for the rest of the run.' -ForegroundColor Magenta
            return $Result.Status
        }
        default { return $Result.Status }
    }
}

function Select-TestHeadset {
    <#
    .SYNOPSIS
        Asks the operator which registered headset to use for the run when
        -HeadsetName was not supplied and more than one candidate exists.

    .EXAMPLE
        $name = Select-TestHeadset -Candidates @('Q3 RED','Q3 BLUE')
    #>
    param([Parameter(Mandatory = $true)][string[]]$Candidates)

    if ($Candidates.Count -eq 0) { return '' }
    if ($Candidates.Count -eq 1) { return $Candidates[0] }

    Write-Host ''
    Write-Host '  Which headset should the tests use?' -ForegroundColor White
    for ($i = 0; $i -lt $Candidates.Count; $i++) {
        Write-Host ("    [{0}] {1}" -f ($i + 1), $Candidates[$i])
    }

    $accept = 1..$Candidates.Count | ForEach-Object { "$_" }
    $choice = Read-TestMenuChoice -Prompt '  Select' -Accept $accept -Default '1'
    return $Candidates[[int]$choice - 1]
}

# ---------------------------------------------------------------------------
# Software USB link control (replaces "unplug / replug the cable" prompts)
# ---------------------------------------------------------------------------

function Test-NrtElevated {
    <# $true when this PowerShell is elevated (Disable-PnpDevice needs it). #>
    try {
        return ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Get-NrtUsbPnpDevice {
    <#
    .SYNOPSIS
        The PnP composite USB device of ONE headset (Meta VID 2833 / Pico VID 2D40), or $null.

    .DESCRIPTION
        Matched on the serial number first. Without a serial it only answers when exactly one
        headset-vendor device is present, so another headset is never disabled by mistake.
        Interface children (MI_xx) are excluded: disabling the composite parent is what makes the
        ADB transport vanish exactly like a pulled cable.

    .EXAMPLE
        $dev = Get-NrtUsbPnpDevice -Serial '2G0YC5ZG1W00ZJ'
    #>
    param([string]$Serial = '')

    try {
        $all = @(Get-PnpDevice -PresentOnly -ErrorAction Stop | Where-Object {
            $_.InstanceId -match '^USB\\VID_(2833|2D40)&PID_[0-9A-F]{4}\\' -and $_.InstanceId -notmatch '&MI_'
        })
    } catch { return $null }

    if ($Serial) {
        $hit = @($all | Where-Object { $_.InstanceId -like ('*\' + $Serial) })
        if ($hit.Count -eq 1) { return $hit[0] }
        return $null
    }
    if ($all.Count -eq 1) { return $all[0] }
    return $null
}

function Get-NrtDisabledUsbFile {
    <# Where the InstanceIds this harness disabled are remembered across processes. #>
    return (Join-Path $PSScriptRoot 'usb_disabled.json')
}

function Save-NrtDisabledUsbIds {
    <# Writes (or, with no ids, deletes) the persisted list. UTF-8 without BOM. Never throws. #>
    param([string[]]$Ids = @())
    try {
        $file = Get-NrtDisabledUsbFile
        if (@($Ids).Count -eq 0) {
            if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
            return
        }
        [System.IO.File]::WriteAllText($file, (ConvertTo-Json -InputObject @($Ids)), (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

function Restore-NrtStaleUsbLink {
    <#
    .SYNOPSIS
        Re-enables a headset USB device left disabled by an EARLIER run (killed before its teardown).

    .DESCRIPTION
        Enables (a) the ids remembered in usb_disabled.json and (b) any present Meta/Pico composite
        USB device whose Windows problem code says "disabled" (22). Needs an elevated shell; does
        nothing otherwise. Returns the InstanceIds it re-enabled. Never throws.

    .EXAMPLE
        $healed = @(Restore-NrtStaleUsbLink)
    #>
    $healed = New-Object System.Collections.Generic.List[string]
    try {
        if (-not (Test-NrtElevated)) { return @() }
        $ids = New-Object System.Collections.Generic.List[string]
        $file = Get-NrtDisabledUsbFile
        if (Test-Path -LiteralPath $file) {
            $raw = Get-Content -LiteralPath $file -Raw -Encoding UTF8
            if ($raw) { foreach ($i in @(ConvertFrom-Json -InputObject $raw)) { if ($i) { $ids.Add([string]$i) } } }
        }
        foreach ($d in @(Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object {
            $_.InstanceId -match '^USB\\VID_(2833|2D40)&PID_[0-9A-F]{4}\\' -and $_.InstanceId -notmatch '&MI_' -and $_.Status -ne 'OK'
        })) {
            $prob = (Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_ProblemCode' -ErrorAction SilentlyContinue).Data
            if ($prob -eq 22 -and -not $ids.Contains($d.InstanceId)) { $ids.Add($d.InstanceId) }
        }
        foreach ($id in $ids) {
            try { Enable-PnpDevice -InstanceId $id -Confirm:$false -ErrorAction Stop; $healed.Add($id) } catch { }
        }
        Save-NrtDisabledUsbIds -Ids @()
        if ($healed.Count -gt 0) { Start-Sleep -Seconds 5 }
    } catch { }
    return @($healed)
}

function Test-NrtUsbHeadsetVisible {
    <#
    .SYNOPSIS
        Is this headset's USB device present and healthy in Windows? Returns @{Visible;Reason}.

    .EXAMPLE
        $v = Test-NrtUsbHeadsetVisible -Serial '1WMHH8242N0366'
    #>
    param([string]$Serial = '')
    $dev = Get-NrtUsbPnpDevice -Serial $Serial
    if (-not $dev) { return @{ Visible = $false; Reason = 'no matching Meta/Pico USB device present in Windows (cable out or device disabled)' } }
    if ([string]$dev.Status -ne 'OK') { return @{ Visible = $false; Reason = ("USB device status is '{0}'" -f $dev.Status) } }
    return @{ Visible = $true; Reason = 'USB device present, status OK' }
}

function Set-NrtUsbLink {
    <#
    .SYNOPSIS
        Cuts (Out) or restores (In) the USB link of a headset from software, instead of asking the
        operator to pull the cable. Returns $true on success, $false when it cannot be done (not
        elevated, device not found, PnP error) so the caller falls back to the operator prompt.

    .EXAMPLE
        if (Set-NrtUsbLink -State Out -Serial $headset.SerialNumber) { ... }
    #>
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Out', 'In')][string]$State,
        [string]$Serial = ''
    )

    if (-not (Test-NrtElevated)) { return $false }

    try {
        if ($State -eq 'Out') {
            $dev = Get-NrtUsbPnpDevice -Serial $Serial
            if (-not $dev) { return $false }
            # Persist BEFORE disabling: a run killed while the device is out must still be healable.
            if (-not $global:TestRun.DisabledUsb.Contains($dev.InstanceId)) { $global:TestRun.DisabledUsb.Add($dev.InstanceId) }
            Save-NrtDisabledUsbIds -Ids @($global:TestRun.DisabledUsb)
            Disable-PnpDevice -InstanceId $dev.InstanceId -Confirm:$false -ErrorAction Stop
            return $true
        }
        $ids = @($global:TestRun.DisabledUsb)
        if ($ids.Count -eq 0) { return $false }
        foreach ($id in $ids) { Enable-PnpDevice -InstanceId $id -Confirm:$false -ErrorAction Stop }
        $global:TestRun.DisabledUsb.Clear()
        Save-NrtDisabledUsbIds -Ids @()
        return $true
    } catch {
        Write-Host ("  Software USB {0} failed: {1}" -f $State.ToLower(), $_.Exception.Message) -ForegroundColor DarkGray
        return $false
    }
}

function Restore-NrtUsbLink {
    <# Re-enables every USB device this run disabled. Safe to call any time (finally blocks, teardown). #>
    try {
        if ($global:TestRun -and $global:TestRun.DisabledUsb -and $global:TestRun.DisabledUsb.Count -gt 0) {
            [void](Set-NrtUsbLink -State In)
        }
    } catch { }
}

function Invoke-NrtCableStep {
    <#
    .SYNOPSIS
        One "cable out" / "cable back in" step. Software PnP first; the operator prompt only when
        software cannot do it or the run asked for the real cable (-PhysicalUsb / -Physical).

    .DESCRIPTION
        Returns 'software', 'physical' or 'declined'. 'declined' must become Skip-Test.
        -Message is the operator text used for the physical case.

    .EXAMPLE
        $how = Invoke-NrtCableStep -Direction Unplug -Serial $h.SerialNumber -Message 'UNPLUG the cable, then press Enter.'
    #>
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Unplug', 'Plug')][string]$Direction,
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$Serial = '',
        [switch]$Physical
    )

    $wantPhysical = ($Physical -and $global:TestRun -and $global:TestRun.PhysicalUsb)
    if (-not $wantPhysical -and -not ($global:TestRun -and $global:TestRun.NoHeadset)) {
        $state = if ($Direction -eq 'Unplug') { 'Out' } else { 'In' }
        if (Set-NrtUsbLink -State $state -Serial $Serial) {
            Write-Host ("  USB link {0} by software (no cable handling)." -f $(if ($state -eq 'Out') { 'cut' } else { 'restored' })) -ForegroundColor DarkGray
            Start-Sleep -Seconds 2
            return 'software'
        }
        Write-Host '  Software USB control unavailable (needs an elevated PowerShell and a matching USB device) - asking the operator.' -ForegroundColor DarkGray
    }
    if (Wait-OperatorAction -Message $Message) { return 'physical' }
    return 'declined'
}
