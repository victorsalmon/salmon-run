function Add-PondSyncRequest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TaskRoot,[Parameter(Mandatory)][string]$RepoPath,[Parameter(Mandatory)][string]$CommitSha)
    $key = Get-PondRepositoryKey -RepoPath $RepoPath
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($key))).ToLowerInvariant()
    $dir = Join-Path (Split-Path $TaskRoot -Parent) 'SyncOutbox'
    $null = New-Item $dir -ItemType Directory -Force
    $branch = (& git -C $RepoPath rev-parse --abbrev-ref HEAD 2>$null) -as [string]
    $path = Join-Path $dir "$hash.json"
    $existing = if (Test-Path $path) { Get-Content $path -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue } else { $null }
    $request = [ordered]@{
        repositoryKey=$key; repoPath=[IO.Path]::GetFullPath($RepoPath); branch=$branch.Trim(); commitSha=$CommitSha.Trim()
        attempts=if($existing){[int]$existing.attempts}else{0}; lastError=if($existing){$existing.lastError}else{''}
        nextAttemptAt=if($existing){$existing.nextAttemptAt}else{[datetimeoffset]::UtcNow.ToString('o')}; queuedAt=[datetimeoffset]::UtcNow.ToString('o')
    }
    $temp="$path.tmp-$PID"; $request | ConvertTo-Json | Set-Content $temp -Encoding utf8 -NoNewline; Move-Item $temp $path -Force
    return $path
}

function Invoke-PondSyncOutbox {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TaskRoot,[int]$MaxFailures=3,[int]$AheadThreshold=100)
    $dir=Join-Path (Split-Path $TaskRoot -Parent) 'SyncOutbox'
    $result=[ordered]@{Processed=0;Succeeded=0;Failed=0;Backlog=0;CircuitOpen=$false;Reasons=@()}
    if(-not(Test-Path $dir)){return [pscustomobject]$result}
    $files=@(Get-ChildItem $dir -Filter '*.json' -File)
    $result.Backlog=$files.Count
    foreach($file in $files | Sort-Object Name){
        $request=Get-Content $file.FullName -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue
        if(-not $request){$result.Failed++;$result.CircuitOpen=$true;$result.Reasons+='malformed-request';continue}
        $next=[datetimeoffset]::MinValue
        if(-not [datetimeoffset]::TryParse([string]$request.nextAttemptAt,[ref]$next)){$next=[datetimeoffset]::MinValue}
        if($next -gt [datetimeoffset]::UtcNow){if([int]$request.attempts -ge $MaxFailures){$result.CircuitOpen=$true};continue}
        $repo=[string]$request.repoPath; $branch=[string]$request.branch; $errorText=''
        try {
            if(-not(Test-Path $repo)){throw 'repository-missing'}
            $dirty=@(& git -C $repo status --porcelain 2>$null)
            if($LASTEXITCODE -ne 0){throw 'status-failed'}
            if($dirty.Count -gt 0){throw 'working-tree-dirty'}
            $aheadText=(& git -C $repo rev-list --count "origin/$branch..HEAD" 2>$null) -as [string]
            $ahead=0; [void][int]::TryParse($aheadText.Trim(),[ref]$ahead)
            if($ahead -gt $AheadThreshold){throw "ahead-threshold:$ahead"}
            & git -C $repo fetch origin $branch 2>&1 | Out-Null
            if($LASTEXITCODE -ne 0){throw 'fetch-failed'}
            & git -C $repo merge-base --is-ancestor "origin/$branch" HEAD 2>$null
            if($LASTEXITCODE -ne 0){
                & git -C $repo merge-base --is-ancestor HEAD "origin/$branch" 2>$null
                if($LASTEXITCODE -eq 0){& git -C $repo merge --ff-only "origin/$branch" 2>&1 | Out-Null; if($LASTEXITCODE -ne 0){throw 'fast-forward-failed'}}
                else{throw 'remote-divergence'}
            }
            & git -C $repo push origin $branch 2>&1 | Out-Null
            if($LASTEXITCODE -ne 0){throw 'push-failed'}
            Remove-Item $file.FullName -Force
            $result.Processed++;$result.Succeeded++;$result.Backlog--
        } catch {
            $errorText=$_.Exception.Message; $request.attempts=[int]$request.attempts+1; $request.lastError=$errorText
            $delay=[math]::Min(1800,[math]::Pow(2,[int]$request.attempts)*30)
            $request.nextAttemptAt=[datetimeoffset]::UtcNow.AddSeconds($delay).ToString('o')
            $request | ConvertTo-Json | Set-Content $file.FullName -Encoding utf8 -NoNewline
            $result.Processed++;$result.Failed++;$result.Reasons+=$errorText
            if([int]$request.attempts -ge $MaxFailures -or $errorText -like 'ahead-threshold:*' -or $errorText -eq 'remote-divergence'){$result.CircuitOpen=$true}
        }
    }
    return [pscustomobject]$result
}