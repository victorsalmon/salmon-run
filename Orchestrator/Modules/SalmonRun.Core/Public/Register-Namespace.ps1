<#
.SYNOPSIS
    Registers a namespace reservation via a lock file, with stale-agent recovery.
.DESCRIPTION
    Creates or checks a reservation file under Tasks/Locks/ namespace-<Prefix>.reserved.
    If the file is held by a different agent whose heartbeat is stale (beyond
    NamespaceReclaimThresholdSeconds in SalmonRun.Constants), the reservation is
    reclaimed. Returns $true if acquired, $false otherwise.
    Aliases: Acquire-NamespaceReservation, Reserve-Namespace
.PARAMETER NamespacePrefix
    Prefix for the reservation filename.
.PARAMETER AgentId
    Agent identifier to stamp on the reservation file.
.OUTPUTS
    $true if the reservation was acquired, $false otherwise.
#>
function Register-Namespace {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$NamespacePrefix,

        [Parameter(Mandatory)]
        [string]$AgentId
    )

    $repoRoot = Get-SalmonRunRepoRoot
    $locksDir = Join-Path $repoRoot "Tasks" "Locks"
    $null = New-Item -ItemType Directory -Path $locksDir -Force

    $reservationPath = Join-Path $locksDir "namespace-$NamespacePrefix.reserved"

    try {
        $null = New-Item -ItemType File -Path $reservationPath -ErrorAction Stop
        "$AgentId | $(Get-Date -Format 'o')" | Write-AtomicFile -Path $reservationPath -Encoding Ascii
        return $true
    } catch {
        $contentRaw = Get-Content -Path $reservationPath -Raw -ErrorAction SilentlyContinue
        if (-not $contentRaw) { return $false }
        $content = $contentRaw.Trim()
        if ($content -match '^(.+?) \|') {
            $reservingAgent = $matches[1].Trim()
            if ($reservingAgent -eq $AgentId) {
                "$AgentId | $(Get-Date -Format 'o')" | Write-AtomicFile -Path $reservationPath -Encoding Ascii
                return $true
            }

            $agentsDir = Join-Path $locksDir ".." "Logs" "agents"
            $heartbeatPath = Join-Path $agentsDir "$reservingAgent.heartbeat"
            $stale = $true
            $hbContentRaw = Get-Content -Path $heartbeatPath -Raw -ErrorAction SilentlyContinue
            if ($hbContentRaw) {
                $hbContent = $hbContentRaw.Trim()
                if ($hbContent) {
                    $parsed = [datetime]::MinValue
                    if ([datetime]::TryParse($hbContent, [ref]$parsed)) {
                        $parsedUtc = $parsed.ToUniversalTime()
                        $reclaimThreshold = (Get-InterclawConstants).NamespaceReclaimThresholdSeconds
                        if (([datetime]::UtcNow - $parsedUtc).TotalSeconds -le $reclaimThreshold) {
                            $stale = $false
                        }
                    }
                }
            }

            if ($stale) {
                $fs = $null; $sw = $null
                try {
                    $fs = [System.IO.File]::Open($reservationPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
                    $sw = [System.IO.StreamWriter]::new($fs, [System.Text.Encoding]::ASCII)
                    $sw.Write("$AgentId | $(Get-Date -Format 'o')")
                    return $true
                } finally {
                    if ($sw) { $sw.Dispose() }
                    if ($fs) { $fs.Dispose() }
                }
            }
        }
        return $false
    }
}
