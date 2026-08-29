BeforeAll {
    $script:ModuleRoot = "$PSScriptRoot/../Modules/SalmonRun.PondEngine"
    . "$PSScriptRoot/../Modules/SalmonRun.PondEngine/Private/Write-PondOperationalEvent.ps1"
    . "$PSScriptRoot/../Modules/SalmonRun.PondEngine/Public/PlanLog.ps1"
}

Describe 'Bounded plan packets and external operational journal' {
    BeforeEach {
        $script:root = Join-Path $TestDrive '.salmon'
        $script:plan = Join-Path $script:root 'Tasks/Code/plan.md'
        $null = New-Item (Split-Path $script:plan) -ItemType Directory -Force
        '# immutable specification' | Set-Content $script:plan -NoNewline
    }

    It 'keeps operational telemetry out of the plan packet' {
        Add-PlanPondLog -PlanPath $script:plan -Entry @{ pond='Code'; role='coder'; action='claim'; detail='claimed' }
        (Get-Content $script:plan -Raw) | Should -Not -Match 'PondLog'
        $events = Join-Path $script:root 'Logs/workflow-events.jsonl'
        $events | Should -Exist
        (Get-Content $events -Raw) | Should -Match '"action":"claim"'
    }

    It 'retains only the latest 32 semantic outcomes in one PondLog block' {
        1..40 | ForEach-Object { Add-PlanPondLog -PlanPath $script:plan -Entry @{ pond='Review'; role='reviewer'; action='review'; detail="attempt $_" } }
        @(Get-PlanPondLog -PlanPath $script:plan).Count | Should -Be 32
        ([regex]::Matches((Get-Content $script:plan -Raw), '(?im)^\*\*PondLog\*\*')).Count | Should -Be 1
        (Get-Content $script:plan -Raw).Length | Should -BeLessThan 65536
    }
}