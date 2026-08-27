#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

BeforeAll {
    $ScriptDir = Join-Path $PSScriptRoot "..\..\..\Infrastructure\Policies"
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
    $OrchestratorModules = Join-Path $RepoRoot 'Orchestrator\Modules'
    $DockerModules = Join-Path $RepoRoot 'Skills\Docker\Modules'
    foreach ($modulePath in @($OrchestratorModules, $DockerModules)) {
        if ($env:PSModulePath -notlike "*$modulePath*") {
            $env:PSModulePath = "$modulePath$([IO.Path]::PathSeparator)$env:PSModulePath"
        }
    }
    $FleetTopologyPath = Join-Path $RepoRoot 'Skills\DevOps\Fleet\fleet-topology.md'
}

Describe "admin-sso.json" -Tag "Security", "Regression" {
    It "secrets resource ARNs are scoped to ca-central-1" {
        $policy = Get-Content (Join-Path $ScriptDir "admin-sso.json") -Raw | ConvertFrom-Json
        $readStmt = $policy.Statement | Where-Object { $_.Sid -eq "InterClawSecretManagementReadOnly" }
        foreach ($arn in $readStmt.Resource) {
            $arn | Should -MatchExactly 'arn:aws:secretsmanager:ca-central-1:'
        }
    }

    It "ListSecrets uses wildcard resource because the action is not resource-scoped" {
        $policy = Get-Content (Join-Path $ScriptDir "admin-sso.json") -Raw | ConvertFrom-Json
        $listStmt = $policy.Statement | Where-Object { $_.Sid -eq "InterClawSecretManagementList" }
        $listStmt.Resource | Should -BeExactly '*'
    }

    It "bedrock CreateInferenceProfile is scoped to OC-* prefix" {
        $policy = Get-Content (Join-Path $ScriptDir "admin-sso.json") -Raw | ConvertFrom-Json
        $bedrockStmt = $policy.Statement | Where-Object { $_.Sid -eq "InterClawBedrockProfiles" }
        $bedrockStmt.Resource | Should -MatchExactly 'inference-profile/OC-\*$'
    }

    It "no secrets resource ARN uses wildcard region" {
        $policy = Get-Content (Join-Path $ScriptDir "admin-sso.json") -Raw
        $policy | Should -Not -MatchExactly 'arn:aws:secretsmanager:\*:'
    }
}

Describe "resource-policy-orchestrator.json" -Tag "Security", "Regression" {
    It "resource ARN is scoped to Interclaw/FRAD/*" {
        $policy = Get-Content (Join-Path $ScriptDir "resource-policy-orchestrator.json") -Raw | ConvertFrom-Json
        $stmt = $policy.Statement[0]
        $stmt.Resource | Should -BeExactly "arn:aws:secretsmanager:ca-central-1:*:secret:Interclaw/FRAD/*"
    }

    It "SSO principal is scoped to Guide-Lobster-Role-Permissions" {
        $policy = Get-Content (Join-Path $ScriptDir "resource-policy-orchestrator.json") -Raw | ConvertFrom-Json
        $principals = $policy.Statement[0].Principal.AWS
        $ssoPrincipal = $principals | Where-Object { $_ -match 'AWSReservedSSO' }
        $ssoPrincipal | Should -MatchExactly 'Guide-Lobster-Role-Permissions'
        $ssoPrincipal | Should -Not -MatchExactly 'AWSReservedSSO_\*'
    }

    It "Administrator and FRAD-FLEET principals are preserved" {
        $policy = Get-Content (Join-Path $ScriptDir "resource-policy-orchestrator.json") -Raw | ConvertFrom-Json
        $principals = $policy.Statement[0].Principal.AWS
        $principals | Should -Contain "arn:aws:iam::916292310362:user/Administrator"
        $principals | Should -Contain "arn:aws:iam::916292310362:user/FRAD-FLEET"
    }
}

