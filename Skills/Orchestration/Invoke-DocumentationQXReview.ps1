<#
.SYNOPSIS
    Runs QX (Quality Experience) documentation review via the AQE bridge.

.DESCRIPTION
    Scans .md files at a given path, sends each to the AQE bridge's qe_qx_analyze
    tool, and produces a structured report with heuristic counts, oracle problems,
    impact scores, and recommendations.
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$Path
)

$ErrorActionPreference = "Stop"
$BridgeUrl = "http://mcp_aqe:21004"  # See Infrastructure/port-registry.json
$RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

# ==== RESOLVE TARGET PATH ====
$TargetPath = if ([System.IO.Path]::IsPathRooted($Path)) {
    $Path
} else {
    Join-Path (Resolve-Path $RepoRoot) $Path
}

if (-not (Test-Path $TargetPath)) {
    Write-Host "[ERROR] Path not found: $TargetPath" -ForegroundColor Red
    exit 1
}

# ==== DISCOVER .MD FILES ====
$MdFiles = if (Test-Path -Path $TargetPath -PathType Container) {
    Get-ChildItem -Path $TargetPath -Filter "*.md" -File -Recurse
} else {
    if ((Get-Item $TargetPath).Extension -ne ".md") {
        Write-Host "[ERROR] Not a .md file: $TargetPath" -ForegroundColor Red
        exit 1
    }
    @(Get-Item -Path $TargetPath)
}

if ($MdFiles.Count -eq 0) {
    Write-Host "[ERROR] No .md files found at: $TargetPath" -ForegroundColor Red
    exit 1
}

# ==== BEGIN REVIEW LOOP ====
Write-Host "`n  QX Documentation Review" -ForegroundColor Cyan
Write-Host "  Bridge: $BridgeUrl" -ForegroundColor Gray
Write-Host "  Files:  $($MdFiles.Count)`n" -ForegroundColor Gray

$Results = @()
$Total = $MdFiles.Count
$Current = 0

foreach ($File in $MdFiles) {
    $Current++
    $RelativePath = if ($File.FullName.StartsWith($RepoRoot)) {
        $File.FullName.Substring($RepoRoot.Length + 1)
    } else {
        $File.Name
    }

    Write-Host "  [$Current/$Total] $RelativePath..." -NoNewline -ForegroundColor Gray

    try {
        $Response = Invoke-RestMethod -Uri "${BridgeUrl}/tools/qe_qx_analyze" `
            -Method POST `
            -Body (@{ target = $RelativePath; mode = "quick" } | ConvertTo-Json) `
            -ContentType "application/json" `
            -TimeoutSec 120

        $HeuristicsCount = if ($Response.heuristics) {
            if ($Response.heuristics -is [array]) { $Response.heuristics.Count } else { 1 }
        } else { 0 }

        $OracleProblems = if ($Response.oracleProblems) {
            if ($Response.oracleProblems -is [array]) { $Response.oracleProblems.Count } else { 1 }
        } elseif ($Response.oracle_problems) {
            if ($Response.oracle_problems -is [array]) { $Response.oracle_problems.Count } else { 1 }
        } else { 0 }

        $ImpactScore = if ($null -ne $Response.impactScore) { $Response.impactScore }
            elseif ($null -ne $Response.impact_score) { $Response.impact_score }
            elseif ($null -ne $Response.overallScore) { $Response.overallScore }
            elseif ($null -ne $Response.overall_score) { $Response.overall_score }
            else { "N/A" }

        $TopRec = if ($Response.recommendations -is [array] -and $Response.recommendations.Count -gt 0) {
            "$($Response.recommendations[0])"
        } elseif ($Response.topRecommendation) {
            "$($Response.topRecommendation)"
        } elseif ($Response.top_recommendation) {
            "$($Response.top_recommendation)"
        } else { "N/A" }
        if ($TopRec.Length -gt 65) { $TopRec = $TopRec.Substring(0, 62) + "..." }

        $Results += [PSCustomObject]@{
            File              = $RelativePath
            HeuristicsApplied = $HeuristicsCount
            OracleProblems    = $OracleProblems
            ImpactScore       = $ImpactScore
            TopRecommendation = $TopRec
            RawResponse       = $Response
        }

        Write-Host " OK" -ForegroundColor Green
    } catch {
        Write-Host " FAIL" -ForegroundColor Red
        Write-Warning "  [WARN] $RelativePath : $_"

        $Results += [PSCustomObject]@{
            File              = $RelativePath
            HeuristicsApplied = "ERROR"
            OracleProblems    = "ERROR"
            ImpactScore       = "ERROR"
            TopRecommendation = $_.Exception.Message
            RawResponse       = $null
        }
    }
}

