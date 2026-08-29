#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }
#Requires -Version 7.0

BeforeAll {
    $__RepoRoot = (Get-Item $PSCommandPath).Directory.Parent.FullName
    $script:OpencodeScript = Join-Path $__RepoRoot 'Modules/SalmonRun.PondEngine/Executors/Opencode.ps1'
}

$feedbackPromptCases = @(
    @{ Role = 'coder'; Patterns = @('Feedback for Coder','FixActions','FailedChecks','Reviewed.*failed','QA.*failed','Audit.*failed') }
    @{ Role = 'reviewer'; Patterns = @('Feedback for Coder','FixActions','FailedChecks','Source.*Review') }
    @{ Role = 'auditor'; Patterns = @('Feedback for Coder','FixActions') }
    @{ Role = 'qa'; Patterns = @('Feedback for Coder','FixActions') }
)

Describe 'OpenCode role prompts surface semantic feedback to coders' -Tag 'PondEngine','Feedback','Regression' {
    It 'role <Role> prompt includes feedback instructions' -TestCases $feedbackPromptCases {
        param([string]$Role, [string[]]$Patterns)

        $td = New-Item -ItemType Directory -Path (Join-Path $TestDrive "feedback-$Role-$(Get-Random)") -Force
        $plan = Join-Path $td 'plan.md'
        @'
# Test plan

**PondLog**

```json
[]
```
'@ | Set-Content -LiteralPath $plan -Encoding utf8 -NoNewline

        . $script:OpencodeScript -Role $Role -LanePath $td -RepoDir $td -PlanFiles @($plan)
        $prompt = Get-OpencodeRolePrompt -Role $Role -RepoDir $td

        foreach ($pattern in $Patterns) {
            $prompt | Should -Match $pattern
        }
    }
}
