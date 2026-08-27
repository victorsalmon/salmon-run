param(
    [string]$ManifestPath = (Join-Path $PSScriptRoot "..\..\..\..\Skills\skills.json"),
    [string]$OutputPath = (Join-Path $PSScriptRoot "..\..\..\..\Skills\skills-index.json"),
    [switch]$WhatIf
)

if (-not (Test-Path $ManifestPath)) {
    Write-Error "Manifest not found: $ManifestPath"
    exit 1
}

$registry = Get-Content $ManifestPath -Raw | ConvertFrom-Json
$active = $registry | Where-Object { $_.stale -ne $true -and $_.type -ne 'archived' }

$index = [ordered]@{
    _meta = [ordered]@{
        version = 1
        updated = (Get-Date -Format "yyyy-MM-dd")
        description = "Lightweight skill discovery index. For full metadata (cross_refs, depends_on, last_verified) use skills.json."
        source = Resolve-Path $ManifestPath -Relative
        entries = $active.Count
    }
}

foreach ($s in ($active | Sort-Object Name)) {
    $entry = [ordered]@{ path = $s.path; type = $s.type }
    if ($s.container) { $entry.container = $s.container }
    if ($s.plugin) { $entry.plugin = $s.plugin }
    $index[$s.name] = $entry
}

$json = $index | ConvertTo-Json -Depth 3
$bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
$lineCount = ($json -split "`n").Length

if ($WhatIf) {
    "WHATIF: Would write $($active.Count) entries ($($bytes.Length) bytes, $lineCount lines) to $OutputPath"
    return
}

[System.IO.File]::WriteAllBytes($OutputPath, $bytes)
Write-Host "Wrote $($active.Count) entries ($($bytes.Length) bytes, $lineCount lines) to $OutputPath"
