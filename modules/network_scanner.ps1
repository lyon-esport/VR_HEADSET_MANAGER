
##########################
# NETWORK SEARCH #
##########################

function Get-Test {
    param (
        $message
    )
    Write-Host "C'est un test ! $message"
} 



function Add-Headset-ScanNetwork {
    [CmdletBinding()]
    param (
        [int]$port = $global:adbPort_default,       # Port a tester
        [int]$timeout = 200 # Delai d'attente en millisecondes
    )
    
    $adbPath = Join-Path -Path $global:adbFolder -ChildPath "adb.exe"
    
    Clear-Host
    Start-Sleep -Milliseconds 200
    Write-Host "=== SCAN DU RESEAU POUR CASQUES ===" -ForegroundColor Cyan

    # etape 1 : Selection de l'interface reseau
    $networks = Get-PrivateNetworks
    if (-not $networks) {
        Write-Host "Aucun reseau prive detecte." -ForegroundColor Red
        return
    }

    Write-Host "`nInterfaces reseau detectees :"
    $i = 1
    foreach ($net in $networks) {
        Write-Host "$i. $($net.InterfaceAlias) - IP $($net.IPAddress) ($($net.NetworkCIDR))"
        $i++
    }

    do {
        $selection = Read-Host "Selectionner une interface reseau (1-$(@($networks).Count))"
    } while (-not ($selection -match '^\d+$') -or [int]$selection -lt 1 -or [int]$selection -gt $(@($networks).Count))

    $selectedNetwork = $networks[[int]$selection - 1].NetworkCIDR

    # etape 2 : Port ADB a scanner

    Write-Host "`nAnalyse du reseau $selectedNetwork sur le port $port ..." -ForegroundColor Yellow
    $foundDevices = Test-PortForCidr -CIDR $selectedNetwork -port $port

    if (-not $foundDevices -or $foundDevices.Count -eq 0) {
        Write-Host "Aucun casque detecte sur le reseau." -ForegroundColor Red
        return
    }


    # etape 3.5 : Connexion ADB et recuperation d'infos
    Start-Sleep -Milliseconds 200
    foreach ($device in $foundDevices) {
        $adbTarget = "$($device.hostname):$port"
        Write-Log "Connexion a $adbTarget..." -Level INFO

        $connectOutput = & $adbPath connect $adbTarget 2>&1
        if ($connectOutput -match 'connected to') {
            $model = & $adbPath -s $adbTarget shell getprop ro.product.model 2>$null | Out-String
            $serial = & $adbPath -s $adbTarget shell getprop ro.serialno 2>$null | Out-String
            if (-not $serial -or $serial.Trim() -eq "") {
                $serial = & $adbPath -s $adbTarget shell getprop ro.boot.serialno 2>$null | Out-String
            }

            # Nettoyage des donnees
            $device | Add-Member -NotePropertyName "Model" -NotePropertyValue ($model.Trim()) -Force
            $device | Add-Member -NotePropertyName "Serial" -NotePropertyValue ($serial.Trim()) -Force

            Write-Log "Connecte a $adbTarget — Modele: $($device.Model), Numero de serie: $($device.Serial)" -Level INFO
            & $adbPath disconnect $adbTarget | Out-Null
        } else {
            Write-Log "echec de connexion a $adbTarget — Ignore." -Level WARNING
            $device | Add-Member -NotePropertyName "Model" -NotePropertyValue "INCONNU" -Force
            $device | Add-Member -NotePropertyName "Serial" -NotePropertyValue "INCONNU" -Force
        }
    }




    <# etape 4 : Afficher les casques detectes
    Write-Host "`nCasques detectes :"
    $i = 1
    foreach ($dev in $foundDevices) {
        Write-Host "$i. [$($dev.hostname)]`t [$($dev.Model)]`t [$($dev.Serial)]"
        $i++
    }#>

    # Verification doublons
    $knownHeadsets = Get-KnownHeadsets
    $knownIPs = $knownHeadsets | ForEach-Object { $_.IPAddress }

    # etape 4 : Afficher les casques detectes
    Write-Host "`nCasques detectes :"
    $i = 1
    foreach ($dev in $foundDevices) {
        $isKnown = $knownIPs -contains $dev.hostname
        if ($isKnown) {
            Write-Host "$i. [$($dev.hostname)]`t [$($dev.Model)]`t [$($dev.Serial)]  (deja ajoute)" -ForegroundColor DarkGray
            $dev | Add-Member -NotePropertyName "AlreadyAdded" -NotePropertyValue $true -Force
        } else {
            Write-Host "$i. [$($dev.hostname)]`t [$($dev.Model)]`t [$($dev.Serial)]"
            $dev | Add-Member -NotePropertyName "AlreadyAdded" -NotePropertyValue $false -Force
        }
        $i++
    }

    # etape 5 : Selectionner ceux a ajouter
    $selections = Read-Host "Saisir les numeros des casques a ajouter (ex: 1,3,5)"
    $indices = $selections -split ',' | ForEach-Object { ($_ -replace '\s','') } | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ - 1 }

    $selectedDevices = @()
    foreach ($index in $indices) {
        if ($index -ge 0 -and $index -lt @($foundDevices).Count) {
            $selectedDevices += $foundDevices[$index]
        }
    }

    if (-not $selectedDevices) {
        Write-Host "Aucun casque selectionne." -ForegroundColor Yellow
        return
    }

    # etape 6 : Confirmation & ajout des casques
    Write-Host "`nCasques a ajouter :"
    foreach ($dev in $selectedDevices) {
        Write-Host "- $($dev.hostname)"
    }

    $confirm = Read-Host "Confirmer l'ajout de ces casques ? (o/n)"
    if ($confirm -ne 'o' -and $confirm -ne 'O') {
        Write-Host "Ajout annule." -ForegroundColor Red
        return
    }

    foreach ($dev in $selectedDevices) {
        $name = Read-Host "Nom a attribuer a $($dev.hostname)"
        if (-not $name) {
            $name = "Casque_$($dev.hostname.Replace('.', '_'))"
        }

        Write-Log "Ajout du casque : $name ($($dev.hostname)) - Modele : $model, S/N : $serial" -Level INFO
        Add-Headset -IPAddress $dev.hostname -Name $name
    }

    Write-Host "`nTous les casques selectionnes ont ete ajoutes !" -ForegroundColor Green
}



