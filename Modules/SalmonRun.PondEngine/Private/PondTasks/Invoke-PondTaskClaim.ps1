function Invoke-PondTaskClaim {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [Pond]$Pond,
        [Parameter(Mandatory)]
        [PondTask]$Task,
        [Parameter(Mandatory)]
        [PondContext]$Context
    )

    $group = $Context.CurrentGroup
    if (-not $group) { $Context.Continue = $false; return $Context }

    $lanePath = $group.StreamPath
    if ([string]::IsNullOrWhiteSpace($lanePath)) {
        Write-Verbose "Invoke-PondTaskClaim: no lane path for group '$($group.Namespace)'"
        $Context.Continue = $false
        return $Context
    }

    $null = New-Item -ItemType Directory -Path $lanePath -Force -ErrorAction SilentlyContinue

    $sourcePaths = @($group.Files | ForEach-Object { $_.FullName })
    $destFiles = [System.Collections.Generic.List[System.IO.FileInfo]]::new()

    foreach ($file in $group.Files) {
        $dest = Join-Path $lanePath $file.Name
        if (Test-Path -LiteralPath $dest) { continue }
        Move-Item -LiteralPath $file.FullName -Destination $dest -Force -ErrorAction Stop
        $destFiles.Add((Get-Item -LiteralPath $dest))
    }

    # Commit and push the .salmon task repo for the claim.
    if ($destFiles.Count -gt 0) {
        $commitMsg = "claim: $($destFiles[0].Name) for $($Pond.Name)"
        Push-PondRepos -Pond $Pond -Context $Context -FinalDest $lanePath -SourcePaths $sourcePaths -DestFiles $destFiles -CommitMessage $commitMsg -TaskRepoOnly
    }

    $Context.UsedNamespaces[$group.Namespace] = $true
    $Context.Continue = $true
    return $Context
}
