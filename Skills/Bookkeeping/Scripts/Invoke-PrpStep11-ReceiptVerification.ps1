<#
.SYNOPSIS
    PRP Step 11: Receipt Verification — bidirectional sync between Zoho and local receipts.
.DESCRIPTION
    Three-phase receipt health check per account:

    Phase A — Discovery: Scans local receipt directories for new files, updates manifest.
    Phase B — Zoho→Local: Downloads Zoho receipts missing locally, updates manifests.
    Phase C — Local→Zoho: Uploads local receipts to matching Zoho expenses (categorized only).

    Phase D is a documentation note only: Zoho's email-to-receipt endpoint exists
    for auto-matching but is not yet implemented.

    Idempotent — safe to re-run. Each phase reports added/updated/skipped counts.
.PARAMETER OrgName
    Organization name (e.g. "intersite-consulting", "room-rentals").
.PARAMETER AccountName
    Account slug (e.g. "MC-6258", "RBC-INTERSITE").
.PARAMETER AllExpenses
    All Zoho expenses from the pipeline's bulk fetch.
.PARAMETER ZohoAll
    All Zoho bank transactions from the pipeline's bulk fetch.
.PARAMETER Token
    Zoho OAuth access token.
.PARAMETER Headers
    HTTP headers for API calls.
.PARAMETER OrgId
    Zoho organization ID.
.PARAMETER AccountId
    Zoho bank account ID.
.PARAMETER IsPlaidImmutable
    Whether the account is Plaid-immutable (affects upload strategy).
.PARAMETER WhatIf
    Dry-run: log what would happen, don't execute.
.EXAMPLE
    Invoke-PrpStep11-ReceiptVerification.ps1 -OrgName "intersite-consulting" -AccountName "MC-6258" -AllExpenses $expenses -ZohoAll $txns
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$OrgName,

    [Parameter(Mandatory)]
    [string]$AccountName,

    [Parameter()]
    [array]$AllExpenses,

    [Parameter()]
    [array]$ZohoAll,

    [Parameter()]
    [string]$Token,

    [Parameter()]
    [hashtable]$Headers,

    [Parameter()]
    [string]$OrgId,

    [Parameter()]
    [string]$AccountId,

    [Parameter()]
    [bool]$IsPlaidImmutable = $false
)

$ErrorActionPreference = "Stop"
$stepNumber = 11
$stepName = "Receipt Verification"

Write-Progress -Activity "[PRP Step $stepNumber]" -Status $stepName

$scriptDir = Split-Path -Parent $PSCommandPath
$repoRoot = Resolve-Path "$scriptDir\..\..\.."
$booksRoot = "$env:USERPROFILE\intersite-docs\Taxes and Bookkeeping\$OrgName"

# Load PRP config
. (Join-Path $scriptDir "Get-PrpConfig.ps1")
$prpCfg = Get-PrpConfig -OrgName $OrgName
$acctCfg = Get-PrpConfig -OrgName $OrgName -AccountName $AccountName

# Resolve receipt dirs from PRP config or fall back to conventions
$stmtFolder = if ($acctCfg.bank_statement_folder) { $acctCfg.bank_statement_folder } else { $AccountName }
$possibleReceiptRoots = @(
    "$booksRoot\2026 Filing\2026 Receipts",
    "$booksRoot\2026 Receipts"
)
$receiptRoot = $null
foreach ($rr in $possibleReceiptRoots) {
    if (Test-Path -LiteralPath $rr) { $receiptRoot = $rr; break }
}

# Map account slug to manifest account prefix
$manifestAccounts = @{
    "RBC-INTERSITE" = "intersite-rbc-chequing"
    "MC-6258"       = "intersite-mc-6258"
}
$manifestAcct = $manifestAccounts[$AccountName]
$acctReceiptDir = if ($receiptRoot -and $manifestAcct) { Join-Path $receiptRoot $manifestAcct } else { $null }

# Find manifests (main _manifest.csv + optional account-specific)
$globalManifest = Join-Path $receiptRoot "_manifest.csv"
$acctManifest = Join-Path $booksRoot "2026 Filing\rbc-6258-manifest.csv"

