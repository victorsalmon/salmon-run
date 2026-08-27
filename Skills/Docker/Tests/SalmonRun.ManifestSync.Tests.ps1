#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

#Requires -Version 7.0

BeforeAll {
    $RepoRoot = (Get-Item $PSCommandPath).Directory.Parent.Parent.Parent.FullName
    $InstallJsonPath = Join-Path $RepoRoot "install.json"
    $BundleManifestPath = Join-Path $RepoRoot "Skills/Docker/Modules/SalmonRun.Secrets/Private/bundle-manifest.ps1"
    $EnvVarRegistryPath = Join-Path $RepoRoot "docs/Reference/env-var-registry.json"

    # Parse install.json secrets keys
    $installJson = Get-Content $InstallJsonPath -Raw | ConvertFrom-Json
    $script:InstallKeys = @()
    foreach ($feature in $installJson.features.PSObject.Properties) {
        $secretsObj = $feature.Value.secrets
        if ($secretsObj) {
            $script:InstallKeys += $secretsObj.PSObject.Properties.Name
        }
    }
    $script:InstallKeys = $script:InstallKeys | Select-Object -Unique

    # Parse bundle-manifest.ps1 keys — separate secret keys from env var names
    $bundleScript = Get-Content $BundleManifestPath -Raw
    $bundleScript = $bundleScript -replace '(?s)^<#.*?#>', ''
    $script:BundleSecretKeys = @()    # keys from Required / Optional / EnvMap keys
    $script:BundleEnvVarNames = @()   # values from EnvMap / SourceKeys
    $requiredPattern = "Required\s*=\s*@\(\s*(.*?)\s*\)"
    $optionalPattern = "Optional\s*=\s*@\(\s*(.*?)\s*\)"
    foreach ($pattern in @($requiredPattern, $optionalPattern)) {
        [regex]::Matches($bundleScript, $pattern, 'Singleline') | ForEach-Object {
            $body = $_.Groups[1].Value
            [regex]::Matches($body, "'([\w_]+)'") | ForEach-Object {
                $script:BundleSecretKeys += $_.Groups[1].Value
            }
        }
    }
    $envMapPattern = "EnvMap\s*=\s*@\{(.*?)\}\s*\n\s*\}"
    [regex]::Matches($bundleScript, $envMapPattern, 'Singleline') | ForEach-Object {
        $body = $_.Groups[1].Value
        # EnvMap keys are secret names; values are env var names
        [regex]::Matches($body, "'([\w_]+)'\s*=\s*'([\w_]+)'") | ForEach-Object {
            $script:BundleSecretKeys += $_.Groups[1].Value
            $script:BundleEnvVarNames += $_.Groups[2].Value
        }
    }
    $script:BundleSecretKeys = $script:BundleSecretKeys | Select-Object -Unique
    $script:BundleEnvVarNames = $script:BundleEnvVarNames | Select-Object -Unique

    # SourceKeys entries are env var names
    $sourceKeysPattern = "SourceKeys\s*=\s*@\(\s*(.*?)\s*\)"
    [regex]::Matches($bundleScript, $sourceKeysPattern, 'Singleline') | ForEach-Object {
        $body = $_.Groups[1].Value
        [regex]::Matches($body, "'([\w_]+)'") | ForEach-Object {
            $script:BundleEnvVarNames += $_.Groups[1].Value
        }
    }
    $script:BundleEnvVarNames = $script:BundleEnvVarNames | Select-Object -Unique
    $script:BundleAllKeys = ($script:BundleSecretKeys + $script:BundleEnvVarNames) | Select-Object -Unique

    # Parse env-var-registry.json keys
    $envVarRegistry = Get-Content $EnvVarRegistryPath -Raw | ConvertFrom-Json
    $script:EnvVarKeys = $envVarRegistry.envVars.PSObject.Properties.Name
}

Describe "install.json ↔ bundle-manifest sync" -Tag "ManifestSync", "Regression-Only" {
    It "Every key in install.json features[*].secrets is published by a bundle" {
        $orphans = $script:InstallKeys | Where-Object { $_ -notin $script:BundleAllKeys }
        if ($orphans) {
            Write-Warning "Keys in install.json but NOT in any bundle: [$($orphans -join ', ')]"
        }
        $orphans | Should -BeNullOrEmpty
    }
    It "Every bundle secret key is declared in install.json" {
        $extra = $script:BundleSecretKeys | Where-Object { $_ -notin $script:InstallKeys }
        if ($extra) {
            Write-Warning "Bundle secret keys not in install.json: [$($extra -join ', ')]"
        }
        $extra | Should -BeNullOrEmpty
    }
}

Describe "bundle-manifest ↔ env-var-registry sync" -Tag "ManifestSync", "Regression-Only" {
    It "Every bundle env var name has a corresponding env-var-registry entry" {
        $missing = $script:BundleEnvVarNames | Where-Object { $_ -notin $script:EnvVarKeys }
        if ($missing) {
            Write-Warning "Bundle env var names missing from env-var-registry: [$($missing -join ', ')]"
        }
        $missing | Should -BeNullOrEmpty
    }
}
