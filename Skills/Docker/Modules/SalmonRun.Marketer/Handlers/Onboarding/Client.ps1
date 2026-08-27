# Onboarding.Client — capability gate for client onboarding workflows.
# Required keys: (internal — no external API key required).
# Capabilities: onboarding:create.

function New-ClientOnboarding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ClientName,
        [Parameter(Mandatory)][string]$ProjectId,
        [string[]]$Services = @(),
        [hashtable]$Metadata = @{}
    )

    Test-MarketerCapability -RequiredCapability 'onboarding:create'

    $onboardingId = [guid]::NewGuid().ToString()
    $state = @{
        OnboardingId = $onboardingId
        ClientName   = $ClientName
        ProjectId    = $ProjectId
        Services     = $Services
        Metadata     = $Metadata
        Step         = 'initiated'
        CreatedAt    = [datetime]::UtcNow.ToString('o')
    }

    Write-MarketerAuditEntry -Capability 'onboarding:create' -Action "New-ClientOnboarding" -Context @{ ClientName = $ClientName; ProjectId = $ProjectId } -Result 'allow'
    return [pscustomobject]$state
}

function Advance-ClientOnboarding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OnboardingId,
        [Parameter(Mandatory)][string]$Step
    )

    Test-MarketerCapability -RequiredCapability 'onboarding:create'

    $validSteps = @('initiated', 'provisioning', 'configured', 'verified', 'completed')
    if ($Step -notin $validSteps) {
        throw "Invalid onboarding step: $Step. Must be one of: $($validSteps -join ', ')"
    }

    Write-MarketerAuditEntry -Capability 'onboarding:create' -Action "Advance-ClientOnboarding" -Context @{ OnboardingId = $OnboardingId; Step = $Step } -Result 'allow'
    return [pscustomobject]@{
        OnboardingId = $OnboardingId
        Step         = $Step
        AdvancedAt   = [datetime]::UtcNow.ToString('o')
    }
}

function Get-ClientOnboardingStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OnboardingId
    )

    Test-MarketerCapability -RequiredCapability 'onboarding:create'

    Write-MarketerAuditEntry -Capability 'onboarding:create' -Action "Get-ClientOnboardingStatus" -Context @{ OnboardingId = $OnboardingId } -Result 'allow'
    return [pscustomobject]@{
        OnboardingId = $OnboardingId
        Status       = 'active'
        RetrievedAt  = [datetime]::UtcNow.ToString('o')
    }
}
