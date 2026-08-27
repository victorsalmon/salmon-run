#Requires -Version 7.0
<#
.SYNOPSIS
    Project files from the canonical repo into the public salmon-run package.

.DESCRIPTION
    Copies canonical source and applies the public-package filter:
    - strips private hostnames, tokens, client paths, and absolute Windows paths
    - drops environment-only skills and scripts
    - keeps the canonical SalmonRun.* modules and public Skills
    - never copies the Tasks/ queue tree (runtime state lives in ~/.salmon)

    The canonical repo path can be supplied by parameter or environment
    variable (`SALMON_CANONICAL_REPO`). No hardcoded private path is required.

    Run after any canonical change, then run Invoke-LeakCheck.ps1.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$CanonicalRepo = $env:SALMON_CANONICAL_REPO,

    [string]$PublicRepo = '',

    [switch]$SkipLeakCheck
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($CanonicalRepo)) {
    throw "Canonical repo not found. Provide -CanonicalRepo or set SALMON_CANONICAL_REPO."
}

if ([string]::IsNullOrWhiteSpace($PublicRepo)) {
    $PublicRoot = $PSScriptRoot | Split-Path -Parent
} else {
    $PublicRoot = $PublicRepo
}

if (-not (Test-Path $CanonicalRepo -PathType Container)) {
    throw "Canonical repo not found at '$CanonicalRepo'"
}

$SourceDirs = @(
    @{ Src = 'Modules'; Pattern = 'SalmonRun.*' },
    @{ Src = 'Skills'; Pattern = '*' }
)

$privatePatterns = @(
    [regex]::Escape($env:USERPROFILE)
    'C:\\+Users\\+[^\\]+'
    'worktree\.ca/[^\s]+'
    'github\.com/[^\s]+'
    '(?i)\b(token|key|secret|password|api_key)\s*=\s*[^\s\r\n]+'
)

function Invoke-ScrubString {
    param([string]$content)
    if ([string]::IsNullOrWhiteSpace($content)) { return $content }
    foreach ($pattern in $privatePatterns) {
        if ([string]::IsNullOrWhiteSpace($pattern)) { continue }
        $content = $content -replace $pattern, '{{REDACTED}}'
    }
    return $content
}

function Invoke-CopyWithScrub {
    param(
        [string]$src,
        [string]$dst
    )
    if (-not (Test-Path -LiteralPath $dst)) {
        if ($PSCmdlet.ShouldProcess($dst, 'Create directory')) {
            $null = New-Item -ItemType Directory -Path $dst -Force
        }
    }
    Get-ChildItem -Path $src -File -Recurse | ForEach-Object {
        $rel = $_.FullName.Substring($src.Length).TrimStart('\', '/')
        $target = Join-Path $dst $rel
        $targetDir = Split-Path -Path $target -Parent
        if (-not (Test-Path -LiteralPath $targetDir) -and $PSCmdlet.ShouldProcess($targetDir, 'Create directory')) {
            $null = New-Item -ItemType Directory -Path $targetDir -Force
        }

        if ($_.Extension -in @('.ps1', '.psm1', '.psd1', '.json', '.md', '.yml', '.yaml', '.env', '.txt')) {
            $content = Get-Content -LiteralPath $_.FullName -Raw -Encoding utf8
            $scrubbed = Invoke-ScrubString -content $content
            if ($PSCmdlet.ShouldProcess($target, 'Write scrubbed file')) {
                $scrubbed | Set-Content -LiteralPath $target -Encoding utf8 -NoNewline
            }
        } elseif ($PSCmdlet.ShouldProcess($_.FullName, 'Copy to public package')) {
            Copy-Item -LiteralPath $_.FullName -Destination $target -Force
        }
    }
}

foreach ($entry in $SourceDirs) {
    $srcRoot = Join-Path $CanonicalRepo $entry.Src
    $dstRoot = Join-Path $PublicRoot $entry.Src
    if (-not (Test-Path $srcRoot)) { continue }

    Get-ChildItem -Path $srcRoot -Directory -Filter $entry.Pattern |
        ForEach-Object {
            $dst = Join-Path $dstRoot $_.Name
            if ($PSCmdlet.ShouldProcess($_.FullName, "Copy and scrub to '$dst'")) {
                Invoke-CopyWithScrub -src $_.FullName -dst $dst
            }
        }
}

Write-Host "Canonical projection complete. Run scripts/Invoke-LeakCheck.ps1 next." -ForegroundColor Green

if (-not $SkipLeakCheck) {
    $leakScript = Join-Path $PublicRoot 'scripts' 'Invoke-LeakCheck.ps1'
    if (Test-Path $leakScript) {
        if ($PSCmdlet.ShouldProcess($PublicRoot, 'Run leak check')) {
            & $leakScript
        }
    }
}
