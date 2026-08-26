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

    $challenge = 'Daily'
    if ($content -match '(?im)^\*\*Challenge\*\*:\s*(?<value>[^\r\n]+)') {
        $challenge = $Matches['value'].Trim()
    } else {
        $tokenCount = $content.Split(@(' ', '`n', '`r'), [System.StringSplitOptions]::RemoveEmptyEntries).Count
        if ($tokenCount -gt 8000) { $challenge = 'Complex' }
        if ($tokenCount -gt 16000) { $challenge = 'Frontier' }
        if ($tokenCount -lt 2000) { $challenge = 'Flash' }
    }

    $timeout = if ($Context.Config -and $null -ne $Context.Config.TimeoutMinutes) { $Context.Config.TimeoutMinutes } else { 30 }
    $Context.Config = [PSCustomObject]@{
        TimeoutMinutes = $timeout
        Tier           = $challenge
        Model          = 'salmon-run-default'
        Effort         = 'standard'
        Provider       = 'opencode'
        Harness        = 'opencode'
    }

    Write-Verbose "Invoke-PondTaskModelRoute: group '$($group.Namespace)' routed to tier '$challenge'"
    return $Context
}
