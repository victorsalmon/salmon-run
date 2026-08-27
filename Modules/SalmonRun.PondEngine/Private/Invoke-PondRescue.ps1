function Invoke-PondRescue {
    <#
    .SYNOPSIS
        Rescues stale or failed plan files back to a source pond.
    .DESCRIPTION
        Scans -SourceDir for files matching -RescuePlan and moves them to
        -TargetDir. Files are considered stale if their last write time is older
        than -StaleThresholdSeconds. Existing files in the target are not
        overwritten; instead a numbered suffix is appended.
    .PARAMETER SourceDir
        Directory to scan (e.g. Tasks/Working or Tasks/Failed).
    .PARAMETER TargetDir
        Directory to move rescued files into.
    .PARAMETER StaleThresholdSeconds
        Age in seconds above which a file is rescued. Default 300.
    .PARAMETER RescuePlan
        Optional. If supplied, only files whose names match this wildcard pattern are rescued.
    .OUTPUTS
        PSCustomObject with Rescued, Skipped, and Errors counts.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$SourceDir,

        [Parameter(Mandatory)]
        [string]$TargetDir,

        [int]$StaleThresholdSeconds = 300,

        [string]$RescuePlan = '*.md'
    )

    $rescued = 0
    $skipped = 0
    $errors = 0

    if (-not (Test-Path $SourceDir)) { return [pscustomobject]@{ Rescued = 0; Skipped = 0; Errors = 0 } }
    $null = New-Item -ItemType Directory -Path $TargetDir -Force

    $cutoff = (Get-Date).AddSeconds(-$StaleThresholdSeconds)
    $files = Get-ChildItem -Path "$SourceDir\$RescuePlan" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff }

    foreach ($file in $files) {
        try {
            $dest = Join-Path $TargetDir $file.Name
            if (Test-Path $dest) {
                $base = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
                $ext = [System.IO.Path]::GetExtension($file.Name)
                $dest = Join-Path $TargetDir "$base-rescued$ext"
                $counter = 1
                while (Test-Path $dest) {
                    $dest = Join-Path $TargetDir "$base-rescued-$counter$ext"
                    $counter++
                }
            }
            Move-Item -LiteralPath $file.FullName -Destination $dest -Force -ErrorAction Stop
            $rescued++
        } catch {
            Write-Warning "POND_RESCUE_FAILED file=$($file.Name) error=$($_.Exception.Message)"
            $errors++
        }
    }

    return [pscustomobject]@{ Rescued = $rescued; Skipped = $skipped; Errors = $errors }
}
