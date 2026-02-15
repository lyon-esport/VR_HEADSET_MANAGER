
 # install Pode module if not already installed
 if (-not (Get-Module -ListAvailable -Name Pode)) {
     Install-Module -Name Pode -Scope CurrentUser -Force
 } 
 else {
    Import-Module pode
 }
function Start-WebServer {
    $port = 8080

    # Define the web page HTML
    $html = @"
<!DOCTYPE html>
<html>
<head>
    <title>Webserver Test</title>
</head>
<body>
    <h1>Webserver Test Page</h1>
    <form method="POST" action="/create-file">
        <button type="submit">Create Log File Entry</button>
    </form>
</body>
</html>
"@

    # Start the Pode server
    Start-PodeServer -Port $port -ScriptBlock {
        # Route for the main page
        Add-PodeRoute -Method Get -Path '/' -ScriptBlock {
            Write-PodeHtmlResponse -Value $using:html
        }

        # Route for the button POST
        Add-PodeRoute -Method Post -Path '/create-file' -ScriptBlock {
            $filePath = Join-Path $PSScriptRoot 'test_webserver.txt'
            $time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            $entry = "Log entry at $time`r`n"

            if (!(Test-Path $filePath)) {
                Set-Content -Path $filePath -Value $entry
            } else {
                Add-Content -Path $filePath -Value $entry
            }

            # Redirect back to main page
            Write-PodeRedirect -Location '/'
        }
    }
}

# To start the server, call:
 Start-WebServer

Show-PodeGui -Title 'MyApplication' -WindowState 'Maximized'


Start-PodeServer {
    Add-PodeEndpoint -Address localhost -Port 8080 -Protocol Http

    Add-PodeRoute -Method Get -Path '/ping' -ScriptBlock {
        Write-PodeJsonResponse -Value @{ 'value' = 'pong' }
    }
}

https://badgerati.github.io/Pode/Tutorials/Routes/Examples/WebPages/#basics
# Need to allow powershell in windows firewall
# Set-NetFirewallRule -DisplayName "Windows PowerShell" -Enabled True

Start-PodeServer {
    Add-PodeEndpoint -Address * -Port 8080 -Protocol Http

    Add-PodeRoute -Method Get -Path '/' -ScriptBlock {
        Write-PodeViewResponse -Path 'index'
    }

    Add-PodeRoute -Method Get -Path '/about' -ScriptBlock {
        Write-PodeViewResponse -Path 'about'
    }
}