# ---- Phase A: Receipt Discovery & Manifest Update ----
function Invoke-PhaseA {
    Write-Information "[PRP STEP 11-A] Receipt Discovery — scanning $acctReceiptDir" -Tags PRP

    $discovered = @()
    $existingManifestRows = @()
    $addedCount = 0

    if (-not $acctReceiptDir -or -not (Test-Path -LiteralPath $acctReceiptDir)) {
        Write-Warning "[PRP STEP 11-A] No receipt directory found for $AccountName — skipping discovery"
        return @{ Discovered = @(); Added = 0; TotalLocal = 0 }
    }

    # Read existing global manifest rows for this account
    if (Test-Path -LiteralPath $globalManifest) {
        $allRows = Import-Csv -LiteralPath $globalManifest
        $existingManifestRows = $allRows | Where-Object { $_.account -eq $manifestAcct }
        Write-Information "[PRP STEP 11-A] Existing manifest has $($existingManifestRows.Count) entries for $manifestAcct" -Tags PRP
    }

    # Scan local receipt files
    $localFiles = Get-ChildItem -LiteralPath $acctReceiptDir -File | Where-Object { $_.Extension -match '\.(pdf|jpg|jpeg|png|gif|tiff?)$' }
    $existingHashes = @{}
    foreach ($row in $existingManifestRows) {
        if ($row.sha256) { $existingHashes[$row.sha256.Trim()] = $true }
    }

    $prevCount = $existingManifestRows.Count
    foreach ($file in $localFiles) {
        try {
            $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLower()
        } catch {
            Write-Warning "[PRP STEP 11-A] Could not hash $($file.Name): $_"
            continue
        }
        if (-not $existingHashes.ContainsKey($hash)) {
            $discovered += @{
                FileName = $file.Name
                FilePath = $file.FullName
                SHA256   = $hash
                Size     = $file.Length
            }
        }
    }

    if ($discovered.Count -gt 0) {
        Write-Information "[PRP STEP 11-A] Discovered $($discovered.Count) new receipt(s) not in manifest" -Tags PRP
        if (-not $WhatIfPreference) {
            # Append new rows to the global manifest
            $newRows = $discovered | ForEach-Object {
                $name = $_.FileName
                # Infer date and amount from filename convention: YYYY-MM-DD - AMOUNT - VENDOR.pdf
                $inferredDate = $null
                $inferredAmount = $null
                if ($name -match '^(\d{4}-\d{2}-\d{2})\s*-\s*([\d.]+)\s*-\s*(.+)\.\w+$') {
                    $inferredDate = $matches[1]
                    $inferredAmount = $matches[2]
                }
                [PSCustomObject]@{
                    filename         = $name
                    date             = $inferredDate
                    amount           = $inferredAmount
                    vendor           = ""
                    account          = $manifestAcct
                    sha256           = $_.SHA256
                    zoho_expense_id  = ""
                    zoho_document_id = ""
                    source           = "prp-discovery"
                    status           = "unmatched"
                    notes            = ""
                }
            }
            # Filter out any stale header rows that may have leaked into data, then append new rows
            $cleanRows = $allRows | Where-Object { $_.filename -and $_.filename -notlike 'filename' }
            $newCsvRows = @($cleanRows) + @($newRows)
            $newCsvRows | Export-Csv -LiteralPath $globalManifest -NoTypeInformation -Encoding utf8
            Write-Information "[PRP STEP 11-A] Appended $($newRows.Count) new row(s) to $globalManifest" -Tags PRP
        }
        $addedCount = $discovered.Count
    } else {
        Write-Information "[PRP STEP 11-A] No new receipts discovered — manifest is current" -Tags PRP
    }

    $totalLocal = ($existingManifestRows.Count + $addedCount)
    return @{
        Discovered = $discovered
        Added      = $addedCount
        TotalLocal = $totalLocal
    }
}

