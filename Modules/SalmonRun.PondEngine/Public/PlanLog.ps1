<#
.SYNOPSIS
    Read and append the shared **PondLog** history section of a salmon-run plan.
.DESCRIPTION
    Every pond writes timestamped, named events into a single **PondLog** section.
    Get-PlanPondLog returns those events; Add-PlanPondLog appends one.
    Add-PlanPondLog uses a per-plan file lock under ~/.salmon/Tasks/Locks to avoid
    cross-agent races without taking a dependency on SalmonRun.Locking module load order.

    The functions are resilient to malformed `PondLog` blocks (e.g. legacy evidence
    lines inserted inside the JSON fence or a corrupted closing fence). When a block
    cannot be parsed as a whole, a valid leading JSON array is extracted and any
    remaining text is moved after the closing fence.
#>

$script:SchemaPath = Join-Path (Join-Path $script:ModuleRoot 'Config') 'plan-header-schema.json'
$script:agentId = $null

<#
.SYNOPSIS
    Returns the parsed plan-header schema for this module.
#>
function Get-SalmonRunPlanSchema {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param()

    if (-not (Test-Path -LiteralPath $script:SchemaPath)) {
        throw "Plan header schema not found at $script:SchemaPath"
    }

    $text = Get-Content -LiteralPath $script:SchemaPath -Raw
    return $text | ConvertFrom-Json
}

<#
.SYNOPSIS
    Attempts to parse a JSON array that may have trailing non-JSON text.
