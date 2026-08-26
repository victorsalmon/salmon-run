function Get-PondExecutorCommand {
    <#
    .SYNOPSIS
        Builds the executor script path and the CLI command for a given profile.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [PondExecutionProfile]$Profile,

        [Parameter(Mandatory)]
        [string]$Role,

        [Parameter(Mandatory)]
        [string]$RepoDir,

        [Parameter(Mandatory)]
        [string[]]$PlanFiles
    )

    $orchModule = Get-Module SalmonRun.Orchestrate -ErrorAction SilentlyContinue
    if (-not $orchModule) {
        $orchModule = Get-Module SalmonRun.Orchestrate -ListAvailable -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    if (-not $orchModule) {
        throw "Get-PondExecutorCommand: SalmonRun.Orchestrate module is required."
    }

    $executorPath = Join-Path $orchModule.ModuleBase 'Executors' "$($Profile.ExecutorFile).ps1"
    if (-not (Test-Path -LiteralPath $executorPath)) {
        throw "Get-PondExecutorCommand: executor script not found at '$executorPath'."
    }

    $fileArgs = $PlanFiles -join ' '
    $command = "$($Profile.Cli) run --command work-$Role-once --model $($Profile.Model) --effort $($Profile.Effort) --files $fileArgs"

    return [PSCustomObject]@{
        ExecutorPath = $executorPath
        Command      = $command
        Role         = $Role
        RepoDir      = $RepoDir
        PlanFiles    = $PlanFiles
    }
}
