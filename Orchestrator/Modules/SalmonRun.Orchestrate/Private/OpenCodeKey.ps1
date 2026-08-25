$script:OpenCodeKeyActiveFile = Join-Path $script:RepoRoot 'Tasks\Logs\.opencode-go-key-active.json'
$script:OpenCodeKeyExhaustedFile = Join-Path $script:RepoRoot 'Tasks\Logs\.opencode-go-key-exhausted.json'

function Get-OpenCodeGoApiKey {
    param([string]$RepoDir = $script:RepoRoot)

    if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
        Write-Warning 'aws CLI not found; keeping existing OPENCODE_GO_KEY if set'
        return
    }

    $exhausted = @()
    if (Test-Path $script:OpenCodeKeyExhaustedFile) {
        $exhausted = (Get-Content $script:OpenCodeKeyExhaustedFile -Raw | ConvertFrom-Json)
        if ($exhausted -isnot [array]) { $exhausted = @($exhausted) }
    }

    $n = 1
    while ($n -le 100) {
        $onName = "OPENCODE_GO${n}_ON"
        $on = (aws secretsmanager get-secret-value --profile salmon-orch --region ca-central-1 --secret-id $onName --query SecretString --output text) 2>$null
        if ($LASTEXITCODE -ne 0) { break }

        $isActive = $on -eq 'true'
        if (-not $isActive -and $on -ne 'false') {
            $expires = $null
            if ([datetime]::TryParse($on, [ref]$expires)) {
                $isActive = $expires.Date -ge (Get-Date).Date
            }
        }

        if ($isActive -and $onName -notin $exhausted) {
            $keyName = "OPENCODE_GO${n}_KEY"
            $key = (aws secretsmanager get-secret-value --profile salmon-orch --region ca-central-1 --secret-id $keyName --query SecretString --output text) 2>$null
            if ($LASTEXITCODE -eq 0) {
                $env:OPENCODE_GO_KEY = $key
                $onName | ConvertTo-Json | Set-Content $script:OpenCodeKeyActiveFile -Encoding utf8 -NoNewline
                return
            }
        }
        $n++
    }

    if (-not $env:OPENCODE_GO_KEY) {
        $userKey = [Environment]::GetEnvironmentVariable('OPENCODE_GO_KEY', 'User')
        $machineKey = [Environment]::GetEnvironmentVariable('OPENCODE_GO_KEY', 'Machine')
        if ($userKey) {
            $env:OPENCODE_GO_KEY = $userKey
            Write-Warning 'No active OPENCODE_GO key found in AWS SM; using OPENCODE_GO_KEY from User environment'
        } elseif ($machineKey) {
            $env:OPENCODE_GO_KEY = $machineKey
            Write-Warning 'No active OPENCODE_GO key found in AWS SM; using OPENCODE_GO_KEY from Machine environment'
        } else {
            Write-Warning 'No active OPENCODE_GO key found in AWS SM and no OPENCODE_GO_KEY env var is set'
        }
    } else {
        Write-Warning 'No active OPENCODE_GO key found in AWS SM; keeping existing OPENCODE_GO_KEY env var'
    }
}

function Switch-OpenCodeGoApiKey {
    param([string]$RepoDir = $script:RepoRoot)

    $active = $null
    if (Test-Path $script:OpenCodeKeyActiveFile) {
        $active = (Get-Content $script:OpenCodeKeyActiveFile -Raw | ConvertFrom-Json)
    }

    $exhausted = @()
    if (Test-Path $script:OpenCodeKeyExhaustedFile) {
        $exhausted = (Get-Content $script:OpenCodeKeyExhaustedFile -Raw | ConvertFrom-Json)
        if ($exhausted -isnot [array]) { $exhausted = @($exhausted) }
    }

    if ($active -and $active -notin $exhausted) {
        $exhausted += $active
    }
    $exhausted | ConvertTo-Json | Set-Content $script:OpenCodeKeyExhaustedFile -Encoding utf8 -NoNewline
    Get-OpenCodeGoApiKey -RepoDir $RepoDir
}

function Test-OpenCodeKeyExhausted {
    param([string]$StreamId, [string]$RepoDir = $script:RepoRoot)

    $patterns = @('rate limit', 'quota', 'exceeded', 'insufficient', 'Usage limit')
    $opencodeLog = "$env:USERPROFILE\.local\share\opencode\log\opencode.log"
    $checks = @($opencodeLog)
    if ($StreamId) {
        $checks += (Join-Path $RepoDir "Tasks/Logs/agents/$StreamId.stderr")
        $checks += (Join-Path $RepoDir "Tasks/Logs/agents/$StreamId.stdout")
    }

    foreach ($path in $checks) {
        if (-not (Test-Path $path)) { continue }
        $tail = Get-Content $path -Tail 30 -ErrorAction SilentlyContinue | Out-String
        foreach ($p in $patterns) {
            if ($tail -match $p) { return $true }
        }
    }
    return $false
}
