#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

# Pester tests for Invoke-PerRepoDependencySweep.ps1
# Source: Skills/Workflows/Audit/Invoke-PerRepoDependencySweep.ps1
# Regression: the script must remain ASCII-only so it parses under Windows
# PowerShell 5.1 (code page 437), and must run on a manifest-less repo root
# without touching the network or failing on missing tools.

BeforeAll {
    $RepoRoot = $PSScriptRoot
    while ($RepoRoot) {
        if (Test-Path (Join-Path $RepoRoot "AGENTS.md") -PathType Leaf) { break }
        if (Test-Path (Join-Path $RepoRoot ".git") -PathType Container) { break }
        $parent = Split-Path $RepoRoot -Parent
        if ($parent -eq $RepoRoot) { break }
        $RepoRoot = $parent
    }
    $Script:ScriptPath = Join-Path $RepoRoot "Skills/Workflows/Audit/Invoke-PerRepoDependencySweep.ps1"
    $Script:TempRepo = Join-Path $env:TEMP "per-repo-dep-sweep-test-$(Get-Random)"
    $null = New-Item -ItemType Directory -Path $Script:TempRepo -Force
    $Script:OutputFile = Join-Path $Script:TempRepo "sweep-report.md"
}

AfterAll {
    if (Test-Path $Script:TempRepo) { Remove-Item $Script:TempRepo -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe "Invoke-PerRepoDependencySweep.ps1" -Tag "Audit" {
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

    It "script contains no non-ASCII characters (PS 5.1 code page 437 portability)" {
        $content = Get-Content $Script:ScriptPath -Raw
        ($content.ToCharArray() | Where-Object { [int]$_ -gt 127 }).Count | Should -Be 0
    }
}

Describe "Invoke-PerRepoDependencySweep.ps1 empty-repo run" -Tag "Audit", "Regression" {
    It "runs on a manifest-less repo root and produces a report without errors" {
        $output = & pwsh -NoProfile -File $Script:ScriptPath -RepoRoot $Script:TempRepo -OutputPath $Script:OutputFile 2>&1
        $LASTEXITCODE | Should -Be 0
        $joined = $output -join "`n"
        $joined | Should -Match 'Dependency sweep report:'
        $Script:OutputFile | Should -Exist
        $report = Get-Content $Script:OutputFile -Raw
        $report | Should -Match 'Manifests scanned: 0 across 0 repos'
        $report | Should -Match 'No vulnerabilities found.'
    }
}
