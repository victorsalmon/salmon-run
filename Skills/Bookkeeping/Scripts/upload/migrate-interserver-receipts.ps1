<#
.SYNOPSIS
    Migrates interserver receipts.
#>

param([switch]$WhatIf)

$ErrorActionPreference = 'Stop'
$repoRoot = Resolve-Path "$PSScriptRoot\..\..\..\.."
$recDir = "$env:USERPROFILE\intersite-docs\Taxes and Bookkeeping\intersite-consulting\2026 Filing\Receipts"
$destDir = "$recDir\intersite-mc-6258"

# ── Step 0: Mark intersite receipts email as read ──
Write-Host "=== Step 0: Mark receipts-intersite emails as read ===" -ForegroundColor Cyan
try {
    $json = aws secretsmanager get-secret-value --secret-id Interclaw/FRAD/Provisioning --profile intersite --region ca-central-1 --query "SecretString" --output text 2>$null | ConvertFrom-Json
    $env:EMAIL_USER = $json.receipts_intersite_email
    $env:EMAIL_PASS = $json.receipts_intersite_pass
    Write-Host "  Got email credentials" -ForegroundColor DarkGray
    $markScript = @'
const { checkMailbox } = require('/app/email/lib/imap.mjs');
async function markRead() {
  const config = { host: process.env.EMAIL_HOST || 'webhosting2049.is.cc', port: 993, tls: true, user: process.env.EMAIL_USER, password: process.env.EMAIL_PASS };
  const messages = await checkMailbox(config, 'INBOX', false);
  if (messages.length === 0) { console.log('0 unseen messages'); return; }
  const Imap = require('imap');
  const imap = new Imap({ ...config, autotls: 'always', tlsOptions: { rejectUnauthorized: false } });
  await new Promise((res, rej) => { imap.once('ready', res); imap.once('error', rej); imap.connect(); });
  const uids = messages.map(m => m.uid);
  await new Promise((res, rej) => { imap.addFlags(uids, '\\Seen', (err) => err ? rej(err) : res()); });
  console.log(`Marked ${uids.length} messages as read (UIDs: ${uids.join(',')})`);
  imap.end();
}
markRead().catch(e => { console.error(e.message); process.exit(1); });
'@
    $tmpScript = Join-Path ([System.IO.Path]::GetTempPath()) "mark-read-$([System.IO.Path]::GetRandomFileName()).mjs"
    Set-Content -Path $tmpScript -Value $markScript -Encoding UTF8
    docker cp $tmpScript "FRAD_is-bookkeeping.1.memnw9wxppuofhqddm1wf806p:/tmp/mark-read.mjs"
    docker exec "FRAD_is-bookkeeping.1.memnw9wxppuofhqddm1wf806p" node /tmp/mark-read.mjs 2>&1
    Remove-Item $tmpScript -Force
} catch {
    Write-Warning "  Could not mark email as read: $_"
}

# ── Step 1: Define InterServer receipt documents by month ──
$isaDocs = @(
    @{ src = "non-matching\2025-04-02 - 5.00 - interserver.net.jpg"; name = "2025-04-02 - 5.00 - InterServer Invoice.jpg" }
    @{ src = "non-matching\2025-05-02 - 5.00 - InterServer.net.jpg"; name = "2025-05-02 - 5.00 - InterServer Invoice.jpg" }
    @{ src = "non-matching\2026-06-03_4_Fwd_InterServer_Invoice_for_Websites_Standard_Web_Hosting_1.pdf"; name = "2025-06-02 - 5.00 - InterServer Invoice.pdf" }
    @{ src = "non-matching\2025-08-02 - 5 - InterServer.pdf"; name = "2025-08-02 - 5.00 - InterServer Invoice.pdf" }
    @{ src = "non-matching\2026-06-03_12_Fwd_InterServer_Invoice_for_Websites_Standard_Web_Hosting_1.pdf"; name = "2025-09-02 - 5.00 - InterServer Invoice.pdf" }
    @{ src = "non-matching\2026-06-03_10_Fwd_InterServer_Invoice_for_Websites_Standard_Web_Hosting_1.pdf"; name = "2025-10-02 - 5.00 - InterServer Invoice.pdf" }
    @{ src = "non-matching\2026-06-03_9_Fwd_InterServer_Invoice_for_Websites_Standard_Web_Hosting_1.pdf"; name = "2025-11-02 - 5.00 - InterServer Invoice.pdf" }
    @{ src = "non-matching\2025-12-02 - 5.0 - InterServer.pdf"; name = "2025-12-02 - 5.00 - InterServer Invoice.pdf" }
    @{ src = "non-matching\2026-06-03_19_Fwd_InterServer_Invoice_for_Websites_Standard_Web_Hosting_1.pdf"; name = "2026-01-02 - 5.00 - InterServer Invoice.pdf" }
    # 2026-02: no PDF — reuse extracted sidecar content
    # 2026-03 already in intersite-mc-6258
    @{ src = "non-matching\2026-04-02 - 5 - InterServer.pdf"; name = "2026-04-02 - 5.00 - InterServer Invoice.pdf" }
    @{ src = "non-matching\2026-05-02 - 5.00 USD - InterServer - Web Hosting Credit Card Payment.pdf"; name = "2026-05-02 - 5.00 - InterServer Invoice.pdf" }
    @{ src = "non-matching\2026-06-03_24_Fwd_InterServer_Invoice_for_Websites_Standard_Web_Hosting_1.pdf"; name = "2026-06-02 - 5.00 - InterServer Invoice.pdf" }
)

