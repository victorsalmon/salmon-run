<#
.SYNOPSIS
    Groups pond candidate files by the pond's GroupBy property.
.DESCRIPTION
    Supported GroupBy values:
      - 'Namespace'  : group by namespace derived from filename
      - 'None'       : each file is its own group
      - 'ProjectId'  : group by **ProjectId** header
      - 'Role|Namespace|Module' : legacy connascence grouping
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

    if ($Pond.GroupBy -eq 'None' -or $Files.Count -eq 0) {
        $groups = foreach ($f in $Files) {
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
            $g = [PondGroup]::new()
            $g.Namespace = $grp.Name
            $g.Role = $Pond.Role
            $g.Module = 'main'
            $g.Files = @($grp.Group)
            $g
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
            $g = [PondGroup]::new()
            $g.Namespace = $parts[1]
            $g.Role = $parts[0]
            $g.Module = $parts[2]
            $g.Files = @($grp.Group)
            $g
        }
        return $groups
    }

    # Default: Namespace
    $grouped = $Files | Group-Object {
        if ($_.Name -match '^(\d{4}[-.]?\d{2}[-.]?\d{2})-([^-]+)-.*$') { $Matches[2] } else { $_.BaseName }
    }
    $groups = foreach ($grp in $grouped) {
        $g = [PondGroup]::new()
        $g.Namespace = $grp.Name
        $g.Role = $Pond.Role
        $g.Module = 'main'
        $g.Files = @($grp.Group)
        $g
    }
    return $groups
}
