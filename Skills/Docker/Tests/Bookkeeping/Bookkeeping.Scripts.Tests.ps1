#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

BeforeAll {
    $script:RepoRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.Parent.FullName
    $script:AcctScripts = Join-Path $script:RepoRoot "Skills" "Bookkeeping" "Scripts"
    $script:TestDataDir = Join-Path $env:TEMP "AcctTests-$(Get-Random)"
    $null = New-Item -ItemType Directory -Path $script:TestDataDir -Force

    New-Item -ItemType Directory -Path (Join-Path $script:TestDataDir "fixtures") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $script:TestDataDir "output") -Force | Out-Null

    $sampleCsv = @"
Date,Description,Amount,Account
2026-01-15,Rent Payment,-2000.00,RBC-FRA
2026-01-20,Internet Bill,-85.00,RBC-FRA
2026-02-01,Rent Payment,-2000.00,RBC-FRA
"@
    Set-Content -Path (Join-Path $script:TestDataDir "fixtures" "sample.csv") -Value $sampleCsv -Encoding utf8

    $sampleTas = @"
date,description,amount,account,category,zoho_expense_id,zoho_has_receipt
2026-01-15,Rent Payment,-2000.00,RBC-FRA,Rent,,
2026-01-20,Internet Bill,-85.00,RBC-FRA,Utilities,,
"@
    Set-Content -Path (Join-Path $script:TestDataDir "fixtures" "sample-tas.csv") -Value $sampleTas -Encoding utf8

    $sampleRegister = @"
Room,Date,Amount,Note,Status
MLM,2026-01-01,2000.00,Jan rent,Paid
MLM,2026-02-01,2000.00,Feb rent,Paid
"@
    Set-Content -Path (Join-Path $script:TestDataDir "fixtures" "sample-register.csv") -Value $sampleRegister -Encoding utf8
}

