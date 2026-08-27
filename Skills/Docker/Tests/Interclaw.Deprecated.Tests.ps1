#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

#Requires -Version 7.0

BeforeAll {
    $__RepoRoot = (Get-Item $PSCommandPath).Directory.Parent.Parent.Parent.FullName
    $__ModuleDir = Join-Path $__RepoRoot "Skills" "Docker" "Modules" "Interclaw.Deprecated"
}

Describe "Interclaw.Deprecated module structure" -Tag "Deprecated", "Regression" {

    It "module directory exists" {
        $__ModuleDir | Should -Exist
    }

    It "module manifest exists" {
        $__Psd1 | Should -Exist
    }

    It "module loader .psm1 exists" {
        $__Psm1 | Should -Exist
    }

    It "thin wrapper .ps1 exists" {
        $__Ps1 | Should -Exist
    }

    It ".ps1 wrapper delegates to .psm1" {
        $content = Get-Content $__Ps1 -Raw
        $content | Should -Match 'Interclaw\.Deprecated\.psm1'
    }

    It "Public directory exists" {
        $__PublicDir | Should -Exist
    }

    It "exports only Invoke-OpencodeWorkerImageBuild" {
        $manifest = Import-PowerShellDataFile -Path $__Psd1
        $manifest.FunctionsToExport | Should -Be @('Invoke-OpencodeWorkerImageBuild')
    }

    It "has correct GUID" {
        $manifest = Import-PowerShellDataFile -Path $__Psd1
        $manifest.GUID | Should -Be '2826b4f8-6602-4bf1-b104-492ece30698c'
    }

    It "declares SalmonRun.Core dependency" {
        $manifest = Import-PowerShellDataFile -Path $__Psd1
        $manifest.RequiredModules | Should -Contain 'SalmonRun.Core'
    }

    It ".psm1 sets StrictMode -Off" {
        $content = Get-Content $__Psm1 -Raw
        $content | Should -Match 'Set-StrictMode -Off'
    }

    It ".psm1 dot-sources Public/*.ps1" {
        $content = Get-Content $__Psm1 -Raw
        $content | Should -Match 'Get-ChildItem.*Public.*\.ps1'
        $content | Should -Match '\. \$_\..*FullName'
    }

    It "no other .ps1 files in Public/ beyond Invoke-OpencodeWorkerImageBuild" {
        $publicFiles = Get-ChildItem $__PublicDir -Filter '*.ps1' -Recurse
        $publicFiles.Count | Should -Be 1
        $publicFiles[0].Name | Should -Be 'Invoke-OpencodeWorkerImageBuild.ps1'
    }
}

Describe "Invoke-OpencodeWorkerImageBuild deprecated contract" -Tag "Deprecated", "Regression" {

    It "declares the function" {
        $content = Get-Content (Join-Path $__PublicDir 'Invoke-OpencodeWorkerImageBuild.ps1') -Raw
        $content | Should -Match 'function Invoke-OpencodeWorkerImageBuild'
    }

    It "emits deprecation warning" {
        $content = Get-Content (Join-Path $__PublicDir 'Invoke-OpencodeWorkerImageBuild.ps1') -Raw
        $content | Should -Match 'is deprecated'
        $content | Should -Match 'Invoke-CodeWorkerImageBuild'
    }

    It "has .SYNOPSIS" {
        $content = Get-Content (Join-Path $__PublicDir 'Invoke-OpencodeWorkerImageBuild.ps1') -Raw
        $content | Should -Match '\.SYNOPSIS'
    }

    It "declares param() with no parameters" {
        $content = Get-Content (Join-Path $__PublicDir 'Invoke-OpencodeWorkerImageBuild.ps1') -Raw
        $content | Should -Match 'param\(\)'
    }

    It "has OutputType of void" {
        $content = Get-Content (Join-Path $__PublicDir 'Invoke-OpencodeWorkerImageBuild.ps1') -Raw
        $content | Should -Match 'OutputType\(\[void\]\)'
    }
}

Describe "Interclaw.Deprecated template files" -Tag "Deprecated", "Regression" {

    It "Templates directory exists" {
        Join-Path $__ModuleDir "Templates" | Should -Exist
    }

    It "Archive directory exists" {
        Join-Path $__ModuleDir "Archive" | Should -Exist
    }

    It "WORK-container-template.md exists" {
        Join-Path $__ModuleDir "Templates" "WORK-container-template.md" | Should -Exist
    }

    It "CODE-container-template.md exists" {
        Join-Path $__ModuleDir "Templates" "CODE-container-template.md" | Should -Exist
    }

    It "cli-inside-agent-template.md exists" {
        Join-Path $__ModuleDir "Templates" "cli-inside-agent-template.md" | Should -Exist
    }

    It "WORK-agent subdirectory has required files" {
        $workAgentDir = Join-Path $__ModuleDir "Templates" "WORK-agent"
        $workAgentDir | Should -Exist
        "identity.md", "heartbeat.md", "soul.md", "memory.md", "system-prompt.md", "tools.md", "agents.md", "bootstrap.md" | ForEach-Object {
            Join-Path $workAgentDir $_ | Should -Exist
        }
    }

    It "WORK-agent has sovereignty subdirectories" {
        "Canada", "USA", "Global" | ForEach-Object {
            Join-Path $__ModuleDir "Templates" "WORK-agent" $_ | Should -Exist
        }
    }

    It "WORK-agent sovereignty dirs contain ORCHESTRATOR.json" {
        "Canada", "USA", "Global" | ForEach-Object {
            Join-Path $__ModuleDir "Templates" "WORK-agent" $_ "ORCHESTRATOR.json" | Should -Exist
        }
    }

    It "Archive README exists" {
        Join-Path $__ModuleDir "Archive" "README.md" | Should -Exist
    }
}
