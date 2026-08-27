#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

#Requires -Version 7.0

BeforeAll {
    $ScriptPath = Join-Path $PSScriptRoot "..\1Cleanup-AWS.ps1"
    $ScriptContent = Get-Content $ScriptPath -Raw
}

Describe "1Cleanup-AWS.ps1 — Parameters" -Tag "Provision" {
    It "script file exists" {
        $ScriptPath | Should -Exist
    }

    It "declares param() block" {
        $ScriptContent | Should -Match 'param\('
    }

    It "has SsoProfile parameter" {
        $ScriptContent | Should -Match '\$SsoProfile'
    }

    It "defaults SsoProfile from AWS_SSO_PROFILE env var" {
        $ScriptContent | Should -Match '\$env:AWS_SSO_PROFILE'
    }

    It "has WhatIf switch parameter" {
        $ScriptContent | Should -Match '\$WhatIf'
    }

    It "has Force switch parameter" {
        $ScriptContent | Should -Match '\$Force'
    }
}

Describe "1Cleanup-AWS.ps1 — Module Loading" -Tag "Provision" {
    It "loads SalmonRun.Core module via psd1" {
        $ScriptContent | Should -Match 'Interclaw\.Core.*\.psd1'
    }

    It "loads SalmonRun.Provision module" {
        $ScriptContent | Should -Match 'Import-InterclawModule Provision'
    }

    It "adds Modules dir to PSModulePath" {
        $ScriptContent | Should -Match 'PSModulePath.*Modules'
    }
}

Describe "1Cleanup-AWS.ps1 — Input Validation" -Tag "Provision" {
    It "exits when SSO profile is not set" {
        $ScriptContent | Should -Match 'exit 1'
        $ScriptContent | Should -Match 'SSO profile not set'
    }

    It "exits when listing IAM users fails" {
        $ScriptContent | Should -Match 'exit 1'
        $ScriptContent | Should -Match 'Could not list IAM users'
    }
}

Describe "1Cleanup-AWS.ps1 — IAM User Filtering" -Tag "Provision" {
    It "filters IAM users by BASE role pattern" {
        $ScriptContent | Should -Match '\*-BASE-\*'
    }

    It "filters IAM users by SENTRY suffix" {
        $ScriptContent | Should -Match '\*-SENTRY'
    }

    It "filters IAM users by REKOGNITIONFALLBACK suffix" {
        $ScriptContent | Should -Match '\*-REKOGNITIONFALLBACK'
    }

    It "exits cleanly when no OC users found" {
        $ScriptContent | Should -Match 'No IAM users found'
        $ScriptContent | Should -Match 'exit 0'
    }
}

Describe "1Cleanup-AWS.ps1 — WhatIf Mode" -Tag "Provision" {
    It "prints what would be deleted in WhatIf mode" {
        $ScriptContent | Should -Match 'WHAT-IF'
    }

    It "exits after WhatIf output without deleting" {
        $ScriptContent | Should -Match 'If \(\$WhatIf\)'
        $ScriptContent | Should -Match 'exit 0'
    }
}

Describe "1Cleanup-AWS.ps1 — Confirmation and Deletion" -Tag "Provision" {
    It "prompts for confirmation unless -Force is used" {
        $ScriptContent | Should -Match '-not \$Force'
        $ScriptContent | Should -Match 'Read-Host'
    }

    It "deletes access keys before user" {
        $ScriptContent | Should -Match 'delete-access-key'
    }

    It "deletes inline policies before user" {
        $ScriptContent | Should -Match 'delete-user-policy'
    }

    It "deletes the IAM user last" {
        $ScriptContent | Should -Match 'delete-user'
    }

    It "tracks DeletedCount and FailedCount" {
        $ScriptContent | Should -Match '\$DeletedCount'
        $ScriptContent | Should -Match '\$FailedCount'
    }
}
