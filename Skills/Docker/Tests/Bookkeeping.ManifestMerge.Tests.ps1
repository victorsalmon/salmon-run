#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..\..")
}

Describe "Merge-ReceiptManifests.ps1" -Tag "Bookkeeping", "ManifestMerge" {
    It "script exists" {
        Join-Path $repoRoot "Skills\Bookkeeping\Scripts\upload\Merge-ReceiptManifests.ps1" | Should -Exist
    }

    It "has ReceiptsBase parameter" {
        $help = Get-Help (Join-Path $repoRoot "Skills\Bookkeeping\Scripts\upload\Merge-ReceiptManifests.ps1") -Parameter ReceiptsBase
        $help | Should -Not -BeNullOrEmpty
    }

    It "has Entity parameter (mandatory, intersite-consulting only)" {
        $help = Get-Help (Join-Path $repoRoot "Skills\Bookkeeping\Scripts\upload\Merge-ReceiptManifests.ps1") -Parameter Entity
        $help | Should -Not -BeNullOrEmpty
        $help.ParameterSets.Parameters | Where-Object { $_.Name -eq "Entity" } | ForEach-Object {
            $_.Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } | ForEach-Object {
                $_.ValidValues | Should -Contain "intersite-consulting"
            }
        }
    }

    It "has OutputManifest parameter" {
        $help = Get-Help (Join-Path $repoRoot "Skills\Bookkeeping\Scripts\upload\Merge-ReceiptManifests.ps1") -Parameter OutputManifest
        $help | Should -Not -BeNullOrEmpty
    }

    Context "Manifest schema (unified _manifest.csv)" {
        BeforeAll {
            $manifestPath = Join-Path $env:USERPROFILE "intersite-docs\Taxes and Bookkeeping\intersite-consulting\2026 Filing\Receipts\_manifest.csv"
            $script:ManifestDataAvailable = Test-Path $manifestPath
        }

        It "_manifest.csv exists after migration" {
            if (-not $script:ManifestDataAvailable) {
                Set-ItResult -Skipped -Because "intersite-docs receipt data not present on this host - external data prerequisite"
            }
            $manifestPath | Should -Exist
        }

        It "_manifest.csv has the unified schema header" {
            if (-not $script:ManifestDataAvailable) {
                Set-ItResult -Skipped -Because "intersite-docs receipt data not present on this host - external data prerequisite"
            }
            $firstLine = Get-Content $manifestPath -TotalCount 1
            $firstLine | Should -Match "filename"
            $firstLine | Should -Match "date"
            $firstLine | Should -Match "amount"
            $firstLine | Should -Match "vendor"
            $firstLine | Should -Match "account"
            $firstLine | Should -Match "sha256"
            $firstLine | Should -Match "zoho_expense_id"
            $firstLine | Should -Match "zoho_document_id"
            $firstLine | Should -Match "source"
            $firstLine | Should -Match "status"
            $firstLine | Should -Match "notes"
        }

        It "_manifest.csv account values are the new subdir names" {
            if (-not $script:ManifestDataAvailable) {
                Set-ItResult -Skipped -Because "intersite-docs receipt data not present on this host - external data prerequisite"
            }
            $rows = Get-Content $manifestPath -Raw | ConvertFrom-Csv
            $accounts = $rows | ForEach-Object { $_.account } | Sort-Object -Unique
            $accounts | Should -Contain "intersite-mc-6258"
            $accounts | Should -Contain "intersite-rbc-chequing"
        }

        It "_manifest.csv has both matched and orphan statuses" {
            if (-not $script:ManifestDataAvailable) {
                Set-ItResult -Skipped -Because "intersite-docs receipt data not present on this host - external data prerequisite"
            }
            $rows = Get-Content $manifestPath -Raw | ConvertFrom-Csv
            $statuses = $rows | ForEach-Object { $_.status } | Sort-Object -Unique
            $statuses | Should -Contain "matched"
            $statuses | Should -Contain "orphan"
        }

        It "_manifest.csv SHA256 column is populated for files that exist on disk" {
            if (-not $script:ManifestDataAvailable) {
                Set-ItResult -Skipped -Because "intersite-docs receipt data not present on this host - external data prerequisite"
            }
            $rows = Get-Content $manifestPath -Raw | ConvertFrom-Csv
            $withHash = $rows | Where-Object { $_.sha256 -and $_.sha256.Length -eq 64 }
            $withHash.Count | Should -BeGreaterThan 200
        }
    }
}