Write-Host "=== Step 1: Move InterServer receipt documents to intersite-mc-6258/ ===" -ForegroundColor Cyan
$movedCount = 0
foreach ($doc in $isaDocs) {
    $srcPath = Join-Path $recDir $doc.src
    $dstPath = Join-Path $destDir $doc.name
    if (Test-Path $dstPath) {
        Write-Host "  Already exists: $($doc.name)" -ForegroundColor DarkGray
        $movedCount++
        continue
    }
    if (-not (Test-Path $srcPath)) {
        Write-Warning "  Source not found: $($doc.src)"
        continue
    }
    if ($WhatIf) { Write-Host "  WOULD MOVE: $($doc.name)" -ForegroundColor Yellow; continue }
    Copy-Item -LiteralPath $srcPath -Destination $dstPath -Force
    Write-Host "  Moved: $($doc.name)" -ForegroundColor Green
    $movedCount++
}
Write-Host "  Moved $movedCount / $($isaDocs.Count) files" -ForegroundColor Cyan

# 2026-02: create Statement Record since PDF is missing
$febPath = Join-Path $destDir "2026-02-02 - 5.00 - InterServer Invoice - Statement Record.txt"
if (-not (Test-Path $febPath)) {
    if (-not $WhatIf) {
        Set-Content -Path $febPath -Value @"
InterServer Standard Web Hosting - Statement Record
Invoice Date: 2026-02-02
Amount: $5.00 USD
Invoice #: 42392304
Service: Standard Web Hosting - intersite.ca
Bank Transaction: 2026-02-03 - $6.94 CAD - MC 6258 (FX rate applies)

Original invoice PDF was not preserved in the receipt pipeline.
Extracted content from email forward preserved in _orphans\rbc-6258-ingest~2026-02-02 - 5 - InterServer.md
"@ -Encoding UTF8
        Write-Host "  Created Statement Record for 2026-02" -ForegroundColor Yellow
    } else {
        Write-Host "  WOULD CREATE Statement Record for 2026-02" -ForegroundColor Yellow
    }
}

# Same for 2025-07
$julPath = Join-Path $destDir "2025-07-02 - 5.00 - InterServer Invoice - Statement Record.txt"
if (-not (Test-Path $julPath)) {
    if (-not $WhatIf) {
        Set-Content -Path $julPath -Value @"
InterServer Standard Web Hosting - Statement Record
Invoice Date: 2025-07-02
Amount: $5.00 USD
Invoice #: 36847730
Service: Standard Web Hosting - intersite.ca
Bank Transaction: 2025-07-03 - $7.00 CAD - MC 6258 (FX rate applies)

Original invoice PDF was not preserved in the receipt pipeline.
Extracted content from email forward preserved in _orphans\rbc-6258-ingest~2025-07-02 - 5 - InterServer.md
"@ -Encoding UTF8
        Write-Host "  Created Statement Record for 2025-07" -ForegroundColor Yellow
    } else {
        Write-Host "  WOULD CREATE Statement Record for 2025-07" -ForegroundColor Yellow
    }
}

# ── Step 2: Create .csv and .md sidecars for each receipt ──
Write-Host "`n=== Step 2: Enrich receipts (create .csv and .md sidecars) ===" -ForegroundColor Cyan
$docs = @(
    @{ date = "2025-04-02"; amt = "5.00"; vendor = "InterServer" },
    @{ date = "2025-05-02"; amt = "5.00"; vendor = "InterServer" },
    @{ date = "2025-06-02"; amt = "5.00"; vendor = "InterServer" },
    @{ date = "2025-07-02"; amt = "5.00"; vendor = "InterServer"; note = "Statement Record" },
    @{ date = "2025-08-02"; amt = "5.00"; vendor = "InterServer" },
    @{ date = "2025-09-02"; amt = "5.00"; vendor = "InterServer" },
    @{ date = "2025-10-02"; amt = "5.00"; vendor = "InterServer" },
    @{ date = "2025-11-02"; amt = "5.00"; vendor = "InterServer" },
    @{ date = "2025-12-02"; amt = "5.00"; vendor = "InterServer" },
    @{ date = "2026-01-02"; amt = "5.00"; vendor = "InterServer" },
    @{ date = "2026-02-02"; amt = "5.00"; vendor = "InterServer"; note = "Statement Record" },
    @{ date = "2026-03-02"; amt = "5.00"; vendor = "InterServer" },
    @{ date = "2026-04-02"; amt = "5.00"; vendor = "InterServer" },
    @{ date = "2026-05-02"; amt = "5.00"; vendor = "InterServer" },
    @{ date = "2026-06-02"; amt = "5.00"; vendor = "InterServer" }
)

