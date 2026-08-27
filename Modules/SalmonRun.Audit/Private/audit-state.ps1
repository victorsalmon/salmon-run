$script:AuditRoot = if ($env:SALMON_RUN_AUDIT_ROOT) { $env:SALMON_RUN_AUDIT_ROOT } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.salmon/audit' }

$maxSizeMb = if ($env:SALMON_RUN_AUDIT_MAX_SIZE_MB) { [int]$env:SALMON_RUN_AUDIT_MAX_SIZE_MB } else { 100 }
$script:AuditMaxSizeBytes = $maxSizeMb * 1MB
$maxRotated = if ($env:SALMON_RUN_AUDIT_MAX_ROTATED) { [int]$env:SALMON_RUN_AUDIT_MAX_ROTATED } else { 5 }
$script:AuditMaxRotatedFiles = $maxRotated

$script:SecretPatterns = @{
    Headers   = @('Authorization', '*api_key*', '*secret*', '*token*', '*password*')
    BodyFields = @('api_key', 'client_secret', 'client_id', 'refresh_token', 'access_token')
    ContentPatterns = @(
        # AWS access key (AKIA...)
        '(?i)\bAKIA[0-9A-Z]{16}\b',
        # OpenRouter API key
        '(?i)\bsk-or-v1-[a-zA-Z0-9]{24,}\b',
        # Zoho refresh token (1000.hex...)
        '(?i)\b1000\.[a-f0-9]{32,}\b',
        # Zoho client ID (1000.ALPHANUM...)
        '(?i)\b1000\.[A-Z0-9]{10,}\b',
        # Generic bearer/auth token in value position
        '(?i)(?:Zoho-oauthtoken|Bearer)\s+[a-zA-Z0-9._-]{20,}',
        # GitHub token (ghp_ or gho_ or github_pat_)
        '(?i)\b(ghp_|gho_|github_pat_)[a-zA-Z0-9]{36,}\b',
        # OpenAI / OpenRouter key prefix
        '(?i)\bsk-[a-zA-Z0-9]{20,}\b'
    )
}
