function Read-FleetSecret {
    <#
    .SYNOPSIS
        Reads a secret value from the bundle or individual secret file.
    .DESCRIPTION
        Tries the JSON secrets bundle first (mounted at /run/secrets/secrets_bundle).
        Falls back to individual secret files for backward compatibility.
    .PARAMETER SecretName
        The name of the secret to read.
    .OUTPUTS
        String value if found, $null otherwise.
    #>
    [OutputType([string])]
    param([string]$SecretName)
    $BundlePath = "/run/secrets/secrets_bundle"
    if (Test-Path $BundlePath) {
        $Bundle = Get-Content -Path $BundlePath -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
        if ($Bundle -and $Bundle.$SecretName) {
            return $Bundle.$SecretName
        }
    }
    $SecretFile = "/run/secrets/$SecretName"
    if (Test-Path $SecretFile) {
        return (Get-Content -Path $SecretFile -Raw).Trim()
    }
    return $null
}
