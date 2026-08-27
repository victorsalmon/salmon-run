#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }
#Requires -Version 7.0

BeforeAll {
    $__RepoRoot = (Get-Item $PSCommandPath).Directory.Parent.FullName
    $script:LeakCheckScript = Join-Path $__RepoRoot 'scripts' 'Invoke-LeakCheck.ps1'
}

Describe 'Leak check' -Tag 'LeakCheck', 'Regression-Only' {
    It 'reports no private references in the public package' {
        $proc = Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$script:LeakCheckScript,'-SearchRoot',$__RepoRoot) -Wait -PassThru -NoNewWindow
        $proc.ExitCode | Should -Be 0
    }

    It 'detects an injected private reference' {
        $tempRoot = Join-Path $TestDrive 'leak-check-test'
        $null = New-Item -ItemType Directory -Path $tempRoot -Force

        # Build the bad string at runtime so the test file itself does not
        # contain a literal leak-pattern match.
        $badPath = 'C:' + '\Users\' + 'RDP' + '\secret.txt'
        $badFile = Join-Path $tempRoot 'leaked.txt'
        ("private path $badPath") | Set-Content -LiteralPath $badFile -Encoding utf8

        $proc = Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$script:LeakCheckScript,'-SearchRoot',$tempRoot) -Wait -PassThru -NoNewWindow
        $proc.ExitCode | Should -Be 1
    }

    It 'allows package.json repository URL with the public origin' {
        $tempRoot = Join-Path $TestDrive 'leak-check-package'
        $null = New-Item -ItemType Directory -Path $tempRoot -Force

        # Build the public URL at runtime to avoid matching private/fleet patterns.
        $publicUrl = 'https://' + 'worktree' + '.ca/' + 'clock' + 'lobster' + '/salmon-run.git'
        $pkg = @{ name = 'test'; repository = @{ type = 'git'; url = $publicUrl } }
        $pkg | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $tempRoot 'package.json') -Encoding utf8

        $proc = Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$script:LeakCheckScript,'-SearchRoot',$tempRoot) -Wait -PassThru -NoNewWindow
        $proc.ExitCode | Should -Be 0
    }
}
