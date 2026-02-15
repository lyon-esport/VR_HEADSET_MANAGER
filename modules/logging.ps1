##########################
### FONCTIONS DE BASE ####
##########################


function Write-Log {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [ValidateSet("DEBUG", "INFO", "SUCCESS", "WARNING", "ERROR", "NONE")]
        [string]$Level = "INFO"
    )

    # Dictionnaire des couleurs pour la console
    $colors = @{
        "DEBUG"   = "DarkGray"
        "INFO"    = "Green"
        "SUCCESS" = @{ Background = "Magenta"; Foreground = "White" }
        "WARNING" = "Yellow"
        "ERROR"   = @{ Background = "Red"; Foreground = "White" }
    }
    
    # Obtenir l'heure actuelle au format "yyyy-MM-dd HH:mm:ss"
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "$timestamp [$Level] $Message"
    $consoleEntry = "[$Level] $Message"

    # Liste des niveaux de log classes par importance
    $logLevels = @("DEBUG", "INFO", "SUCCESS", "WARNING", "ERROR")
    
    # Verifier si le niveau de log autorise l'affichage dans la console
    if ($logLevels.IndexOf($Level) -ge $logLevels.IndexOf($global:debugLevelToConsole) -or $global:debugLevelToConsole -eq "DEBUG") {
        
        if ($colors[$Level].GetType().Name -eq "Hashtable") {
            # Affichage avec fond rouge et texte blanc pour les erreurs
            Write-Host $consoleEntry -BackgroundColor $colors[$Level].Background -ForegroundColor $colors[$Level].Foreground
        } else {
            # Affichage normal pour les autres niveaux
            Write-Host $consoleEntry -ForegroundColor $colors[$Level]
        }
    }

    # Verifier si le niveau de log autorise l'ecriture dans le fichier
    if ($logLevels.IndexOf($Level) -ge $logLevels.IndexOf($global:debugLevelToFile) -or $global:debugLevelToFile -eq "DEBUG") {
        $attempt = 0
        $maxAttempts = 5
        $written = $false

        
        while ($attempt -lt $maxAttempts) {
            try {
                Add-Content -Path $global:logFile -Value $logEntry -erroraction 'silentlycontinue'
                $written = $true
                break
            } catch {
                if ($_ -match "en cours d'utilisation") {
                    Start-Sleep -Milliseconds 200
                    $attempt++
                } else {
                    throw
                }
            }
        }
        if (-not $written) {
            Write-Warning "Impossible d'ecrire dans le fichier log apres $maxAttempts tentatives : $logEntry"
        }
    }

}


# 📌 **Exemples d'utilisation :**
<#
Write-Log -Message "Ceci est un message de debug" -Level "DEBUG"
Write-Log -Message "Processus termine avec succes" -Level "INFO"
Write-Log -Message "Attention : Une configuration est manquante" -Level "WARNING"
Write-Log -Message "Erreur fatale : Impossible de continuer" -Level "ERROR"
#>
