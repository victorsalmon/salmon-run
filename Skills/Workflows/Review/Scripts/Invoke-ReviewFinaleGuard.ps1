<#
.SYNOPSIS
    Review-finale guard: verifies a reviewer lock-header prepend preserved the
    plan body, and rejects instant "review" runs (automated truncation suspects).
.DESCRIPTION
    Dot-source from the Review workflow Finale (workflow.md step 3) BEFORE the
    Move-Item. Exposes:

    - Test-ReviewPlanBodyIntact -Path <plan> : $true when the file still carries
      the plan body (# Session Plan: marker, length >= 200). On $false the caller
      must restore from git and abort the move — never let a truncated record
      reach Tasks/Complete/.
    - Test-InstantReviewDelta -Path <plan> : returns the Released-Locked delta in
      seconds, or $null when either stamp is missing. Deltas < 10s mean the
      "review" was automated truncation, not a real audit.
#>
if (-not (Get-Command Test-PlanHeaderContent -ErrorAction SilentlyContinue)) {
    function Test-PlanHeaderContent {
        param([AllowEmptyString()][string]$Content)
        if (-not $Content) { return $false }
        if ($Content -match '(?m)^\s*#\s+(?:Session\s+Plan|Session|Plan):\s+.+$') { return $true }
        if ($Content -match '(?m)^\s*#\s+Scheduled Task:\s+.+$' -and
            $Content -match '(?m)^\s*\*\*Type\*\*:\s*scheduled-task\b' -and
            $Content -match '(?m)^\s*\*\*Schedule ID\*\*:\s*\S+') { return $true }
        $plainTitle = $Content -match '(?m)^\s*#\s+[^#\r\n].+$'
        if (-not $plainTitle) { return $false }
        $metadataSignals = @(
            ($Content -match '(?m)^\s*\*\*Repo:?\*\*:?\s*.+$'),
            ($Content -match '(?m)^\s*\*\*Date:?\*\*:?\s*.+$'),
            ($Content -match '(?m)^\s*\*\*Origin:?\*\*:?\s*Plan-mode session\b'),
            ($Content -match '(?m)^\s*##\s+(?:Context|Overview|Task(?:s)?)\b')
        ) | Where-Object { $_ }
        return $metadataSignals.Count -ge 2
    }
}
function Test-ReviewPlanBodyIntact {
    param([Parameter(Mandatory)][string]$Path)
    $content = Get-Content $Path -Raw -ErrorAction SilentlyContinue
    if (-not $content) { return $false }
    return ($content.Length -ge 200 -and (Test-PlanHeaderContent -Content $content))
}

function Test-InstantReviewDelta {
    param([Parameter(Mandatory)][string]$Path)
    $lockedMatch = Select-String -Path $Path -Pattern '^- Locked:\s*(.+)$' -ErrorAction SilentlyContinue | Select-Object -First 1
    $releasedMatch = Select-String -Path $Path -Pattern '^- Released:\s*(.+)$' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $lockedMatch -or -not $releasedMatch) { return $null }
    try {
        $locked = [datetime]::Parse($lockedMatch.Matches.Groups[1].Value, [CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
        $released = [datetime]::Parse($releasedMatch.Matches.Groups[1].Value, [CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
        return ($released - $locked).TotalSeconds
    } catch {
        return $null
    }
}
