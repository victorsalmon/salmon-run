<#
.SYNOPSIS
    Lightweight wrapper for the AWS CLI. All AWS commands in Interclaw
    scripts should use this wrapper so tests can Mock it without Start-Job.
    Accepts the aws subcommand and arguments as an array.
.PARAMETER AwsArgs
    Array of arguments to pass to aws.exe (e.g., "iam", "list-users", "--output", "json")
.OUTPUTS
    Raw command output (string or array). Check $LASTEXITCODE if needed.
#>
function Invoke-AwsCli {
    [OutputType([string])]
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$AwsArgs
    )
    $result = Invoke-AwsCommand -Command { aws @AwsArgs } -ThrowOnError:$false
    if ($result.Success) { return $result.Output } else { return $null }
}