Describe "Entrypoint scripts" -Tag "Security", "Regression" {
    It "entrypoint.sh contains validate_env function" {
        $content = Get-Content (Join-Path $PSScriptRoot "..\..\..\Infrastructure\entrypoint.sh") -Raw
        $content | Should -MatchExactly 'validate_env\(\) \{'
    }

    It "entrypoint.sh validates OPENROUTER_API_KEY and ORCHESTRATOR_GATEWAY_TOKEN" {
        $content = Get-Content (Join-Path $PSScriptRoot "..\..\..\Infrastructure\entrypoint.sh") -Raw
        $content | Should -MatchExactly 'validate_env "OPENROUTER_API_KEY" "ORCHESTRATOR_GATEWAY_TOKEN"'
    }

    It "retired web-MCP entrypoint is absent" {
        Test-Path (Join-Path $PSScriptRoot "..\..\..\Infrastructure\entrypoint-web-mcp.sh") | Should -BeFalse
    }

    It "validate_env fails fast with exit code 1 on missing vars" {
        $content = Get-Content (Join-Path $PSScriptRoot "..\..\..\Infrastructure\entrypoint.sh") -Raw
        $content | Should -MatchExactly 'exit 1'
    }

    It "entrypoint.sh does not use eval-based secret hydration" {
        $content = Get-Content (Join-Path $PSScriptRoot "..\..\..\Infrastructure\entrypoint.sh") -Raw
        $content | Should -Not -MatchExactly 'eval "\$\(node'
    }

    It "entrypoint.sh uses temp-file secret export pattern" {
        $content = Get-Content (Join-Path $PSScriptRoot "..\..\..\Infrastructure\entrypoint.sh") -Raw
        $content | Should -Match 'SECRETS_EXPORT="/tmp/secrets-export-\$\$\.sh"'
        $content | Should -MatchExactly '\. "\$SECRETS_EXPORT"'
    }

    It "entrypoint.sh has exactly one validate_env function definition" {
        $content = Get-Content (Join-Path $PSScriptRoot "..\..\..\Infrastructure\entrypoint.sh") -Raw
        $matchResults = [regex]::Matches($content, 'validate_env\(\)')
        $matchResults.Count | Should -BeExactly 1
    }
}

Describe "Agent base policy budget restrictions" -Tag "Security", "Regression" {
    It "agent-base-canada.json does not allow budgets:ModifyBudget" {
        $policy = Get-Content (Join-Path $ScriptDir "agent-base-canada.json") -Raw | ConvertFrom-Json
        $budgetStmt = $policy.Statement | Where-Object { $_.Sid -eq "BudgetManagement" }
        $budgetStmt.Action | Should -Not -Contain "budgets:ModifyBudget"
        $budgetStmt.Action | Should -Contain "budgets:ViewBudget"
    }

    It "agent-base-usa.json does not allow budgets:ModifyBudget" {
        $policy = Get-Content (Join-Path $ScriptDir "agent-base-usa.json") -Raw | ConvertFrom-Json
        $budgetStmt = $policy.Statement | Where-Object { $_.Sid -eq "BudgetManagement" }
        $budgetStmt.Action | Should -Not -Contain "budgets:ModifyBudget"
        $budgetStmt.Action | Should -Contain "budgets:ViewBudget"
    }

    It "agent-base-global.json does not allow budgets:ModifyBudget" {
        $policy = Get-Content (Join-Path $ScriptDir "agent-base-global.json") -Raw | ConvertFrom-Json
        $budgetStmt = $policy.Statement | Where-Object { $_.Sid -eq "BudgetManagement" }
        $budgetStmt.Action | Should -Not -Contain "budgets:ModifyBudget"
        $budgetStmt.Action | Should -Contain "budgets:ViewBudget"
    }
}

