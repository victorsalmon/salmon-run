param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ })]
    [string]$LogsDir,

    [Parameter()]
    [int]$MaxAgeHours = 48,

    [Parameter()]
    [switch]$DryRun
)

$cutoff = (Get-Date).AddHours(-$MaxAgeHours)
$compressed = 0
$skipped = 0

Get-ChildItem -LiteralPath $LogsDir -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
    $_.LastWriteTime -lt $cutoff -and
    $_.Extension -notin '.gz', '.zip' -and
    $_.DirectoryName -notmatch '\\Audit\\' -and
    $_.Name -notlike 'session-start*'
} | ForEach-Object {
    $relPath = $_.FullName.Substring($LogsDir.Length).TrimStart('\')
    if ($DryRun) {
        Write-Host "[DRY-RUN] Would compress: $relPath ($([math]::Round($_.Length/1KB, 1)) KB, last write: $($_.LastWriteTime))"
        $skipped++
        return
    }

    $gzPath = "$($_.FullName).gz"
    try {
        $bytes = [System.IO.File]::ReadAllBytes($_.FullName)
        $stream = [System.IO.File]::OpenWrite($gzPath)
        $gzip = [System.IO.Compression.GzipStream]::new($stream, [System.IO.Compression.CompressionMode]::Compress)
        $gzip.Write($bytes, 0, $bytes.Length)
        $gzip.Close()
        $stream.Close()
        Remove-Item -LiteralPath $_.FullName -Force
        $compressed++
        Write-Host "[COMPRESSED] $relPath ($([math]::Round($_.Length/1KB,1)) KB -> $([math]::Round((Get-Item $gzPath).Length/1KB,1)) KB)"
    } catch {
        Write-Host "[ERROR] Failed to compress $relPath : $_" -ForegroundColor Red
        if (Test-Path $gzPath) { Remove-Item -LiteralPath $gzPath -Force -ErrorAction SilentlyContinue }
    }
}

Write-Host "Done: $compressed file(s) compressed, $skipped skipped (dry-run)"