# ==== GENERATE REPORT ====
$DateStamp = Get-Date -Format "yyyy.MM.dd"
$BuildDir = Join-Path $RepoRoot "docs\_build"
if (-not (Test-Path $BuildDir)) {
    New-Item -ItemType Directory -Path $BuildDir -Force | Out-Null
}

# ==== BUILD REPORT MARKDOWN ====
$ReportPath = Join-Path $BuildDir "qx-review-${DateStamp}.md"

$ReportLines = @(
    "# QX Documentation Review — $DateStamp",
    "",
    "**Bridge**: $BridgeUrl",
    "**Source path**: $Path",
    "**Files analyzed**: $($Results.Count)",
    "**Generated**: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
    "",
    "## Summary Table",
    "",
    "| File | Heuristics Applied | Oracle Problems | Impact Score | Top Recommendation |",
    "| :--- | :---: | :---: | :---: | :--- |"
)

foreach ($R in $Results) {
    $ReportLines += "| $($R.File) | $($R.HeuristicsApplied) | $($R.OracleProblems) | $($R.ImpactScore) | $($R.TopRecommendation) |"
}

$ReportLines += @(
    "",
    "## Detailed Findings",
    ""
)

foreach ($R in $Results) {
    $ReportLines += "### $($R.File)"
    $ReportLines += ""

    if ($R.RawResponse) {
        $Resp = $R.RawResponse

        $Heuristics = if ($Resp.heuristics -is [array]) { $Resp.heuristics } elseif ($Resp.heuristics) { @($Resp.heuristics) } else { @() }
        if ($Heuristics.Count -gt 0) {
            $ReportLines += "**Heuristics Applied ($($Heuristics.Count)):**"
            $ReportLines += ""
            foreach ($H in $Heuristics) {
                $HStr = if ($H -is [string]) { $H } elseif ($H.name) { $H.name } else { "$H" }
                $ReportLines += "- $HStr"
            }
            $ReportLines += ""
        }

        $Oracles = if ($Resp.oracleProblems -is [array]) { $Resp.oracleProblems } elseif ($Resp.oracle_problems -is [array]) { $Resp.oracle_problems } else { @() }
        if ($Oracles.Count -gt 0) {
            $ReportLines += "**Oracle Problems ($($Oracles.Count)):**"
            $ReportLines += ""
            foreach ($O in $Oracles) {
                $OStr = if ($O -is [string]) { $O } elseif ($O.description) { $O.description } else { "$O" }
                $Severity = if ($O.severity) { " ($($O.severity))" } else { "" }
                $ReportLines += "- $OStr$Severity"
            }
            $ReportLines += ""
        }

        $Impacts = if ($Resp.impacts -is [array]) { $Resp.impacts } elseif ($Resp.impactAnalysis) { $Resp.impactAnalysis } else { @() }
        if ($Impacts.Count -gt 0) {
            $ReportLines += "**Impact Analysis:**"
            $ReportLines += ""
            foreach ($Imp in $Impacts) {
                $ImpStr = if ($Imp -is [string]) { $Imp } elseif ($Imp.description) { $Imp.description } else { "$Imp" }
                $ReportLines += "- $ImpStr"
            }
            $ReportLines += ""
        }

        $Recs = if ($Resp.recommendations -is [array]) { $Resp.recommendations } else { @() }
        if ($Recs.Count -gt 0) {
            $ReportLines += "**Recommendations:**"
            $ReportLines += ""
            foreach ($Rec in $Recs) {
                $ReportLines += "- $Rec"
            }
            $ReportLines += ""
        }
    } else {
        $ReportLines += "_Analysis failed or returned no data._"
        $ReportLines += ""
    }
}

$ReportLines += "---"
$ReportLines += "_Report generated by Invoke-DocumentationQXReview.ps1_"

$ReportContent = $ReportLines -join "`r`n"
Set-Content -Path $ReportPath -Value $ReportContent -Encoding UTF8

Write-Host "`n  Report:" -ForegroundColor Cyan
Write-Host "  $ReportPath" -ForegroundColor Green
Write-Host "`n  Done." -ForegroundColor Cyan
