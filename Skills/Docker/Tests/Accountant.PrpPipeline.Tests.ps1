#Requires -Modules Pester

BeforeAll {
    $script:CurrentsbkRecon = "C:\Repos\currentsbk\Skills\Accountant\Scripts\reconciliation"
}

Describe "Invoke-PrpOrgPipeline.ps1 — failed-account exclusion from cross-account matching" -Tag "Accountant", "Regression" {
    BeforeAll {
        $script:PrpOrgScript = Join-Path $script:CurrentsbkRecon "Invoke-PrpOrgPipeline.ps1"
        if (Test-Path $script:PrpOrgScript) {
            $script:PrpOrgContent = Get-Content -LiteralPath $script:PrpOrgScript -Raw
        }
    }

    It "script exists at the canonical currentsbk path" {
        $script:PrpOrgScript | Should -Exist
    }

    It "script syntax is valid" {
        if (-not (Test-Path $script:PrpOrgScript)) { Set-ItResult -Skipped -Because "Invoke-PrpOrgPipeline.ps1 not present"; return }
        $errs = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($script:PrpOrgScript, [ref]$null, [ref]$errs)
        $errs.Count | Should -Be 0
    }

    It "completedAccounts filter does not short-circuit on -ContinueOnError" {
        if (-not (Test-Path $script:PrpOrgScript)) { Set-ItResult -Skipped -Because "Invoke-PrpOrgPipeline.ps1 not present"; return }
        $script:PrpOrgContent | Should -Match 'OverallStatus -ne "FAIL"'
        $script:PrpOrgContent | Should -Not -Match 'OverallStatus -ne "FAIL" -or \$ContinueOnError'
    }

    It "completedAccounts filter excludes FAIL accounts even when -ContinueOnError is set (evaluates the filter from the file)" {
        if (-not (Test-Path $script:PrpOrgScript)) { Set-ItResult -Skipped -Because "Invoke-PrpOrgPipeline.ps1 not present"; return }
        $line = ($script:PrpOrgContent -split "`r?`n") | Where-Object { $_ -match 'Where-Object' -and $_ -match 'OverallStatus -ne "FAIL"' } | Select-Object -First 1
        $expr = [regex]::Match($line, 'Where-Object \{\s*(.*?)\s*\}').Groups[1].Value
        $expr | Should -Not -BeNullOrEmpty
        $sb = [scriptblock]::Create($expr)
        $orgResults = @(
            [PSCustomObject]@{ OverallStatus = "FAIL" }
            [PSCustomObject]@{ OverallStatus = "PASS" }
            [PSCustomObject]@{ OverallStatus = "PASS" }
        )
        $ContinueOnError = $true
        $completedAccounts = @($orgResults | Where-Object $sb)
        $completedAccounts.Count | Should -Be 2
    }

    It "logs how many failed accounts were excluded" {
        if (-not (Test-Path $script:PrpOrgScript)) { Set-ItResult -Skipped -Because "Invoke-PrpOrgPipeline.ps1 not present"; return }
        $script:PrpOrgContent | Should -Match 'failed account\(s\) excluded from cross-account matching'
    }

    It "surfaces evidence-parse failures in the Step Failures report instead of a silent catch" {
        if (-not (Test-Path $script:PrpOrgScript)) { Set-ItResult -Skipped -Because "Invoke-PrpOrgPipeline.ps1 not present"; return }
        $script:PrpOrgContent | Should -Match '\(evidence unreadable\)'
        $script:PrpOrgContent | Should -Match '\$hasFailures = \$true'
    }
}

Describe "Build-TAS.ps1 — atomic TAS write" -Tag "Accountant", "Regression" {
    BeforeAll {
        $script:BuildTasScript = Join-Path $script:CurrentsbkRecon "Build-TAS.ps1"
        if (Test-Path $script:BuildTasScript) {
            $script:BuildTasContent = Get-Content -LiteralPath $script:BuildTasScript -Raw
        }
    }

    It "script exists at the canonical currentsbk path" {
        $script:BuildTasScript | Should -Exist
    }

    It "script syntax is valid" {
        if (-not (Test-Path $script:BuildTasScript)) { Set-ItResult -Skipped -Because "Build-TAS.ps1 not present"; return }
        $errs = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($script:BuildTasScript, [ref]$null, [ref]$errs)
        $errs.Count | Should -Be 0
    }

    It "writes TAS via a sibling temp file then atomically renames into place" {
        if (-not (Test-Path $script:BuildTasScript)) { Set-ItResult -Skipped -Because "Build-TAS.ps1 not present"; return }
        $script:BuildTasContent | Should -Match '\$tempPath = "\$tasPath\.tmp"'
        $script:BuildTasContent | Should -Match 'WriteAllText\(\$tempPath'
        $script:BuildTasContent | Should -Match 'Move-Item -LiteralPath \$tempPath -Destination \$tasPath -Force'
    }

    It "does not write TAS in place with Out-File (no truncation window)" {
        if (-not (Test-Path $script:BuildTasScript)) { Set-ItResult -Skipped -Because "Build-TAS.ps1 not present"; return }
        $script:BuildTasContent | Should -Not -Match 'Out-File -FilePath \$tasPath'
    }

    It "writes BOM-free UTF-8 to match Python csv consumers" {
        if (-not (Test-Path $script:BuildTasScript)) { Set-ItResult -Skipped -Because "Build-TAS.ps1 not present"; return }
        $script:BuildTasContent | Should -Match 'UTF8Encoding\]::new\(\$false\)'
    }

    It "cleans up the temp file if the write or rename fails" {
        if (-not (Test-Path $script:BuildTasScript)) { Set-ItResult -Skipped -Because "Build-TAS.ps1 not present"; return }
        $script:BuildTasContent | Should -Match 'Remove-Item -LiteralPath \$tempPath'
        $script:BuildTasContent | Should -Match 'catch \{'
    }
}
