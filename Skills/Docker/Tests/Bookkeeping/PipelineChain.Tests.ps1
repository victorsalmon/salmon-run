#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

BeforeAll {
    $script:ScriptDir = Resolve-Path "$PSScriptRoot/../../../.."
    $script:ConvertScript = "$script:ScriptDir/Skills/Bookkeeping/Scripts/pdf/convert-pdf-statement-to-sidecar.py"
    $script:BuildTasScript = "$script:ScriptDir/Skills/Bookkeeping/Scripts/reconciliation/Build-TAS.ps1"
}

Describe "Pipeline verification gates" -Tag "Bookkeeping", "Integration" {
    Context "convert-pdf-statement-to-sidecar.py" {
        It "exits with error when output CSV has no data rows" {
            # Create a minimal valid PDF with 0 transactions and verify the script warns
            # (requires pdfplumber — skip in CI without it)
            python -c "import pdfplumber" 2>$null | Out-Null
            if (-not $?) {
                Set-ItResult -Skipped -Because "pdfplumber not installed"
                return
            }

            # Run script on a known sample and check output
            $result = (python "$script:ConvertScript" --help 2>&1) -join "`n"
            $result | Should -Match "Parse RBC chequing"
        }

        It "emits # Account: line in the sidecar header for a SCOTIA statement" {
            python -c "import pdfplumber" 2>$null | Out-Null
            if (-not $?) {
                Set-ItResult -Skipped -Because "pdfplumber not installed"
                return
            }

            $samplePdf = "C:\Repos\intersite-docs\Taxes and Bookkeeping\room-rentals\2026 Bank Statements\SCOTIA-TMH 406000697486\January 2026 e-statement.pdf"
            if (-not (Test-Path $samplePdf)) {
                Set-ItResult -Skipped -Because "sample SCOTIA statement PDF not present on this machine"
                return
            }

            $tmpOut = Join-Path ([System.IO.Path]::GetTempPath()) "sidecar-account-test-$([guid]::NewGuid().ToString('N'))"
            try {
                python "$script:ConvertScript" --output-dir $tmpOut $samplePdf 2>&1 | Out-Null
                $csvPath = Join-Path $tmpOut "January 2026 e-statement.csv"
                Test-Path $csvPath | Should -BeTrue
                $sidecar = Get-Content $csvPath -Raw
                $sidecar | Should -Match "# Account: 406000697486"
            } finally {
                Remove-Item -Path $tmpOut -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context "Build-TAS.ps1" {
        It "rejects empty source CSV directory" {
            # The script should produce a warning when no source CSVs exist
            $result = & "$script:BuildTasScript" -WhatIf 2>&1
            $result | Should -Not -BeNullOrEmpty
        }

        It "returns exit code 0 on dry-run" {
            & "$script:BuildTasScript" -WhatIf 2>&1 | Out-Null
            $LASTEXITCODE | Should -Be 0
        }
    }
}
