<#
.SYNOPSIS
    Returns the current queue contents for inspection.
.DESCRIPTION
    Lists all markdown files in the Code, Review, and Working queues with metadata
    such as file size, last write time, and optional Lock Header parsing.
.PARAMETER Queue
    Specific queue to inspect: Code, Review, Working, or All (default: All).
.PARAMETER AsTable
    If set, writes a formatted table to the console instead of returning objects.
.OUTPUTS
    PSCustomObject[] with queue contents grouped by queue type.
    When -AsTable is set, writes formatted tables to console.
.EXAMPLE
    $queue = Get-OrchestratorQueue
    Get-OrchestratorQueue -Queue Code -AsTable
#>
function Get-OrchestratorQueue {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [ValidateSet("Code", "Review", "Working", "Handoff", "Failed", "ToDo", "Manual", "Paused", "Complete", "Intake", "QA", "Audit", "Archive", "All")]
        [string]$Queue = "All",
        [switch]$AsTable
    )

    $RepoDir = $script:RepoRoot
    $results = [System.Collections.Generic.List[object]]::new()

    function Get-FileEntries {
        param([string]$DirPath, [string]$QueueName)
        $entries = @()
        if (-not (Test-Path $DirPath)) { return $entries }
        $files = Get-ChildItem "$DirPath/*.md" -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne '.gitkeep' }
        foreach ($f in $files) {
            $lockInfo = ""
            $agentId = ""
            $module = "unassigned"
            try {
                $header = Get-Content $f.FullName -TotalCount 10 -Raw -ErrorAction SilentlyContinue
                if ($header -match 'Agent: (\S+)') { $agentId = $Matches[1] }
                if ($header -match 'Status: (\S+)') { $lockInfo = $Matches[1] }
                if ($header -match '(?m)^\*\*Module\*\*:\s*(\S+)') {
                    $mod = $Matches[1].Trim()
                    $module = if ($mod -match '^\d+$') { "module-$mod" } elseif ($mod -ieq 'main' -or $mod -ieq '0') { 'main' } else { $mod }
                }
            } catch {
                    Write-SetupLog "Failed to parse Lock Header from $($f.FullName): $_" -Level WARN
                }
            $entries += [PSCustomObject]@{
                File         = $f.Name
                Queue        = $QueueName
                Module       = $module
                SizeKB       = [math]::Round($f.Length / 1KB, 1)
                LastWrite    = $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
                Agent        = $agentId
                LockStatus   = $lockInfo
            }
        }
        return $entries
    }

    $dirs = @()
    if ($Queue -in @("All", "Code"))    { $dirs += @{ Path = Join-Path $RepoDir "Tasks/Code"; Name = "Code" } }
    if ($Queue -in @("All", "Review"))  { $dirs += @{ Path = Join-Path $RepoDir "Tasks/Review"; Name = "Review" } }
    if ($Queue -in @("All", "Working")) {
        $workingDir = Join-Path $RepoDir "Tasks/Working"
        if (Test-Path $workingDir) {
            $streamDirs = Get-ChildItem "$workingDir/*" -Directory -ErrorAction SilentlyContinue
            if ($streamDirs) {
                foreach ($sd in $streamDirs) {
                    $entries = Get-FileEntries -DirPath $sd.FullName -QueueName "Working/$($sd.Name)"
                    $results.AddRange($entries)
                }
            }
            $flatFiles = Get-FileEntries -DirPath $workingDir -QueueName "Working"
            $results.AddRange($flatFiles)
        }
    }
    if ($Queue -in @("All", "Handoff")) { $dirs += @{ Path = Join-Path $RepoDir "Tasks/Handoff"; Name = "Handoff" } }
    if ($Queue -in @("All", "ToDo"))   { $dirs += @{ Path = Join-Path $RepoDir "Tasks/ToDo"; Name = "ToDo" } }
    if ($Queue -in @("All", "Manual")) { $dirs += @{ Path = Join-Path $RepoDir "Tasks/Manual"; Name = "Manual" } }
    if ($Queue -in @("All", "Paused")) { $dirs += @{ Path = Join-Path $RepoDir "Tasks/Paused"; Name = "Paused" } }
    if ($Queue -in @("All", "Failed")) { $dirs += @{ Path = Join-Path $RepoDir "Tasks/Failed"; Name = "Failed" } }
    if ($Queue -in @("All", "Intake")) { $dirs += @{ Path = Join-Path $RepoDir "Tasks/Intake"; Name = "Intake" } }
    if ($Queue -in @("All", "QA")) { $dirs += @{ Path = Join-Path $RepoDir "Tasks/QA"; Name = "QA" } }
    if ($Queue -in @("All", "Audit")) { $dirs += @{ Path = Join-Path $RepoDir "Tasks/Audit"; Name = "Audit" } }
    if ($Queue -in @("All", "Archive")) { $dirs += @{ Path = Join-Path $RepoDir "Tasks/Archive"; Name = "Archive" } }
    if ($Queue -in @("All", "Complete")) {
        $completeDir = Join-Path $RepoDir "Tasks/Complete"
        if (Test-Path $completeDir) {
            $subDirs = Get-ChildItem "$completeDir/*" -Directory -ErrorAction SilentlyContinue
            if ($subDirs) {
                foreach ($sd in $subDirs) {
                    $entries = Get-FileEntries -DirPath $sd.FullName -QueueName "Complete/$($sd.Name)"
                    $results.AddRange($entries)
                }
            }
            $flatFiles = Get-FileEntries -DirPath $completeDir -QueueName "Complete"
            $results.AddRange($flatFiles)
        }
    }

    foreach ($d in $dirs) {
        $entries = Get-FileEntries -DirPath $d.Path -QueueName $d.Name
        $results.AddRange($entries)
    }

    if ($AsTable) {
        $grouped = $results | Group-Object Queue
        foreach ($g in $grouped) {
            Write-Host "`n[$($g.Name)] $($g.Count) file(s)" -ForegroundColor Cyan
            if ($g.Count -gt 0) {
                Write-Host ("{0,-50} {1,-12} {2,8} {3,16} {4,20} {5,12}" -f "File", "Module", "Size(KB)", "LastWrite", "Agent", "Status") -ForegroundColor White
                Write-Host ("-" * 120) -ForegroundColor DarkGray
                foreach ($e in $g.Group) {
                    Write-Host ("{0,-50} {1,-12} {2,8} {3,16} {4,20} {5,12}" -f $e.File, $e.Module, $e.SizeKB, $e.LastWrite, $e.Agent, $e.LockStatus) -ForegroundColor DarkGray
                }
            }
        }
        return
    }

    return $results | Sort-Object Queue, File
}

Export-ModuleMember -Function Get-OrchestratorQueue
