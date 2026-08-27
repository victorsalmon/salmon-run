<#
.SYNOPSIS
    PRP Step 4: Discover PDF bank statements in the account's statement folder.
.DESCRIPTION
    Scopes PDF search to the account-specific statement folder using PRP config's
    bank_statement_folder. Uses extract-statement-periods.py on statement PDFs only
    (named with convention Statement-*). Falls back to sidecar CSVs already parsed
    in Step 1 if no new PDFs found. Does NOT scan receipt dirs or other accounts.
.PARAMETER OrgName
    Organization name to narrow search scope.
.PARAMETER AccountName
    Account slug for statement folder targeting.
.PARAMETER SidecarPeriods
    Periods already parsed from reconciliation-periods.md in Step 1 (fallback).
.PARAMETER Token
    Zoho OAuth access token.
.PARAMETER Headers
    HTTP headers for API calls.
.PARAMETER OrgId
    Zoho organization ID.
.PARAMETER AccountId
    Zoho bank account ID.
.PARAMETER WhatIf
    Dry-run: log what would happen, don't execute.
.EXAMPLE
    Invoke-PrpStep4-DiscoverStatements.ps1 -OrgName "intersite-consulting" -AccountName "RBC-INTERSITE"
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$OrgName,

    [Parameter()]
    [string]$AccountName,

    [Parameter()]
    [array]$SidecarPeriods,

    [Parameter()]
    [string]$Token,

    [Parameter()]
    [hashtable]$Headers,

    [Parameter()]
    [string]$OrgId,

    [Parameter()]
    [string]$AccountId
)

$ErrorActionPreference = "Stop"
$stepNumber = 4
$stepName = "Discover PDF Statements"

Write-Progress -Activity "[PRP Step $stepNumber]" -Status $stepName

$scriptDir = Split-Path -Parent $PSCommandPath
$booksRoot = "$env:USERPROFILE\intersite-docs\Taxes and Bookkeeping\$OrgName"

# Load PRP config to find the account statement folder
. (Join-Path $scriptDir "Get-PrpConfig.ps1")
$prpCfg = Get-PrpConfig -OrgName $OrgName
$acctCfg = Get-PrpConfig -OrgName $OrgName -AccountName $AccountName

$stmtFolder = if ($acctCfg.bank_statement_folder) { $acctCfg.bank_statement_folder } else { $AccountName }

# Resolve the statement directory — try PRP config root, then fallback to conventions
$bsRoot = $prpCfg.org.bank_statements_root
$candidates = @(
    "$booksRoot\$bsRoot\$stmtFolder",
    "$booksRoot\2026 Filing\2026 Bank Statements\$stmtFolder",
    "$booksRoot\2026 Bank Statements\$stmtFolder"
)

$stmtDir = $null
foreach ($c in $candidates) {
    if (Test-Path -LiteralPath $c) { $stmtDir = $c; break }
}

if (-not $stmtDir) {
    # Broader fallback: search for any folder matching the stmt name
    $dirs = Get-ChildItem "$booksRoot\*Bank Statements*" -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending
    foreach ($d in $dirs) {
        $subDir = Join-Path $d.FullName $stmtFolder
        if (Test-Path -LiteralPath $subDir) { $stmtDir = $subDir; break }
    }
}

if ($WhatIfPreference) {
    Write-Information "[PRP STEP 4] WhatIf: would scan for statement PDFs in $stmtDir" -Tags PRP
    return [PSCustomObject]@{
        StepNumber        = $stepNumber
        Passed            = $true
        Details           = "WhatIf: PDF discovery skipped — would check $stmtDir"
        DiscoveredPeriods = @()
    }
}

