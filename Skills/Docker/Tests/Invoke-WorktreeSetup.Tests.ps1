#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

#Requires -Version 7.0

BeforeAll {
    $script:SetupPath = Join-Path $PSScriptRoot '..' '..' 'Git' 'Invoke-WorktreeSetup.ps1'
    . (Resolve-Path $script:SetupPath).Path

    $script:TestRepo = Join-Path $TestDrive 'test-repo'
    $null = New-Item -ItemType Directory -Path $script:TestRepo -Force
    git -C $script:TestRepo init 2>&1 | Out-Null
    git -C $script:TestRepo config user.name 'Test Agent' 2>&1 | Out-Null
    git -C $script:TestRepo config user.email 'test@example.com' 2>&1 | Out-Null
    'base' | Set-Content (Join-Path $script:TestRepo 'README.md') -NoNewline
    git -C $script:TestRepo add README.md 2>&1 | Out-Null
    git -C $script:TestRepo commit -m 'test base' 2>&1 | Out-Null
    git -C $script:TestRepo branch -M main 2>&1 | Out-Null
}

Describe 'New-AgentWorktree path validation' -Tag 'Unit', 'Regression', 'Worktree' {
    It 'rejects an ordinary nested directory as an existing worktree' {
        $worktreePath = Join-Path $script:TestRepo 'Tasks/Worktrees/module-1'
        $null = New-Item -ItemType Directory -Path $worktreePath -Force

        Push-Location $script:TestRepo
        try {
            $result = New-AgentWorktree -BranchName 'wt/module-1' -WorktreePath $worktreePath -BaseRef 'main' -Resume
            $result.Error | Should -Be $true
            $result.Message | Should -Match 'not a git worktree'
            $result.Source | Should -Not -Be 'existing'
        } finally {
            Pop-Location
        }
    }

    It 'rejects every ordinary nested path, even when its branch already exists' {
        Push-Location $script:TestRepo
        try {
            $relativePaths = @('Tasks/Worktrees/module-a', 'tmp/module-b', 'nested/module-c')
            for ($i = 0; $i -lt $relativePaths.Count; $i++) {
                $worktreePath = Join-Path $script:TestRepo $relativePaths[$i]
                $null = New-Item -ItemType Directory -Path $worktreePath -Force
                $branchName = "wt/module-property-$i"
                $null = git branch $branchName main 2>&1

                $result = New-AgentWorktree -BranchName $branchName -WorktreePath $worktreePath -BaseRef 'main' -Resume
                $result.Error | Should -Be $true
                $result.Message | Should -Match 'not a git worktree'
            }
        } finally {
            Pop-Location
        }
    }

    It 'recognizes a path that Git actually registers as a worktree' {
        $worktreePath = Join-Path $script:TestRepo 'Tasks/Worktrees/registered'

        Push-Location $script:TestRepo
        try {
            $created = New-AgentWorktree -BranchName 'wt/registered' -WorktreePath $worktreePath -BaseRef 'main'
            $created.Error | Should -Be $null
            $created.Source | Should -Be 'created'

            $existing = New-AgentWorktree -BranchName 'wt/registered' -WorktreePath $worktreePath -BaseRef 'main' -Resume
            $existing.Source | Should -Be 'existing'
            $existing.BranchName | Should -Be 'wt/registered'
            Test-Path $worktreePath | Should -Be $true
            @((Get-ExistingWorktrees) | Where-Object { $_.BranchName -eq 'wt/registered' }).Count | Should -Be 1
        } finally {
            Pop-Location
        }
    }
}
