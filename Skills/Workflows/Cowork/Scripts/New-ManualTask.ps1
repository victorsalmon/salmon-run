function New-ManualTask {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Topic,
        [Parameter(Mandatory = $false)]
        [string]$Date = (Get-Date -Format 'yyyy-MM-dd'),
        [Parameter(Mandatory = $true)]
        [string]$OriginatingContext,
        [Parameter(Mandatory = $false)]
        [string]$DateCreated = (Get-Date -Format 'yyyy-MM-dd'),
        [Parameter(Mandatory = $true)]
        [string[]]$Steps,
        [Parameter(Mandatory = $true)]
        [string]$ExpectedOutcome,
        [Parameter(Mandatory = $true)]
        [string]$FollowUp,
        [Parameter(Mandatory = $false)]
        [string]$OutputPath,
        [Parameter(Mandatory = $false)]
        [switch]$DryRun
    )
    if (-not $OriginatingContext -or $Steps.Count -eq 0 -or -not $ExpectedOutcome -or -not $FollowUp) {
        throw "OriginatingContext, Steps, ExpectedOutcome, and FollowUp must all have non-empty values"
    }

    if (-not $OutputPath) {
        $safeTopic = $Topic.ToLower() -replace '\s+', '-' -replace '[^a-z0-9\-]', ''
        $OutputPath = "Tasks/Manual/$Date-$safeTopic.md"
    }

    $lines = @()
    $lines += "# Manual Task: $Topic"
    $lines += ""
    $lines += "## Originating Context"
    $lines += ""
    $lines += $OriginatingContext
    $lines += ""
    $lines += "## Date Created"
    $lines += ""
    $lines += $DateCreated
    $lines += ""
    $lines += "## Step-by-Step Instructions"
    $lines += ""
    for ($i = 0; $i -lt $Steps.Count; $i++) {
        $lines += "$($i + 1). $($Steps[$i])"
    }
    $lines += ""
    $lines += "## Expected Outcome"
    $lines += ""
    $lines += $ExpectedOutcome
    $lines += ""
    $lines += "## Follow-Up"
    $lines += ""
    $lines += $FollowUp

    $output = $lines -join "`n"

    if ($DryRun) { Write-Host $output }
    else { Set-Content -LiteralPath $OutputPath -Value $output -NoNewline }
}