Describe "Move-ReceiptFiles.ps1" -Tag "Bookkeeping", "ManifestMerge" {
    It "script exists" {
        Join-Path $repoRoot "Skills\Bookkeeping\Scripts\upload\Move-ReceiptFiles.ps1" | Should -Exist
    }

    It "has ReceiptsBase parameter" {
        $help = Get-Help (Join-Path $repoRoot "Skills\Bookkeeping\Scripts\upload\Move-ReceiptFiles.ps1") -Parameter ReceiptsBase
        $help | Should -Not -BeNullOrEmpty
    }

    It "has Entity parameter" {
        $help = Get-Help (Join-Path $repoRoot "Skills\Bookkeeping\Scripts\upload\Move-ReceiptFiles.ps1") -Parameter Entity
        $help | Should -Not -BeNullOrEmpty
    }

    It "has ManifestPath parameter" {
        $help = Get-Help (Join-Path $repoRoot "Skills\Bookkeeping\Scripts\upload\Move-ReceiptFiles.ps1") -Parameter ManifestPath
        $help | Should -Not -BeNullOrEmpty
    }

    It "has DryRun switch" {
        $content = Get-Content (Join-Path $repoRoot "Skills\Bookkeeping\Scripts\upload\Move-ReceiptFiles.ps1") -Raw
        $content | Should -Match '\[switch\]\s*\$DryRun'
    }

    Context "New directory layout" {
        BeforeAll {
            $base = Join-Path $env:USERPROFILE "intersite-docs\Taxes and Bookkeeping\intersite-consulting\2026 Filing\Receipts"
            $script:ReceiptsDataAvailable = Test-Path $base
        }

        It "creates intersite-mc-6258/ subdirectory" {
            if (-not $script:ReceiptsDataAvailable) {
                Set-ItResult -Skipped -Because "intersite-docs receipt data not present on this host - external data prerequisite"
            }
            Join-Path $base "intersite-mc-6258" | Should -Exist
        }

        It "creates intersite-rbc-chequing/ subdirectory" {
            if (-not $script:ReceiptsDataAvailable) {
                Set-ItResult -Skipped -Because "intersite-docs receipt data not present on this host - external data prerequisite"
            }
            Join-Path $base "intersite-rbc-chequing" | Should -Exist
        }

        It "creates _orphans/ subdirectory" {
            if (-not $script:ReceiptsDataAvailable) {
                Set-ItResult -Skipped -Because "intersite-docs receipt data not present on this host - external data prerequisite"
            }
            Join-Path $base "_orphans" | Should -Exist
        }

        It "creates _zoho-only/ subdirectory" {
            if (-not $script:ReceiptsDataAvailable) {
                Set-ItResult -Skipped -Because "intersite-docs receipt data not present on this host - external data prerequisite"
            }
            Join-Path $base "_zoho-only" | Should -Exist
        }

        It "creates intersite-outbound/ subdirectory" {
            if (-not $script:ReceiptsDataAvailable) {
                Set-ItResult -Skipped -Because "intersite-docs receipt data not present on this host - external data prerequisite"
            }
            Join-Path $base "intersite-outbound" | Should -Exist
        }

        It "removes old rbc-6258/ directory" {
            if (-not $script:ReceiptsDataAvailable) {
                Set-ItResult -Skipped -Because "intersite-docs receipt data not present on this host - external data prerequisite"
            }
            Join-Path $base "rbc-6258" | Should -Not -Exist
        }

        It "removes old rbc-6258-ingest/ directory" {
            if (-not $script:ReceiptsDataAvailable) {
                Set-ItResult -Skipped -Because "intersite-docs receipt data not present on this host - external data prerequisite"
            }
            Join-Path $base "rbc-6258-ingest" | Should -Not -Exist
        }

        It "removes old rbc-intersite/ directory" {
            if (-not $script:ReceiptsDataAvailable) {
                Set-ItResult -Skipped -Because "intersite-docs receipt data not present on this host - external data prerequisite"
            }
            Join-Path $base "rbc-intersite" | Should -Not -Exist
        }

        It "intersite-mc-6258/ contains at least 111 matched receipts (baseline + 30 from 2026-06-17 sync)" {
            if (-not $script:ReceiptsDataAvailable) {
                Set-ItResult -Skipped -Because "intersite-docs receipt data not present on this host - external data prerequisite"
            }
            $count = (Get-ChildItem (Join-Path $base "intersite-mc-6258") -File).Count
            $count | Should -BeGreaterOrEqual 111
        }

        It "intersite-rbc-chequing/ contains at least 101 matched receipts" {
            if (-not $script:ReceiptsDataAvailable) {
                Set-ItResult -Skipped -Because "intersite-docs receipt data not present on this host - external data prerequisite"
            }
            $count = (Get-ChildItem (Join-Path $base "intersite-rbc-chequing") -File).Count
            $count | Should -BeGreaterOrEqual 101
        }
    }
}

Describe "Invoke-ReceiptSync.ps1 unified manifest integration" -Tag "Bookkeeping", "ManifestMerge" {
    It "script exists" {
        Join-Path $repoRoot "Skills\Bookkeeping\Scripts\upload\Invoke-ReceiptSync.ps1" | Should -Exist
    }

    It "uses _manifest.csv (not the 3 old manifest CSVs) in the \$Manifests array" {
        $content = Get-Content (Join-Path $repoRoot "Skills\Bookkeeping\Scripts\upload\Invoke-ReceiptSync.ps1") -Raw
        # Check the active code path (the $Manifests assignment) — comments may
        # still reference old names for migration context.
        $content | Should -Match '(?s)\$Manifests\s*=\s*@\(.*?_manifest\.csv'
        $content | Should -Not -Match '@\{\s*Slug\s*=\s*"rbc-intersite"'
        $content | Should -Not -Match '@\{\s*Slug\s*=\s*"rbc-6258"'
    }

    It "defines AccountToSubdir mapping table" {
        $content = Get-Content (Join-Path $repoRoot "Skills\Bookkeeping\Scripts\upload\Invoke-ReceiptSync.ps1") -Raw
        $content | Should -Match '\$AccountToSubdir\s*=\s*@\{'
        $content | Should -Match '"rbc-chequing"\s*=\s*"intersite-rbc-chequing"'
        $content | Should -Match '"6258"\s*=\s*"intersite-mc-6258"'
    }

    It "routes downloads to intersite-mc-6258/ or intersite-rbc-chequing/" {
        $content = Get-Content (Join-Path $repoRoot "Skills\Bookkeeping\Scripts\upload\Invoke-ReceiptSync.ps1") -Raw
        $content | Should -Match 'intersite-mc-6258'
        $content | Should -Match 'intersite-rbc-chequing'
    }
}


