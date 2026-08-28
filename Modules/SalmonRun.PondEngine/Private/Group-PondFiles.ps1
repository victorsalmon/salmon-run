<#
.SYNOPSIS
    Groups pond candidate files by the pond's GroupBy property.
.DESCRIPTION
    Supported GroupBy values:
      - 'Namespace'  : group by namespace derived from filename
      - 'None'       : each file is its own group
      - 'ProjectId'  : group by **ProjectId** header
      - 'Role|Namespace|Module' : legacy connascence grouping

    When a pond sets Operators.MaxFilesPerGroup, each namespace (or project)
    group larger than that limit is split into smaller chunks.  This keeps a
    single lane from running an unbounded number of plans and timing out.
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

    # Split a flat list of files into one or more PondGroups respecting the
    # per-group file cap.  Namespace/role are preserved; Module gets a chunk suffix
    # so logs can distinguish the batches.
    function New-ChunkedGroups {
        param(
            [string]$Namespace,
            [string]$Role,
            [System.IO.FileInfo[]]$Items
        )
        $sorted = @($Items | Sort-Object Name)
        $chunkSize = if ($max -gt 0) { $max } else { $sorted.Count }
        $groups = @()
        for ($i = 0; $i -lt $sorted.Count; $i += $chunkSize) {
            $chunk = $sorted[$i..([math]::Min($i + $chunkSize - 1, $sorted.Count - 1))]
            $g = [PondGroup]::new()
            $g.Namespace = $Namespace
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
            $g.Namespace = $f.BaseName
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
            if ($m.Success) { $m.Groups['value'].Value.Trim() } else { $_.BaseName }
        }
        $groups = foreach ($grp in $grouped) {
            New-ChunkedGroups -Namespace $grp.Name -Role $Pond.Role -Items @($grp.Group)
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
            New-ChunkedGroups -Namespace $parts[1] -Role $parts[0] -Items @($grp.Group) |
                ForEach-Object { $_.Module = $parts[2]; $_ }
        }
        return $groups
    }

    # Default: Namespace derived consistently with Get-PondWorktreeStreams.
    $grouped = $Files | Group-Object {
        Get-PondFileNamespace -FileName $_.Name
    }
    $groups = foreach ($grp in $grouped) {
        New-ChunkedGroups -Namespace $grp.Name -Role $Pond.Role -Items @($grp.Group)
    }
    return $groups
}
