function Invoke-PondTaskPrepare {
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
        $Context.Continue = $false
        return $Context
    }

    $files = @(Get-ChildItem "$lanePath/*.md" -ErrorAction SilentlyContinue)
    $lockRe = '(?im)^\*\*Lock\*\*'
    foreach ($file in $files) {
        $src = $file.FullName
        if (-not (Test-Path -LiteralPath $src)) { continue }
        $content = Get-Content -LiteralPath $src -Raw
        if ($content -notmatch $lockRe) {
            $lock = @"

**Lock**
- Agent:
- StartTime: $(Get-Date -Format 'o')
- Lane: $($group.LaneId)
- Stream: $(if ($group.Stream) { $group.Stream.Id } else { 'main' })
"@
            $content + $lock | Set-Content -LiteralPath $src -Encoding utf8 -NoNewline
        }
    }

    return $Context
}
