#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..\..")).Path.TrimEnd('\')
    $script:AcctScripts = Join-Path $script:RepoRoot "Skills\Bookkeeping\Scripts"
    $script:TestDir = Join-Path $env:TEMP "AcctPipeline-$(Get-Random)"
    $null = New-Item -ItemType Directory -Path $script:TestDir -Force

    $sampleReceipt = @"
Date,Amount,Description
2026-01-15,-2000.00,Rent Payment
2026-01-20,-85.00,Internet Bill
"@
    Set-Content -Path (Join-Path $script:TestDir "receipts.csv") -Value $sampleReceipt -Encoding utf8
}

AfterAll {
    if ($script:TestDir -and (Test-Path $script:TestDir)) {
        Remove-Item -Path $script:TestDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe "Bookkeeping Pipeline Integration" -Tag "Bookkeeping", "Integration" {
    It "Process-Receipts.ps1 runs with -WhatIf (no real changes)" {
        $scriptPath = Join-Path $script:AcctScripts "Process-Receipts.ps1"
        if (-not (Test-Path $scriptPath)) { Set-ItResult -Skipped -Because "Process-Receipts.ps1 not found"; return }
        { & $scriptPath -WhatIf -SourceDir $script:TestDir 2>&1 } | Should -Not -Throw
    }

    It "Invoke-BookkeepingEnrichment.ps1 runs with -WhatIf" {
        $scriptPath = Join-Path $script:AcctScripts "Invoke-BookkeepingEnrichment.ps1"
        if (-not (Test-Path $scriptPath)) { Set-ItResult -Skipped -Because "script not found"; return }
        { & $scriptPath -WhatIf -Entity "room-rentals" 2>&1 } | Should -Not -Throw
    }

    It "Invoke-StatusCheck.ps1 runs with -WhatIf" {
        $scriptPath = Join-Path $script:AcctScripts "Invoke-StatusCheck.ps1"
        if (-not (Test-Path $scriptPath)) { Set-ItResult -Skipped -Because "script not found"; return }
        { & $scriptPath -WhatIf -Organization "room-rentals" 2>&1 } | Should -Not -Throw
    }
}
