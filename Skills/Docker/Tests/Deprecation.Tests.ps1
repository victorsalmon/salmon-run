#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..\..")
    $installJsonPath = Join-Path $repoRoot "install.json"
}

Describe "No FLEET_API_TOKEN_DOCUSIGN on mcp_opencode" -Tag "Deprecation" {

    It "New-FleetCompose does not mount FLEET_API_TOKEN_DOCUSIGN on mcp_opencode" {
        # Load the compose generation module function directly
        $composeFunc = Join-Path $repoRoot "Skills\Docker\Modules\SalmonRun.Deploy\Public\New-FleetCompose.ps1"
        if (-not (Test-Path $composeFunc)) {
            Set-ItResult -Skipped -Because "New-FleetCompose.ps1 not found"
            return
        }
        $script = Get-Content $composeFunc -Raw
        # mcp_opencode secrets block should not reference FLEET_API_TOKEN_DOCUSIGN
        $script | Should -Not -Match "mcp_opencode.*FLEET_API_TOKEN_DOCUSIGN"
    }
}

Describe "API-Contracts.md mcp_docusign reference" -Tag "Deprecation" {

    It "mcp_docusign section is marked as RETIRED" {
        $apiContracts = Join-Path $repoRoot "docs\Reference\API-Contracts.md"
        $content = Get-Content $apiContracts -Raw
        $content | Should -Match "mcp_docusign.*(?:RETIRED|DEPRECATED)" -Because "mcp_docusign is retired"
    }
}

Describe "Invoke-OpencodeWorkerImageBuild — deprecated wrapper" -Tag "Deprecation" {
    BeforeAll {
        $script:srcPath = Join-Path $PSScriptRoot "..\Modules\Interclaw.Deprecated\Public\Invoke-OpencodeWorkerImageBuild.ps1"
    }

    It "declares the function with the correct name" {
        $content = Get-Content $script:srcPath -Raw
        $content | Should -Match 'function Invoke-OpencodeWorkerImageBuild'
    }

    It "exports via FunctionsToExport in module manifest" {
        $manifest = Get-Content (Join-Path $PSScriptRoot "..\Modules\Interclaw.Deprecated\Interclaw.Deprecated.psd1") -Raw
        $manifest | Should -Match 'Invoke-OpencodeWorkerImageBuild'
    }

    It "emits deprecation warning when loaded" {
        $content = Get-Content $script:srcPath -Raw
        $content | Should -Match "is deprecated"
        $content | Should -Match "Invoke-CodeWorkerImageBuild"
    }

    It "constructs Dockerfile path from TargetDir" {
        $content = Get-Content $script:srcPath -Raw
        $content | Should -Match 'Join-Path \$TargetDir "Infrastructure" "opencode-worker.Dockerfile"'
    }

    It "computes SHA256 source hash from Dockerfile and COPY contents" {
        $content = Get-Content $script:srcPath -Raw
        $content | Should -Match 'Get-FileHash'
        $content | Should -Match 'SHA256'
        $content | Should -Match 'MemoryStream'
    }

    It "uses org.interclaw.worker.source-hash label for change tracking" {
        $content = Get-Content $script:srcPath -Raw
        $content | Should -Match 'org.interclaw.worker.source-hash'
    }

    It "checks existing image before deciding to rebuild" {
        $content = Get-Content $script:srcPath -Raw
        $content | Should -Match 'docker image inspect opencode-worker:local'
    }

    It "handles missing Dockerfile with error exit" {
        $content = Get-Content $script:srcPath -Raw
        $content | Should -Match 'exit 1'
        $content | Should -Match 'Dockerfile not found'
    }

    It "uses Write-SetupLog for build status reporting" {
        $content = Get-Content $script:srcPath -Raw
        $content | Should -Match 'Write-SetupLog'
    }

    It "uses Push-Location / Pop-Location around docker build" {
        $content = Get-Content $script:srcPath -Raw
        $content | Should -Match 'Push-Location \$TargetDir'
        $content | Should -Match 'Pop-Location'
    }

    It "removes stale latest tag before building" {
        $content = Get-Content $script:srcPath -Raw
        $content | Should -Match 'docker image rm opencode-worker:latest'
    }
}

Describe "Start-ParallelImageBuild no longer includes docusign" -Tag "Deprecation" {

    It "Start-ParallelImageBuild.ps1 does not conditionally include docusign" {
        $script = Join-Path $repoRoot "Skills\Docker\Modules\SalmonRun.Images\Public\Start-ParallelImageBuild.ps1"
        $content = Get-Content $script -Raw
        $content | Should -Not -Match 'docusignEnabled'
        $content | Should -Not -Match 'mcp_docusign'
    }
}
