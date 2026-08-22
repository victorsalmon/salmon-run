<#
.SYNOPSIS
    Lightweight property-based testing framework for PowerShell/Pester.

.DESCRIPTION
    Provides deterministic property testing with:
    - Explicit seeds (default 20260821)
    - Explicit numRuns (default 100)
    - Boundary-biased generators
    - Reproducible failure reporting with seed and input
    - Shrinking via seed replay

.EXAMPLE
    . (Join-Path $repoRoot 'Skills/QA/powershell-property-testing/PropertyTesting.ps1')

    $result = Invoke-Property {
        param($seed)
        $value = Get-Random -Minimum 0 -Maximum 100 -SetSeed $seed
        $output = My-Function $value
        $output | Should -BeGreaterOrEqual 0
    } -Seed 20260821 -NumRuns 100

    $result.Passed | Should -Be $true
#>

$script:DefaultSeed = 20260821
$script:DefaultNumRuns = 100

function Invoke-Property {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$Predicate,
        [int]$Seed = $script:DefaultSeed,
        [int]$NumRuns = $script:DefaultNumRuns,
        [string]$Description = "property"
    )

    $failures = @()
    $passed = $true

    for ($i = 0; $i -lt $NumRuns; $i++) {
        $runSeed = $Seed + $i
        try {
            & $Predicate $runSeed
        } catch {
            $passed = $false
            $failures += [pscustomobject]@{
                RunIndex = $i
                Seed = $runSeed
                Error = $_.Exception.Message
            }
        }
    }

    if (-not $passed) {
        $firstFailure = $failures[0]
        Write-Warning "Property '$Description' FAILED at run $($_.RunIndex) (seed $($firstFailure.Seed)): $($firstFailure.Error)"
        Write-Warning "Replay with: Invoke-Property -Seed $($firstFailure.Seed) -NumRuns 1"
    }

    return [pscustomobject]@{
        Passed = $passed
        NumRuns = $NumRuns
        Seed = $Seed
        Failures = $failures
    }
}

function New-IntGenerator {
    [CmdletBinding()]
    param(
        [int]$Min = [int]::MinValue,
        [int]$Max = [int]::MaxValue,
        [int[]]$Boundaries = @()
    )
    {
        param([int]$seed)
        $rng = [System.Random]::new($seed)
        # 20% chance to use a boundary value
        if ($Boundaries.Count -gt 0 -and $rng.Next(5) -eq 0) {
            return $Boundaries[$rng.Next($Boundaries.Count)]
        }
        return $rng.Next($Min, $Max + 1)
    }
}

function New-StringGenerator {
    [CmdletBinding()]
    param(
        [int]$MinLength = 0,
        [int]$MaxLength = 100,
        [string]$CharSet = "abcdefghijklmnopqrstuvwxyz0123456789-_., ",
        [string[]]$Boundaries = @("", "a", "null", "undefined", "test")
    )
    {
        param([int]$seed)
        $rng = [System.Random]::new($seed)
        # 20% chance to use a boundary value
        if ($Boundaries.Count -gt 0 -and $rng.Next(5) -eq 0) {
            return $Boundaries[$rng.Next($Boundaries.Count)]
        }
        $len = $rng.Next($MinLength, $MaxLength + 1)
        $chars = @()
        $charArray = $CharSet.ToCharArray()
        for ($i = 0; $i -lt $len; $i++) {
            $chars += $charArray[$rng.Next($charArray.Length)]
        }
        return -join $chars
    }
}

function New-BoundaryIntGenerator {
    [CmdletBinding()]
    param(
        [int]$Min = 0,
        [int]$Max = 100,
        [int[]]$Boundaries = @(0, 1, -1, $Min, $Max, $Min + 1, $Max - 1)
    )
    {
        param([int]$seed)
        $rng = [System.Random]::new($seed)
        # 50% chance to use a boundary value
        if ($rng.Next(2) -eq 0) {
            $valid = $Boundaries | Where-Object { $_ -ge $Min -and $_ -le $Max }
            if ($valid.Count -gt 0) {
                return $valid[$rng.Next($valid.Count)]
            }
        }
        return $rng.Next($Min, $Max + 1)
    }
}

function New-BoolGenerator {
    [CmdletBinding()]
    param()
    {
        param([int]$seed)
        $rng = [System.Random]::new($seed)
        return $rng.Next(2) -eq 0
    }
}

function New-ArrayGenerator {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$ElementGenerator,
        [int]$MinLength = 0,
        [int]$MaxLength = 10
    )
    {
        param([int]$seed)
        $rng = [System.Random]::new($seed)
        $len = $rng.Next($MinLength, $MaxLength + 1)
        $result = @()
        for ($i = 0; $i -lt $len; $i++) {
            $result += & $ElementGenerator ($seed + $i * 1000)
        }
        return $result
    }
}

# Functions are available globally when dot-sourced
