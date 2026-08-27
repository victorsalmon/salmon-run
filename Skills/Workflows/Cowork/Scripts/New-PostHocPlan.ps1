function New-PostHocPlan {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Date,
        [Parameter(Mandatory = $true)]
        [string]$Topic,
        [Parameter(Mandatory = $true)]
        [string]$Iteration,
        [Parameter(Mandatory = $true)]
        [string]$Scope,
        [Parameter(Mandatory = $true)]
        [string]$AgentId,
        [Parameter(Mandatory = $true)]
        [string[]]$CommitHashes,
        [Parameter(Mandatory = $true)]
        [string[]]$FilesModified,
        [Parameter(Mandatory = $true)]
        [hashtable[]]$Tasks,
        [Parameter(Mandatory = $false)]
        [string]$Connascence = "None",
        [Parameter(Mandatory = $false)]
        [string]$TestBaseline = "N/A — all new files",
        [Parameter(Mandatory = $false)]
        [string]$OutputPath,
        [Parameter(Mandatory = $false)]
        [switch]$DryRun
    )
    if (-not $Tasks -or $Tasks.Count -eq 0) { throw "At least one -Tasks entry required" }
    foreach ($t in $Tasks) {
        if (-not $t.Title -or -not $t.Why -or -not $t.Files -or -not $t.Changes -or -not $t.Acceptance -or -not $t.Verification) {
            throw "Each Task must have Title, Why, Files, Changes, Acceptance, Verification"
        }
    }

    $lines = @()
    $lines += "# Session Plan: $Date $Topic $Iteration — $Scope"
    $lines += ""
    # Post-hoc plans document already-completed work, so Status: ready is intentional (not subject to the proposal-default rule for interactive plans).
    $lines += "**Status**: ready"
    $lines += "**Date**: $Date"
    $lines += "**Connascence**: $Connascence"
    $lines += "**Test baseline**: $TestBaseline"
    $lines += "**Files**: $($FilesModified -join ', ')"
    $lines += ""
    $lines += "**Lock**"
    $lines += "- Agent: $AgentId"
    $lines += "- Locked: $([datetime]::UtcNow.ToString('o'))"
    $lines += "- Released: $([datetime]::UtcNow.ToString('o'))"
    $lines += "- Status: released"
    $lines += ""
    $lines += "---"
    $lines += "- Agent: reviewer-<pending>"
    $lines += "- Locked: <pending>"
    $lines += "- Already in HEAD: $($CommitHashes -join ', ')"
    $lines += ""
    $lines += "**Validation**"
    $lines += "- Tests: <pending — verify no regressions>"
    $lines += "- Files verified: <pending — inspect all modified files>"
    $lines += ""
    $lines += "---"
    $lines += ""

    for ($i = 0; $i -lt $Tasks.Count; $i++) {
        $t = $Tasks[$i]
        $num = $i + 1
        $lines += "## Task $num`: $($t.Title)"
        $lines += ""
        $lines += "**Why**: $($t.Why)"
        $lines += ""
        $lines += "**Files**: $($t.Files)"
        $lines += ""
        $lines += "**Changes**:"
        foreach ($c in $t.Changes) { $lines += "- $c" }
        $lines += ""
        $lines += "**Acceptance**: $($t.Acceptance)"
        $lines += ""
        $lines += "**Verification**: $($t.Verification)"
        $lines += ""
    }

    $output = $lines -join "`n"

    if ($DryRun) { Write-Host $output }
    else { Set-Content -LiteralPath $OutputPath -Value $output -NoNewline }
}
