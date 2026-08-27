#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

Describe "Native Command Argument Passing" -Tag "Security", "Regression-Only" {
    It "detects no multi-flag-string-to-native-command anti-patterns" {
        $violations = [System.Collections.Generic.List[string]]::new()
        $scriptFiles = Get-ChildItem -Path (Join-Path $PSScriptRoot "..\Scripts") -Recurse -Filter "*.ps1" -File |
            Where-Object { $_.DirectoryName -notmatch 'Tests' -and $_.DirectoryName -notmatch 'node_modules' -and $_.DirectoryName -notmatch '\.opencode' }
        foreach ($file in $scriptFiles) {
            $content = Get-Content -Path $file.FullName -Raw -ErrorAction SilentlyContinue
            if (-not $content) { continue }
            $matches = [regex]::Matches($content, '(?m)^\s*\$([a-zA-Z]\w*)\s*=\s*"(-[a-z].*?-\w.*?)"')
            foreach ($m in $matches) {
                $varName = $m.Groups[1].Value
                $afterLines = $content.Substring($m.Index + $m.Length)
                $nativeCmdPattern = '(docker|aws|git|wsl|netsh)\s+.*\$' + [regex]::Escape($varName) + '\b'
                if ($afterLines -match $nativeCmdPattern) {
                    $violations.Add("$($file.FullName): `$$varName = `"$($m.Groups[2].Value)`" passed to native command")
                }
            }
        }
        if ($violations.Count -gt 0) {
            Write-Host "Violations found:" -ForegroundColor Yellow
            foreach ($v in $violations) { Write-Host "  $v" -ForegroundColor Yellow }
        }
        $violations.Count | Should -Be 0
    }
}
