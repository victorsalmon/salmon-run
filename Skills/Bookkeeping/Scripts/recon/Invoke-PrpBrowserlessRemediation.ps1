<#
.SYNOPSIS
    PRP Browserless Remediation — orchestrates all browser-based fallback functions.
.DESCRIPTION
    Wrapper for browserless-remediation.mjs. Accepts a remediation report
    (from PRP Steps 2-4) and executes all browser-based fixes for
    Plaid-immutable accounts using a single shared Zoho session.
.PARAMETER ReportPath
    Path to the remediation report JSON file.
.PARAMETER OrgName
    Organization name (e.g. "intersite-consulting", "room-rentals").
.PARAMETER AccountName
    Account name as used in reconciliation-periods.md.
.PARAMETER Local
    Run with local Playwright Chromium (dev mode). Default: docker exec.
.PARAMETER PassThru
    Return structured results instead of printing.
.EXAMPLE
    .\Invoke-PrpBrowserlessRemediation.ps1 -ReportPath remediation.json -Local
    .\Invoke-PrpBrowserlessRemediation.ps1 -ReportPath remediation.json
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$ReportPath,

    [Parameter()]
    [string]$OrgName,

    [Parameter()]
    [string]$AccountName,

    [Parameter()]
    [string]$OrgId,

    [switch]$Local,

    [switch]$PassThru
)

$ErrorActionPreference = "Stop"

if (-not $OrgId) {
    Write-Error "[PRP REMEDIATION] -OrgId is required. Pass the Zoho organization ID for this org."
    exit 1
}

$repoRoot = Resolve-Path "$PSScriptRoot\..\..\..\.."
$jsScriptDir = Join-Path $repoRoot "Infrastructure\Browserless\Sites\books.zoho.com"
$jsScript = Join-Path $jsScriptDir "browserless-remediation.mjs"

# Fetch Zoho credentials
Write-Information "[PRP REMEDIATION] Fetching credentials from AWS SM..." -Tags PRP
$profile = $env:AWS_SSO_PROFILE
if (-not $profile) { $profile = 'intersite' }
try {
    $secretsJson = aws secretsmanager get-secret-value --secret-id "Interclaw/FRAD/Provisioning" --profile $profile --region ca-central-1 --query "SecretString" --output text 2>$null
    if (-not $secretsJson) { throw "Empty response" }
    $secrets = $secretsJson | ConvertFrom-Json
} catch {
    Write-Error "Failed to fetch AWS SM secret. Ensure AWS SSO is active: aws sso login --profile intersite"
    exit 1
}

$env:ZOHO_EMAIL = $secrets.ZOHO_BOOKS_RWUSER
$env:ZOHO_PASS = $secrets.ZOHO_BOOKS_RWPASS
$env:BROWSERLESS_API_KEY = $secrets.BROWSERLESS_API_KEY
$env:ORG_ID = $OrgId
Write-Information "[PRP REMEDIATION] Using ORG_ID=$OrgId for OrgName=$OrgName" -Tags PRP

if ($ReportPath) {
    $env:REMEDIATION_INPUT = $ReportPath
    $inputArg = "--input `"$ReportPath`""
} else {
    $inputArg = ""
}

Write-Information "[PRP REMEDIATION] Running browserless remediation..." -Tags PRP

$resultOutput = ""

if ($Local) {
    if (-not (Test-Path -LiteralPath $jsScript)) {
        Write-Error "Script not found at $jsScript"
        exit 1
    }
    Push-Location -LiteralPath $jsScriptDir
    try {
        $resultOutput = node $jsScript 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
    } finally {
        Pop-Location
    }
} else {
    $volMount = (Resolve-Path $jsScriptDir).Path + ":/data"
    $dockerArgs = @(
        "run", "--rm", "-i", "--network", "service_net",
        "-e", "BROWSERLESS_API_KEY", "-e", "ZOHO_EMAIL", "-e", "ZOHO_PASS", "-e", "ORG_ID"
    )
    if ($ReportPath) {
        $reportVol = (Resolve-Path $ReportPath).Path + ":/data/remediation-report.json"
        $dockerArgs += @("-v", $reportVol)
    }
    $dockerArgs += @("-v", $volMount, "-w", "/data",
        "node:20-slim", "sh", "-c",
        "npm install playwright; node /data/browserless-remediation.mjs")
    Write-Information "[PRP REMEDIATION] Running: docker exec" -Tags PRP
    $resultOutput = & docker @dockerArgs 2>&1 | Out-String
    $exitCode = $LASTEXITCODE
}

Write-Information "[PRP REMEDIATION] Script exited with code $exitCode" -Tags PRP
Write-Output $resultOutput

if ($PassThru) {
    $jsonStart = $resultOutput.IndexOf('{')
    $jsonEnd = $resultOutput.LastIndexOf('}') + 1
    if ($jsonStart -ge 0 -and $jsonEnd -gt $jsonStart) {
        $json = $resultOutput.Substring($jsonStart, $jsonEnd - $jsonStart)
        return $json | ConvertFrom-Json
    }
}
