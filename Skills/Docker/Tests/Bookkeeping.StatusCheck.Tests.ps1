#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

# ==============================================================================
# Interclaw — Pester 5 Tests for Bookkeeping Status Check (Invoke-StatusCheck.ps1)
# ==============================================================================

Describe "Invoke-StatusCheck.ps1" -Tag "Bookkeeping" {
    Context "File existence" {
        It "script exists in Skills/Bookkeeping/Scripts/" {
            Join-Path $PSScriptRoot "..\..\..\Skills\Bookkeeping\Scripts\Invoke-StatusCheck.ps1" | Should -Exist
        }
    }

    Context "Date parsing" {
        BeforeAll {
            . (Join-Path $PSScriptRoot "..\..\..\Skills\Bookkeeping\Scripts\Invoke-StatusCheck.ps1") -Organization intersite-consulting 3>$null
        }

        It "parses yyyy-MM-dd dates" {
            $dt = Parse-DateFlexible "2026-06-17"
            $dt | Should -BeOfType [datetime]
            $dt.ToString("yyyy-MM-dd") | Should -Be "2026-06-17"
        }

        It "parses M/d/yyyy dates" {
            $dt = Parse-DateFlexible "1/13/2026"
            $dt | Should -BeOfType [datetime]
            $dt.ToString("yyyy-MM-dd") | Should -Be "2026-01-13"
        }

        It "returns null for empty date" {
            $dt = Parse-DateFlexible ""
            $dt | Should -BeNullOrEmpty
        }

        It "returns null for whitespace date" {
            $dt = Parse-DateFlexible "   "
            $dt | Should -BeNullOrEmpty
        }
    }

    Context "Transaction complete date computation" {
        BeforeAll {
            . (Join-Path $PSScriptRoot "..\..\..\Skills\Bookkeeping\Scripts\Invoke-StatusCheck.ps1") -Organization intersite-consulting 3>$null
        }

        It "returns latest date when sources are continuous" {
            $sources = @(
                @{ label = 'raw'; range = @{ min_date = [datetime]"2026-01-01"; max_date = [datetime]"2026-06-10"; count = 100 } }
                @{ label = 'zoho'; range = @{ min_date = [datetime]"2026-01-01"; max_date = [datetime]"2026-06-17"; count = 50 } }
            )
            $result = Compute-TransactionCompleteDate $sources
            $result | Should -Be "2026-06-17"
        }

        It "stops at gap between sources" {
            $sources = @(
                @{ label = 'raw'; range = @{ min_date = [datetime]"2026-01-01"; max_date = [datetime]"2026-07-31"; count = 100 } }
                @{ label = 'zoho'; range = @{ min_date = [datetime]"2026-09-01"; max_date = [datetime]"2026-12-31"; count = 50 } }
            )
            $result = Compute-TransactionCompleteDate $sources
            $result | Should -Be "2026-07-31"
        }

        It "returns null when no sources" {
            $result = Compute-TransactionCompleteDate @()
            $result | Should -BeNullOrEmpty
        }

        It "handles single source" {
            $sources = @(
                @{ label = 'raw'; range = @{ min_date = [datetime]"2026-01-01"; max_date = [datetime]"2026-06-10"; count = 100 } }
            )
            $result = Compute-TransactionCompleteDate $sources
            $result | Should -Be "2026-06-10"
        }
    }

    Context "Receipt complete date computation" {
        BeforeAll {
            . (Join-Path $PSScriptRoot "..\..\..\Skills\Bookkeeping\Scripts\Invoke-StatusCheck.ps1") -Organization intersite-consulting 3>$null
        }

        It "advances through transactions with receipts" {
            $rows = @(
                [PSCustomObject]@{ date = "2026-01-01"; receipt_filename = "receipt1.jpg"; category = "Office Expenses" }
                [PSCustomObject]@{ date = "2026-01-02"; receipt_filename = "receipt2.jpg"; category = "Office Expenses" }
                [PSCustomObject]@{ date = "2026-01-05"; receipt_filename = "receipt3.jpg"; category = "Office Expenses" }
            )
            $result = Compute-ReceiptCompleteDate -TasRows $rows -ExemptCategories @()
            $result | Should -Be "2026-01-05"
        }

        It "stops at first transaction without receipt" {
            $rows = @(
                [PSCustomObject]@{ date = "2026-01-01"; receipt_filename = "receipt1.jpg"; category = "Automobile Expense" }
                [PSCustomObject]@{ date = "2026-01-02"; receipt_filename = ""; category = "Office Expenses" }
                [PSCustomObject]@{ date = "2026-01-05"; receipt_filename = "receipt3.jpg"; category = "Office Expenses" }
            )
            $result = Compute-ReceiptCompleteDate -TasRows $rows -ExemptCategories @()
            $result | Should -Be "2026-01-01"
        }

        It "skips exempt categories even without receipt" {
            $rows = @(
                [PSCustomObject]@{ date = "2026-01-01"; receipt_filename = ""; category = "Strata Fees" }
                [PSCustomObject]@{ date = "2026-01-02"; receipt_filename = ""; category = "Insurance" }
                [PSCustomObject]@{ date = "2026-01-05"; receipt_filename = ""; category = "Bank Fee" }
            )
            $result = Compute-ReceiptCompleteDate -TasRows $rows -ExemptCategories @("Strata Fees", "Insurance", "Bank Fee")
            $result | Should -Be "2026-01-05"
        }

        It "returns null when first transaction has no receipt and is not exempt" {
            $rows = @(
                [PSCustomObject]@{ date = "2026-01-01"; receipt_filename = ""; category = "Office Expenses" }
            )
            $result = Compute-ReceiptCompleteDate -TasRows $rows -ExemptCategories @("Strata Fees")
            $result | Should -BeNullOrEmpty
        }

        It "returns null when TAS rows are empty" {
            $result = Compute-ReceiptCompleteDate -TasRows @() -ExemptCategories @("Strata Fees")
            $result | Should -BeNullOrEmpty
        }
    }

    Context "Integration — org definitions contain expected accounts" {
        BeforeAll {
            . (Join-Path $PSScriptRoot "..\..\..\Skills\Bookkeeping\Scripts\Invoke-StatusCheck.ps1") -Organization intersite-consulting 3>$null
        }

        It "intersite-consulting has 2 accounts" {
            $orgDefs['intersite-consulting'].accounts.Count | Should -Be 2
        }

        It "room-rentals has 4 accounts" {
            $orgDefs['room-rentals'].accounts.Count | Should -Be 4
        }

        It "all intersite accounts have rawDateColumn defined" {
            foreach ($acct in $orgDefs['intersite-consulting'].accounts) {
                $acct.rawDateColumn | Should -Not -BeNullOrEmpty
            }
        }

        It "all room-rentals accounts have rawDateColumn defined" {
            foreach ($acct in $orgDefs['room-rentals'].accounts) {
                $acct.rawDateColumn | Should -Not -BeNullOrEmpty
            }
        }
    }

    Context "Manifest-based receipt date — covered-date lookup" {
        BeforeAll {
            . (Join-Path $PSScriptRoot "..\..\..\Skills\Bookkeeping\Scripts\Invoke-StatusCheck.ps1") -Organization intersite-consulting 3>$null
            $script:tmpManifest = Join-Path ([System.IO.Path]::GetTempPath()) ("manifest-test-" + [Guid]::NewGuid() + ".csv")
            $script:manifestContent = @"
"filename","date","amount","vendor","account","sha256","zoho_expense_id","zoho_document_id","source","status","notes"
"r1.pdf","2026-01-05","50.00","Acme","acct-1","aaa","","","local","matched",""
"r2.pdf","2026-01-10","30.00","Foo","acct-1","bbb","","","local","matched",""
"r3.pdf","2026-01-15","20.00","Bar","acct-1","ccc","","","local","orphan",""
"r4.pdf","2026-01-20","10.00","Baz","acct-2","ddd","","","local","matched",""
"r5.pdf","2026-01-25","5.00","Qux","acct-1","eee","","","local","uploaded",""
"r6.pdf","2026-02-01","7.00","Quux","acct-1","fff","","","local","archived",""
"r7.pdf","2026-02-05","9.00","Corge","acct-1","ggg","","","local","zoho_only",""
"@
            Set-Content -LiteralPath $script:tmpManifest -Value $script:manifestContent -Encoding utf8
        }
        AfterAll {
            if (Test-Path $script:tmpManifest) { Remove-Item $script:tmpManifest -Force }
        }

        It "returns null for missing manifest" {
            $result = Read-ManifestCoveredDates -ManifestPath "C:\nonexistent\manifest.csv" -AccountFilter "acct-1"
            $result | Should -BeNullOrEmpty
        }

        It "includes all rows with date+amount regardless of status" {
            $covered = Read-ManifestCoveredDates -ManifestPath $script:tmpManifest -AccountFilter "acct-1"
            $covered.Keys.Count | Should -Be 6
            $covered.ContainsKey("2026-01-05") | Should -BeTrue
            $covered.ContainsKey("2026-01-10") | Should -BeTrue
            $covered.ContainsKey("2026-01-25") | Should -BeTrue
            $covered.ContainsKey("2026-02-01") | Should -BeTrue
            $covered.ContainsKey("2026-01-15") | Should -BeTrue
            $covered.ContainsKey("2026-02-05") | Should -BeTrue
        }

        It "filters by account" {
            $covered = Read-ManifestCoveredDates -ManifestPath $script:tmpManifest -AccountFilter "acct-2"
            $covered.Keys.Count | Should -Be 1
            $covered.ContainsKey("2026-01-20") | Should -BeTrue
        }
    }

    Context "Manifest-based receipt date — main computation" {
        BeforeAll {
            . (Join-Path $PSScriptRoot "..\..\..\Skills\Bookkeeping\Scripts\Invoke-StatusCheck.ps1") -Organization intersite-consulting 3>$null
            $script:tmpManifest = Join-Path ([System.IO.Path]::GetTempPath()) ("manifest-test2-" + [Guid]::NewGuid() + ".csv")
            $script:manifestContent = @"
"filename","date","amount","vendor","account","sha256","zoho_expense_id","zoho_document_id","source","status","notes"
"r1.pdf","2026-01-05","50.00","Acme","acct-1","aaa","","","local","matched",""
"r2.pdf","2026-01-10","30.00","Foo","acct-1","bbb","","","local","matched",""
"r3.pdf","2026-01-25","5.00","Qux","acct-1","eee","","","local","uploaded",""
"@
            Set-Content -LiteralPath $script:tmpManifest -Value $script:manifestContent -Encoding utf8
        }
        AfterAll {
            if (Test-Path $script:tmpManifest) { Remove-Item $script:tmpManifest -Force }
        }

        It "advances while TAS dates are in the covered set" {
            $rows = @(
                [PSCustomObject]@{ date = "2026-01-05"; category = "Office Expenses" }
                [PSCustomObject]@{ date = "2026-01-10"; category = "Office Expenses" }
            )
            $result = Compute-ReceiptCompleteDateFromManifest -ManifestPath $script:tmpManifest -AccountFilter "acct-1" -TasRows $rows -ExemptCategories @()
            $result | Should -Be "2026-01-10"
        }

        It "stops at first TAS date not in covered set" {
            $rows = @(
                [PSCustomObject]@{ date = "2026-01-05"; category = "Office Expenses" }
                [PSCustomObject]@{ date = "2026-01-08"; category = "Office Expenses" }
                [PSCustomObject]@{ date = "2026-01-10"; category = "Office Expenses" }
            )
            $result = Compute-ReceiptCompleteDateFromManifest -ManifestPath $script:tmpManifest -AccountFilter "acct-1" -TasRows $rows -ExemptCategories @()
            $result | Should -Be "2026-01-05"
        }

        It "exempt categories do not need manifest coverage" {
            $rows = @(
                [PSCustomObject]@{ date = "2026-01-05"; category = "Office Expenses" }
                [PSCustomObject]@{ date = "2026-01-10"; category = "Office Expenses" }
                [PSCustomObject]@{ date = "2026-01-20"; category = "Bank Fee" }
            )
            $result = Compute-ReceiptCompleteDateFromManifest -ManifestPath $script:tmpManifest -AccountFilter "acct-1" -TasRows $rows -ExemptCategories @("Bank Fee")
            $result | Should -Be "2026-01-20"
        }

        It "treats uploaded as covered" {
            $rows = @(
                [PSCustomObject]@{ date = "2026-01-25"; category = "Office Expenses" }
            )
            $result = Compute-ReceiptCompleteDateFromManifest -ManifestPath $script:tmpManifest -AccountFilter "acct-1" -TasRows $rows -ExemptCategories @()
            $result | Should -Be "2026-01-25"
        }

        It "returns null when manifest does not exist" {
            $rows = @(
                [PSCustomObject]@{ date = "2026-01-05"; category = "Office Expenses" }
            )
            $result = Compute-ReceiptCompleteDateFromManifest -ManifestPath "C:\nonexistent\manifest.csv" -AccountFilter "acct-1" -TasRows $rows -ExemptCategories @()
            $result | Should -BeNullOrEmpty
        }

        It "returns null when no TAS rows" {
            $result = Compute-ReceiptCompleteDateFromManifest -ManifestPath $script:tmpManifest -AccountFilter "acct-1" -TasRows @() -ExemptCategories @()
            $result | Should -BeNullOrEmpty
        }

        It "respects account filter — row in another account does not count" {
            $script:tmpManifest2 = Join-Path ([System.IO.Path]::GetTempPath()) ("manifest-test-acct-" + [Guid]::NewGuid() + ".csv")
            $otherContent = @"
"filename","date","amount","vendor","account","sha256","zoho_expense_id","zoho_document_id","source","status","notes"
"x.pdf","2026-01-05","50.00","Acme","acct-2","aaa","","","local","matched",""
"@
            Set-Content -LiteralPath $script:tmpManifest2 -Value $otherContent -Encoding utf8
            try {
                $rows = @(
                    [PSCustomObject]@{ date = "2026-01-05"; category = "Office Expenses" }
                )
                $result = Compute-ReceiptCompleteDateFromManifest -ManifestPath $script:tmpManifest2 -AccountFilter "acct-1" -TasRows $rows -ExemptCategories @()
                $result | Should -BeNullOrEmpty
            } finally {
                if (Test-Path $script:tmpManifest2) { Remove-Item $script:tmpManifest2 -Force }
            }
        }
    }

    Context "Min-DateString helper" {
        BeforeAll {
            . (Join-Path $PSScriptRoot "..\..\..\Skills\Bookkeeping\Scripts\Invoke-StatusCheck.ps1") -Organization intersite-consulting 3>$null
        }

        It "returns B when A is null" {
            Min-DateString -A $null -B "2026-01-01" | Should -Be "2026-01-01"
        }

        It "returns A when B is null" {
            Min-DateString -A "2026-01-01" -B $null | Should -Be "2026-01-01"
        }

        It "returns the earlier date" {
            Min-DateString -A "2026-01-15" -B "2026-01-10" | Should -Be "2026-01-10"
        }

        It "returns A when equal" {
            Min-DateString -A "2026-01-10" -B "2026-01-10" | Should -Be "2026-01-10"
        }
    }
}
