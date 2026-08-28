function Get-PondExecutorCommand {
    <#
    .SYNOPSIS
        Builds the executor script path and the CLI command for a given profile.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [PondExecutionProfile]$srExecProfile,

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

    $executorPath = Join-Path $orchModule.ModuleBase 'Executors' "$($srExecProfile.ExecutorFile).ps1"
    if (-not (Test-Path -LiteralPath $executorPath)) {
        throw "Get-PondExecutorCommand: executor script not found at '$executorPath'."
    }

    $Credentials = [string[]](@($Credentials | Where-Object { $null -ne $_ }))
    if ($Credentials.Count -eq 0) {
        $Credentials = [string[]](@($srExecProfile.Credentials | Where-Object { $null -ne $_ }))
    }

    $quotedFiles = @($PlanFiles | ForEach-Object { "`"$_`"" })
    $fileArgs = $quotedFiles -join ' '

    # Descriptive command string for logging. The real execution uses StartInfo.
    $command = if ($srExecProfile.Provider -in @('opencode','opencode-go')) {
        "$($srExecProfile.Cli) run <prompt> --model $($srExecProfile.Model) --variant $($srExecProfile.Effort) --auto -f $fileArgs"
    } elseif ($srExecProfile.Provider -eq 'local' -or $srExecProfile.Cli -in @('powershell','pwsh')) {
        "$($srExecProfile.Cli) -File `"$executorPath`" -Role $Role -LanePath `"$LanePath`" -RepoDir `"$RepoDir`" -Provider $($srExecProfile.Provider) $fileArgs"
    } elseif ($srExecProfile.Harness -eq 'deepseek' -or $srExecProfile.Provider -in @('dsh','openrouter','deepinfra')) {
        "dsh --profile headless --provider $($srExecProfile.Provider) --model $($srExecProfile.Model) --prompt <plans>"
    } elseif ($srExecProfile.Provider -eq 'devin') {
        "devin --prompt-file $fileArgs --model $($srExecProfile.Model) -p"
    } elseif ($srExecProfile.Provider -eq 'codex' -or $srExecProfile.Harness -eq 'codex') {
        "codex exec -m $($srExecProfile.Model) -C <RepoDir> -c model_reasoning_effort=$($srExecProfile.Effort) --output-last-message <out> - < $fileArgs"
    } else {
        "$($srExecProfile.Cli) run --command work-$Role-once --model $($srExecProfile.Model) --effort $($srExecProfile.Effort) --files $fileArgs"
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
        '-Provider', $srExecProfile.Provider
    )
    if (-not [string]::IsNullOrWhiteSpace($srExecProfile.Model)) {
        $argumentList += '-Model'
        $argumentList += $srExecProfile.Model
    }
    if (-not [string]::IsNullOrWhiteSpace($srExecProfile.Effort)) {
        $argumentList += '-Effort'
        $argumentList += $srExecProfile.Effort
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


