#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }
#Requires -Version 7.0

BeforeAll {
    $__RepoRoot = (Get-Item $PSCommandPath).Directory.Parent.FullName
    $script:Installer = Join-Path $__RepoRoot 'install.ps1'
    $script:StartScript = Join-Path $__RepoRoot 'Start-SalmonRun.ps1'
}

Describe 'salmon-run installer' -Tag 'Installer', 'Regression-Only' {
    BeforeAll {
        $script:SavedInstallerProcessHome = $env:SALMON_RUN_HOME
        $script:SavedInstallerUserHome = [Environment]::GetEnvironmentVariable('SALMON_RUN_HOME', 'User')
    }

    AfterAll {
        if ($null -ne $script:SavedInstallerProcessHome) { $env:SALMON_RUN_HOME = $script:SavedInstallerProcessHome }
        else { Remove-Item Env:\SALMON_RUN_HOME -ErrorAction SilentlyContinue }
        [Environment]::SetEnvironmentVariable('SALMON_RUN_HOME', $script:SavedInstallerUserHome, 'User')
    }

    It 'creates a runtime home with the expected task queues and directories' {
        $tempHome = Join-Path $TestDrive 'salmon-home'
        $tempInstall = Join-Path $TestDrive 'salmon-install'

        & $script:Installer -InstallPath $tempInstall -RuntimeHome $tempHome

        $expectedDirs = @(
            'Tasks/Intake','Tasks/Code','Tasks/Review','Tasks/QA','Tasks/Audit',
            'Tasks/Working','Tasks/Complete','Tasks/Archive','Tasks/Failed',
            'Tasks/Manual','Tasks/Handoffs','Tasks/Temp','Tasks/Logs',
            'Tasks/Project','Tasks/ProjectReview','Tasks/Schedules','Tasks/Locks',
            'providers','benchmarks','benchmarks/models','cache','secrets'
        )
        foreach ($rel in $expectedDirs) {
            Join-Path $tempHome $rel | Should -Exist
        }
    }

    It 'seeds benchmark schema and sample data when the directory is empty' {
        $tempHome = Join-Path $TestDrive 'salmon-home-bench'
        $tempInstall = Join-Path $TestDrive 'salmon-install-bench'

        & $script:Installer -InstallPath $tempInstall -RuntimeHome $tempHome

        Join-Path $tempHome 'benchmarks/models.json' | Should -Exist
        Join-Path $tempHome 'benchmarks/models.schema.json' | Should -Exist
    }

    It 'copies modules into the runtime home and makes them importable' {
        $tempHome = Join-Path $TestDrive 'salmon-home-modules'
        $tempInstall = Join-Path $TestDrive 'salmon-install-modules'

        & $script:Installer -InstallPath $tempInstall -RuntimeHome $tempHome

        Join-Path $tempHome 'Modules/SalmonRun.PondEngine' | Should -Exist
        Join-Path $tempHome 'Modules/SalmonRun.PondEngine/SalmonRun.PondEngine.psd1' | Should -Exist

        $savedModulePath = $env:PSModulePath
        try {
            $env:PSModulePath = (Join-Path $tempHome 'Modules') + ';' + $savedModulePath
            Remove-Module SalmonRun.PondEngine -Force -ErrorAction SilentlyContinue
            Import-Module SalmonRun.PondEngine -Force -ErrorAction Stop
            Get-Command Start-PondEngine -ErrorAction Stop | Should -Not -BeNullOrEmpty
        } finally {
            $env:PSModulePath = $savedModulePath
        }
    }

    It 'does not overwrite an existing .env or benchmark files' {
        $tempHome = Join-Path $TestDrive 'salmon-home-preserve'
        $tempInstall = Join-Path $TestDrive 'salmon-install-preserve'
        $null = New-Item -ItemType Directory -Path $tempHome -Force

        $envFile = Join-Path $tempHome '.env'
        'EXISTING_ENV=1' | Set-Content -LiteralPath $envFile -Encoding utf8

        $benchDir = Join-Path $tempHome 'benchmarks'
        $null = New-Item -ItemType Directory -Path $benchDir -Force
        $benchFile = Join-Path $benchDir 'models.json'
        '{"seeded":true}' | Set-Content -LiteralPath $benchFile -Encoding utf8

        & $script:Installer -InstallPath $tempInstall -RuntimeHome $tempHome

        (Get-Content -LiteralPath $envFile -Raw) | Should -Match 'EXISTING_ENV'
        (Get-Content -LiteralPath $benchFile -Raw) | Should -Match 'seeded'
    }

    It 'preserves custom runtime ignores and adds coordinator state directories' {
        $tempHome = Join-Path $TestDrive 'salmon-home-ignore'
        $tempInstall = Join-Path $TestDrive 'salmon-install-ignore'
        New-Item $tempHome -ItemType Directory -Force | Out-Null
        'custom-local-entry/' | Set-Content (Join-Path $tempHome '.gitignore') -NoNewline
        & $script:Installer -InstallPath $tempInstall -RuntimeHome $tempHome
        $ignore = Get-Content (Join-Path $tempHome '.gitignore') -Raw
        $ignore | Should -Match 'custom-local-entry/'
        $ignore | Should -Match '(?m)^/Results/\r?$'
        $ignore | Should -Match '(?m)^/State/\r?$'
        $ignore | Should -Match '(?m)^/SyncOutbox/\r?$'
    }


}
Describe 'Start-SalmonRun.ps1 dry run' -Tag 'DryRun', 'Regression-Only' {
    It 'uses an explicit runtime home instead of a stale inherited Pester home' {
        $explicitHome = Join-Path $TestDrive 'explicit-live-home'
        $stalePesterHome = Join-Path ([System.IO.Path]::GetTempPath()) 'Pester_stale/salmon-home'
        $null = New-Item -ItemType Directory -Path $explicitHome -Force
        $null = New-Item -ItemType Directory -Path $stalePesterHome -Force

        $savedHome = $env:SALMON_RUN_HOME
        try {
            $env:SALMON_RUN_HOME = $stalePesterHome
            $output = & $script:StartScript -DryRun -RuntimeHome $explicitHome 6>&1

            ($output -join "`n") | Should -Match ([regex]::Escape($explicitHome))
            $env:SALMON_RUN_HOME | Should -Be $explicitHome
        } finally {
            if ($null -ne $savedHome) { $env:SALMON_RUN_HOME = $savedHome }
            else { Remove-Item Env:\SALMON_RUN_HOME -ErrorAction SilentlyContinue }
        }
    }
    It 'lists ponds and queues without spawning agents' {
        $tempHome = Join-Path $TestDrive 'salmon-dryrun'
        $null = New-Item -ItemType Directory -Path $tempHome -Force

        $savedHome = $env:SALMON_RUN_HOME
        try {
            $env:SALMON_RUN_HOME = $tempHome
            $env:PSModulePath = (Join-Path $__RepoRoot 'Modules') + ';' +
                               (Join-Path $__RepoRoot 'Modules') + ';' + $env:PSModulePath

            $output = & $script:StartScript -DryRun -RuntimeHome $tempHome 6>&1
            ($output -join "`n") | Should -Match 'Salmon Run dry run'
            ($output -join "`n") | Should -Match 'Total queued plans'
        } finally {
            $env:SALMON_RUN_HOME = $savedHome
        }
    }
}



