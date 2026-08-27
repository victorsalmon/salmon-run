function Write-AlignmentAuditLog {
    param([string]$Domain,[string]$Action,[string]$Detail="",[string]$Severity="info")
    try {
        $TaskRoot = if (Get-Command Get-SalmonTaskRoot -ErrorAction SilentlyContinue) {
            Get-SalmonTaskRoot
        } else {
            Join-Path $HOME ".salmon" "Tasks"
        }
        $LogDir = Join-Path $TaskRoot "Logs"
        $Date = (Get-Date -Format 'yyyy-MM-dd')
        $LogPath = Join-Path $LogDir "alignment-audit-$Date.jsonl"
        $null = New-Item -ItemType Directory -Path $LogDir -Force
        $MutexName = "Global\SalmonRun-AlignmentAuditLog-Mutex-$Domain"
        $Mutex = $null
        try {
            $Mutex = New-Object System.Threading.Mutex($false, $MutexName)
            $acquired = $Mutex.WaitOne(5000)
            if (-not $acquired) { Write-Warning "Write-AlignmentAuditLog: mutex timeout (5s)" }

            $PrevHash = ""
            if (Test-Path $LogPath) {
                $LastLine = Get-Content $LogPath -Tail 1 -ErrorAction SilentlyContinue
                if ($LastLine) { $PrevEntry = $LastLine | ConvertFrom-Json; $PrevHash = $PrevEntry.hash }
            }
            $Sep = [char]0x1F
            $Data = "$Domain$Sep$Action$Sep$Detail$Sep$(Get-Date -Format 'o')"
            $HashInput = "$PrevHash$Sep$Data"
            $Hash = [System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($HashInput))).Replace("-","").ToLower()
            $Entry = [ordered]@{ts=(Get-Date -Format 'o');domain=$Domain;action=$Action;detail=$Detail;severity=$Severity;prev=$PrevHash;hash=$Hash}|ConvertTo-Json -Compress
            Add-Content -Path $LogPath -Value $Entry -Encoding UTF8NoBOM
        } finally {
            if ($Mutex) {
                try { $Mutex.ReleaseMutex() } catch { Write-Warning "Write-AlignmentAuditLog: mutex release failed: $_" }
                $Mutex.Dispose()
            }
        }
    } catch { Write-Warning "Write-AlignmentAuditLog failed: $_" }
}
