#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

# Pester tests for Invoke-AqeAuditScan.ps1
# Source: Skills/Workflows/Audit/Invoke-AqeAuditScan.ps1

BeforeAll {
    $RepoRoot = $PSScriptRoot
    while ($RepoRoot) {
        if (Test-Path (Join-Path $RepoRoot "AGENTS.md") -PathType Leaf) { break }
        if (Test-Path (Join-Path $RepoRoot ".git") -PathType Container) { break }
        $parent = Split-Path $RepoRoot -Parent
        if ($parent -eq $RepoRoot) { break }
        $RepoRoot = $parent
    }
    $Script:ScriptPath = Join-Path $RepoRoot "Skills/Workflows/Audit/Invoke-AqeAuditScan.ps1"
    $Script:TempDir = Join-Path $env:TEMP "aqe-audit-test-$(Get-Random)"
    New-Item -ItemType Directory -Path $Script:TempDir -Force | Out-Null
}

AfterAll {
    if (Test-Path $Script:TempDir) { Remove-Item $Script:TempDir -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe "AQE Audit Scan script" -Tag "AQE", "Audit" {
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

    It "script has param block with expected parameters" {
        $content = Get-Content $Script:ScriptPath -Raw
        $content | Should -Match '\$BridgeUrl'
        $content | Should -Match '\$OutputFile'
        $content | Should -Match '\$SkipQualityAssess'
        $content | Should -Match '\$SkipValidationPipeline'
        $content | Should -Match '\$SkipSecurityScan'
        $content | Should -Match '\$SkipTopologyAnalysis'
        $content | Should -Match '\$SkipCoherenceAudit'
        $content | Should -Match '\$SkipDefectPredict'
    }

    It "does not recreate the retired AQE bridge URL default" {
        $content = Get-Content $Script:ScriptPath -Raw
        $content | Should -Not -Match 'http://mcp_aqe:21004'
        $content | Should -Match 'AQE_BRIDGE_URL'
    }

    It "script references all 6 AQE tools" {
        $content = Get-Content $Script:ScriptPath -Raw
        $content | Should -Match 'quality_assess'
        $content | Should -Match 'validation_pipeline'
        $content | Should -Match 'qe_security_url-validate'
        $content | Should -Match 'qe_mincut_analyze'
        $content | Should -Match 'qe_coherence_audit'
        $content | Should -Match 'defect_predict'
    }

    It "script handles unreachable bridge gracefully (non-blocking)" {
        $content = Get-Content $Script:ScriptPath -Raw
        $content | Should -Match 'non-blocking'
        $content | Should -Match 'unreachable'
        # Should write empty results file and return, not throw
        $content | Should -Match 'available = \$false'
    }

    It "script writes JSON output file" {
        $content = Get-Content $Script:ScriptPath -Raw
        $content | Should -Match 'ConvertTo-Json'
        $content | Should -Match 'Set-Content.*OutputFile'
    }

    It "script has summary with per-scan counts" {
        $content = Get-Content $Script:ScriptPath -Raw
        $content | Should -Match 'qualityAssess'
        $content | Should -Match 'validationPipeline'
        $content | Should -Match 'securityScan'
        $content | Should -Match 'topologyAnalysis'
        $content | Should -Match 'coherenceAudit'
        $content | Should -Match 'defectPredict'
    }

    It "script uses recommended AQE parameters per agent guide" {
        $content = Get-Content $Script:ScriptPath -Raw
        # validation_pipeline should use pipeline="requirements" and continueOnFailure=true
        $content | Should -Match 'pipeline.*=.*"requirements"'
        $content | Should -Match 'continueOnFailure.*=.*\$true'
        # quality_assess should use runGate=true
        $content | Should -Match 'runGate.*=.*\$true'
        # qe_mincut_analyze should use weaknessThreshold=0.4 and includePartitioningPoints=true
        $content | Should -Match 'weaknessThreshold.*=.*0\.4'
        $content | Should -Match 'includePartitioningPoints.*=.*\$true'
        # qe_security_url-validate should use enablePII=true
        $content | Should -Match 'enablePII.*=.*\$true'
    }

    Context "Integration (requires AQE bridge)" -Tag "Integration", "Regression-Only" {
        It "runs and produces output file when bridge is unreachable" {
            $outputPath = Join-Path $Script:TempDir "aqe-test-output.json"
            $result = & $Script:ScriptPath -BridgeUrl "http://127.0.0.1:1" -OutputFile $outputPath -TimeoutSec 5
            $outputPath | Should -Exist
            $parsed = Get-Content $outputPath -Raw | ConvertFrom-Json
            $parsed.available | Should -Be $false
            $parsed.findings.Count | Should -Be 0
        }
    }
}
