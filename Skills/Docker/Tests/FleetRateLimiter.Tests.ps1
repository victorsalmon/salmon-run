#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

BeforeAll {
    $rateLimiterPath = Join-Path $PSScriptRoot "..\..\..\Skills\Docker\Modules\SalmonRun.Fleet\Private\rate-limiter.ps1"
    $resolvedPath = (Resolve-Path $rateLimiterPath).Path
    . $resolvedPath
}

Describe "New-RateLimiter" -Tag "Fleet", "Security" {
    It "allows first request for a new client" {
        $rl = New-RateLimiter -Limit 5 -WindowSec 60
        $rl.IsAllowed("client-A") | Should -Be $true
    }

    It "denies when limit is exceeded within window" {
        $rl = New-RateLimiter -Limit 3 -WindowSec 60
        $rl.IsAllowed("client-A") | Should -Be $true
        $rl.IsAllowed("client-A") | Should -Be $true
        $rl.IsAllowed("client-A") | Should -Be $true
        $rl.IsAllowed("client-A") | Should -Be $false
    }

    It "resets after window expires" {
        $rl = New-RateLimiter -Limit 2 -WindowSec 1
        $rl.IsAllowed("client-A") | Should -Be $true
        $rl.IsAllowed("client-A") | Should -Be $true
        $rl.IsAllowed("client-A") | Should -Be $false
        Start-Sleep -Seconds 1.1
        $rl.IsAllowed("client-A") | Should -Be $true
    }

    It "gives independent counters for different tokens" {
        $rl = New-RateLimiter -Limit 2 -WindowSec 60
        $rl.IsAllowed("token-A") | Should -Be $true
        $rl.IsAllowed("token-A") | Should -Be $true
        $rl.IsAllowed("token-A") | Should -Be $false
        $rl.IsAllowed("token-B") | Should -Be $true
        $rl.IsAllowed("token-B") | Should -Be $true
        $rl.IsAllowed("token-B") | Should -Be $false
    }

    It "engages circuit breaker on high error rate" {
        $rl = New-RateLimiter -Limit 10 -WindowSec 60 -CooldownSec 2
        $rl.IsAllowed("client-A") | Should -Be $true
        $rl.IsAllowed("client-A") | Should -Be $true
        $rl.RecordError("client-A")
        $rl.RecordError("client-A")
        $rl.IsAllowed("client-A") | Should -Be $false
    }

    It "recovers after circuit breaker cooldown" {
        $rl = New-RateLimiter -Limit 10 -WindowSec 60 -CooldownSec 1
        $rl.IsAllowed("client-A") | Should -Be $true
        $rl.IsAllowed("client-A") | Should -Be $true
        $rl.RecordError("client-A")
        $rl.RecordError("client-A")
        $rl.IsAllowed("client-A") | Should -Be $false
        Start-Sleep -Seconds 1.1
        $rl.IsAllowed("client-A") | Should -Be $true
    }

    It "RecordError is a no-op for unknown client" {
        $rl = New-RateLimiter -Limit 5 -WindowSec 60
        { $rl.RecordError("nonexistent") } | Should -Not -Throw
    }
}
