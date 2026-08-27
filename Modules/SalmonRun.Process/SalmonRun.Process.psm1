#Requires -Version 7.0
<#
.SYNOPSIS
    Wraps native command invocation with consistent error-action handling and logging.
.DESCRIPTION
    Temporary sets PSNativeCommandUseErrorActionPreference to $false around a
    scriptblock to prevent native exe errors from terminating the host process.
#>
#Requires -Version 7.0

Set-StrictMode -Off

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Command,
        [switch]$ThrowOnError
    )
    # IMPORTANT: Use $global: scope so the preference change is visible to the
    # scriptblock when it is invoked via `& $Command`. The scriptblock executes
    # in its definition scope (the caller's), not the module's scope, so a
    # plain `$PSNativeCommandUseErrorActionPreference = $false` here would NOT
    # be seen by docker/aws.exe inside the scriptblock.
    $savedPreference = $global:PSNativeCommandUseErrorActionPreference
    $global:PSNativeCommandUseErrorActionPreference = $false
    try {
        $OutputRaw = & $Command
        $ExitCode = $LASTEXITCODE
        $OutputStr = if ($OutputRaw -is [array]) { $OutputRaw -join "`n" } else { $OutputRaw }
        $result = [pscustomobject]@{
            Output   = $OutputStr
            ExitCode = $ExitCode
            Success  = ($ExitCode -eq 0)
        }
        if ($ThrowOnError -and -not $result.Success) {
            throw "Invoke-NativeCommand: native command failed (exit $ExitCode): $OutputStr"
        }
        return $result
    } finally {
        $global:PSNativeCommandUseErrorActionPreference = $savedPreference
    }
}

function Invoke-Docker {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
        [string[]]$DockerArgs,
        [Parameter(ValueFromPipeline)]
        [string]$StdinInput
    )
    $prevNativeErr = $global:PSNativeCommandUseErrorActionPreference
    $global:PSNativeCommandUseErrorActionPreference = $false
    if (-not [string]::IsNullOrWhiteSpace($StdinInput)) {
        $prevOutputEncoding = $OutputEncoding
        $prevEncoding = [Console]::OutputEncoding
        $prevArgPassing = $PSNativeCommandArgumentPassing
        [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
        $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
        $PSNativeCommandArgumentPassing = 'Legacy'
        try {
            $StdinInput | & docker @DockerArgs
        } finally {
            [Console]::OutputEncoding = $prevEncoding
            $OutputEncoding = $prevOutputEncoding
            $PSNativeCommandArgumentPassing = $prevArgPassing
            $global:PSNativeCommandUseErrorActionPreference = $prevNativeErr
        }
    }
    else {
        $prevArgPassing = $PSNativeCommandArgumentPassing
        $PSNativeCommandArgumentPassing = 'Legacy'
        try {
            & docker @DockerArgs
        } finally {
            $PSNativeCommandArgumentPassing = $prevArgPassing
            $global:PSNativeCommandUseErrorActionPreference = $prevNativeErr
        }
    }
}

function Invoke-AwsCommand {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Command,
        [switch]$ThrowOnError
    )

    # When AWS env vars are present (cached by RunFix), write or refresh the
    # credentials file under the profile name. This makes --profile $name
    # resolve to the temp access keys instead of attempting SSO auth.
    # ALWAYS refresh — RunFix re-caches creds each poll cycle (~60s), and stale
    # temp creds expire in ~1hr.
    # The original ~/.aws/credentials content is backed up and restored so the
    # operator's long-lived profiles are not deleted after the run. ~/.aws/config
    # is never touched.
    $credPath = $null
    $credExisted = $false
    $originalCredContent = $null
    try {
        if ($env:AWS_ACCESS_KEY_ID) {
            $profileName = if ($env:AWS_SSO_PROFILE) { $env:AWS_SSO_PROFILE } else { "default" }
            $homeDir = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
            $credPath = Join-Path $homeDir ".aws" "credentials"
            $credDir = Split-Path $credPath -Parent
            if (-not (Test-Path $credDir)) { $null = New-Item -ItemType Directory -Path $credDir -Force }

            # Backup original credentials; do not touch ~/.aws/config.
            $credExisted = Test-Path $credPath
            $originalCredContent = if ($credExisted) { Get-Content $credPath -ErrorAction SilentlyContinue } else { @() }
            if ($null -eq $originalCredContent) { $originalCredContent = @() }

            # Build temp content: remove the old [profile] section, append fresh entry
            $existing = $originalCredContent
            $profileHeader = "[$profileName]"
            $newLines = @()
            $skipSection = $false
            foreach ($line in $existing) {
                if ($line.Trim() -eq $profileHeader) { $skipSection = $true; continue }
                if ($skipSection -and $line.Trim() -match '^\[.*\]$') { $skipSection = $false }
                if (-not $skipSection) { $newLines += $line }
            }

            $newLines += ""
            $newLines += $profileHeader
            $newLines += "aws_access_key_id = $env:AWS_ACCESS_KEY_ID"
            $newLines += "aws_secret_access_key = $env:AWS_SECRET_ACCESS_KEY"
            $newLines += "aws_session_token = $env:AWS_SESSION_TOKEN"
            Set-Content -Path $credPath -Value ($newLines -join "`n") -Encoding UTF8 -Force -ErrorAction Stop

            if ($PSVersionTable.Platform -eq 'Win32NT') {
                if (Get-Command Restrict-FileAccess -ErrorAction SilentlyContinue) {
                    Restrict-FileAccess -Path $credPath
                } else {
                    $acl = New-Object System.Security.AccessControl.FileSecurity
                    $acl.SetAccessRuleProtection($true, $false)
                    $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
                    $ace = New-Object System.Security.AccessControl.FileSystemAccessRule($currentUser, 'Read,Write', 'Allow')
                    $acl.SetAccessRule($ace)
                    Set-Acl -Path $credPath -AclObject $acl -ErrorAction Stop | Out-Null
                }
            } elseif ($PSVersionTable.Platform -eq 'Unix') {
                & chmod 600 -- $credPath 2>$null
            }
        }

        return Invoke-NativeCommand -Command $Command -ThrowOnError:$ThrowOnError
    } finally {
        if ($credPath) {
            if ($credExisted) {
                # Restore the operator's original credentials file.
                Set-Content -Path $credPath -Value $originalCredContent -Encoding UTF8 -Force -ErrorAction SilentlyContinue
            } elseif (Test-Path $credPath) {
                # We created a new credentials file; remove it.
                Remove-Item -LiteralPath $credPath -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Test-NativeCommandResult {
    param(
        [Parameter(Mandatory)]
        [scriptblock]$Command,
        [switch]$Recoverable
    )
    $result = Invoke-NativeCommand $Command
    if (-not $result.Success) {
        $msg = "Native command failed (exit $($result.ExitCode)): $($result.Output)"
        $logCmd = Get-Command Write-SetupLog -ErrorAction SilentlyContinue
        if ($logCmd) {
            & $logCmd $msg -Level $(if ($Recoverable) { "WARN" } else { "ERROR" })
        }
        if ($Recoverable) {
            $addErrCmd = Get-Command Add-SetupError -ErrorAction SilentlyContinue
            if ($addErrCmd) {
                & $addErrCmd -Phase "NativeCommand" -Message $msg -Recoverable:$true
            }
        } else {
            throw $msg
        }
    }
    return $result
}
