[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$SourcePath = "$env:USERPROFILE\intersite-docs\Upscale Havens\Leases\Docusign",
    [string]$DestRoot = "$env:USERPROFILE\intersite-docs\Misc Agreements",
    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $SourcePath)) {
    Write-Warning "Source path not found: $SourcePath"
    return
}

$files = Get-ChildItem -LiteralPath $SourcePath -File -Filter "*.pdf"
if ($files.Count -eq 0) {
    Write-Host "No PDF files found in source path."
    return
}

Write-Host "Found $($files.Count) file(s) to migrate from: $SourcePath"
Write-Host ""

$results = @()

foreach ($file in $files) {
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
    $dateSigned = $file.LastWriteTime.ToString("yyyy-MM-dd")
    $signerName = "Unknown"
    $formName = "Signed Document"

    # Heuristic: filename format <title>_<id>_signed.pdf
    if ($baseName -match '^(.+?)_\d+_signed$') {
        $titlePart = $matches[1].Trim()
        $formName = $titlePart -replace '_', ' '
        # Try to extract signer name — look for common patterns
        if ($titlePart -match '(.+?)(?:[-–—]\s*(.+))') {
            $formName = $matches[1].Trim()
            $potentialSigner = $matches[2].Trim()
            if ($potentialSigner -match '^\w+ \w+') {
                $signerName = $potentialSigner
            }
        }
    } elseif ($baseName -match '^(.+?)_signed$') {
        $formName = ($matches[1].Trim()) -replace '_', ' '
    }

    $destFileName = "$dateSigned - $signerName - $formName.pdf"
    $destPath = Join-Path -Path $DestRoot -ChildPath $destFileName

    $srcHash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash

    if (Test-Path -LiteralPath $destPath) {
        $destHash = (Get-FileHash -LiteralPath $destPath -Algorithm SHA256).Hash
        if ($destHash -eq $srcHash) {
            Write-Host "[SKIP] $($file.Name) — already exists at destination (identical)"
            $results += [PSCustomObject]@{
                Source      = $file.Name
                Destination = $destFileName
                Status      = "Skipped (identical)"
                SHA256      = $srcHash
            }
            continue
        } else {
            Write-Warning "[CONFLICT] $($file.Name) — destination exists but has different content"
            $results += [PSCustomObject]@{
                Source      = $file.Name
                Destination = $destFileName
                Status      = "Conflict"
                SHA256      = $srcHash
            }
            continue
        }
    }

    $null = New-Item -ItemType Directory -Path $DestRoot -Force
    if ($PSCmdlet.ShouldProcess("$($file.Name) → $destFileName", "Copy file")) {
        Copy-Item -LiteralPath $file.FullName -Destination $destPath -Force
        $destHash = (Get-FileHash -LiteralPath $destPath -Algorithm SHA256).Hash
        if ($destHash -eq $srcHash) {
            Write-Host "[COPY] $($file.Name) → $destFileName (verified)"
            $results += [PSCustomObject]@{
                Source      = $file.Name
                Destination = $destFileName
                Status      = "Copied"
                SHA256      = $srcHash
            }
        } else {
            Write-Error "[FAIL] $($file.Name) — hash mismatch after copy!"
            $results += [PSCustomObject]@{
                Source      = $file.Name
                Destination = $destFileName
                Status      = "HashMismatch"
                SHA256      = $srcHash
            }
        }
    } else {
        Write-Host "[WHATIF] Would copy $($file.Name) → $destFileName"
        $results += [PSCustomObject]@{
            Source      = $file.Name
            Destination = $destFileName
            Status      = "WhatIf"
            SHA256      = $srcHash
        }
    }
}

Write-Host ""
Write-Host "=== Migration Summary ==="
$results | Format-Table -AutoSize
Write-Host ""

$copied = @($results | Where-Object { $_.Status -eq "Copied" })
$skipped = @($results | Where-Object { $_.Status -eq "Skipped (identical)" })
$conflicts = @($results | Where-Object { $_.Status -eq "Conflict" })
$whatif = @($results | Where-Object { $_.Status -eq "WhatIf" })

Write-Host "Copied: $($copied.Count) | Skipped: $($skipped.Count) | Conflicts: $($conflicts.Count) | WhatIf: $($whatif.Count)"
if ($conflicts.Count -gt 0) {
    Write-Warning "Resolve $($conflicts.Count) conflict(s) before removing originals."
}
if ($copied.Count -gt 0 -or $skipped.Count -gt 0) {
    Write-Host "After verification, originals can be removed from: $SourcePath"
}
