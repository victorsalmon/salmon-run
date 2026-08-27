<#
.SYNOPSIS
Prints a formatted health check results summary to the console.
#>
function Format-FleetHealthReport {
    [OutputType([void])]
    param()
    $PassCount = ($script:Results | Where-Object { $_.Passed }).Count
    $TotalCount = $script:Results.Count
    Write-Information -MessageData "`n  Passed: $PassCount / $TotalCount, Failed: $script:FailCount" -Tags "INFO"
}

