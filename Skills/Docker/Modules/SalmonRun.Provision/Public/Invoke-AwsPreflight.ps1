<#
.SYNOPSIS
    Runs AWS pre-flight checks for fleet provisioning.
.DESCRIPTION
    Checks AWS session validity, IAM permissions, secret availability, coding key
    presence, and hydration readiness for all required bundle types.
.PARAMETER SsoProfile
    AWS SSO profile name for API calls.
.PARAMETER SecretsRegion
    AWS region for Secrets Manager operations.
.PARAMETER ProjectCode
    Project code for agent naming and secret paths.
.PARAMETER AgentRoles
    Array of agent role objects with Role and other properties.
.PARAMETER InstallOpencode
    Whether opencode containers should be deployed ("true"/"false").
.PARAMETER InstallBookkeeping
    Whether Bookkeeping container should be deployed ("true"/"false").
.PARAMETER InstallJsonPath
    Path to install.json for test status updates.
#>
function Invoke-AwsPreflight {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$SsoProfile,
        [Parameter(Mandatory)]
        [string]$SecretsRegion,
        [Parameter(Mandatory)]
        [string]$ProjectCode,
        [Parameter(Mandatory)]
        [array]$AgentRoles,
        [Parameter(Mandatory)]
        [string]$InstallOpencode,
        [Parameter(Mandatory)]
        [string]$InstallBookkeeping,
        [Parameter(Mandatory)]
        [string]$InstallJsonPath
    )

    Write-Information -MessageData "`n[PREFLIGHT] Checking AWS access and permissions..." -Tags "INFO"

    Test-AwsSessionValidity -SsoProfile $SsoProfile

    Test-AwsIamPermissions -SsoProfile $SsoProfile -SecretsRegion $SecretsRegion -ProjectCode $ProjectCode

    Test-SecretAvailability -ProjectCode $ProjectCode -SsoProfile $SsoProfile -SecretsRegion $SecretsRegion

    $hasCodingKeys = Test-CodingKeyPresence -ProjectCode $ProjectCode -SsoProfile $SsoProfile -SecretsRegion $SecretsRegion
    if (-not $hasCodingKeys -and $InstallOpencode -eq "true") {
        Write-SetupLog -Message "No coding keys in AWS SM - mcp_opencode containers will be disabled at deploy time." -Level WARN
    }

    # Hydration readiness: verify every bundle's required keys can be resolved
    Write-Information -MessageData "  [PREFLIGHT] Checking secret hydration readiness..." -Tags "INFO"
    $hydrationBundleTypes = @()
    foreach ($agentRole in $AgentRoles) {
        $roleCode = $agentRole.Role
        if ($roleCode -in @('BASE')) { $hydrationBundleTypes += $roleCode }
    }
    $hydrationBundleTypes += @('Fleet', 'Coding', 'Proxy', 'WebMcp')
    if ($InstallBookkeeping -eq "true") { $hydrationBundleTypes += 'Bookkeeper' }

    $hydrationResults = Test-HydrationReadiness -BundleTypes $hydrationBundleTypes -CheckAws -SsoProfile $SsoProfile -SecretsRegion $SecretsRegion -ProjectCode $ProjectCode
    $hydrationFailures = $hydrationResults | Where-Object { -not $_.Passed -and $_.Check -ne 'Overall' }
    if ($hydrationFailures.Count -gt 0) {
        Write-Information -MessageData "  [FAIL] $($hydrationFailures.Count) hydration check(s) failed:" -Tags "ERROR"
        $affectedContainers = [System.Collections.Generic.HashSet[string]]::new()
        $installJson = if (Test-Path $InstallJsonPath) { Get-Content $InstallJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
        foreach ($f in $hydrationFailures) {
            Write-Information -MessageData "    - $($f.Check): $($f.Detail)" -Tags "INFO"
            Write-SetupLog "Hydration pre-flight: $($f.Check) - $($f.Detail)" -Level ERROR
            $prefix = if ($f.Check -match '^(Feature):(.+)$') {
                $featKey = $matches[2]
                if ($installJson -and $installJson.features) {
                    $found = $null
                    foreach ($fn in $installJson.features.PSObject.Properties.Name) {
                        $fv = $installJson.features.$fn
                        if ($fv.secrets -and $fv.secrets.PSObject.Properties.Name -contains $featKey) { $found = $fn; break }
                    }
                    $found
                } else { $null }
            } else { $f.Check -replace ':.+$', '' }
            if ($prefix) { $null = $affectedContainers.Add($prefix) }
        }
        Write-SetupLog "Hydration pre-flight: $($hydrationFailures.Count) failures" -Level ERROR
        $containerStatus = @{}
        foreach ($c in $affectedContainers) { $containerStatus[$c] = 'failed' }
        try {
            Update-InstallJsonTestStatus -ContainerStatus $containerStatus -Path $InstallJsonPath
            Write-Information -MessageData "  [STATUS] Test status set to 'failed' in $InstallJsonPath for: $($affectedContainers -join ', ')" -Tags "WARN"
        } catch {
            Write-SetupLog "Could not update install.json testStatus: $_" -Level WARN
        }
        Write-Information -MessageData "  [ABORT] Secrets hydration pre-flight failed - setup cannot continue." -Tags "ERROR"
        Write-Information -MessageData "  Run 'Invoke-Pester Tests/HydrationIntegration.Tests.ps1 -Tag HydrationE2E' for detailed diagnostics." -Tags "INFO"
        throw "Secrets hydration failed - $($hydrationFailures.Count) check(s) failed for: $($affectedContainers -join ', ')"
    } else {
        $containerStatus = @{}
        foreach ($bt in $hydrationBundleTypes) { $containerStatus[$bt] = 'passed' }
        try {
            Update-InstallJsonTestStatus -ContainerStatus $containerStatus -Path $InstallJsonPath
        } catch {
            Write-SetupLog "Could not update install.json testStatus: $_" -Level WARN
        }
        Write-Information -MessageData "  [OK] All hydration checks passed." -Tags "INFO"
    }

    Write-Information -MessageData "  [OK] All pre-flight checks passed." -Tags "INFO"

    return $hasCodingKeys
}
