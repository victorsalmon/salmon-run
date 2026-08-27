#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

Describe "Build-TAS ConvertTo-IsoDate" -Tag "Bookkeeping", "TAS", "Regression" {
    BeforeAll {
        $script:tasBuildPath = Join-Path $PSScriptRoot "..\..\Bookkeeper\Scripts\reconciliation\Build-TAS.ps1"
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:tasBuildPath, [ref]$null, [ref]$null)
        $fn = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
            Where-Object { $_.Name -eq "ConvertTo-IsoDate" } | Select-Object -First 1
        if ($fn) {
            $sb = [System.Management.Automation.ScriptBlock]::Create($fn.Extent.Text)
            . $sb
        } else {
            throw "ConvertTo-IsoDate function not found in Build-TAS.ps1"
        }
    }

    It "converts TD M/D/YYYY to YYYY-MM-DD" {
        ConvertTo-IsoDate "1/5/2026" | Should -Be "2026-01-05"
    }

    It "converts RBC-style M/D/YYYY with two-digit day" {
        ConvertTo-IsoDate "12/25/2026" | Should -Be "2026-12-25"
    }

    It "passes ISO dates through unchanged" {
        ConvertTo-IsoDate "2026-01-05" | Should -Be "2026-01-05"
    }

    It "leaves unrecognized formats untouched" {
        ConvertTo-IsoDate "20260105" | Should -Be "20260105"
    }
}

Describe "Build-TAS description backfill" -Tag "Bookkeeping", "TAS", "Regression" {
    BeforeAll {
        $script:tasBuildPath = Join-Path $PSScriptRoot "..\..\Bookkeeper\Scripts\reconciliation\Build-TAS.ps1"
    }

    It "backfill row-side key uses normalized yyyy-MM-dd date" {
        $content = Get-Content $script:tasBuildPath -Raw
        $content | Should -Match 'ConvertTo-IsoDate \$r\.date'
        $content | Should -Not -Match '\$key = "\$\(\$r\.date\)\|'
    }

    It "warns when backfill candidates exist but none match" {
        $content = Get-Content $script:tasBuildPath -Raw
        $content | Should -Match 'possible date-format drift'
        $content | Should -Match 'rawLookup\.Count -gt 0'
    }
}
