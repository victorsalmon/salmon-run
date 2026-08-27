param(
    [Parameter(Mandatory)]
    [string]$ClientSlug,

    [string]$ClientName,

    [switch]$Interactive,

    [switch]$SkipEmail,

    [switch]$SkipRepo,

    [string]$ResumeFrom,

    [string]$RootPath = "$HOME\Clients"
)

$ErrorActionPreference = "Stop"

$checkpointPath = Join-Path (Join-Path $RootPath $ClientSlug) ".onboarding-checkpoint.json"
$scriptsDir = Split-Path $PSScriptRoot -Parent

function Get-ClientName {
    if ($ClientName) { return $ClientName }
    if ($Interactive) {
        $name = Read-Host "Client display name (e.g., 'Acme Corp')"
        if (-not $name) { throw "Client name is required." }
        return $name
    }
    return $ClientSlug
}

function Write-Checkpoint {
    param([string]$Stage)
    $checkpoint = @{
        slug        = $ClientSlug
        completed   = @()
        updated_at  = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
    }
    if (Test-Path $checkpointPath) {
        $checkpoint = Get-Content $checkpointPath -Raw | ConvertFrom-Json
    }
    if ($checkpoint.completed -notcontains $Stage) {
        $checkpoint.completed += $Stage
    }
    $checkpoint.updated_at = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
    New-Item -ItemType Directory -Path (Split-Path $checkpointPath -Parent) -Force | Out-Null
    $checkpoint | ConvertTo-Json | Set-Content $checkpointPath
}

function Test-Completed {
    param([string]$Stage)
    if (-not (Test-Path $checkpointPath)) { return $false }
    $checkpoint = Get-Content $checkpointPath -Raw | ConvertFrom-Json
    return $checkpoint.completed -contains $Stage
}

function Invoke-Stage {
    param([string]$Stage, [scriptblock]$Block)
    if ($ResumeFrom -and (Test-Completed $Stage)) {
        Write-Host "[Checkpoint] Stage '$Stage' already completed. Skipping."
        return
    }
    if ($ResumeFrom -and (Test-Completed $ResumeFrom) -and -not (Test-Completed $Stage)) {
        Write-Host "[Checkpoint] Resuming from '$ResumeFrom', running stage '$Stage'."
    }
    Write-Host "`n=== Stage: $Stage ==="
    & $Block
    Write-Checkpoint $Stage
    Write-Host "  -> Completed."
}

# Resolve client name early
$resolvedName = Get-ClientName
Write-Host "Onboarding '$resolvedName' ($ClientSlug)"

# Stage 1: Validate checklist
Invoke-Stage "validate-checklist" {
    $checklistPath = Join-Path $scriptsDir "Skills\Clients\onboarding-checklist.md"
    if (-not (Test-Path $checklistPath)) {
        Write-Warning "Checklist not found at $checklistPath — skipping validation."
        return
    }
    Write-Host "Checklist available at: $checklistPath"
    if ($Interactive) {
        Write-Host "Please ensure the checklist is filled out before proceeding."
        $response = Read-Host "Continue? (Y/n)"
        if ($response -eq "n") { throw "Onboarding aborted by user." }
    }
}

# Stage 2: Create folder
Invoke-Stage "create-folder" {
    $folderScript = Join-Path $scriptsDir "Skills\Clients\New-ClientFolder.ps1"
    & $folderScript -ClientSlug $ClientSlug -ClientName $resolvedName -RootPath $RootPath
}

# Stage 3: Provision email
if (-not $SkipEmail) {
    Invoke-Stage "provision-email" {
        $emailScript = Join-Path $scriptsDir "Skills\Clients\New-ClientEmail.ps1"
        & $emailScript -ClientSlug $ClientSlug -MailboxName "ap" -Domain "$ClientSlug.ca" -WhatIf
        if ($Interactive) {
            $response = Read-Host "Approved email config above? (Y/n)"
            if ($response -eq "n") { throw "Email provisioning aborted." }
        }
    }
} else {
    Write-Host "  Skipping email provisioning (-SkipEmail)"
}

# Stage 4: Create GitHub repo
if (-not $SkipRepo) {
    Invoke-Stage "create-repo" {
        $repoScript = Join-Path $scriptsDir "Skills\Clients\New-ClientGitHubRepo.ps1"
        & $repoScript -ClientSlug $ClientSlug -ClientName $resolvedName -RootPath $RootPath -DryRun
        if ($Interactive) {
            $response = Read-Host "Approved repo config above? (Y/n)"
            if ($response -eq "n") { throw "Repo creation aborted." }
        }
    }
} else {
    Write-Host "  Skipping repo creation (-SkipRepo)"
}

# Stage 5: Register IMAP monitoring
Invoke-Stage "register-monitoring" {
    $monitorScript = Join-Path $scriptsDir "Skills\Clients\Register-ClientEmailMonitor.ps1"
    if (Test-Path $monitorScript) {
        & $monitorScript -ClientSlug $ClientSlug -Email "ap@$ClientSlug.ca" -WhatIf
    } else {
        Write-Host "Monitor registration script not yet created — skipping."
    }
}

# Stage 6: Update registry
Invoke-Stage "update-registry" {
    $configPath = Join-Path $scriptsDir "..\Infrastructure\clients\providers-config.json"
    $registryPath = Join-Path (Split-Path $configPath -Parent) "clients-registry.json"
    Write-Host "Registry would be updated at: $registryPath"
}

# Stage 7: Output report
Invoke-Stage "output-report" {
    Write-Host ""
    Write-Host "=============================="
    Write-Host "ONBOARDING REPORT"
    Write-Host "=============================="
    Write-Host "Client:     $resolvedName ($ClientSlug)"
    Write-Host "Folder:     $(Join-Path $RootPath $ClientSlug)"
    Write-Host "Email:      ap@$ClientSlug.ca"
    Write-Host "Repo:       https://github.com/intersite-orchestrator/$ClientSlug"
    Write-Host "Status:     Onboarding complete"
    Write-Host "=============================="
}
