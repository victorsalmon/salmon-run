#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..\..")
}

Describe "Resolve-OrphanReceipts.ps1" -Tag "Bookkeeping", "OrphanReconciliation" {
    It "script exists" {
        Join-Path $repoRoot "Skills\Bookkeeping\Scripts\Resolve-OrphanReceipts.ps1" | Should -Exist
    }

    It "has OrphansDir parameter" {
        $help = Get-Help (Join-Path $repoRoot "Skills\Bookkeeping\Scripts\Resolve-OrphanReceipts.ps1") -Parameter OrphansDir
        $help | Should -Not -BeNullOrEmpty
    }

    It "has Apply switch" {
        $content = Get-Content (Join-Path $repoRoot "Skills\Bookkeeping\Scripts\Resolve-OrphanReceipts.ps1") -Raw
        $content | Should -Match '\[switch\]\s*\$Apply'
    }

    It "applies Split-Path -Leaf to source path resolution (defensive against legacy manifest prefixes)" {
        # Per feedback Issue 2: the source path should use Split-Path -Leaf to handle
        # legacy manifest entries that may carry `_orphans\filename` prefixes.
        $content = Get-Content (Join-Path $repoRoot "Skills\Bookkeeping\Scripts\Resolve-OrphanReceipts.ps1") -Raw
        $content | Should -Match 'Join-Path \$OrphansDir \(Split-Path \$r\.Filename -Leaf\)'
    }

    It "has Format-ReconciliationReports.ps1 sibling" {
        Join-Path $repoRoot "Skills\Bookkeeping\Scripts\Format-ReconciliationReports.ps1" | Should -Exist
    }
}

Describe "Reconcile-ManifestStatus.ps1" -Tag "Bookkeeping", "OrphanReconciliation" {
    It "script exists" {
        Join-Path $repoRoot "Skills\Bookkeeping\Scripts\Reconcile-ManifestStatus.ps1" | Should -Exist
    }

    It "has ReceiptsDir parameter" {
        $help = Get-Help (Join-Path $repoRoot "Skills\Bookkeeping\Scripts\Reconcile-ManifestStatus.ps1") -Parameter ReceiptsDir
        $help | Should -Not -BeNullOrEmpty
    }

    It "has ManifestPath parameter" {
        $help = Get-Help (Join-Path $repoRoot "Skills\Bookkeeping\Scripts\Reconcile-ManifestStatus.ps1") -Parameter ManifestPath
        $help | Should -Not -BeNullOrEmpty
    }

    It "has WhatIf switch" {
        $content = Get-Content (Join-Path $repoRoot "Skills\Bookkeeping\Scripts\Reconcile-ManifestStatus.ps1") -Raw
        $content | Should -Match '\[switch\]\s*\$WhatIf'
    }

    It "uses [ordered]@{} for indexDirs to guarantee enumeration order" {
        # Per the script's own comments: regular hashtables don't guarantee order in
        # PowerShell, which causes non-deterministic results when a basename exists
        # in multiple directories.
        $content = Get-Content (Join-Path $repoRoot "Skills\Bookkeeping\Scripts\Reconcile-ManifestStatus.ps1") -Raw
        $content | Should -Match '\[ordered\]@\{'
    }

    Context "Manifest drift after sweep" {
        BeforeAll {
            $manifestPath = Join-Path $env:USERPROFILE "intersite-docs\Taxes and Bookkeeping\intersite-consulting\2026 Filing\Receipts\_manifest.csv"
        }

        It "_manifest.csv exists" {
            $manifestPath | Should -Exist
        }

        It "_manifest.csv no longer has 'promoted' status (all cleared by sweep)" {
            $rows = Get-Content $manifestPath -Raw | ConvertFrom-Csv
            $promoted = $rows | Where-Object { $_.status -eq "promoted" }
            $promoted.Count | Should -Be 0
        }

        It "_manifest.csv has fewer than 50 'archived' rows (only ones actually in _orphans/archived/)" {
            # The sweep preserves 'archived' status for files actually in _orphans/archived/.
            # After the sweep this should be a small number (5 or so), not the 264 that
            # were in the manifest before the sweep.
            $rows = Get-Content $manifestPath -Raw | ConvertFrom-Csv
            $archived = $rows | Where-Object { $_.status -eq "archived" }
            $archived.Count | Should -BeLessOrEqual 50
        }
    }
}

Describe "Reconcile-ManifestStatus.ps1 idempotency" -Tag "Bookkeeping", "OrphanReconciliation" {
    It "second run produces zero changes" {
        # Run the sweep twice in WhatIf mode; both should report 0 changes after the
        # first real sweep has cleaned up the drift. *>&1 captures the host's
        # information stream (where Write-Host writes) in addition to stdout/stderr.
        $script = Join-Path $repoRoot "Skills\Bookkeeping\Scripts\Reconcile-ManifestStatus.ps1"
        $first = & $script -WhatIf *>&1 | Out-String
        $second = & $script -WhatIf *>&1 | Out-String

        # Both runs should report 0 changes
        $first | Should -Match "Changed:\s+0"
        $second | Should -Match "Changed:\s+0"
    }
}