function Get-IpRange {
<#
.SYNOPSIS
    Given a subnet in CIDR format, get all of the valid IP addresses in that range.
.DESCRIPTION
    Given a subnet in CIDR format, get all of the valid IP addresses in that range.
.PARAMETER Subnets
    The subnet written in CIDR format 'a.b.c.d/#' and an example would be '192.168.1.24/27'. Can be a single value, an
    array of values, or values can be taken from the pipeline.
.EXAMPLE
    Get-IpRange -Subnets '192.168.1.24/30'
 
    192.168.1.25
    192.168.1.26
.EXAMPLE
    (Get-IpRange -Subnets '10.100.10.0/24').count
 
    254
.EXAMPLE
    '192.168.1.128/30' | Get-IpRange
 
    192.168.1.129
    192.168.1.130
.NOTES
    Inspired by https://gallery.technet.microsoft.com/PowerShell-Subnet-db45ec74
 
    * Added comment help
#>

    [CmdletBinding(ConfirmImpact = 'None')]
    Param(
        [Parameter(Mandatory, HelpMessage = 'Please enter a subnet in the form a.b.c.d/#', ValueFromPipeline, Position = 0)]
        [string[]] $Subnets
    )

    begin {
        Write-Verbose -Message "Starting [$($MyInvocation.Mycommand)]"
    }

    process {
        foreach ($subnet in $subnets) {
            if ($subnet -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/\d{1,2}$') {
                #Split IP and subnet
                $IP = ($Subnet -split '\/')[0]
                [int] $SubnetBits = ($Subnet -split '\/')[1]
                if ($SubnetBits -lt 7 -or $SubnetBits -gt 30) {
                    Write-Error -Message 'The number following the / must be between 7 and 30'
                    break
                }
                #Convert IP into binary
                #Split IP into different octects and for each one, figure out the binary with leading zeros and add to the total
                $Octets = $IP -split '\.'
                $IPInBinary = @()
                foreach ($Octet in $Octets) {
                    #convert to binary
                    $OctetInBinary = [convert]::ToString($Octet, 2)
                    #get length of binary string add leading zeros to make octet
                    $OctetInBinary = ('0' * (8 - ($OctetInBinary).Length) + $OctetInBinary)
                    $IPInBinary = $IPInBinary + $OctetInBinary
                }
                $IPInBinary = $IPInBinary -join ''
                #Get network ID by subtracting subnet mask
                $HostBits = 32 - $SubnetBits
                $NetworkIDInBinary = $IPInBinary.Substring(0, $SubnetBits)
                #Get host ID and get the first host ID by converting all 1s into 0s
                $HostIDInBinary = $IPInBinary.Substring($SubnetBits, $HostBits)
                $HostIDInBinary = $HostIDInBinary -replace '1', '0'
                #Work out all the host IDs in that subnet by cycling through $i from 1 up to max $HostIDInBinary (i.e. 1s stringed up to $HostBits)
                #Work out max $HostIDInBinary
                $imax = [convert]::ToInt32(('1' * $HostBits), 2) - 1
                $IPs = @()
                #Next ID is first network ID converted to decimal plus $i then converted to binary
                For ($i = 1 ; $i -le $imax ; $i++) {
                    #Convert to decimal and add $i
                    $NextHostIDInDecimal = ([convert]::ToInt32($HostIDInBinary, 2) + $i)
                    #Convert back to binary
                    $NextHostIDInBinary = [convert]::ToString($NextHostIDInDecimal, 2)
                    #Add leading zeros
                    #Number of zeros to add
                    $NoOfZerosToAdd = $HostIDInBinary.Length - $NextHostIDInBinary.Length
                    $NextHostIDInBinary = ('0' * $NoOfZerosToAdd) + $NextHostIDInBinary
                    #Work out next IP
                    #Add networkID to hostID
                    $NextIPInBinary = $NetworkIDInBinary + $NextHostIDInBinary
                    #Split into octets and separate by . then join
                    $IP = @()
                    For ($x = 1 ; $x -le 4 ; $x++) {
                        #Work out start character position
                        $StartCharNumber = ($x - 1) * 8
                        #Get octet in binary
                        $IPOctetInBinary = $NextIPInBinary.Substring($StartCharNumber, 8)
                        #Convert octet into decimal
                        $IPOctetInDecimal = [convert]::ToInt32($IPOctetInBinary, 2)
                        #Add octet to IP
                        $IP += $IPOctetInDecimal
                    }
                    #Separate by .
                    $IP = $IP -join '.'
                    $IPs += $IP
                }
                Write-Output -InputObject $IPs
            } else {
                Write-Error -Message "Subnet [$subnet] is not in a valid format"
            }
        }
    }

    end {
        Write-Verbose -Message "Ending [$($MyInvocation.Mycommand)]"
    }
}

