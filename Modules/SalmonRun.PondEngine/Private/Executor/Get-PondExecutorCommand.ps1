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

    $quotedFiles = @($PlanFiles | ForEach-Object { "`"$_`"" })
    $fileArgs = $quotedFiles -join ' '

    # Descriptive command string for logging. The real execution uses StartInfo.
    $command = if ($Profile.Provider -in @('opencode','opencode-go')) {
        "$($Profile.Cli) run <prompt> --model $($Profile.Model) --variant $($Profile.Effort) --auto -f $fileArgs"
    } elseif ($Profile.Provider -eq 'local' -or $Profile.Cli -in @('powershell','pwsh')) {
        "$($Profile.Cli) -File `"$executorPath`" -Role $Role -LanePath `"$LanePath`" -RepoDir `"$RepoDir`" -Provider $($Profile.Provider) $fileArgs"
    } elseif ($Profile.Harness -eq 'deepseek' -or $Profile.Provider -in @('dsh','openrouter','deepinfra')) {
        "dsh --profile headless --provider $($Profile.Provider) --model $($Profile.Model) --prompt <plans>"
    } elseif ($Profile.Provider -eq 'devin') {
        "devin --prompt-file $fileArgs --model $($Profile.Model) -p"
    } elseif ($Profile.Provider -eq 'codex' -or $Profile.Harness -eq 'codex') {
        "codex exec -m $($Profile.Model) -C <RepoDir> -c model_reasoning_effort=$($Profile.Effort) --output-last-message <out> - < $fileArgs"
    } else {
        "$($Profile.Cli) run --command work-$Role-once --model $($Profile.Model) --effort $($Profile.Effort) --files $fileArgs"
    }

    $filePath = if (Get-Command -Name 'pwsh' -CommandType Application -ErrorAction SilentlyContinue) {
        'pwsh'
    } else {
        'powershell'
    }

    $argumentList = @(
        '-NoProfile'
        '-NonInteractive'
        '-File', $executorPath
        '-Role', $Role
        '-LanePath', $LanePath
        '-RepoDir', $RepoDir
        '-Provider', $Profile.Provider
    )
    if (-not [string]::IsNullOrWhiteSpace($Profile.Model)) {
        $argumentList += '-Model'
        $argumentList += $Profile.Model
    }
    if (-not [string]::IsNullOrWhiteSpace($Profile.Effort)) {
        $argumentList += '-Effort'
        $argumentList += $Profile.Effort
    }
    if ($TimeoutMinutes -gt 0) {
        $argumentList += '-TimeoutMinutes'
        $argumentList += $TimeoutMinutes
    }
    foreach ($pf in $PlanFiles) { $argumentList += $pf }

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
