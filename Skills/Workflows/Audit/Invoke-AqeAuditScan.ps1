param(
    [string]$BridgeUrl = "",  # Optional legacy bridge override; /aqe is the supported path.
    [string]$OutputFile = "",
    [string]$RepoRoot = "",
    [switch]$SkipQualityAssess,
    [switch]$SkipValidationPipeline,
    [switch]$SkipSecurityScan,
    [switch]$SkipTopologyAnalysis,
    [switch]$SkipCoherenceAudit,
    [switch]$SkipDefectPredict,
    [int]$TimeoutSec = 60
)

# Used by: Skills/Workflows/Audit/alignment-audit.md (Phase 0 - AQE Quality Sweep)
#          Skills/Workflows/Audit/architectural-audit.md (Phase 0)
#          Skills/Workflows/Audit/functional-audit.md (Phase 0)
#
# Compatibility wrapper for the retired AQE REST bridge. New audits should use
# the /aqe skill and local quality scripts. If no explicit legacy bridge URL is
# supplied, this writes an empty non-blocking result and returns.
#
# AQE tools used (all High reliability per docs/Reference/AQE-Agent-Guide.md):
#   - quality_assess: 4-pillar scorecard (coverage, complexity, maintainability, security)
#   - validation_pipeline: 13-step doc quality checker
#   - qe_security_url-validate: URL and PII scanner
#   - qe_mincut_analyze: fleet topology SPOF detection
#   - qe_coherence_audit: cross-domain coherence check
#   - defect_predict: predict defect-prone areas (Medium reliability — verify output)

$ErrorActionPreference = "Continue"

# Resolve an explicitly enabled legacy bridge URL.
# This script lives in Skills/Workflows/Audit/; the resolver is in
# Skills/AQE/ — reach it via the Skills sibling of OpenCode.
$__resolver = Join-Path $PSScriptRoot '..\..\..\AQE\Resolve-AqeBridgeUrl.ps1'
if (Test-Path $__resolver) {
    . $__resolver
    if (-not $BridgeUrl) { $BridgeUrl = Resolve-AqeBridgeUrl }
} elseif (-not $BridgeUrl) {
    # Standalone copies may still use an explicit environment override, but do
    # not recreate the retired localhost default.
    $BridgeUrl = $env:AQE_BRIDGE_URL
}

# Resolve repo root
if (-not $RepoRoot) { $RepoRoot = $env:AUDIT_TARGET_REPO }
if (-not $RepoRoot) {
    $RepoRoot = $PSScriptRoot
    while ($RepoRoot) {
        if (Test-Path (Join-Path $RepoRoot "AGENTS.md") -PathType Leaf) { break }
        if (Test-Path (Join-Path $RepoRoot ".git") -PathType Container) { break }
        $parent = Split-Path $RepoRoot -Parent
        if ($parent -eq $RepoRoot) { $RepoRoot = $null; break }
        $RepoRoot = $parent
    }
}
if (-not $RepoRoot) { $RepoRoot = Join-Path $HOME "intersite-orchestrator" }

# Default output path
if (-not $OutputFile) {
    $today = Get-Date -Format "yyyy-MM-dd"
    $OutputFile = Join-Path $RepoRoot "Tasks\Logs\aqe-scan-$today.json"
}

# Ensure output directory exists
$outDir = Split-Path $OutputFile -Parent
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

if (-not $BridgeUrl) {
    $result = [PSCustomObject]@{
        timestamp = (Get-Date -Format "o")
        bridgeUrl = $null
        available = $false
        findings  = @()
        summary   = @{ total = 0; qualityAssess = 0; validationPipeline = 0; securityScan = 0; topologyAnalysis = 0; coherenceAudit = 0; defectPredict = 0 }
        note      = "Legacy AQE bridge disabled because mcp_aqe was retired. Use the /aqe skill and local quality scripts."
    }
    $result | ConvertTo-Json -Depth 5 | Set-Content -Path $OutputFile -Encoding UTF8
    Write-Host "  Legacy AQE bridge disabled; wrote an empty non-blocking result: $OutputFile" -ForegroundColor Yellow
    return $result
}

$findings = @()
$available = $false

