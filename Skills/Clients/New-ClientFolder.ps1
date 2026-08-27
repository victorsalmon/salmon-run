param(
    [Parameter(Mandatory)]
    [string]$ClientSlug,

    [Parameter(Mandatory)]
    [string]$ClientName,

    [string]$TemplateName = "bookkeeping",

    [string]$RootPath = "$HOME\Clients",

    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"

# Resolve template path
$templatePath = Join-Path $PSScriptRoot "..\Infrastructure\clients\templates\$TemplateName\folder-layout.json"
if (-not (Test-Path $templatePath)) {
    $templatePath = Join-Path $PSScriptRoot "..\..\Infrastructure\clients\templates\$TemplateName\folder-layout.json"
}
if (-not (Test-Path $templatePath)) {
    $templatePath = Join-Path (Split-Path $PSScriptRoot -Parent) "Infrastructure\clients\templates\$TemplateName\folder-layout.json"
}
if (-not (Test-Path $templatePath)) {
    throw "Template not found: $TemplateName (searched relative to script root)"
}

$template = Get-Content $templatePath -Raw | ConvertFrom-Json

$clientRoot = Join-Path $RootPath $ClientSlug

function Expand-Variables {
    param([string]$Text, [hashtable]$Vars)
    $result = $Text
    foreach ($key in $Vars.Keys) {
        $result = $result -replace "\{$key\}", $Vars[$key]
    }
    return $result
}

$globalVars = @{
    slug      = $ClientSlug
    name      = $ClientName
    timestamp = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
}

if ($WhatIf) {
    Write-Host "[WhatIf] Scaffolding client folder for '$ClientName' ($ClientSlug) at: $clientRoot"
}

# Process directory entries
foreach ($entry in $template.directories) {
    $resolvedPath = Expand-Variables -Text $entry.path -Vars $globalVars
    $target = Join-Path $clientRoot $resolvedPath

    if ($entry.type -eq "dir") {
        if ($WhatIf) {
            Write-Host "[WhatIf]  Create directory: $target"
        } else {
            New-Item -ItemType Directory -Path $target -Force | Out-Null
        }
    }
    elseif ($entry.type -eq "file") {
        $content = ""
        if ($entry.content -is [pscustomobject]) {
            $content = $entry.content | ConvertTo-Json -Depth 10
        } elseif ($entry.content -is [string]) {
            $content = Expand-Variables -Text $entry.content -Vars $globalVars
        }

        if ($WhatIf) {
            Write-Host "[WhatIf]  Create file: $target"
        } else {
            $parent = Split-Path $target -Parent
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
            Set-Content -Path $target -Value $content -NoNewline
        }
    }
    elseif ($entry.type -eq "dir-template") {
        # For the first pass, just create the parent directory
        # Bank account iteration is handled at provisioning time
        if ($WhatIf) {
            Write-Host "[WhatIf]  Create template directory (actual accounts resolved later): $target"
        } else {
            New-Item -ItemType Directory -Path $target -Force | Out-Null
        }
    }
}

if (-not $WhatIf) {
    # Write client-config.json with minimal info
    $configPath = Join-Path $clientRoot "client-config.json"
    $config = @{
        slug        = $ClientSlug
        name        = $ClientName
        created_at  = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
        service_type = "bookkeeping"
    }
    Set-Content -Path $configPath -Value ($config | ConvertTo-Json -Depth 10)

    # Initialize git repo
    Push-Location $clientRoot
    try {
        git init 2>&1 | Out-Null
        git add -A 2>&1 | Out-Null
        git commit -m "Initial scaffold for $ClientName ($ClientSlug)" 2>&1 | Out-Null
    } finally {
        Pop-Location
    }

    Write-Host "Client folder scaffolded at: $clientRoot"
    Write-Host "Git repository initialized with initial commit."
} else {
    Write-Host "[WhatIf]  git init in: $clientRoot"
    Write-Host "[WhatIf]  git add + git commit with 'Initial scaffold for $ClientName ($ClientSlug)'"
}

# Output summary
$summary = @{
    ClientSlug  = $ClientSlug
    ClientName  = $ClientName
    RootPath    = $clientRoot
    Template    = $TemplateName
    Directories = @($template.directories | Where-Object { $_.type -eq "dir" -or $_.type -eq "dir-template" } | ForEach-Object { Expand-Variables -Text $_.path -Vars $globalVars })
}
if (-not $WhatIf) {
    $summary.GitInitialized = $true
}
return $summary
