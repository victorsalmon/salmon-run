param(
    [Parameter(Mandatory)]
    [string]$ClientSlug,

    [Parameter(Mandatory)]
    [string]$ClientName,

    [string]$GitHubOrg,

    [string]$RootPath = "$HOME\Clients",

    [ValidateSet("private", "internal")]
    [string]$Visibility = "private",

    [string]$ConfigPath = "$HOME\intersite-orchestrator\Infrastructure\clients\providers-config.json",

    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

# Resolve GitHub org from config if not provided
if (-not $GitHubOrg) {
    if (-not (Test-Path $ConfigPath)) {
        $altPath = Join-Path $PSScriptRoot "..\..\Infrastructure\clients\providers-config.json"
        if (Test-Path $altPath) { $ConfigPath = $altPath }
    }
    if (Test-Path $ConfigPath) {
        $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
        $gitConfig = $config.git.providers.$($config.git.active_provider)
        if ($gitConfig.default_org) { $GitHubOrg = $gitConfig.default_org }
    }
}

if (-not $GitHubOrg) {
    throw "GitHub organization not specified and no default found in providers-config.json. Pass -GitHubOrg."
}

$clientRoot = Join-Path $RootPath $ClientSlug

Write-Host "GitHub Repo Plan:"
Write-Host "  Client:       $ClientName ($ClientSlug)"
Write-Host "  Organization: $GitHubOrg"
Write-Host "  Repo:         $GitHubOrg/$ClientSlug (visibility: $Visibility)"
Write-Host "  Local path:   $clientRoot"

# Check gh CLI
try {
    $ghStatus = gh auth status 2>&1
    if ($LASTEXITCODE -ne 0) { throw "gh not authenticated" }
    Write-Host "  gh CLI:       authenticated"
} catch {
    Write-Warning "gh CLI not available or not authenticated: $_"
    if (-not $DryRun) { throw "Cannot proceed without GitHub CLI (gh). Install from https://cli.github.com/ and run 'gh auth login'." }
}

# Check if local folder exists and has git
$localExists = Test-Path $clientRoot
$hasGit = $false
if ($localExists) {
    $hasGit = Test-Path (Join-Path $clientRoot ".git")
}

# Check if repo already exists on GitHub
try {
    $existingRepo = gh repo view "$GitHubOrg/$ClientSlug" --json name,visibility 2>&1
    $repoExists = $LASTEXITCODE -eq 0
} catch {
    $repoExists = $false
}

if ($repoExists) {
    Write-Host "  Repo exists:  yes ($((ConvertFrom-Json $existingRepo).visibility))"
} else {
    Write-Host "  Repo exists:  no (will create)"
}

Write-Host ""

if ($DryRun) {
    if (-not $localExists) {
        Write-Host "[DryRun] Would scaffold local folder with New-ClientFolder.ps1"
    }
    if (-not $repoExists) {
        Write-Host "[DryRun] Would create GitHub repo: gh repo create $GitHubOrg/$ClientSlug --$Visibility --push"
    }
    if ($localExists -and -not $hasGit) {
        Write-Host "[DryRun] Would git init at $clientRoot"
    }
    if ($hasGit) {
        Write-Host "[DryRun] Would set remote: git remote add origin git@github.com:${GitHubOrg}/${ClientSlug}.git"
    }
    Write-Host "[DryRun] Would push initial scaffold: git push -u origin main"
    return @{
        ClientSlug    = $ClientSlug
        GitHubOrg     = $GitHubOrg
        RepoName      = "$GitHubOrg/$ClientSlug"
        Visibility    = $Visibility
        LocalPath     = $clientRoot
        DryRun        = $true
    }
}

# Scaffold local folder if needed
if (-not $localExists) {
    Write-Host "Scaffolding local folder..."
    & (Join-Path $PSScriptRoot "New-ClientFolder.ps1") -ClientSlug $ClientSlug -ClientName $ClientName -RootPath $RootPath
}

# Create the GitHub repo
Write-Host "Creating GitHub repo $GitHubOrg/$ClientSlug ($Visibility)..."
$createResult = gh repo create "$GitHubOrg/$ClientSlug" --$Visibility --push 2>&1
if ($LASTEXITCODE -ne 0) {
    if ($createResult -match "already exists") {
        Write-Host "Repo already exists, will connect local to existing repo."
    } else {
        throw "Failed to create GitHub repo: $createResult"
    }
} else {
    Write-Host "GitHub repo created: $createResult"
}

# Ensure remote is set on local repo
Push-Location $clientRoot
try {
    $remotes = git remote 2>&1
    if ($remotes -notcontains "origin") {
        git remote add origin "git@github.com:${GitHubOrg}/${ClientSlug}.git" 2>&1
        Write-Host "Remote 'origin' added."
    } else {
        Write-Host "Remote 'origin' already exists."
    }

    # Push if not already pushed
    $branches = git branch --show-current 2>&1
    if ($branches -eq "main" -or $branches -eq "master") {
        $pushResult = git push -u origin "HEAD:$branches" 2>&1
        Write-Host "Pushed to origin/$branches."
    }
} finally {
    Pop-Location
}

# Write client registry entry
$registryPath = Join-Path (Split-Path $ConfigPath -Parent) "clients-registry.json"
$registry = @()
if (Test-Path $registryPath) {
    try { $registry = Get-Content $registryPath -Raw | ConvertFrom-Json } catch {}
}

$existing = $registry | Where-Object { $_.slug -eq $ClientSlug }
if (-not $existing) {
    $entry = @{
        id          = [guid]::NewGuid().ToString()
        display_name = $ClientName
        slug        = $ClientSlug
        status      = "onboarding"
        service_type = "bookkeeping"
        contacts    = @()
        onboarded_at = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
        providers   = @{
            git = @{ provider = "github"; config = @{ org = $GitHubOrg; repo = $ClientSlug } }
        }
    } | ConvertFrom-Json -AsHashtable

    $registry = @($registry) + @($entry)
    $registry | ConvertTo-Json -Depth 10 | Set-Content $registryPath
    Write-Host "Client registry entry written."
}

Write-Host ""
Write-Host "Done. Repo URL: https://github.com/$GitHubOrg/$ClientSlug"

return @{
    ClientSlug = $ClientSlug
    RepoUrl    = "https://github.com/$GitHubOrg/$ClientSlug"
    LocalPath  = $clientRoot
}