# ---- Phase B: Zoho → Local Download ----
function Invoke-PhaseB {
    param($AllExpensesLocal)

    Write-Information "[PRP STEP 11-B] Zoho→Local sync — checking Zoho expenses with attachments" -Tags PRP

    $downloadCount = 0
    $alreadyHaveCount = 0
    $skipCount = 0

    if (-not $AllExpensesLocal -or $AllExpensesLocal.Count -eq 0) {
        Write-Information "[PRP STEP 11-B] No Zoho expenses provided — nothing to sync" -Tags PRP
        return @{ Downloaded = 0; AlreadyHad = 0; Skipped = 0 }
    }

    if (-not $Headers -or -not $OrgId) {
        Write-Warning "[PRP STEP 11-B] No Zoho API credentials — skipping download"
        return @{ Downloaded = 0; AlreadyHad = 0; Skipped = 0 }
    }

    $receiptDownloadDir = if ($acctReceiptDir) { $acctReceiptDir } else { "$booksRoot\2026 Receipts\$manifestAcct" }
    $null = New-Item -ItemType Directory -Path $receiptDownloadDir -Force

    $expensesWithAttachments = $AllExpensesLocal | Where-Object { $_.has_attachment -eq $true -or $_.has_attachment -eq "true" }

    Write-Information "[PRP STEP 11-B] $($expensesWithAttachments.Count) expense(s) have attachments in Zoho" -Tags PRP

    foreach ($exp in $expensesWithAttachments) {
        $expenseId = $exp.expense_id
        if (-not $expenseId) { $skipCount++; continue }

        $expectedName = "receipt_${expenseId}.pdf"
        $localPath = Join-Path $receiptDownloadDir $expectedName

        if (Test-Path -LiteralPath $localPath) {
            $alreadyHaveCount++
            continue
        }

        if ($WhatIfPreference) {
            Write-Information "[PRP STEP 11-B] WhatIf: would download receipt for expense $expenseId ($($exp.amount) on $($exp.date))" -Tags PRP
            $skipCount++
            continue
        }

        try {
            $uri = "https://www.zohoapis.com/books/v3/expenses/$expenseId/attachment?organization_id=$OrgId"
            $downloadResult = $null
            try {
                Invoke-RestMethod -Uri $uri -Headers $Headers -OutFile $localPath -ErrorAction Stop
                if ((Get-Item -LiteralPath $localPath -ErrorAction SilentlyContinue).Length -gt 0) {
                    $downloadCount++
                    Write-Information "[PRP STEP 11-B] Downloaded receipt for expense $expenseId → $localPath" -Tags PRP
                } else {
                    Remove-Item -LiteralPath $localPath -Force -ErrorAction SilentlyContinue
                    Write-Warning "[PRP STEP 11-B] Expense $expenseId returned empty attachment"
                    $skipCount++
                }
            } catch {
                if (Test-Path -LiteralPath $localPath) { Remove-Item -LiteralPath $localPath -Force -ErrorAction SilentlyContinue }
                throw
            }
        } catch {
            Write-Warning "[PRP STEP 11-B] Could not download receipt for expense $expenseId`: $_"
            $skipCount++
        }
    }

    Write-Information "[PRP STEP 11-B] Downloaded $downloadCount, already had $alreadyHaveCount, skipped $skipCount" -Tags PRP
    return @{ Downloaded = $downloadCount; AlreadyHad = $alreadyHaveCount; Skipped = $skipCount }
}