.DESCRIPTION
    The opencode models sometimes insert a legacy evidence line such as
    `**Reviewed**: completed by ...` inside the ```json fence, after the closing
    `]` of the array.  This helper extracts the leading valid JSON array and
    returns any text that follows it.
#>
function Read-PondLogJsonArray {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Text
    )

    $result = @()
    $extra = ''

    if ([string]::IsNullOrWhiteSpace($Text) -or $Text.Trim() -eq '[]') {
        return @($result, $extra)
    }

    try {
        $result = $Text | ConvertFrom-Json -ErrorAction Stop
        return @($result, $extra)
    } catch {
        # Try to find a valid leading JSON array by trimming after the last ']'.
        # We walk backwards through each ']' because the legacy text appears after
        # the array's closing bracket.
        $idx = $Text.LastIndexOf(']')
        while ($idx -gt 0) {
            $candidate = $Text.Substring(0, $idx + 1)
            $trailing = $Text.Substring($idx + 1).Trim()
            try {
                $result = $candidate | ConvertFrom-Json -ErrorAction Stop
                $extra = $trailing
                return @($result, $extra)
            } catch {
                $idx = $Text.LastIndexOf(']', $idx - 1)
            }
        }
    }

    return @($result, $extra)
}

<#
.SYNOPSIS
    Returns the PondLog history from a plan file.
#>
function Get-PlanPondLog {
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [string]$PlanPath
    )

    process {
        if (-not (Test-Path -LiteralPath $PlanPath)) {
            return @()
        }

        $content = Get-Content -LiteralPath $PlanPath -Raw
        if ([string]::IsNullOrWhiteSpace($content)) {
            return @()
        }

        $re = [regex]::new(
            '(?im)^\*\*PondLog\*\*\s*(?:\r?\n)+\s*```json\s*(?:\r?\n)+(.*?)\r?\n\s*```[^\n]*',
            [System.Text.RegularExpressions.RegexOptions]::Singleline
        )

        $srMatchResults = $re.Matches($content)
        if ($srMatchResults.Count -eq 0) {
            return @()
        }

        $allEntries = [System.Collections.Generic.List[object]]::new()
        foreach ($m in $srMatchResults) {
            $json = $m.Groups[1].Value.Trim()
            $parsed, $extra = Read-PondLogJsonArray -Text $json
            if ($parsed) {
                $allEntries.AddRange(@($parsed | Where-Object { $null -ne $_ }))
            }
        }

        $result = @($allEntries | ForEach-Object {
            if ($_ -is [hashtable]) { [PSCustomObject]$_ } else { $_ }
        })

        return $result
    }
}

<#
.SYNOPSIS
    Appends a timestamped event to the **PondLog** section of a plan file.
#>
function Add-PlanPondLog {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [string]$PlanPath,

        [Parameter(Mandatory)]
        [object]$Entry
    )

    # Normalize the entry to a PSCustomObject with a fixed key order.
    $raw = if ($Entry -is [PSCustomObject]) { $Entry } else { [PSCustomObject]$Entry }
    $ordered = [ordered]@{}
    foreach ($key in @('ts', 'pond', 'role', 'action', 'detail', 'agent')) {
        $prop = $raw.PSObject.Properties[$key]
        $value = if ($null -ne $prop) { $prop.Value } else { $null }
        if ($null -ne $value) {
            $ordered[$key] = $value
        }
    }
    # Include any extra keys the caller supplied (e.g., lane, stream).
    foreach ($prop in $raw.PSObject.Properties) {
        if (-not $ordered.Contains($prop.Name)) {
            $ordered[$prop.Name] = $prop.Value
        }
    }

    # Default timestamp and lower-case action.
    if (-not $ordered.Contains('ts') -or [string]::IsNullOrWhiteSpace($ordered['ts'])) {
        $ordered['ts'] = [datetime]::UtcNow.ToString('o')
    }
    if ($ordered.Contains('action') -and -not [string]::IsNullOrWhiteSpace($ordered['action'])) {
        $ordered['action'] = $ordered['action'].ToString().ToLowerInvariant()
    } else {
        throw "Add-PlanPondLog: 'action' is required."
    }

    $schema = Get-SalmonRunPlanSchema
    $allowedActions = $schema.pondLogActions.PSObject.Properties.Name
    if ($allowedActions -notcontains $ordered['action']) {
        throw "Add-PlanPondLog: action '$($ordered['action'])' is not a standard PondLog action."
    }

    $newEntry = [PSCustomObject]$ordered

    # Claims, locks, routing, process starts, and Git transport are operational
    # telemetry. Keep them out of the immutable plan packet and in the bounded
    # external event journal.
    $operationalActions = @('claim','prepare','lock','route','spawn','commit','push')
    if ($ordered['action'] -in $operationalActions) {
        return Write-PondOperationalEvent -PlanPath $PlanPath -Entry $newEntry
    }

    # Acquire a per-plan cross-process mutex. Use the Global\ prefix so the
    # same plan file is protected across sessions, containers, and agent runspaces.
    $pathForHash = [System.Text.Encoding]::UTF8.GetBytes($PlanPath)
    $hash = [System.BitConverter]::ToString([System.Security.Cryptography.SHA1]::Create().ComputeHash($pathForHash)).Replace('-', '').ToLowerInvariant()
    $mutexName = "Global\SalmonRun-PlanLog-$hash"

    $mutex = $null
    $acquired = $false
    $createdNew = $false
    try {
        $mutex = [System.Threading.Mutex]::new($false, $mutexName, [ref]$createdNew)
        try {
            $acquired = $mutex.WaitOne([timespan]::FromSeconds(30))
        } catch [System.Threading.AbandonedMutexException] {
            # The previous owner terminated without releasing; ownership was transferred to us.
            $acquired = $true
        }

        if (-not $acquired) {
            throw "Add-PlanPondLog: could not acquire lock for $PlanPath"
        }

        $content = if (Test-Path -LiteralPath $PlanPath) {
            Get-Content -LiteralPath $PlanPath -Raw
        } else {
            ''
        }

        # Match all PondLog blocks.  We remove them, collect the entries, and write a
        # single clean block at the end of the file.  Any non-JSON text (e.g. legacy
        # evidence lines) found inside the old block is moved after the closing fence.
        $re = [regex]::new(
            '(?im)^\*\*PondLog\*\*\s*(?:\r?\n)+\s*```json\s*(?:\r?\n)+(.*?)\r?\n\s*```[^\n]*',
            [System.Text.RegularExpressions.RegexOptions]::Singleline
        )

        $srMatchResults = $re.Matches($content)
        $allEntries = [System.Collections.Generic.List[object]]::new()
        $extraText = [System.Collections.Generic.List[string]]::new()
        if ($srMatchResults.Count -gt 0) {
            foreach ($m in $srMatchResults) {
                $json = $m.Groups[1].Value
                $parsed, $extra = Read-PondLogJsonArray -Text $json
                if ($parsed) {
                    $allEntries.AddRange(@($parsed | Where-Object { $null -ne $_ }))
                }
                if (-not [string]::IsNullOrWhiteSpace($extra)) {
                    [void]$extraText.Add($extra)
                }
            }
            $content = $re.Replace($content, '').TrimEnd()
        }

        $allEntries.Add($newEntry)
        $boundedEntries = @($allEntries | Select-Object -Last 32)
        $jsonBlock = $boundedEntries | ConvertTo-Json -Depth 3 -Compress:$false

        $extraSection = if ($extraText.Count -gt 0) { "`n`n" + ($extraText -join "`n`n").Trim() } else { '' }
        $newContent = $content + "`n`n**PondLog**`n``````json`n" + $jsonBlock + "`n``````n" + $extraSection
        Set-Content -LiteralPath $PlanPath -Value $newContent -Encoding UTF8 -NoNewline
    } finally {
        if ($null -ne $mutex) {
            if ($acquired) {
                [void]$mutex.ReleaseMutex()
            }
            $mutex.Dispose()
        }
    }

    return $newEntry
}

