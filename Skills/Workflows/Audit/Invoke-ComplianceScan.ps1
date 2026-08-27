<#
.SYNOPSIS
    Hermetic grep/Select-String pre-scan for the Compliance Audit (Phase 0).
    Surfaces raw compliance signals (region strings, encryption flags, PII in
    logs, secret literals, DSAR handlers, tenant-isolation markers, auth
    presence, breach-notification code) that the per-standard survey then
    reasons about.

.DESCRIPTION
    Walks a repo (respecting -ExcludeDirs and .gitignore) over a defined file
    set and emits JSON findings. Hermetic by design: no network, no external
    modules - only Get-ChildItem / Select-String / ConvertTo-Json.

    Output shape (written to -OutputFile):
        { date, repoRoot, categories: { <name>: [ findings ] } }
    where each finding is:
        { file, line, pattern, category, severity, standard }

    Findings are informational - severity gating happens in Phase C of the
    Compliance Audit. Exit code 0 on success (findings are NOT failures);
    exit 1 only on engine error.

    Secret literals are reported as file:line + pattern name only. Secret
    values are NEVER written into the scan output (cross-repo no-leak rule).

.PARAMETER RepoRoot
    Repository root to scan. Defaults to ".".

.PARAMETER OutputFile
    Path to write JSON results. Default: <RepoRoot>/Tasks/Logs/compliance-scan-<date>.json

.PARAMETER ExcludeDirs
    Directory names to skip. Default: node_modules, .git, dist, build, _site, .next, tmp

.EXAMPLE
    .\Invoke-ComplianceScan.ps1 -RepoRoot C:/repos/currents-bookkeeping
.EXAMPLE
    .\Invoke-ComplianceScan.ps1 -RepoRoot . -OutputFile "$env:TEMP/compliance-scan.json"
.NOTES
    Aligns the hardcoded_secrets category with the taxonomy in
    docs/Security/fleet-secret-inventory-2026-07-26.md (credential /
    placeholder / example / false-positive) and the standard field values
    with the native engine enums in
    C:/Repos/currents-bookkeeping/scripts/compliance-audit/types.mjs.
#>

[CmdletBinding()]
param(
    [string]$RepoRoot = ".",
    [string]$OutputFile = "",
    [string[]]$ExcludeDirs = @('node_modules', '.git', 'dist', 'build', '_site', '.next', 'tmp')
)

$ErrorActionPreference = "Stop"

