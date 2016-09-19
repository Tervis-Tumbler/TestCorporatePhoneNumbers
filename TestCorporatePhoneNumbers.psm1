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
            $Item | ConvertTo-Json | Out-File "$OutputDirectory/$($item.id).json"
            New-WebHookInboxResponse -Headers @{"Content-Type"="text/plain"} -ItemID $item.id -body (
                New-TwiMLResponse -InnerElements (
                    New-TwiMLHangup
                )
            ).OuterXML
        }
    }
}

Function Test-CorporatePhoneNumbers {
    $TwilioPhoneNumberForOutBoundCall = Get-TwilioIncomingPhoneNumbers | 
    select -ExpandProperty incoming_phone_numbers | 
    select -ExpandProperty phone_number

    $WebHookInboxResponse = New-WebHookInbox -Response_Mode wait
    Set-WebHookInboxID -WebHookInboxID $WebHookInboxResponse.id
    Start-Job -ScriptBlock {param($WebHookInboxID) Invoke-WebHookInboxResponder -WebHookInboxID $WebHookInboxID} -ArgumentList $($WebHookInboxResponse.id)

    ForEach ($CompanyCellPhone in $CompanyCellPhones) {
        $URLToConfirmPhoneStillInUse = New-TwilioTwimletSimpleMenuURL -Message "Hello, This is a message from Tervis IT. Please press 1 to confirm you still use this company supplied cell phone." -Options (
            New-TwilioTwimletSimpleMenuOption -Digits 1 -Url (
                New-TwilioTwimletSimpleMenuURL -Message "If you are $($CompanyCellPhone.EmployeeName) please press 9. If not please press 1" -Options (
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

        New-TwilioCall -From $TwilioPhoneNumberForOutBoundCall -To $CompanyCellPhone.CellPhoneNumber -Url $URLToConfirmPhoneStillInUse
    }

    New-TwilioCall -From $TwilioPhoneNumberForOutBoundCall -To $CompanyCellPhone.CellPhoneNumber -Url (
        New-TervisTwimletMessageAndRedirectURL -Message "Thank you for confirming your use of this cell phone. Good bye." -URL (
            New-TestCoropratePhoneNumberWebHookInboxURL -EndCallState IdentityConfirmed
        )
    )

    ForEach ($CompanyCellPhone in $CompanyCellPhones) {

        New-WebHookInboxAPIInputURL -QueryStringParamterString "ApplicationName=TestCorporatePhoneNumbers&MessageType=IdentityConfirmed"
        $MessageURLThankYouForConfirming = New-TwilioTwimletMessageURL -Messages "Thank you for confirming your use of this cell phone. Good bye."


        $TwiMLXMLDocument = New-TwiMLXMLDocument -InnerElements $(
            New-TwiMLResponse -InnerElements $(
                $(New-TwiMLSay -Message "This is a test"),
                $(New-TwiMLRedirect -Method post `
                    -URL $(New-WebHookInboxAPIInputURL -QueryStringParamterString "ApplicationName=TestCorporatePhoneNumbers&MessageType=StatusCallback")
                )
            )
        )

        New-TwilioCall -From $TwilioPhoneNumberForOutBoundCall -To $CompanyCellPhone.CellPhoneNumber -Url $(New-TwilioTwimletEcho -Twiml $TwiMLXMLDocument.OuterXML)

    
    }

}


Function New-TestCoropratePhoneNumberWebHookInboxURL {
    param (
        [ValidateSet("IdentityConfirmed","IdentityWrong")]$EndCallState
    )
    New-WebHookInboxAPIInputURL -QueryStringParamterString "ApplicationName=TestCorporatePhoneNumbers&MessageType=$EndCallState"
}
