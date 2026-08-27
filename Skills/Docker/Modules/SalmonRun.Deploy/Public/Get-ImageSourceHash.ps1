<#
.SYNOPSIS
    Cached content-hash computation for Docker images to detect staleness.
.DESCRIPTION
    Computes a SHA256 content hash of a Dockerfile and all files referenced by COPY
    instructions. Results are cached in a module-scoped hashtable with mtime-based
    staleness detection. Used by parallel image build to skip rebuilding images whose
    source files haven't changed.
.PARAMETER DockerfilePath
    Path to the Dockerfile to hash.
.PARAMETER TargetDir
    Build context directory for resolving COPY source paths.
.PARAMETER ImageName
    Image name for cache key and logging.
#>
$script:ImageSourceHashCache = @{}

<#
.SYNOPSIS
    Computes a content hash of Dockerfile and source files to detect image staleness.
#>
function Get-ImageSourceHash {
    [OutputType([void])]
    param(
        [string]$DockerfilePath,
        [string]$TargetDir,
        [string]$ImageName
    )
    $CacheKey = $DockerfilePath

    if ($script:ImageSourceHashCache.ContainsKey($CacheKey)) {
        $Cached = $script:ImageSourceHashCache[$CacheKey]
        $Stale = $false
        foreach ($Source in $Cached.Sources) {
            if (Test-Path -LiteralPath $Source) {
                $CurrentMtime = (Get-Item -LiteralPath $Source).LastWriteTimeUtc
                if ($CurrentMtime -gt $Cached.Timestamp) {
                    $Stale = $true
                    break
                }
            }
        }
        if (-not $Stale) {
            Write-SetupLog "  [CACHE] Source hash for $ImageName unchanged (mtime check)" -Level DEBUG
            return $Cached.Hash
        }
        Write-SetupLog "  [CACHE] Source hash for $ImageName STALE (file modified)" -Level DEBUG
    }

    $HashInput = Get-Content -LiteralPath $DockerfilePath -Raw -ErrorAction SilentlyContinue
    if (-not $HashInput) {
        throw "Dockerfile not found or empty: $DockerfilePath"
    }
    $CopyMatches = [regex]::Matches($HashInput, 'COPY\s+(\S+)\s+', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $SourceFiles = [System.Collections.Generic.List[string]]::new()
    $SourceFiles.Add($DockerfilePath)
    foreach ($Cm in $CopyMatches) {
        $CopySrc = Join-Path $TargetDir ($Cm.Groups[1].Value)
        if (Test-Path -LiteralPath $CopySrc -PathType Leaf) {
            $HashInput += "`n---$($Cm.Groups[1].Value)---`n" + (Get-Content -LiteralPath $CopySrc -Raw)
            $SourceFiles.Add($CopySrc)
        } elseif (Test-Path -LiteralPath $CopySrc -PathType Container) {
            $AllFiles = Get-ChildItem -LiteralPath $CopySrc -File -Recurse | Sort-Object FullName
            foreach ($File in $AllFiles) {
                if ($File.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
                $content = Get-Content -LiteralPath $File.FullName -Raw -ErrorAction SilentlyContinue
                if ($null -eq $content) { continue }
                $HashInput += "`n---$($Cm.Groups[1].Value)$($File.FullName.Substring($CopySrc.Length))---`n" + $content
                $SourceFiles.Add($File.FullName)
            }
        }
    }
    $SourceHash = (Get-FileHash -InputStream ([System.IO.MemoryStream]::new([System.Text.Encoding]::UTF8.GetBytes($HashInput))) -Algorithm SHA256).Hash.Substring(0, 16)

    $script:ImageSourceHashCache[$CacheKey] = @{
        Hash      = $SourceHash
        Timestamp = Get-Date
        Sources   = $SourceFiles
    }

    return $SourceHash
}
