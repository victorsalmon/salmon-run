#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

# ==============================================================================
# Interclaw — Pester 6 Tests for New-AttioCustomFields.ps1
# ==============================================================================

Describe "New-AttioCustomFields" -Tag "Marketer" {

    BeforeAll {
        $ScriptPath = Join-Path $PSScriptRoot "..\..\..\Marketer\New-AttioCustomFields.ps1"
    }

    It "exists at expected path" {
        $ScriptPath | Should -Exist
    }

    It "has .SYNOPSIS help comment" {
        $content = Get-Content $ScriptPath -Raw
        $content | Should -Match "\.SYNOPSIS"
    }

    It "has no [OutputType()] annotation (not applicable — script uses exit codes)" {
        $content = Get-Content $ScriptPath -Raw
        $content | Should -Not -Match "\[OutputType"
    }

    It "param block parses correctly" {
        $tokens = $null; $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errors)
        $errors | Should -BeNullOrEmpty
    }

    It "accepts -ApiKey parameter" {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$null)
        $paramBlock = $ast.ParamBlock
        $paramBlock | Should -Not -BeNullOrEmpty
        $paramBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq "ApiKey" } | Should -Not -BeNullOrEmpty
    }

    It "accepts -BaseUrl parameter with default value" {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$null)
        $paramBlock = $ast.ParamBlock
        $baseUrlParam = $paramBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq "BaseUrl" }
        $baseUrlParam | Should -Not -BeNullOrEmpty
        $baseUrlParam.DefaultValue | Should -Not -BeNullOrEmpty
    }

    It "defines 4 custom fields by slug names" {
        $content = Get-Content $ScriptPath -Raw
        $content | Should -Match 'slug\s*=\s*"verification_status"'
        $content | Should -Match 'slug\s*=\s*"email_confidence"'
        $content | Should -Match 'slug\s*=\s*"lead_score"'
        $content | Should -Match 'slug\s*=\s*"campaign_status"'
    }

    It "has idempotency check for existing slugs" {
        $content = Get-Content $ScriptPath -Raw
        $content | Should -Match '\$Slug\s+-in\s+\$ExistingSlugs'
    }

    It "exits 1 when no API key is available" {
        $content = Get-Content $ScriptPath -Raw
        $content | Should -Match 'exit\s+1'
    }

    It "bootstraps via Initialize-InterclawEnvironment with repo root two levels up" {
        $content = Get-Content $ScriptPath -Raw
        $content | Should -Match '\$__ocRepoRoot = Split-Path \(Split-Path \$PSScriptRoot -Parent\) -Parent'
        $content | Should -Match 'Initialize-InterclawEnvironment -RepoRoot \$__ocRepoRoot'
    }

    It "adds Skills/Docker/Modules to PSModulePath before Initialize-InterclawEnvironment" {
        $content = Get-Content $ScriptPath -Raw
        $content | Should -Match '\$env:PSModulePath = "\$__ocRepoRoot\\Skills\\Docker\\Modules'
        $psModulePathIdx = $content.IndexOf('PSModulePath')
        $initIdx = $content.IndexOf('Initialize-InterclawEnvironment')
        $psModulePathIdx | Should -BeGreaterThan 0
        $initIdx | Should -BeGreaterThan $psModulePathIdx
    }

    It "imports Interclaw Core and Secrets modules" {
        $content = Get-Content $ScriptPath -Raw
        $content | Should -Match 'Import-InterclawModule Core'
        $content | Should -Match 'Import-InterclawModule Secrets'
    }

    It "does not reference the stale ORCHESTRATOR.Core/Secrets module paths" {
        $content = Get-Content $ScriptPath -Raw
        $content | Should -Not -Match 'ORCHESTRATOR\.(Core|Secrets)'
    }

    It "keeps the AWS SM fallback for ATTIO_WRITE_KEY" {
        $content = Get-Content $ScriptPath -Raw
        $content | Should -Match 'Get-SecretFromAws -KeyName "ATTIO_WRITE_KEY"'
    }
}

Describe "New-AttioCustomFields AWS SM fallback" -Tag "Marketer", "Regression" {

    It "proceeds via AWS Secrets Manager fallback when -ApiKey and env var are absent" {
        $scriptPath = (Resolve-Path $ScriptPath).Path
        $pwshExe = (Get-Process -Id $PID).Path
        $probeFile = Join-Path $TestDrive "attio-auth-probe.txt"

        $cmd = @'
Remove-Item Env:ATTIO_WRITE_KEY -ErrorAction SilentlyContinue
function Initialize-InterclawEnvironment { param([string]$RepoRoot) }
function Import-InterclawModule { param([string]$Name) }
function Get-SecretFromAws { param([string]$KeyName) "mock-secret-$KeyName" }
function Invoke-RestMethod {
    param($Uri, [string]$Method, $Headers, $Body, [string]$ContentType, [string]$ErrorAction)
    if ($Method -eq 'GET') {
        "GET`t$($Headers['Authorization'])" | Set-Content -Path '__PROBE__'
        return @{ data = @(@{ slug = 'existing_field' }) }
    }
    return @{ ok = $true }
}
& '__SCRIPT__' -ApiKey ""
'@
        $cmd = $cmd.Replace('__PROBE__', $probeFile).Replace('__SCRIPT__', $scriptPath)
        & $pwshExe -NoProfile -Command $cmd | Out-Null
        $LASTEXITCODE | Should -Be 0
        $probe = Get-Content $probeFile -Raw -ErrorAction SilentlyContinue
        $probe | Should -Not -BeNullOrEmpty
        $probe | Should -Match 'Bearer mock-secret-ATTIO_WRITE_KEY'
    }
}
