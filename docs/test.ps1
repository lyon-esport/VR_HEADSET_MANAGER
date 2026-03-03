$UserMessages = DATA
{    ConvertFrom-StringData @'

    # English strings

        Msg1 = "Enter a name."
        Msg2 = "Enter your employee ID."
        Msg3 = "Enter your building number."
'@
}
$UserMessages.Msg1
Write-Host $PSUICulture
Import-LocalizedData -BindingVariable "UserMessages" -ErrorAction:SilentlyContinue
$UserMessages.Msg1
Pause