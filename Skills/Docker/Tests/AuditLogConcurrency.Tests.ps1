#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

#Requires -Version 7.0

BeforeAll {
    $script:WebStatePath = Join-Path $PSScriptRoot "..\Modules\SalmonRun.Web\Private\web-state.ps1"
    $script:WebWriterPath = Join-Path $PSScriptRoot "..\Modules\SalmonRun.Web\Private\Write-WebAuditEntry.ps1"
    $script:MarketerStatePath = Join-Path $PSScriptRoot "..\Modules\SalmonRun.Marketer\Private\marketer-state.ps1"
    $script:MarketerWriterPath = Join-Path $PSScriptRoot "..\Modules\SalmonRun.Marketer\Private\Write-MarketerAuditEntry.ps1"
    $script:TestDrive = Join-Path $env:TEMP "AuditLogConcurrency_$(Get-Random)"
    $null = New-Item -ItemType Directory -Path $script:TestDrive -Force
}

AfterAll {
    Remove-Item -LiteralPath $script:TestDrive -Recurse -Force -ErrorAction SilentlyContinue
}

Describe "Write-WebAuditEntry concurrency" -Tag "Web", "Regression" {
    It "preserves all 50 entries when invoked in parallel (no lost writes)" {
        $logPath = Join-Path $script:TestDrive "web-audit.jsonl"
        Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue

        1..50 | ForEach-Object -Parallel {
            $n = $_
            . $using:WebStatePath
            . $using:WebWriterPath
            $script:WebAuditLogPath = $using:logPath
            Write-WebAuditEntry -Capability 'search:tavily' -Action "parallel-write-$n" -Context @{ N = $n } -Result 'allow'
        } -ThrottleLimit 8

        $lines = Get-Content -LiteralPath $logPath -ErrorAction Stop | Where-Object { $_.Trim() }
        $lines.Count | Should -Be 50

        $entries = @($lines | ForEach-Object { $_ | ConvertFrom-Json })
        @($entries | Select-Object -ExpandProperty act -Unique).Count | Should -Be 50
        $entries.Count | Should -Be 50

        for ($i = 1; $i -lt $entries.Count; $i++) {
            $entries[$i].prev | Should -Be $entries[$i - 1].hash
        }
        $entries[0].prev | Should -Be ''
        foreach ($e in $entries) {
            $e.hash | Should -Match '^[a-f0-9]{64}$'
        }
    }
}

Describe "Write-MarketerAuditEntry concurrency" -Tag "Marketer", "Regression" {
    It "preserves all 50 entries when invoked in parallel (no lost writes)" {
        $logPath = Join-Path $script:TestDrive "marketer-audit.jsonl"
        Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue

        1..50 | ForEach-Object -Parallel {
            $n = $_
            . $using:MarketerStatePath
            . $using:MarketerWriterPath
            $script:MarketerAuditLogPath = $using:logPath
            Write-MarketerAuditEntry -Capability 'attio:read' -Action "parallel-write-$n" -Context @{ N = $n } -Result 'allow'
        } -ThrottleLimit 8

        $lines = Get-Content -LiteralPath $logPath -ErrorAction Stop | Where-Object { $_.Trim() }
        $lines.Count | Should -Be 50

        $entries = @($lines | ForEach-Object { $_ | ConvertFrom-Json })
        @($entries | Select-Object -ExpandProperty act -Unique).Count | Should -Be 50
        $entries.Count | Should -Be 50

        for ($i = 1; $i -lt $entries.Count; $i++) {
            $entries[$i].prev | Should -Be $entries[$i - 1].hash
        }
        $entries[0].prev | Should -Be ''
        foreach ($e in $entries) {
            $e.hash | Should -Match '^[a-f0-9]{64}$'
        }
    }
}
