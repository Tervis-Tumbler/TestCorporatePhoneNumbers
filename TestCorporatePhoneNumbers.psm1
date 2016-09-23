#Requires -modules TwilioPowerShell, TwiMLPowerShell, TwilioTwimletPowerShell, TervisTwimlet, WebHookInboxPowerShell

$OutputDirectory = "\\tervis.prv\applications\Logs\Infrastructure\TestCorporatePhoneNumbers"

$CallHandlingApplicationStates = [PSCustomObject][Ordered]@{
    Name = "IdentityConfirmed"
    StateType = "EndState"
},[PSCustomObject][Ordered]@{
    Name = "IdentityWrong"
    StateType = "EndState"
},[PSCustomObject][Ordered]@{
    Name = "IdentityConfirmedWithVoice"
    StateType = "EndState"
},[PSCustomObject][Ordered]@{
    Name = "CaptureRecordingAndRedirect"
    StateType = "IntermediateState"
}

Function Get-CallHandlingApplicationStates {
    param (
        [Parameter(Mandatory)]$Name
    )

    $CallHandlingApplicationStates | 
    where Name -EQ $Name
}

Function Invoke-WebHookInboxResponder {
    [CMDLetBinding()]
    param (
        $WebHookInboxID
    )
    $LastCursor = Get-WebHookInboxContent -Order -created | 
    select -ExpandProperty items | 
    Add-Member -MemberType ScriptProperty -Name IDInt -Value {[int]$This.ID} -PassThru |
    sort IDInt -Descending | 
    select -First 1 -ExpandProperty IDInt

    if (-not $($LastCursor)) {$LastCursor = 0}

    while ($true) {
        $Response = Get-WebHookInboxContent -Since "id:$LastCursor"
        $LastCursor = $Response.last_cursor

        ForEach ($Item in $Response.Items) {
            $TwilioCallProperties = $Item.body | ConvertFrom-URLEncodedQueryStringParameterString
            $TestCorproatePhoneNumberProperties = $Item.query | ConvertFrom-URLEncodedQueryStringParameterString
            $CallHandlingApplicationState = Get-CallHandlingApplicationStates -Name $TestCorproatePhoneNumberProperties.CallHandlingApplicationStateName

            $OutputFilePath = "$OutputDirectory\$($TwilioCallProperties.Called)"
            New-Item -ItemType Directory -Force -Path $OutputFilePath | Out-Null

            if ($TwilioCallProperties.RecordingUrl) {
                Write-Verbose "Saving recording"
                $URI = [URI]$TwilioCallProperties.RecordingUrl
                Invoke-WebRequest -Uri $TwilioCallProperties.RecordingUrl -OutFile "$OutputFilePath\$(split-path $URI.LocalPath -Leaf).wav"
            }

            if ($CallHandlingApplicationState.StateType -eq "EndState") {
                Write-Verbose "Writing Log of end state of the call"
                [PSCustomObject][Ordered]@{
                    PhoneNumberTwilioFormat = $TwilioCallProperties.Called
                    UserResponseDateTime = $Item.created
                    EndState = $CallHandlingApplicationState.Name
                } | 
                ConvertTo-Json | 
                Out-File "$OutputFilePath\$($Item.created | get-date -Format -- FileDateTime).json"

                Write-Verbose "Reached an EndState, hanging up"
                New-WebHookInboxResponse -Headers @{"Content-Type"="text/xml"} -ItemID $item.id -body (
                    New-TwiMLResponse -InnerElements (
                        New-TwiMLHangup
                    )
                ).OuterXML
            }

            if ($CallHandlingApplicationState.Name -eq "CaptureRecordingAndRedirect") {
                Write-Verbose "CaptureRecordingAndRedirect"
                New-WebHookInboxResponse -Headers @{"Content-Type"="text/xml"} -ItemID $item.id -body (
                    New-TwiMLResponse -InnerElements (
                        New-TwiMLRedirect -Method Post -URL (
                            New-TervisTwimletMessageAndRedirectURL -Message "Thank you for confirming your use of this cell phone. Good bye." -URL (                               
                                New-TestCoropratePhoneNumberWebHookInboxURL -CallHandlingApplicationStateName IdentityConfirmedWithVoice
                            )
                        )
                    )
                ).OuterXML
            }               
        }
    }
}

Function Start-WebHookInboxResponderJob {
    param (
        $WebHookInboxID
    )
    if (Get-Job -Name WebHookInboxResponder -ErrorAction SilentlyContinue){ 
        Get-Job -Name WebHookInboxResponder | Stop-Job -PassThru | Remove-Job
    }
    Start-Job -Name WebHookInboxResponder -ScriptBlock {param($WebHookInboxID) Invoke-WebHookInboxResponder -WebHookInboxID $WebHookInboxID} -ArgumentList $WebHookInboxID | Out-Null
}

