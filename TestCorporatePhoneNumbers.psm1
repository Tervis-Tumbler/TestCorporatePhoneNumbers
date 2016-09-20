#Requires -modules TwilioPowerShell, TwiMLPowerShell, TwilioTwimletPowerShell, TervisTwimlet, WebHookInboxPowerShell

$OutputDirectory = "\\tervis.prv\applications\Logs\Infrastructure\TestCorporatePhoneNumbers"

Function Invoke-WebHookInboxResponder {
    param (
        $WebHookInboxID
    )
    $LastCursor = 0

    while ($true) {
        $Response = Get-WebHookInboxContent -Since "id:$LastCursor"
        $LastCursor = $Response.last_cursor

        ForEach ($Item in $Response.Items) {
            $TwilioCallProperties = $Item.body | ConvertFrom-URLEncodedQueryStringParameterString
            $TestCorproatePhoneNumberProperties = $Item.query | ConvertFrom-URLEncodedQueryStringParameterString

            $OutputFilePath = "$OutputDirectory/$($TwilioCallProperties.Called)/"
            New-Item -ItemType Directory -Force -Path $OutputFilePath | Out-Null

            [PSCustomObject][Ordered]@{
                PhoneNumberTwilioFormat = $TwilioCallProperties.Called
                UserResponseDateTime = $Item.created
                MessageType = $TestCorproatePhoneNumberProperties.MessageType
            } | ConvertTo-Json | Out-File "$OutputFilePath/$($Item.created | get-date -Format -- FileDateTime).json"

            New-WebHookInboxResponse -Headers @{"Content-Type"="text/plain"} -ItemID $item.id -body (
                New-TwiMLResponse -InnerElements (
                    New-TwiMLHangup
                )
            ).OuterXML
        }
    }
}

Function Start-WebHookInboxResponderJob {
    param (
        $WebHookInboxID
    )
    if (Get-Job -Name WebHookInboxResponder){ 
        Get-Job -Name WebHookInboxResponder | Stop-Job -PassThru | Remove-Job
    }
    Start-Job -Name WebHookInboxResponder -ScriptBlock {param($WebHookInboxID) Invoke-WebHookInboxResponder -WebHookInboxID $WebHookInboxID} -ArgumentList $WebHookInboxID
}

Function Get-ATTCompanyCellPhones {
    param (
        $PathToBasicWirelessUserInventoryReportCSV = $(Import-Clixml $env:USERPROFILE\PathToBasicWirelessUserInventoryReportCSV.txt)
    )
    get-content -path $PathToBasicWirelessUserInventoryReportCSV | 
    Select-Object -Skip 9 |
    Out-String |
    ConvertFrom-Csv |
    Add-Member -Name PhoneNumberTwilioFormat -MemberType ScriptProperty -Value {"+1" + $this."Wireless Number"} -PassThru
}

Function Test-CorporatePhoneNumbers {
    $TwilioPhoneNumberForOutBoundCall = Get-TwilioIncomingPhoneNumbers | 
    select -ExpandProperty incoming_phone_numbers | 
    select -ExpandProperty phone_number

    $WebHookInboxResponse = New-WebHookInbox -Response_Mode wait
    Set-WebHookInboxID -WebHookInboxID $WebHookInboxResponse.id
    Start-WebHookInboxResponderJob -WebHookInboxID $WebHookInboxResponse.id
    
    $CompanyCellPhones = Get-ATTCompanyCellPhones | Where 'Wireless User Full Name' -Match "Chris Magnuson"

    ForEach ($CompanyCellPhone in $CompanyCellPhones) {
        $URLToConfirmPhoneStillInUse = New-TwilioTwimletSimpleMenuURL -Message "Hello, This is a message from Tervis IT. Please press 1 to confirm you still use this company supplied cell phone." -Options (
            New-TwilioTwimletSimpleMenuOption -Digits 1 -Url (
                New-TwilioTwimletSimpleMenuURL -Message "If you are $($CompanyCellPhone."Wireless User Full Name") please press 9. If not please press 1" -Options (
                    (
                        New-TwilioTwimletSimpleMenuOption -Digits 9 -Url (
                            New-TervisTwimletMessageAndRedirectURL -Message "Thank you for confirming your use of this cell phone. Good bye." -URL (
                                New-TestCoropratePhoneNumberWebHookInboxURL -EndCallState IdentityConfirmed
                            )
                        )
                    ) + (
                        New-TwilioTwimletSimpleMenuOption -Digits 1 -Url (
                            New-TervisTwimletMessageAndRedirectURL -Message "To prevent this phone from being suspended, please contact the Tervis Help Desk. Please ask them to update the record of who is using this phone. Good bye." -URL (
                                New-TestCoropratePhoneNumberWebHookInboxURL -EndCallState  IdentityWrong
                            )
                        )
                    )
                )
            )
        )

        New-TwilioCall -From $TwilioPhoneNumberForOutBoundCall -To $CompanyCellPhone.PhoneNumberTwilioFormat -Url $URLToConfirmPhoneStillInUse
    }
}


Function New-TestCoropratePhoneNumberWebHookInboxURL {
    param (
        [ValidateSet("IdentityConfirmed","IdentityWrong")]$EndCallState
    )
    New-WebHookInboxAPIInputURL -QueryStringParamterString "ApplicationName=TestCorporatePhoneNumbers&MessageType=$EndCallState"
}
