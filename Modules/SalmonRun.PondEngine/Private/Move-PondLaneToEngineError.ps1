function Move-PondLaneToEngineError {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$LanePath,
        [Parameter(Mandatory)][string]$TaskRoot,
        [Parameter(Mandatory)][string]$PondName,
        [Parameter(Mandatory)][string]$Reason
    )

    $pausedDir = Join-Path $TaskRoot 'Paused'
    $null = New-Item -ItemType Directory -Path $pausedDir -Force
    $moved = [System.Collections.Generic.List[string]]::new()
    foreach ($file in @(Get-ChildItem -LiteralPath $LanePath -Filter '*.md' -File -ErrorAction SilentlyContinue)) {
        $content = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction SilentlyContinue
        if ($content -match '(?im)^\*\*Status\*\*:\s*[^\r\n]+') {
            $content = $content -replace '(?im)^\*\*Status\*\*:\s*[^\r\n]+', '**Status**: engine-error'
        } else {
            $content = $content.TrimEnd() + "`n`n**Status**: engine-error"
        }
        foreach ($header in @{
            FailureType='engine-error'
            Blocked='true'
            BlockedBy='PondEngine'
            BlockedReason=$Reason
        }.GetEnumerator()) {
            $escaped = [regex]::Escape([string]$header.Key)
            if ($content -match "(?im)^\*\*$escaped\*\*:\s*[^\r\n]+") {
                $content = $content -replace "(?im)^\*\*$escaped\*\*:\s*[^\r\n]+", "**$($header.Key)**: $($header.Value)"
            } else {
                $content = $content.TrimEnd() + "`n**$($header.Key)**: $($header.Value)"
            }
        }
        Set-Content -LiteralPath $file.FullName -Value $content -Encoding utf8 -NoNewline
        $dest = Join-Path $pausedDir $file.Name
        $counter = 1
        while (Test-Path -LiteralPath $dest) {
            $dest = Join-Path $pausedDir "$($file.BaseName)-engine-error-$counter$($file.Extension)"
            $counter++
        }
        $saved = $false
        for ($i = 0; $i -lt 3; $i++) {
            try {
                if ($i -gt 0) { Start-Sleep -Seconds 1 }
                Move-Item -LiteralPath $file.FullName -Destination $dest -Force -ErrorAction Stop
                $saved = $true
                break
            } catch {
                # If the file is still locked by a child process, copy the contents
                # and leave the original for the caller to clean up.
                if ($i -eq 2) {
                    Copy-Item -LiteralPath $file.FullName -Destination $dest -Force -ErrorAction SilentlyContinue
                }
            }
        }
        if ($saved -or (Test-Path -LiteralPath $dest)) {
            $moved.Add($dest)
        }
    }
    return [pscustomobject]@{ Moved=$moved.Count; Files=$moved.ToArray(); Pond=$PondName; Reason=$Reason }
}