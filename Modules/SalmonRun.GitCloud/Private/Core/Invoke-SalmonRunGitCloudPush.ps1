function Invoke-SalmonRunGitCloudPush {
    <#
    .SYNOPSIS
        Internal helper that pushes to a Git remote with optional token auth.
    .DESCRIPTION
        Detects whether the remote URL is SSH or HTTPS. For HTTPS, it writes a
        temporary GIT_ASKPASS helper that returns the token as both username
        and password. This avoids embedding credentials in the command line.
        If the URL is SSH, a plain git push is performed.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$RemoteUrl,

        [Parameter(Mandatory)]
        [string]$RefSpec,

        [Parameter(Mandatory)]
        [string]$Token
    )

    $isHttps = $RemoteUrl -like 'https://*'
    $askPassFile = $null
    $askPassCmd = $null

    try {
        if ($isHttps) {
            $baseName = "salmon-run-askpass-" + [Guid]::NewGuid().ToString('N')
            $askPassPath = Join-Path $env:TEMP ($baseName + '.ps1')
            $askPassCmdPath = Join-Path $env:TEMP ($baseName + '.cmd')
            $askPassFile = [System.IO.FileInfo]::new($askPassPath)
            $askPassCmd = [System.IO.FileInfo]::new($askPassCmdPath)
            $askPassScript = @'
param([string]$Prompt)
return $env:SALMON_RUN_GITCLOUD_PUSH_TOKEN
'@
            $askPassScript | Set-Content -LiteralPath $askPassFile.FullName -Encoding utf8 -NoNewline

            @"
@echo off
powershell -File `"$($askPassFile.FullName)`" %*
"@ | Set-Content -LiteralPath $askPassCmd.FullName -Encoding ascii -NoNewline

            $env:SALMON_RUN_GITCLOUD_PUSH_TOKEN = $Token
            $env:GIT_ASKPASS = $askPassCmd.FullName
            $env:GIT_TERMINAL_PROMPT = '1'
        }

        # Disable any credential helper so the GIT_ASKPASS token from this call is used,
        # rather than a token that may already be cached for the worktree host.
        $output = & git -c credential.helper= push $RemoteUrl $RefSpec 2>&1
        $exit = $LASTEXITCODE

        foreach ($line in $output) { Write-Verbose "Invoke-SalmonRunGitCloudPush: $line" }

        if ($exit -ne 0) {
            Write-Warning "Invoke-SalmonRunGitCloudPush: git push exited $exit. Output: $($output -join ' | ')"
        }

        return [pscustomobject]@{ Success = ($exit -eq 0); ExitCode = $exit; Remote = $RemoteUrl; RefSpec = $RefSpec }
    } finally {
        if ($askPassFile -and (Test-Path $askPassFile.FullName)) {
            Remove-Item $askPassFile.FullName -Force -ErrorAction SilentlyContinue
        }
        if ($askPassCmd -and (Test-Path $askPassCmd.FullName)) {
            Remove-Item $askPassCmd.FullName -Force -ErrorAction SilentlyContinue
        }
        Remove-Item Env:\SALMON_RUN_GITCLOUD_PUSH_TOKEN -ErrorAction SilentlyContinue
        Remove-Item Env:\GIT_ASKPASS -ErrorAction SilentlyContinue
        Remove-Item Env:\GIT_TERMINAL_PROMPT -ErrorAction SilentlyContinue
    }
}
