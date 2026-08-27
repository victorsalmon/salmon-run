function New-CredentialRef {
    param(
        [Parameter(Mandatory = $false)]
        [string]$AwsPath = "Interclaw/FRAD/Provisioning",
        [Parameter(Mandatory = $false)]
        [string]$Region = "ca-central-1",
        [Parameter(Mandatory = $true)]
        [hashtable[]]$Credentials,
        [Parameter(Mandatory = $false)]
        [switch]$SsoRequired = $true,
        [Parameter(Mandatory = $false)]
        [ValidateSet('markdown-table', 'inline')]
        [string]$OutputFormat = 'markdown-table',
        [Parameter(Mandatory = $false)]
        [switch]$DryRun
    )
    if (-not $Credentials -or $Credentials.Count -eq 0) { throw "At least one -Credentials entry required" }

    $lines = @()
    $ssoLine = "SSO session required to retrieve."
    if (-not $SsoRequired) { $ssoLine = "" }

    if ($ssoLine) { $lines += "All secrets live in ``$AwsPath`` (region ``$Region``). $ssoLine" }
    else { $lines += "All secrets live in ``$AwsPath`` (region ``$Region``)." }
    $lines += ""

    if ($OutputFormat -eq 'markdown-table') {
        $lines += "| AWS SM Key | Purpose |"
        $lines += "|------------|---------|"
        foreach ($cred in $Credentials) {
            $lines += "| $($cred.Key) | $($cred.Purpose) |"
        }
    } else {
        foreach ($cred in $Credentials) {
            $lines += "$($cred.Key): $($cred.Purpose)"
        }
    }
    $lines += ""

    $output = $lines -join "`n"

    if ($DryRun) { Write-Host $output }
    else { Write-Host $output }
}