try {
    $root = (Resolve-Path $RepoRoot -ErrorAction Stop).Path

    if (-not $OutputFile) {
        $today = Get-Date -Format "yyyy-MM-dd"
        $OutputFile = Join-Path $root "Tasks\Logs\compliance-scan-$today.json"
    }

    # ------------------------------------------------------------------
    # File discovery (hermetic walk; exclude dirs + .gitignore respected)
    # ------------------------------------------------------------------
    $includeExts = @('.ts', '.tsx', '.js', '.mjs', '.tf', '.yaml', '.yml', '.json', '.ps1', '.py', '.sql')

    $gitignorePatterns = @()
    $gitignorePath = Join-Path $root ".gitignore"
    if (Test-Path -LiteralPath $gitignorePath -PathType Leaf) {
        $gitignorePatterns = @(Get-Content -LiteralPath $gitignorePath |
            Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') })
    }

    function Test-GitIgnoredPath {
        param([string]$RelPath, [string[]]$Patterns)
        foreach ($p in $Patterns) {
            $p = $p.Trim()
            $negated = $p.StartsWith('!')
            if ($negated) { $p = $p.Substring(1) }
            $p = $p.TrimStart('/')
            $dirOnly = $p.EndsWith('/')
            $p = $p.TrimEnd('/')
            $matched = $false
            if ($dirOnly) {
                $matched = ($RelPath -eq $p) -or ($RelPath -like "$p/*") -or ($RelPath -like "*/$p/*")
            } else {
                $matched = ($RelPath -eq $p) -or ($RelPath -like "$p/*") -or ($RelPath -like "*/$p") -or ($RelPath -like "*/$p/*")
            }
            if ($matched) {
                if ($negated) { return $false }
                return $true
            }
        }
        return $false
    }

    $scannable = @()
    $allFiles = @(Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue)
    foreach ($f in $allFiles) {
        $rel = $f.FullName.Substring($root.Length).TrimStart('\', '/')
        $segments = $rel -split '[\\/]'
        $excluded = $false
        foreach ($seg in $segments) {
            if ($ExcludeDirs -contains $seg) { $excluded = $true; break }
        }
        if ($excluded) { continue }
        if (Test-GitIgnoredPath -RelPath $rel -Patterns $gitignorePatterns) { continue }
        if ($f.Name -eq 'template.yaml' -or $f.Name -like '*.template') {
            $scannable += [pscustomobject]@{ FullName = $f.FullName; Rel = $rel; Name = $f.Name; Ext = $f.Extension }
            continue
        }
        if ($includeExts -contains $f.Extension.ToLower()) {
            $scannable += [pscustomobject]@{ FullName = $f.FullName; Rel = $rel; Name = $f.Name; Ext = $f.Extension }
        }
    }

    # ------------------------------------------------------------------
    # Category scanners
    # ------------------------------------------------------------------
    $categories = [ordered]@{
        regions              = @()
        encryption_at_rest   = @()
        pii_in_logs          = @()
        dsar_deletion        = @()
        hardcoded_secrets    = @()
        tenant_isolation     = @()
        access_auth          = @()
        breach_notification  = @()
    }

    $stdSovereignty = 'canadian_data_sovereignty'
    $stdSoc2        = 'soc2|iso_27001'
    $stdPii         = 'pipeda|gdpr|hipaa'
    $stdDsar        = 'gdpr|pipeda'
    $stdSecrets     = 'soc2|iso_27001|pipeda'
    $stdTenant      = 'soc2|iso_27001'
    $stdAuth        = 'soc2|iso_27001|hipaa'
    $stdBreach      = 'pipeda|gdpr|hipaa'
    $stdEncrypt     = 'soc2|iso_27001|hipaa'

    function Add-Finding {
        param([string]$Category, [string]$File, [int]$Line, [string]$Pattern, [string]$Severity, [string]$Standard)
        $categories[$Category] += [pscustomobject]@{
            file     = $File
            line     = $Line
            pattern  = $Pattern
            category = $Category
            severity = $Severity
            standard = $Standard
        }
    }

    # -- regions: any AWS region other than ca-central-1 in IaC/config files.
    #    SOV-1 contract (compliance-audit.md): grep all IaC
    #    (backend/cdk/**/*.ts, **/*.tf, **/template.yaml) for AWS region strings
    $regionPattern = '\b(us-east-1|us-east-2|us-west-1|us-west-2|eu-west-1|eu-central-1|ap-[a-z0-9-]+|sa-east-1)\b'
    foreach ($f in $scannable | Where-Object { $_.Ext -in @('.ts', '.tsx', '.tf', '.yaml', '.yml', '.json', '.template') -or $_.Name -eq 'template.yaml' }) {
        $hits = @(Select-String -LiteralPath $f.FullName -Pattern $regionPattern -AllMatches)
        foreach ($m in $hits) {
            if ($m.Line -match 'ca-central-1') { continue }
            Add-Finding -Category 'regions' -File $f.Rel -Line $m.LineNumber `
                -Pattern 'non-ca-central-1 AWS region' -Severity 'high' -Standard $stdSovereignty
        }
    }

    # -- encryption_at_rest: positive markers + negative PII-resource findings
    $encPattern = '\b(encryption|Encrypted|SSE|KMS|deletionProtection|StorageEncrypted)\b'
    $piiColPattern = '\b(sin|ssn|dob|dateOfBirth|passport|idNumber|health_card|phi|email)\b'
    $resPattern = '(aws_db_instance|aws_s3_bucket|aws_dynamodb_table|create table|CREATE TABLE|dynamodb|StorageEncrypted|RdsInstance|Database)'
    foreach ($f in $scannable | Where-Object { $_.Ext -in @('.ts', '.tsx', '.js', '.mjs', '.ps1', '.py', '.sql', '.tf', '.yaml', '.yml', '.json') -or $_.Name -eq 'template.yaml' }) {
        $encHits = @(Select-String -LiteralPath $f.FullName -Pattern $encPattern -AllMatches)
        foreach ($m in $encHits) {
            Add-Finding -Category 'encryption_at_rest' -File $f.Rel -Line $m.LineNumber `
                -Pattern 'encryption-at-rest marker present' -Severity 'info' -Standard $stdEncrypt
        }
        $resHit = @(Select-String -LiteralPath $f.FullName -Pattern $resPattern -AllMatches)
        if ($resHit.Count -gt 0) {
            $hasPii = @(Select-String -LiteralPath $f.FullName -Pattern $piiColPattern -AllMatches)
            if ($hasPii.Count -gt 0 -and $encHits.Count -eq 0) {
                Add-Finding -Category 'encryption_at_rest' -File $f.Rel -Line $resHit[0].LineNumber `
                    -Pattern 'PII-bearing resource without encryption-at-rest marker' -Severity 'high' -Standard $stdEncrypt
            }
        }
    }

    # -- pii_in_logs: log/console calls referencing PII field names
    $logCallPattern = '(console\.|logger\.|Write-Host|Log\.|printf\()'
    foreach ($f in $scannable | Where-Object { $_.Ext -in @('.ts', '.tsx', '.js', '.mjs', '.ps1', '.py') }) {
        $hits = @(Select-String -LiteralPath $f.FullName -Pattern '\b(sin|dob|dateOfBirth|passport|idNumber|health_card|phi)\b' -AllMatches)
        foreach ($m in $hits) {
            if ($m.Line -match $logCallPattern) {
                Add-Finding -Category 'pii_in_logs' -File $f.Rel -Line $m.LineNumber `
                    -Pattern 'PII field referenced by log call' -Severity 'high' -Standard $stdPii
            }
        }
    }

    # -- dsar_deletion: positive handler signals (absence is a Phase A gap)
    $dsarPattern = '(deletion_queue|sendDeletion\w*|rightToBeForgotten|erasure)'
    foreach ($f in $scannable) {
        $hits = @(Select-String -LiteralPath $f.FullName -Pattern $dsarPattern -AllMatches)
        foreach ($m in $hits) {
            Add-Finding -Category 'dsar_deletion' -File $f.Rel -Line $m.LineNumber `
                -Pattern 'DSAR deletion handler present' -Severity 'info' -Standard $stdDsar
        }
    }

    # -- hardcoded_secrets: literals; file:line + pattern only, never values
    $awsHome = Join-Path $HOME '.aws'
    $secretSets = @(
        @{ Name = 'AKIA access key literal';        Pattern = 'AKIA[0-9A-Z]{16}';                     Severity = 'critical' },
        @{ Name = 'OpenAI-style secret literal';    Pattern = 'sk-[A-Za-z0-9_-]{20,}';                 Severity = 'high' },
        @{ Name = 'GitHub PAT literal';             Pattern = 'ghp_[A-Za-z0-9]{30,}';                  Severity = 'high' },
        @{ Name = 'Slack token literal';            Pattern = 'xox[baprs]-[A-Za-z0-9-]{10,}';          Severity = 'high' },
        @{ Name = 'generic key assignment';         Pattern = '(api[_-]?key|secret|client[_-]?secret|token)\s*[:=]\s*["'']+[A-Za-z0-9+/=_\-]{16,}["'']+'; Severity = 'medium' }
    )
    foreach ($f in $scannable) {
        if ($f.FullName -like "$awsHome/*" -or $f.FullName -eq $awsHome) { continue }
        foreach ($s in $secretSets) {
            $hits = @(Select-String -LiteralPath $f.FullName -Pattern $s.Pattern -AllMatches)
            foreach ($m in $hits) {
                if ($s.Severity -eq 'medium' -and $m.Line -match '(example|placeholder|dummy|your_)') { continue }
                Add-Finding -Category 'hardcoded_secrets' -File $f.Rel -Line $m.LineNumber `
                    -Pattern $s.Name -Severity $s.Severity -Standard $stdSecrets
            }
        }
    }

    # -- tenant_isolation: tenant-scoped tables missing org/tenant key; RLS presence
    $tablePattern = '(create table|CREATE TABLE|CREATE TABLE IF NOT EXISTS|type\s+\w+\s+(table|struct)\b)'
    $tenantKeyPattern = '\b(org_id|tenant_id)\b'
    $rlsPattern = '\b(rls|row level security)\b'
    foreach ($f in $scannable | Where-Object { $_.Ext -in @('.ts', '.tsx', '.js', '.mjs', '.py', '.ps1', '.sql') }) {
        $tables = @(Select-String -LiteralPath $f.FullName -Pattern $tablePattern -AllMatches)
        if ($tables.Count -gt 0) {
            $hasTenantKey = @(Select-String -LiteralPath $f.FullName -Pattern $tenantKeyPattern -AllMatches)
            if ($hasTenantKey.Count -eq 0) {
                Add-Finding -Category 'tenant_isolation' -File $f.Rel -Line $tables[0].LineNumber `
                    -Pattern 'tenant-scoped table without org_id/tenant_id' -Severity 'medium' -Standard $stdTenant
            }
        }
        $rlsHits = @(Select-String -LiteralPath $f.FullName -Pattern $rlsPattern -AllMatches)
        foreach ($m in $rlsHits) {
            Add-Finding -Category 'tenant_isolation' -File $f.Rel -Line $m.LineNumber `
                -Pattern 'RLS policy marker present' -Severity 'info' -Standard $stdTenant
        }
    }

    # -- access_auth: data-access routes with no visible auth guard on the line
    $routePattern = '(app|router|server|fastify|express)\.(get|post|put|patch|delete)\s*\(|@(Get|Post|Put|Patch|Delete)\b|Route::(get|post|resource|any)'
    $authMarkerPattern = '\b(auth|requireUser|assertAuthenticated|middleware|guard|isAuthenticated|protect)\b'
    foreach ($f in $scannable | Where-Object { $_.Ext -in @('.ts', '.tsx', '.js', '.mjs', '.py', '.ps1') }) {
        $hits = @(Select-String -LiteralPath $f.FullName -Pattern $routePattern -AllMatches)
        foreach ($m in $hits) {
            if ($m.Line -notmatch $authMarkerPattern) {
                Add-Finding -Category 'access_auth' -File $f.Rel -Line $m.LineNumber `
                    -Pattern 'data-access route without visible auth guard' -Severity 'medium' -Standard $stdAuth
            }
        }
    }

    # -- breach_notification: WATCH category; fully-automated sendBreach is a finding
    $breachPattern = 'sendBreach\w*'
    foreach ($f in $scannable) {
        $hits = @(Select-String -LiteralPath $f.FullName -Pattern $breachPattern -AllMatches)
        foreach ($m in $hits) {
            if ($m.Line -match 'sendBreach\w*\s*\(' -and $m.Line -notmatch '(manual|requires|TODO|FIXME|human)') {
                Add-Finding -Category 'breach_notification' -File $f.Rel -Line $m.LineNumber `
                    -Pattern 'fully-automated breach notification call' -Severity 'high' -Standard $stdBreach
            } else {
                Add-Finding -Category 'breach_notification' -File $f.Rel -Line $m.LineNumber `
                    -Pattern 'breach notification code present (watch)' -Severity 'info' -Standard $stdBreach
            }
        }
    }

    # ------------------------------------------------------------------
    # Emit
    # ------------------------------------------------------------------
    $result = [ordered]@{
        date       = Get-Date -Format "yyyy-MM-dd"
        repoRoot   = $root
        categories = $categories
    }
    $json = $result | ConvertTo-Json -Depth 6

    $outDir = Split-Path -Parent $OutputFile
    if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
        $null = New-Item -ItemType Directory -Path $outDir -Force
    }
    $json | Set-Content -LiteralPath $OutputFile -Encoding utf8

    $totalFindings = 0
    $catCount = 0
    foreach ($entry in $categories.GetEnumerator()) {
        if ($entry.Value.Count -gt 0) { $catCount++ }
        $totalFindings += $entry.Value.Count
    }
    Write-Host "Compliance scan: $totalFindings findings across $catCount categories -> $OutputFile"
    exit 0
}
catch {
    Write-Error "Compliance scan engine error: $_"
    exit 1
}
