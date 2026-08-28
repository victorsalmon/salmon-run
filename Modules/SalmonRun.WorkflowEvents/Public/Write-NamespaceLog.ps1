function Write-NamespaceLog {
    <#
    .SYNOPSIS
        Appends a JSONL entry to Tasks/Logs/<Namespace>.log for decision/knowledge logging.
    .DESCRIPTION
        Writes one JSONL line to Tasks/Logs/<Namespace>.log with a timestamp, agent
        identity, event type, detail string, and associated file paths.

        Unlike Write-WorkflowEvent (which tracks inter-agent coordination with mutex
        and byte-offset), this is a lightweight append — no locking, no offsets.
        The file is created on first use. Best-effort — never throws on IO failure.

        Use this for: decisions, lessons learned, state changes, failure patterns,
        approved pivots, and any knowledge that needs to survive across sessions.
    .PARAMETER Namespace
        Domain/entity name matching the project's logical areas:
        example-project, example-consulting, Bookkeeper, deploy, sentry, plan,
        audit, cowork, base, skill-dev, infrastructure.
    .PARAMETER Type
        Event subtype: MEMORY (default), DECISION, LESSON, PIVOT, STATE_CHANGE,
        FAILURE_PATTERN, CONFUSION, NOTE.
    .PARAMETER Detail
        Free-text description of the event.
    .PARAMETER Files
        Array of file paths relevant to the event.
    .PARAMETER AgentId
        Agent identity. Defaults to $env:OC_RESERVATION_AGENT_ID, else "<unknown>".
    .PARAMETER Phase
        Agent phase at time of event: coder, reviewer, sentry, rescue, audit,
        planner, cowork, Bookkeeper.
    .EXAMPLE
        Write-NamespaceLog -Namespace example-project -Type DECISION -Detail "Switched RBC-FRA to monthly Plaid sync"
    .EXAMPLE
        Write-NamespaceLog -Namespace Bookkeeper -Type LESSON -Detail "Categorization rules need separate entries for EXAMPLE-ACCT and EXAMPLE-CARD" -Files @("docs/examples/categorization-rules.json")
    #>
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [string]$Namespace,

        [Parameter(Mandatory)]
        [ValidateSet('MEMORY', 'DECISION', 'LESSON', 'PIVOT', 'STATE_CHANGE', 'FAILURE_PATTERN', 'CONFUSION', 'NOTE')]
        [string]$Type,

        [string]$Detail = '',

        [string[]]$Files = @(),

        [string]$AgentId = $env:OC_RESERVATION_AGENT_ID,

        [string]$Phase = ''
    )

    $Files = @() + $Files
    $taskRoot = try { Get-SalmonTaskRoot } catch { $PWD.Path }
    $logFile = Join-Path $taskRoot 'Logs' "$Namespace.log"

    try {
        $null = New-Item -ItemType Directory -Path (Join-Path $taskRoot 'Logs') -Force

        $eventItem = @{
            id     = (Get-Date -Format 'yyyyMMddHHmmssfff') + '-' + [System.IO.Path]::GetRandomFileName().Substring(0, 8)
            ts     = [datetime]::UtcNow.ToString('o')
            agent  = $AgentId
            ns     = $Namespace
            type   = $Type
            phase  = $Phase
            files  = $Files
            detail = $Detail
        }

        $json = $eventItem | ConvertTo-Json -Compress -ErrorAction SilentlyContinue
        if ($json) {
            Add-Content -Path $logFile -Value $json -Encoding utf8 -ErrorAction SilentlyContinue
        }
    } catch {
        Write-Debug "Write-NamespaceLog failed: $_"
    }
}