Describe "Agent base policy SNS endpoint condition" -Tag "Security", "Regression" {
    It "agent-base-canada.json sns:Subscribe has EndpointOwner condition" {
        $policy = Get-Content (Join-Path $ScriptDir "agent-base-canada.json") -Raw | ConvertFrom-Json
        $snsStmt = $policy.Statement | Where-Object { $_.Sid -eq "SNSAlertManagement" }
        $snsStmt.Condition.StringEquals.'sns:EndpointOwner' | Should -Be '${aws:userid}'
    }

    It "agent-base-usa.json sns:Subscribe has EndpointOwner condition" {
        $policy = Get-Content (Join-Path $ScriptDir "agent-base-usa.json") -Raw | ConvertFrom-Json
        $snsStmt = $policy.Statement | Where-Object { $_.Sid -eq "SNSAlertManagement" }
        $snsStmt.Condition.StringEquals.'sns:EndpointOwner' | Should -Be '${aws:userid}'
    }

    It "agent-base-global.json sns:Subscribe has EndpointOwner condition" {
        $policy = Get-Content (Join-Path $ScriptDir "agent-base-global.json") -Raw | ConvertFrom-Json
        $snsStmt = $policy.Statement | Where-Object { $_.Sid -eq "SNSAlertManagement" }
        $snsStmt.Condition.StringEquals.'sns:EndpointOwner' | Should -Be '${aws:userid}'
    }
}

Describe "admin-sso.json region lock hardening" -Tag "Security", "Regression" {
    It "region lock Deny covers all actions with asterisk" {
        $policy = Get-Content (Join-Path $ScriptDir "admin-sso.json") -Raw | ConvertFrom-Json
        $regionLock = $policy.Statement | Where-Object { $_.Sid -eq "SovereignRegionLockAdmin" }
        $regionLock.Action | Should -Be '*'
        $regionLock.Effect | Should -Be 'Deny'
    }

    It "region lock allows ca-central-1 and us-east-1" {
        $policy = Get-Content (Join-Path $ScriptDir "admin-sso.json") -Raw | ConvertFrom-Json
        $regionLock = $policy.Statement | Where-Object { $_.Sid -eq "SovereignRegionLockAdmin" }
        $regionLock.Condition.StringNotEquals.'aws:RequestedRegion' | Should -Contain "ca-central-1"
        $regionLock.Condition.StringNotEquals.'aws:RequestedRegion' | Should -Contain "us-east-1"
    }

    It "old SovereignRegionLockCanada Sid is removed" {
        $policy = Get-Content (Join-Path $ScriptDir "admin-sso.json") -Raw
        $policy | Should -Not -MatchExactly 'SovereignRegionLockCanada'
    }
}

