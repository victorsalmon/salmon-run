<#
.SYNOPSIS
    Checks environment for available coding API keys and reports status.
.DESCRIPTION
    Scans env vars for OPENCODE_GO1_KEY, OPENCODE_GO5_KEY.
    Throws if fewer than RequiredCount keys are found. Displays helpful
    setup instructions when keys are missing.
.PARAMETER RequiredCount
    Minimum number of keys that must be available. Defaults to 1.
.PARAMETER ProjectCode
    Optional project code for AWS SM fallback lookup.
.OUTPUTS
    OrderedHashtable of available key name to description mappings.
#>
function Test-CodingKeyAvailability {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [int]$RequiredCount = 1,
        [string]$ProjectCode
    )

    $KeyRegistry = [ordered]@{
        "OPENCODE_GO1_KEY" = "opencode-go (Minimax M2.7)"
        "OPENCODE_GO5_KEY" = "opencode-go key 5 (backup)"
    }

    $AvailableKeys = @()
    foreach ($KeyName in $KeyRegistry.Keys) {
        $Val = [System.Environment]::GetEnvironmentVariable($KeyName)
        if (-not [string]::IsNullOrWhiteSpace($Val)) {
            $AvailableKeys += $KeyName
            Write-Information -MessageData "  [OK]   $KeyName ($($KeyRegistry[$KeyName]))" -Tags "INFO"
        }
        else {
            Write-Information -MessageData "  [SKIP] $KeyName ($($KeyRegistry[$KeyName])) -- not configured" -Tags "INFO"
        }
    }

    if ($AvailableKeys.Count -lt $RequiredCount) {
        Write-Information -MessageData "`n  [FAIL] No coding CLI keys available. At least one of:" -Tags "ERROR"
        foreach ($K in $KeyRegistry.Keys) {
            Write-Information -MessageData "    - $K ($($KeyRegistry[$K]))" -Tags "ERROR"
        }
        Write-Information -MessageData ""
        $smPath = "Interclaw/$(Get-ProjectCode)/Provisioning"
        Write-Information -MessageData "  Add to AWS Secrets Manager ($smPath):" -Tags "INFO"
        foreach ($K in $KeyRegistry.Keys) {
            Write-Information -MessageData "    `$Secrets | Add-Member -NotePropertyName `"$K`" -NotePropertyValue `"your-key`" -Force" -Tags "INFO"
        }
        Write-Information -MessageData '    $Updated = $Secrets | ConvertTo-Json -Compress' -Tags "INFO"
        Write-Information -MessageData "    aws secretsmanager put-secret-value --secret-id `"$smPath`" --secret-string `$Updated --profile interclaw" -Tags "INFO"
        Write-Information -MessageData ""
        Write-Information -MessageData "  Or add to <project-root>/install.json:" -Tags "INFO"
        foreach ($K in $KeyRegistry.Keys) {
            Write-Information -MessageData "    $K=your-key-here" -Tags "INFO"
        }
        Write-SetupLog "Phase 0b FAILED: no coding keys available" -Level ERROR
        throw "No coding keys available. Required: $RequiredCount, found: $($AvailableKeys.Count)"
    }

    Write-SetupLog "Phase 0b: $($AvailableKeys.Count) coding key(s) available: $($AvailableKeys -join ', ')"
    Write-Information -MessageData "  [PASS] $($AvailableKeys.Count) coding key(s) available" -Tags "INFO"

    return [pscustomobject]@{
        Available     = ($AvailableKeys.Count -ge $RequiredCount)
        KeyCount      = $AvailableKeys.Count
        AvailableKeys = $AvailableKeys
        KeyRegistry   = $KeyRegistry
    }
}

