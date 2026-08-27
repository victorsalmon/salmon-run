<#
.SYNOPSIS
    Invokes a Docker command with standardized stderr logging.
.DESCRIPTION
    Wraps native command invocation with controlled stderr handling. For Tier 2
    (critical) operations, failures are logged as warnings. For Tier 1 (discovery)
    operations, use -SuppressStderr to log at DEBUG level instead of suppressing
    entirely. Use -FailOnError for operations that must succeed.
.PARAMETER Command
    Scriptblock containing the Docker command to execute.
.PARAMETER SuppressStderr
    Log output at DEBUG level instead of VERBOSE (for Tier 1 discovery operations).
.PARAMETER FailOnError
    Throw on failure instead of logging a warning (for critical operations).
.PARAMETER OperationLabel
    Human-readable label for log messages.
.OUTPUTS
    PSCustomObject with Output, ExitCode, and Success properties.
.EXAMPLE
    Invoke-DockerWithLogging -Command { docker volume rm myvol 2>&1 } -OperationLabel "Volume removal"
    Invoke-DockerWithLogging -Command { docker volume ls --format "{{.Name}}" 2>&1 } -SuppressStderr
    Invoke-DockerWithLogging -Command { docker service update --force mysvc 2>&1 } -FailOnError
#>
function Invoke-DockerWithLogging {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [scriptblock]$Command,

        [string]$OperationLabel = "Docker operation",

        [switch]$SuppressStderr,

        [switch]$FailOnError
    )

    # IMPORTANT: Use $global: scope so the preference change applies when the
    # scriptblock executes. The scriptblock runs in its definition scope, not
    # this function's local scope, so a plain `$PSNativeCommandUseErrorActionPreference = $false`
    # would NOT be seen by docker inside the scriptblock.
    $savedPreference = $global:PSNativeCommandUseErrorActionPreference
    $global:PSNativeCommandUseErrorActionPreference = $false
    try {
        $OutputRaw = & $Command
        $ExitCode = $LASTEXITCODE
        $OutputStr = if ($null -eq $OutputRaw) { "" } elseif ($OutputRaw -is [array]) { $OutputRaw -join "`n" } else { [string]$OutputRaw }

        if ($ExitCode -ne 0) {
            $msg = "$OperationLabel failed (exit ${ExitCode}): ${OutputStr}"
            if ($FailOnError) {
                Write-Error $msg
                throw $msg
            } else {
                Write-Warning $msg
            }
        } elseif ($SuppressStderr) {
            Write-Debug "$OperationLabel completed: ${OutputStr}"
        } else {
            Write-Verbose "$OperationLabel completed: ${OutputStr}"
        }

        return [pscustomobject]@{
            Output   = $OutputStr
            ExitCode = $ExitCode
            Success  = ($ExitCode -eq 0)
        }
    } finally {
        $global:PSNativeCommandUseErrorActionPreference = $savedPreference
    }
}
