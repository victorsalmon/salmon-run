<#
.SYNOPSIS
    Validates that all COPY source paths in Dockerfiles reference existing files.
.DESCRIPTION
    Recursively scans for Dockerfiles, extracts COPY source paths, and checks
    each resolves to an existing file relative to RootDir. Skips COPY --from=
    (multi-stage) and wildcard paths. Returns a hashtable with Passed (bool)
    and Failures (string array).
.PARAMETER RootDir
    Root directory to scan for Dockerfiles and resolve COPY sources against.
.OUTPUTS
    Hashtable with Passed (bool) and Failures (string array).
#>
function Assert-DockerfileCopyPaths {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$RootDir
    )
    $failures = [System.Collections.Generic.List[string]]::new()
    $excludeDirs = @('.opencode', 'node_modules')
    $dockerfiles = Get-ChildItem -Path $RootDir -Recurse -Filter "*Dockerfile*" -File |
        Where-Object { $dir = $_.DirectoryName; -not ($excludeDirs | Where-Object { $dir -match "(^|[/\\])$_($|[/\\])" }) }
    foreach ($df in $dockerfiles) {
        $content = Get-Content -Path $df.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $content) { continue }
        foreach ($match in [regex]::Matches($content, '(?m)^COPY\s+(--from=\S+\s+)?(\S+)\s+(\S+)')) {
            $fromFlag = $match.Groups[1].Value
            $src = $match.Groups[2].Value
            $src = $src -replace '["\x27]', ''
            if ($fromFlag -match '--from=') { continue }
            if ($src -match '^/') { continue }
            if ($src -match '[\*\?]') { continue }
            $resolved = Join-Path $RootDir $src
            if (-not (Test-Path $resolved)) {
                $failures.Add("$($df.Name): COPY source '$src' not found (resolved: $resolved)")
            }
        }
    }
    $passed = $failures.Count -eq 0
    return @{ Passed = $passed; Failures = @($failures) }
}
