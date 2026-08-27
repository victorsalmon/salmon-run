#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

# Pester tests for Invoke-AutomatedScan.ps1
# Source: Skills/Workflows/Audit/Invoke-AutomatedScan.ps1
# Regression: Scan 8 (module parser validation) must not emit
# "(suppressed [ref] exception: ...)" spam — ParseInput must be called with
# declared variables, not [ref]$null.

BeforeAll {
    $RepoRoot = $PSScriptRoot
    while ($RepoRoot) {
        if (Test-Path (Join-Path $RepoRoot "AGENTS.md") -PathType Leaf) { break }
        if (Test-Path (Join-Path $RepoRoot ".git") -PathType Container) { break }
        $parent = Split-Path $RepoRoot -Parent
        if ($parent -eq $RepoRoot) { break }
        $RepoRoot = $parent
    }
    $Script:ScriptPath = Join-Path $RepoRoot "Skills/Workflows/Audit/Invoke-AutomatedScan.ps1"
    $Script:TempRepo = Join-Path $env:TEMP "automated-scan-test-$(Get-Random)"
    $Script:ModuleDir = Join-Path $Script:TempRepo "Skills/Docker/Modules/TestModule"
    $null = New-Item -ItemType Directory -Path $Script:ModuleDir -Force
    $null = New-Item -ItemType Directory -Path (Join-Path $Script:TempRepo "Infrastructure") -Force
    @'
function Get-TestValue {
    param([int]$Value)
    return $Value * 2
}
'@ | Set-Content -Path (Join-Path $Script:ModuleDir "ValidFile.ps1") -Encoding utf8
    @'
function Get-BrokenValue {
    param([int]$Value
    return $Value
}
'@ | Set-Content -Path (Join-Path $Script:ModuleDir "BrokenFile.ps1") -Encoding utf8
    $Script:OutputFile = Join-Path $Script:TempRepo "Tasks/Logs/automated-scan-test.json"
}

AfterAll {
    if (Test-Path $Script:TempRepo) { Remove-Item $Script:TempRepo -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe "Invoke-AutomatedScan.ps1" -Tag "Audit" {
    It "script file exists" {
        $Script:ScriptPath | Should -Exist
    }

    It "script has valid PowerShell syntax" {
        $content = Get-Content $Script:ScriptPath -Raw
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$tokens, [ref]$errors)
        $errors.Count | Should -Be 0
    }

    It "Scan 8 ParseInput uses declared variables for both [ref] args" {
        $content = Get-Content $Script:ScriptPath -Raw
        $content | Should -Match '\$tokens = \$null'
        $content | Should -Match 'ParseInput\(\$content, \[ref\]\$tokens, \[ref\]\$errors\)'
        $content | Should -Not -Match 'ParseInput\([^)]*\[ref\]\$null'
    }

    It "Scan 8 retains [ref] false-positive filters as defense-in-depth" {
        $content = Get-Content $Script:ScriptPath -Raw
        $content | Should -Match '\[ref\] argument must be a variable'
        $content | Should -Match 'suppressed \[ref\] exception'
    }
}

Describe "Invoke-AutomatedScan.ps1 [ref] exception spam regression" -Tag "Audit", "Regression" {
    It "scan exits 0 with no suppressed [ref] lines and reports the planted parse finding" {
        $output = & pwsh -NoProfile -File $Script:ScriptPath -RepoRoot $Script:TempRepo -OutputFile $Script:OutputFile 6>&1
        $LASTEXITCODE | Should -Be 0
        $joined = $output -join "`n"
        $joined | Should -Not -Match 'suppressed \[ref\] exception'
        $joined | Should -Not -Match '\(filtered \d+ \[ref\]'
        $Script:OutputFile | Should -Exist
        $parsed = Get-Content $Script:OutputFile -Raw | ConvertFrom-Json
        $parsed.totalFindings | Should -Be 1
        $parsed.findings[0].scan | Should -Be "parser-validation"
        $parsed.findings[0].file | Should -Match 'BrokenFile\.ps1$'
    }
}
