#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

BeforeAll {
    $Script:RepoRoot = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
    $Script:AqeDir = Join-Path $RepoRoot "Skills/AQE"
}

Describe "AQE script: AQE-FullEvaluation.ps1" -Tag "AQE" {
    It "exists at expected path" {
        Join-Path $AqeDir "AQE-FullEvaluation.ps1" | Should -Exist
    }

    It "has .SYNOPSIS help comment" {
        $content = Get-Content (Join-Path $AqeDir "AQE-FullEvaluation.ps1") -Raw
        $content | Should -Match '\.SYNOPSIS'
    }

    It "has .OUTPUTS help comment" {
        $content = Get-Content (Join-Path $AqeDir "AQE-FullEvaluation.ps1") -Raw
        $content | Should -Match '\.OUTPUTS'
    }

    It "param block parses correctly" {
        $content = Get-Content (Join-Path $AqeDir "AQE-FullEvaluation.ps1") -Raw
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$null, [ref]$null)
        $params = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.ParameterAst] }, $true)
        $params.Count | Should -BeGreaterOrEqual 2
    }
}

Describe "AQE script: AQE-CompareBaseline.ps1" -Tag "AQE" {
    It "exists at expected path" {
        Join-Path $AqeDir "AQE-CompareBaseline.ps1" | Should -Exist
    }

    It "has .SYNOPSIS help comment" {
        $content = Get-Content (Join-Path $AqeDir "AQE-CompareBaseline.ps1") -Raw
        $content | Should -Match '\.SYNOPSIS'
    }

    It "has .OUTPUTS help comment" {
        $content = Get-Content (Join-Path $AqeDir "AQE-CompareBaseline.ps1") -Raw
        $content | Should -Match '\.OUTPUTS'
    }

    It "has mandatory ResultsPath parameter" {
        $content = Get-Content (Join-Path $AqeDir "AQE-CompareBaseline.ps1") -Raw
        $content | Should -Match '\[Parameter\(Mandatory\)\]'
        $content | Should -Match '\$ResultsPath'
    }
}

Describe "AQE script: Compare-AQEFleetToSwarm.ps1" -Tag "AQE" {
    It "exists at expected path" {
        Join-Path $AqeDir "Compare-AQEFleetToSwarm.ps1" | Should -Exist
    }

    It "has .SYNOPSIS help comment" {
        $content = Get-Content (Join-Path $AqeDir "Compare-AQEFleetToSwarm.ps1") -Raw
        $content | Should -Match '\.SYNOPSIS'
    }

    It "has .OUTPUTS help comment" {
        $content = Get-Content (Join-Path $AqeDir "Compare-AQEFleetToSwarm.ps1") -Raw
        $content | Should -Match '\.OUTPUTS'
    }

    It "has PassThru parameter" {
        $content = Get-Content (Join-Path $AqeDir "Compare-AQEFleetToSwarm.ps1") -Raw
        $content | Should -Match '-PassThru'
    }
}

Describe "AQE script: Invoke-InterclawDefectPredict.ps1" -Tag "AQE" {
    It "exists at expected path" {
        Join-Path $AqeDir "Invoke-InterclawDefectPredict.ps1" | Should -Exist
    }

    It "has .SYNOPSIS help comment" {
        $content = Get-Content (Join-Path $AqeDir "Invoke-InterclawDefectPredict.ps1") -Raw
        $content | Should -Match '\.SYNOPSIS'
    }

    It "has .OUTPUTS help comment" {
        $content = Get-Content (Join-Path $AqeDir "Invoke-InterclawDefectPredict.ps1") -Raw
        $content | Should -Match '\.OUTPUTS'
    }

    It "has mandatory Path parameter" {
        $content = Get-Content (Join-Path $AqeDir "Invoke-InterclawDefectPredict.ps1") -Raw
        $content | Should -Match '\[Parameter\(Mandatory\s*=\s*\$true\)\]'
    }
}

Describe "AQE script: Invoke-PesterCoverage.ps1" -Tag "AQE" {
    It "exists at expected path" {
        Join-Path $AqeDir "Invoke-PesterCoverage.ps1" | Should -Exist
    }

    It "has .SYNOPSIS help comment" {
        $content = Get-Content (Join-Path $AqeDir "Invoke-PesterCoverage.ps1") -Raw
        $content | Should -Match '\.SYNOPSIS'
    }

    It "has .OUTPUTS help comment" {
        $content = Get-Content (Join-Path $AqeDir "Invoke-PesterCoverage.ps1") -Raw
        $content | Should -Match '\.OUTPUTS'
    }
}

