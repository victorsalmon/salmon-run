function Start-PondExecutor {
    <#
    .SYNOPSIS
        Starts the selected executor for a pond group.

        The current implementation resolves the executor command and records it
        in the lane as a .run sentinel. A real harness can later consume this
        sentinel to launch the CLI; the monitor task watches for .complete.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Command,

        [Parameter(Mandatory)]
        [string]$LanePath,

        [string]$LogPath
    )

    $runFile = Join-Path $LanePath '.run'
    $Command | ConvertTo-Json -Depth 2 | Set-Content -LiteralPath $runFile -Encoding utf8 -NoNewline

    $pidFile = Join-Path $LanePath '.pid'
    "# $LogPath" | Set-Content -LiteralPath $pidFile -Encoding utf8 -NoNewline

    Write-Verbose "Start-PondExecutor: wrote run sentinel for role '$($Command.Role)' to '$runFile'"
    return $Command
}