# ---- Phase 1: Scan for statement PDFs (named with convention) ----
$foundPdfs = @()
$discoveredPeriods = @()
if ($stmtDir -and (Test-Path -LiteralPath $stmtDir)) {
    Write-Information "[PRP STEP 4] Scanning $stmtDir for statement PDFs" -Tags PRP

    # Only match statement-named PDFs, not generic receipt/invoice PDFs
    $statementPatterns = @(
        '*Statement-*.pdf',
        '*MasterCard Statement-*.pdf',
        '*Chequing Statement-*.pdf',
        '*Visa Statement-*.pdf'
    )
    foreach ($pattern in $statementPatterns) {
        $foundPdfs += Get-ChildItem -LiteralPath $stmtDir -Filter $pattern -ErrorAction SilentlyContinue
    }
    Write-Information "[PRP STEP 4] Found $($foundPdfs.Count) statement PDF(s) matching conventions" -Tags PRP

    # Also include CSV sidecar files as secondary source
    $sidecarCsvs = Get-ChildItem -LiteralPath $stmtDir -Filter "*.csv" | Where-Object {
        $_.Name -notmatch 'Zoho|Fiscal|enriched|dry-run|_archive'
    }
    Write-Information "[PRP STEP 4] Found $($sidecarCsvs.Count) sidecar CSV(s)" -Tags PRP

    # Try to extract period data from each statement PDF
    $extractScript = Join-Path $scriptDir "..\pdf\extract-statement-periods.py"
    if ($foundPdfs.Count -gt 0 -and (Test-Path -LiteralPath $extractScript)) {
        foreach ($pdf in $foundPdfs) {
            try {
                $json = & python $extractScript --pdf "$($pdf.FullName)" --json 2>$null
                $result = $json | ConvertFrom-Json -ErrorAction SilentlyContinue
                if ($result -and $result.period_end) {
                    $discoveredPeriods += [PSCustomObject]@{
                        period_end      = $result.period_end
                        closing_balance = [decimal]($result.closing_balance -or 0)
                        source_file     = $pdf.FullName
                        extracted_by    = "extract-statement-periods.py"
                    }
                    Write-Information "[PRP STEP 4] Extracted: $($result.period_end) = $($result.closing_balance) (from $($pdf.Name))" -Tags PRP
                }
            } catch {
                Write-Warning "[PRP STEP 4] extract-statement-periods.py failed on $($pdf.Name): $_"
            }
        }
    }

    # Fallback: if PDF extraction produced no periods, try parsing sidecar CSVs
    if ($discoveredPeriods.Count -eq 0 -and $sidecarCsvs.Count -gt 0) {
        Write-Information "[PRP STEP 4] PDF extraction yielded no periods — inferring from sidecar CSV filenames" -Tags PRP
        foreach ($csv in $sidecarCsvs) {
            if ($csv.BaseName -match '(\d{4}-\d{2}-\d{2})') {
                $endDateStr = $matches[1]
                $discoveredPeriods += [PSCustomObject]@{
                    period_end      = $endDateStr
                    closing_balance = [decimal]0
                    source_file     = $csv.FullName
                    extracted_by    = "sidecar-filename"
                }
            }
        }
    }

    # Deduplicate by period_end
    $discoveredPeriods = $discoveredPeriods | Sort-Object period_end -Unique
}

# ---- Phase 2: Fall back to sidecar periods from Step 1 ----
if ($discoveredPeriods.Count -eq 0 -and $SidecarPeriods -and $SidecarPeriods.Count -gt 0) {
    Write-Information "[PRP STEP 4] No PDF statements found — falling back to $($SidecarPeriods.Count) sidecar-derived periods from reconciliation-periods.md" -Tags PRP
    $discoveredPeriods = $SidecarPeriods | ForEach-Object {
        [PSCustomObject]@{
            period_end      = $_.end.ToString('yyyy-MM-dd')
            closing_balance = $_.closing_balance
            source_file     = "reconciliation-periods.md"
            extracted_by    = "sidecar-periods-fallback"
        }
    }
}

$detail = "$($discoveredPeriods.Count) period(s) discovered"
if ($stmtDir) { $detail += " from $stmtDir" }
if ($discoveredPeriods.Count -eq 0) { $detail += " — no periods found" }

Write-Information "[PRP STEP 4] $detail" -Tags PRP
Write-Progress -Activity "[PRP Step $stepNumber]" -Status $stepName -Completed

$passed = $discoveredPeriods.Count -gt 0
return [PSCustomObject]@{
    StepNumber        = $stepNumber
    Passed            = $passed
    Details           = $detail
    DiscoveredPeriods = $discoveredPeriods
    NextSteps         = @(
        $(if ($passed) { "Proceed to Step 5: Period / Fiscal Year Selection" }
          else { "Place bank statement PDFs in the account's statement folder, or verify sidecar CSVs exist" })
    )
}
