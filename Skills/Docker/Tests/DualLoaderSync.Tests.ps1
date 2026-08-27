#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

#Requires -Version 7.0

BeforeAll {
    $ModulesRoot = Join-Path (Split-Path $PSScriptRoot -Parent) "Modules"
    $script:ModuleDirs = Get-ChildItem $ModulesRoot -Directory -Filter 'Interclaw.*'
}

Describe "Dual Loader Sync" -Tag "ModuleDeps", "Regression-Only" {

    It "Every .psm1 is loadable via Import-Module" {
        $failures = @()
        foreach ($dir in $script:ModuleDirs) {
            $modName = $dir.Name
            $psm1 = Join-Path $dir.FullName "$modName.psm1"
            if (-not (Test-Path $psm1)) {
                $failures += "${modName}: missing .psm1"
                continue
            }
            try {
                Import-Module -Name $psm1 -Force -DisableNameChecking -ErrorAction Stop
                Remove-Module $modName -ErrorAction SilentlyContinue
            } catch {
                $failures += "${modName}: Import-Module failed - $($_.Exception.Message)"
            }
        }
        if ($failures) {
            Write-Warning ($failures -join "`n")
        }
        $failures | Should -BeNullOrEmpty
    }

    It "Every .ps1 loads the same functions as its .psm1" {
        $mismatches = @()
        foreach ($dir in $script:ModuleDirs) {
            $modName = $dir.Name
            $ps1File = Join-Path $dir.FullName "$modName.ps1"
            $psm1File = Join-Path $dir.FullName "$modName.psm1"

            if (-not (Test-Path $ps1File) -or -not (Test-Path $psm1File)) { continue }

            try {
                Remove-Module $modName -ErrorAction SilentlyContinue
                . $ps1File
                $ps1Functions = Get-Command -Module $modName -ErrorAction SilentlyContinue | ForEach-Object Name | Sort-Object

                Remove-Module $modName -ErrorAction SilentlyContinue
                Import-Module -Name $psm1File -Force -DisableNameChecking
                $psm1Functions = Get-Command -Module $modName -ErrorAction SilentlyContinue | ForEach-Object Name | Sort-Object

                $diff = Compare-Object $ps1Functions $psm1Functions
                if ($diff) {
                    $mismatches += "${modName}: $(($diff | ForEach-Object { "$($_.SideIndicator):$($_.InputObject)" }) -join ', ')"
                }

                Remove-Module $modName -ErrorAction SilentlyContinue
            } catch {
                $mismatches += "${modName}: test error - $($_.Exception.Message)"
            }
        }
        if ($mismatches) {
            Write-Warning ($mismatches -join "`n")
        }
        $mismatches | Should -BeNullOrEmpty
    }
}
