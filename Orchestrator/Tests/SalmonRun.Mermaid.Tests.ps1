#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }

BeforeAll {
    $repoRoot = (Get-Item $PSCommandPath).Directory.Parent.FullName
    $modulePath = Join-Path $repoRoot 'Modules/SalmonRun.Mermaid'
    Import-Module -Name $modulePath -Force
}

Describe 'SalmonRun.Mermaid Module' {
    It 'exports Get-RepoMermaidChunks and Split-RepoMermaidChunks' {
        $module = Get-Module SalmonRun.Mermaid
        $module.ExportedFunctions.Keys | Should -Contain 'Get-RepoMermaidChunks'
        $module.ExportedFunctions.Keys | Should -Contain 'Split-RepoMermaidChunks'
    }
}

Describe 'Get-RepoMermaidChunks' {
    It 'extracts a single flowchart block' {
        $td = New-Item -ItemType Directory -Path (Join-Path $TestDrive "mermaid-$(Get-Random)") -Force
        $md = Join-Path $td 'README.md'
        @'
# README

```mermaid
flowchart LR
    A --> B
```
'@ | Set-Content -LiteralPath $md -Encoding utf8

        $chunks = Get-RepoMermaidChunks -RepoDir $td

        $chunks | Should -HaveCount 1
        $chunks[0].Source | Should -Be 'README.md'
        $chunks[0].ChunkType | Should -Be 'mermaid'
        $chunks[0].DiagramType | Should -Be 'flowchart'
        $chunks[0].Title | Should -Match 'flowchart-0'
    }

    It 'extracts multiple diagram types' {
        $td = New-Item -ItemType Directory -Path (Join-Path $TestDrive "mermaid-multi-$(Get-Random)") -Force
        $md = Join-Path $td 'docs.md'
        @'
```mermaid
sequenceDiagram
    A->>B: hello
```

```mermaid
classDiagram
    A : +String name
```
'@ | Set-Content -LiteralPath $md -Encoding utf8

        $chunks = Get-RepoMermaidChunks -RepoDir $td

        $chunks | Should -HaveCount 2
        $chunks[0].DiagramType | Should -Be 'sequenceDiagram'
        $chunks[1].DiagramType | Should -Be 'classDiagram'
    }

    It 'returns empty when no mermaid blocks exist' {
        $td = New-Item -ItemType Directory -Path (Join-Path $TestDrive "mermaid-empty-$(Get-Random)") -Force
        $md = Join-Path $td 'plain.md'
        '# No diagrams here' | Set-Content -LiteralPath $md -Encoding utf8

        $chunks = Get-RepoMermaidChunks -RepoDir $td

        $chunks | Should -HaveCount 0
    }

    It 'writes chunk files when OutputDir is supplied' {
        $td = New-Item -ItemType Directory -Path (Join-Path $TestDrive "mermaid-out-$(Get-Random)") -Force
        $out = Join-Path $TestDrive 'mermaid-chunks'
        $md = Join-Path $td 'README.md'
        @'
```mermaid
graph TD
    Start --> Stop
```
'@ | Set-Content -LiteralPath $md -Encoding utf8

        $chunks = Get-RepoMermaidChunks -RepoDir $td -OutputDir $out

        $chunks | Should -HaveCount 1
        $files = Get-ChildItem -Path $out -Filter '*.md'
        $files | Should -HaveCount 1
        $content = Get-Content -LiteralPath $files[0].FullName -Raw
        $content | Should -Match '---'
        $content | Should -Match 'chunk_type: mermaid'
        $content | Should -Match 'graph TD'
    }
}

Describe 'Split-RepoMermaidChunks' {
    It 'uses the default Salmon Run chunks directory' {
        $td = New-Item -ItemType Directory -Path (Join-Path $TestDrive "mermaid-split-$(Get-Random)") -Force
        $md = Join-Path $td 'README.md'
        @'
```mermaid
graph TD
    A --> B
```
'@ | Set-Content -LiteralPath $md -Encoding utf8

        $salmonHome = Join-Path $TestDrive 'split-home'
        $savedHome = $env:SALMON_RUN_HOME
        try {
            $env:SALMON_RUN_HOME = $salmonHome
            $chunks = Split-RepoMermaidChunks -RepoDir $td
            $chunks | Should -HaveCount 1
            Join-Path $salmonHome 'chunks' | Should -Exist
        } finally {
            $env:SALMON_RUN_HOME = $savedHome
        }
    }
}