AfterAll {
    if ($script:TestDataDir -and (Test-Path $script:TestDataDir)) {
        Remove-Item -Path $script:TestDataDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe "Bookkeeping Scripts — TAS Generation" -Tag "Bookkeeping", "Unit" {
    It "Build-TAS.ps1 handles fixture CSV data" {
        $scriptPath = Join-Path $script:AcctScripts "Build-TAS.ps1"
        if (-not (Test-Path $scriptPath)) { Set-ItResult -Skipped -Because "Build-TAS.ps1 not found"; return }
        $result = & $scriptPath -WhatIf 2>&1
        $LASTEXITCODE | Should -Be 0 -Because "script should parse without fatal error"
    }

    It "Build-IntersiteTAS.ps1 handles fixture data" {
        $scriptPath = Join-Path $script:AcctScripts "Build-IntersiteTAS.ps1"
        if (-not (Test-Path $scriptPath)) { Set-ItResult -Skipped -Because "Build-IntersiteTAS.ps1 not found"; return }
        { & $scriptPath -WhatIf 2>&1 } | Should -Not -Throw
    }

    It "Build-IntersiteTAS.ps1 declares receipt_exempt in Write-Row" {
        $scriptPath = Join-Path $script:AcctScripts "Build-IntersiteTAS.ps1"
        if (-not (Test-Path $scriptPath)) { Set-ItResult -Skipped -Because "Build-IntersiteTAS.ps1 not found"; return }
        $content = Get-Content $scriptPath -Raw
        $content | Should -Match "receipt_exempt"
        $content | Should -Match "Income .* no receipt required"
        $content | Should -Match "Programmatic exemption"
    }

    It "Build-TAS.ps1 declares receipt_exempt in Write-Row" {
        $scriptPath = Join-Path $script:AcctScripts "Build-TAS.ps1"
        if (-not (Test-Path $scriptPath)) { Set-ItResult -Skipped -Because "Build-TAS.ps1 not found"; return }
        $content = Get-Content $scriptPath -Raw
        $content | Should -Match "receipt_exempt"
        $content | Should -Match "Income .* no receipt required"
        $content | Should -Match "Programmatic exemption"
    }

    It "Invoke-StatusCheck.ps1 checks receipt_exempt column" {
        $scriptPath = Join-Path $script:AcctScripts "Invoke-StatusCheck.ps1"
        if (-not (Test-Path $scriptPath)) { Set-ItResult -Skipped -Because "Invoke-StatusCheck.ps1 not found"; return }
        $content = Get-Content $scriptPath -Raw
        $content | Should -Match "isTasExempt"
        $content | Should -Match "receipt_exempt"
    }

    It "Build-TAS.ps1 — zoho filename derived from cutoff and label" -Tag "Regression" {
        $scriptPath = Join-Path $script:AcctScripts "Build-TAS.ps1"
        if (-not (Test-Path $scriptPath)) { Set-ItResult -Skipped -Because "Build-TAS.ps1 not found"; return }
        $content = Get-Content $scriptPath -Raw
        # zoho filenames should be computed dynamically
        $content | Should -Match 'zoho.*06\.11-Present'
        # Account config should come from shared entity config
        $content | Should -Match 'Get-EntityConfig'
        # WhatIf should display per-file status
        $content | Should -Match 'Expected source files'
    }

    It "Build-TAS.ps1 — crossRefAccounts populated from shared config" -Tag "Regression" {
        $scriptPath = Join-Path $script:AcctScripts "Build-TAS.ps1"
        if (-not (Test-Path $scriptPath)) { Set-ItResult -Skipped -Because "Build-TAS.ps1 not found"; return }
        $content = Get-Content $scriptPath -Raw
        # crossRefAccounts should be built from accountDefs
        $content | Should -Match 'crossRefAccounts = \$accountDefs'
        # Resolve-TransferOutMatch should use dynamic slugs
        $content | Should -Match '\$xrefSlugs = \$crossRefAccounts'
    }

    It "Build-TAS.ps1 — Receipt matching uses [decimal] precision" -Tag "Regression" {
        $scriptPath = Join-Path $script:AcctScripts "Build-TAS.ps1"
        if (-not (Test-Path $scriptPath)) { Set-ItResult -Skipped -Because "Build-TAS.ps1 not found"; return }
        $content = Get-Content $scriptPath -Raw
        # Should parse amounts as [decimal] for receipt matching
        $content | Should -Match '\[decimal\]\$_.amount'
    }

    It "Process-Receipts.ps1 — PDF conversion wraps errors per-file, skips corrupt PDFs" -Tag "Regression" {
        $scriptPath = Join-Path $script:AcctScripts "Process-Receipts.ps1"
        if (-not (Test-Path $scriptPath)) { Set-ItResult -Skipped -Because "Process-Receipts.ps1 not found"; return }
        $content = Get-Content $scriptPath -Raw
        $content | Should -Match 'skippedPdfs'
        $content | Should -Match 'FAILED:'
        $content | Should -Match 'Skipped.*corrupt/unprocessable'
    }

    It "Invoke-Zoho.ps1 — token expiry tracking with 401 retry" -Tag "Regression" {
        $scriptPath = Join-Path $script:AcctScripts "Invoke-Zoho.ps1"
        if (-not (Test-Path $scriptPath)) { Set-ItResult -Skipped -Because "Invoke-Zoho.ps1 not found"; return }
        $content = Get-Content $scriptPath -Raw
        $content | Should -Match 'tokenExpiry'
        $content | Should -Match 'Get-ValidAccessToken'
        $content | Should -Match 'Invoke-ZohoApiCall'
        $content | Should -Match '401|invalid_token'
    }

    It "Invoke-IntersiteMonthlyUpdate.ps1 — TAS backup and diff preservation" -Tag "Regression" {
        $scriptPath = Join-Path $script:AcctScripts "Invoke-IntersiteMonthlyUpdate.ps1"
        if (-not (Test-Path $scriptPath)) { Set-ItResult -Skipped -Because "Invoke-IntersiteMonthlyUpdate.ps1 not found"; return }
        $content = Get-Content $scriptPath -Raw
        $content | Should -Match 'Backup.*saved'
        $content | Should -Match 'TAS content differs from backup'
        $content | Should -Match 'git diff.*no-index'
    }

    It "Invoke-RoomRentalsMonthlyUpdate.ps1 — TAS backup and diff preservation" -Tag "Regression" {
        $scriptPath = Join-Path $script:AcctScripts "Invoke-RoomRentalsMonthlyUpdate.ps1"
        if (-not (Test-Path $scriptPath)) { Set-ItResult -Skipped -Because "Invoke-RoomRentalsMonthlyUpdate.ps1 not found"; return }
        $content = Get-Content $scriptPath -Raw
        $content | Should -Match 'Backup.*saved'
        $content | Should -Match 'TAS content differs from backup'
        $content | Should -Match 'git diff.*no-index'
    }

    It "extract-statement-periods.py — unknown format returns null balance with warning" -Tag "Regression" {
        $scriptPath = Join-Path $script:AcctScripts "pdf" "extract-statement-periods.py"
        if (-not (Test-Path $scriptPath)) { Set-ItResult -Skipped -Because "extract-statement-periods.py not found"; return }
        $content = Get-Content $scriptPath -Raw
        $content | Should -Match "fmt == 'unknown'"
        $content | Should -Match 'ending_balance.*None'
        $content | Should -Match 'Unknown bank format'
        $content | Should -Match 'warning'
    }

    It "Get-EntityConfig.ps1 — loads entity config from cloud-books-entities.json" -Tag "Bookkeeping", "Unit" {
        $sharedPath = Join-Path $script:AcctScripts "shared" "Get-EntityConfig.ps1"
        if (-not (Test-Path $sharedPath)) { Set-ItResult -Skipped -Because "Get-EntityConfig.ps1 not found"; return }
        . $sharedPath
        $cfg = Get-EntityConfig -Entity "room-rentals"
        $cfg.Entity | Should -Not -BeNullOrEmpty
        $cfg.Entity.org_id | Should -Be "925004567"
        $cfg.Entity.cutoff_date | Should -Be "2026-06-10"
        $exempt = Get-ExemptCategories -Entity "room-rentals"
        $exempt | Should -Not -BeNullOrEmpty
        $exempt | Should -Contain "Strata Fees"
    }

    It "Build-IntersiteTAS.ps1 — Duplicate zoho_transaction_id flagged not silently dropped" -Tag "Regression" {
        $scriptPath = Join-Path $script:AcctScripts "Build-IntersiteTAS.ps1"
        if (-not (Test-Path $scriptPath)) { Set-ItResult -Skipped -Because "Build-IntersiteTAS.ps1 not found"; return }
        $content = Get-Content $scriptPath -Raw
        # Should detect and flag duplicate zoho IDs, not silently drop
        $content | Should -Match 'Duplicate zoho_transaction_id'
        $content | Should -Match 'zoho-duplicate'
        $content | Should -Match 'kept both rows'
    }
}

Describe "Bookkeeping Scripts — Statement Processing" -Tag "Bookkeeping", "Unit" {
    It "convert-pdf-statement-to-sidecar.py has valid syntax" {
        $scriptPath = Join-Path $script:AcctScripts "convert-pdf-statement-to-sidecar.py"
        if (-not (Test-Path $scriptPath)) { Set-ItResult -Skipped -Because "convert-pdf-statement-to-sidecar.py not found"; return }
        $result = & python -m py_compile $scriptPath 2>&1
        $LASTEXITCODE | Should -Be 0 -Because "Python script should compile without syntax errors"
    }

    It "convert-pdf-invoice-to-sidecar.py has valid syntax" {
        $scriptPath = Join-Path $script:AcctScripts "convert-pdf-invoice-to-sidecar.py"
        if (-not (Test-Path $scriptPath)) { Set-ItResult -Skipped -Because "convert-pdf-invoice-to-sidecar.py not found"; return }
        $result = & python -m py_compile $scriptPath 2>&1
        $LASTEXITCODE | Should -Be 0 -Because "Python script should compile without syntax errors"
    }

    It "reconcile-sidecars-vs-csv.py has valid syntax" {
        $scriptPath = Join-Path $script:AcctScripts "reconcile-sidecars-vs-csv.py"
        if (-not (Test-Path $scriptPath)) { Set-ItResult -Skipped -Because "reconcile-sidecars-vs-csv.py not found"; return }
        $result = & python -m py_compile $scriptPath 2>&1
        $LASTEXITCODE | Should -Be 0 -Because "Python script should compile without syntax errors"
    }

    It "extract-statement-periods.py has valid syntax" {
        $scriptPath = Join-Path $script:AcctScripts "extract-statement-periods.py"
        if (-not (Test-Path $scriptPath)) { Set-ItResult -Skipped -Because "extract-statement-periods.py not found"; return }
        $result = & python -m py_compile $scriptPath 2>&1
        $LASTEXITCODE | Should -Be 0 -Because "Python script should compile without syntax errors"
    }

    It "dedup-nonmatching.py has valid syntax" {
        $scriptPath = Join-Path $script:AcctScripts "dedup-nonmatching.py"
        if (-not (Test-Path $scriptPath)) { Set-ItResult -Skipped -Because "dedup-nonmatching.py not found"; return }
        $result = & python -m py_compile $scriptPath 2>&1
        $LASTEXITCODE | Should -Be 0 -Because "Python script should compile without syntax errors"
    }
}

Describe "Bookkeeping Scripts — Zoho Helpers" -Tag "Bookkeeping", "Unit" {
    It "zoho-auth.js has valid syntax" {
        $scriptPath = Join-Path $script:AcctScripts "zoho-auth.js"
        if (-not (Test-Path $scriptPath)) { Set-ItResult -Skipped -Because "zoho-auth.js not found"; return }
        $result = & node --check $scriptPath 2>&1
        $LASTEXITCODE | Should -Be 0 -Because "Node.js script should compile without syntax errors"
    }

    It "zoho-expenses.js has valid syntax" {
        $scriptPath = Join-Path $script:AcctScripts "zoho-expenses.js"
        if (-not (Test-Path $scriptPath)) { Set-ItResult -Skipped -Because "zoho-expenses.js not found"; return }
        $result = & node --check $scriptPath 2>&1
        $LASTEXITCODE | Should -Be 0 -Because "Node.js script should compile without syntax errors"
    }

    It "zoho-upload.js has valid syntax" {
        $scriptPath = Join-Path $script:AcctScripts "zoho-upload.js"
        if (-not (Test-Path $scriptPath)) { Set-ItResult -Skipped -Because "zoho-upload.js not found"; return }
        $result = & node --check $scriptPath 2>&1
        $LASTEXITCODE | Should -Be 0 -Because "Node.js script should compile without syntax errors"
    }

    It "zoho-contacts.js has valid syntax" {
        $scriptPath = Join-Path $script:AcctScripts "zoho-contacts.js"
        if (-not (Test-Path $scriptPath)) { Set-ItResult -Skipped -Because "zoho-contacts.js not found"; return }
        $result = & node --check $scriptPath 2>&1
        $LASTEXITCODE | Should -Be 0 -Because "Node.js script should compile without syntax errors"
    }

    It "export-zoho-csv.mjs has valid syntax" {
        $scriptPath = Join-Path $script:AcctScripts "export-zoho-csv.mjs"
        if (-not (Test-Path $scriptPath)) { Set-ItResult -Skipped -Because "export-zoho-csv.mjs not found"; return }
        $result = & node --check $scriptPath 2>&1
        $LASTEXITCODE | Should -Be 0 -Because "Node.js script should compile without syntax errors"
    }

    It "Sync-TasReceiptStatus.mjs has valid syntax" {
        $scriptPath = Join-Path $script:AcctScripts "Sync-TasReceiptStatus.mjs"
        if (-not (Test-Path $scriptPath)) { Set-ItResult -Skipped -Because "Sync-TasReceiptStatus.mjs not found"; return }
        $result = & node --check $scriptPath 2>&1
        $LASTEXITCODE | Should -Be 0 -Because "Node.js script should compile without syntax errors"
    }

    It "sync-local-books-from-zoho.mjs has valid syntax" {
        $scriptPath = Join-Path $script:AcctScripts "sync-local-books-from-zoho.mjs"
        if (-not (Test-Path $scriptPath)) { Set-ItResult -Skipped -Because "sync-local-books-from-zoho.mjs not found"; return }
        $result = & node --check $scriptPath 2>&1
        $LASTEXITCODE | Should -Be 0 -Because "Node.js script should compile without syntax errors"
    }
}

Describe "Bookkeeping Scripts — PowerShell Helpers" -Tag "Bookkeeping", "Unit" {
    It "Get-RentIncomeLedger.ps1 parses without errors" {
        $scriptPath = Join-Path $script:AcctScripts "Get-RentIncomeLedger.ps1"
        if (-not (Test-Path $scriptPath)) { Set-ItResult -Skipped -Because "Get-RentIncomeLedger.ps1 not found"; return }
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseInput(
            (Get-Content $scriptPath -Raw), [ref]$null, [ref]$errors
        )
        $realErrors = $errors | Where-Object { $_.Message -notmatch '\[ref\] cannot be applied' }
        $realErrors.Count | Should -Be 0 -Because "PowerShell script should parse without errors"
    }

    It "Invoke-BookkeepingEnrichment.ps1 parses without errors" {
        $scriptPath = Join-Path $script:AcctScripts "Invoke-BookkeepingEnrichment.ps1"
        if (-not (Test-Path $scriptPath)) { Set-ItResult -Skipped -Because "script not found"; return }
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseInput(
            (Get-Content $scriptPath -Raw), [ref]$null, [ref]$errors
        )
        $realErrors = $errors | Where-Object { $_.Message -notmatch '\[ref\] cannot be applied' }
        $realErrors.Count | Should -Be 0
    }

    It "Invoke-StatusCheck.ps1 parses without errors" {
        $scriptPath = Join-Path $script:AcctScripts "Invoke-StatusCheck.ps1"
        if (-not (Test-Path $scriptPath)) { Set-ItResult -Skipped -Because "script not found"; return }
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseInput(
            (Get-Content $scriptPath -Raw), [ref]$null, [ref]$errors
        )
        $realErrors = $errors | Where-Object { $_.Message -notmatch '\[ref\] cannot be applied' }
        $realErrors.Count | Should -Be 0
    }

    It "Update-ReconciliationPeriods.ps1 parses without errors" {
        $scriptPath = Join-Path $script:AcctScripts "Update-ReconciliationPeriods.ps1"
        if (-not (Test-Path $scriptPath)) { Set-ItResult -Skipped -Because "script not found"; return }
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseInput(
            (Get-Content $scriptPath -Raw), [ref]$null, [ref]$errors
        )
        $realErrors = $errors | Where-Object { $_.Message -notmatch '\[ref\] cannot be applied' }
        $realErrors.Count | Should -Be 0
    }

    It "Process-Receipts.ps1 parses without errors" {
        $scriptPath = Join-Path $script:AcctScripts "Process-Receipts.ps1"
        if (-not (Test-Path $scriptPath)) { Set-ItResult -Skipped -Because "script not found"; return }
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseInput(
            (Get-Content $scriptPath -Raw), [ref]$null, [ref]$errors
        )
        $realErrors = $errors | Where-Object { $_.Message -notmatch '\[ref\] cannot be applied' }
        $realErrors.Count | Should -Be 0
    }

    It "Invoke-Zoho.ps1 no `${Global}: references remain" {
        $scriptPath = Join-Path $script:AcctScripts "Invoke-Zoho.ps1"
        if (-not (Test-Path $scriptPath)) { Set-ItResult -Skipped -Because "script not found"; return }
        $content = Get-Content $scriptPath -Raw
        # Should not reference $Global:ClientId, $Global:ClientSecret, $Global:RefreshToken
        $content | Should -Not -Match '\$Global:Client'
        $content | Should -Not -Match '\$Global:RefreshToken'
    }

    It "Invoke-Zoho.ps1 uses `${script}: scope for credential assignment" {
        $scriptPath = Join-Path $script:AcctScripts "Invoke-Zoho.ps1"
        if (-not (Test-Path $scriptPath)) { Set-ItResult -Skipped -Because "script not found"; return }
        $content = Get-Content $scriptPath -Raw
        $content | Should -Match '\$script:ZohoClientId\s*='
        $content | Should -Match '\$script:ZohoClientSecret\s*='
        $content | Should -Match '\$script:ZohoRefreshToken\s*='
    }

    It "Invoke-Zoho.ps1 validates receipt dates instead of silent fallback" {
        $scriptPath = Join-Path $script:AcctScripts "Invoke-Zoho.ps1"
        if (-not (Test-Path $scriptPath)) { Set-ItResult -Skipped -Because "script not found"; return }
        $content = Get-Content $scriptPath -Raw
        # Should reject malformed dates rather than falling back to Get-Date
        $content | Should -Match 'malformed date'
        $content | Should -Not -Match '\$date = .*\$r\.date.*Get-Date'
    }

    It "Build-TAS.ps1 has description backfill section" {
        $scriptPath = Join-Path $script:AcctScripts "Build-TAS.ps1"
        if (-not (Test-Path $scriptPath)) { Set-ItResult -Skipped -Because "script not found"; return }
        $content = Get-Content $scriptPath -Raw
        $content | Should -Match 'Backfill descriptions from raw bank CSVs'
        $content | Should -Match '\$backfilledCount'
    }
}

Describe "Sync-TasReceiptStatus.mjs — write pattern" -Tag "Bookkeeping", "Unit" {
    It "uses atomic write pattern (temp file + rename)" {
        $scriptPath = Join-Path $script:AcctScripts "Sync-TasReceiptStatus.mjs"
        if (-not (Test-Path $scriptPath)) { Set-ItResult -Skipped -Because "script not found"; return }
        $content = Get-Content $scriptPath -Raw
        $content | Should -Match '\.tmp\.'
        $content | Should -Match 'renameSync'
        $content | Should -Match '\.lck'
    }

    It "uses timestamped backup instead of hardcoded .bak3" {
        $scriptPath = Join-Path $script:AcctScripts "Sync-TasReceiptStatus.mjs"
        if (-not (Test-Path $scriptPath)) { Set-ItResult -Skipped -Because "script not found"; return }
        $content = Get-Content $scriptPath -Raw
        $content | Should -Match 'Date\.now\(\)'
        $content | Should -Not -Match '\.bak3'
    }
}
