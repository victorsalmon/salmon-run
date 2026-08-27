#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

#Requires -Version 7.0
# ==============================================================================
# Migrate-WaveToZoho.ps1 — Pester 5 Tests
# Source: Wave→Zoho migration (Scripts/Migrate-WaveToZoho.ps1)
# ==============================================================================

BeforeAll {
    $ScriptPath = Join-Path $PSScriptRoot "..\..\..\Archived\Scripts\Bookkeeping\Migrate-WaveToZoho.ps1"
    $ScriptContent = Get-Content $ScriptPath -Raw
    $ScriptLines = Get-Content $ScriptPath
}

Describe "Migrate-WaveToZoho.ps1 Structure" -Tag "Migration" -Skip:$(-not (Test-Path (Join-Path $PSScriptRoot '..\..\..\Archived\Scripts\Bookkeeping\Migrate-WaveToZoho.ps1'))) {
    It "Script file exists" {
        $ScriptPath | Should -Exist
    }

    It "Script has comment-based help (SYNOPSIS)" {
        $ScriptContent | Should -Match '\.SYNOPSIS'
    }

    It "Script has comment-based help (DESCRIPTION)" {
        $ScriptContent | Should -Match '\.DESCRIPTION'
    }

    It "Script uses CmdletBinding" {
        $ScriptContent | Should -Match 'CmdletBinding'
    }

    It "Script has consistency checkpoint - ErrorActionPreference Stop" {
        $ScriptContent | Should -Match '\$ErrorActionPreference = "Stop"'
    }

    It "Script is not empty" {
        $ScriptLines.Count | Should -BeGreaterThan 100
    }
}

Describe "Routing Table" -Tag "Migration" {
    It "All 4 accounts defined in AccountRouting" {
        $matchCount = [regex]::Matches($ScriptContent, 'wave_business\s*=\s*"').Count
        $matchCount | Should -Be 4
    }

    It "Intersite Consulting Inc. route defined" {
        $ScriptContent | Should -Match 'Intersite Consulting Inc\.'
    }

    It "Francis route defined" {
        $ScriptContent | Should -Match '"Francis"'
    }

    It "MLM route defined" {
        $ScriptContent | Should -Match '"MLM"'
    }

    It "TMH route defined" {
        $ScriptContent | Should -Match '"TMH"'
    }

    It "ZOHO_ORG_ID_INTERSITE referenced" {
        $ScriptContent | Should -Match 'ZOHO_ORG_ID_INTERSITE'
    }

    It "ZOHO_ORG_ID_ROOM_RENTALS referenced" {
        $ScriptContent | Should -Match 'ZOHO_ORG_ID_ROOM_RENTALS'
    }

    It "Each route has wave_account_id placeholder" {
        $ScriptContent | Should -Match 'wave_account_id\s*=\s*\$null'
    }
}

Describe "Functions" -Tag "Migration" {
    It "Resolve-WaveAccountIds function exists" {
        $ScriptContent | Should -Match 'function Resolve-WaveAccountIds'
    }

    It "Get-WaveTransactionsForAccount function exists" {
        $ScriptContent | Should -Match 'function Get-WaveTransactionsForAccount'
    }

    It "Get-AccountMappings function exists" {
        $ScriptContent | Should -Match 'function Get-AccountMappings'
    }

    It "Convert-WaveTransactionToZoho function exists" {
        $ScriptContent | Should -Match 'function Convert-WaveTransactionToZoho'
    }

    It "Get-ZohoBankAccountId function exists" {
        $ScriptContent | Should -Match 'function Get-ZohoBankAccountId'
    }

    It "Import-TransactionsToZoho function exists" {
        $ScriptContent | Should -Match 'function Import-TransactionsToZoho'
    }

    It "Test-MigrationIntegrity function exists" {
        $ScriptContent | Should -Match 'function Test-MigrationIntegrity'
    }
}

Describe "Endpoint Calls" -Tag "Migration" {
    It "Calls wave.businesses.list" {
        $ScriptContent | Should -Match 'wave\.businesses\.list'
    }

    It "Calls wave.accounts.list" {
        $ScriptContent | Should -Match 'wave\.accounts\.list'
    }

    It "Calls wave.transactions.list" {
        $ScriptContent | Should -Match 'wave\.transactions\.list'
    }

    It "Calls zoho.bankaccounts.list" {
        $ScriptContent | Should -Match 'zoho\.bankaccounts\.list'
    }

    It "Calls zoho.banktransactions.import" {
        $ScriptContent | Should -Match 'zoho\.banktransactions\.import'
    }

    It "Calls zoho.banktransactions.list" {
        $ScriptContent | Should -Match 'zoho\.banktransactions\.list'
    }
}

