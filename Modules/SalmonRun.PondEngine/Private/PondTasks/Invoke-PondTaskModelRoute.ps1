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

    # Printing normally supplies Challenge. Preserve the historical heuristic
    # only for legacy plans, then pass all resolution through the validated
    # field-by-field precedence resolver.
    if ($content -notmatch '(?im)^\*\*Challenge\*\*:') {
        $tokenCount = $content.Split(@(' ', '`n', '`r'), [System.StringSplitOptions]::RemoveEmptyEntries).Count
        $tier = if ($tokenCount -gt 16000) { 'Frontier' } elseif ($tokenCount -gt 8000) { 'Complex' } elseif ($tokenCount -lt 2000) { 'Flash' } else { 'Daily' }
        $content = "**Challenge**: $tier`n$content"
    }

    $planPaths = $files | Select-Object -ExpandProperty FullName
    $resolved = $null
    try { $runtimeConfig = Get-SalmonRunExecutionConfig -CurrentConfig $Context.Config }
    catch {
        $runtimeConfig = @{}
        $resolved = [pscustomobject]@{ DecisionRequired = $true; Error = $_.Exception.Message; Profile = $null }
    }
    if (-not $resolved) { $resolved = Resolve-PondExecutionProfileForPlan -Pond $Pond -Content $content -RuntimeConfig $runtimeConfig }

    $timeout = if ($Context.Config -and $null -ne $Context.Config.TimeoutMinutes) { $Context.Config.TimeoutMinutes } else { 30 }
    $namespaceMap = if ($Context.Config -and $Context.Config.PSObject.Properties['NamespaceRepoMap']) { $Context.Config.NamespaceRepoMap } else { @{} }
    if ($resolved.DecisionRequired) {
        foreach ($planPath in $planPaths) {
            Set-PondPlanHeader -Path $planPath -Name 'DecisionRequired' -Value 'yes'
            Set-PondPlanHeader -Path $planPath -Name 'DecisionReason' -Value $resolved.Error
        }
        $fallback = Resolve-PondExecutionProfile -Tier 'Daily'
        $Context.Config = [PondExecutionProfile]$fallback
        $Context.Config | Add-Member -NotePropertyName 'DecisionRequired' -NotePropertyValue $true -Force
        $Context.Config | Add-Member -NotePropertyName 'ValidationError' -NotePropertyValue $resolved.Error -Force
        $Context.Config | Add-Member -NotePropertyName 'NamespaceRepoMap' -NotePropertyValue $namespaceMap -Force
        $Context.Success = $false
        Write-Verbose "Invoke-PondTaskModelRoute: decision required for '$($group.Namespace)': $($resolved.Error)"
        return $Context
    }
    $srExecProfile = $resolved.Profile

    # Preserve orchestrator config that the tasks and Push-PondRepos need.
    $Context.Config = [PondExecutionProfile]$srExecProfile
    $Context.Config | Add-Member -NotePropertyName 'NamespaceRepoMap' -NotePropertyValue $namespaceMap -Force

    Write-Verbose "Invoke-PondTaskModelRoute: group '$($group.Namespace)' routed to tier '$($srExecProfile.Tier)' ($($srExecProfile.Harness)/$($srExecProfile.Provider)/$($srExecProfile.Model)/$($srExecProfile.Effort))"
    return $Context
}

