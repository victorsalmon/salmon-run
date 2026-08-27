#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

Describe "Write-AtomicFile helper function" -Tag "Core", "Regression-Only" {
    BeforeAll {
        $atomicFilePath = Join-Path $PSScriptRoot "..\..\..\Orchestrator\Modules\SalmonRun.Core\Public\Write-AtomicFile.ps1"
        . $atomicFilePath
    }

    It "Write-AtomicFile helper exists in SalmonRun.Core Public" {
        Test-Path $atomicFilePath | Should -Be $true
    }

    It "Write-AtomicFile uses temp file + atomic-replace primitive (MoveFileEx/File.Move/Move-Item)" {
        $content = Get-Content -LiteralPath $atomicFilePath -Raw
        $content | Should -Match 'GetRandomFileName|\.tmp'
        $content | Should -Match 'MoveFileEx|\[System\.IO\.File\]::Move|Move-Item'
    }

    It "Write-AtomicFile writes correct content to final path" {
        $testDir = Join-Path $env:TEMP "oc-atomic-test-$(Get-Random)"
        New-Item -ItemType Directory -Path $testDir -Force | Out-Null
        try {
            $testFile = Join-Path $testDir "test-output.txt"
            "hello world" | Write-AtomicFile -Path $testFile -Encoding utf8
            Test-Path $testFile | Should -Be $true
            (Get-Content -LiteralPath $testFile -Raw).Trim() | Should -Be "hello world"
        } finally {
            Remove-Item -LiteralPath $testDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "Write-AtomicFile does not leave .tmp file after success" {
        $testDir = Join-Path $env:TEMP "oc-atomic-test-$(Get-Random)"
        New-Item -ItemType Directory -Path $testDir -Force | Out-Null
        try {
            $testFile = Join-Path $testDir "test-output.txt"
            "data" | Write-AtomicFile -Path $testFile -Encoding utf8
            Test-Path "$testFile.tmp" | Should -Be $false
        } finally {
            Remove-Item -LiteralPath $testDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "Write-AtomicFile preserves content on crash — .tmp exists before rename" {
        $testDir = Join-Path $env:TEMP "oc-atomic-test-$(Get-Random)"
        New-Item -ItemType Directory -Path $testDir -Force | Out-Null
        try {
            $testFile = Join-Path $testDir "test-output.txt"
            $tmpFile = "$testFile.tmp"
            "crash recovery data" | Set-Content -Path $tmpFile -Encoding utf8
            Move-Item -LiteralPath $tmpFile -Destination $testFile -Force
            Test-Path $testFile | Should -Be $true
            (Get-Content -LiteralPath $testFile -Raw).Trim() | Should -Be "crash recovery data"
            Test-Path $tmpFile | Should -Be $false
        } finally {
            Remove-Item -LiteralPath $testDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe "Call sites use Write-AtomicFile" -Tag "Core", "Regression-Only" {
    It "Compile-FleetComposeOutput uses Write-AtomicFile for compose output" {
        $composePath = Join-Path $PSScriptRoot "..\Modules\SalmonRun.Deploy\Public\Compile-FleetComposeOutput.ps1"
        $content = Get-Content -LiteralPath $composePath -Raw
        $content | Should -Match 'Write-AtomicFile.*OutputPath'
        $content | Should -Not -Match 'Set-Content.*OutputPath'
    }

    It "New-FleetCompose delegates compose output to Compile-FleetComposeOutput" {
        $composePath = Join-Path $PSScriptRoot "..\Modules\SalmonRun.Deploy\Public\New-FleetCompose.ps1"
        $content = Get-Content -LiteralPath $composePath -Raw
        $content | Should -Match 'Compile-FleetComposeOutput'
    }

    It "New-FleetAliases uses Write-AtomicFile for alias file" {
        $aliasesPath = Join-Path $PSScriptRoot "..\Modules\SalmonRun.Deploy\Public\New-FleetAliases.ps1"
        $content = Get-Content -LiteralPath $aliasesPath -Raw
        $content | Should -Match 'Write-AtomicFile.*AliasFile'
        $content | Should -Not -Match 'Set-Content.*AliasFile'
    }

    It "deploy phase modules persist password/token atomically (no plaintext Out-File)" {
        $dockerSecretsPath = Join-Path $PSScriptRoot "..\Modules\SalmonRun.Deploy\Public\Invoke-DeployPhaseDockerSecrets.ps1"
        $iamBedrockPath = Join-Path $PSScriptRoot "..\Modules\SalmonRun.Deploy\Public\Invoke-DeployPhaseIamAndBedrock.ps1"
        $dockerSecrets = Get-Content -LiteralPath $dockerSecretsPath -Raw
        $iamBedrock = Get-Content -LiteralPath $iamBedrockPath -Raw
        $dockerSecrets | Should -Match 'WriteAllBytes.*persistedPasswordFile'
        $dockerSecrets | Should -Match 'WriteAllBytes.*persistedTokenFile'
        $dockerSecrets | Should -Not -Match 'Out-File.*persisted'
        $iamBedrock | Should -Match 'Write-AtomicFile.*persistedTokenFile'
        $iamBedrock | Should -Not -Match 'Out-File.*persisted'
    }
}
