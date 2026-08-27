<#
.SYNOPSIS
    Reads .compliance-audit.yml (schema per compliance-audit.md, section
    "Config file contract") into a validated object. The single reader of the
    config; every consumer (slash command, Phase A skip logic) relies on its
    output shape.

.DESCRIPTION
    Hand-rolled line/regex parser - no YAML module dependency. The schema is
    fixed and flat:

        version: 1
        target_repo: <leaf name>
        region_required: <region>          (default ca-central-1)
        standards:
          canadian_data_sovereignty:
            status: required               (allowed: required | not_applicable)
            rationale: <string>
          pipeda: ...
          soc2: ...
          iso_27001: ...
          hipaa: ...
          gdpr: ...
        run_native_engine: <bool>          (default true)
        last_confirmed: <ISO date>
        reconfirm_after_days: <int>        (default 365)

    Validation (throws with a clear message; NEVER returns a partial object):
      - version must be present and equal 1
      - standards map is required; unknown standard keys are ignored
      - each standard's status must be required or not_applicable
      - a standard marked not_applicable MUST carry a non-empty rationale
      - unknown top-level keys are ignored (forward compatibility)
      - a missing standard key defaults to required with an empty rationale

.PARAMETER Path
    Path to the config file. Relative paths resolve against the current
    working directory; absolute paths are used as-is.

.PARAMETER AsHashtable
    Return a hashtable instead of a PSCustomObject for consumers that prefer
    hashtables.

.EXAMPLE
    $cfg = .\ConvertFrom-ComplianceConfig.ps1 -Path .compliance-audit.yml
    $cfg.standards.hipaa.status      # -> not_applicable
    $cfg.regionRequired              # -> ca-central-1
.NOTES
    This file implements the canonical schema in compliance-audit.md exactly -
    field names and allowed status values are the contract.
#>

[CmdletBinding()]
param(
    [string]$Path = ".compliance-audit.yml",
    [switch]$AsHashtable
)

$ErrorActionPreference = "Stop"

$knownStandards = @('canadian_data_sovereignty', 'pipeda', 'soc2', 'iso_27001', 'hipaa', 'gdpr')
$allowedStatus = @('required', 'not_applicable')

function Remove-InlineComment {
    param([string]$Value)
    if ($Value -match '^([^#]+?)\s*#') { return $matches[1].TrimEnd() }
    return $Value
}

function Unquote-Value {
    param([string]$Value)
    $v = (Remove-InlineComment -Value $Value).Trim()
    if ($v.Length -ge 2 -and (($v.StartsWith('"') -and $v.EndsWith('"')) -or ($v.StartsWith("'") -and $v.EndsWith("'")))) {
        return $v.Substring(1, $v.Length - 2)
    }
    return $v
}

$resolvedPath = if ([System.IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path (Get-Location) $Path }
if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
    throw ".compliance-audit.yml: file not found at '$resolvedPath'"
}

$top = @{}
$standards = @{}
$inStandards = $false
$currentStandard = $null

foreach ($rawLine in Get-Content -LiteralPath $resolvedPath) {
    $line = $rawLine.TrimEnd()
    if ([string]::IsNullOrWhiteSpace($line) -or $line -match '^\s*#') { continue }

    if ($line -match '^standards:\s*$') {
        $inStandards = $true
        continue
    }

    if ($inStandards) {
        if ($line -match '^  ([A-Za-z0-9_]+):\s*(.*)$') {
            $currentStandard = $matches[1]
            $inlineVal = Unquote-Value -Value $matches[2]
            if ($inlineVal) {
                $standards[$currentStandard] = @{ status = $inlineVal; rationale = '' }
            } else {
                if (-not $standards.ContainsKey($currentStandard)) {
                    $standards[$currentStandard] = @{ status = ''; rationale = '' }
                }
            }
            continue
        }
        if ($currentStandard -and $line -match '^    ([A-Za-z0-9_]+):\s*(.*)$') {
            $prop = $matches[1]
            $val = Unquote-Value -Value $matches[2]
            if (-not $standards.ContainsKey($currentStandard)) {
                $standards[$currentStandard] = @{ status = ''; rationale = '' }
            }
            $standards[$currentStandard][$prop] = $val
            continue
        }
        if ($line -match '^\S') {
            $inStandards = $false
        }
    }

    if (-not $inStandards -and $line -match '^([A-Za-z0-9_]+):\s*(.*)$') {
        $top[$matches[1]] = Unquote-Value -Value $matches[2]
    }
}
# ---- Validation: version ----
if (-not $top.ContainsKey('version')) {
    throw ".compliance-audit.yml: missing required field 'version'"
}
$versionInt = 0
if (-not [int]::TryParse($top['version'], [ref]$versionInt)) {
    throw ".compliance-audit.yml: invalid version '$($top['version'])' (expected integer 1)"
}
if ($versionInt -ne 1) {
    throw ".compliance-audit.yml: unsupported version '$($top['version'])' (expected 1)"
}

