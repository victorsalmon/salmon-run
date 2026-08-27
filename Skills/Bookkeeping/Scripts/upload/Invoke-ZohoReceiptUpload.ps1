#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
    DEPRECATED — Use Invoke-Zoho.ps1 -Action ReceiptUpload instead.
.DESCRIPTION
    This script is deprecated. It now delegates to Invoke-Zoho.ps1 -Action ReceiptUpload.
    Kept for backward compatibility. Will be removed in a future cleanup pass.
.PARAMETER Entity
    Entity name from cloud-books-entities.json.
.PARAMETER ManifestPath
    Path to the manifest CSV file.
.PARAMETER AwsProfile
    AWS CLI profile for SM lookup.
.PARAMETER DryRun
    Print what would be done without making API calls.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet("intersite-consulting", "room-rentals")]
    [string]$Entity,
    [string]$ManifestPath,
    [string]$AwsProfile = "intersite",
    [switch]$DryRun
)
Write-Warning "[DEPRECATED] Invoke-ZohoReceiptUpload.ps1 is deprecated. Use Invoke-Zoho.ps1 -Action ReceiptUpload instead."
$params = @{
    Action     = "ReceiptUpload"
    Entity     = $Entity
    AwsProfile = $AwsProfile
    DryRun     = $DryRun.IsPresent
}
if ($ManifestPath) { $params.ManifestPath = $ManifestPath }
& (Join-Path $PSScriptRoot "..\Invoke-Zoho.ps1") @params
