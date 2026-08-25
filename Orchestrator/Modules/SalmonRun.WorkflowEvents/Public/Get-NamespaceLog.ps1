function Get-NamespaceLog {
    <#
    .SYNOPSIS
        Reads entries from Tasks/Logs/<Namespace>.log with optional date filtering.
    .DESCRIPTION
        Returns all entries from the specified namespace log as an array of
        PSCustomObjects sorted by timestamp. Supports optional Since/Until
        date filters. Best-effort — never throws on IO failure.
    .PARAMETER Namespace
        Namespace log to read (e.g. "example-project", "example-consulting").
    .PARAMETER Since
        Optional DateTime — return only entries at or after this time.
    .PARAMETER Until
        Optional DateTime — return only entries at or before this time.
    .PARAMETER ListNamespaces
        Switch — returns all namespace log names found in Tasks/Logs/ instead of reading entries.
    .EXAMPLE
        Get-NamespaceLog -Namespace example-project
    .EXAMPLE
        Get-NamespaceLog -Namespace Bookkeeper -Since (Get-Date).AddDays(-7)
    .EXAMPLE
        Get-NamespaceLog -ListNamespaces
    #>
    [OutputType([array])]
    param(
        [string]$Namespace,

        [datetime]$Since,

        [datetime]$Until,

        [switch]$ListNamespaces
    )

    $repoRoot = try { & (Get-Item function:Get-SalmonRunRepoRoot -ErrorAction Stop) } catch { $PWD.Path }
    $logsDir = Join-Path $repoRoot 'Tasks' 'Logs'

    if ($ListNamespaces.IsPresent) {
        return Get-ChildItem -Path $logsDir -Filter '*.log' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne 'workflow-events.log' } |
            ForEach-Object { $_.BaseName } |
            Sort-Object
    }

    if (-not $Namespace) {
        Write-Debug "Get-NamespaceLog: -Namespace or -ListNamespaces required"
        return @()
    }

    $logFile = Join-Path $logsDir "$Namespace.log"

    if (-not (Test-Path $logFile)) {
        return @()
    }

    try {
        $entries = Get-Content -Path $logFile -ErrorAction SilentlyContinue |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object {
                try { $_ | ConvertFrom-Json -ErrorAction SilentlyContinue } catch { $null }
            } |
            Where-Object { $_ -ne $null }

        if ($Since) { $entries = $entries | Where-Object { $_.ts.ToUniversalTime() -ge $Since.ToUniversalTime() } }
        if ($Until) { $entries = $entries | Where-Object { $_.ts.ToUniversalTime() -le $Until.ToUniversalTime() } }

        return $entries | Sort-Object { $_.ts.ToUniversalTime() }
    } catch {
        Write-Debug "Get-NamespaceLog failed: $_"
        return @()
    }
}
