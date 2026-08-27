#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

# ==============================================================================
# Interclaw — Pester 5 Tests for Receipt Manifest & Pipeline
# Tests for Find-Receipt, Parse-DateFlexible, Read-ManifestCoveredDates,
# and Rebuild-Manifest validation.
# ==============================================================================

BeforeAll {
    $scriptRoot = Resolve-Path "$PSScriptRoot\..\..\.."
    $acctScripts = "$scriptRoot\Skills\Bookkeeping\Scripts"
}

Describe "Find-Receipt matching" -Tag "Bookkeeping", "Manifest" {
    BeforeAll {
        # Replica of Find-Receipt from Build-IntersiteTAS.ps1
        function Find-Receipt($dt, $amt) {
            $absAmt = [math]::Abs([double]$amt)
            $key = "$dt|$("{0:F2}" -f $absAmt)"
            if ($script:receipts.ContainsKey($key)) {
                return ($script:receipts[$key] | Select-Object -First 1)
            }
            $bd = Get-Date $dt
            foreach ($entry in $script:receipts.GetEnumerator()) {
                $parts = $entry.Key -split '\|'
                $rAmt = [double]$parts[1]
                if ([math]::Abs($rAmt - $absAmt) -gt 0.1) { continue }
                $dd = ((Get-Date $parts[0]) - $bd).TotalDays
                if ([math]::Abs($dd) -le 3) { return ($entry.Value | Select-Object -First 1) }
            }
            return $null
        }

        $script:receipts = [System.Collections.Generic.Dictionary[string, object]]@{}
        $script:receipts["2026-01-15|33.60"] = @("rbc-6258/2026-01-15 - 33.60 - Freedom.pdf")
        $script:receipts["2026-01-20|100.00"] = @("rbc-6258/2026-01-20 - 100.00 - Amazon.pdf")
    }

    It "matches exact date and amount" {
        $result = Find-Receipt "2026-01-15" 33.60
        $result | Should -Be "rbc-6258/2026-01-15 - 33.60 - Freedom.pdf"
    }

    It "matches fuzzy amount within `$0.10" {
        $result = Find-Receipt "2026-01-15" 33.67
        $result | Should -Be "rbc-6258/2026-01-15 - 33.60 - Freedom.pdf"
    }

    It "matches fuzzy date within 3 days" {
        $result = Find-Receipt "2026-01-17" 100.00
        $result | Should -Be "rbc-6258/2026-01-20 - 100.00 - Amazon.pdf"
    }

    It "returns null for no match" {
        $result = Find-Receipt "2026-06-01" 999.99
        $result | Should -BeNullOrEmpty
    }

    It "uses {0:F2} key format for consistency" {
        $key = "2026-01-15|$("{0:F2}" -f 33.60)"
        $script:receipts.ContainsKey($key) | Should -BeTrue
    }

    It "handles negative amounts by absolute value" {
        $result = Find-Receipt "2026-01-20" -100.00
        $result | Should -Be "rbc-6258/2026-01-20 - 100.00 - Amazon.pdf"
    }
}

