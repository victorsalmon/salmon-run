#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }
#Requires -Version 7.0

BeforeAll {
    $privateRoot = Join-Path $PSScriptRoot '../Modules/SalmonRun.PondEngine/Private'
    . (Join-Path $privateRoot 'PondRepositoryIdentity.ps1')
    . (Join-Path $privateRoot 'PondSyncOutbox.ps1')
}

Describe 'Serialized sync outbox' -Tag 'PondEngine','Git','Regression-Only' {
    It 'acknowledges an already-pushed checkpoint before retry backoff' {
        $remote = Join-Path $TestDrive 'remote.git'
        $repo = Join-Path $TestDrive 'runtime'
        $taskRoot = Join-Path $repo 'Tasks'
        git init --bare $remote | Out-Null
        git init -b main $repo | Out-Null
        git -C $repo config user.email 'salmon-run-tests@example.invalid'
        git -C $repo config user.name 'Salmon Run Tests'
        New-Item $taskRoot -ItemType Directory -Force | Out-Null
        '# seed' | Set-Content (Join-Path $taskRoot 'plan.md') -NoNewline
        git -C $repo add .
        git -C $repo commit -m seed | Out-Null
        git -C $repo remote add origin $remote
        git -C $repo push -u origin main | Out-Null

        $sha = (git -C $repo rev-parse HEAD).Trim()
        $requestPath = Add-PondSyncRequest -TaskRoot $taskRoot -RepoPath $repo -CommitSha $sha
        $request = Get-Content $requestPath -Raw | ConvertFrom-Json
        $request.attempts = 9
        $request.lastError = 'working-tree-dirty'
        $request.nextAttemptAt = [datetimeoffset]::UtcNow.AddHours(4).ToString('o')
        $request | ConvertTo-Json | Set-Content $requestPath -NoNewline

        $result = Invoke-PondSyncOutbox -TaskRoot $taskRoot

        $result.Succeeded | Should -Be 1
        $result.Backlog | Should -Be 0
        $result.CircuitOpen | Should -BeFalse
        $requestPath | Should -Not -Exist
    }
}