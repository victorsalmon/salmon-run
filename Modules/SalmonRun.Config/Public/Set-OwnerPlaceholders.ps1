<#
.SYNOPSIS
    Configures or reconfigures owner placeholder values interactively.
.DESCRIPTION
    Prompts the user for each owner field (name, phone, pronouns, etc.)
    and saves them to the owner config JSON file. Skips if NonInteractive
    and existing config is present.
.PARAMETER NonInteractive
    Switch to suppress prompts. Uses existing config without changes.
.OUTPUTS
    Hashtable of configured placeholder name-value pairs.
#>
function Set-OwnerPlaceholders {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([switch]$NonInteractive)

    $existing = Get-OwnerPlaceholders
    $hasExisting = $existing.Count -gt 0

    if ($hasExisting) {
        Write-Information -MessageData "`n  Existing owner configuration found:" -Tags "INFO"
        foreach ($k in $existing.Keys | Sort-Object) {
            Write-Information -MessageData "    $k = $($existing[$k])" -Tags "INFO"
        }
        if (-not $NonInteractive) {
            $overwrite = Read-Host "`n  Reconfigure? [y/N] "
            if ($overwrite -notmatch '^[Yy]') {
                Write-Information -MessageData "  [SKIP] Owner configuration unchanged." -Tags "INFO"
                return $existing
            }
        }
    }

    if ($NonInteractive) {
        $exampleDefaults = @{
            OWNER_NAME        = "Your Name"
            OWNER_SHORT_NAME  = "you"
            OWNER_PHONE       = "+15551234567"
            OWNER_PRONOUNS    = "they/them"
            OWNER_LOCATION    = "Your City"
            OWNER_TIMEZONE    = "America/New_York"
            OWNER_BUSINESS    = "Your Business"
            OWNER_BUSINESS_NAME = ""
            OWNER_TELEGRAM    = "@yourhandle"
            OWNER_GITHUB      = "your-github-user"
        }
        foreach ($k in $exampleDefaults.Keys) {
            if ($existing.ContainsKey($k) -and $existing[$k] -eq $exampleDefaults[$k]) {
                throw "NonInteractive mode: $k still has example value '$($exampleDefaults[$k])'. Run interactively to set real values."
            }
        }
        Write-Information -MessageData "  [SKIP] NonInteractive mode — returning existing config unchanged." -Tags "INFO"
        return $existing
    }

    $PlaceholderMeta = @{
        OWNER_NAME        = @{ Prompt = "Full name"; Default = "(example) Your Name" }
        OWNER_SHORT_NAME  = @{ Prompt = "What to call you (short name)"; Default = "(example) you" }
        OWNER_PHONE       = @{ Prompt = "Signal phone number (with country code)"; Default = "(example) +15551234567" }
        OWNER_PRONOUNS    = @{ Prompt = "Pronouns"; Default = "(example) they/them" }
        OWNER_LOCATION    = @{ Prompt = "Your location (city)"; Default = "(example) Your City" }
        OWNER_TIMEZONE    = @{ Prompt = "IANA timezone"; Default = "(example) America/New_York" }
        OWNER_BUSINESS    = @{ Prompt = "Your business or organization name"; Default = "(example) Your Business" }
        OWNER_BUSINESS_NAME = @{ Prompt = "Business display name (if different)"; Default = "(example)" }
        OWNER_TELEGRAM    = @{ Prompt = "Telegram handle (with @)"; Default = "(example) @yourhandle" }
        OWNER_GITHUB      = @{ Prompt = "GitHub username"; Default = "(example) your-github-user" }
    }

    $newConfig = @{}
    Write-Information -MessageData "`n  Owner Configuration Wizard" -Tags "INFO"
    Write-Information -MessageData "  Press Ctrl+C to cancel without saving. Leave blank to keep default.`n" -Tags "INFO"

    foreach ($key in ($PlaceholderMeta.Keys | Sort-Object)) {
        $meta = $PlaceholderMeta[$key]
        $existingVal = if ($hasExisting -and $existing.ContainsKey($key)) { $existing[$key] } else { $meta.Default }
        $promptText = "  $($meta.Prompt) [$existingVal]"
        if ($key -eq "OWNER_BUSINESS_NAME" -and [string]::IsNullOrWhiteSpace($existingVal)) {
            $promptText = "  $($meta.Prompt) [{OWNER_BUSINESS}]"
        }
        $input = Read-Host $promptText
        if ([string]::IsNullOrWhiteSpace($input)) { $input = $existingVal }
        if ($input -match '^\(example\)') {
            Write-Warning "  Value '$input' looks like an example — please enter a real value."
            $input = Read-Host "  $($meta.Prompt) [REQUIRED]"
        }
        $newConfig[$key] = $input
    }

    $configDir = Split-Path $script:OwnerConfigPath -Parent
    if (-not (Test-Path $configDir)) { New-Item -ItemType Directory -Path $configDir -Force | Out-Null }

    $newConfig | Write-AtomicJson -Path $script:OwnerConfigPath -Depth 3

    Write-Information -MessageData "`n  [OK] Owner configuration saved to $($script:OwnerConfigPath)" -Tags "INFO"
    Write-SetupLog "Owner configuration saved to $script:OwnerConfigPath"

    return $newConfig
}

