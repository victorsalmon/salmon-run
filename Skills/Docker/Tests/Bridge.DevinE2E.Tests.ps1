BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
    $scriptPath = Join-Path $repoRoot 'run-bridge-e2e.ps1'
}

Describe 'Devin bridge e2e script' -Tag 'Bridge', 'Devin', 'Regression' {
    It 'Is parseable' {
        $errs = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$errs)
        $errs | Should -BeNullOrEmpty
    }

    It 'Has the expected parameters' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)
        $paramBlock = $ast.Find({ $args[0] -is [System.Management.Automation.Language.ParamBlockAst] }, $true)
        $paramBlock | Should -Not -BeNullOrEmpty
        $names = $paramBlock.Parameters.Name.VariablePath.UserPath
        $names | Should -Contain 'Model'
        $names | Should -Contain 'Effort'
        $names | Should -Contain 'Prompt'
        $names | Should -Contain 'TimeoutSeconds'
        $names | Should -Contain 'KeepArtifacts'
    }

    It 'Defaults to SWE-1-7 and max effort' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)
        $paramBlock = $ast.Find({ $args[0] -is [System.Management.Automation.Language.ParamBlockAst] }, $true)
        $defaults = @{}
        foreach ($p in $paramBlock.Parameters) {
            if ($p.DefaultValue) {
                $defaults[$p.Name.VariablePath.UserPath] = $p.DefaultValue.Extent.Text.Trim("'")
            }
        }
        $defaults['Model'] | Should -Be 'swe-1-7'
        $defaults['Effort'] | Should -Be 'max'
    }

    It 'Records the latest output to Tasks/Logs/bridge-e2e-latest-output.jsonl' {
        $content = Get-Content $scriptPath -Raw
        $content | Should -Match 'bridge-e2e-latest-output\.jsonl'
    }

    It 'Requires an API key before running the bridge' {
        $content = Get-Content $scriptPath -Raw
        $content | Should -Match 'DEVIN_API_KEY'
        $content | Should -Match 'DSO_ACP_AUTH_API_KEY'
    }
}
