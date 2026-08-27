<#
.SYNOPSIS
    API key rotation scaffolding script.
.DESCRIPTION
    Lists and rotates API keys across AWS Secrets Manager. Supports
    coding keys (auto-generated) and vendor-issued API keys (manual rotation).
    All operations are -WhatIf safe.
.PARAMETER KeyType
    Which key type to rotate: CodingKeys, Browserless, Tavily, Firecrawl, All
.PARAMETER WhatIf
    Show what would change without making changes.
#>

param(
    [ValidateSet('CodingKeys', 'Browserless', 'Tavily', 'Firecrawl', 'All')]
    [string]$KeyType = 'All',
    [switch]$WhatIf
)

# ── Rotation Plan ──────────────────────────────────────────────────────────
# Key Type         | AWS SM Secret Name                        | Rotation | Method
# -----------------|--------------------------------------------|----------|-------------------------------
# Coding Keys G1-5 | opencode/coding-keys/go-key-{1..5}        | Auto     | crypto random 48 hex
# Browserless      | Interclaw/FRAD/Provisioning (BROWSERLESS.) | Manual   | Vendor-generated token
# Tavily           | Interclaw/FRAD/Provisioning (TAVILY*)      | Manual   | Vendor-generated API key
# Firecrawl        | Interclaw/FRAD/Provisioning (FIRECRAWL*)   | Manual   | Vendor-generated API key

$LogDir = Join-Path $PWD "Tasks" "Logs"
$null = New-Item -ItemType Directory -Path $LogDir -Force

function Write-RotationLog {
    param([string]$Message, [string]$Level = "INFO")
    $entry = [PSCustomObject]@{
        Timestamp = (Get-Date -Format 'o')
        Level     = $Level
        Message   = $Message
    }
    $entryJson = $entry | ConvertTo-Json -Compress
    Add-Content -Path (Join-Path $LogDir "key-rotation.log") -Value $entryJson -Encoding utf8
    Write-Host "[$Level] $Message"
}

function Get-AwsSecretObject {
    param([string]$SecretId)
    $profile = $env:AWS_SSO_PROFILE ?? 'interclaw'
    $region = $env:AWS_SECRETS_REGION ?? 'ca-central-1'
    $raw = aws secretsmanager get-secret-value `
        --secret-id $SecretId `
        --profile $profile `
        --region $region `
        --query SecretString `
        --output text
    return $raw | ConvertFrom-Json
}

function Update-AwsSecret {
    param([string]$SecretId, [object]$SecretObject)
    $profile = $env:AWS_SSO_PROFILE ?? 'interclaw'
    $region = $env:AWS_SECRETS_REGION ?? 'ca-central-1'
    $json = $SecretObject | ConvertTo-Json -Compress
    aws secretsmanager put-secret-value `
        --secret-id $SecretId `
        --secret-string $json `
        --profile $profile `
        --region $region
}

# ── Coding Keys ────────────────────────────────────────────────────────────

function Invoke-RotateCodingKeys {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    Write-RotationLog "Rotating Coding Keys..."

    for ($i = 1; $i -le 5; $i++) {
        $secretName = "opencode/coding-keys/go-key-$i"
        $newKey = New-CryptographicToken -ByteCount 48

        if ($PSCmdlet.ShouldProcess($secretName, "Rotate coding key G$i")) {
            $existing = Get-AwsSecretObject -SecretId $secretName -ErrorAction SilentlyContinue
            $secretObj = if ($existing) { $existing } else { @{} }
            $secretObj | Add-Member -NotePropertyName "opencode_go_key$i" -NotePropertyValue $newKey -Force
            Update-AwsSecret -SecretId $secretName -SecretObject $secretObj
            Write-RotationLog "Coding key G$i rotated" -Level "INFO"
        } else {
            Write-Host "  [WHATIF] Would rotate coding key G$i → new 48-char hex key"
        }
    }
}

# ── Vendor API Keys ───────────────────────────────────────────────────────

function Invoke-RotateVendorKey {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$KeyName,
        [string]$DisplayName,
        [string]$SecretId = "Interclaw/FRAD/Provisioning"
    )
    Write-RotationLog "Rotating $DisplayName..."

    if ($PSCmdlet.ShouldProcess($SecretId, "Rotate $DisplayName")) {
        Write-RotationLog "${DisplayName}: Manual rotation required — update key in AWS SM ${SecretId}" -Level "WARN"
        Write-Host "  [MANUAL] $DisplayName is vendor-issued. To rotate:"
        Write-Host "    1. Generate new key at vendor dashboard"
        Write-Host "    2. Update AWS SM secret '$SecretId' key '$KeyName'"
        Write-Host "    3. Redeploy fleet or restart affected services"
    } else {
        Write-Host "  [WHATIF] Would mark $DisplayName for manual rotation"
    }
}

# ── Main ───────────────────────────────────────────────────────────────────

switch ($KeyType) {
    'CodingKeys' { Invoke-RotateCodingKeys -WhatIf:$WhatIf }
    'Browserless' { Invoke-RotateVendorKey -KeyName "BROWSERLESS_API_KEY" -DisplayName "Browserless Token" -WhatIf:$WhatIf }
    'Tavily' { Invoke-RotateVendorKey -KeyName "TAVILY_API_KEY" -DisplayName "Tavily API Key" -WhatIf:$WhatIf }
    'Firecrawl' { Invoke-RotateVendorKey -KeyName "FIRECRAWL_API_KEY" -DisplayName "Firecrawl API Key" -WhatIf:$WhatIf }
    'All' {
        Invoke-RotateCodingKeys -WhatIf:$WhatIf
        Invoke-RotateVendorKey -KeyName "BROWSERLESS_API_KEY" -DisplayName "Browserless Token" -WhatIf:$WhatIf
        Invoke-RotateVendorKey -KeyName "TAVILY_API_KEY" -DisplayName "Tavily API Key" -WhatIf:$WhatIf
        Invoke-RotateVendorKey -KeyName "FIRECRAWL_API_KEY" -DisplayName "Firecrawl API Key" -WhatIf:$WhatIf
    }
}

Write-RotationLog "Rotation complete for $KeyType" -Level "INFO"