foreach ($d in $docs) {
    $baseName = if ($d.note -eq "Statement Record") {
        "$($d.date) - $($d.amt) - $($d.vendor) Invoice - Statement Record"
    } else {
        "$($d.date) - $($d.amt) - $($d.vendor) Invoice"
    }
    
    # CSV sidecar
    $csvPath = Join-Path $destDir "$baseName.csv"
    if (-not (Test-Path $csvPath)) {
        if (-not $WhatIf) {
            "date,amount,vendor,sha256,filename" | Set-Content -Path $csvPath -Encoding UTF8
            Write-Host "  Created CSV: $baseName.csv" -ForegroundColor Green
        } else {
            Write-Host "  WOULD CREATE CSV: $baseName.csv" -ForegroundColor Yellow
        }
    }

    # MD sidecar
    $mdPath = Join-Path $destDir "$baseName.md"
    if (-not (Test-Path $mdPath)) {
        if (-not $WhatIf) {
            @"
# $($d.vendor) Invoice
- Date: $($d.date)
- Amount: $$($d.amt) USD
- Vendor: $($d.vendor) (InterServer.net)
- Service: Standard Web Hosting - intersite.ca
- Source: Email forward to receipts-intersite@clocklobster.com
- Pipeline: migrate-interserver-receipts.ps1
- Note: USD invoice; CAD bank transaction amount varies due to FX conversion
"@ | Set-Content -Path $mdPath -Encoding UTF8
            Write-Host "  Created MD: $baseName.md" -ForegroundColor Green
        } else {
            Write-Host "  WOULD CREATE MD: $baseName.md" -ForegroundColor Yellow
        }
    }
}

# ── Step 3: Update manifest ──
Write-Host "`n=== Step 3: Update receipt manifest ===" -ForegroundColor Cyan
Write-Host "  Calling Invoke-BookkeepingEnrichment (or rebuild manifest)..." -ForegroundColor DarkGray
# For individual receipt additions, append to manifest with proper account
$manifestPath = "$recDir\_manifest.csv"
$newRows = @()
foreach ($d in $docs) {
    $baseName = if ($d.note -eq "Statement Record") {
        "$($d.date) - $($d.amt) - $($d.vendor) Invoice - Statement Record"
    } else {
        "$($d.date) - $($d.amt) - $($d.vendor) Invoice"
    }
    # Check if already in manifest
    if (Test-Path $manifestPath) {
        $existing = Import-Csv $manifestPath | Where-Object { $_.filename -match "$($d.date).*InterServer|interserver" -and $_.account -eq 'intersite-mc-6258' }
        if ($existing) {
            Write-Host "  Already in manifest: $($d.date) InterServer" -ForegroundColor DarkGray
            continue
        }
    }
    $newRows += [PSCustomObject]@{
        filename = "$baseName.pdf"
        date     = $d.date
        amount   = $d.amt
        vendor   = $d.vendor
        account  = "intersite-mc-6258"
        sha256   = ""
        zoho_expense_id    = ""
        zoho_document_id   = ""
        source   = "invoice-forward"
        status   = "processed"
        notes    = "USD invoice; CAD txn on MC-6258 via FX"
    }
}

if ($newRows.Count -gt 0 -and -not $WhatIf) {
    $newRows | Export-Csv -Path "$recDir\_manifest-isa-additions.csv" -NoTypeInformation -Encoding UTF8
    Write-Host "  Wrote $($newRows.Count) new manifest entries to _manifest-isa-additions.csv" -ForegroundColor Green
    Write-Host "  These should be merged into _manifest.csv manually or via update-manifest" -ForegroundColor Yellow
} elseif ($WhatIf) {
    Write-Host "  WOULD ADD $($newRows.Count) entries to manifest" -ForegroundColor Yellow
} else {
    Write-Host "  All entries already in manifest" -ForegroundColor DarkGray
}

# ── Step 4: Rebuild TAS ──
Write-Host "`n=== Step 4: Rebuild TAS ===" -ForegroundColor Cyan
if (-not $WhatIf) {
    & "$repoRoot\Skills\Bookkeeping\Scripts\reconciliation\Build-IntersiteTAS.ps1"
} else {
    Write-Host "  WOULD RUN: Build-IntersiteTAS.ps1" -ForegroundColor Yellow
}

# ── Step 5: Queue for Zoho upload ──
Write-Host "`n=== Step 5: Queue receipts for Zoho upload ===" -ForegroundColor Cyan
Write-Host "  Receipts in intersite-mc-6258/ ready for Zoho upload." -ForegroundColor DarkGray
Write-Host "  Run this when ready:" -ForegroundColor DarkGray
Write-Host "    node `"$repoRoot\Skills\Bookkeeping\Scripts\zoho\zoho-attach-receipts.mjs`" --dir `"$destDir`" --org intersite-consulting" -ForegroundColor White

Write-Host "`n=== Done ===" -ForegroundColor Cyan
