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
        [string[]]$PlanFiles,

        [string]$LanePath = '',

        [int]$TimeoutMinutes = 30,

        [string[]]$Credentials = @()
    )

    $orchModule = Get-Module SalmonRun.PondEngine -ErrorAction SilentlyContinue
    if (-not $orchModule) {
        $orchModule = Get-Module SalmonRun.PondEngine -ListAvailable -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    if (-not $orchModule) {
        throw "Get-PondExecutorCommand: SalmonRun.PondEngine module is required."
    }

    $executorPath = Join-Path $orchModule.ModuleBase 'Executors' "$($Profile.ExecutorFile).ps1"
    if (-not (Test-Path -LiteralPath $executorPath)) {
        throw "Get-PondExecutorCommand: executor script not found at '$executorPath'."
    }

    $Credentials = [string[]](@($Credentials | Where-Object { $_ -ne $null }))
    if ($Credentials.Count -eq 0) {
        $Credentials = [string[]](@($Profile.Credentials | Where-Object { $_ -ne $null }))
    }

    $fileArgs = $PlanFiles -join ' '
    $command = "$($Profile.Cli) run --command work-$Role-once --model $($Profile.Model) --effort $($Profile.Effort) --files $fileArgs"

    # Build a structured StartInfo for Start-Process. The local PowerShell
    # executor expects the lane path and plan files as parameters.
    if ($Profile.Provider -eq 'local' -or $Profile.Cli -in @('powershell','pwsh')) {
        $filePath = if ($Profile.Cli -in @('pwsh','powershell')) { $Profile.Cli } else { 'powershell' }
        $argumentList = @(
            '-NoProfile'
            '-NonInteractive'
            '-File', $executorPath
            '-Role', $Role
            '-LanePath', $LanePath
            '-RepoDir', $RepoDir
        )
        foreach ($pf in $PlanFiles) { $argumentList += $pf }
        $command = "$filePath -NoProfile -NonInteractive -File `"$executorPath`" -Role $Role -LanePath `"$LanePath`" -RepoDir `"$RepoDir`" `"$fileArgs`""
    } else {
        $filePath = $Profile.Cli
        $argumentList = @('run','--command',"work-$Role-once",'--model',$Profile.Model,'--effort',$Profile.Effort,'--files') + @($PlanFiles)
    }

    return [PSCustomObject]@{
        ExecutorPath = $executorPath
        Command      = $command
        StartInfo    = [PSCustomObject]@{
            FilePath      = $filePath
            ArgumentList  = $argumentList
        }
        Role         = $Role
        RepoDir      = $RepoDir
        PlanFiles    = $PlanFiles
        LanePath     = $LanePath
        TimeoutMinutes = $TimeoutMinutes
        Credentials  = $Credentials
    }
}
