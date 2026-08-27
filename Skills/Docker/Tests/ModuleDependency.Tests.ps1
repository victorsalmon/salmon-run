#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

#Requires -Version 7.0

Describe "Module Dependency Graph" -Tag "ModuleDependency", "CI" {
    BeforeAll {
        $RepoRoot = (Get-Item $PSCommandPath).Directory.Parent.Parent.Parent.FullName
        $ModulesRoots = @(
            (Join-Path $RepoRoot "Skills" "Docker" "Modules"),
            (Join-Path $RepoRoot "Orchestrator" "Modules")
        )

        function Get-ModuleDependencyGraph {
            param([string[]]$ModulesRoots)

            $graph = @{}
            $psd1Files = Get-ChildItem -Path $ModulesRoots -Filter "*.psd1" -Recurse
            foreach ($f in $psd1Files) {
                $moduleName = $f.Directory.Name
                $data = Import-PowerShellDataFile $f.FullName -ErrorAction SilentlyContinue
                if (-not $data) { continue }
                $deps = @($data.RequiredModules) | Where-Object { $_ -is [string] -and $_ -match '^(Interclaw|SalmonRun)\.' }
                $graph[$moduleName] = $deps
            }
            return $graph
        }

        function Find-DependencyCycles {
            param([hashtable]$Graph)

            $cycles = @()
            $visited = @{}
            $recStack = @{}
            $path = @()

            function Visit($node) {
                if ($recStack[$node]) { return }
                if ($visited[$node]) { return }
                $visited[$node] = $true
                $recStack[$node] = $true
                $path += $node

                foreach ($dep in @($Graph[$node])) {
                    if ($recStack[$dep]) {
                        $cyclePath = @()
                        $capture = $false
                        foreach ($n in $path) {
                            if ($n -eq $dep -or $capture) {
                                $capture = $true
                                $cyclePath += $n
                            }
                        }
                        $cyclePath += $dep
                        $cycles += ,$cyclePath
                    }
                    elseif (-not $visited[$dep]) {
                        Visit $dep
                    }
                }

                $recStack[$node] = $false
                $path = $path[0..($path.Count - 2)]
            }

            foreach ($node in $Graph.Keys) {
                if (-not $visited[$node]) {
                    Visit $node
                }
            }

            return $cycles
        }
    }
    It "Has no circular dependencies between modules" {
        $graph = Get-ModuleDependencyGraph -ModulesRoots $ModulesRoots
        $cycles = Find-DependencyCycles -Graph $graph

        if ($cycles.Count -gt 0) {
            $msg = "Circular dependencies detected:`n"
            foreach ($cycle in $cycles) {
                $msg += "  Cycle: $($cycle -join ' -> ')`n"
            }
            Write-Warning $msg
        }
        $cycles.Count | Should -Be 0
    }

    It "Every module in the graph is a known module" {
        $knownModules = Get-ChildItem -Path $ModulesRoots -Directory |
            Where-Object { $_.Name -match '^(Interclaw|SalmonRun)\.' } |
            ForEach-Object { $_.Name }
        $graph = Get-ModuleDependencyGraph -ModulesRoots $ModulesRoots
        $unknownDeps = @()
        foreach ($module in $graph.Keys) {
            foreach ($dep in $graph[$module]) {
                if ($dep -notin $knownModules) {
                    $unknownDeps += "$module -> $dep"
                }
            }
        }
        $unknownDeps | Should -BeNullOrEmpty
    }
}
