function Resolve-OrchestratorRepoRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$StartPath,
        [string[]]$RequiredMarkers = @('Tasks', 'Orchestrator')
    )

    $candidate = if (Test-Path -LiteralPath $StartPath -PathType Leaf) {
        Split-Path -Parent (Resolve-Path -LiteralPath $StartPath).Path
    } else {
        (Resolve-Path -LiteralPath $StartPath).Path
    }

    while ($candidate) {
        $hasMarkers = $true
        foreach ($marker in $RequiredMarkers) {
            if (-not (Test-Path -LiteralPath (Join-Path $candidate $marker))) {
                $hasMarkers = $false
                break
            }
        }
        if ($hasMarkers) { return $candidate }

        $parent = Split-Path -Parent $candidate
        if (-not $parent -or $parent -eq $candidate) { break }
        $candidate = $parent
    }

    throw "Could not resolve an orchestrator repository root from '$StartPath'. Required markers: $($RequiredMarkers -join ', ')."
}
