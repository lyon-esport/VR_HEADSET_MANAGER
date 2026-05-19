##########################
### BASE FUNCTIONS    ####
##########################


function Write-Log {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [ValidateSet("DEBUG", "INFO", "SUCCESS", "WARNING", "ERROR", "NONE")]
        [string]$Level = "INFO"
    )

    # Color dictionary for the console
    $colors = @{
        "DEBUG"   = "DarkGray"
        "INFO"    = "Green"
        "SUCCESS" = @{ Background = "Magenta"; Foreground = "White" }
        "WARNING" = "Yellow"
        "ERROR"   = @{ Background = "Red"; Foreground = "White" }
    }
    
    # Get the current time in "yyyy-MM-dd HH:mm:ss" format
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "$timestamp [$Level] $Message"
    $consoleEntry = "[$Level] $Message"

    # List of log levels sorted by importance
    $logLevels = @("DEBUG", "INFO", "SUCCESS", "WARNING", "ERROR")
    
    # Check whether the log level allows console output
    if ($logLevels.IndexOf($Level) -ge $logLevels.IndexOf($global:debugLevelToConsole) -or $global:debugLevelToConsole -eq "DEBUG") {
        
        if ($colors[$Level].GetType().Name -eq "Hashtable") {
            # Display with colored background for errors/success
            Write-Host $consoleEntry -BackgroundColor $colors[$Level].Background -ForegroundColor $colors[$Level].Foreground
        } else {
            # Normal display for other log levels
            Write-Host $consoleEntry -ForegroundColor $colors[$Level]
        }
    }

    # Check whether the log level allows writing to file
    if ($logLevels.IndexOf($Level) -ge $logLevels.IndexOf($global:debugLevelToFile) -or $global:debugLevelToFile -eq "DEBUG") {
        try {
            $mtx = [System.Threading.Mutex]::new($false, 'Global\VRHMLog')
            $acq = $false
            try {
                $acq = $mtx.WaitOne(1000)
                $bytes = [System.Text.Encoding]::Default.GetBytes($logEntry + "`r`n")
                $fs = [System.IO.File]::Open(
                    $global:logFile,
                    [System.IO.FileMode]::Append,
                    [System.IO.FileAccess]::Write,
                    [System.IO.FileShare]::ReadWrite)
                try { $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Close() }
            } finally {
                if ($acq) { $mtx.ReleaseMutex() }
                $mtx.Dispose()
            }
        } catch {
            Write-Warning "Failed to write to the log file: $logEntry"
        }
    }

}


# 📌 **Usage examples:**
<#
Write-Log -Message "This is a debug message" -Level "DEBUG"
Write-Log -Message "Process completed successfully" -Level "INFO"
Write-Log -Message "Warning: A configuration item is missing" -Level "WARNING"
Write-Log -Message "Fatal error: Cannot continue" -Level "ERROR"
#>
