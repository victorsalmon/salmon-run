# Used by: Skills/Cowork/fork.md (opencode.json /fork command template)
# Script-level param block - required so `powershell -File` binds named arguments.
param(
    [Parameter(Mandatory = $true)]
    [string]$Topic,
    [Parameter(Mandatory = $true)]
    [string]$Goal,
    [Parameter(Mandatory = $true)]
    [string]$ContextFile,
    [Parameter(Mandatory = $false)]
    [string]$Date = (Get-Date -Format 'yyyy-MM-dd'),
    [Parameter(Mandatory = $false)]
    [string]$OutputDir = "Tasks/Handoff",
    [Parameter(Mandatory = $false)]
    [switch]$StubOnly,
    [Parameter(Mandatory = $false)]
    [switch]$DryRun
)

function Invoke-ForkFlow {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Topic,
        [Parameter(Mandatory = $true)]
        [string]$Goal,
        [Parameter(Mandatory = $true)]
        [string]$ContextFile,
        [Parameter(Mandatory = $false)]
        [string]$Date = (Get-Date -Format 'yyyy-MM-dd'),
        [Parameter(Mandatory = $false)]
        [string]$OutputDir = "Tasks/Handoff",
        [Parameter(Mandatory = $false)]
        [switch]$StubOnly,
        [Parameter(Mandatory = $false)]
        [switch]$DryRun
    )

    $ErrorActionPreference = "Stop"

    # Resolve paths relative to the project root
    $repoRoot = Resolve-Path -LiteralPath "$PSScriptRoot\..\..\.." -ErrorAction Stop
    $handoffDir = Join-Path -Path $repoRoot -ChildPath $OutputDir

    # Ensure the other scripts are available
    $newForkStub = Join-Path -Path $repoRoot -ChildPath "Skills/Cowork/Scripts/New-ForkStub.ps1"
    $invokeFork  = Join-Path -Path $repoRoot -ChildPath "Skills/Cowork/Scripts/Invoke-Fork.ps1"

    if (-not (Test-Path -LiteralPath $newForkStub)) { throw "New-ForkStub.ps1 not found at $newForkStub" }
    if (-not (Test-Path -LiteralPath $invokeFork))  { throw "Invoke-Fork.ps1 not found at $invokeFork" }

    # Read context body from file
    if (-not $DryRun -and -not (Test-Path -LiteralPath $ContextFile)) {
        throw "Context file not found at '$ContextFile'"
    }
    $contextBody = Get-Content -LiteralPath $ContextFile -Raw -ErrorAction Stop

    # Dot-source the helper functions
    . $newForkStub
    . $invokeFork

    # Step 1: Write the Fork-Stub
    Write-Host "[fork] Writing Fork-Stub: Topic='$Topic', Goal='$Goal'"
    $stubPath = New-ForkStub -Topic $Topic -Goal $Goal -ContextBody $contextBody -Date $Date -OutputDir $handoffDir -DryRun:$DryRun

    if ($DryRun) {
        Write-Host "[fork] (dry-run) Fork-Stub preview written above. Would launch at: $stubPath"
        return
    }

    Write-Host "[fork] Fork-Stub written: $stubPath"

    # Step 2: Launch the fork (or print stub-only message)
    Write-Host "[fork] Launching fork..."
    $null = Invoke-Fork -StubPath $stubPath -Goal $Goal -StubOnly:$StubOnly -DryRun:$DryRun

    Write-Host "[fork] Fork completed. Stub: $stubPath"
    return $stubPath
}

# Invoke the function when run via `powershell -File`
Invoke-ForkFlow -Topic $Topic -Goal $Goal -ContextFile $ContextFile -Date $Date -OutputDir $OutputDir -StubOnly:$StubOnly -DryRun:$DryRun
