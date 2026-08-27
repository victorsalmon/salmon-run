<#
.SYNOPSIS
    Hot-inject Zoho Books credentials into the api-proxy secrets bundle.
.DESCRIPTION
    Reads the current proxy_secrets_bundle from the running api-proxy container,
    fetches Zoho Books credentials from AWS Secrets Manager, merges them into the
    bundle, and performs a zero-downtime secret rotation using the canonical bundle
    name. Uses the same temp-secret rotation pattern as Start-SecretRotationEndpoint.
.PARAMETER Project
    Project name used for stack and service naming. Default: FRAD
.PARAMETER AwsSecretId
    AWS Secrets Manager secret ID containing Zoho credential keys. Default: Interclaw/FRAD/Provisioning
.PARAMETER AwsProfile
    AWS SSO profile name. Default: intersite
.PARAMETER StackServiceName
    Docker Swarm service name for api-proxy. Default: FRAD_is-api
.EXAMPLE
    .\Inject-ZohoBundle.ps1
    Default run — injects Zoho keys for FRAD project using intersite profile.
.EXAMPLE
    .\Inject-ZohoBundle.ps1 -Project MYPROJ -AwsProfile myprofile -StackServiceName MYPROJ_api-proxy
    Custom project and AWS profile.
#>
[CmdletBinding()]
param(
    [string]$Project = "FRAD",
    [string]$AwsSecretId = "Interclaw/FRAD/Provisioning",
    [string]$AwsProfile = "intersite",
    [string]$StackServiceName = "FRAD_is-api"
)

$ErrorActionPreference = "Stop"
$BundleName = "proxy_secrets_bundle"

Write-Host "=== Zoho Key Injector ===" -ForegroundColor Cyan

Write-Host "Finding api-proxy container..." -ForegroundColor Gray
$proxyId = docker ps --filter name=$StackServiceName --format '{{.ID}}'
if (-not $proxyId) {
    Write-Error "api-proxy container not found (service: $StackServiceName)"
    exit 1
}
Write-Host "  Container: $proxyId" -ForegroundColor Gray

Write-Host "Reading current bundle from api-proxy..." -ForegroundColor Gray
$bundleJson = docker exec $proxyId cat /run/secrets/secrets_bundle 2>&1
if ($LASTEXITCODE -ne 0 -or -not $bundleJson) {
    Write-Error "Failed to read secrets_bundle from container"
    exit 1
}
$bundle = $bundleJson | ConvertFrom-Json -AsHashtable

Write-Host "Fetching Zoho keys from AWS SM..." -ForegroundColor Gray
$awsBlob = aws secretsmanager get-secret-value --secret-id $AwsSecretId --profile $AwsProfile --query "SecretString" --output text 2>&1 | ConvertFrom-Json

Write-Host "Building new bundle..." -ForegroundColor Gray
$bundle.ZOHO_BOOKS_ID = $awsBlob.ZOHO_BOOKS_ID
$bundle.ZOHO_BOOKS_SECRET = $awsBlob.ZOHO_BOOKS_SECRET
$bundle.ZOHO_BOOKS_REFRESH = $awsBlob.ZOHO_BOOKS_REFRESH
$bundle.ZOHO_BOOKS_ORG_RENTALS = $awsBlob.ZOHO_BOOKS_ORG_RENTALS
$bundle.ZOHO_BOOKS_ORG_INTERSITE = $awsBlob.ZOHO_BOOKS_ORG_INTERSITE
$bundle.ZOHO_BOOKS_FWD_RENTALS = $awsBlob.ZOHO_BOOKS_FWD_RENTALS

Write-Host "Performing zero-downtime secret rotation..." -ForegroundColor Gray
$tempName = "${BundleName}_injecting"
try {
    $newJson = $bundle | ConvertTo-Json -Compress

    $prevOutputEncoding = $OutputEncoding
    $prevEncoding = [Console]::OutputEncoding
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
    $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $null = $newJson | docker secret create $tempName - 2>&1
    [Console]::OutputEncoding = $prevEncoding
    $OutputEncoding = $prevOutputEncoding
    if ($LASTEXITCODE -ne 0) { throw "Failed to create temp secret $tempName" }

    $null = docker service update --detach=false --secret-rm=$BundleName --secret-add="source=$tempName,target=secrets_bundle" $StackServiceName 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Failed to update service $StackServiceName with temp secret" }

    $null = docker secret rm $BundleName -ErrorAction SilentlyContinue 2>&1

    $prevOutputEncoding = $OutputEncoding
    $prevEncoding = [Console]::OutputEncoding
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
    $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $null = $newJson | docker secret create $BundleName - 2>&1
    [Console]::OutputEncoding = $prevEncoding
    $OutputEncoding = $prevOutputEncoding
    if ($LASTEXITCODE -ne 0) { throw "Failed to re-create secret $BundleName" }

    $null = docker service update --detach=false --secret-rm=$tempName --secret-add="source=$BundleName,target=secrets_bundle" $StackServiceName 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Failed to restore canonical secret on $StackServiceName" }

    $null = docker secret rm $tempName -ErrorAction SilentlyContinue 2>&1

    Write-Host "[DONE] api-proxy updated with Zoho keys" -ForegroundColor Cyan
} catch {
    Write-Warning "Rolling back..."
    $null = docker secret rm $tempName -ErrorAction SilentlyContinue 2>&1
    Write-Error "Failed: $_"
    exit 1
}
