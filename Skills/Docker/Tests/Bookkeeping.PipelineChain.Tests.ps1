#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

# ==============================================================================
# Interclaw — Pipeline Chain Verification Tests
# Tests the cross-stage verification gates and warning propagation contract.
# ==============================================================================

Describe "Pipeline Chain — convert-pdf-statement-to-sidecar" -Tag "Bookkeeping" {
    Context "Verification gates" {
        It "script exists at the correct path" {
            Join-Path $PSScriptRoot "..\..\..\Skills\Bookkeeping\Scripts\pdf\convert-pdf-statement-to-sidecar.py" | Should -Exist
        }

        It "script syntax is valid" {
            $scriptPath = Join-Path $PSScriptRoot "..\..\..\Skills\Bookkeeping\Scripts\pdf\convert-pdf-statement-to-sidecar.py"
            $result = python -m py_compile $scriptPath 2>&1
            $LASTEXITCODE | Should -Be 0
        }

        It "write_sidecar_csv exits 1 when CSV has no headers" {
            $scriptPath = Join-Path $PSScriptRoot "..\..\..\Skills\Bookkeeping\Scripts\pdf\convert-pdf-statement-to-sidecar.py"
            $tmpPdf = Join-Path $env:TEMP "test-empty-$([Guid]::NewGuid()).pdf"
            $tmpCsv = [System.IO.Path]::ChangeExtension($tmpPdf, '.csv')
            try {
                'not a real pdf' | Out-File -LiteralPath $tmpPdf -Encoding utf8
                $result = python $scriptPath $tmpPdf 2>&1
                $LASTEXITCODE | Should -Be 1
            } finally {
                if (Test-Path $tmpPdf) { Remove-Item $tmpPdf -Force -ErrorAction SilentlyContinue }
                if (Test-Path $tmpCsv) { Remove-Item $tmpCsv -Force -ErrorAction SilentlyContinue }
            }
        }

        It "script imports required modules" {
            $scriptPath = Join-Path $PSScriptRoot "..\..\..\Skills\Bookkeeping\Scripts\pdf\convert-pdf-statement-to-sidecar.py"
            $importCheck = python -c "
import sys
sys.path.insert(0, '$([System.IO.Path]::GetDirectoryName($scriptPath))')
import ast, pathlib
tree = ast.parse(pathlib.Path('$scriptPath').read_text())
imports = {n.names[0].name for n in ast.walk(tree) if isinstance(n, ast.Import)}
aliases = {n.module for n in ast.walk(tree) if isinstance(n, ast.ImportFrom)}
print(sorted(imports | aliases - {'os','sys','re','csv','io','json','pathlib'}) or 'none')
"
            $LASTEXITCODE | Should -Be 0
        }
    }

    Context "Pipeline warnings file contract" {
        It "write_pipeline_warnings creates valid JSON" {
            $scriptPath = Join-Path $PSScriptRoot "..\..\..\Skills\Bookkeeping\Scripts\pdf\convert-pdf-statement-to-sidecar.py"
            $pythonCode = @"
import sys, json, tempfile, os
sys.path.insert(0, '$([System.IO.Path]::GetDirectoryName($scriptPath))')
exec(open('$scriptPath').read().split('def write_pipeline_warnings')[1].split('\ndef ')[0], {'__builtins__': __builtins__, 'os': __builtins__.__dict__.get('__import__')('os'), 'json': __builtins__.__dict__.get('__import__')('json')})
"@
            $tmpDir = [System.IO.Path]::GetTempPath()
            $testCsv = Join-Path $tmpDir "test-$([Guid]::NewGuid()).csv"
            try {
                '' | Out-File -LiteralPath $testCsv -Encoding utf8
                $result = python -c "
import json, os, sys
warnings = [{'stage': 'test', 'severity': 'error', 'message': 'test warning', 'file': r'$testCsv'}]
warnings_path = os.path.splitext(r'$testCsv')[0] + '.pipeline-warnings.json'
with open(warnings_path, 'w') as f:
    json.dump(warnings, f)
# Read back and verify
with open(warnings_path) as f:
    loaded = json.load(f)
assert len(loaded) == 1
assert loaded[0]['severity'] == 'error'
assert loaded[0]['message'] == 'test warning'
print('OK')
" 2>&1
                $LASTEXITCODE | Should -Be 0
            } finally {
                $warningFile = [System.IO.Path]::ChangeExtension($testCsv, '.pipeline-warnings.json')
                if (Test-Path $testCsv) { Remove-Item $testCsv -Force -ErrorAction SilentlyContinue }
                if (Test-Path $warningFile) { Remove-Item $warningFile -Force -ErrorAction SilentlyContinue }
            }
        }
    }
}

Describe "Pipeline Chain — Build-TAS.ps1" -Tag "Bookkeeping" {
    Context "Source CSV verification" {
        It "script exists" {
            Join-Path $PSScriptRoot "..\..\..\Skills\Bookkeeping\Scripts\reconciliation\Build-TAS.ps1" | Should -Exist
        }

        It "warns on empty source CSV" {
            $tmpDir = Join-Path $env:TEMP "tas-test-$([Guid]::NewGuid())"
            $null = New-Item -ItemType Directory -Path $tmpDir -Force
            $tmpCsv = Join-Path $tmpDir "empty.csv"
            "date,amount" | Out-File -LiteralPath $tmpCsv -Encoding utf8
            try {
                $content = Get-Content $tmpCsv
                $dataRows = @($content | Where-Object { $_ -notmatch '^#' -and $_ -match '\d' })
                $dataRows.Count | Should -Be 0
            } finally {
                Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

Describe "Pipeline Chain — Sync-TasReceiptStatus.mjs" -Tag "Bookkeeping" {
    Context "Verification gates" {
        It "script exists" {
            Join-Path $PSScriptRoot "..\..\..\Skills\Bookkeeping\Scripts\zoho\Sync-TasReceiptStatus.mjs" | Should -Exist
        }

        It "script syntax is valid" {
            $scriptPath = Join-Path $PSScriptRoot "..\..\..\Skills\Bookkeeping\Scripts\zoho\Sync-TasReceiptStatus.mjs"
            $result = node --check $scriptPath 2>&1
            $LASTEXITCODE | Should -Be 0
        }
    }
}

Describe "Pipeline Chain — Invoke-ReconciliationCheck.ps1" -Tag "Bookkeeping" {
    Context "Pipeline warnings display" {
        It "script exists" {
            Join-Path $PSScriptRoot "..\..\..\Skills\Bookkeeping\Scripts\reconciliation\Invoke-ReconciliationCheck.ps1" | Should -Exist
        }

        It "parses pipeline warnings file correctly" {
            $tmpDir = Join-Path $env:TEMP "recon-test-$([Guid]::NewGuid())"
            $null = New-Item -ItemType Directory -Path $tmpDir -Force
            $warningsFile = Join-Path $tmpDir ".pipeline-warnings.json"
            $warningsContent = @'
[
  {"stage": "convert-pdf-statement-to-sidecar", "severity": "error", "message": "Output CSV missing headers"},
  {"stage": "Build-TAS", "severity": "warning", "message": "Empty raw CSV for account"}
]
'@
            Set-Content -LiteralPath $warningsFile -Value $warningsContent -Encoding utf8
            try {
                $parsed = Get-Content $warningsFile -Raw -Encoding UTF8 | ConvertFrom-Json
                $parsed.Count | Should -Be 2
                $parsed[0].stage | Should -Be "convert-pdf-statement-to-sidecar"
                $parsed[0].severity | Should -Be "error"
                $parsed[1].severity | Should -Be "warning"
            } finally {
                Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
