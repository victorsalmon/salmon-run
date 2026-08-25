<#
.SYNOPSIS
    Generates a cryptographically random Base64 token string.
.DESCRIPTION
    Uses RandomNumberGenerator to produce secure random bytes, returns a
    URL-safe Base64 string with padding characters stripped.
.PARAMETER ByteCount
    Number of random bytes to generate (default 32).
#>
function New-CryptographicToken {
    param([int]$ByteCount = 32)
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $bytes = [byte[]]::new($ByteCount)
    $rng.GetBytes($bytes)
    return [System.Convert]::ToBase64String($bytes) -replace '[+/=]' -replace '-', ''
}
