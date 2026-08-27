<#
.SYNOPSIS
    AWS SSO session management, credential hydration, IAM user creation, secret import, and sovereignty isolation tests for Interclaw.
#>
#Requires -Version 7.0

Set-StrictMode -Off

$script:ModuleRoot = $PSScriptRoot
$PublicPath = Join-Path $script:ModuleRoot 'Public'
if (Test-Path $PublicPath) {
    Get-ChildItem -Path $PublicPath -Filter '*.ps1' -Recurse | ForEach-Object {
        . $_.FullName
    }
}

Export-ModuleMember -Function @(
    'Initialize-AwsSsoSession',
    'Invoke-AgentCredentialTests',
    'Invoke-AgentOrchProvisioning',
    'Invoke-AgentProvisioningPipeline',
    'Invoke-AwsCli',
    'Invoke-AwsPreflight',
    'Invoke-BedrockProfileSetup',
    'Invoke-OrphanIamCleanup',
    'Invoke-SecretHydration',
    'Invoke-WithCredentialSwap',
    'New-AgentIamUser',
    'New-FleetIamUser',
    'New-RekognitionFallbackIamUser',
    'Read-ContainerSecretBundle',
    'Remove-AgentIamUser',
    'Test-AgentCredentialIsolation',
    'Test-AwsIamPermissions',
    'Test-AwsSessionValidity',
    'Test-CodingKeyPresence',
    'Test-FleetCredentialIsolation',
    'Test-SecretAvailability',
    'Test-Sovereignty'
)
