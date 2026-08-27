#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

BeforeAll {
    $script:RepoRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.Parent.FullName
    $script:AcctInfra = Join-Path $script:RepoRoot "Skills" "Bookkeeping"
    $script:HandlerDir = Join-Path $script:AcctInfra "handlers" "SalmonRun.Bookkeeping"
    $script:VisionHandlerDir = Join-Path $script:HandlerDir "Handlers" "Vision"
    $script:OcrScript = Join-Path $script:AcctInfra "vision" "extract-receipt-ocr.py"
    $script:BundleManifest = Join-Path $script:RepoRoot "Skills" "Docker" "Modules" "SalmonRun.Secrets" "Private" "bundle-manifest.ps1"
    $script:Psm1 = Join-Path $script:HandlerDir "SalmonRun.Bookkeeping.psm1"
}

Describe "Bookkeeping Vision OCR" -Tag "Bookkeeping", "Vision", "Regression" {

    It "Invoke-ImageAnalysis.ps1 exists in Handlers/Vision/" {
        (Join-Path $script:VisionHandlerDir "Invoke-ImageAnalysis.ps1") | Should -Exist
    }

    It "Invoke-ImageAnalysis.ps1 parses without errors" {
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $script:VisionHandlerDir "Invoke-ImageAnalysis.ps1"), [ref]$null, [ref]$errors
        )
        $errors.Count | Should -Be 0 -Because "PowerShell handler should parse without syntax errors"
    }

    It "Invoke-ImageAnalysis.ps1 shells out to extract-receipt-ocr.py" {
        $content = Get-Content (Join-Path $script:VisionHandlerDir "Invoke-ImageAnalysis.ps1") -Raw
        $content | Should -Match "extract-receipt-ocr.py"
        $content | Should -Match "python3"
    }

    It "Invoke-ImageAnalysis.ps1 passes --api-key-env OPENROUTER_API_KEY" {
        $content = Get-Content (Join-Path $script:VisionHandlerDir "Invoke-ImageAnalysis.ps1") -Raw
        $content | Should -Match -- "--api-key-env OPENROUTER_API_KEY"
    }

    It "Invoke-ImageAnalysis.ps1 derives sidecar name from temp image stem" {
        $content = Get-Content (Join-Path $script:VisionHandlerDir "Invoke-ImageAnalysis.ps1") -Raw
        $content | Should -Match "GetFileNameWithoutExtension"
        $content | Should -Not -Match '"result\.json"'
    }

    It "Invoke-ImageAnalysis.ps1 checks the OCR exit code" {
        $content = Get-Content (Join-Path $script:VisionHandlerDir "Invoke-ImageAnalysis.ps1") -Raw
        $content | Should -Match '\$exitCode -ne 0'
    }

    It "ReceiptOcr.ps1 no longer contains stale /home/node/app/audit path" {
        $receiptPath = Join-Path $script:VisionHandlerDir "ReceiptOcr.ps1"
        $receiptPath | Should -Exist
        $content = Get-Content -Path $receiptPath -Raw
        $content | Should -Not -Match "/home/node/app/audit"
        $content | Should -Match "/data/vision-output"
    }

    It "ReceiptOcr.ps1 calls Invoke-ImageAnalysis" {
        $content = Get-Content (Join-Path $script:VisionHandlerDir "ReceiptOcr.ps1") -Raw
        $content | Should -Match "Invoke-ImageAnalysis"
    }

    It "Test-BookkeepingCapability vision:ocr gate checks OpenRouterApiKey" {
        $capPath = Join-Path $script:HandlerDir "Private" "Test-BookkeepingCapability.ps1"
        $capPath | Should -Exist
        $content = Get-Content -Path $capPath -Raw
        $content | Should -Match 'vision:ocr.*OpenRouterApiKey'
    }

    It "Bookkeeper bundle manifest has OPENROUTER_API_KEY" {
        $script:BundleManifest | Should -Exist
        $content = Get-Content -Path $script:BundleManifest -Raw
        $content | Should -Match "OPENROUTER_API_KEY"
    }

    It "SalmonRun.Bookkeeping.psm1 loads OpenRouterApiKey" {
        $script:Psm1 | Should -Exist
        $content = Get-Content -Path $script:Psm1 -Raw
        $content | Should -Match "OpenRouterApiKey"
    }

    It "SalmonRun.Bookkeeping.psd1 exports Invoke-ReceiptOcr" {
        $psd1Path = Join-Path $script:HandlerDir "SalmonRun.Bookkeeping.psd1"
        $psd1Path | Should -Exist
        $content = Get-Content -Path $psd1Path -Raw
        $content | Should -Match "'Invoke-ReceiptOcr'"
    }

    It "OCR script exists at Skills/Bookkeeping/vision/" {
        $script:OcrScript | Should -Exist
    }

    It "extract-receipt-ocr.py compiles without syntax errors" {
        $result = & python -m py_compile $script:OcrScript 2>&1
        $LASTEXITCODE | Should -Be 0 -Because "Python script should compile without syntax errors"
    }

    It "extract-receipt-ocr.py falls back to OPENROUTER_API_KEY" {
        $content = Get-Content -Path $script:OcrScript -Raw
        $content | Should -Match "os.environ.get\(args.api_key_env\)"
        $content | Should -Match 'OPENROUTER_API_KEY'
    }
}

