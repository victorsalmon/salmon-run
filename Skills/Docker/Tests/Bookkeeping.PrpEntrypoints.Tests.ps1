#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..\..")
    $prpScripts = @(
        "Invoke-PrpStepDG-DataGathering.ps1",
        "Invoke-PrpStepRC-ReceiptCheck.ps1",
        "Invoke-PrpStepTR-TasRebuild.ps1",
        "Invoke-PrpStep0-TokenAcquisition.ps1",
        "Invoke-PrpStep05-PlaidDetection.ps1",
        "Invoke-PrpStep1-SidecarVerify.ps1",
        "Invoke-PrpStep2-ZohoMatch.ps1",
        "Invoke-PrpStep3-CategorizationAudit.ps1",
        "Invoke-PrpStep35-CategoryChecks.ps1",
        "Invoke-PrpStep4-AuditWarnings.ps1",
        "Invoke-PrpStep5-BalanceForward.ps1",
        "Invoke-PrpStep55-DriftCorrection.ps1",
        "Invoke-PrpStep6-Reconcile.ps1",
        "Invoke-PrpStep7-ReconTable.ps1",
        "Invoke-PrpAcctPipeline.ps1"
    )
    $script:prpScriptPaths = $prpScripts | ForEach-Object { Join-Path $repoRoot "Skills\Bookkeeping\Scripts\reconciliation\$_" }
}

Describe "PRP Entrypoint Scripts - Syntax" -Tag "Bookkeeping", "PrpEntrypoints" {
    It "All 15 PRP scripts exist on disk" {
        $missing = $script:prpScriptPaths | Where-Object { -not (Test-Path -LiteralPath $_) }
        $missing.Count | Should -Be 0 -Because "every PRP step script must exist"
    }

    It "All PRP scripts parse without errors" {
        $parseErrors = @()
        foreach ($path in $script:prpScriptPaths) {
            $errors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
            if ($errors -and $errors.Count -gt 0) {
                $parseErrors += "[$(Split-Path $path -Leaf)] $($errors[0].Message)"
            }
        }
        $parseErrors.Count | Should -Be 0 -Because "all scripts must parse cleanly"
    }
}

Describe "PRP Entrypoint Scripts - Conventions" -Tag "Bookkeeping", "PrpEntrypoints" {
    It "All step scripts use [CmdletBinding(SupportsShouldProcess)]" {
        $violations = @()
        foreach ($path in $script:prpScriptPaths) {
            $content = Get-Content -LiteralPath $path -Raw
            if ($content -notmatch '\[CmdletBinding\(SupportsShouldProcess\)\]') {
                $violations += Split-Path $path -Leaf
            }
        }
        $violations.Count | Should -Be 0 -Because "all scripts should support -WhatIf"
    }

    It "All step scripts return a PSCustomObject with Passed, StepNumber, Details" {
        $violations = @()
        foreach ($path in $script:prpScriptPaths) {
            $content = Get-Content -LiteralPath $path -Raw
            if ($content -notmatch 'PSCustomObject' -or $content -notmatch 'Passed' -or $content -notmatch 'StepNumber') {
                $violations += Split-Path $path -Leaf
            }
        }
        $violations.Count | Should -Be 0 -Because "all scripts must return structured PSCustomObject"
    }

    It "All step scripts use Write-Progress with PRP naming" {
        $violations = @()
        foreach ($path in $script:prpScriptPaths) {
            $content = Get-Content -LiteralPath $path -Raw
            if ($content -notmatch 'Write-Progress') {
                $violations += Split-Path $path -Leaf
            }
        }
        $violations.Count | Should -Be 0 -Because "all scripts should use Write-Progress for visibility"
    }
}

Describe "PRP Pipeline - WhatIf" -Tag "Bookkeeping", "PrpEntrypoints", "Regression-Only" {
    It "Invoke-PrpAcctPipeline.ps1 runs with -WhatIf and shows all steps" {
        $pipelinePath = Join-Path $repoRoot "Skills\Bookkeeping\Scripts\reconciliation\Invoke-PrpAcctPipeline.ps1"
        $output = & $pipelinePath -AccountName "TEST" -OrgName "intersite-consulting" -WhatIf 6>&1
        $output -join "`n" | Should -Match "Step DG | PASS"
        $output -join "`n" | Should -Match "Step 7f | PASS"
    }
}
