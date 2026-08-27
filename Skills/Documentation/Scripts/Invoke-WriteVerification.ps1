#Requires -Version 7
<#
.SYNOPSIS
    Verify that a recently-written file on disk actually contains the intended content.

.DESCRIPTION
    This script is the self-check floor for file writes. It should be called
    immediately after a Write/Edit tool writes or overwrites a file:

        & (Resolve-Path "Skills/Documentation/Scripts/Invoke-WriteVerification.ps1") `
            -Path "C:\...\file.ps1" -Contains "function Invoke-Example"

    If the content is not present (for example, the IDE had the file open and
    overwrote the agent's version, or the write tool reported success but the
    file was not updated), the script throws a descriptive error. It can also
    compare an expected full text or SHA256 hash.

.PARAMETER Path
    Absolute path to the file to verify.

.PARAMETER Contains
    A string that must be present in the file. Leading/trailing whitespace and
    line-ending style are normalized before the check.

.PARAMETER Match
    A regular expression that must match somewhere in the file.

.PARAMETER ExpectedContent
    The expected full content of the file. Line endings are normalized before
    comparison.

.PARAMETER ExpectedHash
    The expected SHA256 hash (as a hex string) of the file bytes.
#>
param(
    [Parameter(Mandatory)][string]$Path,
    [string]$Contains,
    [string]$Match,
    [string]$ExpectedContent,
    [string]$ExpectedHash
)

if (-not (Test-Path -Path $Path -PathType Leaf)) {
    throw "Write verification failed: file not found on disk at '$Path'"
}

$bytes = [System.IO.File]::ReadAllBytes($Path)
$hash = [System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)).Replace('-', '').ToLowerInvariant()
$text = [System.Text.Encoding]::UTF8.GetString($bytes)

$normText = ($text -replace "`r`n", "`n").Trim()

if ($ExpectedHash) {
    if ($ExpectedHash -ne $hash) {
        throw "Write verification failed: SHA256 hash mismatch for '$Path'. Expected '$ExpectedHash', got '$hash'. The file on disk may have been overwritten by another process."
    }
}

if ($ExpectedContent) {
    $normExpected = ($ExpectedContent -replace "`r`n", "`n").Trim()
    if ($normText -ne $normExpected) {
        throw "Write verification failed: full content mismatch for '$Path'. The file on disk does not match the expected content."
    }
}

if ($Contains) {
    $normContains = ($Contains -replace "`r`n", "`n").Trim()
    if (-not $normText.Contains($normContains)) {
        throw "Write verification failed: expected snippet not found in '$Path'. The file may not contain the change."
    }
}

if ($Match) {
    if (-not ($text -match $Match)) {
        throw "Write verification failed: regex '$Match' did not match in '$Path'."
    }
}

[PSCustomObject]@{
    Path = $Path
    Hash = $hash
    Length = $bytes.Length
    Verified = $true
}
