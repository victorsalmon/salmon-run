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

    foreach ($file in $group.Files) {
        $dest = Join-Path $lanePath $file.Name
        if (Test-Path -LiteralPath $dest) { continue }
        Move-Item -LiteralPath $file.FullName -Destination $dest -Force -ErrorAction Stop
    }

    $Context.UsedNamespaces[$group.Namespace] = $true
    $Context.Continue = $true
    return $Context
}
