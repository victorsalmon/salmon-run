function New-FinalHandoff {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Topic,
        [Parameter(Mandatory = $true)]
        [string]$AgentId,
        [Parameter(Mandatory = $false)]
        [string]$Date = (Get-Date -Format 'yyyy-MM-dd'),
        [Parameter(Mandatory = $true)]
        [ValidateSet('context-capacity', 'milestone-complete', 'user-request')]
        [string]$Reason,
        [Parameter(Mandatory = $false)]
        [string[]]$MemoryFilesUpdated,
        [Parameter(Mandatory = $false)]
        [hashtable[]]$CompletedItems,
        [Parameter(Mandatory = $false)]
        [hashtable[]]$IncompleteItems,
        [Parameter(Mandatory = $false)]
        [hashtable[]]$WhatWorked,
        [Parameter(Mandatory = $false)]
        [hashtable[]]$WhatDidntWork,
        [Parameter(Mandatory = $false)]
        [hashtable[]]$SuggestedSkills,
        [Parameter(Mandatory = $false)]
        [hashtable]$KeyFiles,
        [Parameter(Mandatory = $false)]
        [string[]]$OrphanRefs,
        [Parameter(Mandatory = $false)]
        [hashtable]$Redirects,
        [Parameter(Mandatory = $false)]
        [hashtable[]]$GrepPatterns,
        [Parameter(Mandatory = $false)]
        [hashtable[]]$KeyDirectories,
        [Parameter(Mandatory = $false)]
        [hashtable[]]$ExternalLinks,
        [Parameter(Mandatory = $false)]
        [string]$OutputPath,
        [Parameter(Mandatory = $false)]
        [switch]$DryRun
    )
    if ((-not $CompletedItems -or $CompletedItems.Count -eq 0) -and (-not $IncompleteItems -or $IncompleteItems.Count -eq 0)) {
        throw "At least one of -CompletedItems or -IncompleteItems must be provided"
    }

    $lines = @()
    $lines += "---"
    $lines += "type: final-handoff"
    $lines += "Date: $Date"
    $lines += "Reason: $Reason"
    $lines += "---"
    $lines += ""
    $lines += "# Final Handoff: $Topic"
    $lines += ""

    if ($MemoryFilesUpdated -and $MemoryFilesUpdated.Count -gt 0) {
        $lines += "## Memory Files Written/Updated"
        $lines += ""
        foreach ($m in $MemoryFilesUpdated) { $lines += "- $m" }
        $lines += ""
    }

    if ($CompletedItems -and $CompletedItems.Count -gt 0) {
        $lines += "## Completed Items"
        $lines += ""
        $lines += "| Item | Verification | Evidence |"
        $lines += "|------|--------------|----------|"
        foreach ($item in $CompletedItems) {
            $lines += "| $($item.Item) | $($item.Verification) | $($item.Evidence) |"
        }
        $lines += ""
    }

    if ($IncompleteItems -and $IncompleteItems.Count -gt 0) {
        $lines += "## Incomplete Items"
        $lines += ""
        $lines += "| Item | Current State | What Remains | Blockers |"
        $lines += "|------|---------------|--------------|----------|"
        foreach ($item in $IncompleteItems) {
            $lines += "| $($item.Item) | $($item.CurrentState) | $($item.Remaining) | $($item.Blockers) |"
        }
        $lines += ""
    }

    if ($WhatWorked -and $WhatWorked.Count -gt 0) {
        $lines += "## Tools & Approaches — What Worked"
        $lines += ""
        foreach ($item in $WhatWorked) {
            $lines += "- $($item.Approach) → $($item.VerifiedBy)"
        }
        $lines += ""
    }

    if ($WhatDidntWork -and $WhatDidntWork.Count -gt 0) {
        $lines += "## Tools & Approaches — What Didn't Work"
        $lines += ""
        foreach ($item in $WhatDidntWork) {
            $lines += "- $($item.Approach) — $($item.Why)"
        }
        $lines += ""
    }

    if ($SuggestedSkills -and $SuggestedSkills.Count -gt 0) {
        $lines += "## Suggested Skills for Next Agent"
        $lines += ""
        foreach ($item in $SuggestedSkills) {
            $lines += "- **$($item.Name)**: $($item.Why)"
        }
        $lines += ""
    }

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

    if ($GrepPatterns -and $GrepPatterns.Count -gt 0) {
        $lines += "## Quick Reference"
        $lines += ""
        $lines += "### Grep Patterns"
        $lines += ""
        $lines += "| Pattern | Scope | Why |"
        $lines += "|---------|-------|-----|"
        foreach ($g in $GrepPatterns) {
            $lines += "| $($g.Pattern) | $($g.Scope) | $($g.Why) |"
        }
        $lines += ""

        if ($KeyDirectories) {
            $lines += "### Key Directories"
            $lines += ""
            $lines += "| Directory | Why |"
            $lines += "|-----------|-----|"
            foreach ($d in $KeyDirectories) {
                $lines += "| $($d.Path) | $($d.Why) |"
            }
            $lines += ""
        }

        if ($ExternalLinks) {
            $lines += "### External Links"
            $lines += ""
            $lines += "| URL | Purpose |"
            $lines += "|-----|---------|"
            foreach ($l in $ExternalLinks) {
                $lines += "| $($l.Url) | $($l.Purpose) |"
            }
            $lines += ""
        }
    }

    if ($Redirects -and $Redirects.Count -gt 0) {
        $lines += "## Redirects / Deprecations"
        $lines += ""
        $lines += "| Old Path | New Path |"
        $lines += "|----------|----------|"
        foreach ($old in $Redirects.Keys) {
            $lines += "| $old | $($Redirects[$old]) |"
        }
        $lines += ""
    }

    $output = $lines -join "`n"

    if ($DryRun) { Write-Host $output }
    else { Set-Content -LiteralPath $OutputPath -Value $output -NoNewline }
}
