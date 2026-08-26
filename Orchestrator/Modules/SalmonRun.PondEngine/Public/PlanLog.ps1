<#
.SYNOPSIS
    Read and append the shared **PondLog** history section of a salmon-run plan.
.DESCRIPTION
    Every pond writes timestamped, named events into a single **PondLog** section.
    Get-PlanPondLog returns those events; Add-PlanPondLog appends one.
    Add-PlanPondLog uses a per-plan file lock under ~/.salmon/Tasks/Locks to avoid
    cross-agent races without taking a dependency on SalmonRun.Locking module load order.
#>

$script:SchemaPath = Join-Path $script:ModuleRoot 'Config' 'plan-header-schema.json'
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

        $match = [regex]::Match(
            $content,
            '(?im)^\*\*PondLog\*\*\s*(?:\r?\n)+\s*```json\s*(?:\r?\n)+(.*?)\s*```',
            [System.Text.RegularExpressions.RegexOptions]::Singleline
        )

        if (-not $match.Success) {
            return @()
        }

        $json = $match.Groups[1].Value.Trim()
        if ([string]::IsNullOrWhiteSpace($json) -or $json -eq '[]') {
            return @()
        }

        try {
            $entries = $json | ConvertFrom-Json -ErrorAction Stop
        } catch {
            Write-Error "PondLog section in $PlanPath is not valid JSON: $_"
            return @()
        }

        $result = $entries | Where-Object { $null -ne $_ } | ForEach-Object {
            if ($_ -is [hashtable]) { [PSCustomObject]$_ } else { $_ }
        }

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

        $re = [regex]::new(
            '(?im)^(\*\*PondLog\*\*\s*(?:\r?\n)+\s*```json\s*(?:\r?\n)+)(.*?)(\r?\n\s*```)',
            [System.Text.RegularExpressions.RegexOptions]::Singleline
        )

        $entries = @()
        $match = $re.Match($content)
        if ($match.Success) {
            $json = $match.Groups[2].Value.Trim()
            if (-not [string]::IsNullOrWhiteSpace($json) -and $json -ne '[]') {
                $entries = $json | ConvertFrom-Json -ErrorAction Stop
            }
            $pre = $content.Substring(0, $match.Groups[1].Index + $match.Groups[1].Length)
            $post = $content.Substring($match.Groups[3].Index)
        } else {
            $pre = $content.TrimEnd() + "`n`n**PondLog**`n```json`n"
            $post = "`n````n"
        }

        $entries = @($entries) + $newEntry
        $jsonBlock = $entries | ConvertTo-Json -Depth 3 -Compress:$false

        $newContent = $pre + $jsonBlock + "`n" + $post
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
