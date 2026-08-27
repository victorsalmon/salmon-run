function New-CoworkStub {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Topic,
        [Parameter(Mandatory = $true)]
        [string]$AgentId,
        [Parameter(Mandatory = $false)]
        [string]$Date = (Get-Date -Format 'yyyy-MM-dd'),
        [Parameter(Mandatory = $true)]
        [ValidateSet('released', 'stalled')]
        [string]$Status,
        [Parameter(Mandatory = $true)]
        [string]$CurrentState,
        [Parameter(Mandatory = $false)]
        [string]$MemoryReference,
        [Parameter(Mandatory = $true)]
        [string[]]$WhatWorked,
        [Parameter(Mandatory = $true)]
        [string[]]$WhatDidntWork,
        [Parameter(Mandatory = $false)]
        [string[]]$SkillsUsed,
        [Parameter(Mandatory = $true)]
        [string[]]$NextActions,
        [Parameter(Mandatory = $false)]
        [hashtable]$KeyFiles,
        [Parameter(Mandatory = $false)]
        [string[]]$OrphanRefs,
        [Parameter(Mandatory = $false)]
        [string]$OutputPath,
        [Parameter(Mandatory = $false)]
        [switch]$DryRun
    )
    if ($WhatWorked.Count -eq 0) { throw "-WhatWorked must have at least one item" }
    if ($WhatDidntWork.Count -eq 0) { throw "-WhatDidntWork must have at least one item" }
    if ($CurrentState.Length -lt 20) { throw "-CurrentState must be at least 20 characters" }

    $lines = @()
    $lines += "---"
    $lines += "type: cowork-stub"
    $lines += "Date: $Date"
    $lines += "Status: $Status"
    $lines += "---"
    $lines += ""
    $lines += "# Cowork Stub: $Topic"
    $lines += ""

    $lines += "## Current State"
    $lines += ""
    $lines += $CurrentState
    $lines += ""

    if ($MemoryReference) {
        $lines += "## Memory Reference"
        $lines += ""
        $lines += "- $MemoryReference"
        $lines += ""
    }

    $lines += "## What Worked"
    $lines += ""
    foreach ($item in $WhatWorked) { $lines += "- $item" }
    $lines += ""

    $lines += "## What Didn't Work"
    $lines += ""
    foreach ($item in $WhatDidntWork) { $lines += "- $item" }
    $lines += ""

    if ($SkillsUsed -and $SkillsUsed.Count -gt 0) {
        $lines += "## Skills Used"
        $lines += ""
        foreach ($s in $SkillsUsed) { $lines += "- $s" }
        $lines += ""
    }

    $lines += "## What Next Agent Needs"
    $lines += ""
    for ($i = 0; $i -lt $NextActions.Count; $i++) {
        $lines += "$($i + 1). $($NextActions[$i])"
    }
    $lines += ""

    if ($KeyFiles -and $KeyFiles.Count -gt 0) {
        $lines += "## Key Files"
        $lines += ""
        $lines += "| File | Path | Purpose |"
        $lines += "|------|------|---------|"
        foreach ($key in $KeyFiles.Keys) {
            $entry = $KeyFiles[$key]
            $lines += "| $key | $($entry.Path) | $($entry.Purpose) |"
        }
        $lines += ""
    }

    if ($OrphanRefs -and $OrphanRefs.Count -gt 0) {
        $lines += "> **Orphan notes**:"
        foreach ($ref in $OrphanRefs) { $lines += "> - $ref" }
        $lines += ""
    }

    $output = $lines -join "`n"

    if ($DryRun) { Write-Host $output }
    else { Set-Content -LiteralPath $OutputPath -Value $output -NoNewline }
}
