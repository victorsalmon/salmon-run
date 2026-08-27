<#
.SYNOPSIS
    Runs orchestrator-level provisioning: IAM cleanup, Fleet IAM, rekognition-fallback IAM.
#>
function Invoke-AgentOrchProvisioning {
    [OutputType([void])]
    param(
        [pscustomobject]$AgentContext,
        [string]$SsoProfile,
        [string]$SovereigntyTier,
        [string]$SecretsRegion,
        [string[]]$AllInstanceIds
    )
    Write-SetupLog "AwsOrch started"
    Write-Verbose "  --- AWS ORCHESTRATOR INFRASTRUCTURE ---"

    if ($SsoProfile) { Set-Item -Path "Env:\AWS_SSO_PROFILE" -Value $SsoProfile }

    $null = New-FleetIamUser -AgentContext $AgentContext
    Invoke-OrphanIamCleanup -AgentContext $AgentContext -AdditionalProtectedInstanceIds $AllInstanceIds
    $photoResult = New-RekognitionFallbackIamUser -AgentContext $AgentContext
    if ($photoResult.AccessKeyId -and $photoResult.SecretAccessKey) {
        Set-Item -Path "Env:\PROXY_AWS_ACCESS_KEY_ID" -Value $photoResult.AccessKeyId
        Set-Item -Path "Env:\PROXY_AWS_SECRET_ACCESS_KEY" -Value $photoResult.SecretAccessKey
        # Persist to AWS SM so the proxy bundle builder can find them
        # via the standard AWS SM fallback (Docker Desktop's Swarm secret
        # volume mounts create empty dirs, not files).
        $smPairs = @(
            @{N='PROXY_AWS_ACCESS_KEY_ID'; V=$photoResult.AccessKeyId},
            @{N='PROXY_AWS_SECRET_ACCESS_KEY'; V=$photoResult.SecretAccessKey}
        )
        $smProfile = $env:AWS_SSO_PROFILE
        $smRegion = $SecretsRegion
        foreach ($p in $smPairs) {
            $r = Invoke-AwsCommand { aws secretsmanager create-secret --name $p.N --secret-string $p.V --profile $smProfile --region $smRegion 2>&1 }
            if (-not $r.Success) {
                $null = Invoke-AwsCommand { aws secretsmanager put-secret-value --secret-id $p.N --secret-string $p.V --profile $smProfile --region $smRegion 2>&1 }
            }
        }
        Write-SetupLog "Rekognition-fallback AWS keys persisted to AWS SM" -Level INFO
    }

    Write-SetupLog "AwsOrch complete"
}
