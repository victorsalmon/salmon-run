param(
    [Parameter(Mandatory)] [string]$Domain,
    [Parameter(Mandatory)][ValidateSet("critical", "high", "medium", "low", "info")] [string]$Severity,
    [Parameter(Mandatory)][ValidateSet("critical", "high", "medium", "low")] [string]$BlastRadius,
    [Parameter(Mandatory)] [string]$Title,
    [Parameter(Mandatory)] [string]$Detail,
    [Parameter(Mandatory)] [string[]]$Files,
    [string]$LoggedBy = $env:COMPUTERNAME,
    [string]$RepoRoot = ""
)

$ErrorActionPreference = "Stop"

if ($Files.Count -eq 0) {
    Write-Error "Files parameter must contain at least one path"
    exit 1
}

if ([string]::IsNullOrWhiteSpace($Detail)) {
    Write-Error "Detail parameter must not be empty — every finding needs a substantive description"
    exit 1
}

# Resolve repo root
if ($RepoRoot) {
    $repoRoot = $RepoRoot
} elseif ($env:AUDIT_TARGET_REPO) {
    $repoRoot = $env:AUDIT_TARGET_REPO
} else {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $repoRoot = $scriptDir
    while ($repoRoot) {
        if (Test-Path (Join-Path $repoRoot "AGENTS.md") -PathType Leaf) { break }
        if (Test-Path (Join-Path $repoRoot ".git") -PathType Container) { break }
        $parent = Split-Path $repoRoot -Parent
        if ($parent -eq $repoRoot) { $repoRoot = $null; break }
        $repoRoot = $parent
    }
    if (-not $repoRoot) { $repoRoot = Join-Path $HOME "intersite-orchestrator" }
}

# Draft plan directory: Tasks/Code/Drafts/<domain>/
$draftsDir = Join-Path $repoRoot "Tasks\Code\Drafts"
$domainDir = Join-Path $draftsDir $Domain
$null = New-Item -ItemType Directory -Path $domainDir -Force

# Generate unique finding ID
$domainPrefix = $Domain -replace '^domain-', 'D'
$idPrefix = "$domainPrefix-$($Severity.ToUpper())-"
$maxNum = 0
Get-ChildItem -Path $domainDir -Filter "*.md" -ErrorAction SilentlyContinue | ForEach-Object {
    if ($_.BaseName -match "^$([Regex]::Escape($idPrefix))(\d+)$") {
        $num = [int]$matches[1]
        if ($num -gt $maxNum) { $maxNum = $num }
    }
}
$newId = "$idPrefix$($maxNum + 1)"
$planPath = Join-Path $domainDir "$newId.md"

# Build draft plan content
$lines = @()
$lines += "# Draft Plan: $Domain — $Title"
$lines += ""
$lines += "**Finding ID**: $newId"
$lines += "**Severity**: $Severity"
$lines += "**Blast Radius**: $BlastRadius"
$lines += "**Files**: $($Files -join ', ')"
$lines += "**Detail**: $Detail"
$lines += "**LoggedBy**: $LoggedBy"
$lines += "**Timestamp**: $(Get-Date -Format 'o')"
$lines += ""

$content = $lines -join "`r`n"
$content | Out-File $planPath -Encoding utf8

# Also write to the audit log for hash-chain integrity
$auditLogScript = Join-Path $scriptDir "Write-AlignmentAuditLog.ps1"
if (Test-Path $auditLogScript) {
    . $auditLogScript
    $auditDetail = @{
        draftPlanId = $newId
        planTitle = $Title
        planDetail = $Detail
        draftPath = $planPath
    } | ConvertTo-Json -Compress
    Write-AlignmentAuditLog -Domain $Domain -Action "finding" -Detail $auditDetail -Severity $Severity
}

Write-Output "Written: $newId -> $planPath"
