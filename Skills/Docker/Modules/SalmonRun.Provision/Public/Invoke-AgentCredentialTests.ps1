<#
.SYNOPSIS
Runs AWS credential isolation tests for each agent in the fleet.
#>
function Invoke-AgentCredentialTests {
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'ConvertTo-SecureString -AsPlainText required for credential testing')]
    [OutputType([void])]
    param(
        [pscustomobject]$AgentContext,
        [string]$SsoProfile
    )
    Write-SetupLog "AwsTest started ($($AgentContext.RoleCode))"
    Write-Verbose "  --- AWS CREDENTIAL ISOLATION TEST ($($AgentContext.RoleCode)) ---"

    $CredentialResults = @()

    $IamUserName = "$($AgentContext.ProjectCode)-$($AgentContext.RoleCode)-$($AgentContext.InstanceId)"
    $AgentCreds = @{
        AccessKeyId = $env:AWS_ACCESS_KEY_ID
        IamUserName = $IamUserName
    }

    $BundleName = "$($AgentContext.SecretPrefix)_secrets_bundle"
    $ServiceName = "$($AgentContext.ProjectCode)_oc-$($AgentContext.RoleCode.ToLower())"
    $BundleData = Read-ContainerSecretBundle -BundleName $BundleName -ServiceName $ServiceName
    if ($BundleData.aws_id -and $BundleData.aws_secret) {
        $AgentVerify = Test-AgentCredentialIsolation -AgentAccessKeyId (ConvertTo-SecureString $BundleData.aws_id -AsPlainText -Force) -AgentSecretAccessKey (ConvertTo-SecureString $BundleData.aws_secret -AsPlainText -Force) -IamUserName $IamUserName
        $CredentialResults += $AgentVerify
    }

    if ($AgentContext.RoleCode -eq "ORCH") {
        $FleetServiceName = "$($AgentContext.ProjectCode)_fleet"
        $FleetData = Read-ContainerSecretBundle -BundleName "fleet_secrets_bundle" -ServiceName $FleetServiceName
        if ($FleetData.fleet_aws_id -and $FleetData.fleet_aws_secret) {
            $FleetVerify = Test-FleetCredentialIsolation -FleetAccessKeyId (ConvertTo-SecureString $FleetData.fleet_aws_id -AsPlainText -Force) -FleetSecretAccessKey (ConvertTo-SecureString $FleetData.fleet_aws_secret -AsPlainText -Force) -FleetIamUserName "$($AgentContext.ProjectCode)-FLEET"
            $CredentialResults += $FleetVerify
        }
    }

    $AnyFailures = $CredentialResults | Where-Object { -not $_.Passed }
    if ($AnyFailures) {
        Write-Warning "`n[CRITICAL] Credential isolation verification failed. Aborting."
        foreach ($Fail in $AnyFailures) {
            foreach ($Msg in $Fail.Failures) {
                Write-Warning "  - $Msg"
            }
        }
        throw "Credential isolation test failed for $($AgentContext.RoleCode)-$($AgentContext.InstanceId)"
    }

    Write-SetupLog "AwsTest complete"
}
