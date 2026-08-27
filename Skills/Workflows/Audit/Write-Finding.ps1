# DEPRECATED: This script writes to a shared JSON Findings Manifest.
# Replaced by Write-DraftPlan.ps1 which writes individual draft plan files
# to Tasks/Code/Drafts/<domain>/ — no cross-process mutex contention,
# no JSON serialization boundary, and direct compatibility with the updated
# Superseded by Write-SessionPlan.ps1 (shared skill). Retained for archival reference.
#
# Kept for backward compatibility with any workflows still referencing it.
# New audit workflows should use Write-DraftPlan.ps1 instead.

param(
    [Parameter(Mandatory)] [string]$ManifestPath,
    [Parameter(Mandatory)] [string]$Domain,
    [Parameter(Mandatory)][ValidateSet("critical", "high", "medium", "low")] [string]$Severity,
    [Parameter(Mandatory)][ValidateSet("critical", "high", "medium", "low")] [string]$BlastRadius,
    [Parameter(Mandatory)] [string]$Title,
    [Parameter(Mandatory)] [string]$Detail,
    [Parameter(Mandatory)] [string[]]$Files,
    [switch]$Deferred,
    [string]$DeferredReason = "Deferred per user direction",
    [string]$LoggedBy = $env:COMPUTERNAME
)

$ErrorActionPreference = "Stop"

if ($Files.Count -eq 0) {
    Write-Error "Files parameter must contain at least one path"
    exit 1
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$auditLogScript = Join-Path $scriptDir "Write-AlignmentAuditLog.ps1"

$MutexName = "Local\Interclaw-AuditFindings-Mutex"
$Mutex = $null
$acquiredLock = $false

try {
    $Mutex = New-Object System.Threading.Mutex($false, $MutexName)
    $acquiredLock = $Mutex.WaitOne(10000)
    if (-not $acquiredLock) {
        Write-Error "Could not acquire mutex for Findings Manifest at $ManifestPath"
        exit 1
    }

    $manifest = $null
    if (Test-Path $ManifestPath) {
        $manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json
    } else {
        $manifest = [PSCustomObject]@{
            version = 1
            auditDate = (Get-Date -Format "yyyy-MM-dd")
            findings = @()
            deferredFindings = @()
        }
    }

    # Generate unique ID — scan all entries (both findings and deferredFindings) to avoid collisions
    $domainPrefix = $Domain -replace '^domain-', 'D'
    $idPrefix = "$domainPrefix-$($Severity.ToUpper())-"
    $maxNum = 0
    $allEntries = @($manifest.findings) + @($manifest.deferredFindings)
    foreach ($entry in $allEntries) {
        if ($entry.id -match "^$([Regex]::Escape($idPrefix))(\d+)$") {
            $num = [int]$matches[1]
            if ($num -gt $maxNum) { $maxNum = $num }
        }
    }
    $newId = "$idPrefix$($maxNum + 1)"

    $finding = [PSCustomObject]@{
        id = $newId
        domain = $Domain
        severity = $Severity
        blastRadius = $BlastRadius
        title = $Title
        detail = $Detail
        files = @($Files)
        loggedBy = $LoggedBy
        timestamp = (Get-Date -Format "o")
    }

    if ($Deferred) {
        $deferredEntry = [PSCustomObject]@{
            id = $newId
            domain = $Domain
            severity = $Severity
            reason = $DeferredReason
            originalFinding = $finding
        }
        $manifest.deferredFindings = @($manifest.deferredFindings) + $deferredEntry
    } else {
        $manifest.findings = @($manifest.findings) + $finding
    }

    $manifestJson = $manifest | ConvertTo-Json -Depth 10
    $null = New-Item -ItemType Directory -Path (Split-Path $ManifestPath -Parent) -Force
    $tmpPath = "$ManifestPath.tmp"
    $manifestJson | Out-File $tmpPath -Encoding utf8
    Move-Item -LiteralPath $tmpPath -Destination $ManifestPath -Force

    if (Test-Path $auditLogScript) {
        . $auditLogScript
        $auditDetail = @{
            manifestFindingId = $newId
            findingTitle = $Title
            findingDetail = $Detail
        } | ConvertTo-Json -Compress
        Write-AlignmentAuditLog -Domain $Domain -Action "finding" -Detail $auditDetail -Severity $Severity
    }

    Write-Output "Written: $newId"
} finally {
    if ($acquiredLock -and $Mutex) { $Mutex.ReleaseMutex() }
    if ($Mutex) { $Mutex.Dispose() }
}
