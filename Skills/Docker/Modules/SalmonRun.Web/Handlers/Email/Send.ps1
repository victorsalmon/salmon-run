# Email.Send — email sending capability.
# Required keys: (no secrets required — uses environment-based SMTP configuration).
# Capabilities: email:send.

function Send-EmailMessage {
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'ConvertTo-SecureString -AsPlainText required for SMTP PSCredential')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$To,
        [Parameter(Mandatory)][string]$Subject,
        [Parameter(Mandatory)][string]$Body,
        [string[]]$Attachments
    )

    Test-WebCapability -RequiredCapability 'email:send'

    $smtpServer = $env:SMTP_SERVER
    $smtpPort = $env:SMTP_PORT -as [int]
    $smtpUser = $env:SMTP_USER
    $smtpPass = $env:SMTP_PASS
    $fromAddress = $env:SMTP_FROM

    if (-not $smtpServer -or -not $fromAddress) {
        return [pscustomobject]@{ Success = $false; StatusCode = 400; Message = "SMTP server or from address not configured" }
    }

    try {
        $mailParams = @{
            SmtpServer  = $smtpServer
            Port        = if ($smtpPort) { $smtpPort } else { 587 }
            From        = $fromAddress
            To          = $To
            Subject     = $Subject
            Body        = $Body
            BodyAsHtml  = $Body -match '</?\w+[^>]*>'
            UseSsl      = $true
            ErrorAction = 'Stop'
        }
        if ($smtpUser -and $smtpPass) {
            $mailParams.Credential = New-Object System.Management.Automation.PSCredential ($smtpUser, (ConvertTo-SecureString $smtpPass -AsPlainText -Force))
        }
        if ($Attachments -and $Attachments.Count -gt 0) {
            $mailParams.Attachments = $Attachments
        }

        Send-MailMessage @mailParams

        Write-WebAuditEntry -Capability 'email:send' -Action "Send-EmailMessage" -Context @{ To = $To; Subject = $Subject } -Result 'allow'

        return [pscustomobject]@{
            MessageId  = [guid]::NewGuid().ToString()
            SentAt     = [datetime]::UtcNow.ToString('o')
            Recipients = @($To)
        }
    }
    catch {
        Write-WebAuditEntry -Capability 'email:send' -Action "Send-EmailMessage" -Context @{ To = $To; Subject = $Subject } -Result 'deny'
        return [pscustomobject]@{ Success = $false; StatusCode = 500; Message = "Failed to send email: $_" }
    }
}
