<#
.SYNOPSIS
    Move receipt files from old 3-directory layout to the new unified structure.
.DESCRIPTION
    Reads _manifest.csv and moves each tracked file to its new location based on
    account + status. Also moves any untracked files in the old locations to
    _orphans/. Renames old directories to .legacy as a safety net.
.PARAMETER ReceiptsBase
    Base path for receipts. Default: $env:USERPROFILE\intersite-docs\Taxes and Bookkeeping
.PARAMETER Entity
    Entity name (currently only intersite-consulting is supported).
.PARAMETER ManifestPath
    Path to _manifest.csv. Default: <ReceiptsBase>\<Entity>\2026 Filing\Receipts\_manifest.csv
.PARAMETER DryRun
    Print what would be done without making changes.
.PARAMETER SkipLegacy
    Do not rename old directories to .legacy. Useful for repeated dry-runs.
.EXAMPLE
    .\Move-ReceiptFiles.ps1 -Entity intersite-consulting -DryRun
#>
[CmdletBinding()]
param(
    [string]$ReceiptsBase = "$env:USERPROFILE\intersite-docs\Taxes and Bookkeeping",
    [Parameter(Mandatory)]
    [ValidateSet("intersite-consulting")]
    [string]$Entity,
    [string]$ManifestPath,
    [switch]$DryRun,
    [switch]$SkipLegacy
)

$ErrorActionPreference = "Stop"

$EntityDir = Join-Path $ReceiptsBase $Entity
$ReceiptDir = Join-Path $EntityDir "2026 Filing" "Receipts"
if (-not (Test-Path $ReceiptDir)) { Write-Error "Receipt dir not found: $ReceiptDir"; exit 1 }

if (-not $ManifestPath) {
    $ManifestPath = Join-Path $ReceiptDir "_manifest.csv"
}
if (-not (Test-Path $ManifestPath)) { Write-Error "Manifest not found: $ManifestPath (run Merge-ReceiptManifests.ps1 first)"; exit 1 }

$raw = Get-Content $ManifestPath -Raw -Encoding UTF8
$bom = [char]0xFEFF
if ($raw.Length -gt 0 -and $raw[0] -eq $bom) { $raw = $raw.Substring(1) }
$manifest = $raw | ConvertFrom-Csv
Write-Host "Loaded $($manifest.Count) manifest entries"

# Old layout subdirs we want to scan and drain
$oldSubdirs = @(
    "rbc-6258"
    "rbc-6258-ingest"
    "rbc-intersite"
)

# New layout target dirs
$newDirs = @{
    "intersite-mc-6258"     = Join-Path $ReceiptDir "intersite-mc-6258"
    "intersite-rbc-chequing" = Join-Path $ReceiptDir "intersite-rbc-chequing"
    "_orphans"              = Join-Path $ReceiptDir "_orphans"
    "_zoho-only"            = Join-Path $ReceiptDir "_zoho-only"
}

# Build lookup: filename -> manifest row
$byFilename = @{}
foreach ($r in $manifest) {
    $byFilename[$r.filename] = $r
}

function Resolve-TargetDir {
    param($Row)
    if (-not $Row) { return $newDirs["_orphans"] }
    $account = $Row.account
    $status = $Row.status
    if ($status -in @("matched","uploaded","promoted")) {
        if ($newDirs.ContainsKey($account)) { return $newDirs[$account] }
    }
    return $newDirs["_orphans"]
}

# --- Phase 1: move manifest-tracked files ---
$moved = 0
$alreadyInPlace = 0
$notFound = 0
$errors = 0

foreach ($r in $manifest) {
    $filename = $r.filename
    $targetDir = Resolve-TargetDir -Row $r
    $targetPath = Join-Path $targetDir $filename

    # Already in place?
    if (Test-Path $targetPath) {
        $alreadyInPlace++
        continue
    }

    # Search for source in old locations
    $sourcePath = $null
    $candidates = @()
    foreach ($sd in $oldSubdirs) {
        $candidates += Join-Path $ReceiptDir $sd $filename
        # also check subdirs of rbc-6258 (non-matching, _unknown)
        $rbc6258 = Join-Path $ReceiptDir $sd
        if (Test-Path $rbc6258) {
            Get-ChildItem -Path $rbc6258 -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                $candidates += Join-Path $_.FullName $filename
            }
        }
    }
    $candidates += Join-Path $ReceiptDir $filename
    foreach ($c in $candidates) { if (Test-Path $c) { $sourcePath = $c; break } }

    if (-not $sourcePath) {
        $notFound++
        continue
    }

    if ($DryRun) {
        Write-Host "  [DRY] $sourcePath -> $targetPath"
    } else {
        try {
            $null = New-Item -ItemType Directory -Path $targetDir -Force
            Move-Item -LiteralPath $sourcePath -Destination $targetPath -Force
            $moved++
        } catch {
            Write-Host "  [ERR] $filename : $_" -ForegroundColor Red
            $errors++
        }
    }
}