# Fonction pour tester un port sur une adresse IP specifique

#test-port -hostname "192.168.1.243"
function Test-Port {
    param (
        [Parameter(Mandatory=$true)]
        [string]$hostname,  # Nom d'hôte ou adresse IP
        [int]$port = $Global:adbPort_default,         # Port a tester
        [int]$timeout = 200 # Delai d'attente en millisecondes
    )

    $requestCallback = $state = $null
    $client = New-Object System.Net.Sockets.TcpClient

    # Commencer la tentative de connexion
    $beginConnect = $client.BeginConnect($hostname, $port, $requestCallback, $state)

    # Attendre pendant le delai d'attente specifie
    $startTime = Get-Date
    while (-not $client.Connected -and ((Get-Date) - $startTime).TotalMilliseconds -lt $timeout) {
        Start-Sleep -Milliseconds 10  # Attente de 10ms pour ne pas surcharger le processeur
    }

    # Verifier si la connexion est reussie
    if ($client.Connected) {
        $open = $true
    } else {
        $open = $false
    }

    # Fermer la connexion
    $client.Close()

    # Retourner l'objet avec le resultat du test
    return [pscustomobject]@{
        hostname = $hostname
        port     = $port
        open     = $open
    }
}


#Test-PortInternal -hostname "192.168.1.243"
#$hostname = $ip =  "192.168.1.243"
#$port = 5555
#$timeout = 200
function Test-PortInternal {
    param($hostname, $port, $timeout)
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $async = $tcp.BeginConnect($hostname, $port, $null, $null)
        $wait = $async.AsyncWaitHandle.WaitOne($timeout, $false)
        if (-not $wait) {
            return @{ hostname = $hostname; open = $false }
        }
        $tcp.EndConnect($async)
        return @{ hostname = $hostname; open = $true }
    } catch {
        return @{ hostname = $hostname; open = $false }
    } finally {
        if ($tcp) { $tcp.Close() }
    }
}


