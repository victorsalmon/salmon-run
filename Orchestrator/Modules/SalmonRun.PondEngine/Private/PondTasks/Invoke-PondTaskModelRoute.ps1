function Invoke-PondTaskModelRoute {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [Pond]$Pond,
        [Parameter(Mandatory)]
        [PondTask]$Task,
        [Parameter(Mandatory)]
        [PondContext]$Context
    )

    $group = $Context.CurrentGroup
    if (-not $group) { $Context.Continue = $false; return $Context }

    $lanePath = $group.StreamPath
    $files = @(Get-ChildItem "$lanePath/*.md" -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) { $Context.Continue = $false; return $Context }

    $first = $files | Sort-Object Name | Select-Object -First 1
    $content = Get-Content -LiteralPath $first.FullName -Raw

    # Determine the tier. Explicit Challenge header wins; otherwise fall back to
    # a token-count heuristic.
    $tier = 'Daily'
    if ($content -match '(?im)^\*\*Challenge\*\*:\s*(?<value>[^\r\n]+)') {
        $tier = $Matches['value'].Trim()
        if ($tier -notin @('Flash','Daily','Complex','Frontier','Local')) {
            Write-Verbose "Invoke-PondTaskModelRoute: unknown Challenge '$tier'; defaulting to Daily"
            $tier = 'Daily'
        }
    } else {
        $tokenCount = $content.Split(@(' ', '`n', '`r'), [System.StringSplitOptions]::RemoveEmptyEntries).Count
        if ($tokenCount -gt 16000) { $tier = 'Frontier' }
        elseif ($tokenCount -gt 8000) { $tier = 'Complex' }
        elseif ($tokenCount -lt 2000) { $tier = 'Flash' }
        else { $tier = 'Daily' }
    }

    $planPaths = $files | Select-Object -ExpandProperty FullName
    $profile = Resolve-PondExecutionProfile -Tier $tier -PlanFiles $planPaths

    # Preserve the timeout value set by Start-PondEngine.
    $timeout = if ($Context.Config -and $null -ne $Context.Config.TimeoutMinutes) { $Context.Config.TimeoutMinutes } else { 30 }
    $Context.Config = [PondExecutionProfile]$profile
    $Context.Config | Add-Member -NotePropertyName 'TimeoutMinutes' -NotePropertyValue $timeout -Force

    Write-Verbose "Invoke-PondTaskModelRoute: group '$($group.Namespace)' routed to tier '$tier' ($($profile.Harness)/$($profile.Provider)/$($profile.Model)/$($profile.Effort))"
    return $Context
}
