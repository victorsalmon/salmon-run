#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

#Requires -Version 7.0

BeforeAll {
    $ScriptPath = Join-Path $PSScriptRoot "..\1Install.ps1"
    $ScriptContent = Get-Content $ScriptPath -Raw
}

Describe "1Install.ps1 — Structure and Constants" -Tag "Host" {
    It "script file exists" {
        $ScriptPath | Should -Exist
    }

    It "defines InstallConstants hashtable" {
        $ScriptContent | Should -Match '\$InstallConstants\s*=\s*@\{'
    }

    It "InstallConstants contains RestartDelaySec" {
        $ScriptContent | Should -Match 'RestartDelaySec'
    }

    It "InstallConstants contains DockerDaemonMaxAttempts" {
        $ScriptContent | Should -Match 'DockerDaemonMaxAttempts'
    }

    It "InstallConstants contains DockerDaemonRetryIntervalSec" {
        $ScriptContent | Should -Match 'DockerDaemonRetryIntervalSec'
    }

    It "has admin elevation check at the top" {
        $ScriptContent | Should -Match 'IsInRole.*Administrator'
    }

    It "loads SalmonRun.Core module via Initialize-InterclawEnvironment" {
        $ScriptContent | Should -Match 'Initialize-InterclawEnvironment'
    }

    It "calls Import-InterclawModule Core" {
        $ScriptContent | Should -Match "Import-InterclawModule Core"
    }
}

Describe "1Install.ps1 — Winget Application Definitions" -Tag "Host" {
    It "defines PowerShell 7 app" {
        $ScriptContent | Should -Match 'Microsoft.PowerShell'
    }

    It "defines Git app" {
        $ScriptContent | Should -Match 'Git.Git'
    }

    It "defines AWS CLI app" {
        $ScriptContent | Should -Match 'Amazon.AWSCLI'
    }

    It "defines Docker Desktop app with ExePath variable" {
        $ScriptContent | Should -Match 'Docker.DockerDesktop'
        $ScriptContent | Should -Match '\$dockerDesktopExe'
        $ScriptContent | Should -Match 'Docker Desktop\.exe'
    }

    It "defines Tailscale app" {
        $ScriptContent | Should -Match 'Tailscale.Tailscale'
    }

    It "uses Invoke-NativeCommand for winget operations" {
        $ScriptContent | Should -Match 'Invoke-NativeCommand.*winget'
    }
}

Describe "1Install.ps1 — Windows Version Check" -Tag "Host" {
    It "reads Windows version from registry" {
        $ScriptContent | Should -Match 'HKLM.*Windows NT\\CurrentVersion'
    }

    It "exits with code 1 when build is below 1903" {
        $ScriptContent | Should -Match 'Build.*-lt.*1903'
        $ScriptContent | Should -Match 'exit 1'
    }

    It "logs error when Windows build is too old" {
        $ScriptContent | Should -Match 'Write-SetupLog.*ERROR'
        $ScriptContent | Should -Match 'build.*1903'
    }
}

Describe "1Install.ps1 — WSL2 Feature Detection" -Tag "Host" {
    It "checks Microsoft-Windows-Subsystem-Linux feature" {
        $ScriptContent | Should -Match 'Microsoft-Windows-Subsystem-Linux'
    }

    It "checks VirtualMachinePlatform feature" {
        $ScriptContent | Should -Match 'VirtualMachinePlatform'
    }

    It "tracks NeedsRestart when enabling features" {
        $ScriptContent | Should -Match '\$NeedsRestart\s*=\s*\$true'
    }

    It "uses Get-WindowsOptionalFeature to check state" {
        $ScriptContent | Should -Match 'Get-WindowsOptionalFeature'
    }
}

Describe "1Install.ps1 — Docker Daemon Wait" -Tag "Host" {
    It "checks Docker Desktop process" {
        $ScriptContent | Should -Match 'Get-Process.*Docker Desktop'
    }

    It "starts Docker Desktop if not running" {
        $ScriptContent | Should -Match 'Start-Process \$dockerDesktopExe'
        $ScriptContent | Should -Match 'Docker Desktop\.exe'
    }

    It "uses docker info to test readiness" {
        $ScriptContent | Should -Match 'docker info'
    }

    It "exits with code 1 when Docker never becomes ready" {
        $ScriptContent | Should -Match 'exit 1'
        $ScriptContent | Should -Match 'did not become ready'
    }

    It "registers Docker Desktop boot task via Host module" {
        $ScriptContent | Should -Match 'Register-DockerDesktopBootTask'
    }
}

Describe "1Install.ps1 — AWS SSO Config Detection" -Tag "Host" {
    It "checks if ~/.aws/config exists" {
        $ScriptContent | Should -Match 'AwsConfigPath'
    }

    It "detects existing SSO session in config" {
        $ScriptContent | Should -Match 'sso-session'
    }

    It "writes SSO config with expected sections" {
        $ScriptContent | Should -Match 'sso_session'
        $ScriptContent | Should -Match 'sso_account_id'
        $ScriptContent | Should -Match 'sso_role_name'
    }
}

Describe "1Install.ps1 — Firewall Rule" -Tag "Host" {
    It "creates Interclaw-Gateway-Inbound-Block rule" {
        $ScriptContent | Should -Match 'Interclaw-Gateway-Inbound-Block'
    }

    It "uses Get-PortRegistry for port range" {
        $ScriptContent | Should -Match 'Get-PortRegistry'
    }

    It "blocks inbound TCP on Private profile" {
        $ScriptContent | Should -Match '-Profile Private'
        $ScriptContent | Should -Match '-Action Block'
        $ScriptContent | Should -Match '-Direction Inbound'
    }
}

Describe "1Install.ps1 — install.json Creation" -Tag "Host" {
    It "prompts for project code" {
        $ScriptContent | Should -Match 'Read-Host.*Project code'
    }

    It "writes install.json with Write-AtomicJson" {
        $ScriptContent | Should -Match 'Write-AtomicJson.*Depth 10'
    }

    It "sets default features with sentry enabled by default" {
        $ScriptContent | Should -Match 'sentry.*install.*\$true'
    }
}
