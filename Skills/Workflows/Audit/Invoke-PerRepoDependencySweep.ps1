param(
    [string]$RepoRoot = "C:\Repos",
    [string]$OutputPath = "",
    [string[]]$Repos = @(),
    [switch]$Json
)

# Used by: Skills/Workflows/Audit/alignment-audit.md (cross-repo dependency sweep)
# Scans all repos under $RepoRoot for npm/Python manifests and runs npm audit /
# pip-audit against each, producing a consolidated Markdown (or JSON) report.
# Exclusions: node_modules, .git, Tasks (agent task dirs), .branch-checkouts
# (stale branch clones), cdk.out (generated), dist/build (generated), .venv,
# .next, node tooling dirs.
# ASCII-only source: typographic characters break the PS 5.1 parser (code page
# 437). Keep every byte in this file below 0x80.

$ErrorActionPreference = "Stop"
$Script:Timeouts = @{ Npm = 180; Pip = 180 }

function Get-AuditManifests {
    param([string]$Root)
    $include = @("package.json", "package-lock.json", "npm-shrinkwrap.json", "requirements*.txt", "Pipfile.lock", "poetry.lock")
    Get-ChildItem -Path $Root -Recurse -Depth 4 -File -Include $include -ErrorAction SilentlyContinue |
        Where-Object {
            $_.FullName -notmatch '(\\|\/)\.git(\\|\/)|(\\|\/)node_modules(\\|\/)|(\\|\/)Tasks(\\|\/)|(\\|\/)\.branch-checkouts(\\|\/)|(\\|\/)cdk\.out(\\|\/)|(\\|\/)dist(\\|\/)|(\\|\/)build(\\|\/)|(\\|\/)\.venv(\\|\/)|(\\|\/)\.next(\\|\/)'
        }
}

function Invoke-CommandWithTimeout {
    param([scriptblock]$Command, [int]$TimeoutSeconds, [string]$WorkingDirectory = "", [object[]]$ArgumentList = @())
    $startParams = @{ ScriptBlock = $Command; ArgumentList = $ArgumentList }
    if ($WorkingDirectory) { $startParams.WorkingDirectory = $WorkingDirectory }
    $job = Start-Job @startParams
    try {
        if (-not (Wait-Job -Job $job -Timeout $TimeoutSeconds)) {
            Stop-Job -Job $job -ErrorAction SilentlyContinue
            return @{ TimedOut = $true; Output = ""; ExitCode = -1 }
        }
        $output = Receive-Job -Job $job -ErrorAction SilentlyContinue
        $exitCode = $job.ChildJobs[0].JobStateInfo.Reason | ForEach-Object { $_.ExitCode }
        if ($null -eq $exitCode) { $exitCode = 0 }
        return @{ TimedOut = $false; Output = ($output | Out-String); ExitCode = $exitCode }
    } finally {
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }
}

function Get-RepoName {
    param([string]$ManifestPath, [string]$Root)
    $rel = $ManifestPath.Substring($Root.Length).TrimStart('\', '/')
    $parts = $rel -split '[\\/]'
    if ($parts.Count -gt 0) { return $parts[0] }
    return $rel
}

function Test-NpmAuditAvailable {
    $r = Invoke-CommandWithTimeout -Command { npm --version } -TimeoutSeconds 60
    return (-not $r.TimedOut -and $r.Output -match '\d+\.\d+\.\d+')
}

function Invoke-NpmAudit {
    param([string]$ManifestDir)
    $lock = Get-ChildItem -Path $ManifestDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -in @("package-lock.json", "npm-shrinkwrap.json") } | Select-Object -First 1
    if (-not $lock) {
        return @{ Status = "skipped"; Reason = "no lockfile" }
    }
    $r = Invoke-CommandWithTimeout -Command {
        param($dir)
        Set-Location $dir
        npm audit --omit=dev --json 2>$null
    } -TimeoutSeconds $Script:Timeouts.Npm -WorkingDirectory $ManifestDir -ArgumentList @($ManifestDir)
    if ($r.TimedOut) { return @{ Status = "error"; Reason = "npm audit timed out" } }
    $json = $null
    try { $json = $r.Output | ConvertFrom-Json } catch { $json = $null }
    if ($null -eq $json -or $json.error) {
        $reason = if ($json.error) { $json.error.summary } else { "unparseable npm audit output" }
        return @{ Status = "error"; Reason = $reason }
    }
    $vulns = $json.metadata.vulnerabilities
    $total = 0
    if ($vulns) { foreach ($key in @("info", "low", "moderate", "high", "critical")) { $total += [int]$vulns.$key } }
    return @{
        Status   = "ok"
        Total    = $total
        Info     = [int]$vulns.info
        Low      = [int]$vulns.low
        Moderate = [int]$vulns.moderate
        High     = [int]$vulns.high
        Critical = [int]$vulns.critical
    }
}

function Invoke-PipAudit {
    param([string]$ReqFile)
    $cmd = if (Get-Command uvx -ErrorAction SilentlyContinue) {
        { param($f) uvx pip-audit -r $f --format json 2>$null }
    } elseif (Get-Command pip-audit -ErrorAction SilentlyContinue) {
        { param($f) pip-audit -r $f --format json 2>$null }
    } else {
        return @{ Status = "skipped"; Reason = "pip-audit/uvx not installed" }
    }
    $r = Invoke-CommandWithTimeout -Command $cmd -TimeoutSeconds $Script:Timeouts.Pip -WorkingDirectory (Split-Path -Parent $ReqFile) -ArgumentList @($ReqFile)
    if ($r.TimedOut) { return @{ Status = "error"; Reason = "pip-audit timed out" } }
    $json = $null
    try { $json = $r.Output | ConvertFrom-Json } catch { $json = $null }
    if ($null -eq $json) {
        return @{ Status = "error"; Reason = "unparseable pip-audit output" }
    }
    $deps = @($json.dependencies)
    $vulnCount = 0
    foreach ($d in $deps) { $vulnCount += @($d.vulns).Count }
    return @{ Status = "ok"; Total = $vulnCount }
}

