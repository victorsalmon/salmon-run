<#
.SYNOPSIS
    DEPRECATED — Use Invoke-Zoho.ps1 -Action Upload instead.
.DESCRIPTION
    This script is deprecated. It now delegates to Invoke-Zoho.ps1 -Action Upload.
    Kept for backward compatibility. Will be removed in a future cleanup pass.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet("intersite-consulting", "room-rentals")]
    [string]$Entity,
    [string]$ClientId,
    [string]$ClientSecret,
    [string]$RefreshToken,
    [string]$OrganizationId,
    [string]$AwsProfile = "intersite",
    [string]$ReceiptsBase = "$env:USERPROFILE\intersite-docs\Taxes and Bookkeeping",
    [switch]$DryRun,
    [switch]$Resume,
    [switch]$Force
)
Write-Warning "[DEPRECATED] Invoke-ZohoUpload.ps1 is deprecated. Use Invoke-Zoho.ps1 -Action Upload instead."
$params = @{
    Action       = "Upload"
    Entity       = $Entity
    AwsProfile   = $AwsProfile
    ReceiptsBase = $ReceiptsBase
    DryRun       = $DryRun.IsPresent
    Resume       = $Resume.IsPresent
    Force        = $Force.IsPresent
}
if ($ClientId) { $params.ClientId = $ClientId }
if ($ClientSecret) { $params.ClientSecret = $ClientSecret }
if ($RefreshToken) { $params.RefreshToken = $RefreshToken }
if ($OrganizationId) { $params.OrganizationId = $OrganizationId }
& (Join-Path $PSScriptRoot "..\Invoke-Zoho.ps1") @params
