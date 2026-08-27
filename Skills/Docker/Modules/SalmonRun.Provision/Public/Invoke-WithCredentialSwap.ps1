<#
.SYNOPSIS
    Temporarily swaps AWS credentials, executes a script block, then restores the originals.
    Used by credential isolation tests in 1AWS.ps1.
    Always restores original credentials via try/finally, even if the script block throws.
#>
function Invoke-WithCredentialSwap {
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)]
        [SecureString]$AccessKeyId,
        [Parameter(Mandatory = $true)]
        [SecureString]$SecretAccessKey,
        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock,
        [Parameter(Mandatory = $false)]
        [string]$Region = "us-east-1"
    )

    # Convert SecureString to plaintext for credential files and env vars
    $plainAccessKey = [System.Net.NetworkCredential]::new("", $AccessKeyId).Password
    $plainSecretKey = [System.Net.NetworkCredential]::new("", $SecretAccessKey).Password

    # Save original env vars
    $SavedKeyId = $env:AWS_ACCESS_KEY_ID
    $SavedSecretKey = $env:AWS_SECRET_ACCESS_KEY
    $SavedSessionToken = $env:AWS_SESSION_TOKEN
    $SavedProfile = $env:AWS_PROFILE
    $SavedDefaultProfile = $env:AWS_DEFAULT_PROFILE
    $SavedSsoProfile = $env:AWS_SSO_PROFILE
    $SavedConfigFile = $env:AWS_CONFIG_FILE
    $SavedSharedCredentialsFile = $env:AWS_SHARED_CREDENTIALS_FILE

    # Create a temporary credentials file with a named profile.
    # This is more reliable than env vars because the AWS CLI v2 on Windows
    # can pick up cached SSO tokens even when AWS_ACCESS_KEY_ID is set.
    $TempCredDir = Join-Path ([System.IO.Path]::GetTempPath()) "oc-credswap-$([System.IO.Path]::GetRandomFileName())"
    New-Item -ItemType Directory -Path $TempCredDir -Force | Out-Null
    # Restrict directory ACL to current user only to prevent credential leakage
    $credAcl = Get-Acl -Path $TempCredDir
    $credAcl.SetAccessRuleProtection($true, $false)
    $credUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $credRule = New-Object System.Security.AccessControl.FileSystemAccessRule($credUser, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
    $credAcl.SetAccessRule($credRule)
    Set-Acl -Path $TempCredDir -AclObject $credAcl
    $TempCredFile = Join-Path $TempCredDir "credentials"
    $TempConfigFile = Join-Path $TempCredDir "config"

    @"
[ORCHESTRATOR-swap]
aws_access_key_id = $plainAccessKey
aws_secret_access_key = $plainSecretKey
"@ | Write-AtomicFile -Path $TempCredFile -Encoding UTF8

    @"
[profile ORCHESTRATOR-swap]
region = $Region
"@ | Write-AtomicFile -Path $TempConfigFile -Encoding UTF8

    try {
        # Point AWS CLI exclusively at our temporary files via profile (not env vars)
        # Using AWS_SHARED_CREDENTIALS_FILE + AWS_PROFILE avoids leaking plaintext creds to child processes
        $env:AWS_SHARED_CREDENTIALS_FILE = $TempCredFile
        $env:AWS_CONFIG_FILE = $TempConfigFile
        $env:AWS_PROFILE = "ORCHESTRATOR-swap"
        Remove-Item Env:\AWS_SESSION_TOKEN -ErrorAction SilentlyContinue
        Remove-Item Env:\AWS_DEFAULT_PROFILE -ErrorAction SilentlyContinue
        Remove-Item Env:\AWS_SSO_PROFILE -ErrorAction SilentlyContinue

        # Verify identity before running tests
        $IdentityResult = Invoke-AwsCommand { aws sts get-caller-identity --profile ORCHESTRATOR-swap --output json 2>$null }
        if ($IdentityResult.Success -and -not [string]::IsNullOrWhiteSpace($IdentityResult.Output)) {
            try {
                try { $Identity = $IdentityResult.Output | ConvertFrom-Json } catch { Write-SetupLog "Credential swap: JSON parse failed for identity output" -Level WARN; $Identity = $null }
                Write-SetupLog "Credential swap active: $($Identity.Arn)"
            } catch {
                Write-SetupLog "Credential swap verification failed  -  non-JSON output: $($IdentityResult.Output)" -Level WARN
                throw "Credential swap failed: AWS returned non-JSON response. Aborting to prevent execution with wrong credentials."
            }
        }
        else {
            Write-SetupLog "Credential swap verification failed  -  tests may use wrong identity" -Level WARN
        }

        & $ScriptBlock
    }
    finally {
        # Restore original env vars
        if (-not [string]::IsNullOrWhiteSpace($SavedKeyId)) { $env:AWS_ACCESS_KEY_ID = $SavedKeyId }
        else { Remove-Item Env:\AWS_ACCESS_KEY_ID -ErrorAction SilentlyContinue }
        if (-not [string]::IsNullOrWhiteSpace($SavedSecretKey)) { $env:AWS_SECRET_ACCESS_KEY = $SavedSecretKey }
        else { Remove-Item Env:\AWS_SECRET_ACCESS_KEY -ErrorAction SilentlyContinue }
        if (-not [string]::IsNullOrWhiteSpace($SavedSessionToken)) { $env:AWS_SESSION_TOKEN = $SavedSessionToken }
        else { Remove-Item Env:\AWS_SESSION_TOKEN -ErrorAction SilentlyContinue }
        if (-not [string]::IsNullOrWhiteSpace($SavedProfile)) { $env:AWS_PROFILE = $SavedProfile }
        else { Remove-Item Env:\AWS_PROFILE -ErrorAction SilentlyContinue }
        if (-not [string]::IsNullOrWhiteSpace($SavedDefaultProfile)) { $env:AWS_DEFAULT_PROFILE = $SavedDefaultProfile }
        else { Remove-Item Env:\AWS_DEFAULT_PROFILE -ErrorAction SilentlyContinue }
        if (-not [string]::IsNullOrWhiteSpace($SavedSsoProfile)) { $env:AWS_SSO_PROFILE = $SavedSsoProfile }
        else { Remove-Item Env:\AWS_SSO_PROFILE -ErrorAction SilentlyContinue }
        if (-not [string]::IsNullOrWhiteSpace($SavedConfigFile)) { $env:AWS_CONFIG_FILE = $SavedConfigFile }
        else { Remove-Item Env:\AWS_CONFIG_FILE -ErrorAction SilentlyContinue }
        if (-not [string]::IsNullOrWhiteSpace($SavedSharedCredentialsFile)) { $env:AWS_SHARED_CREDENTIALS_FILE = $SavedSharedCredentialsFile }
        else { Remove-Item Env:\AWS_SHARED_CREDENTIALS_FILE -ErrorAction SilentlyContinue }

        # Clean up temp files
        Remove-Item -Path $TempCredDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
