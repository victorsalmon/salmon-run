#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

#Requires -Version 7.0

BeforeAll {
    $RepoRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.FullName
    $EntrypointPath = Join-Path $RepoRoot "Infrastructure/opencode/entrypoint.sh"
    $GitignorePath = Join-Path $RepoRoot ".gitignore"
}

Describe "mcp_opencode entrypoint clone contract" -Tag "Entrypoint", "Regression" {
    It ".gitignore contains .wt/ entry" {
        $content = Get-Content $GitignorePath -Raw
        $content | Should -Match '\.wt/'
    }

    It ".gitignore contains .opencode.json entry" {
        $content = Get-Content $GitignorePath -Raw
        $content | Should -Match '\.opencode\.json'
    }

    It "entrypoint.sh contains a git clone reference" {
        $content = Get-Content $EntrypointPath -Raw
        $content | Should -Match 'git clone'
    }

    It "entrypoint.sh references /workspace/intersite-orchestrator as the Tasks bind mount" {
        $content = Get-Content $EntrypointPath -Raw
        $content | Should -Match '/workspace/intersite-orchestrator'
    }

    It "entrypoint.sh uses GITHUB_TOKEN or GITHUB_TOKEN_PUSHSELECT for auth" {
        $content = Get-Content $EntrypointPath -Raw
        $content | Should -Match 'GITHUB_TOKEN(_PUSHSELECT)?'
    }
}
