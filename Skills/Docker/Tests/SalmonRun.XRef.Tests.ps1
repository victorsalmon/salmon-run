#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

#Requires -Version 7.0

BeforeAll {
    $RepoRoot = (Get-Item $PSCommandPath).Directory.Parent.Parent.Parent.FullName
    $script:DocRoots = @(
        "docs",
        "AGENTS.md",
        "Skills\ORCHESTRATOR\Personas"
    )
    $script:DocFiles = foreach ($root in $script:DocRoots) {
        $fullPath = Join-Path $RepoRoot $root
        if (Test-Path $fullPath) {
            if (Test-Path -Path $fullPath -PathType Leaf) {
                Get-Item $fullPath
            } else {
                Get-ChildItem $fullPath -Recurse -Include *.md -File
            }
        }
    }
    $script:ExcludedPrefixes = @(
        "Tasks/Complete",
        "Tasks/Manual",
        "Tasks/Logs",
        "Tasks/Locks",
        "Tasks/Working",
        "Workspace"
    )
}

Describe "Documentation Cross-Reference Integrity" -Tag "XRef", "Regression-Only" {
    It "Every file path referenced in documentation exists on disk" {
        $violations = @()
        foreach ($file in $script:DocFiles) {
            $content = Get-Content $file.FullName -Raw
            $pathPattern = '`([A-Z][A-Za-z]*\/[A-Za-z0-9._\/-]+\.[a-z]{1,4})(?::\d+)?`'
            $matches_found = [regex]::Matches($content, $pathPattern)
            foreach ($m in $matches_found) {
                $path = $m.Groups[1].Value.TrimEnd(':')
                $path = ($path -split ':')[0]
                $fullPath = Join-Path $RepoRoot $path
                # Normalize to forward slashes for portable prefix matching across Windows/PowerShell
                $normalizedFullPath = $fullPath -replace '\\', '/'
                $excluded = $script:ExcludedPrefixes | Where-Object { $normalizedFullPath -like "*$($_)*" }
                if ($excluded) { continue }
                if (-not (Test-Path $fullPath)) {
                    $violations += "$($file.Name) -> $path (NOT FOUND)"
                }
            }
        }
        if ($violations) {
            Write-Warning "Documentation references to non-existent files:"
            $violations | ForEach-Object { Write-Warning "  $_" }
        }
        $violations | Should -BeNullOrEmpty -Because "doc references must resolve to real files"
    }
}
