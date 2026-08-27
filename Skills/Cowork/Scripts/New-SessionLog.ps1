function New-SessionLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Topic,
        [Parameter(Mandatory = $true)]
        [string]$AgentId,
        [Parameter(Mandatory = $false)]
        [string]$Date = (Get-Date -Format 'yyyy-MM-dd'),
        [Parameter(Mandatory = $true)]
        [hashtable[]]$Phases,
        [Parameter(Mandatory = $false)]
        [hashtable[]]$WhatWorked,
        [Parameter(Mandatory = $false)]
        [hashtable[]]$WhatDidntWork,
        [Parameter(Mandatory = $false)]
        [hashtable[]]$SkillsUsed,
        [Parameter(Mandatory = $false)]
        [string]$Pattern,
        [Parameter(Mandatory = $false)]
        [string[]]$UtilityScriptsCreated,
        [Parameter(Mandatory = $false)]
        [hashtable]$ApiFootprint,
        [Parameter(Mandatory = $false)]
        [string]$OutputPath,
        [Parameter(Mandatory = $false)]
        [switch]$DryRun
    )
    if (-not $Phases -or $Phases.Count -eq 0) { throw "At least one -Phases entry required" }

    $lines = @()
    $lines += "# Session Log: $Topic"
    $lines += ""
    $lines += "## Session Context"
    $lines += ""
    $lines += "- **Topic**: $Topic"
    $lines += "- **Date**: $Date"
    $lines += "- **Agent**: $AgentId"
    $lines += ""

    foreach ($phase in $Phases) {
        $lines += "## Phase $($phase.Number) — $($phase.Title) (Hours: $($phase.Hours))"
        $lines += ""
        foreach ($a in $phase.Accomplished) { $lines += "- $a" }
        $lines += ""
    }

    if ($WhatWorked -and $WhatWorked.Count -gt 0) {
        $lines += "## What Worked"
        $lines += ""
        foreach ($item in $WhatWorked) {
            $lines += "- $($item.Approach) (verified by: $($item.VerifiedBy))"
        }
        $lines += ""
    }

    if ($WhatDidntWork -and $WhatDidntWork.Count -gt 0) {
        $lines += "## What Didn't Work"
        $lines += ""
        foreach ($item in $WhatDidntWork) {
            $lines += "- $($item.Approach) — $($item.Why)"
        }
        $lines += ""
    }

    if ($SkillsUsed -and $SkillsUsed.Count -gt 0) {
        $lines += "## Skills Used"
        $lines += ""
        $lines += "| Name | Adequacy |"
        $lines += "|------|----------|"
        foreach ($item in $SkillsUsed) {
            $lines += "| $($item.Name) | $($item.Adequacy) |"
        }
        $lines += ""
    }

    if ($Pattern) {
        $lines += "## Working Pattern"
        $lines += ""
        $lines += $Pattern
        $lines += ""
    }

    if ($UtilityScriptsCreated -and $UtilityScriptsCreated.Count -gt 0) {
        $lines += "## Utility Scripts Created"
        $lines += ""
        foreach ($s in $UtilityScriptsCreated) { $lines += "- $s" }
        $lines += ""
    }

    if ($ApiFootprint -and $ApiFootprint.Count -gt 0) {
        $lines += "## API Footprint"
        $lines += ""
        $lines += "| Metric | Value |"
        $lines += "|--------|-------|"
        foreach ($key in $ApiFootprint.Keys) {
            $lines += "| $key | $($ApiFootprint[$key]) |"
        }
        $lines += ""
    }

    $output = $lines -join "`n"

    if ($DryRun) { Write-Host $output }
    else { Set-Content -LiteralPath $OutputPath -Value $output -NoNewline }
}
