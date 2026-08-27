<#
.DEPRECATED
    This script is an ad-hoc diagnostic tool with no known automated callers.
    The key rotation lifecycle is now managed by Rotate-BundleSecret.ps1 and
    deploy.ps1 Phase 9 (Credential Isolation). Retained only for manual inspection.
    See docs/Reference/KeyRotation.md for the canonical rotation schedule.

.SYNOPSIS
    Checks age of all third-party keys stored in AWS Secrets Manager against rotation schedules.
.DESCRIPTION
    Reads the key rotation registry from docs/Reference/KeyRotation.md and queries
    AWS SM for each secret's creation date. Reports keys approaching their rotation deadline.
    Exits 1 if any key is past due, 0 otherwise.
.PARAMETER DaysBeforeExpiry
    Number of days before rotation deadline to trigger a warning (default 30).
.PARAMETER Profile
    AWS CLI profile name (default "interclaw").
.PARAMETER Region
    AWS region (default "ca-central-1").
.EXAMPLE
    .\Skills\Docker\Check-KeyAge.ps1 -DaysBeforeExpiry 14
#>
param(
    [int]$DaysBeforeExpiry = 30,
    [string]$Profile = "interclaw",
    [string]$Region = "ca-central-1"
)

$ErrorActionPreference = "Stop"
$rotations = @{
    "GITHUB_TOKEN_READALL"       = 90
    "GITHUB_TOKEN_PUSHSELECT"    = 90
    "TAVILY_API_KEY"             = 180
    "FIRECRAWL_API_KEY"          = 180
    "BROWSERLESS_API_KEY"        = 180
    "ATTIO_READ_KEY"             = 180
    "ATTIO_WRITE_KEY"            = 180
    "ATTIO_ARCHIVE_KEY"          = 180
    "HUNTER_API_KEY"             = 180
    "SMARTLEAD_API_KEY"          = 180
    "APOLLO_SEARCH"              = 180
    "APOLLO_ENRICH"              = 180
    "ZEROBOUNCE_API_KEY"         = 180
    "GOCARDLESS_PAY_READ"        = 365
    "GOCARDLESS_PAY_RW"          = 365
    "GCP_SERVICE_SECRET"         = 365
    "TAILSCALE_KEY"              = 90
    "OPENCODE_GO1_KEY"           = 90
    "OPENCODE_GO2_KEY"           = 90
    "OPENCODE_GO3_KEY"           = 90
    "OPENCODE_GO4_KEY"           = 90
    "OPENCODE_GO5_KEY"           = 90
    "DOCUSIGN_SMTP_HOST"         = 180
    "DOCUSIGN_SMTP_PASS"         = 180
    "WAVE_CLIENT_ID"             = 365
    "WAVE_CLIENT_SECRET"         = 365
    "WAVE_ACCESS_TOKEN"          = 365
}

$secretsToCheck = @(
    @{Id = "Interclaw/FRAD/Provisioning"; Keys = @("TAVILY_API_KEY", "FIRECRAWL_API_KEY", "BROWSERLESS_API_KEY")}
    @{Id = "Interclaw/FRAD/Orchestrator"; Keys = @("GITHUB_TOKEN_READALL", "GITHUB_TOKEN_PUSHSELECT", "OPENCODE_GO1_KEY", "OPENCODE_GO2_KEY", "OPENCODE_GO3_KEY", "OPENCODE_GO4_KEY", "OPENCODE_GO5_KEY", "GCP_SERVICE_SECRET")}
    @{Id = "Intersite/FRAD/Proxy"; Keys = @("ATTIO_READ_KEY", "ATTIO_WRITE_KEY", "ATTIO_ARCHIVE_KEY", "HUNTER_API_KEY", "SMARTLEAD_API_KEY", "APOLLO_SEARCH", "APOLLO_ENRICH", "ZEROBOUNCE_API_KEY", "WAVE_CLIENT_ID", "WAVE_CLIENT_SECRET", "WAVE_ACCESS_TOKEN")}
    @{Id = "Interclaw/FRAD/Tailscale"; Keys = @("TAILSCALE_KEY")}
    @{Id = "Intersite/FRAD/Bookkeeper"; Keys = @("GOCARDLESS_PAY_READ", "GOCARDLESS_PAY_RW")}
    @{Id = "Interclaw/FRAD/Docusign"; Keys = @("DOCUSIGN_SMTP_HOST", "DOCUSIGN_SMTP_PASS")}
)

$today = Get-Date
$exitCode = 0
$warnings = @()

Write-Host "Checking key ages against rotation schedules..."
Write-Host "Warning threshold: $DaysBeforeExpiry days before rotation deadline"
Write-Host ""

foreach ($secret in $secretsToCheck) {
    try {
        $result = aws secretsmanager get-secret-value --secret-id $secret.Id --profile $Profile --region $Region --output json 2>&1 | ConvertFrom-Json
        foreach ($key in $secret.Keys) {
            $rotationDays = $rotations[$key]
            if (-not $rotationDays) { continue }
            $creationDateStr = $result.CreatedDate
            if (-not $creationDateStr) {
                Write-Warning "  ${key}: no creation date available"
                continue
            }
            $creationDate = if ($creationDateStr -is [datetime]) { $creationDateStr } else { [datetime]::Parse($creationDateStr) }
            $deadline = $creationDate.AddDays($rotationDays)
            $daysUntilExpiry = [math]::Floor(($deadline - $today).TotalDays)
            $daysSinceCreation = [math]::Floor(($today - $creationDate).TotalDays)
            $agePct = [math]::Round(($daysSinceCreation / $rotationDays) * 100, 0)
            if ($daysUntilExpiry -le 0) {
                Write-Host "  [OVERDUE] $key — created $($creationDate.ToString('yyyy-MM-dd')), rotation $rotationDays days, $([math]::Abs($daysUntilExpiry)) day(s) past deadline" -ForegroundColor Red
                $exitCode = 1
                $warnings += $key
            } elseif ($daysUntilExpiry -le $DaysBeforeExpiry) {
                Write-Host "  [WARN] $key — created $($creationDate.ToString('yyyy-MM-dd')), ${agePct}% of ${rotationDays}d rotation ($daysUntilExpiry day(s) remaining)" -ForegroundColor Yellow
                $warnings += $key
            } else {
                Write-Host "  [OK] $key — created $($creationDate.ToString('yyyy-MM-dd')), ${agePct}% of ${rotationDays}d rotation ($daysUntilExpiry day(s) remaining)" -ForegroundColor Green
            }
        }
    } catch {
        Write-Warning "  Could not read $($secret.Id): $_"
    }
}

if ($warnings.Count -gt 0) {
    Write-Host ""
    Write-Host "$($warnings.Count) key(s) need attention. See docs/Reference/KeyRotation.md for rotation procedures." -ForegroundColor Yellow
} else {
    Write-Host ""
    Write-Host "All keys are within rotation schedule." -ForegroundColor Green
}

exit $exitCode
