<#
.SYNOPSIS
    Split repository Mermaid diagrams into chunk files.

.DESCRIPTION
    Convenience wrapper around Get-RepoMermaidChunks that writes the chunks to
    the configured Salmon Run runtime location (`~/.salmon/chunks` or
    `%SALMON_RUN_HOME%\chunks`) unless an explicit -OutputDir is provided.
#>
function Split-RepoMermaidChunks {
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory)]
        [string]$RepoDir,

        [string]$OutputDir = '',

        [string]$FilePattern = '*.md'
    )

    $ErrorActionPreference = 'Stop'

    if ([string]::IsNullOrWhiteSpace($OutputDir)) {
        $homeRoot = if ($env:SALMON_RUN_HOME) { $env:SALMON_RUN_HOME } else { Join-Path $env:USERPROFILE '.salmon' }
        $OutputDir = Join-Path $homeRoot 'chunks'
    }

    return Get-RepoMermaidChunks -RepoDir $RepoDir -OutputDir $OutputDir -FilePattern $FilePattern
}