# Main
if (-not (Test-Path $RepoRoot -PathType Container)) {
    Write-Error "RepoRoot not found: $RepoRoot"
    exit 2
}

$manifests = @(Get-AuditManifests -Root $RepoRoot)
if ($Repos.Count -gt 0) {
    $manifests = @($manifests | Where-Object { $name = Get-RepoName -ManifestPath $_.FullName -Root $RepoRoot; $Repos -contains $name })
}

$npmOk = Test-NpmAuditAvailable
$results = [System.Collections.Generic.List[object]]::new()

foreach ($m in $manifests) {
    $rel = $m.FullName.Substring($RepoRoot.Length).TrimStart('\', '/')
    $repo = Get-RepoName -ManifestPath $m.FullName -Root $RepoRoot
    $fileName = $m.Name.ToLower()
    $result = $null
    if ($fileName -in @("package.json", "package-lock.json", "npm-shrinkwrap.json")) {
        if (-not $npmOk) {
            $result = @{ Tool = "npm"; Status = "skipped"; Reason = "npm not installed" }
        } else {
            $r = Invoke-NpmAudit -ManifestDir $m.DirectoryName
            $result = @{ Tool = "npm" }
            $result += $r
        }
    } elseif ($fileName -like "requirements*.txt" -or $fileName -in @("pipfile.lock", "poetry.lock")) {
        $r = Invoke-PipAudit -ReqFile $m.FullName
        $result = @{ Tool = "pip-audit" }
        $result += $r
    }
    if ($result) {
        $results.Add([PSCustomObject]@{
            Repo     = $repo
            Manifest = $rel
            Tool     = $result.Tool
            Status   = $result.Status
            Detail   = if ($result.Status -eq "ok") { "total=$($result.Total)" } else { $result.Reason }
            Total    = if ($result.Status -eq "ok") { [int]$result.Total } else { -1 }
        })
    }
}

$findings = @($results | Where-Object { $_.Status -eq "ok" -and $_.Total -gt 0 })
$byRepo = $results | Group-Object Repo

if (-not $OutputPath) {
    $today = Get-Date -Format "yyyy-MM-dd"
    $OutputPath = Join-Path $RepoRoot "audit-deps-report-$today.md"
}

if ($Json) {
    $payload = [PSCustomObject]@{
        GeneratedAt = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssK")
        RepoRoot    = $RepoRoot
        ManifestCount = $results.Count
        Findings    = @($results | Where-Object { $_.Total -gt 0 })
        Results     = @($results)
    }
    $jsonOut = if ($OutputPath -like "*.json") { $OutputPath } else { $OutputPath -replace "\.md$", ".json" }
    $payload | ConvertTo-Json -Depth 5 | Set-Content -Path $jsonOut -Encoding utf8
    Write-Host "Dependency sweep JSON report: $jsonOut"
    exit 0
}

$report = [System.Text.StringBuilder]::new()
[void]$report.AppendLine("# Cross-Repo Dependency Sweep")
[void]$report.AppendLine()
[void]$report.AppendLine("Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
[void]$report.AppendLine("Repo root: $RepoRoot")
[void]$report.AppendLine("Manifests scanned: $($results.Count) across $($byRepo.Count) repos")
[void]$report.AppendLine()
[void]$report.AppendLine("## Vulnerable Manifests")
[void]$report.AppendLine()
if ($findings.Count -eq 0) {
    [void]$report.AppendLine("No vulnerabilities found.")
} else {
    [void]$report.AppendLine("| Repo | Manifest | Tool | Vulnerabilities |")
    [void]$report.AppendLine("| --- | --- | --- | --- |")
    foreach ($f in ($findings | Sort-Object Total -Descending)) {
        [void]$report.AppendLine("| $($f.Repo) | $($f.Manifest) | $($f.Tool) | $($f.Total) |")
    }
}
[void]$report.AppendLine()
[void]$report.AppendLine("## Per-Repo Summary")
[void]$report.AppendLine()
[void]$report.AppendLine("| Repo | Scanned | Vulnerable | Errors/Skipped |")
[void]$report.AppendLine("| --- | --- | --- | --- |")
foreach ($g in ($byRepo | Sort-Object Name)) {
    $scanned = @($g.Group).Count
    $vuln = @($g.Group | Where-Object { $_.Total -gt 0 }).Count
    $other = @($g.Group | Where-Object { $_.Status -ne "ok" }).Count
    [void]$report.AppendLine("| $($g.Name) | $scanned | $vuln | $other |")
}
[void]$report.AppendLine()
[void]$report.AppendLine("## Details")
[void]$report.AppendLine()
foreach ($r in ($results | Sort-Object Repo, Manifest)) {
    [void]$report.AppendLine("- **$($r.Repo)** - $($r.Manifest) - $($r.Tool): **$($r.Status)** ($($r.Detail))")
}
[void]$report.AppendLine()

$report.ToString() | Set-Content -Path $OutputPath -Encoding utf8
Write-Host "Dependency sweep report: $OutputPath"
Write-Host "Manifests scanned: $($results.Count), vulnerable: $($findings.Count)"