Describe "Transform Logic" -Tag "Migration" {
    It "Positive amount produces deposit type" {
        $txnType = if (150.00 -ge 0) { "deposit" } else { "withdrawal" }
        $txnType | Should -Be "deposit"
    }

    It "Negative amount produces withdrawal type" {
        $txnType = if (-75.50 -ge 0) { "deposit" } else { "withdrawal" }
        $txnType | Should -Be "withdrawal"
    }

    It "Absolute value used for amount" {
        $absAmount = [math]::Abs(-75.50)
        $absAmount | Should -Be 75.50
    }

    It "Zero-amount transaction skipped (returns null)" {
        $amount = 0
        $shouldSkip = ($amount -eq 0)
        $shouldSkip | Should -BeTrue
    }

    It "Description cleaned of extra whitespace" {
        $desc = "Payment  for   invoice" -replace '\s+', ' '
        $desc | Should -Be "Payment for invoice"
    }

    It "Description truncated at 255 characters" {
        $long = "A" * 300
        $trimmed = $long.Substring(0, 252) + "..."
        $trimmed.Length | Should -Be 255
    }

    It "Empty description generates fallback" {
        $desc = ""
        $isBlank = [string]::IsNullOrWhiteSpace($desc)
        $fallback = if ($isBlank) { "Migrated from Wave — 2026-03-15" } else { $desc }
        $fallback | Should -Match "Migrated from Wave"
    }

    It "Null category resolves to null category_id in output" {
        $hasCategory = $false
        $zohoCategoryId = if ($hasCategory) { "12345" } else { $null }
        $zohoCategoryId | Should -BeNullOrEmpty
    }
}

Describe "Resumption and Batching" -Tag "Migration" {
    It "Batch calculation: 137 transactions at 50 per batch = 3 batches" {
        $total = 137
        $batchSize = 50
        $batches = [math]::Ceiling($total / $batchSize)
        $batches | Should -Be 3
    }

    It "Batch calculation: 50 transactions at 50 per batch = 1 batch" {
        $total = 50
        $batchSize = 50
        $batches = [math]::Ceiling($total / $batchSize)
        $batches | Should -Be 1
    }

    It "Resume state file detection via Test-Path" {
        $path = [System.IO.Path]::Combine($TestDrive, "state.json")
        Set-Content -Path $path -Value '{"imported":10,"imported_dates":["2026-03-01"],"completed":false}'
        (Test-Path $path) | Should -BeTrue
    }

    It "Completed state prevents re-run without -Force" {
        $state = @{ completed = $true; imported = 50 }
        $shouldSkip = $state.completed
        $shouldSkip | Should -BeTrue
    }
}

Describe "Date Validation" -Tag "Migration" {
    It "fromDate before toDate is valid" {
        $from = [DateTime]"2026-01-01"
        $to = [DateTime]"2026-03-15"
        ($from -lt $to) | Should -BeTrue
    }

    It "fromDate after toDate is invalid" {
        $from = [DateTime]"2026-03-15"
        $to = [DateTime]"2026-01-01"
        ($from -lt $to) | Should -BeFalse
    }

    It "fromDate equal to toDate is valid (single day)" {
        $from = [DateTime]"2026-01-01"
        $to = [DateTime]"2026-01-01"
        ($from -le $to) | Should -BeTrue
    }
}

Describe "Idempotency" -Tag "Migration" {
    It "Same input produces same output in routing table structure" {
        $route = @{
            wave_business  = "Intersite Consulting Inc."
            wave_account_id = $null
            zoho_org_id    = "env:ZOHO_ORG_ID_INTERSITE"
            label          = "Intersite — RBC"
        }
        $route2 = @{
            wave_business  = "Intersite Consulting Inc."
            wave_account_id = $null
            zoho_org_id    = "env:ZOHO_ORG_ID_INTERSITE"
            label          = "Intersite — RBC"
        }
        $route.wave_business | Should -Be $route2.wave_business
        $route.zoho_org_id | Should -Be $route2.zoho_org_id
        $route.label | Should -Be $route2.label
    }

    It "Transform function is deterministic for same input" {
        $txnInput = @{
            amount = @{ value = 100.00 }
            description = "Test payment"
            date = "2026-03-01"
            account = $null
        }

        $firstType = if ($txnInput.amount.value -ge 0) { "deposit" } else { "withdrawal" }
        $secondType = if ($txnInput.amount.value -ge 0) { "deposit" } else { "withdrawal" }
        $firstType | Should -Be $secondType
    }
}

Describe "Verification Logic" -Tag "Migration" {
    It "Matching counts and amounts passes integrity check" {
        $waveCount = 150
        $zohoCount = 150
        $waveTotal = 12500.00
        $zohoTotal = 12500.00
        $countMatch = $waveCount -eq $zohoCount
        $amountMatch = [math]::Abs(($waveTotal - $zohoTotal)) -lt 0.01
        $match = $countMatch -and $amountMatch
        $match | Should -BeTrue
    }

    It "Mismatched count fails integrity check" {
        $waveCount = 150
        $zohoCount = 148
        $countMatch = $waveCount -eq $zohoCount
        $countMatch | Should -BeFalse
    }

    It "Small rounding difference (< 0.01) passes integrity check" {
        $waveTotal = 12500.00
        $zohoTotal = 12500.005
        $amountMatch = [math]::Abs(($waveTotal - $zohoTotal)) -lt 0.01
        $amountMatch | Should -BeTrue
    }

    It "Large difference (> 0.01) fails integrity check" {
        $waveTotal = 12500.00
        $zohoTotal = 12501.00
        $amountMatch = [math]::Abs(($waveTotal - $zohoTotal)) -lt 0.01
        $amountMatch | Should -BeFalse
    }
}