# Fonction pour obtenir toutes les adresses IP d'un CIDR et tester le port en PARALLEL
<#
$test = Test-PortForCidr -CIDR $selectedNetwork -port $port
$CIDR = $selectedNetwork
Test-port -hostname "192.168.1.243" -port 5555 
Test-port -hostname "192.168.1.243" -port 46801

#$CIDR = $($net.NetworkCIDR)
# Test-PortForCidr -CIDR "192.168.1.0/24" -timeout 200
#$CIDR = "192.168.1.0/24"
#$ip = "192.168.1.243"
#>
function Test-PortForCidr {
    <#
    .SYNOPSIS
    Teste la disponibilité d'un port sur toutes les adresses IP d'un réseau CIDR en parallèle.
    
    .PARAMETER CIDR
    La notation CIDR du réseau à scanner (ex: "192.168.1.0/24")
    
    .PARAMETER Port
    Le port à tester (par défaut: 5555)
    
    .PARAMETER Timeout
    Timeout en millisecondes (par défaut: 500ms)
    
    .PARAMETER MaxThreads
    Nombre maximum de threads parallèles (par défaut: 50)
    #>
    param (
        [Parameter(Mandatory=$true)]
        [string]$CIDR,
        
        [int]$Port = 5555,
        
        [ValidateRange(100,5000)]
        [int]$Timeout = 500,
        
        [int]$MaxThreads = 50
    )

    # Récupérer toutes les IPs du CIDR
    $ipRange = Get-IpRange $CIDR
    $totalIPs = $ipRange.Count
    Write-Log "Scan de $totalIPs adresses IP sur le port $Port" INFO

    # Configuration du pool de runspaces
    $runspacePool = [runspacefactory]::CreateRunspacePool(1, $MaxThreads)
    $runspacePool.Open()
    $jobs = @()

    # ScriptBlock pour tester un port
    $testPortScript = {
        param($ip, $port, $timeout)
        
        $result = [PSCustomObject]@{
                IPAddress   = $ip
                Port        = $port
                Open        = $false
        }
        
        try {
            $tcpClient = New-Object System.Net.Sockets.TcpClient
            $asyncResult = $tcpClient.BeginConnect($ip, $port, $null, $null)
            $connectionStatus = $asyncResult.AsyncWaitHandle.WaitOne($timeout, $false)

            if ($connectionStatus -and $tcpClient.Connected) {
                $result.Open = $true
                $tcpClient.EndConnect($asyncResult)
            }
        }
        catch {}
        finally {
            if ($tcpClient) { $tcpClient.Dispose() }
        }
        return $result
    }

    # Lancement des jobs en parallèle
    foreach ($ip in $ipRange) {
        $powershell = [powershell]::Create().AddScript($testPortScript).AddArgument($ip).AddArgument($Port).AddArgument($Timeout)
        $powershell.RunspacePool = $runspacePool
        $jobs += [PSCustomObject]@{
            PowerShell = $powershell
            AsyncResult = $powershell.BeginInvoke()
        }
    }
    Start-Sleep -Milliseconds $(20*$timeout)
    # Collecte des résultats
    $results = do {
        foreach ($job in $jobs) {
            if ($job.AsyncResult.IsCompleted) {
                $job.PowerShell.EndInvoke($job.AsyncResult)
                $job.PowerShell.Dispose()
            }
        }
        $jobs = $jobs | Where-Object { -not $_.AsyncResult.IsCompleted }
    } while ($jobs.Count -gt 0)

    # Nettoyage
    $runspacePool.Close()
    $runspacePool.Dispose()

    return $results | Where-Object Open
}




