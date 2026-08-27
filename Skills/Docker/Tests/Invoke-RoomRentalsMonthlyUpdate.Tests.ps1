#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

<#
.DEPRECATED
    Tests for the monthly update wrappers. The wrappers are superseded by
    the PRP pipeline (Invoke-PrpStepDG-DataGathering.ps1 etc.). These tests
    are preserved as reference for porting patterns to any future PRP tests.
#>

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..\..")
    $roomRentalsWrapper = Join-Path $repoRoot "Skills\Bookkeeping\Scripts\Invoke-RoomRentalsMonthlyUpdate.ps1"
    $intersiteWrapper   = Join-Path $repoRoot "Skills\Bookkeeping\Scripts\Invoke-IntersiteMonthlyUpdate.ps1"
    $buildTas           = Join-Path $repoRoot "Skills\Bookkeeping\Scripts\reconciliation\Build-TAS.ps1"
    $intersiteTas       = Join-Path $repoRoot "Skills\Bookkeeping\Scripts\reconciliation\Build-IntersiteTAS.ps1"
}

Describe "Invoke-RoomRentalsMonthlyUpdate.ps1 structure" -Tag "Bookkeeping", "MonthlyUpdate" {
    It "script exists" {
        $roomRentalsWrapper | Should -Exist
    }

    It "declares -WhatIf param" {
        $content = Get-Content $roomRentalsWrapper -Raw
        $content | Should -Match '\[switch\]\$WhatIf'
    }

    It "exports the room-rentals entity (not intersite-consulting)" {
        $content = Get-Content $roomRentalsWrapper -Raw
        $content | Should -Match 'entity\s*=\s*"room-rentals"'
        $content | Should -Not -Match 'entity\s*=\s*"intersite-consulting"'
    }

    It "calls /zoho/transactions/export endpoint" {
        $content = Get-Content $roomRentalsWrapper -Raw
        $content | Should -Match '/zoho/transactions/export'
    }

    It "invokes Build-TAS.ps1 (room-rentals)" {
        $content = Get-Content $roomRentalsWrapper -Raw
        $content | Should -Match 'Build-TAS\.ps1'
        $content | Should -Not -Match 'Build-IntersiteTAS\.ps1'
    }

    It "uses the 3 expected rental account slugs (fra, mlm, tmh)" {
        $content = Get-Content $roomRentalsWrapper -Raw
        $content | Should -Match '"fra"'
        $content | Should -Match '"mlm"'
        $content | Should -Match '"tmh"'
    }

    It "rejects em dashes in user-facing strings (Windows PS 5.1 codepage safety)" {
        $content = Get-Content $roomRentalsWrapper -Raw
        $content.Contains([char]0x2014) | Should -BeFalse -Because "em dash breaks .ps1 parsing under default `bash` -> `powershell` (Windows PS 5.1) invocation"
    }
}

Describe "Invoke-RoomRentalsMonthlyUpdate.ps1 + Invoke-IntersiteMonthlyUpdate.ps1 are parallel" -Tag "Bookkeeping", "MonthlyUpdate", "Regression-Only" {
    BeforeAll {
        $intersite = (Get-Content $intersiteWrapper -Raw) -split "`n"
        $roomRentals = (Get-Content $roomRentalsWrapper -Raw) -split "`n"
    }

    It "both use the same Step 1 export endpoint" {
        $intersiteOut   = ($intersite   | Select-String -Pattern '/zoho/transactions/export').Count
        $roomRentalsOut = ($roomRentals | Select-String -Pattern '/zoho/transactions/export').Count
        $roomRentalsOut | Should -BeGreaterOrEqual 1
        $intersiteOut   | Should -BeGreaterOrEqual 1
    }

    It "both call docker ps to find the Bookkeeping container" {
        $roomRentals | Where-Object { $_ -match 'docker\s+ps\s+--filter\s+name=FRAD_is-bookkeeping' } | Should -Not -BeNullOrEmpty
        $intersite   | Where-Object { $_ -match 'docker\s+ps\s+--filter\s+name=FRAD_is-bookkeeping' } | Should -Not -BeNullOrEmpty
    }

    It "both pull the fleet API token from the container" {
        $roomRentals | Where-Object { $_ -match '/run/secrets/fleet_api_token' } | Should -Not -BeNullOrEmpty
        $intersite   | Where-Object { $_ -match '/run/secrets/fleet_api_token' } | Should -Not -BeNullOrEmpty
    }
}

