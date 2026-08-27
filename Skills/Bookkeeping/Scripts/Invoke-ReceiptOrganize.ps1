<#
.SYNOPSIS
    Organizes receipt files.
#>

param([switch]$WhatIf)

$ErrorActionPreference = 'Stop'
$recDir = "$env:USERPROFILE\intersite-docs\Taxes and Bookkeeping\intersite-consulting\2026 Filing\Receipts"
$destDir = "$recDir\intersite-mc-6258"
$matchedDir = "$recDir\matched"
$manifestPath = "$recDir\_manifest.csv"
$repoRoot = Resolve-Path "$PSScriptRoot\..\..\.."

if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
if (-not (Test-Path $matchedDir)) { New-Item -ItemType Directory -Path $matchedDir -Force | Out-Null }

$manifest = if (Test-Path $manifestPath) { Import-Csv $manifestPath } else { @() }

$script:manifestRows = [System.Collections.ArrayList]@()

function Add-ToManifestEntry($date, $amount, $vendor, $filename, $account, $notes) {
    [void]$script:manifestRows.Add([PSCustomObject]@{
        filename = $filename
        date     = $date
        amount   = $amount
        vendor   = $vendor
        account  = $account
        sha256   = ""
        zoho_expense_id  = ""
        zoho_document_id = ""
        source   = "pipeline"
        status   = "processed"
        notes    = $notes
    })
}

