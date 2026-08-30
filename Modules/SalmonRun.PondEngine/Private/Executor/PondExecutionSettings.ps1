function Get-PondSettingValue {
    [CmdletBinding()]
    param([object]$Object, [Parameter(Mandatory)][string]$Name)

    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($key in $Object.Keys) {
            if ([string]$key -ieq $Name) { return $Object[$key] }
        }
        return $null
    }
    $property = $Object.PSObject.Properties | Where-Object Name -IEQ $Name | Select-Object -First 1
    if ($property) { return $property.Value }
    return $null
}

function Get-PondPlanOverrides {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Content)

    $result = [ordered]@{ Values = @{}; Confirmed = $false; Error = $null }
    if ($Content -match '(?im)^\*\*Overrides confirmation\*\*:\s*confirmed by user\s*$') {
        $result.Confirmed = $true
    }
    $match = [regex]::Match($Content, '(?im)^\*\*Overrides\*\*:\s*(?<value>[^\r\n]+)')
    if (-not $match.Success) { return [pscustomobject]$result }

    $allowed = @('Challenge','Harness','Provider','Model','Effort','TimeoutMinutes','CostCeiling')
    foreach ($entry in $match.Groups['value'].Value.Split(',')) {
        if ($entry.Trim() -notmatch '^(?<pond>[A-Za-z][A-Za-z0-9-]*)\.(?<field>[A-Za-z]+)\s*=\s*(?<value>.+)$') {
            $result.Error = "Invalid plan override '$($entry.Trim())'. Expected Pond.Field=value."
            break
        }
        $field = $Matches.field
        if ($field -notin $allowed) {
            $result.Error = "Invalid plan override field '$field'. Allowed fields: $($allowed -join ', ')."
            break
        }
        $result.Values["$($Matches.pond).$field"] = $Matches.value.Trim()
    }
    return [pscustomobject]$result
}

function Resolve-PondExecutionProfileForPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Pond]$Pond,
        [Parameter(Mandatory)][string]$Content,
        [object]$RuntimeConfig = @{}
    )

    $overrides = Get-PondPlanOverrides -Content $Content
    if ($overrides.Error) {
        return [pscustomobject]@{ DecisionRequired = $true; Error = $overrides.Error; Profile = $null }
    }
    if ($overrides.Values.Count -gt 0 -and -not $overrides.Confirmed) {
        return [pscustomobject]@{ DecisionRequired = $true; Error = 'Plan overrides must be confirmed by the user.'; Profile = $null }
    }

    $execution = Get-PondSettingValue -Object $RuntimeConfig -Name 'execution'
    $global = Get-PondSettingValue -Object $execution -Name 'defaults'
    $ponds = Get-PondSettingValue -Object $execution -Name 'ponds'
    $pondConfig = Get-PondSettingValue -Object $ponds -Name $Pond.Name

    $values = [ordered]@{
        Challenge = $Pond.Execution.Challenge
        Harness = $Pond.Execution.Harness
        Provider = $Pond.Execution.Provider
        Model = $Pond.Execution.Model
        Effort = $Pond.Execution.Effort
        TimeoutMinutes = $Pond.Execution.TimeoutMinutes
        CostCeiling = $Pond.Execution.CostCeiling
    }
    foreach ($source in @($global, $pondConfig)) {
        if ($null -eq $source) { continue }
        foreach ($field in @($values.Keys)) {
            $candidate = Get-PondSettingValue -Object $source -Name $field
            if ($null -ne $candidate -and -not [string]::IsNullOrWhiteSpace([string]$candidate)) {
                $values[$field] = $candidate
            }
        }
    }

    if ($Content -match '(?im)^\*\*Challenge\*\*:\s*(?<value>[^\r\n]+)') {
        $values.Challenge = $Matches.value.Trim()
    }
    foreach ($field in @($values.Keys)) {
        $key = "$($Pond.Name).$field"
        if ($overrides.Values.ContainsKey($key)) { $values[$field] = $overrides.Values[$key] }
    }

    if ([string]::IsNullOrWhiteSpace([string]$values.Challenge)) { $values.Challenge = 'Daily' }
    if ($values.Challenge -notin @('Flash','Daily','Complex','Frontier','Local')) {
        return [pscustomobject]@{ DecisionRequired = $true; Error = "Invalid Challenge '$($values.Challenge)' for pond '$($Pond.Name)'."; Profile = $null }
    }

    [int]$timeout = 0
    [double]$ceiling = 0.0
    if (-not [int]::TryParse([string]$values.TimeoutMinutes, [ref]$timeout) -or $timeout -le 0) {
        return [pscustomobject]@{ DecisionRequired = $true; Error = "TimeoutMinutes for pond '$($Pond.Name)' must be a positive integer."; Profile = $null }
    }
    if (-not [double]::TryParse([string]$values.CostCeiling, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$ceiling) -or $ceiling -lt 0) {
        return [pscustomobject]@{ DecisionRequired = $true; Error = "CostCeiling for pond '$($Pond.Name)' must be zero or greater."; Profile = $null }
    }

    try {
        $params = @{ Tier = $values.Challenge; TimeoutMinutes = $timeout; CostCeiling = $ceiling }
        foreach ($field in @('Harness','Provider','Model','Effort')) {
            if (-not [string]::IsNullOrWhiteSpace([string]$values[$field])) { $params[$field] = [string]$values[$field] }
        }
        $profile = Resolve-PondExecutionProfile @params
    } catch {
        return [pscustomobject]@{ DecisionRequired = $true; Error = $_.Exception.Message; Profile = $null }
    }

    if ($ceiling -gt 0 -and $profile.CostWithThinking -gt $ceiling) {
        return [pscustomobject]@{
            DecisionRequired = $true
            Error = "Resolved model cost $($profile.CostWithThinking) exceeds the configured cost ceiling $ceiling for pond '$($Pond.Name)'."
            Profile = $null
        }
    }
    return [pscustomobject]@{ DecisionRequired = $false; Error = $null; Profile = $profile }
}

function Get-SalmonRunExecutionConfig {
    [CmdletBinding()]
    param([object]$CurrentConfig)

    if ($CurrentConfig -and (Get-PondSettingValue -Object $CurrentConfig -Name 'execution')) { return $CurrentConfig }
    $homePath = if ($env:SALMON_RUN_HOME) { $env:SALMON_RUN_HOME } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.salmon' }
    $path = Join-Path $homePath 'config.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @{} }
    try { return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable -Depth 20 -ErrorAction Stop }
    catch { throw "Invalid Salmon Run execution config '$path': $($_.Exception.Message)" }
}
