function Invoke-SalmonRunAQE {
    <#
    .SYNOPSIS
        Runs the full salmon-run AQE quality-gate suite.
    .DESCRIPTION
        Executes Pester tests, documentation lint, and an optional AQE bridge
        scan. Returns a single report object with pass/fail status for each
        gate. The AQE bridge is best-effort and does not fail the overall run.
    .PARAMETER RepoDir
        Repository root. Defaults to Get-SalmonRunRepoRoot.
    .PARAMETER TestPaths
        Directories/files to scan for Pester tests. Default is @('Tests','Skills/QA').
    .PARAMETER RunBridge
        Whether to attempt an AQE bridge call. Default is true only when the URI is set.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [string]$RepoDir = (Get-SalmonRunRepoRoot),

        [string[]]$TestPaths = @(
            'Tests',
            'Skills/QA'
        ),

        [switch]$RunBridge = ($null -ne $env:SALMON_AQE_BRIDGE_URI)
    )

    $resolvedPaths = $TestPaths | ForEach-Object { Join-Path $RepoDir $_ }

    $pester = Invoke-SalmonRunPesterSuite -Path $resolvedPaths
    $docLint = Invoke-SalmonRunDocLint -RepoDir $RepoDir

    $bridge = $null
    if ($RunBridge -and $env:SALMON_AQE_BRIDGE_URI) {
        $bridge = Invoke-SalmonRunAQEBridge -Payload @{
            repo    = $RepoDir
            pester  = @{
                totals  = $pester.Totals
                passed  = $pester.Passed
                failed  = $pester.Failed
                skipped = $pester.Skipped
            }
            docLint = @{
                passed = $docLint.Passed
                errors = $docLint.Errors
            }
        }
    }

    $allPassed = ($pester.Failed -eq 0) -and $docLint.Passed

    return [PSCustomObject]@{
        Passed    = $allPassed
        Pester    = $pester
        DocLint   = $docLint
        Bridge    = $bridge
        Timestamp = (Get-Date -Format 'o')
    }
}
