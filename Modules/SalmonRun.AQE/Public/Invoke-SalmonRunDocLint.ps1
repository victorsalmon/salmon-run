function Invoke-SalmonRunDocLint {
    <#
    .SYNOPSIS
        Runs the salmon-run documentation linter.
    .DESCRIPTION
        Finds and executes `C:\\Repos\\Public\\salmon-run\\Tools\\Documentation\\Scripts\\Invoke-DocLint.ps1`
        from the repository root. If the script is missing, returns a warning
        and a success status so the runner does not break.
    .PARAMETER RepoDir
        Repository root. Defaults to the current SalmonRun repo root.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [string]$RepoDir = (Get-SalmonRunRepoRoot)
    )

    $lintScript = Join-Path $RepoDir 'Tools' 'Documentation' 'Scripts' 'Invoke-DocLint.ps1'
    if (-not (Test-Path -LiteralPath $lintScript)) {
        return [PSCustomObject]@{ Passed = $true; Warnings = @('Doc lint script not found'); Errors = @() }
    }

    try {
        $output = & $lintScript -RepoRoot $RepoDir 2>&1
        $exitCode = $LASTEXITCODE
        $stderr = $output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { $_.ToString() }
        $stdout = $output | Where-Object { $_ -is [string] }
        $failed = ($exitCode -ne 0) -or ($stderr.Count -gt 0) -or ($stdout -join ' ') -match 'FAIL|ERROR'
        return [PSCustomObject]@{
            Passed   = -not $failed
            Warnings = @()
            Errors   = if ($failed) { $stderr + $stdout } else { @() }
        }
    } catch {
        return [PSCustomObject]@{ Passed = $false; Warnings = @(); Errors = @($_.Exception.Message) }
    }
}