# ---- Validation: standards map ----
if ($standards.Count -eq 0) {
    throw ".compliance-audit.yml: missing required 'standards' map"
}
foreach ($key in @($standards.Keys)) {
    if ($knownStandards -notcontains $key) { continue }
    $status = $standards[$key]['status']
    if ($allowedStatus -notcontains $status) {
        throw ".compliance-audit.yml: invalid status '$status' for $key"
    }
    if ($status -eq 'not_applicable' -and [string]::IsNullOrWhiteSpace($standards[$key]['rationale'])) {
        throw ".compliance-audit.yml: $key marked not_applicable but has no rationale"
    }
}

# Default missing known standards to required with empty rationale
foreach ($ks in $knownStandards) {
    if (-not $standards.ContainsKey($ks)) {
        $standards[$ks] = @{ status = 'required'; rationale = '' }
    }
}

# ---- Scalar fields with defaults ----
$regionRequired = if ($top.ContainsKey('region_required') -and $top['region_required']) { $top['region_required'] } else { 'ca-central-1' }

$runNativeEngine = $true
if ($top.ContainsKey('run_native_engine') -and $top['run_native_engine']) {
    if ($top['run_native_engine'] -eq 'true') { $runNativeEngine = $true }
    elseif ($top['run_native_engine'] -eq 'false') { $runNativeEngine = $false }
    else { throw ".compliance-audit.yml: invalid run_native_engine '$($top['run_native_engine'])' (expected true|false)" }
}

$reconfirmAfterDays = 365
if ($top.ContainsKey('reconfirm_after_days') -and $top['reconfirm_after_days']) {
    $parsedDays = 0
    if (-not [int]::TryParse($top['reconfirm_after_days'], [ref]$parsedDays)) {
        throw ".compliance-audit.yml: invalid reconfirm_after_days '$($top['reconfirm_after_days'])' (expected integer)"
    }
    $reconfirmAfterDays = $parsedDays
}

$lastConfirmed = if ($top.ContainsKey('last_confirmed')) { $top['last_confirmed'] } else { $null }
$targetRepo = if ($top.ContainsKey('target_repo')) { $top['target_repo'] } else { $null }

if ($AsHashtable) {
    $standardsHash = @{}
    foreach ($ks in $knownStandards) {
        $standardsHash[$ks] = @{ status = $standards[$ks]['status']; rationale = $standards[$ks]['rationale'] }
    }
    return @{
        version            = $versionInt
        targetRepo         = $targetRepo
        regionRequired     = $regionRequired
        runNativeEngine    = $runNativeEngine
        lastConfirmed      = $lastConfirmed
        reconfirmAfterDays = $reconfirmAfterDays
        standards          = $standardsHash
    }
}

$standardsOut = @{}
foreach ($ks in $knownStandards) {
    $standardsOut[$ks] = [pscustomobject]@{
        status    = $standards[$ks]['status']
        rationale = $standards[$ks]['rationale']
    }
}

[pscustomobject]@{
    version            = $versionInt
    targetRepo         = $targetRepo
    regionRequired     = $regionRequired
    runNativeEngine    = $runNativeEngine
    lastConfirmed      = $lastConfirmed
    reconfirmAfterDays = $reconfirmAfterDays
    standards          = $standardsOut
}
