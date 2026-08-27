function Invoke-PondTaskArchive {
    <#
    .SYNOPSIS
        Compresses completed plans older than a configured age into archives.
    .DESCRIPTION
        Scans the Complete pond for .md files whose LastWriteTime is older than
        the configured AgeDays. Eligible files are compressed into a single
        archive under Tasks/Archive and then removed from Complete.
        Public-safe: prefers the 7z CLI when available, otherwise falls back to
        the built-in Compress-Archive cmdlet (producing .zip).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [Pond]$Pond,

        [Parameter(Mandatory)]
        [PondTask]$Task,

        [Parameter(Mandatory)]
        [PondContext]$Context
    )

    $ageDays = if ($Task.Arguments -and $null -ne $Task.Arguments['AgeDays']) { $Task.Arguments['AgeDays'] } else { 7 }
    $preferredFormat = if ($Task.Arguments -and $Task.Arguments['ArchiveFormat']) { $Task.Arguments['ArchiveFormat'] } else { '7z' }

    $completeDir = Get-PondQueuePath -Pond $Pond -Context $Context
    $archiveDir = Join-Path (Split-Path -Parent $completeDir) 'Archive'
    $null = New-Item -ItemType Directory -Path $archiveDir -Force -ErrorAction SilentlyContinue

    if (-not (Test-Path -LiteralPath $completeDir)) {
        $Context.Success = $true
        return $Context
    }

    $cutoff = (Get-Date).AddDays(-$ageDays)
    $files = @(Get-ChildItem -Path "$completeDir/*.md" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff } | Sort-Object Name)

    if ($files.Count -eq 0) {
        Write-Verbose "Invoke-PondTaskArchive: no plans older than $ageDays days"
        $Context.Success = $true
        return $Context
    }

    $use7z = $false
    $sevenZip = Get-Command '7z' -ErrorAction SilentlyContinue
    if ($preferredFormat -eq '7z' -and $sevenZip) {
        $use7z = $true
    }

    $dateStamp = (Get-Date -Format 'yyyyMMdd')
    $seq = 0
    do {
        $seq++
        $ext = if ($use7z) { '7z' } else { 'zip' }
        $archiveName = "archive-$dateStamp-{0:D3}.$ext" -f $seq
        $archivePath = Join-Path $archiveDir $archiveName
    } while (Test-Path -LiteralPath $archivePath)

    try {
        if ($use7z) {
            $argList = @('a', '-t7z', '-mx=5', $archivePath) + ($files | Select-Object -ExpandProperty FullName)
            $proc = Start-Process -FilePath $sevenZip.Source -ArgumentList $argList -NoNewWindow -Wait -PassThru
            if ($proc.ExitCode -ne 0) {
                throw "7z exited with code $($proc.ExitCode)"
            }
        } else {
            Compress-Archive -Path ($files | Select-Object -ExpandProperty FullName) -DestinationPath $archivePath -Force -ErrorAction Stop
        }

        # Remove only files that were actually archived.
        foreach ($file in $files) {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
        }

        Write-Verbose "Invoke-PondTaskArchive: archived $($files.Count) plan(s) to $archivePath"
        $Context.Success = $true
    } catch {
        Write-Warning "Invoke-PondTaskArchive: failed to archive plans: $_"
        $Context.Success = $false
    }

    return $Context
}
