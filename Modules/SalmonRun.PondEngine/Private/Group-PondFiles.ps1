<#
.SYNOPSIS
    Groups pond candidate files by the pond's GroupBy property.
.DESCRIPTION
    Supported GroupBy values:
      - 'Namespace'  : group by exact plan family (original + feedback files)
                       while preserving the connascence namespace for stream/lane
                       selection.
      - 'None'       : each file is its own group
      - 'ProjectId'  : group by **ProjectId** header
      - 'Role|Namespace|Module' : legacy connascence grouping

    A plan family is one originally-written session plan plus all of its
    `-feedback<N>.md` descendants. Families are never split across groups, so
    the whole family moves through the pipeline as a unit.
#>
function Group-PondFiles {
    [CmdletBinding()]
    [OutputType([PondGroup[]])]
    param(
        [Parameter(Mandatory)]
        [Pond]$Pond,
        [Parameter(Mandatory)]
        [System.IO.FileInfo[]]$Files,
        [Parameter(Mandatory)]
        [PondContext]$Context
    )

    $max = if ($Pond.Operators -and $Pond.Operators.PSObject.Properties['MaxFilesPerGroup']) {
        $Pond.Operators.MaxFilesPerGroup
    } else { 0 }

    # Split a flat list of files into one or more PondGroups.  Families are not
    # split, so the chunk size is capped only for project/legacy groupings.
    function New-ChunkedGroups {
        param(
            [string]$Namespace,
            [string]$PlanFamily,
            [string]$Role,
            [System.IO.FileInfo[]]$Items,
            [int]$ChunkSize = -1
        )
        $sorted = @($Items | Sort-Object Name)
        $chunkSize = if ($ChunkSize -gt 0 -and $max -gt 0) { [math]::Min($ChunkSize, $max) } elseif ($max -gt 0) { $max } else { $sorted.Count }
        if ($chunkSize -le 0) { $chunkSize = $sorted.Count }
        $groups = @()
        for ($i = 0; $i -lt $sorted.Count; $i += $chunkSize) {
            $end = [math]::Min($i + $chunkSize - 1, $sorted.Count - 1)
            $chunk = $sorted[$i..$end]
            $g = [PondGroup]::new()
            $g.Namespace = $Namespace
            $g.PlanFamily = $PlanFamily
            $g.Role = $Role
            $g.Module = if ($i -eq 0) { 'main' } else { "main-$($i / $chunkSize + 1)" }
            $g.Files = @($chunk)
            $groups += $g
        }
        return $groups
    }

    if ($Pond.GroupBy -eq 'None' -or $Files.Count -eq 0) {
        $groups = foreach ($f in ($Files | Sort-Object Name)) {
            $g = [PondGroup]::new()
            $g.Namespace = (Get-PondFileNamespace -FileName $f.Name)
            $g.PlanFamily = (Get-PondFilePlanFamily -FileName $f.Name)
            $g.Role = $Pond.Role
            $g.Module = 'main'
            $g.Files = @($f)
            $g
        }
        return $groups
    }

    if ($Pond.GroupBy -eq 'ProjectId') {
        $grouped = $Files | Group-Object {
            $c = Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue
            $m = [regex]::Match($c, '(?im)^\*\*ProjectId\*\*:\s*(?<value>[^\r\n]+)')
            if ($m.Success) {
                $m.Groups['value'].Value.Trim()
            } else {
                # Standalone QA/planner plans that do not belong to a project must
                # still group by their connascence namespace so Get-StreamForGroup
                # can find a matching worktree stream.
                Get-PondFileNamespace -FileName $_.Name
            }
        }
        $groups = foreach ($grp in $grouped) {
            $first = $grp.Group | Select-Object -First 1
            $ns = Get-PondFileNamespace -FileName $first.Name
            $planFamily = Get-PondFilePlanFamily -FileName $first.Name
            New-ChunkedGroups -Namespace $ns -PlanFamily $planFamily -Role $Pond.Role -Items @($grp.Group) -ChunkSize 0
        }
        return $groups
    }

    if ($Pond.GroupBy -eq 'Role|Namespace|Module') {
        $grouped = $Files | Group-Object {
            $ns = if ($_.Name -match '^(\d{4}[-.]?\d{2}[-.]?\d{2})-([^-]+)-.*$') { $Matches[2] } else { $_.BaseName }
            "$($Pond.Role)|$ns|main"
        }
        $groups = foreach ($grp in $grouped) {
            $parts = $grp.Name -split '\|'
            $first = $grp.Group | Select-Object -First 1
            $planFamily = Get-PondFilePlanFamily -FileName $first.Name
            New-ChunkedGroups -Namespace $parts[1] -PlanFamily $planFamily -Role $parts[0] -Items @($grp.Group) -ChunkSize 0 |
                ForEach-Object { $_.Module = $parts[2]; $_ }
        }
        return $groups
    }

    # Default: group by exact plan family, keep connascence namespace for lane/streams.
    $grouped = $Files | Group-Object {
        Get-PondFilePlanFamily -FileName $_.Name
    }
    $groups = foreach ($grp in $grouped) {
        $first = $grp.Group | Select-Object -First 1
        $ns = Get-PondFileNamespace -FileName $first.Name
        $planFamily = $grp.Name
        New-ChunkedGroups -Namespace $ns -PlanFamily $planFamily -Role $Pond.Role -Items @($grp.Group) -ChunkSize 0
    }
    return $groups
}