function Move-And-Enrich($srcRel, $dstName, $date, $cadAmt, $vendor, $account, $notes) {
    $src = Join-Path $recDir $srcRel
    $ext = [System.IO.Path]::GetExtension($src)
    $dst = Join-Path $destDir "$dstName$ext"
    if (-not (Test-Path $src)) { Write-Warning "  NOT FOUND: $srcRel"; return }
    
    $wasCopied = $false
    if (-not (Test-Path $dst)) {
        if (-not $WhatIf) {
            Copy-Item -LiteralPath $src -Destination $dst -Force
            Write-Host "  Moved: $dstName$ext" -ForegroundColor Green
            $wasCopied = $true
        } else {
            Write-Host "  WOULD MOVE: $src → $dstName$ext" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  Already exists: $dstName$ext" -ForegroundColor DarkGray
    }
    
    if (-not $WhatIf) {
        # Create CSV sidecar (idempotent)
        $csvPath = Join-Path $destDir "$dstName.csv"
        if (-not (Test-Path $csvPath)) {
            "date,amount,vendor,sha256,filename" | Set-Content -Path $csvPath -Encoding UTF8
        }
        # Create MD sidecar (idempotent)
        $mdPath = Join-Path $destDir "$dstName.md"
        if (-not (Test-Path $mdPath)) {
            "# $vendor`n- Date: $date`n- Amount: $$cadAmt CAD`n- Vendor: $vendor`n- Pipeline: Invoke-ReceiptOrganize.ps1`n- Notes: $notes" | Set-Content -Path $mdPath -Encoding UTF8
        }
        
        # Always add to manifest (checks duplicates inside Add-ToManifestEntry)
        Add-ToManifestEntry $date $cadAmt $vendor "intersite-mc-6258/$dstName$ext" $account $notes
    }
}

# ═══════════════════════════════════════════════
# Step 1: Move and enrich each found receipt
# ═══════════════════════════════════════════════
Write-Host "=== Step 1: Move & Enrich Receipts ===" -ForegroundColor Cyan

# 1. AppSumo May 2 ($19 USD = $27 CAD)
Move-And-Enrich "non-matching\2025-05-02 - 19.00 - AppSumo.jpg" "2025-05-02 - 27.00 - AppSumo" "2025-05-02" "27.00" "AppSumo" "intersite-mc-6258" "$19 USD; $27 CAD @ 1.421052 FX"

# 2. AppSumo May 3 ($52.90 USD = $75.17 CAD)
Move-And-Enrich "non-matching\2025-05-03 - 52.90 - AppSumo.jpg" "2025-05-03 - 75.17 - AppSumo" "2025-05-03" "75.17" "AppSumo" "intersite-mc-6258" "$52.90 USD; $75.17 CAD @ 1.420982 FX"

# 3. BoldSign May 30 ($60 USD = $85.07 CAD)
Move-And-Enrich "non-matching\2025-05-30 - 60.00 - BoldSign.pdf" "2025-05-30 - 85.07 - BoldSign" "2025-05-30" "85.07" "BoldSign" "intersite-mc-6258" "$60 USD; $85.07 CAD @ 1.417833 FX"

# 4. WPForms Jun 10 ($99 USD = $139.12 CAD)
Move-And-Enrich "non-matching\2025-06-10 - 99.00 - WPForms, LLC.pdf" "2025-06-10 - 139.12 - WPForms" "2025-06-10" "139.12" "WPForms" "intersite-mc-6258" "$99 USD; $139.12 CAD @ 1.405252 FX"

# 5. LegalShield Sep 15 ($72.69) — receipt covers Sep+Oct at $145.38 total
Move-And-Enrich "non-matching\2025-09-14 - 145.38 - LegalShield Sep and Oct.pdf" "2025-09-15 - 72.69 - LegalShield Sep" "2025-09-15" "72.69" "LegalShield" "intersite-mc-6258" "Receipt covers Sep+Oct ($145.38 for both)"

# 6. Home Depot Nov 4 ($193.38)
Move-And-Enrich "non-matching\2025.11.04 - 193.38 - Home Depot - Replace Mulch.pdf" "2025-11-04 - 193.38 - Home Depot" "2025-11-04" "193.38" "Home Depot" "intersite-mc-6258" "Replace Mulch - Home Depot #7084 Vernon"

# 7. Temu Nov 5 ($59.71)
Move-And-Enrich "non-matching\2025.11.05 - 59.71 temu towels_68UkSbPDkSpxWjPbjxGM.pdf" "2025-11-05 - 59.71 - Temu" "2025-11-05" "59.71" "Temu" "intersite-mc-6258" "Towels - Temu.com"

# 8. Civil Resolution Tribunal Nov 26 ($25)
Move-And-Enrich "non-matching\2025-11-27 - 25.0 - Civil Resolution Tribunal.pdf" "2025-11-26 - 25.00 - Civil Resolution Tribunal" "2025-11-26" "25.00" "Civil Resolution Tribunal" "intersite-mc-6258" "CRT filing fee"

# 9. MozSEO Jan 25 ($315.51) — receipt already has CAD amount
Move-And-Enrich "non-matching\2026.01.25 - mozSEO 315.51 CAD - Receipt-2841-3373.pdf" "2026-01-25 - 315.51 - MozSEO" "2026-01-25" "315.51" "MozSEO" "intersite-mc-6258" "MozSEO SEO service"

# ═══════════════════════════════════════════════
# Step 2: Write updated manifest
# ═══════════════════════════════════════════════
Write-Host "`n=== Step 2: Update Manifest ===" -ForegroundColor Cyan
$allRows = @($manifest) + $script:manifestRows
if (-not $WhatIf) {
    $allRows | Export-Csv -Path $manifestPath -NoTypeInformation -Encoding UTF8
    Write-Host "  Manifest updated: $($allRows.Count) total entries ($($script:manifestRows.Count) new)" -ForegroundColor Green
}

# ═══════════════════════════════════════════════
# Step 3: Rebuild TAS
# ═══════════════════════════════════════════════
Write-Host "`n=== Step 3: Rebuild TAS ===" -ForegroundColor Cyan
if (-not $WhatIf) {
    & "$repoRoot\Skills\Bookkeeper\Scripts\Build-IntersiteTAS.ps1"
}

# ═══════════════════════════════════════════════
# Step 4: Run Status Check
# ═══════════════════════════════════════════════
Write-Host "`n=== Step 4: Status Check ===" -ForegroundColor Cyan
if (-not $WhatIf) {
    & "$repoRoot\Skills\Bookkeeper\Scripts\Invoke-StatusCheck.ps1" -Organization intersite-consulting
}

Write-Host "`n=== Pipeline Complete ===" -ForegroundColor Cyan
Write-Host "Remaining unmatched (exceptions noted):" -ForegroundColor Yellow
Write-Host "  Ozerty.ca Jul 30 ($50.03) — amount mismatch with receipt ($73.58)" -ForegroundColor Yellow
Write-Host "  Ozerty adjustment Oct 10 ($50.03) — adjustment, no receipt needed" -ForegroundColor Yellow
Write-Host "  Pixella AI May 5 ($2.09) — per user exception (tiny amount)" -ForegroundColor Yellow
Write-Host "  LegalShield Oct 15 ($72.69) — covered by the Sep receipt (Sep+Oct combined)" -ForegroundColor DarkGray
Write-Host "`nQueue for Zoho upload:" -ForegroundColor Cyan
Write-Host "  node `"$repoRoot\Skills\Bookkeeper\Scripts\zoho-attach-receipts.mjs`" --dir `"$destDir`" --org intersite-consulting" -ForegroundColor White
