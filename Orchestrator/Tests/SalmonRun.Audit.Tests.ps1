#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

Describe "SalmonRun.Audit Module" -Tag "Audit", "Regression-Only" {
    BeforeAll {
        $script:AuditTestDir = Join-Path $env:TEMP "SalmonRun-AuditTests-$(Get-Random)"
        $null = New-Item -ItemType Directory -Path $script:AuditTestDir -Force
        $script:OriginalAuditRoot = $env:SALMON_RUN_AUDIT_ROOT
        $env:SALMON_RUN_AUDIT_ROOT = $script:AuditTestDir

        $modulePath = Join-Path $PSScriptRoot '..' 'Modules' 'SalmonRun.Audit' 'SalmonRun.Audit.psd1'
        $script:AuditModule = Import-Module -Name $modulePath -Force -ErrorAction Stop -PassThru
    }

    AfterAll {
        if ($script:OriginalAuditRoot) {
            $env:SALMON_RUN_AUDIT_ROOT = $script:OriginalAuditRoot
        } else {
            Remove-Item Env:\SALMON_RUN_AUDIT_ROOT -ErrorAction SilentlyContinue
        }
        if (Test-Path $script:AuditTestDir) {
            Remove-Item $script:AuditTestDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    AfterEach {
        Remove-Item "$script:AuditTestDir\*" -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "exports the expected public functions" {
        $manifest = Import-PowerShellDataFile -Path (Join-Path $PSScriptRoot '..' 'Modules' 'SalmonRun.Audit' 'SalmonRun.Audit.psd1')
        $expected = @(
            'Invoke-ApiCall',
            'Write-AuditEntry',
            'Get-AuditTrail',
            'Get-LastHash',
            'Test-AuditChainIntegrity',
            'Protect-JsonFile',
            'Invoke-RedactJsonContent'
        )
        foreach ($name in $expected) {
            $manifest.FunctionsToExport | Should -Contain $name
        }
    }

    It "requires SalmonRun.Core" {
        $manifest = Import-PowerShellDataFile -Path (Join-Path $PSScriptRoot '..' 'Modules' 'SalmonRun.Audit' 'SalmonRun.Audit.psd1')
        $manifest.RequiredModules | Should -Contain 'SalmonRun.Core'
    }

    Context "Audit log path and rotation" {
        It "creates a domain-specific audit log path" {
            $logPath = & $script:AuditModule { param($d) Get-AuditLogPath -Domain $d } 'test-domain'
            $logPath | Should -BeLike "*$script:AuditTestDir*test-domain*audit.jsonl"
            Test-Path (Split-Path -Parent $logPath) | Should -Be $true
        }
    }

    Context "Write and read audit entries" {
        It "writes and retrieves a single audit entry" {
            $env:OC_RESERVATION_AGENT_ID = 'pester-agent'
            Write-AuditEntry -Entry @{ action = 'test-action'; payload = 'hello' } -Domain 'roundtrip'
            $entries = Get-AuditTrail -Domain 'roundtrip'
            $entries | Should -HaveCount 1
            $entries[0].action | Should -Be 'test-action'
            $entries[0].agent | Should -Be 'pester-agent'
            $entries[0].payload | Should -Be 'hello'
        }

        It "chains multiple entries with valid prev/hash links" {
            $env:OC_RESERVATION_AGENT_ID = 'pester-agent'
            Write-AuditEntry -Entry @{ action = 'first' } -Domain 'chain'
            Write-AuditEntry -Entry @{ action = 'second' } -Domain 'chain'
            $entries = Get-AuditTrail -Domain 'chain'
            $entries | Should -HaveCount 2
            $entries[1].prev | Should -Be $entries[0].hash
            $integrity = Test-AuditChainIntegrity -Domain 'chain'
            $integrity.Valid | Should -Be $true
            $integrity.BrokenLinks | Should -BeNullOrEmpty
        }

        It "reports a broken chain when an entry is tampered" {
            $env:OC_RESERVATION_AGENT_ID = 'pester-agent'
            Write-AuditEntry -Entry @{ action = 'first' } -Domain 'tamper'
            Write-AuditEntry -Entry @{ action = 'second' } -Domain 'tamper'
            $logPath = & $script:AuditModule { param($d) Get-AuditLogPath -Domain $d } 'tamper'
            $lines = Get-Content -LiteralPath $logPath
            $lines[0] = $lines[0] -replace '"action":"first"', '"action":"forged"'
            $lines | Set-Content -LiteralPath $logPath -Encoding utf8
            $integrity = Test-AuditChainIntegrity -Domain 'tamper'
            $integrity.Valid | Should -Be $false
            $integrity.BrokenLinks.Count | Should -BeGreaterThan 0
        }

        It "filters by Since and Endpoint" {
            $env:OC_RESERVATION_AGENT_ID = 'pester-agent'
            $start = ([datetime]::UtcNow).AddSeconds(-5)
            Write-AuditEntry -Entry @{ action = 'search'; target = 'alpha' } -Domain 'filter'
            $sinceEntries = Get-AuditTrail -Domain 'filter' -Since $start
            $sinceEntries | Should -HaveCount 1
            $endpointEntries = Get-AuditTrail -Domain 'filter' -Endpoint 'search'
            $endpointEntries | Should -HaveCount 1
        }

        It "returns the last hash" {
            $env:OC_RESERVATION_AGENT_ID = 'pester-agent'
            Write-AuditEntry -Entry @{ action = 'first' } -Domain 'lasthash'
            Write-AuditEntry -Entry @{ action = 'second' } -Domain 'lasthash'
            $last = Get-LastHash -Domain 'lasthash'
            $entries = Get-AuditTrail -Domain 'lasthash'
            $last | Should -Be $entries[-1].hash
        }
    }

    Context "Secret redaction" {
        It "redacts sensitive query parameters in URIs" {
            $redacted = & $script:AuditModule { param($u) Invoke-RedactUri -Uri $u } 'https://api.example.com/call?api_key=secret123&user=alice&token=abc'
            $redacted | Should -Match 'api_key=\*\*\*'
            $redacted | Should -Match 'token=\*\*\*'
            $redacted | Should -Match 'user=alice'
        }

        It "redacts headers and body fields" {
            $headers = @{ Authorization = 'Bearer supersecret'; 'X-Public' = 'ok' }
            $body = @{ api_key = 'secret'; user = 'alice' } | ConvertTo-Json -Compress
            $redacted = & $script:AuditModule { param($h,$b) Invoke-RedactSecrets -Headers $h -Body $b } $headers $body
            $redacted.Headers.Authorization | Should -Be '***'
            $redacted.Headers.'X-Public' | Should -Be 'ok'
            $redacted.Body | Should -Match '"api_key":"\*\*\*"'
        }

        It "redacts known secret patterns in JSON content" {
            $content = '{"aws_key":"AKIA1234567890123456","name":"alice"}'
            $redacted = Invoke-RedactJsonContent -Content $content
            $redacted | Should -Match '\*\*\*REDACTED\*\*\*'
            $redacted | Should -Match '"name":"alice"'
        }

        It "protects a JSON file in place" {
            $file = Join-Path $script:AuditTestDir 'secret.json'
            '{"api_key":"AKIA1234567890123456","name":"alice"}' | Set-Content -LiteralPath $file -Encoding utf8
            Protect-JsonFile -Path $file
            $protected = Get-Content -LiteralPath $file -Raw
            $protected | Should -Match '\*\*\*REDACTED\*\*\*'
            $protected | Should -Match '"name":"alice"'
        }
    }

    Context "Invoke-ApiCall" {
        It "logs an audit entry for a successful call" {
            $env:OC_RESERVATION_AGENT_ID = 'pester-agent'
            Mock -CommandName Invoke-RestMethod -ModuleName SalmonRun.Audit -MockWith { return @{ ok = $true } }
            $result = Invoke-ApiCall -Uri 'https://api.example.com/test' -Domain 'apicall' -Action 'TestCall'
            $result.ok | Should -Be $true
            $entries = Get-AuditTrail -Domain 'apicall'
            $entries | Should -HaveCount 1
            $entries[0].action | Should -Be 'TestCall'
            $entries[0].req.method | Should -Be 'GET'
            $entries[0].req.uri | Should -Be 'https://api.example.com/test'
        }

        It "throws and logs an audit error on failure" {
            $env:OC_RESERVATION_AGENT_ID = 'pester-agent'
            Mock -CommandName Invoke-RestMethod -ModuleName SalmonRun.Audit -MockWith { throw 'network down' }
            { Invoke-ApiCall -Uri 'https://api.example.com/fail' -Domain 'apierror' -Action 'FailCall' } | Should -Throw
            $entries = Get-AuditTrail -Domain 'apierror' -IncludeErrors
            $entries | Should -HaveCount 1
            $entries[0].error | Should -Match 'network down'
        }
    }
}
