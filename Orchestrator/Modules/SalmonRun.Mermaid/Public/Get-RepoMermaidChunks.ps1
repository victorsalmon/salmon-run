<#
.SYNOPSIS
    Extract Mermaid diagrams from repository Markdown files into model-ingestible chunks.

.DESCRIPTION
    Scans a directory tree for `*.md` files, finds fenced `mermaid` code blocks,
    and returns a list of chunk objects with source, index, diagram type, title,
    and the raw diagram text. Optional `-OutputDir` will also write one `.md`
    chunk file per block.
#>
function Get-RepoMermaidChunks {
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory)]
        [string]$RepoDir,

        [string]$OutputDir = '',

        [string]$FilePattern = '*.md',

        [ValidateSet('mermaid','all')]
        [string]$ChunkType = 'mermaid'
    )

    $ErrorActionPreference = 'Stop'

    function Get-MermaidDiagramType {
        param([string]$diagram)
        if ([string]::IsNullOrWhiteSpace($diagram)) { return 'unknown' }
        $first = ($diagram -split "`r?`n")[0].Trim()
        if ($first -match '^\s*(graph|flowchart|sequenceDiagram|classDiagram|stateDiagram|erDiagram|gantt|pie|mindmap|timeline|gitgraph|requirementDiagram|c4c|journey)\b') {
            return $Matches[1].Trim()
        }
        return 'unknown'
    }

    function Get-ChunkTitle {
        param(
            [string]$diagram,
            [string]$source,
            [int]$index
        )
        $type = Get-MermaidDiagramType -diagram $diagram
        $base = [System.IO.Path]::GetFileNameWithoutExtension($source)
        return "$base-$type-$index"
    }

    $repoRoot = Resolve-Path -Path $RepoDir -ErrorAction Stop
    $files = Get-ChildItem -Path $repoRoot -File -Filter $FilePattern -Recurse

    $chunks = [System.Collections.Generic.List[PSCustomObject]]::new()

    $relative = {
        param([string]$full)
        $rel = $full.Substring($repoRoot.Path.Length).TrimStart('\', '/')
        return $rel
    }

    foreach ($file in $files) {
        $content = Get-Content -LiteralPath $file.FullName -Raw -Encoding utf8
        if ([string]::IsNullOrWhiteSpace($content)) { continue }

        $matches = [regex]::Matches($content, '```mermaid\s*\r?\n(.*?)\r?\n```', 'Singleline')
        $index = 0

        foreach ($m in $matches) {
            $diagram = $m.Groups[1].Value.Trim()
            $sourceRel = & $relative $file.FullName
            $type = Get-MermaidDiagramType -diagram $diagram
            $title = Get-ChunkTitle -diagram $diagram -source $sourceRel -index $index

            $chunk = [PSCustomObject]@{
                Source     = $sourceRel
                Index      = $index
                Title      = $title
                ChunkType  = 'mermaid'
                DiagramType = $type
                Body       = $diagram
            }

            $chunks.Add($chunk)

            if (-not [string]::IsNullOrWhiteSpace($OutputDir)) {
                $null = New-Item -ItemType Directory -Path $OutputDir -Force
                $outFile = Join-Path $OutputDir "$($title -replace '\s+','-').md"
                $frontMatter = @(
                    '---'
                    "source: $sourceRel"
                    "index: $index"
                    "chunk_type: mermaid"
                    "diagram_type: $type"
                    "title: $title"
                    '---'
                    ''
                    '```mermaid'
                    $diagram
                    '```'
                ) -join "`n"
                $frontMatter | Set-Content -LiteralPath $outFile -Encoding utf8 -NoNewline
            }

            $index++
        }
    }

    return $chunks.ToArray()
}