Describe "Monthly update workflow event logging" -Tag "Bookkeeping", "MonthlyUpdate", "Logging" {
    BeforeAll {
        $logFile = Join-Path $repoRoot "Tasks/Logs/workflow-events.log"
    }

    It "Invoke-RoomRentalsMonthlyUpdate.ps1 defines an Emit-MonthlyUpdateEvent function" {
        $content = Get-Content $roomRentalsWrapper -Raw
        $content | Should -Match 'function Emit-MonthlyUpdateEvent'
    }

    It "Invoke-IntersiteMonthlyUpdate.ps1 defines an Emit-MonthlyUpdateEvent function" {
        $content = Get-Content $intersiteWrapper -Raw
        $content | Should -Match 'function Emit-MonthlyUpdateEvent'
    }

    It "both wrappers emit a MONTHLY_UPDATE_START event" {
        $roomRentalsContent = Get-Content $roomRentalsWrapper -Raw
        $intersiteContent   = Get-Content $intersiteWrapper -Raw
        $roomRentalsContent | Should -Match '"MONTHLY_UPDATE_START"'
        $intersiteContent   | Should -Match '"MONTHLY_UPDATE_START"'
    }

    It "both wrappers emit a MONTHLY_UPDATE_END event" {
        $roomRentalsContent = Get-Content $roomRentalsWrapper -Raw
        $intersiteContent   = Get-Content $intersiteWrapper -Raw
        $roomRentalsContent | Should -Match '"MONTHLY_UPDATE_END"'
        $intersiteContent   | Should -Match '"MONTHLY_UPDATE_END"'
    }

    It "both wrappers tag phase as cowork" {
        $roomRentalsContent = Get-Content $roomRentalsWrapper -Raw
        $intersiteContent   = Get-Content $intersiteWrapper -Raw
        $roomRentalsContent | Should -Match 'phase\s*=\s*"cowork"'
        $intersiteContent   | Should -Match 'phase\s*=\s*"cowork"'
    }

    It "start event detail includes entity and mode" {
        $roomRentalsContent = Get-Content $roomRentalsWrapper -Raw
        $intersiteContent   = Get-Content $intersiteWrapper -Raw
        $roomRentalsContent | Should -Match 'entity=room-rentals mode='
        $intersiteContent   | Should -Match 'entity=intersite-consulting mode='
    }

    It "end event detail includes duration and totals" {
        $roomRentalsContent = Get-Content $roomRentalsWrapper -Raw
        $roomRentalsContent | Should -Match 'duration='
        $roomRentalsContent | Should -Match 'totalTxns='
        $roomRentalsContent | Should -Match 'copiedFiles='
        $roomRentalsContent | Should -Match 'tasRows='
    }

    It "the workflow events log has at least one MONTHLY_UPDATE entry from this session" {
        $repoRootLocal = Resolve-Path (Join-Path $PSScriptRoot "..\..\..")
        $logFileLocal = Join-Path $repoRootLocal "Tasks/Logs/workflow-events.log"
        if (-not (Test-Path $logFileLocal)) {
            Set-ItResult -Skipped -Because "workflow-events.log not present -- run a monthly update first"
            return
        }
        $entries = Get-Content $logFileLocal | Where-Object { $_ -match 'MONTHLY_UPDATE' }
        $entries.Count | Should -BeGreaterOrEqual 2 -Because "a WhatIf or Real run should produce at least a START + END event pair"
    }
}

Describe "Build-TAS.ps1 regression: .Trim() does not pass multi-char strings" -Tag "Bookkeeping", "BuildTAS", "Regression-Only" {
    It "Parse-Zoho line does not call .Trim with comma-separated multi-char string args" {
        $content = Get-Content $buildTas -Raw
        $content | Should -Not -Match '\.Trim\(.[\u2014\u2013 -]+.,\s*.[\u2014\u2013 -]+.\)' -Because "PowerShell .Trim() expects params char[]; passing 2-char strings throws 'String must be exactly one character long'. This regression surfaced in 2026-06-15 when the room-rentals wrapper first populated RBC-FRA Plaid data."
    }

    It "Trim() usages in Build-TAS.ps1 are all single-char or no-arg" {
        $content = Get-Content $buildTas -Raw
        $trimCalls = [regex]::Matches($content, '\.Trim\(([^)]*)\)')
        $violations = @()
        foreach ($m in $trimCalls) {
            $arg = $m.Groups[1].Value.Trim()
            if ($arg -eq '') { continue }                       # .Trim() — fine
            if ($arg -match "^['\""].['""]$") { continue }      # .Trim('x') single char — fine
            $violations += "line $($m.Index): .Trim($arg)"
        }
        $violations | Should -BeNullOrEmpty -Because "all .Trim() calls should be either no-arg or single-char. Multi-char strings fail at runtime in PowerShell 7."
    }
}

Describe "Build-TAS.ps1 account list matches the wrapper's accountMap" -Tag "Bookkeeping", "BuildTAS", "Regression-Only" {
    It "Build-TAS.ps1 § accounts declares 3 rental accounts" {
        $content = Get-Content $buildTas -Raw
        $slugMatches = [regex]::Matches($content, 'slug="([A-Z0-9\-]+)"')
        $slugs = $slugMatches | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
        $slugs | Should -Contain "SCOTIA-TMH"
        $slugs | Should -Contain "TD-MLM-6467010"
        $slugs | Should -Contain "RBC-FRA-5172549"
    }

    It "wrapper's zoho filename format matches Build-TAS.ps1 expected names" {
        $tasContent = Get-Content $buildTas -Raw
        $wrapperContent = Get-Content $roomRentalsWrapper -Raw
        $wrapperFilenames = [regex]::Matches($wrapperContent, 'zoho = "([^"]+)"') | ForEach-Object { $_.Groups[1].Value }
        $wrapperFilenames.Count | Should -BeGreaterOrEqual 3 -Because "wrapper must declare a zoho filename for each of the 3 rental accounts"
        foreach ($fn in $wrapperFilenames) {
            $pattern = [regex]::Escape($fn)
            $tasContent | Should -Match $pattern -Because "Build-TAS.ps1 must look up the Zoho filename the wrapper produces, otherwise Parse-Zoho will not find it."
        }
    }
}