Function Get-ATTCompanyCellPhones {
    param (
        $PathToBasicWirelessUserInventoryReportCSV = $(Import-Clixml $env:USERPROFILE\PathToBasicWirelessUserInventoryReportCSV.txt)
    )
    get-content -path $PathToBasicWirelessUserInventoryReportCSV | 
    Select-Object -Skip 9 |
    Out-String |
    ConvertFrom-Csv |
    Add-Member -Name PhoneNumberTwilioFormat -MemberType ScriptProperty -Value {"+1" + $this."Wireless Number"} -PassThru |
    Add-Member -Name LastCommunicationTime -MemberType ScriptProperty -Value {
        "$OutputDirectory\$($this.PhoneNumberTwilioFormat)"
    } -PassThru |
    Add-Member -Name LastMessage -MemberType ScriptProperty -Value {"$OutputDirectory\$($this.PhoneNumberTwilioFormat)"} -PassThru
}

Function Test-CorporatePhoneNumbers {
    $TwilioPhoneNumberForOutBoundCall = Get-TwilioIncomingPhoneNumbers | 
    select -ExpandProperty incoming_phone_numbers | 
    select -ExpandProperty phone_number

    #$WebHookInboxResponse = New-WebHookInbox -Response_Mode wait
    #Set-WebHookInboxID -WebHookInboxID $WebHookInboxResponse.id
    #Start-WebHookInboxResponderJob -WebHookInboxID $WebHookInboxResponse.id
    
    $CompanyCellPhones = Get-ATTCompanyCellPhones | Where 'Wireless User Full Name' -Match "Chris Magnuson"

    ForEach ($CompanyCellPhone in $CompanyCellPhones) {
        New-TwilioCall -From $TwilioPhoneNumberForOutBoundCall -To $CompanyCellPhone.PhoneNumberTwilioFormat -Url (New-URLToConfirmPhoneStillInUseByPressing1AndSayingName)
    }
}

Function New-URLToConfirmPhoneStillInUseByPressing1AndSayingName {
    New-TwilioTwimletSimpleMenuURL -Message "Hello, This is a message from Tervis IT. Please press 1 to confirm you still use this company supplied cell phone." -Options (
        New-TwilioTwimletSimpleMenuOption -Digits 1 -Url (
            New-TervisTwimletMessageAndRecordURL -Message "Please say your name and then press any key" -Action (
                New-TestCoropratePhoneNumberWebHookInboxURL -CallHandlingApplicationStateName "CaptureRecordingAndRedirect"
            )
        )
    )
}

Function New-URLToConfirmPhoneStillInUseByPressing1 {
    New-TwilioTwimletSimpleMenuURL -Message "Hello, This is a message from Tervis IT. Please press 1 to confirm you still use this company supplied cell phone." -Options (
        New-TwilioTwimletSimpleMenuOption -Digits 1 -Url (
            New-TwilioTwimletSimpleMenuURL -Message "If you are $($CompanyCellPhone."Wireless User Full Name") please press 9. If not please press 1" -Options (
                (
                    New-TwilioTwimletSimpleMenuOption -Digits 9 -Url (
                        New-TervisTwimletMessageAndRedirectURL -Message "Thank you for confirming your use of this cell phone. Good bye." -URL (
                            New-TestCoropratePhoneNumberWebHookInboxURL -CallHandlingApplicationStateName IdentityConfirmed
                        )
                    )
                ) + (
                    New-TwilioTwimletSimpleMenuOption -Digits 1 -Url (
                        New-TervisTwimletMessageAndRedirectURL -Message "To prevent this phone from being suspended, please contact the Tervis Help Desk. Please ask them to update the record of who is using this phone. Good bye." -URL (
                            New-TestCoropratePhoneNumberWebHookInboxURL -CallHandlingApplicationStateName  IdentityWrong
                        )
                    )
                )
            )
        )
    )
}

Function New-TestCoropratePhoneNumberWebHookInboxURL {
    param (
        [ValidateSet("IdentityConfirmed","IdentityWrong","IdentityConfirmedWithVoice","CaptureRecordingAndRedirect")]
        $CallHandlingApplicationStateName
    )
    $QueryStringParamterString = [Ordered]@{
        ApplicationName = "TestCorporatePhoneNumbers"
        CallHandlingApplicationStateName = $CallHandlingApplicationStateName
    } | ConvertTo-URLEncodedQueryStringParameterString

    New-WebHookInboxAPIInputURL -QueryStringParamterString $QueryStringParamterString
}
