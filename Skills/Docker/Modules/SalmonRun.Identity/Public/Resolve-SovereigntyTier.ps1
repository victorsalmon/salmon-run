# ==============================================================================
# Public: Resolve-SovereigntyTier
# ==============================================================================
# Prompts for sovereignty tier (G/C/U), maps to full region/label/folder name,
# validates ORCHESTRATOR.json config files for each role/tier, and sets env vars.
#
# Extracted from 0setup.ps1:346-423
# ==============================================================================
<#
.SYNOPSIS
    Prompts for sovereignty tier, resolves region/label, validates per-role configs, and sets env vars.
.PARAMETER RoleArray
    Array of agent role strings (e.g. ORCH, VERI, BASE).
.PARAMETER AgentsRoot
    Root directory containing agent configuration subdirectories.
#>
function Resolve-SovereigntyTier {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string[]]$RoleArray,

        [Parameter(Mandatory)]
        [string]$AgentsRoot
    )

    Write-Information -MessageData "`n[SOVEREIGNTY] Select deployment sovereignty tier:"
    Write-Information -MessageData "  [G] Global (no restriction) — No regional lock; uses best-available providers"
    Write-Information -MessageData "  [C] Canada (ca-central-1)  — Strict Canadian data residency"
    Write-Information -MessageData "  [U] USA (us-east-1)        — Strict US data residency"

    $SovereigntyChoice = Get-ConfigValue "INTERCLAW_SOVEREIGNTY" "Sovereignty tier" "" -Aliases @("SOVEREIGNTY")
    if ([string]::IsNullOrWhiteSpace($SovereigntyChoice)) {
        $SovereigntyChoice = Read-Host "  Enter G, C, or U (Default: G)"
        if ([string]::IsNullOrWhiteSpace($SovereigntyChoice)) { $SovereigntyChoice = "G" }
    }

    $SovereigntyTier = $null
    $SovereigntyLabel = $null
    $SovereigntyRegion = $null

    switch ($SovereigntyChoice.Trim().ToUpper()) {
        "G"      { $SovereigntyTier = "global"; $SovereigntyLabel = "Global"; $SovereigntyRegion = "us-east-1" }
        "GLOBAL"  { $SovereigntyTier = "global"; $SovereigntyLabel = "Global"; $SovereigntyRegion = "us-east-1" }
        "C"      { $SovereigntyTier = "canada"; $SovereigntyLabel = "Canada (ca-central-1)"; $SovereigntyRegion = "ca-central-1" }
        "CANADA"  { $SovereigntyTier = "canada"; $SovereigntyLabel = "Canada (ca-central-1)"; $SovereigntyRegion = "ca-central-1" }
        "U"      { $SovereigntyTier = "usa"; $SovereigntyLabel = "USA (us-east-1)"; $SovereigntyRegion = "us-east-1" }
        "USA"     { $SovereigntyTier = "usa"; $SovereigntyLabel = "USA (us-east-1)"; $SovereigntyRegion = "us-east-1" }
        default {
            Write-Information -MessageData "  [FAIL] Invalid sovereignty choice: '$SovereigntyChoice'. Use G, C, or U. Aborting." -Tags "ERROR"
            Write-SetupLog "ABORT: Invalid sovereignty choice=$SovereigntyChoice" -Level ERROR
            throw "Invalid sovereignty choice: $SovereigntyChoice"
        }
    }

    $SecretsRegion = "ca-central-1"
    Set-Item -Path "Env:\INTERCLAW_SOVEREIGNTY" -Value $SovereigntyTier
    Set-Item -Path "Env:\AWS_REGION" -Value $SovereigntyRegion
    Set-Item -Path "Env:\AWS_SECRETS_REGION" -Value $SecretsRegion
    Write-Information -MessageData "  Sovereignty: $SovereigntyLabel" -Tags "INFO"
    Write-SetupLog "Sovereignty: tier=$SovereigntyTier region=$SovereigntyRegion secretsRegion=$SecretsRegion"

    $SovFolderMap = @{ "canada" = "Canada"; "usa" = "USA"; "global" = "Global" }
    $SovUpper = $SovFolderMap[$SovereigntyTier]
    if (-not $SovUpper) {
        Write-Information -MessageData "  [FAIL] Unknown sovereignty tier: '$SovereigntyTier'. Aborting." -Tags "ERROR"
        Write-SetupLog "ABORT: Unknown sovereignty tier=$SovereigntyTier" -Level ERROR
        throw "Unknown sovereignty tier: $SovereigntyTier"
    }

    foreach ($Role in $RoleArray) {
        $RoleUpper = $Role.ToUpper()
        $ConfigSrcDir = Join-Path $AgentsRoot $RoleUpper
        $ConfigSrcPath = Join-Path $ConfigSrcDir "$SovUpper" "ORCHESTRATOR.json"
        if (-not (Test-Path $ConfigSrcPath)) {
            Write-Warning "  [WARN] Sovereignty config not found for $RoleUpper/$SovUpper — using provider defaults from Infrastructure/ORCHESTRATOR/providers/"
            Write-SetupLog "Sovereignty config missing for $RoleUpper/$SovUpper — using provider defaults" -Level WARN
            continue
        }

        $AgentConfigRaw = Get-Content $ConfigSrcPath -Raw
        try {
            $AgentConfigObj = $AgentConfigRaw | ConvertFrom-Json
            if (Get-Command Test-InterclawConfigSchema -ErrorAction SilentlyContinue) {
                $Validation = Test-InterclawConfigSchema -Config $AgentConfigObj -ConfigType "Agent"
                if (-not $Validation.Valid) {
                    Write-Warning "  [WARN] Agent config schema errors for $RoleUpper / $SovUpper :"
                    foreach ($Err in $Validation.Errors) {
                        Write-Warning "    - $Err"
                    }
                    Write-SetupLog "Agent config schema invalid for $RoleUpper / $SovUpper : $($Validation.Errors -join '; ')" -Level WARN
                    continue
                }
                if ($Validation.Warnings.Count -gt 0) {
                    Write-Warning "  [WARN] Agent config warnings for $RoleUpper / $SovUpper :"
                    foreach ($Warn in $Validation.Warnings) {
                        Write-Warning "    - $Warn"
                    }
                    Write-SetupLog "Agent config warnings for $RoleUpper / $SovUpper : $($Validation.Warnings -join '; ')" -Level WARN
                }
            }
            Write-SetupLog "Sovereignty config validated for $RoleUpper / $SovUpper"
        }
        catch {
            Write-Warning "  [WARN] Could not parse agent config JSON for $RoleUpper / $SovUpper : $($_.Exception.Message)"
            Write-SetupLog "Sovereignty config JSON parse error for $RoleUpper / $SovUpper : $($_.Exception.Message)" -Level WARN
        }
    }
    Write-SetupLog "Sovereignty tier resolved: $SovereigntyTier"

    return [pscustomobject]@{
        Tier          = $SovereigntyTier
        Label         = $SovereigntyLabel
        Region        = $SovereigntyRegion
        SecretsRegion = $SecretsRegion
        SovUpper      = $SovUpper
    }
}