Describe "Parse-DateFlexible" -Tag "Bookkeeping", "Manifest" {
    BeforeAll {
        # Replica of Parse-DateFlexible from Invoke-StatusCheck.ps1
        function Parse-DateFlexible {
            param([string]$DateStr)
            if ([string]::IsNullOrWhiteSpace($DateStr)) { return $null }
            $d = $DateStr.Trim()
            $result = [datetime]::MinValue
            if ([datetime]::TryParseExact($d, 'yyyy-MM-dd', [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$result)) { return $result }
            if ([datetime]::TryParseExact($d, 'M/d/yyyy', [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$result)) { return $result }
            if ([datetime]::TryParseExact($d, 'yyyy-M-d', [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$result)) { return $result }
            if ([datetime]::TryParse($d, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$result)) { return $result }
            return $null
        }
    }

    It "handles yyyy-MM-dd format" {
        $result = Parse-DateFlexible "2026-01-15"
        $result | Should -Not -BeNullOrEmpty
        $result.ToString("yyyy-MM-dd") | Should -Be "2026-01-15"
    }

    It "handles M/d/yyyy format" {
        $result = Parse-DateFlexible "1/15/2026"
        $result | Should -Not -BeNullOrEmpty
        $result.ToString("yyyy-MM-dd") | Should -Be "2026-01-15"
    }

    It "handles yyyy-M-d format" {
        $result = Parse-DateFlexible "2026-1-5"
        $result | Should -Not -BeNullOrEmpty
        $result.ToString("yyyy-MM-dd") | Should -Be "2026-01-05"
    }

    It "returns null for empty string" {
        $result = Parse-DateFlexible ""
        $result | Should -BeNullOrEmpty
    }

    It "returns null for invalid date" {
        $result = Parse-DateFlexible "not-a-date"
        $result | Should -BeNullOrEmpty
    }

    It "trims whitespace" {
        $result = Parse-DateFlexible "  2026-01-15  "
        $result | Should -Not -BeNullOrEmpty
        $result.ToString("yyyy-MM-dd") | Should -Be "2026-01-15"
    }

    It "returns null for null input" {
        $result = Parse-DateFlexible $null
        $result | Should -BeNullOrEmpty
    }
}

Describe "Read-ManifestCoveredDates" -Tag "Bookkeeping", "Manifest" {
    BeforeAll {
        # Replica of Parse-DateFlexible (needed by Read-ManifestCoveredDates)
        function Parse-DateFlexible {
            param([string]$DateStr)
            if ([string]::IsNullOrWhiteSpace($DateStr)) { return $null }
            $d = $DateStr.Trim()
            $result = [datetime]::MinValue
            if ([datetime]::TryParseExact($d, 'yyyy-MM-dd', [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$result)) { return $result }
            if ([datetime]::TryParseExact($d, 'M/d/yyyy', [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$result)) { return $result }
            if ([datetime]::TryParseExact($d, 'yyyy-M-d', [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$result)) { return $result }
            if ([datetime]::TryParse($d, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$result)) { return $result }
            return $null
        }

        # Replica of Read-ManifestCoveredDates from Invoke-StatusCheck.ps1
        function Read-ManifestCoveredDates {
            param([string]$ManifestPath, [string]$AccountFilter)
            if (-not $ManifestPath -or -not (Test-Path $ManifestPath)) { return $null }
            try {
                $rows = Import-Csv $ManifestPath
            } catch {
                return $null
            }
            if (-not $rows -or $rows.Count -eq 0) { return @{} }
            $covered = @{}
            foreach ($row in $rows) {
                if ($AccountFilter -and $row.account -ne $AccountFilter) { continue }
                if ([string]::IsNullOrWhiteSpace($row.date)) { continue }
                if ([string]::IsNullOrWhiteSpace($row.amount)) { continue }
                $dt = Parse-DateFlexible $row.date
                if ($dt) { $covered[$dt.ToString('yyyy-MM-dd')] = $true }
            }
            return $covered
        }
    }

    It "counts orphan-status rows (after bug fix)" {
        $testCsv = Join-Path $TestDrive "test_orphan.csv"
        @"
filename,date,amount,vendor,account,status
file1.pdf,2026-01-15,33.60,Freedom,rbc-6258,matched
file2.pdf,2026-01-20,100.00,Amazon,rbc-6258,orphan
"@ | Set-Content $testCsv -Encoding utf8

        $covered = Read-ManifestCoveredDates -ManifestPath $testCsv
        $covered.ContainsKey("2026-01-15") | Should -BeTrue
        $covered.ContainsKey("2026-01-20") | Should -BeTrue
    }

    It "returns null for nonexistent path" {
        $result = Read-ManifestCoveredDates -ManifestPath "C:\nonexistent\file.csv"
        $result | Should -BeNullOrEmpty
    }

    It "filters by account if AccountFilter is set" {
        $testCsv = Join-Path $TestDrive "test_filter.csv"
        @"
filename,date,amount,vendor,account,status
f1.pdf,2026-01-15,33.60,Freedom,rbc-6258,matched
f2.pdf,2026-01-20,100.00,Amazon,rbc-intersite,matched
"@ | Set-Content $testCsv -Encoding utf8

        $covered = Read-ManifestCoveredDates -ManifestPath $testCsv -AccountFilter "rbc-6258"
        $covered.ContainsKey("2026-01-15") | Should -BeTrue
        $covered.ContainsKey("2026-01-20") | Should -BeFalse
    }

    It "returns empty hash for empty file" {
        $testCsv = Join-Path $TestDrive "empty.csv"
        "filename,date,amount,vendor,account,status" | Set-Content $testCsv -Encoding utf8

        $covered = Read-ManifestCoveredDates -ManifestPath $testCsv
        $covered.Count | Should -Be 0
    }

    It "skips rows with empty date" {
        $testCsv = Join-Path $TestDrive "empty_date.csv"
        @"
filename,date,amount,vendor,account,status
f1.pdf,,33.60,Freedom,rbc-6258,matched
f2.pdf,2026-01-20,100.00,Amazon,rbc-6258,matched
"@ | Set-Content $testCsv -Encoding utf8

        $covered = Read-ManifestCoveredDates -ManifestPath $testCsv
        $covered.ContainsKey("2026-01-20") | Should -BeTrue
        $covered.Count | Should -Be 1
    }

    It "skips rows with empty amount" {
        $testCsv = Join-Path $TestDrive "empty_amt.csv"
        @"
filename,date,amount,vendor,account,status
f1.pdf,2026-01-15,,Freedom,rbc-6258,matched
"@ | Set-Content $testCsv -Encoding utf8

        $covered = Read-ManifestCoveredDates -ManifestPath $testCsv
        $covered.Count | Should -Be 0
    }
}

Describe "Rebuild-Manifest validation" -Tag "Bookkeeping", "Manifest" {
    It "marks unparseable filenames via receipt_utils" {
        $pyPath = $acctScripts -replace '\\', '/'
        $parseResult = & python -c "import sys; sys.path.insert(0, '$pyPath'); from receipt_utils import parse_filename_meta; meta = parse_filename_meta('IMG_0001.jpg'); print('ok' if meta is None else 'fail')" 2>&1
        $parseResult | Should -Be "ok"

        $parseResult2 = & python -c "import sys; sys.path.insert(0, '$pyPath'); from receipt_utils import parse_filename_meta; meta = parse_filename_meta('2026-01-15 - 33.60 - Freedom.pdf'); print('ok' if meta and meta['date'] == '2026-01-15' else 'fail')" 2>&1
        $parseResult2 | Should -Be "ok"
    }

    It "skips non-matching dirs in file walk" {
        $testDir = Join-Path $TestDrive "walktest"
        New-Item -ItemType Directory -Path "$testDir\sub1" -Force | Out-Null
        New-Item -ItemType Directory -Path "$testDir\sub2\non-matching" -Force | Out-Null

        Set-Content -Path "$testDir\sub1\2026-01-01 - 10.00 - A.pdf" -Value "a"
        Set-Content -Path "$testDir\sub1\2026-01-02 - 20.00 - B.jpg" -Value "b"
        Set-Content -Path "$testDir\sub2\non-matching\2026-01-03 - 30.00 - C.pdf" -Value "c"

        $skipDirs = @('non-matching')
        $files = Get-ChildItem $testDir -Recurse -File -Include *.pdf,*.jpg,*.jpeg,*.png | Where-Object {
            $fullPath = $_.FullName
            $inSkip = $false
            foreach ($sd in $skipDirs) {
                if ($fullPath -match "\\$sd" -or $fullPath -match "/$sd") {
                    $inSkip = $true; break
                }
            }
            -not $inSkip
        }
        $files.Count | Should -Be 2
    }
}
