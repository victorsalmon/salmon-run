#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

# ==============================================================================
# Interclaw — Pester 6 Tests for Test-ApolloEmailFinder.ps1
# ==============================================================================

Describe "Test-ApolloEmailFinder" -Tag "Marketer" {

    BeforeAll {
        $ScriptPath = Join-Path $PSScriptRoot "..\..\..\Marketer\Test-ApolloEmailFinder.ps1"
    }

    It "exists at expected path" {
        $ScriptPath | Should -Exist
    }

    It "has .SYNOPSIS help comment" {
        $content = Get-Content $ScriptPath -Raw
        $content | Should -Match "\.SYNOPSIS"
    }

    It "has no [OutputType()] annotation (not applicable — script uses exit codes or PassThru)" {
        $content = Get-Content $ScriptPath -Raw
        $content | Should -Not -Match "\[OutputType"
    }

    It "param block parses correctly" {
        $tokens = $null; $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errors)
        $errors | Should -BeNullOrEmpty
    }

    It "accepts -Domain as mandatory parameter" {
        $content = Get-Content $ScriptPath -Raw
        $content | Should -Match '\[Parameter\(Mandatory\)\]'
        $content | Should -Match '\[string\]\$Domain'
    }

    It "accepts -ApiKey parameter" {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$null)
        $paramBlock = $ast.ParamBlock
        $paramBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq "ApiKey" } | Should -Not -BeNullOrEmpty
    }

    It "accepts -Limit parameter with default value" {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$null)
        $paramBlock = $ast.ParamBlock
        $limitParam = $paramBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq "Limit" }
        $limitParam | Should -Not -BeNullOrEmpty
        $limitParam.DefaultValue | Should -Not -BeNullOrEmpty
    }

    It "accepts -PassThru switch" {
        $content = Get-Content $ScriptPath -Raw
        $content | Should -Match '\$PassThru\b'
        $content | Should -Match 'switch\]\$PassThru'
    }

    It "calls Apollo API at /people/search endpoint" {
        $content = Get-Content $ScriptPath -Raw
        $content | Should -Match "/people/search"
    }

    It "reports no-people-found warning" {
        $content = Get-Content $ScriptPath -Raw
        $content | Should -Match "No people found"
    }

    It "exits 1 on API error" {
        $content = Get-Content $ScriptPath -Raw
        $content | Should -Match 'exit\s+1'
    }

    It "saves report to JSON file" {
        $content = Get-Content $ScriptPath -Raw
        $content | Should -Match 'ConvertTo-Json'
        $content | Should -Match 'Set-Content'
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

    It "imports Interclaw Core, Secrets and Diagnostics modules" {
        $content = Get-Content $ScriptPath -Raw
        $content | Should -Match 'Import-InterclawModule Core'
        $content | Should -Match 'Import-InterclawModule Secrets'
        $content | Should -Match 'Import-InterclawModule Diagnostics'
    }

    It "does not reference the stale ORCHESTRATOR.Core/Secrets module paths" {
        $content = Get-Content $ScriptPath -Raw
        $content | Should -Not -Match 'ORCHESTRATOR\.(Core|Secrets)'
    }

    It "keeps the AWS SM fallback for APOLLO_SEARCH" {
        $content = Get-Content $ScriptPath -Raw
        $content | Should -Match 'Get-SecretFromAws -KeyName "APOLLO_SEARCH"'
    }
}

Describe "Test-ApolloEmailFinder AWS SM fallback" -Tag "Marketer", "Regression" {

    It "proceeds via AWS Secrets Manager fallback when -ApiKey and env var are absent" {
        $scriptPath = (Resolve-Path $ScriptPath).Path
        $pwshExe = (Get-Process -Id $PID).Path
        $probeFile = Join-Path $TestDrive "apollo-auth-probe.txt"
        $reportsDir = Join-Path $TestDrive "reports"

        $cmd = @'
Remove-Item Env:APOLLO_SEARCH -ErrorAction SilentlyContinue
function Initialize-InterclawEnvironment { param([string]$RepoRoot) }
function Import-InterclawModule { param([string]$Name) }
function Get-SecretFromAws { param([string]$KeyName) "mock-secret-$KeyName" }
function Get-ReportsDir { New-Item -ItemType Directory -Path '__REPORTS__' -Force | Out-Null; return '__REPORTS__' }
function Write-SetupLog { param($Message, $Level) }
function Invoke-RestMethod {
    param($Uri, [string]$Method, $Headers, $Body, [string]$ContentType, [string]$ErrorAction)
    $Body | Set-Content -Path '__PROBE__'
    return @{
        people = @(@{ first_name = 'Jane'; last_name = 'Doe'; email = 'jane@example.com'; title = 'CEO'; email_confidence = 0.95; organization_name = 'Example'; phone = '555'; linkedin_url = 'https://linkedin.com/in/jane' })
        pagination = @{ page = 1; per_page = 5; total_entries = 1; total_pages = 1 }
    }
}
& '__SCRIPT__' -Domain "example.com" -ApiKey ""
'@
        $cmd = $cmd.Replace('__PROBE__', $probeFile).Replace('__REPORTS__', $reportsDir).Replace('__SCRIPT__', $scriptPath)
        & $pwshExe -NoProfile -Command $cmd | Out-Null
        $LASTEXITCODE | Should -Be 0
        $probe = Get-Content $probeFile -Raw -ErrorAction SilentlyContinue
        $probe | Should -Not -BeNullOrEmpty
        $probe | Should -Match 'mock-secret-APOLLO_SEARCH'
    }
}
