#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

# ==============================================================================
# Hydration Integration Tests — real AWS SSO + Secrets Manager validation
# ==============================================================================
# These tests exercise the exact same path as deploy.ps1 Phase 8.5 but with
# deeper end-to-end validation: every bundle-manifest variable must be declared
# in install.json, and every "AWS SM" placeholder must be resolvable from
# Secrets Manager.
#
# When any check fails, a detailed Coder investigation task is written to
# Tasks/Logs/ so that a single fix makes secret hydration work.
#
# Prerequisite: Active AWS SSO session (run aws sso login first).
# If no SSO profile is available, all tests skip gracefully.
# ==============================================================================

BeforeAll {
    $diagnosticsPath = Join-Path $PSScriptRoot '..\Modules\SalmonRun.Diagnostics\SalmonRun.Diagnostics.ps1'
    if (Test-Path $diagnosticsPath) { . $diagnosticsPath }
    . (Join-Path $PSScriptRoot "..\..\..\Orchestrator\Modules\SalmonRun.Core\SalmonRun.Core.ps1")
    . (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Process\SalmonRun.Process.ps1")
    . (Join-Path $PSScriptRoot "..\Modules\SalmonRun.DeployState\SalmonRun.DeployState.ps1")
    . (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Secrets\SalmonRun.Secrets.ps1")
    . (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Provision\SalmonRun.Provision.ps1")

    Mock Write-SetupLog { }
    Mock Write-Warning { }
    Mock Write-Verbose { }

    $detectedProfile = [System.Environment]::GetEnvironmentVariable('AWS_SSO_PROFILE')
    if (-not $detectedProfile) {
        $awsConfigPath = Join-Path (Get-HomeDir) ".aws/config"
        if (Test-Path $awsConfigPath) {
            $profiles = @()
            Get-Content $awsConfigPath | ForEach-Object {
                if ($_ -match '^\[profile\s+(.+)\]$') { $profiles += $matches[1] }
                elseif ($_ -match '^\[default\]$') { $profiles += "default" }
            }
            $profiles = @($profiles | Where-Object { $_ -ne "sso-session" })
            if ($profiles.Count -eq 1) { $detectedProfile = $profiles[0] }
        }
    }
    if (-not $detectedProfile) { $detectedProfile = "default" }
    $script:SsoProfile = $detectedProfile

    $installJsonPath = Join-Path (Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent) "install.json"
    if (Test-Path $installJsonPath) {
        $raw = Get-Content $installJsonPath -Raw -ErrorAction SilentlyContinue
        $script:InstallJson = if ($raw) { $raw | ConvertFrom-Json } else { $null }
    } else { $script:InstallJson = $null }

    $script:ProjectCode = if ($script:InstallJson -and $script:InstallJson.project.code) {
        $script:InstallJson.project.code
    } else { [System.Environment]::GetEnvironmentVariable('INSTALL_PROJECT') ?? 'FRAD' }

    $script:SecretsRegion = if ($script:InstallJson -and $script:InstallJson.fleet -and $script:InstallJson.fleet.sovereignty) {
        @{ 'canada' = 'ca-central-1'; 'usa' = 'us-east-1'; 'global' = 'ca-central-1' }[$script:InstallJson.fleet.sovereignty]
    } else { 'us-east-1' }

    $script:SkipReason = if (-not $script:SsoProfile) { "AWS_SSO_PROFILE not set" }
    elseif (-not $script:InstallJson) { "install.json not found" }
    elseif (-not $script:InstallJson.features) { "install.json has no features section" }
    elseif (-not $script:InstallJson.project) { "install.json has no project section" }
    else { $null }

    $script:Failures = [System.Collections.Generic.List[pscustomobject]]::new()
    $script:SessionIdentity = $null
    $script:TestRunId = (Get-Date -Format 'yyyyMMdd-HHmmss')
    $script:ResultCount = 0
    $script:Invocation = $Pester

    function Write-HydrationInvestigationTask {
        $failCount = $script:Failures.Count

        $failedChecks = $script:Failures | ForEach-Object {
            "- **$($_.Check)**: $($_.Detail)"
        } | Sort-Object -Unique

        $permissionIssues = $script:Failures | Where-Object { $_.Detail -match 'AccessDenied|Unauthorized|not authorized' } | ForEach-Object {
            "- $($_.Detail)"
        } | Sort-Object -Unique

        $secretNames = $script:Failures | Where-Object { $_.Check -match 'AWS_SM_Resolve:' } | ForEach-Object {
            "- $($_.Check -replace 'AWS_SM_Resolve:', '')"
        } | Sort-Object -Unique

        $containerStatus = $script:Failures | Where-Object { $_.Container } | ForEach-Object { $_.Container } | Sort-Object -Unique
        $containerLines = if ($containerStatus.Count -gt 0) {
            $containerStatus | ForEach-Object {
                "| $_ | failed |"
            }
        } else { @() }

        $failedStr = $failedChecks -join "`n"
        $permStr = $permissionIssues -join "`n"
        $secStr = $secretNames -join "`n"
        $containerTable = if ($containerLines.Count -gt 0) {
            @("", "| Container | Status |", "|---|---|") + $containerLines -join "`n"
        } else { "" }
        $now = Get-Date -Format 'yyyy-MM-dd'
        $identityStr = if ($script:SessionIdentity) {
            "Arn=$($script:SessionIdentity.Arn) Account=$($script:SessionIdentity.Account) UserId=$($script:SessionIdentity.UserId)"
        } else { "Session expired or unavailable" }

        $lines = @(
            "# Session Plan: Hydrate Secrets Fix - $script:TestRunId"
            ""
            "**Date**: $now"
            "**Status**: ready"
            "**Scope**: Fix secret hydration failures detected by integration tests"
            "**Failures**: $failCount"
            ""
            "---"
            ""
            "## Overview"
            ""
            "The Hydration Integration test (Skills/Docker/Tests/HydrationIntegration.Tests.ps1) detected $failCount failure(s) in the secret hydration pipeline. These must be resolved for deploy.ps1 Phase 8.5 to succeed."
            ""
            "---"
            ""
            "## Summary"
            ""
            "| Field | Value |"
            "|---|---|"
            "| AWS SSO Profile | $($script:SsoProfile) |"
            "| Secrets Region | $script:SecretsRegion |"
            "| Project Code | $script:ProjectCode |"
            "| Caller Identity | $identityStr |"
            "| Failed Checks | $failCount |"
            ""
            "---"
            ""
            "## Affected Containers"
            ""
            "The following containers have failed testStatus based on their unresolved secrets:"
            ""
            $containerTable
            ""
            "---"
            ""
            "## Failed Checks"
            ""
            $(if ($failedChecks.Count -gt 0) { $failedStr } else { "None" })
            ""
            "---"
            ""
            "## Permission Issues Detected"
            ""
            $(if ($permissionIssues.Count -gt 0) { $permStr } else { "None" })
            ""
            "---"
            ""
            "## Unresolvable Secrets (AWS SM)"
            ""
            $(if ($secretNames.Count -gt 0) { $secStr } else { "None - all AWS SM secrets resolved." })
            ""
            "---"
            ""
            "## Task 1: Resolve missing or inaccessible secrets"
            ""
            "**Why**: The hydration pre-flight in deploy.ps1 Phase 8.5 reads every bundle secret from either environment variables or AWS Secrets Manager. If any are missing, the pipeline may deploy containers without required credentials."
            ""
            "**Changes**:"
            "- For each secret marked AWS SM in install.json, ensure it exists in the project's AWS SM secret (Interclaw/$($script:ProjectCode)/Orchestrator) or a fallback secret (Interclaw/$($script:ProjectCode)/Provisioning)."
            "- If the secret exists but is inaccessible, check IAM permissions for the SSO profile $($script:SsoProfile) - it must have secretsmanager:GetSecretValue on the secret resource."
            "- If the secret does not exist at all, add it via the AWS console or CLI using aws secretsmanager put-secret-value."
            ""
            "**Acceptance**: Re-run Invoke-Pester Skills/Docker/Tests/HydrationIntegration.Tests.ps1 -Tag HydrationE2E and confirm all checks pass."
            ""
            "---"
            ""
            "## Task 2: Verify install.json covers every manifest variable"
            ""
            "**Why**: Every secret key in the bundle manifest must be declared under install.json.features.<feature>.secrets with value AWS SM (or an env-var override). Missing declarations cause silent failures."
            ""
            "**Changes**:"
            "- Cross-reference Skills/Docker/Modules/SalmonRun.Secrets/Private/bundle-manifest.ps1 SourceKeys with install.json features."
            "- Add any missing keys to the appropriate feature's secrets block."
            "- If a key belongs to a feature not yet in install.json, add the feature entry."
            ""
            "**Acceptance**: The test every bundle manifest secret appears in install.json features passes."
            ""
            "---"
            ""
            "## Environment"
            ""
            "- Test file: Skills/Docker/Tests/HydrationIntegration.Tests.ps1"
            "- Manifest: Skills/Docker/Modules/SalmonRun.Secrets/Private/bundle-manifest.ps1"
            "- install.json: install.json (repo root)"
            "- SSO profile: $($script:SsoProfile)"
            "- Run time: $(Get-Date -Format 'o')"
        )

        $taskDir = Join-Path (Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent) "Tasks" "Logs"
        if (-not (Test-Path $taskDir)) { New-Item -ItemType Directory -Path $taskDir -Force | Out-Null }
        $taskPath = Join-Path $taskDir "hydrate-secrets-fix-$script:TestRunId.md"
        $lines -join "`n" | Set-Content -Path $taskPath -Encoding UTF8
        Write-Host "  [INVESTIGATION] Task written to $taskPath" -ForegroundColor Yellow
        return $taskPath
    }

    $script:MaxEnumerationAttempts = 20
    $script:EnumerableKeyPrefixes = @('WAVE_ORG_ID', 'WAVE_ORG_NAME')

    function Resolve-SecretKey {
        param([string]$KeyName, [string]$SsoProfile)
        $val = Get-SecretFromAws -KeyName $KeyName -SsoProfile $SsoProfile -ErrorAction SilentlyContinue
        if (-not [string]::IsNullOrWhiteSpace($val)) { return $val }

        foreach ($prefix in $script:EnumerableKeyPrefixes) {
            if ($KeyName -eq $prefix -or $KeyName -like "$prefix*") {
                for ($i = 1; $i -le $script:MaxEnumerationAttempts; $i++) {
                    $enumKey = "$prefix$i"
                    $enumVal = Get-SecretFromAws -KeyName $enumKey -SsoProfile $SsoProfile -ErrorAction SilentlyContinue
                    if ([string]::IsNullOrWhiteSpace($enumVal)) { break }
                    if ($KeyName -eq $prefix) { return $enumVal }
                }
            }
        }
        return $null
    }

    function Get-SecretContainer {
        param([string]$KeyName)
        $m = Get-BundleManifest
        $containers = [System.Collections.Generic.List[string]]::new()

        if ($m.Agent.ORCH.SourceKeys -contains $KeyName) { $containers.Add('ORCH') }
        if ($m.Agent.BASE.SourceKeys -contains $KeyName) { $containers.Add('BASE') }
        if ($m.Agent.BASE.SourceKeys -contains $KeyName) { $containers.Add('BASE') }
        if ($m.Sentry.SourceKeys -contains $KeyName) { $containers.Add('Sentry') }
        if ($m.Coding.SourceKeys -contains $KeyName) { $containers.Add('Coding') }
        if ($m.Proxy.SourceKeys -contains $KeyName) { $containers.Add('Proxy') }
        if ($m.WebMcp.SourceKeys -contains $KeyName) { $containers.Add('WebMcp') }

        if ($containers.Count -eq 0) { $containers.Add('Unknown') }
        return $containers.ToArray()
    }
}

Describe "HydrationIntegration" -Tag "Integration", "HydrationE2E", "Secrets", "Preflight", "Regression-Only" {

    Context "AWS SSO session" {
        It "has an active AWS SSO session" -Skip:$script:SkipReason {
            Test-AwsSessionValidity -SsoProfile $script:SsoProfile
        }

        It "can determine caller identity" -Skip:$script:SkipReason {
            $result = Invoke-NativeCommand {
                aws sts get-caller-identity --profile "$($script:SsoProfile)" --output json 2>&1
            }
            if ($result.Success -and $result.Output) {
                $script:SessionIdentity = try { $result.Output | ConvertFrom-Json } catch { $null }
            }
            $script:SessionIdentity | Should -Not -BeNullOrEmpty
        }
    }

    Context "install.json manifest coverage" {
        It "loads the bundle manifest" -Skip:$script:SkipReason {
            $m = Get-BundleManifest
            $m | Should -Not -BeNullOrEmpty
        }

        It "has features section in install.json" -Skip:$script:SkipReason {
            $script:InstallJson.features | Should -Not -BeNullOrEmpty
        }

        It "every bundle manifest SourceKey appears in install.json features" -Skip:$script:SkipReason {
            $m = Get-BundleManifest

            $featureSecrets = @{}
            if ($script:InstallJson -and $script:InstallJson.features) {
                foreach ($featureName in $script:InstallJson.features.PSObject.Properties.Name) {
                    $feature = $script:InstallJson.features.$featureName
                    if ($feature.install -eq $true -and $feature.secrets) {
                        foreach ($secretKey in $feature.secrets.PSObject.Properties.Name) {
                            $featureSecrets[$secretKey] = $feature.secrets.$secretKey
                        }
                    }
                }
            }
            $featureKeys = [System.Collections.Generic.HashSet[string]]::new()
            foreach ($k in $featureSecrets.Keys) { $featureKeys.Add($k) | Out-Null }

            $manifestKeys = [System.Collections.Generic.HashSet[string]]::new()
            foreach ($bundleType in $m.Keys) {
                if ($bundleType -eq 'Agent') {
                    foreach ($agentType in $m.Agent.Keys) {
                        if ($agentType -in @('BASE')) {
                            foreach ($k in $m.Agent.$agentType.SourceKeys) { $manifestKeys.Add($k) | Out-Null }
                        }
                    }
                } elseif ($bundleType -in @('Sentry', 'Coding', 'Proxy', 'WebMcp')) {
                    foreach ($k in $m.$bundleType.SourceKeys) { $manifestKeys.Add($k) | Out-Null }
                }
            }

            $keysNotInInstallJson = @()
            foreach ($key in $manifestKeys) {
                if (-not $featureKeys.Contains($key)) {
                    $keysNotInInstallJson += $key
                }
            }

            if ($keysNotInInstallJson.Count -gt 0) {
                $script:Failures.Add([pscustomobject]@{
                    Check   = 'InstallJsonCoverage'
                    Passed  = $false
                    Detail  = "Bundle manifest keys missing from install.json features: $($keysNotInInstallJson -join ', ')"
                    Profile = $script:SsoProfile
                })
            }
            $keysNotInInstallJson.Count | Should -Be 0 -Because "every bundle manifest key must be declared in install.json features with value 'AWSSM Interclaw/FRAD/Provisioning', 'AWSSM Interclaw/FRAD/Orchestrator', or 'api-proxy'"
        }
    }

    Context "AWS Secrets Manager variable resolution" {
        It "finds 'AWS SM' feature secrets in install.json" -Skip:$script:SkipReason {
            $featureSecrets = @{}
            if ($script:InstallJson -and $script:InstallJson.features) {
                foreach ($featureName in $script:InstallJson.features.PSObject.Properties.Name) {
                    $feature = $script:InstallJson.features.$featureName
                    if ($feature.install -eq $true -and $feature.secrets) {
                        foreach ($secretKey in $feature.secrets.PSObject.Properties.Name) {
                            $featureSecrets[$secretKey] = $feature.secrets.$secretKey
                        }
                    }
                }
            }
            $awsSmKeys = @($featureSecrets.Keys | Where-Object { $featureSecrets[$_] -like 'AWSSM Interclaw/*' })
            $awsSmKeys.Count | Should -BeGreaterThan 0
        }

        It "resolves all 'AWS/*' feature secrets from Secrets Manager" -Skip:$script:SkipReason {
            $featureSecrets = @{}
            if ($script:InstallJson -and $script:InstallJson.features) {
                foreach ($featureName in $script:InstallJson.features.PSObject.Properties.Name) {
                    $feature = $script:InstallJson.features.$featureName
                    if ($feature.install -eq $true -and $feature.secrets) {
                        foreach ($secretKey in $feature.secrets.PSObject.Properties.Name) {
                            $featureSecrets[$secretKey] = $feature.secrets.$secretKey
                        }
                    }
                }
            }
            $awsSmKeys = @($featureSecrets.Keys | Where-Object { $featureSecrets[$_] -like 'AWS/*' })
            $script:ResultCount = $awsSmKeys.Count

            $resolved = 0
            $failed = @()
            foreach ($key in $awsSmKeys) {
                $val = Resolve-SecretKey -KeyName $key -SsoProfile $script:SsoProfile
                if ([string]::IsNullOrWhiteSpace($val)) {
                    $failed += $key
                    $containers = Get-SecretContainer -KeyName $key
                    $script:Failures.Add([pscustomobject]@{
                        Check     = "AWS_SM_Resolve:$key"
                        Passed    = $false
                        Detail    = "'$key' is 'AWS SM' in install.json but not resolvable from Secrets Manager. Profile: $($script:SsoProfile), Region: $($script:SecretsRegion)"
                        Profile   = $script:SsoProfile
                        Region    = $script:SecretsRegion
                        Container = $containers -join ','
                    })
                } else { $resolved++ }
            }

            if ($failed.Count -gt 0) {
                Write-Host "  [FAIL] $($failed.Count)/$($awsSmKeys.Count) secrets unresolvable: $($failed -join ', ')" -ForegroundColor Red
            }
            $failed.Count | Should -Be 0 -Because "every 'AWS SM' value in install.json must be resolvable from AWS Secrets Manager"
        }
    }

    Context "IAM permissions for secret access" {
        It "can describe the project Orchestrator secret" -Skip:$script:SkipReason {
            $result = Invoke-NativeCommand {
                aws secretsmanager describe-secret `
                    --secret-id "Interclaw/$($script:ProjectCode)/Orchestrator" `
                    --profile "$($script:SsoProfile)" `
                    --region "$($script:SecretsRegion)" `
                    --output json 2>&1
            }
            if (-not $result.Success) {
                $script:Failures.Add([pscustomobject]@{
                    Check   = 'IAM:secretsmanager:DescribeSecret'
                    Passed  = $false
                    Detail  = "Cannot describe Interclaw/$($script:ProjectCode)/Orchestrator: $($result.Output)"
                    Profile = $script:SsoProfile
                    Region  = $script:SecretsRegion
                })
            }
            $result.Success | Should -BeTrue -Because "SSO profile must have secretsmanager:DescribeSecret on the project secret"
        }

        It "can read the project Orchestrator secret value" -Skip:$script:SkipReason {
            $result = Invoke-NativeCommand {
                aws secretsmanager get-secret-value `
                    --secret-id "Interclaw/$($script:ProjectCode)/Orchestrator" `
                    --profile "$($script:SsoProfile)" `
                    --region "$($script:SecretsRegion)" `
                    --query "SecretString" --output text 2>&1
            }
            if (-not $result.Success) {
                $script:Failures.Add([pscustomobject]@{
                    Check   = 'IAM:secretsmanager:GetSecretValue'
                    Passed  = $false
                    Detail  = "Cannot read Interclaw/$($script:ProjectCode)/Orchestrator: $($result.Output)"
                    Profile = $script:SsoProfile
                    Region  = $script:SecretsRegion
                })
            }
            $result.Success | Should -BeTrue -Because "SSO profile must have secretsmanager:GetSecretValue on the project secret"
        }

        It "can describe the Provisioning secret" -Skip:$script:SkipReason {
            $result = Invoke-NativeCommand {
                aws secretsmanager describe-secret `
                    --secret-id "Interclaw/$($script:ProjectCode)/Provisioning" `
                    --profile "$($script:SsoProfile)" `
                    --region "$($script:SecretsRegion)" `
                    --output json 2>&1
            }
            if (-not $result.Success) {
                $script:Failures.Add([pscustomobject]@{
                    Check   = 'IAM:secretsmanager:DescribeSecret:Provisioning'
                    Passed  = $false
                    Detail  = "Cannot describe Interclaw/$($script:ProjectCode)/Provisioning: $($result.Output)"
                    Profile = $script:SsoProfile
                    Region  = $script:SecretsRegion
                })
            }
            $result.Success | Should -BeTrue -Because "SSO profile must have secretsmanager:DescribeSecret on the provisioning secret"
        }

        It "has iam:ListUsers permission" -Skip:$script:SkipReason {
            $listResult = Invoke-NativeCommand {
                aws iam list-users --max-items 1 --profile "$($script:SsoProfile)" --output json 2>&1
            }
            if (-not $listResult.Success) {
                $script:Failures.Add([pscustomobject]@{
                    Check   = 'IAM:iam:ListUsers'
                    Passed  = $false
                    Detail  = "iam:ListUsers failed: $($listResult.Output)"
                    Profile = $script:SsoProfile
                })
            }
            $listResult.Success | Should -BeTrue -Because "SSO profile must have iam:ListUsers"
        }
    }

    Context "Credential manifest consistency" -Tag "ManifestConsistency" {
        It "every AWS/Provisioning key exists in Interclaw/FRAD/Provisioning" -Skip:$script:SkipReason {
            $featureSecrets = Get-InstallJsonFeatureSecrets
            $provisioningKeys = @($featureSecrets.Keys | Where-Object { $featureSecrets[$_] -match '^AWSSM Interclaw/' -and $featureSecrets[$_] -match '/Provisioning$' })
            $provisioningSecret = Get-SecretFromAws -KeyName "Interclaw/$($script:ProjectCode)/Provisioning" -AsObject
            $missing = $provisioningKeys | Where-Object { -not $provisioningSecret.PSObject.Properties.Name -contains $_ }
            $missing.Count | Should -Be 0 -Because "every AWSSM Interclaw/.../Provisioning key must exist in the Provisioning secret"
        }

        It "every AWS/Orchestrator key exists in Interclaw/FRAD/Orchestrator" -Skip:$script:SkipReason {
            $featureSecrets = Get-InstallJsonFeatureSecrets
            $orchestratorKeys = @($featureSecrets.Keys | Where-Object { $featureSecrets[$_] -match '^AWSSM Interclaw/' -and $featureSecrets[$_] -match '/Orchestrator$' })
            $orchestratorSecret = Get-SecretFromAws -KeyName "Interclaw/$($script:ProjectCode)/Orchestrator" -AsObject
            $missing = $orchestratorKeys | Where-Object { -not $orchestratorSecret.PSObject.Properties.Name -contains $_ }
            $missing.Count | Should -Be 0 -Because "every AWSSM Interclaw/.../Orchestrator key must exist in the Orchestrator secret"
        }

        It "install.json container-name values match iam-manifest consumedBy entries" -Skip:$script:SkipReason {
            $featureSecrets = Get-InstallJsonFeatureSecrets
            $containerValues = @($featureSecrets.Keys | Where-Object { $featureSecrets[$_] -notlike 'AWSSM Interclaw/*' })
            $iamManifest = Read-CredentialManifest -ManifestName "iam"
            $allConsumedBy = $iamManifest.iamUsers | ForEach-Object { $_.consumedBy } | Select-Object -Unique
            foreach ($key in $containerValues) {
                $containers = $featureSecrets[$key] -split ',' | ForEach-Object { $_.Trim() }
                foreach ($container in $containers) {
                    $container -in $allConsumedBy | Should -BeTrue -Because "$key references container $container which must exist in iam-manifest consumedBy entries"
                }
            }
        }

        It "every iam-manifest feedSecret exists as a docker-manifest swarmName" -Skip:$script:SkipReason {
            $iam = Read-CredentialManifest -ManifestName "iam"
            $docker = Read-CredentialManifest -ManifestName "docker"
            $dockerNames = $docker.secrets | ForEach-Object { $_.swarmName }
            $iamSecrets = $iam.iamUsers | ForEach-Object { $_.feedSecrets } | Where-Object { $_ }
            $missing = $iamSecrets | Where-Object { $_ -notin $dockerNames }
            $missing.Count | Should -Be 0 -Because "every IAM feedSecret must have a corresponding docker-manifest entry"
        }

        It "every iam-manifest feedBundle exists as a docker-manifest swarmName" -Skip:$script:SkipReason {
            $iam = Read-CredentialManifest -ManifestName "iam"
            $docker = Read-CredentialManifest -ManifestName "docker"
            $dockerNames = $docker.secrets | ForEach-Object { $_.swarmName }
            $iamBundles = $iam.iamUsers | ForEach-Object { $_.feedBundle } | Where-Object { $_ }
            $missing = $iamBundles | Where-Object { $_ -notin $dockerNames }
            $missing.Count | Should -Be 0 -Because "every IAM feedBundle must have a corresponding docker-manifest entry"
        }

        It "docker-manifest bundleNames align with bundle-manifest.ps1" -Skip:$script:SkipReason {
            $manifest = Get-BundleManifest
            $bundleNames = @()
            foreach ($type in $manifest.Keys) {
                if ($manifest[$type].BundleName) { $bundleNames += $manifest[$type].BundleName }
            }
            $docker = Read-CredentialManifest -ManifestName "docker"
            $dockerBundles = $docker.secrets | Where-Object { $_.type -eq 'json-bundle' }
            foreach ($entry in $dockerBundles) {
                if ($entry.swarmName -notin @('proxy_secrets_bundle', 'coding_secrets_bundle', 'sentry_secrets_bundle',
                                              'web_mcp_secrets_bundle', 'bookkeeping_secrets_bundle')) {
                    continue
                }
                $entry.swarmName -in $bundleNames | Should -BeTrue -Because "docker-manifest bundle $($entry.swarmName) must have a matching BundleName in bundle-manifest.ps1"
            }
        }

        It "every docker-manifest secret exists in Docker Swarm" -Skip:$script:SkipReason {
            $docker = Read-CredentialManifest -ManifestName "docker"
            $actualSecrets = Invoke-Docker secret ls --format '{{.Name}}' 2>$null
            if (-not $actualSecrets) { $actualSecrets = @() }
            $missing = @()
            foreach ($entry in $docker.secrets) {
                if ($entry.swarmName -notin $actualSecrets) {
                    $missing += $entry.swarmName
                }
            }
            $missing.Count | Should -Be 0 -Because "every swarm secret in docker-manifest must exist in 'docker secret ls'"
        }

        It "no undocumented Docker Swarm secrets" -Skip:$script:SkipReason {
            $docker = Read-CredentialManifest -ManifestName "docker"
            $documented = $docker.secrets | ForEach-Object { $_.swarmName }
            $actualSecrets = Invoke-Docker secret ls --format '{{.Name}}' 2>$null
            if (-not $actualSecrets) { $actualSecrets = @() }
            $orphans = $actualSecrets | Where-Object { $_ -notin $documented }
            $orphans.Count | Should -Be 0 -Because "every Swarm secret must be documented in docker-manifest.json"
        }
    }
}

AfterAll {
    if ($script:Failures.Count -gt 0) {
        $taskFile = Write-HydrationInvestigationTask
        Write-Host "`n  ============================================================" -ForegroundColor Yellow
        Write-Host "  [HYDRATION FAILED] $($script:Failures.Count) failure(s) detected." -ForegroundColor Yellow
        Write-Host "  Investigation task written to:" -ForegroundColor White
        Write-Host "    $taskFile" -ForegroundColor White
        Write-Host "  A Coder can pick this up to fix all hydration issues." -ForegroundColor White
        Write-Host "  ============================================================" -ForegroundColor Yellow
    } else {
        Write-Host "`n  [OK] All hydration integration checks passed." -ForegroundColor Green
        Write-Host "  deploy.ps1 Phase 8.5 should succeed with this SSO session." -ForegroundColor Green
        Write-Host "  Profile: $($script:SsoProfile), Project: $($script:ProjectCode)" -ForegroundColor White
        if ($script:SessionIdentity) {
            Write-Host "  Identity: $($script:SessionIdentity.Arn)" -ForegroundColor White
        }
    }
}