# ============================================================
# Pre-flight: Check AQE bridge availability
# ============================================================
Write-Host "AQE Audit Scan: Checking bridge at $BridgeUrl..." -ForegroundColor Cyan
try {
    $health = Invoke-RestMethod -Uri "$BridgeUrl/health" -Method GET -TimeoutSec 10
    $available = $true
    Write-Host "  Bridge reachable. AQE version: $($health.version)" -ForegroundColor Green
} catch {
    Write-Host "  WARNING: AQE bridge unreachable at $BridgeUrl." -ForegroundColor Yellow
    Write-Host "  Audit will continue without AQE quality findings." -ForegroundColor Yellow
    Write-Host "  This is non-blocking — grep-based automated scan still runs." -ForegroundColor Gray
}

if (-not $available) {
    $result = [PSCustomObject]@{
        timestamp = (Get-Date -Format "o")
        bridgeUrl = $BridgeUrl
        available = $false
        findings  = @()
        summary   = @{ total = 0; qualityAssess = 0; validationPipeline = 0; securityScan = 0; topologyAnalysis = 0; coherenceAudit = 0; defectPredict = 0 }
        note      = "AQE bridge unreachable. Audit continues with grep-based scan only."
    }
    $result | ConvertTo-Json -Depth 5 | Set-Content -Path $OutputFile -Encoding UTF8
    Write-Host "  Results (empty): $OutputFile" -ForegroundColor Gray
    return $result
}