# FonctioRemove-Jobn pour calculer le reseau IP
function ConvertTo-CIDR {
    param (
        [string]$IPAddress,
        [int]$PrefixLength
    )

    # Convertir le prefixe en masque de sous-reseau binaire
    $binaryMask = ("1" * $PrefixLength).PadRight(32, "0")
    $maskBytes = $binaryMask -split "(.{8})" | Where-Object { $_ -ne "" } | ForEach-Object { [Convert]::ToInt32($_, 2) }

    # Convertir l'IP en octets
    $ipBytes = $IPAddress.Split('.') | ForEach-Object { [int]$_ }

    # Appliquer un ET logique pour obtenir l'adresse reseau
    $networkBytes = for ($i = 0; $i -lt 4; $i++) {
        $ipBytes[$i] -band $maskBytes[$i]
    }

    # Rejoindre les octets pour former l'adresse reseau
    $networkIP = $networkBytes -join '.'

    # Retourner le reseau au format CIDR
    return "$networkIP/$PrefixLength"
}

# Fonction pour lister les reseaux IP connectes a la machine
function Get-PrivateNetworks {
    <#
    .SYNOPSIS
        Liste les reseaux IP prives connectes au PC avec leurs prefixes et reseaux complets.

    .DESCRIPTION
        Cette fonction identifie les adresses IP attribuees aux interfaces reseau du systeme 
        et filtre uniquement celles qui appartiennent aux classes privees A, B ou C. Elle retourne
        le reseau calcule au format CIDR avec le prefixe.

    .OUTPUTS
        Retourne un tableau contenant les interfaces reseau, adresses IP, prefixes et reseaux CIDR.

    .EXAMPLE
        $networks = Get-PrivateNetworks
        Liste toutes les adresses IP privees avec leurs reseaux.

    .NOTES
        Compatible avec PowerShell 5.x.
    #>



    # Recuperation des interfaces reseau actives avec leurs IP
    $networkInterfaces = Get-NetIPAddress | Where-Object {
        $_.AddressFamily -eq 'IPv4' -and $_.IPAddress -match '\d+\.\d+\.\d+\.\d+' -and
        $_.IPAddress -notlike '169.254.*' # Exclut les adresses APIPA
    }

    # Filtrer uniquement les adresses IP privees selon les classes RFC 1918
    $privateIPs = $networkInterfaces | Where-Object {
        ($_).IPAddress -match '^10\.' -or           # Classe A
        ($_).IPAddress -match '^172\.(1[6-9]|2[0-9]|3[0-1])\.' -or # Classe B
        ($_).IPAddress -match '^192\.168\.'        # Classe C
    }

    # Ajouter le reseau CIDR a chaque resultat
    $privateIPs | ForEach-Object {
        [PSCustomObject]@{
            InterfaceAlias = $_.InterfaceAlias
            IPAddress      = $_.IPAddress
            PrefixLength   = $_.PrefixLength
            NetworkCIDR    = ConvertTo-CIDR -IPAddress $_.IPAddress -PrefixLength $_.PrefixLength
        }
    }
}


function Test-ValidIPv4 {
    param (
        [string]$ipAddress
    )
    
    # Regex pour validation IPv4 standard
    $ipv4Pattern = '^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$'
    
    # Vérification 1 : Format basique
    if (-not ($ipAddress -match $ipv4Pattern)) {
        return $false
    }
    
    # Vérification 2 : Plages réservées/localhost
    $octets = $ipAddress -split '\.'
    if ($octets[0] -eq '127') { return $false }  # Loopback
    if ($octets[0] -eq '0')   { return $false }   # Réseau réservé
    
    # Vérification 3 : Plages multicast/link-local
    if ($octets[0] -eq '224' -or $octets[0] -eq '239') { return $false }
    if ($octets[0] -eq '169' -and $octets[1] -eq '254') { return $false }
    
    return $true
}