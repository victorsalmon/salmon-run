function Invoke-SalmonRunPesterSuite {
    <#
    .SYNOPSIS
        Runs a Pester test suite and returns a normalized pass/fail/summary.
    .DESCRIPTION
        Discovers *.Tests.ps1 files under Path, invokes Pester, and returns
        a PSCustomObject with Totals, Passed, Failed, and a Results array.
    .PARAMETER Path
        Directory or list of directories to scan for Pester tests.
    .PARAMETER Output
        Pester output level. Default 'Normal'.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [string[]]$Path,

        [ValidateSet('None', 'Normal', 'Detailed', 'Diagnostic')]
        [string]$Output = 'Normal'
    )

    $allTests = @()
    foreach ($p in $Path) {
        if (Test-Path -LiteralPath $p -PathType Container) {
            $allTests += Get-ChildItem -Path $p -Filter '*.Tests.ps1' -Recurse -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName
        } elseif (Test-Path -LiteralPath $p -PathType Leaf) {
            $allTests += $p
        }
    }

    $allTests = @($allTests | Select-Object -Unique)
    if ($allTests.Count -eq 0) {
        return [PSCustomObject]@{ Totals = 0; Passed = 0; Failed = 0; Skipped = 0; Results = @() }
    }

    try {
        $result = Invoke-Pester -Path $allTests -Output $Output -PassThru -ErrorAction Stop
    } catch {
        return [PSCustomObject]@{ Totals = 0; Passed = 0; Failed = 0; Skipped = 0; Error = $_.Exception.Message; Results = @() }
    }

    return [PSCustomObject]@{
        Totals  = $result.TotalCount
        Passed  = $result.PassedCount
        Failed  = $result.FailedCount
        Skipped = $result.SkippedCount
        Results = $result.Tests
    }
}
