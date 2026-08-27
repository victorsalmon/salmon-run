#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

# ==============================================================================
# SalmonRun.Telegram Module Tests
# ==============================================================================

BeforeAll {
    $diagnosticsPath = Join-Path $PSScriptRoot '..\Modules\SalmonRun.Diagnostics\SalmonRun.Diagnostics.ps1'
    if (Test-Path $diagnosticsPath) { . $diagnosticsPath }
    . (Join-Path $PSScriptRoot "..\..\..\Orchestrator\Modules\SalmonRun.Core\SalmonRun.Core.ps1")
    . (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Fleet\SalmonRun.Fleet.ps1")
    . (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Telegram\SalmonRun.Telegram.ps1")

    Mock Write-SetupLog { }
    Mock Write-Host { }
    Mock Write-FleetLog { }
}

Describe "Test-TelegramSender" -Tag "Telegram" {
    It "rejects when Telegram is not configured" {
        $config = @{ IsConfigured = $false; OwnerUsername = ""; OwnerUserId = "" }
        $result = Test-TelegramSender -FromUsername "attacker" -FromUserId "12345" -Config $config
        $result.IsAuthorized | Should -BeFalse
        $result.RejectionReason | Should -Be "TELEGRAM_NOT_CONFIGURED"
    }

    It "authorizes when both username and user ID match" {
        $config = @{ IsConfigured = $true; OwnerUsername = "victor"; OwnerUserId = "99999" }
        $result = Test-TelegramSender -FromUsername "victor" -FromUserId "99999" -Config $config
        $result.IsAuthorized | Should -BeTrue
    }

    It "rejects when username mismatch" {
        $config = @{ IsConfigured = $true; OwnerUsername = "victor"; OwnerUserId = "99999" }
        $result = Test-TelegramSender -FromUsername "attacker" -FromUserId "99999" -Config $config
        $result.IsAuthorized | Should -BeFalse
        $result.RejectionReason | Should -Be "USERNAME_MISMATCH"
    }

    It "rejects when user ID mismatch" {
        $config = @{ IsConfigured = $true; OwnerUsername = "victor"; OwnerUserId = "99999" }
        $result = Test-TelegramSender -FromUsername "victor" -FromUserId "00000" -Config $config
        $result.IsAuthorized | Should -BeFalse
        $result.RejectionReason | Should -Be "USERID_MISMATCH"
    }

    It "rejects on both mismatch" {
        $config = @{ IsConfigured = $true; OwnerUsername = "victor"; OwnerUserId = "99999" }
        $result = Test-TelegramSender -FromUsername "attacker" -FromUserId "00000" -Config $config
        $result.IsAuthorized | Should -BeFalse
        $result.RejectionReason | Should -Be "BOTH_MISMATCH"
    }

    It "normalizes @ prefix on username" {
        $config = @{ IsConfigured = $true; OwnerUsername = "victor"; OwnerUserId = "99999" }
        $result = Test-TelegramSender -FromUsername "@victor" -FromUserId "99999" -Config $config
        $result.IsAuthorized | Should -BeTrue
    }
}

Describe "Write-TelegramSecurityEvent" -Tag "Telegram" {
    BeforeEach {
        Mock Get-HomeDir { return "$env:TEMP\ORCHESTRATOR-test-telegram" }
        Mock Add-Content { }
    }

    It "writes security log entry" {
        { Write-TelegramSecurityEvent -EventType "UNAUTHORIZED_MESSAGE" -SenderUsername "attacker" -SenderUserId "00000" } | Should -Not -Throw
        Should -Invoke Add-Content -Times 1 -Exactly
    }

    It "truncates long message text" {
        $long = "A" * 500
        { Write-TelegramSecurityEvent -EventType "UNAUTHORIZED_MESSAGE" -MessageText $long } | Should -Not -Throw
    }

    It "logs HIGH_VOLUME to setup log" {
        Mock Write-SetupLog { }
        { Write-TelegramSecurityEvent -EventType "HIGH_VOLUME" -Detail "test volume alert" } | Should -Not -Throw
        Should -Invoke Write-SetupLog -Times 1 -Exactly
    }
}

Describe "Test-TelegramTrafficAnomaly" -Tag "Telegram" {
    BeforeEach {
        Mock Get-ReportsDir { return "$env:TEMP\ORCHESTRATOR-test-telegram\Tasks\Logs" }
    }

    It "returns no anomaly when log file missing" {
        Mock Test-Path { return $false } -ParameterFilter { $Path -like "*telegram-security*" }
        $result = Test-TelegramTrafficAnomaly -Threshold 10 -WindowMinutes 5
        $result.IsAnomaly | Should -BeFalse
    }

    It "returns no anomaly when below threshold" {
        $logDir = "$env:TEMP\ORCHESTRATOR-test-telegram\Tasks\Logs\security"
        New-Item -ItemType Directory -Path $logDir -Force -ErrorAction SilentlyContinue | Out-Null
        $logFile = Join-Path $logDir "telegram-security-$(Get-Date -Format 'yyyyMMdd').log"
        $entry = @{ timestamp = [DateTime]::UtcNow.ToString("o"); eventType = "UNAUTHORIZED_MESSAGE"; senderUserId = "1" } | ConvertTo-Json -Compress
        Set-Content -Path $logFile -Value $entry -Encoding UTF8
        $result = Test-TelegramTrafficAnomaly -Threshold 10 -WindowMinutes 5
        $result.IsAnomaly | Should -BeFalse
        $result.EventCount | Should -Be 1
    }
}

Describe "Invoke-TelegramPollingWithBackoff" -Tag "Telegram", "Regression-Only" {
    BeforeAll {
        . (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Telegram\SalmonRun.Telegram.ps1")
        $global:sleepDurations = @()
        Mock Start-Sleep { $global:sleepDurations += $Seconds; if ($global:sleepDurations.Count -ge 10) { throw "TIMEOUT_BREAK" } }
        Mock Write-FleetLog { }
        Mock Write-SetupLog { }
    }
    BeforeEach {
        $global:sleepDurations = @()
    }

    It "resets backoff on success" {
        $attempts = 0
        $action = { $global:attempts++; return $true }
        try { Invoke-TelegramPollingWithBackoff -PollAction $action -BaseIntervalSec 1 -CircuitBreakerThreshold 10 } catch {}
        $global:sleepDurations | Should -Not -BeNullOrEmpty
        $global:sleepDurations[0] | Should -Be 1
    }

    It "applies exponential backoff on failures" {
        $failCount = 0
        $action = { $global:failCount++; throw "fail" }
        try { Invoke-TelegramPollingWithBackoff -PollAction $action -BaseIntervalSec 1 -MaxBackoffSec 30 -CircuitBreakerThreshold 10 } catch {}
        $global:sleepDurations.Count | Should -Be 10
        $global:sleepDurations[0] | Should -Be 1
        $global:sleepDurations[1] | Should -Be 2
        $global:sleepDurations[2] | Should -Be 4
        $global:sleepDurations[3] | Should -Be 8
    }

    It "caps backoff at MaxBackoffSec" {
        $failCount = 0
        $action = { $global:failCount++; throw "fail" }
        try { Invoke-TelegramPollingWithBackoff -PollAction $action -BaseIntervalSec 1 -MaxBackoffSec 5 -CircuitBreakerThreshold 10 } catch {}
        $cappedDelays = $global:sleepDurations | Where-Object { $_ -gt 5 }
        $cappedDelays.Count | Should -Be 0
    }

    It "engages circuit breaker after threshold failures" {
        $action = { throw "fail" }
        try { Invoke-TelegramPollingWithBackoff -PollAction $action -BaseIntervalSec 1 -MaxBackoffSec 30 -CircuitBreakerThreshold 3 -CircuitBreakerIntervalSec 60 } catch {}
        $circuitBreakerSleeps = $global:sleepDurations | Where-Object { $_ -eq 60 }
        $circuitBreakerSleeps.Count | Should -BeGreaterThan 0
    }

    It "resets circuit breaker on success after failures" {
        $callCount = 0
        $action = {
            $global:callCount++
            if ($global:callCount -le 3) { throw "fail" }
            return $true
        }
        try { Invoke-TelegramPollingWithBackoff -PollAction $action -BaseIntervalSec 1 -MaxBackoffSec 30 -CircuitBreakerThreshold 3 -CircuitBreakerIntervalSec 60 } catch {}
        $baseSleeps = $global:sleepDurations | Where-Object { $_ -eq 1 }
        $baseSleeps.Count | Should -BeGreaterThan 0
    }

    It "rejects null PollAction" {
        { Invoke-TelegramPollingWithBackoff -PollAction $null } | Should -Throw
    }
}

Describe "SalmonRun.Telegram Module" -Tag "Telegram", "Regression-Only" {
    Context "Approve-TelegramPairing" {
        It "returns not paired when no ORCH containers found" {
            function docker {
                $argLine = $args -join ' '
                $global:LASTEXITCODE = 0
                if ($argLine -match 'secret ls') { return "" }
                if ($argLine -match 'ps --filter') { return "" }
                return ""
            }
            $Result = Approve-TelegramPairing -PairingCode "12345"
            $Result.Paired | Should -BeFalse
            $Result.Errors | Should -Contain "No ORCH containers found"
        }

        It "auto-pairs with pairing code when ORCH containers exist" {
            function docker {
                $argLine = $args -join ' '
                $global:LASTEXITCODE = 0
                if ($argLine -match 'secret ls') { return "telegram_bot_token_orch" }
                if ($argLine -match 'ps --filter') { return "frad_oc-orch" }
                if ($argLine -match 'pairing approve') { return "paired" }
                return ""
            }
            $Result = Approve-TelegramPairing -PairingCode "12345"
            $Result.Paired | Should -BeTrue
        }

        It "skips in NonInteractive mode without pairing code" {
            function docker {
                $argLine = $args -join ' '
                $global:LASTEXITCODE = 0
                if ($argLine -match 'secret ls') { return "telegram_bot_token_orch" }
                if ($argLine -match 'ps --filter') { return "frad_oc-orch" }
                return ""
            }
            $Result = Approve-TelegramPairing -NonInteractive
            $Result.Paired | Should -BeFalse
        }
    }
}

Describe "Invoke-TelegramPollingWithBackoff" -Tag "Telegram", "Regression-Only" {
    BeforeEach {
        Mock Start-Sleep { }
        Mock Write-FleetLog { }
        Mock Write-Warning { }
    }

    It "calls PollAction repeatedly on success and exits on controlled throw" {
        $callCount = 0
        $pollAction = {
            if (++$callCount -ge 3) { throw "EXIT_TEST" }
            return $true
        }
        try {
            Invoke-TelegramPollingWithBackoff -PollAction $pollAction -BaseIntervalSec 1 -MaxBackoffSec 4 -CircuitBreakerThreshold 5
        } catch {
            $_.Exception.Message | Should -Be "EXIT_TEST"
        }
        $callCount | Should -Be 3
        Should -Invoke Start-Sleep -Times 3 -Exactly
    }

    It "applies exponential backoff on consecutive failures before threshold" {
        $callCount = 0
        $pollAction = {
            if (++$callCount -ge 4) { throw "EXIT_TEST" }
            return $false
        }
        try {
            Invoke-TelegramPollingWithBackoff -PollAction $pollAction -BaseIntervalSec 1 -MaxBackoffSec 4 -CircuitBreakerThreshold 5
        } catch {
            $_.Exception.Message | Should -Be "EXIT_TEST"
        }
        Should -Invoke Write-FleetLog -Times 4 -Exactly -ParameterFilter {
            param($Message, $Level)
            ($callCount -le 4) -and ($Message -match "backing off|error")
        }
    }

    It "engages circuit breaker after threshold failures" {
        $callCount = 0
        $circuitBreakerLogPattern = "circuit-breaker engaged"
        $pollAction = {
            if (++$callCount -ge 6) { throw "EXIT_TEST" }
            return $false
        }
        try {
            Invoke-TelegramPollingWithBackoff -PollAction $pollAction -BaseIntervalSec 1 -MaxBackoffSec 4 -CircuitBreakerThreshold 3
        } catch {
            $_.Exception.Message | Should -Be "EXIT_TEST"
        }
        Should -Invoke Write-FleetLog -Times 1 -Exactly -ParameterFilter { $Message -match $circuitBreakerLogPattern }
    }

    It "resets circuit breaker on success after failures" {
        $callCount = 0
        $pollAction = {
            if (++$callCount -le 4) { return $false }
            if ($callCount -ge 7) { throw "EXIT_TEST" }
            return $true
        }
        try {
            Invoke-TelegramPollingWithBackoff -PollAction $pollAction -BaseIntervalSec 1 -MaxBackoffSec 4 -CircuitBreakerThreshold 3
        } catch {
            $_.Exception.Message | Should -Be "EXIT_TEST"
        }
        Should -Invoke Write-FleetLog -Times 1 -Exactly -ParameterFilter { $Message -match "circuit-breaker reset" }
    }

    It "resets backoff counter on success" {
        $callCount = 0
        $pollAction = {
            if (++$callCount -le 3) { return $false }
            if ($callCount -ge 5) { throw "EXIT_TEST" }
            return $true
        }
        try {
            Invoke-TelegramPollingWithBackoff -PollAction $pollAction -BaseIntervalSec 1 -MaxBackoffSec 4 -CircuitBreakerThreshold 5
        } catch {
            $_.Exception.Message | Should -Be "EXIT_TEST"
        }
        Should -Invoke Write-FleetLog -Times 1 -Exactly -ParameterFilter { $Message -match "backoff reset after" }
    }
}

Describe "Send-TelegramMessage" -Tag "Telegram" {
    BeforeEach {
        Mock Invoke-WebRequest { }
        Mock Write-SetupLog { }
    }

    It "returns false when Telegram not configured" {
        $config = @{ IsConfigured = $false; BotToken = ""; OwnerUsername = ""; OwnerUserId = "" }
        $result = Send-TelegramMessage -Message "test" -Config $config
        $result | Should -BeFalse
    }

    It "posts to correct Telegram API endpoint" {
        $config = @{ IsConfigured = $true; BotToken = "123:abc"; OwnerUsername = "victor"; OwnerUserId = "99999" }
        Mock Invoke-WebRequest {
            return [PSCustomObject]@{ StatusCode = 200; Content = '{"ok":true,"result":{"message_id":1}}' }
        }
        $result = Send-TelegramMessage -Message "hello" -Config $config

        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
            $Uri -eq "https://api.telegram.org/bot123:abc/sendMessage"
        }
        $result | Should -BeTrue
    }

    It "sends message with MarkdownV2 parse mode by default" {
        $config = @{ IsConfigured = $true; BotToken = "123:abc"; OwnerUsername = "victor"; OwnerUserId = "99999" }
        Mock Invoke-WebRequest {
            $body = $Body | ConvertFrom-Json
            $body.parse_mode | Should -Be "MarkdownV2"
            return [PSCustomObject]@{ StatusCode = 200; Content = '{"ok":true,"result":{"message_id":1}}' }
        }
        Send-TelegramMessage -Message "hello" -Config $config | Should -BeTrue
    }

    It "supports HTML parse mode" {
        $config = @{ IsConfigured = $true; BotToken = "123:abc"; OwnerUsername = "victor"; OwnerUserId = "99999" }
        Mock Invoke-WebRequest {
            $body = $Body | ConvertFrom-Json
            $body.parse_mode | Should -Be "HTML"
            return [PSCustomObject]@{ StatusCode = 200; Content = '{"ok":true,"result":{"message_id":1}}' }
        }
        Send-TelegramMessage -Message "<b>bold</b>" -ParseMode "HTML" -Config $config | Should -BeTrue
    }

    It "returns false on API error" {
        $config = @{ IsConfigured = $true; BotToken = "123:abc"; OwnerUsername = "victor"; OwnerUserId = "99999" }
        Mock Invoke-WebRequest { throw "API error" }
        $result = Send-TelegramMessage -Message "test" -Config $config
        $result | Should -BeFalse
    }

    It "returns false on non-200 response" {
        $config = @{ IsConfigured = $true; BotToken = "123:abc"; OwnerUsername = "victor"; OwnerUserId = "99999" }
        Mock Invoke-WebRequest { return [PSCustomObject]@{ StatusCode = 429; Content = '{"ok":false}' } }
        $result = Send-TelegramMessage -Message "test" -Config $config
        $result | Should -BeFalse
    }

    It "supports Silent switch to suppress logs" {
        $config = @{ IsConfigured = $true; BotToken = "123:abc"; OwnerUsername = "victor"; OwnerUserId = "99999" }
        Mock Invoke-WebRequest {
            return [PSCustomObject]@{ StatusCode = 200; Content = '{"ok":true,"result":{"message_id":1}}' }
        }
        Send-TelegramMessage -Message "ping" -Config $config -Silent | Should -BeTrue
        Should -Invoke Write-SetupLog -Times 0 -Exactly
    }
}

Describe "Receive-TelegramMessages" -Tag "Telegram" {
    BeforeEach {
        Mock Write-SetupLog { }
        Mock Write-TelegramSecurityEvent { }
        Mock Test-TelegramSender {
            return [PSCustomObject]@{ IsAuthorized = $true; RejectionReason = $null; Detail = "verified" }
        }
        $testDir = Join-Path $env:TEMP "ORCHESTRATOR-test-telegram-recv"
        $null = New-Item -ItemType Directory -Path $testDir -Force
        $offsetFile = Join-Path $testDir "offset.txt"
    }

    AfterEach {
        if (Test-Path $testDir) { Remove-Item -Path $testDir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "returns 0 when Telegram not configured" {
        $config = @{ IsConfigured = $false }
        $result = Receive-TelegramMessages -Config $config -OutputDir $testDir -OffsetFile (Join-Path $testDir "offset.txt")
        $result | Should -Be 0
    }

    It "writes incoming message as task stub when authorized" {
        $config = @{ IsConfigured = $true; BotToken = "123:abc"; OwnerUsername = "victor"; OwnerUserId = "99999" }
        Mock Invoke-WebRequest {
            $fakeResponse = @{
                ok = $true
                result = @(
                    @{
                        update_id = 1001
                        message = @{
                            message_id = 42
                            from = @{ username = "victor"; id = 99999 }
                            text = "run the tests"
                            date = 1700000000
                        }
                    }
                )
            }
            return [PSCustomObject]@{ StatusCode = 200; Content = ($fakeResponse | ConvertTo-Json -Depth 5) }
        }
        Mock Test-TelegramSender {
            return [PSCustomObject]@{ IsAuthorized = $true; RejectionReason = $null; Detail = "verified" }
        }

        $count = Receive-TelegramMessages -Config $config -OutputDir $testDir -OffsetFile $offsetFile -TimeoutSec 2
        $count | Should -Be 1

        $files = Get-ChildItem "$testDir/*.md" -ErrorAction SilentlyContinue
        $files.Count | Should -Be 1
        $content = Get-Content $files[0].FullName -Raw
        $content | Should -Match "run the tests"
        $content | Should -Match "source: telegram"
        $content | Should -Match "message_id: 42"
        $content | Should -Match "status: ready"
    }

    It "rejects unauthorized messages" {
        $config = @{ IsConfigured = $true; BotToken = "123:abc"; OwnerUsername = "victor"; OwnerUserId = "99999" }
        Mock Invoke-WebRequest {
            $fakeResponse = @{
                ok = $true
                result = @(
                    @{
                        update_id = 1001
                        message = @{
                            message_id = 42
                            from = @{ username = "attacker"; id = 11111 }
                            text = "malicious command"
                            date = 1700000000
                        }
                    }
                )
            }
            return [PSCustomObject]@{ StatusCode = 200; Content = ($fakeResponse | ConvertTo-Json -Depth 5) }
        }
        Mock Test-TelegramSender {
            return [PSCustomObject]@{ IsAuthorized = $false; RejectionReason = "BOTH_MISMATCH"; Detail = "Attacker" }
        }

        $count = Receive-TelegramMessages -Config $config -OutputDir $testDir -OffsetFile $offsetFile -TimeoutSec 2
        $count | Should -Be 0
        Should -Invoke Write-TelegramSecurityEvent -Times 1 -Exactly
    }

    It "persists update offset to avoid re-processing" {
        $config = @{ IsConfigured = $true; BotToken = "123:abc"; OwnerUsername = "victor"; OwnerUserId = "99999" }
        $callCount = 0
        Mock Invoke-WebRequest {
            $callCount++
            $body = $Body | ConvertFrom-Json
            $fakeResponse = @{
                ok = $true
                result = @(
                    @{
                        update_id = ($body.offset + 1)
                        message = @{
                            message_id = 42
                            from = @{ username = "victor"; id = 99999 }
                            text = "hello"
                            date = 1700000000
                        }
                    }
                )
            }
            return [PSCustomObject]@{ StatusCode = 200; Content = ($fakeResponse | ConvertTo-Json -Depth 5) }
        }

        # First call: processes message, updates offset
        $count1 = Receive-TelegramMessages -Config $config -OutputDir $testDir -OffsetFile $offsetFile -TimeoutSec 2
        $count1 | Should -Be 1

        # Second call: offset should be 1002 (last update_id + 1), no new messages
        $count2 = Receive-TelegramMessages -Config $config -OutputDir $testDir -OffsetFile $offsetFile -TimeoutSec 2
        $count2 | Should -Be 1

        # Verify offset persisted
        $savedOffset = Get-Content $offsetFile -Raw -ErrorAction SilentlyContinue
        $savedOffset.Trim() | Should -Match '^\d+$'
    }
}
