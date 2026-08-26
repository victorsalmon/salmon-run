function Get-AuditLogPath {
    [OutputType([string])]
    param([string]$Domain)
    $domainDir = Join-Path $script:AuditRoot $Domain
    $null = New-Item -ItemType Directory -Path $domainDir -Force -ErrorAction SilentlyContinue
    return Join-Path $domainDir 'audit.jsonl'
}

function Invoke-AuditLogRotation {
    param([string]$LogPath)
    if (-not (Test-Path -LiteralPath $LogPath)) { return }
    $fileInfo = Get-Item -LiteralPath $LogPath
    if ($fileInfo.Length -lt $script:AuditMaxSizeBytes) { return }

    $domainDir = Split-Path -Parent $LogPath
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $compressedPath = Join-Path $domainDir "audit-$timestamp.jsonl.gz"

    try {
        $rawBytes = [System.IO.File]::ReadAllBytes($LogPath)
        $memoryStream = New-Object System.IO.MemoryStream
        $gzipStream = New-Object System.IO.Compression.GzipStream($memoryStream, [System.IO.Compression.CompressionMode]::Compress)
        $gzipStream.Write($rawBytes, 0, $rawBytes.Length)
        $gzipStream.Close()
        [System.IO.File]::WriteAllBytes($compressedPath, $memoryStream.ToArray())
        $memoryStream.Dispose()
        [System.IO.File]::WriteAllText($LogPath, '')
    } catch {
        Write-Warning "Invoke-AuditLogRotation: failed to rotate '$LogPath': $_"
        return
    }

    $rotatedFiles = Get-ChildItem -LiteralPath $domainDir -Filter 'audit-*.jsonl.gz' | Sort-Object Name -Descending
    if ($rotatedFiles.Count -gt $script:AuditMaxRotatedFiles) {
        $rotatedFiles | Select-Object -Skip $script:AuditMaxRotatedFiles | Remove-Item -Force -ErrorAction SilentlyContinue
    }
}
