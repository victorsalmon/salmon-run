<#
.SYNOPSIS
    PRP Step 0: Acquire Zoho OAuth token with persistent caching.
.DESCRIPTION
    Wraps Get-ZohoToken.ps1, accepts -OrgId and -OrgName, returns token
    and headers hashtable. Uses the persistent file cache so re-runs within
    55 minutes cost zero OAuth refreshes.
.PARAMETER OrgId
    Zoho organization ID.
.PARAMETER OrgName
    Logical org name for token cache scoping (e.g. "intersite-consulting").
.PARAMETER Token
    Pre-acquired token (skip acquisition if provided).
.PARAMETER Headers
    Pre-built headers (skip acquisition if provided).
.PARAMETER WhatIf
    Dry-run: log what would happen, don't execute.
.EXAMPLE
    Invoke-PrpStep0-TokenAcquisition.ps1 -OrgId "925048093" -OrgName "intersite-consulting"
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$OrgId,

    [Parameter()]
    [string]$OrgName,

    [Parameter()]
    [string]$Token,

    [Parameter()]
    [hashtable]$Headers
)

$ErrorActionPreference = "Stop"
$stepNumber = 0
$stepName = "Token Acquisition"

Write-Progress -Activity "[PRP Step $stepNumber]" -Status $stepName

if ($Token -and $Headers) {
    Write-Information "[PRP STEP 0] Token and headers already provided — skipping acquisition" -Tags PRP
    return [PSCustomObject]@{
        StepNumber = $stepNumber
        Passed     = $true
        Details    = "Token and headers already provided"
        NextSteps  = @()
        Token      = $Token
        Headers    = $Headers
    }
}

if ($WhatIfPreference) {
    Write-Information "[PRP STEP 0] WhatIf: would acquire token for OrgId=$OrgId OrgName=$OrgName" -Tags PRP
    return [PSCustomObject]@{
        StepNumber = $stepNumber
        Passed     = $true
        Details    = "WhatIf: token acquisition skipped"
        NextSteps  = @("Run without -WhatIf to acquire token")
        Token      = $null
        Headers    = $null
    }
}

$scriptDir = Split-Path -Parent $PSCommandPath
. (Join-Path $scriptDir "Get-ZohoToken.ps1")

try {
    $tokenResult = Get-ZohoToken -AccountName $OrgName -OrgId $OrgId
    $acquiredToken = $tokenResult.access_token
    $acquiredHeaders = @{
        Authorization  = "Zoho-oauthtoken $acquiredToken"
        "Content-Type" = "application/json"
    }
    $source = if ($tokenResult.from_cache) { "cache" } else { "fresh OAuth refresh" }

    Write-Information "[PRP STEP 0] Token acquired ($source)" -Tags PRP
    Write-Progress -Activity "[PRP Step $stepNumber]" -Status $stepName -Completed

    return [PSCustomObject]@{
        StepNumber = $stepNumber
        Passed     = $true
        Details    = "Token acquired from $source"
        NextSteps  = @("Proceed to Step 0.5: Plaid Detection")
        Token      = $acquiredToken
        Headers    = $acquiredHeaders
    }
}
catch {
    Write-Error "[PRP STEP 0] Token acquisition failed: $_"
    Write-Progress -Activity "[PRP Step $stepNumber]" -Status $stepName -Completed

    return [PSCustomObject]@{
        StepNumber = $stepNumber
        Passed     = $false
        Details    = "Token acquisition failed: $_"
        NextSteps  = @("Check Bookkeeping container is running", "Verify Zoho credentials in secret bundle", "Re-run with -Verbose for details")
        Token      = $null
        Headers    = $null
    }
}