# ---- Phase C: Local → Zoho Upload ----
function Invoke-PhaseC {
    Write-Information "[PRP STEP 11-C] Local→Zoho sync — uploading local receipts to matching Zoho expenses" -Tags PRP

    $uploadCount = 0
    $skipCount = 0
    $alreadyLinkedCount = 0

    if (-not $acctReceiptDir -or -not (Test-Path -LiteralPath $acctReceiptDir)) {
        Write-Information "[PRP STEP 11-C] No local receipt directory — nothing to upload" -Tags PRP
        return @{ Uploaded = 0; Skipped = 0; AlreadyLinked = 0 }
    }

    if ($IsPlaidImmutable) {
        Write-Information "[PRP STEP 11-C] Plaid-immutable account — upload disabled to avoid transaction duplication. Use Zoho UI: Banking → Uncategorized → Attach Receipt." -Tags PRP
        return @{ Uploaded = 0; Skipped = $null; AlreadyLinked = 0; Note = "Plaid-immutable: use Zoho UI for receipt attachment" }
    }

    # Use zoho-attach-receipts.mjs for matching and upload
    $attachScript = Join-Path (Join-Path $scriptDir "zoho") "zoho-attach-receipts.mjs"
    if (-not (Test-Path -LiteralPath $attachScript)) {
        Write-Warning "[PRP STEP 11-C] zoho-attach-receipts.mjs not found at $attachScript — cannot upload"
        return @{ Uploaded = 0; Skipped = $null; AlreadyLinked = 0; Note = "Upload script not found" }
    }

    Write-Information "[PRP STEP 11-C] Would invoke: node $attachScript --account $manifestAcct --manifest $globalManifest" -Tags PRP

    if ($WhatIfPreference) {
        Write-Information "[PRP STEP 11-C] WhatIf: would scan local receipts and upload unmatched, categorized ones" -Tags PRP
        return @{ Uploaded = 0; Skipped = 0; AlreadyLinked = 0; WhatIf = $true }
    }

    try {
        $attachArgs = @(
            "--account", $manifestAcct,
            "--manifest", $globalManifest,
            "--org-id", $OrgId
        )
        if ($Token) { $attachArgs += "--token"; $attachArgs += $Token }

        $output = & node $attachScript @attachArgs 2>&1
        Write-Information "[PRP STEP 11-C] Upload script output: $output" -Tags PRP

        $uploadCount = ($output | Select-String -Pattern "uploaded|attached" -CaseInsensitive).Count
    } catch {
        Write-Warning "[PRP STEP 11-C] Upload script failed: $_"
        return @{ Uploaded = 0; Skipped = $null; AlreadyLinked = 0; Note = "Upload script failed: $_" }
    }

    Write-Information "[PRP STEP 11-C] Uploaded $uploadCount receipt(s), skipped $skipCount" -Tags PRP
    return @{ Uploaded = $uploadCount; Skipped = $skipCount; AlreadyLinked = $alreadyLinkedCount }
}

# ---- Phase D: Note about email endpoint ----
function Write-PhaseD {
    Write-Information "[PRP STEP 11-D] Email endpoint note — Zoho Books supports email-to-receipt auto-matching via receipts@books.zoho.com. This could eliminate manual upload entirely when properly configured. Investigation deferred: need to verify sender-whitelist setup and auto-match reliability with Plaid-synced transactions." -Tags PRP
}

# ===== EXECUTION =====

Write-Information "[PRP STEP 11] Starting Receipt Verification for $AccountName ($OrgName)" -Tags PRP

$phaseAResult = Invoke-PhaseA
$phaseBResult = Invoke-PhaseB -AllExpensesLocal $AllExpenses
$phaseCResult = Invoke-PhaseC
Write-PhaseD

# Build summary
$detail = "Phase A: $($phaseAResult.Added) new, $($phaseAResult.TotalLocal) total local | " +
          "Phase B: $($phaseBResult.Downloaded) downloaded, $($phaseBResult.AlreadyHad) already had | " +
          "Phase C: $($phaseCResult.Uploaded) uploaded"

$allPassed = $true
$warnings = @()
if ($phaseAResult.Added -gt 0) { $warnings += "New local receipts discovered — manifest updated" }
if ($phaseBResult.Downloaded -gt 0) { $warnings += "Zoho receipts downloaded — manifest should be updated" }
if ($phaseCResult.Uploaded -gt 0) { $warnings += "Local receipts uploaded to Zoho" }
if ($phaseCResult.Note) { $warnings += $phaseCResult.Note }

if ($warnings.Count -gt 0) {
    Write-Warning "[PRP STEP 11] Warnings: $($warnings -join '; ')"
}

Write-Progress -Activity "[PRP Step $stepNumber]" -Status $stepName -Completed

return [PSCustomObject]@{
    StepNumber    = $stepNumber
    Passed        = $allPassed
    Details       = $detail
    Warnings      = $warnings
    PhaseAResult  = $phaseAResult
    PhaseBResult  = $phaseBResult
    PhaseCResult  = $phaseCResult
    NextSteps     = @(
        "Proceed to Step 12: Update Status",
        "Run Sync-TasReceiptStatus.mjs after upload to sync receipt links to TAS"
    )
}
