#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

$script:RunIntegration = $env:INTERCLAW_RUN_INTEGRATION_TESTS -eq 'true'
$script:FleetServices = @(
    @{ Name = 'mcp_aqe';       Port = 21004 }
    @{ Name = 'is-bookkeeping'; Port = 21008 }
    @{ Name = 'is-marketer';   Port = 21011 }
)

Describe 'Fleet API contract' -Tag 'ApiContract', 'Integration' {
    foreach ($svc in $script:FleetServices) {
        Context "$($svc.Name) (port $($svc.Port))" {
            It 'GET /api/health returns 200 without auth' -Skip:$(-not $script:RunIntegration) {
                $r = Invoke-WebRequest -Uri "http://localhost:$($svc.Port)/api/health" -UseBasicParsing -SkipHttpErrorCheck
                $r.StatusCode | Should -Be 200
            }

            It 'GET /api/health returns standard shape' -Skip:$(-not $script:RunIntegration) {
                $r = Invoke-RestMethod -Uri "http://localhost:$($svc.Port)/api/health"
                $r.status  | Should -Be 'ok'
                $r.service | Should -Be $svc.Name
                $r.uptime  | Should -BeGreaterOrEqual 0
            }

            It 'GET /api/routes returns route array' -Skip:$(-not $script:RunIntegration) {
                $r = Invoke-RestMethod -Uri "http://localhost:$($svc.Port)/api/routes"
                $routes = if ($r.PSObject.Properties.Name -contains 'routes') { $r.routes } else { $r }
                $routes | Should -Not -BeNullOrEmpty
                $routes[0].method | Should -Not -BeNullOrEmpty
                $routes[0].path   | Should -Not -BeNullOrEmpty
            }

            It 'GET /api/version returns metadata' -Skip:$(-not $script:RunIntegration) {
                $r = Invoke-RestMethod -Uri "http://localhost:$($svc.Port)/api/version"
                $r.name    | Should -Be $svc.Name
                $r.version | Should -Not -BeNullOrEmpty
                $r.built   | Should -Not -BeNullOrEmpty
            }

            It 'GET /api/ready returns 200 or 503 with ready boolean' -Skip:$(-not $script:RunIntegration) {
                $r = Invoke-WebRequest -Uri "http://localhost:$($svc.Port)/api/ready" -UseBasicParsing -SkipHttpErrorCheck
                @(200, 503) | Should -Contain $r.StatusCode
                $body = $r.Content | ConvertFrom-Json
                $body.ready  | Should -BeOfType [bool]
                $body.checks | Should -BeNullOrEmpty
            }

            It 'Response includes X-Request-Id header' -Skip:$(-not $script:RunIntegration) {
                $r = Invoke-WebRequest -Uri "http://localhost:$($svc.Port)/api/health" -UseBasicParsing -SkipHttpErrorCheck
                $r.Headers['X-Request-Id'] | Should -Not -BeNullOrEmpty
            }

            It 'Response includes security headers' -Skip:$(-not $script:RunIntegration) {
                $r = Invoke-WebRequest -Uri "http://localhost:$($svc.Port)/api/health" -UseBasicParsing -SkipHttpErrorCheck
                $r.Headers['X-Content-Type-Options'] | Should -Be 'nosniff'
                $r.Headers['X-Frame-Options'] | Should -Be 'DENY'
            }
        }
    }
}