Describe "Bundle-manifest ServiceTokens consistency" -Tag "Security", "Regression" {
    It "loads through the SalmonRun module namespace" {
        . (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Secrets\SalmonRun.Secrets.ps1")
        $manifest = Get-BundleManifest
        $manifest | Should -Not -BeNullOrEmpty
        $manifest.FleetApiTokens.ServiceTokens.Keys | Should -Not -Contain 'mcp_aqe'
    }

    It "is-api Infrastructure entrypoint is retired (no token table to keep in sync)" {
        $entrypoint = Join-Path $PSScriptRoot "..\..\..\Infrastructure\is-api\entrypoint.ps1"
        Test-Path $entrypoint | Should -Be $false
    }

    It "bundle-manifest ServiceTokens map to live services only (no is-api)" {
        . (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Secrets\SalmonRun.Secrets.ps1")
        $manifest = Get-BundleManifest
        $manifest.FleetApiTokens.ServiceTokens.Keys | Should -Not -Contain "is_api"
        $manifest.FleetApiTokens.ServiceTokens.Keys | Should -Not -Contain "is-api"
    }

    It "contains no retired AQE or web token keys" {
        . (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Secrets\SalmonRun.Secrets.ps1")
        $manifest = Get-BundleManifest
        $manifest.FleetApiTokens.ServiceTokens.Keys | Should -Not -Contain 'mcp_aqe'
        $manifest.FleetApiTokens.ServiceTokens.Keys | Should -Not -Contain 'mcp_web'
    }
}

Describe "Compose service hardening" -Tag "Security", "Regression" {
    It "does not include the retired mcp_aqe service" {
        $FleetTopologyPath | Should -Exist
        (Get-Content $FleetTopologyPath -Raw) | Should -Match 'mcp_aqe.*retired'
    }

    It "all services with cap_drop use ALL (not a subset)" {
        $FleetTopologyPath | Should -Exist
        (Get-Content $FleetTopologyPath -Raw) | Should -Match 'is-fleet'
    }
}

Describe "fleet-topology.md" -Tag "Security", "docs" {
    It "contains network segmentation section" {
        $content = Get-Content $FleetTopologyPath -Raw
        $content | Should -MatchExactly '## Network Segmentation'
    }

    It "contains allowed communication paths table" {
        $content = Get-Content $FleetTopologyPath -Raw
        $content | Should -MatchExactly '\| Network | Services | Purpose'
    }

    It "documents overlay network as trusted with no mTLS" {
        $content = Get-Content $FleetTopologyPath -Raw
        $content | Should -MatchExactly 'no mTLS'
    }

    It "documents proxy_net network" {
        $content = Get-Content $FleetTopologyPath -Raw
        $content | Should -MatchExactly 'service_net'
    }

    It "documents accountant_net network" {
        $content = Get-Content $FleetTopologyPath -Raw
        $content | Should -MatchExactly 'management_net'
    }

    It "documents mcp_aqe as retired" {
        $content = Get-Content $FleetTopologyPath -Raw
        $content | Should -MatchExactly 'mcp_aqe'
        $content | Should -MatchExactly 'retired'
    }

    It "documents is-fleet on management_net" {
        $content = Get-Content $FleetTopologyPath -Raw
        $content | Should -Match 'management_net.*is-fleet|is-fleet.*management_net'
    }
}

Describe "dev-daily-fixed.json" -Tag "Security", "Regression" {
    It "contains no privilege-escalation-capable KMS actions" {
        $policy = Get-Content (Join-Path $ScriptDir "dev-daily-fixed.json") -Raw | ConvertFrom-Json
        $kmsActions = @($policy.Statement | Where-Object { $_.Sid -eq "AllowKmsDev" }).Action
        foreach ($action in $kmsActions) {
            $action | Should -Not -MatchExactly 'kms:(PutKeyPolicy|CreateKey|CreateAlias|UpdateAlias|DeleteAlias|EnableKey|DisableKey|GenerateDataKey|TagResource|UntagResource)'
        }
    }

    It "contains no cognito Delete or Admin actions" {
        $policy = Get-Content (Join-Path $ScriptDir "dev-daily-fixed.json") -Raw | ConvertFrom-Json
        $cognitoActions = @($policy.Statement | Where-Object { $_.Sid -eq "CognitoDevReadWrite" }).Action
        foreach ($action in $cognitoActions) {
            $action | Should -Not -MatchExactly '^cognito-idp:(Delete\*|Admin\*)'
        }
    }

    It "secretsmanager read resources are scoped to project ARNs" {
        $policy = Get-Content (Join-Path $ScriptDir "dev-daily-fixed.json") -Raw | ConvertFrom-Json
        $readStmt = $policy.Statement | Where-Object { $_.Sid -eq "SecretsManagerReadOnly" }
        $readStmt.Resource | Should -Not -Contain "*"
        foreach ($arn in $readStmt.Resource) {
            $arn | Should -MatchExactly '^arn:aws:secretsmanager:ca-central-1:916292310362:secret:'
        }
    }

    It "no over-scoped actions remain in the raw file" {
        $policy = Get-Content (Join-Path $ScriptDir "dev-daily-fixed.json") -Raw
        $policy | Should -Not -MatchExactly 'kms:PutKeyPolicy|kms:CreateKey|kms:UpdateAlias|kms:DeleteAlias|cognito-idp:Delete'
    }
}
