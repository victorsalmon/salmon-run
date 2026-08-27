<#
.SYNOPSIS
    Full receipt pipeline: scan → match → organize → regenerate manifests → rebuild TAS → status check.
.DESCRIPTION
    Orchestrates the complete receipt lifecycle:
    1. Scan all receipt files across both organizations
    2. Cross-match against both orgs' TAS (exact + fuzzy)
    3. Move matched → matched/, unmatched → non-matching/
    4. Regenerate manifests (scan for any files not in manifest)
    5. Run enrichment
    6. Rebuild TAS
    7. Run status check
#>

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $PSCommandPath

# ── Phase 1: Match ──────────────────────────────────────────────────────────
Write-Host "╔$('═' * 58)╗" -ForegroundColor Cyan
Write-Host "║  Phase 1: Cross-org receipt matching                    ║" -ForegroundColor Cyan
Write-Host "╚$('═' * 58)╝" -ForegroundColor Cyan

$matchResults = & "$scriptDir\Invoke-ReceiptMatch.ps1" -PassThru

$matched = $matchResults | Where-Object { $_.Status -eq 'matched' }
$unmatched = $matchResults | Where-Object { $_.Status -eq 'unmatched' }

Write-Host "`nMatch results: $($matched.Count) matched, $($unmatched.Count) unmatched" -ForegroundColor Cyan

# ── Phase 2: Organize ───────────────────────────────────────────────────────
Write-Host "`n╔$('═' * 58)╗" -ForegroundColor Cyan
Write-Host "║  Phase 2: Organize files + update references             ║" -ForegroundColor Cyan
Write-Host "╚$('═' * 58)╝" -ForegroundColor Cyan

$matchResults | & "$scriptDir\Invoke-ReceiptOrganize.ps1"
if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
    Write-Error "Organize phase failed"
    exit 1
}

# ── Phase 3a: Rebuild manifests from disk ───────────────────────────────────
Write-Host "`n╔$('═' * 58)╗" -ForegroundColor Cyan
Write-Host "║  Phase 3a: Rebuild manifests from disk                    ║" -ForegroundColor Cyan
Write-Host "╚$('═' * 58)╝" -ForegroundColor Cyan

foreach ($entity in @('room-rentals', 'intersite-consulting')) {
    Write-Host "`n--- $entity ---" -ForegroundColor Yellow
    & "$scriptDir\Rebuild-Manifest.ps1" -Entity $entity -Force
}

# ── Phase 3b: Scan for new files ─────────────────────────────────────────────
Write-Host "`n╔$('═' * 58)╗" -ForegroundColor Cyan
Write-Host "║  Phase 3b: Scan for new receipts                          ║" -ForegroundColor Cyan
Write-Host "╚$('═' * 58)╝" -ForegroundColor Cyan

foreach ($entity in @('room-rentals', 'intersite-consulting')) {
    Write-Host "`n--- $entity ---" -ForegroundColor Yellow
    & "$scriptDir\Invoke-ReceiptScanAndRebuild.ps1" -Entity $entity
}

# ── Phase 4: Rebuild TAS ────────────────────────────────────────────────────
Write-Host "`n╔$('═' * 58)╗" -ForegroundColor Cyan
Write-Host "║  Phase 4: Rebuild TAS                                    ║" -ForegroundColor Cyan
Write-Host "╚$('═' * 58)╝" -ForegroundColor Cyan

Write-Host "`n--- room-rentals ---" -ForegroundColor Yellow
& "$scriptDir\reconciliation\Build-TAS.ps1"

Write-Host "`n--- intersite-consulting ---" -ForegroundColor Yellow
& "$scriptDir\reconciliation\Build-IntersiteTAS.ps1"

# ── Phase 5: Status check ───────────────────────────────────────────────────
Write-Host "`n╔$('═' * 58)╗" -ForegroundColor Cyan
Write-Host "║  Phase 5: Status check                                    ║" -ForegroundColor Cyan
Write-Host "╚$('═' * 58)╝" -ForegroundColor Cyan

Write-Host "`n--- room-rentals ---" -ForegroundColor Yellow
& "$scriptDir\Invoke-StatusCheck.ps1" -Organization room-rentals

Write-Host "`n--- intersite-consulting ---" -ForegroundColor Yellow
& "$scriptDir\Invoke-StatusCheck.ps1" -Organization intersite-consulting

Write-Host "`n$('★' * 60)" -ForegroundColor Green
Write-Host "  Full receipt pipeline complete!" -ForegroundColor Green
Write-Host "  $($matched.Count) receipts matched across orgs" -ForegroundColor Green
Write-Host "  $($unmatched.Count) receipts remain in non-matching/" -ForegroundColor Yellow
Write-Host "$('★' * 60)" -ForegroundColor Green
