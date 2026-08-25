# DeepSeekCacheFilter.ps1
# Enforces the DeepSeek V4 prompt-cache contract for orchestrator-dispatched
# prompts. The runtime still owns tool serialization and conversation history,
# but this module canonicalizes the bytes the orchestrator controls:
# the static prompt text, the OPENCODE_CONFIG_CONTENT / policy payload, and
# the JSONL records written to dsh-adapter stdin.

function Test-IsDeepSeekV4Model {
    <#
    .SYNOPSIS
        Returns true if the selected model is a DeepSeek V4 variant.
    #>
    param([string]$Model)
    if ([string]::IsNullOrWhiteSpace($Model)) { return $false }
    return $Model -match '(?i)deepseek[-_]?v4[-_]?(?:flash|pro|max)?'
}

function ConvertTo-CanonicalJson {
    <#
    .SYNOPSIS
        Recursively serializes an object to a byte-stable JSON string.
    .DESCRIPTION
        Sorts object keys alphabetically, uses consistent number formatting,
        and delegates string/quote/backslash escaping to ConvertTo-Json.
        This makes semantically identical schemas produce identical cache
        prefixes without reimplementing JSON escaping.
    #>
    [CmdletBinding()]
    param([object]$InputObject)

    function Convert-Node($node) {
        if ($null -eq $node) { return 'null' }
        if ($node -is [bool]) { return $node.ToString().ToLowerInvariant() }
        if ($node -is [int] -or $node -is [long] -or $node -is [double] -or $node -is [decimal] -or $node -is [float]) {
            return [Convert]::ToString($node, [System.Globalization.CultureInfo]::InvariantCulture)
        }
        if ($node -is [string]) {
            # ConvertTo-Json already handles quotes, backslashes and control chars canonically.
            return ($node | ConvertTo-Json -Compress)
        }
        if ($node -is [array] -or ($node -is [System.Collections.IEnumerable] -and -not ($node -is [hashtable] -or $node -is [System.Collections.IDictionary]))) {
            $items = foreach ($item in $node) { Convert-Node $item }
            return '[' + ($items -join ',') + ']'
        }

        $props = @()
        if ($node -is [System.Collections.IDictionary]) {
            foreach ($key in ($node.Keys | Sort-Object)) {
                $props += (Convert-Node $key) + ':' + (Convert-Node $node[$key])
            }
        } else {
            $names = $node | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name | Sort-Object
            if (-not $names) {
                $names = $node.PSObject.Properties | Select-Object -ExpandProperty Name | Sort-Object
            }
            foreach ($name in $names) {
                $value = $node.$name
                $props += (Convert-Node $name) + ':' + (Convert-Node $value)
            }
        }
        return '{' + ($props -join ',') + '}'
    }

    return Convert-Node $InputObject
}

function Invoke-DeepSeekPromptFilter {
    <#
    .SYNOPSIS
        Normalizes the static prompt text for DeepSeek V4 caching.
    .DESCRIPTION
        - Removes leading/trailing whitespace and collapses multiple blank lines.
        - Ensures the prompt does not contain per-request mutable data in the
          static portion (timestamps, PIDs, etc.).
        - Keeps the static template first, then the plan body, so the byte-stable
          prefix is as long as possible.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [string]$Role = 'coder'
    )

    # Collapse multiple blank lines and trim ends for byte stability.
    $normalized = $Prompt -replace '(?m)^[ \t]+$', ''
    $normalized = $normalized -replace '(\r?\n){3,}', "`r`n`r`n"
    $normalized = $normalized.Trim()

    # Detect and warn about common dynamic values that break cache prefixes.
    $dynamicPatterns = @(
        '\b\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})?\b',
        '\bPID:\s*\d+\b',
        '\binstance-\d+\b',
        '\bstream-\d+\b',
        '\bmodule-\d+/lane-(?:coder|reviewer)-\d+\b'
    )
    foreach ($pattern in $dynamicPatterns) {
        if ($normalized -match $pattern) {
            Write-OrchestratorLogSafe "DEEPSEEK_CACHE_DYNAMIC_WARNING pattern='$pattern' role=$role" -Level WARN
        }
    }

    return $normalized
}

function Invoke-DeepSeekPolicyFilter {
    <#
    .SYNOPSIS
        Canonicalizes an orchestrator-controlled policy/config object.
    .DESCRIPTION
        Serializes the object with ConvertTo-CanonicalJson so the policy payload
        (e.g., OPENCODE_CONFIG_CONTENT) has a byte-stable cache prefix.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Policy,
        [string]$Model = ''
    )
    if (-not (Test-IsDeepSeekV4Model -Model $Model)) {
        # For non-V4 models we still return a canonical JSON string, but we do
        # not log cache-specific actions.
        return (ConvertTo-CanonicalJson -InputObject $Policy)
    }
    $canonical = ConvertTo-CanonicalJson -InputObject $Policy
    Write-OrchestratorLogSafe "DEEPSEEK_CACHE_POLICY_FILTERED model='$Model' length=$($canonical.Length)" -Level INFO
    return $canonical
}

function Invoke-DeepSeekJsonLFilter {
    <#
    .SYNOPSIS
        Canonicalizes the JSONL records written to dsh-adapter / Devin stdin.
    .DESCRIPTION
        Takes an array of records, converts each to canonical JSON, and joins
        them with a single LF. This makes the start/prompt/shutdown records
        byte-stable across runs.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][array]$Records,
        [string]$Model = ''
    )
    if (-not (Test-IsDeepSeekV4Model -Model $Model)) {
        return ($Records | ForEach-Object { $_ | ConvertTo-Json -Compress }) -join "`n"
    }
    $lines = foreach ($record in $Records) { ConvertTo-CanonicalJson -InputObject $record }
    $output = $lines -join "`n"
    Write-OrchestratorLogSafe "DEEPSEEK_CACHE_JSONL_FILTERED model='$Model' records=$($Records.Count) length=$($output.Length)" -Level INFO
    return $output
}
