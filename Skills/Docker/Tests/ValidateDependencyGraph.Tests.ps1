#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

BeforeAll {
    $RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..\..")
    $script:ValidatePath = Join-Path $RepoRoot "Skills\\Orchestration\Scripts\Invoke-ValidateDependencyGraph.ps1"
    $script:TempDir = Join-Path $env:TEMP "Interclaw-Tests-DepGraph-$(Get-Random)"
    $null = New-Item -ItemType Directory -Path $script:TempDir -Force
}

AfterAll {
    if (Test-Path $script:TempDir) { Remove-Item -Recurse -Force $script:TempDir }
}

Describe "Parse DependsOn" -Tag "DependencyGraph" {
    It "returns empty list for root session (no DependsOn)" {
        $file = Join-Path $script:TempDir "session-root.md"
        Set-Content -Path $file -Value "# Test`n**Status**: ready`n"
        $null = & $script:ValidatePath -Path $script:TempDir -ExitCode
        $LASTEXITCODE | Should -Be 0
    }

    It "parses single DependsOn with status gate" {
        $d = Join-Path $script:TempDir "sub1"; $null = New-Item -ItemType Directory -Path $d -Force
        $file = Join-Path $d "2026.06.21-A-1-test.md"
        Set-Content -Path $file -Value @"
# Test
**Status**: ready
**DependsOn**: B-2 (status: reviewed)
"@
        $file2 = Join-Path $d "2026.06.21-B-2-upstream.md"
        Set-Content -Path $file2 -Value "# Upstream`n**Status**: ready`n"
        $output = & $script:ValidatePath -Path $d -Detailed -ExitCode *>&1
        $LASTEXITCODE | Should -Be 0
        $output | Should -Not -BeNullOrEmpty
    }

    It "parses multiple DependsOn entries" {
        $d = Join-Path $script:TempDir "sub2"; $null = New-Item -ItemType Directory -Path $d -Force
        $file = Join-Path $d "2026.06.21-C-1-test.md"
        Set-Content -Path $file -Value @"
# Test
**Status**: ready
**DependsOn**: A-1 (status: reviewed), B-2 (status: complete)
"@
        $file2 = Join-Path $d "2026.06.21-A-1-upstream.md"
        Set-Content -Path $file2 -Value "# A`n**Status**: ready`n"
        $file3 = Join-Path $d "2026.06.21-B-2-upstream2.md"
        Set-Content -Path $file3 -Value "# B`n**Status**: ready`n"
        $output = & $script:ValidatePath -Path $d -Detailed -ExitCode *>&1
        $LASTEXITCODE | Should -Be 0
        $output | Should -Not -BeNullOrEmpty
    }
}

Describe "Cycle detection" -Tag "DependencyGraph" {
    It "detects direct self-cycle" {
        $d = Join-Path $script:TempDir "sub3"; $null = New-Item -ItemType Directory -Path $d -Force
        $file = Join-Path $d "2026.06.21-A-1-test.md"
        Set-Content -Path $file -Value @"
# Test
**Status**: ready
**DependsOn**: A-1 (status: reviewed)
"@
        $output = & $script:ValidatePath -Path $d -ExitCode *>&1
        $LASTEXITCODE | Should -Be 1
        $output | Should -Match "FAIL"
    }

    It "detects mutual cycle between two sessions" {
        $d = Join-Path $script:TempDir "sub4"; $null = New-Item -ItemType Directory -Path $d -Force
        $file = Join-Path $d "2026.06.21-A-1-test.md"
        Set-Content -Path $file -Value @"
# Test A
**Status**: ready
**DependsOn**: B-2 (status: reviewed)
"@
        $file2 = Join-Path $d "2026.06.21-B-2-test.md"
        Set-Content -Path $file2 -Value @"
# Test B
**Status**: ready
**DependsOn**: A-1 (status: reviewed)
"@
        $output = & $script:ValidatePath -Path $d -ExitCode *>&1
        $LASTEXITCODE | Should -Be 1
        $output | Should -Match "FAIL"
    }
}

Describe "Dangling ref" -Tag "DependencyGraph" {
    It "detects ref to non-existent session" {
        $d = Join-Path $script:TempDir "sub5"; $null = New-Item -ItemType Directory -Path $d -Force
        $file = Join-Path $d "2026.06.21-A-1-test.md"
        Set-Content -Path $file -Value @"
# Test
**Status**: ready
**DependsOn**: Z-99 (status: reviewed)
"@
        $output = & $script:ValidatePath -Path $d -ExitCode *>&1
        $LASTEXITCODE | Should -Be 1
        ($output -join "`n") | Should -Match "does not match any plan file"
    }
}

Describe "Invalid status gate" -Tag "DependencyGraph" {
    It "rejects invalid status gate" {
        $d = Join-Path $script:TempDir "sub6"; $null = New-Item -ItemType Directory -Path $d -Force
        $file = Join-Path $d "2026.06.21-A-1-test.md"
        Set-Content -Path $file -Value @"
# Test
**Status**: ready
**DependsOn**: B-2 (status: invalid_gate)
"@
        $file2 = Join-Path $d "2026.06.21-B-2-upstream.md"
        Set-Content -Path $file2 -Value "# B`n**Status**: ready`n"
        $output = & $script:ValidatePath -Path $d -ExitCode -Detailed *>&1
        $LASTEXITCODE | Should -Be 1
        ($output -join "`n") | Should -Match "invalid status"
    }
}

Describe "Clean graph" -Tag "DependencyGraph" {
    It "passes a well-formed 3-session graph" {
        $d = Join-Path $script:TempDir "sub7"; $null = New-Item -ItemType Directory -Path $d -Force
        $a = Join-Path $d "2026.06.21-A-1-root.md"
        Set-Content -Path $a -Value "# A`n**Status**: ready`n"
        $b = Join-Path $d "2026.06.21-B-2-middle.md"
        Set-Content -Path $b -Value @"
# B
**Status**: ready
**DependsOn**: A-1 (status: reviewed)
"@
        $c = Join-Path $d "2026.06.21-C-3-leaf.md"
        Set-Content -Path $c -Value @"
# C
**Status**: ready
**DependsOn**: B-2 (status: reviewed)
"@
        $output = & $script:ValidatePath -Path $d -ExitCode *>&1
        $LASTEXITCODE | Should -Be 0
        $output | Should -Match "passed"
    }
}
