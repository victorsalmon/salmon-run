#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

#Requires -Version 7.0

BeforeAll {
    $script:RepoRoot = (Resolve-Path "$PSScriptRoot\..\..\..").Path.TrimEnd('\')
    $script:ScriptPath = Join-Path $script:RepoRoot "Infrastructure/opencode/worktree-session.ps1"
    . $script:ScriptPath

    $script:BareRemote = "$TestDrive/bare-remote.git"
    git init --bare $script:BareRemote 2>&1 | Out-Null

    $script:TestRepo = "$TestDrive/testrepo"
    $null = New-Item -ItemType Directory -Path $script:TestRepo -Force
    git -C $script:TestRepo init 2>&1 | Out-Null
    git -C $script:TestRepo config user.name 'Devin' 2>&1 | Out-Null
    git -C $script:TestRepo config user.email 'devin@example.com' 2>&1 | Out-Null
    git -C $script:TestRepo remote add origin $script:BareRemote 2>&1 | Out-Null
    'init' | Out-File "$script:TestRepo/init.txt" -Encoding utf8 -NoNewline
    git -C $script:TestRepo add init.txt 2>&1 | Out-Null
    git -C $script:TestRepo commit -m 'init' 2>&1 | Out-Null
    git -C $script:TestRepo branch -M main 2>&1 | Out-Null
    git -C $script:TestRepo push -u origin main 2>&1 | Out-Null

    # Tracked files needed by Test-WorktreeHead
    $null = New-Item -ItemType Directory -Path "$script:TestRepo/Skills" -Force
    '' | Out-File "$script:TestRepo/Skills/.gitkeep" -Encoding utf8 -NoNewline
    '' | Out-File "$script:TestRepo/AGENTS.md" -Encoding utf8 -NoNewline
    '' | Out-File "$script:TestRepo/AGENTS-Code.md" -Encoding utf8 -NoNewline
    '{"name":"base"}' | Out-File "$script:TestRepo/opencode.json" -Encoding utf8 -NoNewline
    '{"mcp":{"servers":{}}}' | Out-File "$script:TestRepo/.opencode.json" -Encoding utf8 -NoNewline
    $null = New-Item -ItemType Directory -Path "$script:TestRepo/Infrastructure/opencode/config" -Force
    '{"mcp":{"servers":{"is_api":{"url":"http://is-api","headers":{}}}},"permissions":{"allowed":["*"]}}' | Out-File "$script:TestRepo/Infrastructure/opencode/config/opencode.json" -Encoding utf8 -NoNewline
    git -C $script:TestRepo add . 2>&1 | Out-Null
    git -C $script:TestRepo commit -m 'base files' 2>&1 | Out-Null
    git -C $script:TestRepo push origin main 2>&1 | Out-Null

    $env:OPENCODE_GO_KEY = 'key'
    $env:GITHUB_TOKEN = 'token'
}

AfterAll {
    if ($TestDrive -and (Test-Path $TestDrive)) {
        Get-ChildItem -Path $TestDrive -Recurse -File -ErrorAction SilentlyContinue | Set-ItemProperty -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
    }
}

Describe "Worktree session primitives" -Tag "Worktree", "Regression" {
    Context "New-SessionWorktree" {
        It "creates worktree at expected path with branch name" {
            Push-Location $script:TestRepo
            try {
                $result = New-SessionWorktree -SessionId 'new-session' -PlanSlug 'new-plan'
                $result.WorktreePath | Should -Be (Join-Path $script:TestRepo '.wt/new-session')
                $result.BranchName | Should -Be 'wt/code-multi/new-plan'
                Test-Path $result.WorktreePath | Should -Be $true
            } finally {
                Pop-Location
            }
        }

        It "returns existing worktree when branch already exists" {
            Push-Location $script:TestRepo
            try {
                $first = New-SessionWorktree -SessionId 'existing-session' -PlanSlug 'existing-plan'
                $second = New-SessionWorktree -SessionId 'existing-session' -PlanSlug 'existing-plan'
                $second.Source | Should -Be 'existing'
            } finally {
                Pop-Location
            }
        }
    }

    Context "Write-WorktreeMcpOverlay" {
        It "merges mcp block and injects bearer token" {
            $env:FLEET_API_TOKEN_WEB = 'token123'
            $wtPath = "$script:TestRepo/.wt/overlay-test"
            if (-not (Test-Path $wtPath)) { New-Item -ItemType Directory -Path $wtPath -Force | Out-Null }
            Copy-Item "$script:TestRepo/opencode.json" "$wtPath/opencode.json" -Force
            $null = New-Item -ItemType Directory -Path "$wtPath/Infrastructure/opencode/config" -Force
            Copy-Item "$script:TestRepo/Infrastructure/opencode/config/opencode.json" "$wtPath/Infrastructure/opencode/config/opencode.json" -Force

            Write-WorktreeMcpOverlay -WorktreePath $wtPath

            $overlay = Get-Content "$wtPath/.opencode.json" -Raw | ConvertFrom-Json -AsHashtable
            $overlay.mcp | Should -Not -BeNullOrEmpty
            $overlay.mcp.servers.is_api.headers.Authorization | Should -Be 'Bearer token123'
        }
    }

    Context "Test-WorktreeHead" {
        It "passes when all components present" {
            $wtPath = $script:TestRepo
            $result = Test-WorktreeHead -WorktreePath $wtPath
            $result.Pass | Should -Be $true
        }

        It "fails when Skills directory is missing" {
            $wtPath = "$TestDrive/no-skills"
            $null = New-Item -ItemType Directory -Path $wtPath -Force
            $result = Test-WorktreeHead -WorktreePath $wtPath
            $result.Pass | Should -Be $false
        }

        It "fails when OPENCODE_GO_KEY is unset" {
            $wtPath = "$TestDrive/no-key"
            $null = New-Item -ItemType Directory -Path "$wtPath/Skills" -Force
            $saved = $env:OPENCODE_GO_KEY
            $env:OPENCODE_GO_KEY = ''
            try {
                $result = Test-WorktreeHead -WorktreePath $wtPath
                ($result.Checks | Where-Object { $_.Name -eq 'OPENCODE_GO_KEY set' }).Pass | Should -Be $false
            } finally {
                $env:OPENCODE_GO_KEY = $saved
            }
        }

        It "fails when .opencode.json is missing" {
            $wtPath = "$TestDrive/no-overlay"
            $null = New-Item -ItemType Directory -Path "$wtPath/Skills" -Force
            $null = New-Item -ItemType File -Path "$wtPath/AGENTS.md" -Force
            $null = New-Item -ItemType File -Path "$wtPath/AGENTS-Code.md" -Force
            $result = Test-WorktreeHead -WorktreePath $wtPath
            ($result.Checks | Where-Object { $_.Name -eq '.opencode.json exists and valid' }).Pass | Should -Be $false
        }
    }

    Context "Remove-SessionWorktree" {
        It "removes worktree and branch" {
            Push-Location $script:TestRepo
            try {
                $wt = New-SessionWorktree -SessionId 'remove-me' -PlanSlug 'remove-plan'
                { Remove-SessionWorktree -SessionId 'remove-me' -Force } | Should -Not -Throw
                Test-Path $wt.WorktreePath | Should -Be $false
            } finally {
                Pop-Location
            }
        }
    }
}
