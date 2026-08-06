function ConvertTo-LockHeader {
    param(
        [string]$AgentId,
        [string]$Status,
        [string]$ExistingContent,
        [string]$ReleaseTimestamp
    )
    if (-not $ReleaseTimestamp -and $Status -eq 'released') {
        $ReleaseTimestamp = [datetime]::UtcNow.ToString('o')
    }
    $now = [datetime]::UtcNow.ToString('o')
    if ([string]::IsNullOrWhiteSpace($AgentId)) {
        throw "AgentId cannot be empty — a Lock Header with a blank Agent: is invalid."
    }
    $newBlock = @"
- Agent: $AgentId
- Locked: $now
- Status: $Status
"@
    if ($Status -eq 'released') {
        $newBlock += "`n- Released: $ReleaseTimestamp"
    }
    if ($ExistingContent -match '(?ms)^\*\*Lock\*\*') {
        if ($ExistingContent -match '(?ms)^---$') {
            $lastSep = $ExistingContent.LastIndexOf('---')
            $before = $ExistingContent.Substring(0, $lastSep)
            return $before + "---`n" + $newBlock + "`n" + $ExistingContent.Substring($lastSep + 3)
        }
        return $ExistingContent + "`n---`n" + $newBlock
    }
    # No existing lock header — prepend the block but ALWAYS preserve the body.
    # Dropping $ExistingContent here produced header-only stubs (plan body lost).
    return "`n**Lock**`n" + $newBlock + "`n" + $ExistingContent
}
$AgentId = $null; $Status = $null; $ExistingContent = $null; $ReleaseTimestamp = $null
$DryRun = $false; $OutputPath = $null
if ($args.Count -ge 2) { $AgentId = $args[0]; $Status = $args[1] }
for ($i = 2; $i -lt $args.Count; $i++) {
    switch -Wildcard ($args[$i]) {
        '-ExistingContent' { $ExistingContent = $args[++$i] }
        '-ReleaseTimestamp' { $ReleaseTimestamp = $args[++$i] }
        '-DryRun' { $DryRun = $true }
        '-OutputPath' { $OutputPath = $args[++$i] }
    }
}
if (-not $Status) { Write-Error "Status is required"; exit 1 }
$result = ConvertTo-LockHeader -AgentId $AgentId -Status $Status -ExistingContent $ExistingContent -ReleaseTimestamp $ReleaseTimestamp
if ($DryRun) { Write-Output $result }
elseif ($OutputPath) {
    # Atomic write contract (see workflow-primitives.md § Lock Header Format):
    # temp-write + Move-Item (atomic on same volume), then verify the original
    # plan body survived. A header-only file is a bug, not a valid lock state.
    if (-not (Test-Path $OutputPath)) { Write-Error "Source file missing: $OutputPath"; exit 2 }
    $src = Get-Content $OutputPath -Raw -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($src)) { Write-Error "Source file empty or unreadable: $OutputPath"; exit 2 }
    if ([string]::IsNullOrWhiteSpace($ExistingContent)) { Write-Error "Existing content missing for $OutputPath"; exit 2 }
    $tempPath = "$OutputPath.tmp.$PID"
    $result | Set-Content -Path $tempPath -NoNewline -Encoding utf8
    Move-Item -LiteralPath $tempPath -Destination $OutputPath -Force
    $written = Get-Content $OutputPath -Raw -ErrorAction SilentlyContinue
    $bodySurvived = $false
    if ($written) {
        if ($ExistingContent) {
            $bodySurvived = $written.Length -ge $ExistingContent.Length -and $written -match '# Session Plan:'
        } else {
            $bodySurvived = $written -match '# Session Plan:'
        }
    }
    if (-not $bodySurvived) {
        Write-Host "LOCK_WRITE_TRUNCATION path='$OutputPath' len=$($written.Length) originalLen=$($ExistingContent.Length) — restoring from git" -ForegroundColor Red
        try {
            $relSpec = try { [System.IO.Path]::GetRelativePath((Get-Location).Path, $OutputPath) } catch { $OutputPath }
            $restored = git show "HEAD:$relSpec" 2>$null
            if (-not $restored) { $restored = git show "HEAD:$OutputPath" 2>$null }
            if (-not $restored) {
                # History fallback: the tracked copy may have been moved or displaced by a
                # concurrent safe-pull — search all refs before giving up (orchestrator-tooling-2).
                $candidate = git log --all --format='%H' -1 -- "$relSpec" 2>$null
                if (-not $candidate) { $candidate = git log --all --format='%H' -1 -- "$OutputPath" 2>$null }
                if ($candidate) { $restored = git show "$candidate`:$relSpec" 2>$null }
            }
            if ($restored) {
                $restored | Set-Content -Path $OutputPath -NoNewline -Encoding utf8
                Write-Host "LOCK_WRITE_RESTORED path='$OutputPath' from git HEAD" -ForegroundColor Yellow
            } else {
                # No canonical blob exists anywhere in history — a header-only file is worse
                # than no file (it can be committed by a concurrent safe-pull checkpoint).
                Write-Host "LOCK_WRITE_UNRESTORABLE path='$OutputPath' — deleting truncated file and aborting lock" -ForegroundColor Red
                Remove-Item -LiteralPath $OutputPath -Force -ErrorAction SilentlyContinue
            }
        } catch { }
        exit 3
    }
}
else { Write-Error "Specify -OutputPath or use -DryRun"; exit 1 }
exit 0