Describe "AQE script: Invoke-PSScriptAnalyzerScan.ps1" -Tag "AQE" {
    It "exists at expected path" {
        Join-Path $AqeDir "Invoke-PSScriptAnalyzerScan.ps1" | Should -Exist
    }

    It "has .SYNOPSIS help comment" {
        $content = Get-Content (Join-Path $AqeDir "Invoke-PSScriptAnalyzerScan.ps1") -Raw
        $content | Should -Match '\.SYNOPSIS'
    }

    It "has .OUTPUTS help comment" {
        $content = Get-Content (Join-Path $AqeDir "Invoke-PSScriptAnalyzerScan.ps1") -Raw
        $content | Should -Match '\.OUTPUTS'
    }
}

Describe "AQE script: Invoke-SprintQualityGate.ps1" -Tag "AQE" {
    It "exists at expected path" {
        Join-Path $AqeDir "Invoke-SprintQualityGate.ps1" | Should -Exist
    }

    It "has .SYNOPSIS help comment" {
        $content = Get-Content (Join-Path $AqeDir "Invoke-SprintQualityGate.ps1") -Raw
        $content | Should -Match '\.SYNOPSIS'
    }

    It "has .OUTPUTS help comment" {
        $content = Get-Content (Join-Path $AqeDir "Invoke-SprintQualityGate.ps1") -Raw
        $content | Should -Match '\.OUTPUTS'
    }
}

Describe "AQE script: Invoke-VERIReviewGate.ps1" -Tag "AQE" {
    It "exists at expected path" {
        Join-Path $AqeDir "Invoke-VERIReviewGate.ps1" | Should -Exist
    }

    It "has .SYNOPSIS help comment" {
        $content = Get-Content (Join-Path $AqeDir "Invoke-VERIReviewGate.ps1") -Raw
        $content | Should -Match '\.SYNOPSIS'
    }

    It "has .OUTPUTS help comment" {
        $content = Get-Content (Join-Path $AqeDir "Invoke-VERIReviewGate.ps1") -Raw
        $content | Should -Match '\.OUTPUTS'
    }
}

Describe "AQE script: Validate-WebhookSecurity.ps1" -Tag "AQE" {
    It "exists at expected path" {
        Join-Path $AqeDir "Validate-WebhookSecurity.ps1" | Should -Exist
    }

    It "has .SYNOPSIS help comment" {
        $content = Get-Content (Join-Path $AqeDir "Validate-WebhookSecurity.ps1") -Raw
        $content | Should -Match '\.SYNOPSIS'
    }

    It "has .OUTPUTS help comment" {
        $content = Get-Content (Join-Path $AqeDir "Validate-WebhookSecurity.ps1") -Raw
        $content | Should -Match '\.OUTPUTS'
    }

    It "has parameter sets for Url and File" {
        $content = Get-Content (Join-Path $AqeDir "Validate-WebhookSecurity.ps1") -Raw
        $content | Should -Match 'ParameterSetName\s*=\s*"Url"'
        $content | Should -Match 'ParameterSetName\s*=\s*"File"'
    }
}

Describe "AQE script: Invoke-OrchestratorDefectPredict.ps1" -Tag "AQE" {
    It "exists at expected path" {
        Join-Path $AqeDir "Invoke-OrchestratorDefectPredict.ps1" | Should -Exist
    }

    It "has .SYNOPSIS help comment" {
        $content = Get-Content (Join-Path $AqeDir "Invoke-OrchestratorDefectPredict.ps1") -Raw
        $content | Should -Match '\.SYNOPSIS'
    }

    It "has .OUTPUTS help comment" {
        $content = Get-Content (Join-Path $AqeDir "Invoke-OrchestratorDefectPredict.ps1") -Raw
        $content | Should -Match '\.OUTPUTS'
    }

    It "param block parses correctly" {
        $content = Get-Content (Join-Path $AqeDir "Invoke-OrchestratorDefectPredict.ps1") -Raw
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$null, [ref]$null)
        $params = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.ParameterAst] }, $true)
        $params.Count | Should -BeGreaterOrEqual 1
    }
}