Describe "Bookkeeping Vision OCR — Python invocation" -Tag "Bookkeeping", "Vision", "Unit" {
    It "extract-receipt-ocr.py exits 1 when no API key is available" {
        if (-not (Test-Path $script:OcrScript)) { Set-ItResult -Skipped -Because "OCR script not found"; return }
        $origOrch = $env:OPENROUTER_ORCH_KEY
        $origApi = $env:OPENROUTER_API_KEY
        try {
            Remove-Item Env:OPENROUTER_ORCH_KEY -ErrorAction SilentlyContinue
            Remove-Item Env:OPENROUTER_API_KEY -ErrorAction SilentlyContinue
            $tmpOut = Join-Path $env:TEMP "vision-ocr-out-$(Get-Random)"
            $dummy = Join-Path $env:TEMP "vision-ocr-dummy-$(Get-Random).png"
            Set-Content -Path $dummy -Value "dummy" -NoNewline
            $null = & python $script:OcrScript $dummy --output-dir $tmpOut 2>&1
            $LASTEXITCODE | Should -Be 1 -Because "script requires an API key to proceed"
        } finally {
            if ($null -ne $origOrch) { $env:OPENROUTER_ORCH_KEY = $origOrch }
            if ($null -ne $origApi) { $env:OPENROUTER_API_KEY = $origApi }
            Remove-Item -LiteralPath $tmpOut -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $dummy -Force -ErrorAction SilentlyContinue
        }
    }

    It "extract-receipt-ocr.py skips nonexistent image without crashing" {
        if (-not (Test-Path $script:OcrScript)) { Set-ItResult -Skipped -Because "OCR script not found"; return }
        $origOrch = $env:OPENROUTER_ORCH_KEY
        $origApi = $env:OPENROUTER_API_KEY
        try {
            $env:OPENROUTER_ORCH_KEY = "dummy-key-for-skip-test"
            $tmpOut = Join-Path $env:TEMP "vision-ocr-out-$(Get-Random)"
            $missing = Join-Path $env:TEMP "vision-ocr-missing-$(Get-Random).png"
            $out = & python $script:OcrScript $missing --output-dir $tmpOut 2>&1
            $LASTEXITCODE | Should -Be 0 -Because "missing image is skipped, not fatal"
            $out -join "`n" | Should -Match "SKIP"
        } finally {
            if ($null -ne $origOrch) { $env:OPENROUTER_ORCH_KEY = $origOrch } else { Remove-Item Env:OPENROUTER_ORCH_KEY -ErrorAction SilentlyContinue }
            if ($null -ne $origApi) { $env:OPENROUTER_API_KEY = $origApi }
            Remove-Item -LiteralPath $tmpOut -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