# ============================================================
# Helper: Call AQE tool via REST bridge
# ============================================================
function Invoke-AqeTool {
    param([string]$ToolName, [hashtable]$Params, [int]$Timeout)
    try {
        $response = Invoke-RestMethod -Uri "$BridgeUrl/tools/$ToolName" -Method POST `
            -Body ($Params | ConvertTo-Json) -ContentType "application/json" -TimeoutSec $Timeout
        return @{ success = $true; data = $response; error = "" }
    } catch {
        $msg = if ($_.Exception.Response) {
            "$([int]$_.Exception.Response.StatusCode) $($_.Exception.Message)"
        } else { $_.Exception.Message }
        return @{ success = $false; data = $null; error = $msg }
    }
}

# ============================================================
# SCAN 1: quality_assess — 4-pillar code quality scorecard
# ============================================================
if (-not $SkipQualityAssess) {
    Write-Host "AQE Scan 1: quality_assess (4-pillar scorecard)..." -ForegroundColor Cyan
    $moduleTargets = @(
        @{ Path = "Orchestrator/Modules/SalmonRun.Core/SalmonRun.Core.ps1"; Label = "SalmonRun.Core" }
        @{ Path = "Skills/Docker/Modules/SalmonRun.Deploy/Public/Generate-FleetCompose.ps1"; Label = "SalmonRun.Deploy" }
        @{ Path = "Orchestrator/Modules/SalmonRun.Config/SalmonRun.Config.ps1"; Label = "SalmonRun.Config" }
        @{ Path = "Skills/Docker/deploy.ps1"; Label = "deploy.ps1" }
        @{ Path = "Orchestrator/Orchestration/LocalOrchestrator.ps1"; Label = "LocalOrchestrator" }
    )
    foreach ($target in $moduleTargets) {
        $fullPath = Join-Path $RepoRoot $target.Path
        if (-not (Test-Path $fullPath)) { continue }
        $rel = [System.IO.Path]::GetRelativePath($RepoRoot, $fullPath)
        $result = Invoke-AqeTool -ToolName "quality_assess" -Params @{
            target = $rel
            runGate = $true
        } -Timeout $TimeoutSec
        if ($result.success) {
            $findings += [PSCustomObject]@{
                scan = "quality-assess"
                file = $rel
                label = $target.Label
                severity = "info"
                title = "Quality assessment for $rel"
                detail = ($result.data | ConvertTo-Json -Depth 3 -Compress)
                aqeData = $result.data
            }
            Write-Host "  OK: $rel" -ForegroundColor Green
        } else {
            $findings += [PSCustomObject]@{
                scan = "quality-assess"
                file = $rel
                label = $target.Label
                severity = "low"
                title = "AQE quality_assess failed for $rel"
                detail = $result.error
            }
            Write-Host "  FAIL: $rel — $($result.error)" -ForegroundColor Yellow
        }
    }
}

# ============================================================
# SCAN 2: validation_pipeline — 13-step doc quality checker
# ============================================================
if (-not $SkipValidationPipeline) {
    Write-Host "AQE Scan 2: validation_pipeline (doc quality)..." -ForegroundColor Cyan
    $docTargets = @(
        "docs/Reference/AQE-Agent-Guide.md"
        "docs/Reference/API-Contracts.md"
        "docs/Reference/Logging.md"
        "AGENTS.md"
        "README.md"
    )
    foreach ($docPath in $docTargets) {
        $fullPath = Join-Path $RepoRoot $docPath
        if (-not (Test-Path $fullPath)) { continue }
        $result = Invoke-AqeTool -ToolName "validation_pipeline" -Params @{
            pipeline = "requirements"
            target = $docPath
            continueOnFailure = $true
        } -Timeout $TimeoutSec
        if ($result.success) {
            $findings += [PSCustomObject]@{
                scan = "validation-pipeline"
                file = $docPath
                severity = "info"
                title = "Doc validation for $docPath"
                detail = ($result.data | ConvertTo-Json -Depth 3 -Compress)
                aqeData = $result.data
            }
            Write-Host "  OK: $docPath" -ForegroundColor Green
        } else {
            $findings += [PSCustomObject]@{
                scan = "validation-pipeline"
                file = $docPath
                severity = "low"
                title = "AQE validation_pipeline failed for $docPath"
                detail = $result.error
            }
            Write-Host "  FAIL: $docPath — $($result.error)" -ForegroundColor Yellow
        }
    }
}

# ============================================================
# SCAN 3: qe_security_url-validate — PII/secret scanner
# ============================================================
if (-not $SkipSecurityScan) {
    Write-Host "AQE Scan 3: qe_security_url-validate (PII/secret scan)..." -ForegroundColor Cyan
    # Scan key config files for exposed secrets/PII that grep might miss
    $configTargets = @(
        "Infrastructure/manifests/docker-manifest.json"
        "Infrastructure/manifests/install-local.json"
        "Infrastructure/manifests/client-services.json"
        "install.json"
    )
    foreach ($configPath in $configTargets) {
        $fullPath = Join-Path $RepoRoot $configPath
        if (-not (Test-Path $fullPath)) { continue }
        $content = Get-Content -LiteralPath $fullPath -Raw
        $result = Invoke-AqeTool -ToolName "qe_security_url-validate" -Params @{
            content = $content
            enablePII = $true
        } -Timeout $TimeoutSec
        if ($result.success) {
            $findings += [PSCustomObject]@{
                scan = "security-pii"
                file = $configPath
                severity = "info"
                title = "Security/PII scan for $configPath"
                detail = ($result.data | ConvertTo-Json -Depth 3 -Compress)
                aqeData = $result.data
            }
            Write-Host "  OK: $configPath" -ForegroundColor Green
        } else {
            $findings += [PSCustomObject]@{
                scan = "security-pii"
                file = $configPath
                severity = "low"
                title = "AQE security scan failed for $configPath"
                detail = $result.error
            }
            Write-Host "  FAIL: $configPath — $($result.error)" -ForegroundColor Yellow
        }
    }
}

# ============================================================
# SCAN 4: qe_mincut_analyze — fleet topology SPOF detection
# ============================================================
if (-not $SkipTopologyAnalysis) {
    Write-Host "AQE Scan 4: qe_mincut_analyze (topology SPOF)..." -ForegroundColor Cyan
    $result = Invoke-AqeTool -ToolName "qe_mincut_analyze" -Params @{
        weaknessThreshold = 0.4
        includePartitioningPoints = $true
    } -Timeout $TimeoutSec
    if ($result.success) {
        $findings += [PSCustomObject]@{
            scan = "topology-spof"
            file = "fleet"
            severity = "info"
            title = "Fleet topology SPOF analysis"
            detail = ($result.data | ConvertTo-Json -Depth 4 -Compress)
            aqeData = $result.data
        }
        Write-Host "  OK: fleet topology analyzed" -ForegroundColor Green
    } else {
        $findings += [PSCustomObject]@{
            scan = "topology-spof"
            file = "fleet"
            severity = "low"
            title = "AQE topology analysis failed"
            detail = $result.error
        }
        Write-Host "  FAIL: $($result.error)" -ForegroundColor Yellow
    }
}

# ============================================================
# SCAN 5: qe_coherence_audit — cross-domain coherence
# ============================================================
if (-not $SkipCoherenceAudit) {
    Write-Host "AQE Scan 5: qe_coherence_audit (cross-domain coherence)..." -ForegroundColor Cyan
    $result = Invoke-AqeTool -ToolName "qe_coherence_audit" -Params @{} -Timeout $TimeoutSec
    if ($result.success) {
        $findings += [PSCustomObject]@{
            scan = "coherence-audit"
            file = "fleet"
            severity = "info"
            title = "Cross-domain coherence audit"
            detail = ($result.data | ConvertTo-Json -Depth 4 -Compress)
            aqeData = $result.data
        }
        Write-Host "  OK: coherence audit complete" -ForegroundColor Green
    } else {
        $findings += [PSCustomObject]@{
            scan = "coherence-audit"
            file = "fleet"
            severity = "low"
            title = "AQE coherence audit failed"
            detail = $result.error
        }
        Write-Host "  FAIL: $($result.error)" -ForegroundColor Yellow
    }
}

# ============================================================
# SCAN 6: defect_predict — predict defect-prone areas
# ============================================================
if (-not $SkipDefectPredict) {
    Write-Host "AQE Scan 6: defect_predict (defect prediction)..." -ForegroundColor Cyan
    $result = Invoke-AqeTool -ToolName "defect_predict" -Params @{
        target = "Skills/Docker/Modules"
    } -Timeout $TimeoutSec
    if ($result.success) {
        $findings += [PSCustomObject]@{
            scan = "defect-predict"
            file = "Skills/Docker/Modules"
            severity = "info"
            title = "Defect prediction for PowerShell modules"
            detail = ($result.data | ConvertTo-Json -Depth 4 -Compress)
            aqeData = $result.data
        }
        Write-Host "  OK: defect prediction complete" -ForegroundColor Green
    } else {
        $findings += [PSCustomObject]@{
            scan = "defect-predict"
            file = "Skills/Docker/Modules"
            severity = "low"
            title = "AQE defect_predict failed"
            detail = $result.error
        }
        Write-Host "  FAIL: $($result.error)" -ForegroundColor Yellow
    }
}

# ============================================================
# Write results
# ============================================================
$summary = @{
    total = $findings.Count
    qualityAssess = ($findings | Where-Object { $_.scan -eq "quality-assess" }).Count
    validationPipeline = ($findings | Where-Object { $_.scan -eq "validation-pipeline" }).Count
    securityScan = ($findings | Where-Object { $_.scan -eq "security-pii" }).Count
    topologyAnalysis = ($findings | Where-Object { $_.scan -eq "topology-spof" }).Count
    coherenceAudit = ($findings | Where-Object { $_.scan -eq "coherence-audit" }).Count
    defectPredict = ($findings | Where-Object { $_.scan -eq "defect-predict" }).Count
}

$output = [PSCustomObject]@{
    timestamp  = (Get-Date -Format "o")
    bridgeUrl  = $BridgeUrl
    available  = $true
    findings   = $findings
    summary    = $summary
}

$output | ConvertTo-Json -Depth 6 | Set-Content -Path $OutputFile -Encoding UTF8

Write-Host "`n  AQE Audit Scan summary:" -ForegroundColor Cyan
Write-Host "  Total findings:      $($summary.total)" -ForegroundColor Gray
Write-Host "  quality_assess:      $($summary.qualityAssess)" -ForegroundColor Gray
Write-Host "  validation_pipeline: $($summary.validationPipeline)" -ForegroundColor Gray
Write-Host "  security/PII:        $($summary.securityScan)" -ForegroundColor Gray
Write-Host "  topology SPOF:       $($summary.topologyAnalysis)" -ForegroundColor Gray
Write-Host "  coherence audit:     $($summary.coherenceAudit)" -ForegroundColor Gray
Write-Host "  defect predict:      $($summary.defectPredict)" -ForegroundColor Gray
Write-Host "  Results:             $OutputFile" -ForegroundColor Gray

return $output
