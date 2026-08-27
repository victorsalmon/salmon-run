# Used by: Skills/Cowork/fork.md (via Invoke-ForkFlow.ps1)
function New-ForkStub {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Topic,
        [Parameter(Mandatory = $true)]
        [string]$Goal,
        [Parameter(Mandatory = $true)]
        [string]$ContextBody,
        [Parameter(Mandatory = $false)]
        [string]$Date = (Get-Date -Format 'yyyy-MM-dd'),
        [Parameter(Mandatory = $false)]
        [string]$OutputDir = "Tasks/Handoff",
        [Parameter(Mandatory = $false)]
        [switch]$DryRun
    )

    if ($Topic.Length -eq 0) { throw "-Topic must not be empty" }
    if ($Goal.Length -lt 10) { throw "-Goal must be at least 10 characters" }
    if ($ContextBody.Length -lt 50) { throw "-ContextBody must be at least 50 characters" }

    $slug = $Topic -replace '[^a-zA-Z0-9-]', '-'
    $filename = "fork-stub-$Date-$slug.md"
    $path = Join-Path -Path $OutputDir -ChildPath $filename

    $lines = @()
    $lines += "---"
    $lines += "type: fork-stub"
    $lines += "Date: $Date"
    $lines += "Topic: $Topic"
    $lines += "---"
    $lines += ""
    $lines += "# Fork-Stub: $Topic"
    $lines += ""
    $lines += "**Goal**: $Goal"
    $lines += ""
    $lines += "## Transferred Context"
    $lines += ""
    $lines += $ContextBody
    $lines += ""
    $lines += "---"
    $lines += "*This stub transfers all context needed for the forked goal.*"
    $lines += "*The original session has compressed away this context.*"

    $output = $lines -join "`n"

    if ($DryRun) {
        Write-Host $output
        return $path
    }

    $null = New-Item -ItemType Directory -Path $OutputDir -Force -ErrorAction SilentlyContinue
    Set-Content -LiteralPath $path -Value $output -NoNewline
    return (Resolve-Path -LiteralPath $path -ErrorAction Stop).Path
}
