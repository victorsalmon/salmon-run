BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
    $scriptPath = Join-Path $repoRoot 'Skills\Documentation\Scripts\Invoke-WriteVerification.ps1'
    $testDir = Join-Path ([System.IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString())
    $null = New-Item -ItemType Directory -Path $testDir -Force
}

AfterAll {
    Remove-Item $testDir -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-WriteVerification' -Tag 'Documentation', 'Regression' {
    It 'Passes when the expected snippet is present' {
        $file = Join-Path $testDir 'present.txt'
        "hello world`nextra" | Out-File -FilePath $file -Encoding utf8
        $result = & $scriptPath -Path $file -Contains 'hello world'
        $result.Verified | Should -Be $true
        $result.Length | Should -BeGreaterThan 0
    }

    It 'Fails when the expected snippet is missing' {
        $file = Join-Path $testDir 'missing.txt'
        "goodbye" | Out-File -FilePath $file -Encoding utf8
        { & $scriptPath -Path $file -Contains 'hello world' } | Should -Throw '*expected snippet not found*'
    }

    It 'Fails when the file does not exist' {
        $file = Join-Path $testDir 'nonexistent.txt'
        { & $scriptPath -Path $file -Contains 'anything' } | Should -Throw '*file not found*'
    }

    It 'Fails when the SHA256 hash does not match' {
        $file = Join-Path $testDir 'hash.txt'
        "content" | Out-File -FilePath $file -Encoding utf8
        { & $scriptPath -Path $file -ExpectedHash '0000000000000000000000000000000000000000000000000000000000000000' } | Should -Throw '*hash mismatch*'
    }

    It 'Passes when the full expected content matches' {
        $file = Join-Path $testDir 'full.txt'
        "line one`r`nline two" | Out-File -FilePath $file -Encoding utf8
        $result = & $scriptPath -Path $file -ExpectedContent "line one`nline two"
        $result.Verified | Should -Be $true
    }

    It 'Fails when the full expected content does not match' {
        $file = Join-Path $testDir 'mismatch.txt'
        "actual" | Out-File -FilePath $file -Encoding utf8
        { & $scriptPath -Path $file -ExpectedContent 'expected' } | Should -Throw '*full content mismatch*'
    }

    It 'Matches a regex pattern' {
        $file = Join-Path $testDir 'regex.txt'
        "version 1.2.3" | Out-File -FilePath $file -Encoding utf8
        $result = & $scriptPath -Path $file -Match '\d+\.\d+\.\d+'
        $result.Verified | Should -Be $true
    }
}
