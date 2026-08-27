#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

#Requires -Version 7.0

BeforeAll {
    $RepoRoot = (Get-Item $PSCommandPath).Directory.Parent.Parent.Parent.FullName
    $ModulesRoot = Join-Path $RepoRoot "Skills" "Docker" "Modules"
    $script:KnownModules = Get-ChildItem -Path $ModulesRoot -Directory |
        Where-Object { $_.Name -like "SalmonRun.*" -or $_.Name -like "Interclaw.*" } |
        ForEach-Object { $_.Name }
}

Describe "RequiredModules Integrity" -Tag "ModuleDeps", "Regression-Only" {
    It "Every RequiredModules entry in psd1 points to a real module" {
        $psd1Files = Get-ChildItem -Path $ModulesRoot -Filter "*.psd1" -Recurse
        $violations = @()
        foreach ($f in $psd1Files) {
            $data = Import-PowerShellDataFile $f.FullName
            foreach ($req in @($data.RequiredModules)) {
                if ($req -is [string] -and $req -notin $script:KnownModules) {
                    $violations += "$($f.Name) requires non-existent module: $req"
                }
            }
        }
        if ($violations) {
            Write-Warning "RequiredModules violations:"
            $violations | ForEach-Object { Write-Warning "  $_" }
        }
        $violations | Should -BeNullOrEmpty
    }
}

Describe "Import-Module Integrity" -Tag "ModuleDeps", "Regression-Only" {
    It "Every Import-Module call in scripts targets a real module" {
        $scriptFiles = Get-ChildItem "$RepoRoot/Skills/Docker" -Recurse -Include *.ps1
        $violations = @()
        $pattern = 'Import-Module\s+(?:.*?\s+)?(?:-Name\s+)?["'']?((?:Interclaw|SalmonRun)\.\w+)["'']?'
        foreach ($f in $scriptFiles) {
            $matches_found = [regex]::Matches((Get-Content $f.FullName -Raw), $pattern)
            foreach ($m in $matches_found) {
                $module = $m.Groups[1].Value
                if ($module -notin $script:KnownModules -and $module -ne "Interclaw.Deprecated") {
                    $violations += "$($f.Name) imports non-existent module: $module"
                }
            }
        }
        if ($violations) {
            Write-Warning "Import-Module violations:"
            $violations | ForEach-Object { Write-Warning "  $_" }
        }
        $violations | Should -BeNullOrEmpty
    }
}

Describe "Module Hygiene - Set-StrictMode" -Tag "ModuleDeps", "Regression-Only" {
    It "All .psm1 files have Set-StrictMode -Version Latest" {
        $psm1Files = Get-ChildItem -Path $ModulesRoot -Filter "*.psm1" -Recurse
        $violations = @()
        foreach ($f in $psm1Files) {
            $content = Get-Content -Path $f.FullName -Raw
            if ($content -notmatch '(?m)^Set-StrictMode\s+-Version\s+Latest') {
                $violations += "$($f.Name)"
            }
        }
        $violations | Should -BeNullOrEmpty
    }

    It "All .psm1 files missing #Requires have been updated" {
        $psm1Files = Get-ChildItem -Path $ModulesRoot -Filter "*.psm1" -Recurse
        $violations = @()
        foreach ($f in $psm1Files) {
            $content = Get-Content -Path $f.FullName -Raw
            if ($content -notmatch '(?m)^#Requires\s+-Version\s+7\.0') {
                $violations += "$($f.Name)"
            }
        }
        $violations | Should -BeNullOrEmpty
    }
}

Describe "Module Hygiene - FunctionsToExport" -Tag "ModuleDeps", "Regression-Only" {
    It "SalmonRun.Secrets exports align with Public/ function declarations" {
        $psd1Path = Join-Path $ModulesRoot "SalmonRun.Secrets" "SalmonRun.Secrets.psd1"
        $publicDir = Join-Path $ModulesRoot "SalmonRun.Secrets" "Public"
        $data = Import-PowerShellDataFile $psd1Path
        $publicFuncs = Get-ChildItem -Path $publicDir -Filter "*.ps1" | Select-Object -ExpandProperty BaseName
        $inPsd1 = @($data.FunctionsToExport | Where-Object { $_ })
        $inPublic = [string[]]@()
        foreach ($func in $publicFuncs) {
            $content = Get-Content -Path (Join-Path $publicDir "$func.ps1") -Raw
            if ($content -match [regex]::Escape("function $func")) {
                $inPublic += $func
            }
        }
        $onlyInPsd1 = $inPsd1 | Where-Object { $_ -notin $inPublic }
        $onlyInPublic = $inPublic | Where-Object { $_ -notin $inPsd1 }
        $onlyInPsd1 | Should -BeNullOrEmpty
        $onlyInPublic | Should -BeNullOrEmpty
    }
}

Describe "Module Hygiene - RequiredModules" -Tag "ModuleDeps", "Regression-Only" {
    It "SalmonRun.Fleet declares Diagnostics in RequiredModules" {
        $psd1Path = Join-Path $ModulesRoot "SalmonRun.Fleet" "SalmonRun.Fleet.psd1"
        $data = Import-PowerShellDataFile $psd1Path
        $data.RequiredModules | Should -Contain "SalmonRun.Diagnostics"
    }

    It "SalmonRun.Images declares Diagnostics in RequiredModules" {
        $psd1Path = Join-Path $ModulesRoot "SalmonRun.Images" "SalmonRun.Images.psd1"
        $data = Import-PowerShellDataFile $psd1Path
        $data.RequiredModules | Should -Contain "SalmonRun.Diagnostics"
    }

    It "SalmonRun.Deploy declares Diagnostics in RequiredModules" {
        $psd1Path = Join-Path $ModulesRoot "SalmonRun.Deploy" "SalmonRun.Deploy.psd1"
        $data = Import-PowerShellDataFile $psd1Path
        $data.RequiredModules | Should -Contain "SalmonRun.Diagnostics"
    }
}

Describe "psd1 Field Completeness" -Tag "ModuleDeps", "Regression-Only" {
    It "Every psd1 has RootModule, Author, Description, and Version" {
        $psd1Files = Get-ChildItem -Path $ModulesRoot -Filter "*.psd1" -Recurse
        $violations = @()
        foreach ($f in $psd1Files) {
            $data = Import-PowerShellDataFile $f.FullName
            foreach ($field in @("RootModule", "Author", "Description", "ModuleVersion")) {
                if (-not $data.$field) {
                    $violations += "$($f.Name) missing $field"
                }
            }
        }
        if ($violations) {
            Write-Warning "psd1 field violations:"
            $violations | ForEach-Object { Write-Warning "  $_" }
        }
        $violations | Should -BeNullOrEmpty
    }
}
