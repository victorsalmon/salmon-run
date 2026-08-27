#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

# ==============================================================================
# Source: env var registry (Scripts/0setup.ps1)
# ==============================================================================

<#
.SYNOPSIS
    Validates the environment variable registry and parallel-safety invariants.
#>

Describe "Env Var Registry" -Tag "Governance" {
    It "Registry file exists and is valid JSON" {
        $root = (Get-Item $PSCommandPath).Directory.Parent.Parent.Parent.FullName
        $reg = Join-Path $root "docs\Reference\env-var-registry.json"
        $reg | Should -Exist
        $Json = Get-Content $reg -Raw
        { $Json | ConvertFrom-Json -ErrorAction Stop } | Should -Not -Throw
    }

    It "Registry has all required fields for each entry" {
        $root = (Get-Item $PSCommandPath).Directory.Parent.Parent.Parent.FullName
        $reg = Join-Path $root "docs\Reference\env-var-registry.json"
        $Registry = Get-Content $reg -Raw | ConvertFrom-Json
        foreach ($Entry in $Registry.envVars.PSObject.Properties) {
            $Entry.Value.description | Should -Not -BeNullOrEmpty
            $Entry.Value.scope | Should -Not -BeNullOrEmpty
            ($Entry.Value.parallelSafe -eq $true -or $Entry.Value.parallelSafe -eq $false) | Should -Be $true -Because "parallelSafe should be boolean"
        }
    }
}

Describe "AgentContext parameterization" -Tag "Provision" {
    BeforeAll {
        $root = (Get-Item $PSCommandPath).Directory.Parent.Parent.Parent.FullName
        . (Join-Path $root "Orchestrator\Modules\SalmonRun.Core\SalmonRun.Core.ps1")
        . (Join-Path $root "Skills\Docker\Modules\SalmonRun.Secrets\SalmonRun.Secrets.ps1")
        . (Join-Path $root "Skills\Docker\Modules\SalmonRun.Identity\SalmonRun.Identity.ps1")
        . (Join-Path $root "Skills\Docker\Modules\SalmonRun.Provision\SalmonRun.Provision.ps1")
    }

    It "New-AgentIamUser accepts -AgentContext parameter" {
        $Func = Get-Command New-AgentIamUser -ErrorAction SilentlyContinue
        $Func | Should -Not -BeNullOrEmpty
        $Func.Parameters.ContainsKey('AgentContext') | Should -Be $true
    }

    It "New-SentryIamUser accepts -AgentContext parameter" {
        $Func = Get-Command New-SentryIamUser -ErrorAction SilentlyContinue
        $Func | Should -Not -BeNullOrEmpty
        $Func.Parameters.ContainsKey('AgentContext') | Should -Be $true
    }

    It "New-RekognitionFallbackIamUser accepts -AgentContext parameter" {
        $Func = Get-Command New-RekognitionFallbackIamUser -ErrorAction SilentlyContinue
        $Func | Should -Not -BeNullOrEmpty
        $Func.Parameters.ContainsKey('AgentContext') | Should -Be $true
    }

    It "Invoke-OrphanIamCleanup accepts -AgentContext parameter" {
        $Func = Get-Command Invoke-OrphanIamCleanup -ErrorAction SilentlyContinue
        $Func | Should -Not -BeNullOrEmpty
        $Func.Parameters.ContainsKey('AgentContext') | Should -Be $true
    }

    It "Invoke-OrphanIamCleanup accepts -AdditionalProtectedInstanceIds parameter" {
        $Func = Get-Command Invoke-OrphanIamCleanup -ErrorAction SilentlyContinue
        $Func | Should -Not -BeNullOrEmpty
        $Func.Parameters.ContainsKey('AdditionalProtectedInstanceIds') | Should -Be $true
    }

    It "Invoke-BedrockProfileSetup accepts -AgentContext parameter" {
        $Func = Get-Command Invoke-BedrockProfileSetup -ErrorAction SilentlyContinue
        $Func | Should -Not -BeNullOrEmpty
        $Func.Parameters.ContainsKey('AgentContext') | Should -Be $true
    }

    It "Invoke-SecretHydration accepts -AgentContext parameter" {
        $Func = Get-Command Invoke-SecretHydration -ErrorAction SilentlyContinue
        $Func | Should -Not -BeNullOrEmpty
        $Func.Parameters.ContainsKey('AgentContext') | Should -Be $true
    }
}

Describe "Parallel-safety static analysis" -Tag "Governance" {
    It "Parallel blocks should not contain env-var mutations" {
        $root = (Get-Item $PSCommandPath).Directory.Parent.Parent.Parent.FullName
        $ModuleFiles = Get-ChildItem -Path (Join-Path $root "Skills" "Docker" "Modules") -Recurse -Filter "*.ps1" -File
        $ParallelLines = @()
        foreach ($file in $ModuleFiles) {
            $Content = Get-Content $file.FullName -Raw
            $Lines = $Content -split "`n"
            $inParallel = $false
            $depth = 0
            for ($i = 0; $i -lt $Lines.Count; $i++) {
                $line = $Lines[$i]
                if ($line -match 'ForEach-Object\s+-Parallel') { $inParallel = $true; $depth = 0 }
                if ($inParallel) {
                    foreach ($c in $line.ToCharArray()) {
                        if ($c -eq '{') { $depth++ }
                        elseif ($c -eq '}') { $depth-- }
                    }
                    if ($depth -le 0 -and $line -match '^\s*\}' -and $inParallel) { $inParallel = $false }
                }
                if ($inParallel -and $line -match 'Set-Item.*Env:') {
                    $ParallelLines += "$($file.Name):$($i+1) — $($line.Trim())"
                }
            }
        }
        $ParallelLines | Should -BeNullOrEmpty
    }
}

Describe "New-AgentContext" -Tag "Identity" {
    BeforeAll {
        $root = (Get-Item $PSCommandPath).Directory.Parent.Parent.Parent.FullName
        . (Join-Path $root "Orchestrator\Modules\SalmonRun.Core\SalmonRun.Core.ps1")
        . (Join-Path $root "Orchestrator\Modules\SalmonRun.Config\SalmonRun.Config.ps1")
        . (Join-Path $root "Skills\Docker\Modules\SalmonRun.Identity\SalmonRun.Identity.ps1")
    }

    It "Creates context from explicit parameters" {
        $Ctx = New-AgentContext -ProjectCode "TEST" -RoleCode "ORCH" -InstanceId "99" -Index 0
        $Ctx.ProjectCode | Should -Be "TEST"
        $Ctx.RoleCode | Should -Be "ORCH"
        $Ctx.InstanceId | Should -Be "99"
        $Ctx.Index | Should -Be 0
        $Ctx.AgentName | Should -Be "Agent-TEST-ORCH-99"
        $Ctx.GatewayPort | Should -BeOfType [int]
        $Ctx.SecretPrefix | Should -Not -BeNullOrEmpty
        $Ctx.SovereigntyTier | Should -Not -BeNullOrEmpty
    }
}
