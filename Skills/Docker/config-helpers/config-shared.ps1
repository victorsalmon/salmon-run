function Should-ConfigureFeature {
    param([string]$FeatureName)
    $feature = $script:InstallJson.features.$FeatureName
    if (-not $feature) { return $true }
    if (-not $feature.install) {
        Write-Host "  [SKIP] $FeatureName not configured (install: false)" -ForegroundColor Gray
        Write-SetupLog "$FeatureName skipped (install: false)"
        return $false
    }
    return $true
}

function Invoke-LocalPhase {
    param([string]$Phase, [scriptblock]$ScriptBlock, [switch]$Recoverable)
    if ($WhatIfPreference) {
        Write-Host "  [WHATIF] Would execute phase '$Phase'" -ForegroundColor Magenta
        return
    }
    $params = @{ Phase = $Phase; ScriptBlock = $ScriptBlock }
    if ($Recoverable) { $params.Recoverable = $true }
    SalmonRun.DeployState\Invoke-DeployStatePhase @params
}
