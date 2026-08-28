#Requires -Version 5.1
<#
.SYNOPSIS
    Operator interaction for the VR HEADSET MANAGER non-regression test harness.

.DESCRIPTION
    Dot-sourced by scripts\Invoke-NonRegressionTests.ps1. Provides:
      - Get-OperatorVerdict   : Manual-mode verdict override after each test
      - Confirm-TestStep      : yes/no question, auto-answers in Auto mode
      - Wait-OperatorAction   : blocking "do this physical thing" prompt
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
