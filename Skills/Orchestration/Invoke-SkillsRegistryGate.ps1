# Invoke-SkillsRegistryGate.ps1
# Verifies every Skills/skills.json path/cross_refs/depends_on/superseded_by/persona_anchor/shared_refs
# entry resolves. `path`, `superseded_by`, `persona_anchor`, `cross_refs`, and `shared_refs` must point to
# files on disk. `depends_on` may be either a filesystem path or a skill name (matched against the
# `name` field of another registry entry). Fails loudly when registry has broken references.
#
# Exit codes:
#   0 - clean (all references resolve)
#   1 - broken refs (with failure list)
#   2 - schema parse error (registry JSON invalid)
#   3 - registry file missing
[CmdletBinding()]
param(
    [string]$RegistryPath = 'Skills/skills.json',
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $RegistryPath)) {
    Write-Error "Registry file not found: $RegistryPath"
    exit 3
}

try {
    $registry = Get-Content -LiteralPath $RegistryPath -Raw | ConvertFrom-Json
} catch {
    Write-Error "Schema parse error reading $RegistryPath - $($_.Exception.Message)"
    exit 2
}

if ($null -eq $registry) {
    Write-Error "Registry parsed to null - corrupt JSON"
    exit 2
}

$failures = New-Object System.Collections.Generic.List[string]

# Build a lookup of valid skill names for depends_on resolution
$skillNames = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
foreach ($entry in $registry) {
    if ($entry.name) { [void]$skillNames.Add($entry.name) }
}

foreach ($entry in $registry) {
    $name = if ($entry.name) { $entry.name } else { '<unnamed>' }

    if ($entry.path) {
        if (-not (Test-Path -LiteralPath $entry.path)) {
            $failures.Add("$name`: path '$($entry.path)' missing")
        }
    }

    if ($entry.superseded_by) {
        $resolvedAsPath = Test-Path -LiteralPath $entry.superseded_by
        $resolvedAsName = $skillNames.Contains($entry.superseded_by)
        if (-not ($resolvedAsPath -or $resolvedAsName)) {
            $failures.Add("$name`: superseded_by '$($entry.superseded_by)' missing (not a path or registered skill name)")
        }
    }

    if ($entry.persona_anchor) {
        if (-not (Test-Path -LiteralPath $entry.persona_anchor)) {
            $failures.Add("$name`: persona_anchor '$($entry.persona_anchor)' missing")
        }
    }

    foreach ($ref in @($entry.cross_refs) + @($entry.shared_refs)) {
        if ($ref -and -not (Test-Path -LiteralPath $ref)) {
            $failures.Add("$name`: ref '$ref' missing")
        }
    }

    foreach ($dep in @($entry.depends_on)) {
        if (-not $dep) { continue }
        $resolvedAsPath = Test-Path -LiteralPath $dep
        $resolvedAsName = $skillNames.Contains($dep)
        if (-not ($resolvedAsPath -or $resolvedAsName)) {
            $failures.Add("$name`: depends_on '$dep' missing (not a path or registered skill name)")
        }
    }
}

if ($failures.Count -gt 0) {
    if (-not $Quiet) {
        Write-Host "Skills registry gate: $($failures.Count) failure(s) found" -ForegroundColor Red
        $failures | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    }
    exit 1
}

if (-not $Quiet) {
    Write-Host "Skills registry gate: clean ($($registry.Count) entries verified)"
}
exit 0