Write-Host "`nManifest-tracked files:"
Write-Host "  Moved:          $moved"
Write-Host "  Already in new: $alreadyInPlace"
Write-Host "  Not found:      $notFound"
Write-Host "  Errors:         $errors"

# --- Phase 2: collect untracked files from old locations ---
$untrackedMoved = 0
$untrackedErrors = 0
$untrackedSkipped = 0
$untrackedInManifest = 0

foreach ($sd in $oldSubdirs) {
    $oldDir = Join-Path $ReceiptDir $sd
    if (-not (Test-Path $oldDir)) { continue }
    $files = Get-ChildItem -Path $oldDir -Recurse -File -ErrorAction SilentlyContinue
    foreach ($f in $files) {
        if ($byFilename.ContainsKey($f.Name)) {
            # Manifest has a row for this filename. Phase 1 should have moved it.
            # In dry-run, Phase 1 didn't actually move, so the file is still here.
            # In real run, if it's still here, that's a bug to investigate.
            if ($DryRun) {
                $untrackedInManifest++
            } else {
                $untrackedSkipped++
            }
            continue
        }
        $targetDir = $newDirs["_orphans"]
        $targetPath = Join-Path $targetDir $f.Name
        # Avoid name collisions in _orphans by prefixing with subdir
        if (Test-Path $targetPath) {
            $targetPath = Join-Path $targetDir ("$sd~$($f.Name)")
        }
        if ($DryRun) {
            Write-Host "  [DRY-UNTRACKED] $($f.FullName) -> $targetPath"
        } else {
            try {
                $null = New-Item -ItemType Directory -Path $targetDir -Force
                Move-Item -LiteralPath $f.FullName -Destination $targetPath -Force
                $untrackedMoved++
            } catch {
                Write-Host "  [ERR-UNTRACKED] $($f.Name) : $_" -ForegroundColor Red
                $untrackedErrors++
            }
        }
    }
}

Write-Host "`nUntracked files (not in manifest):"
Write-Host "  Moved to _orphans: $untrackedMoved"
Write-Host "  Skipped (manifest collisions, would be handled in real run): $untrackedSkipped"
Write-Host "  Errors:            $untrackedErrors"

# --- Phase 3: rename old directories to .legacy ---
if (-not $SkipLegacy -and -not $DryRun) {
    foreach ($sd in $oldSubdirs) {
        $oldDir = Join-Path $ReceiptDir $sd
        $legacyDir = Join-Path $ReceiptDir "$sd.legacy"
        if (Test-Path $oldDir) {
            # Only rename if directory is now empty (or near-empty)
            $remaining = @(Get-ChildItem -Path $oldDir -Recurse -File -ErrorAction SilentlyContinue)
            if ($remaining.Count -eq 0) {
                Remove-Item -LiteralPath $oldDir -Recurse -Force -ErrorAction SilentlyContinue
                Write-Host "  Removed empty old dir: $sd"
            } else {
                Rename-Item -LiteralPath $oldDir -NewName "$sd.legacy" -Force -ErrorAction SilentlyContinue
                Write-Host "  Renamed: $sd -> $sd.legacy (had $remaining.Count files remaining)"
            }
        }
    }
} elseif ($DryRun) {
    foreach ($sd in $oldSubdirs) {
        $oldDir = Join-Path $ReceiptDir $sd
        if (Test-Path $oldDir) {
            $remaining = @(Get-ChildItem -Path $oldDir -Recurse -File -ErrorAction SilentlyContinue)
            Write-Host "  [DRY-LEGACY] $sd -> $sd.legacy ($($remaining.Count) files would remain)"
        }
    }
}

# --- Final summary ---
$sep = "=" * 60
$dryTag = if ($DryRun) { "(DRY RUN) " } else { "" }
Write-Host ""
Write-Host $sep
Write-Host "Migration ${dryTag}complete for $Entity" -ForegroundColor Cyan
Write-Host "  Manifest-tracked moved:     $moved"
Write-Host "  Untracked moved to _orphans: $untrackedMoved"
Write-Host "  Already in place:           $alreadyInPlace"
Write-Host "  Not found in old locations: $notFound"
Write-Host "  Errors:                     $($errors + $untrackedErrors)"
Write-Host $sep
