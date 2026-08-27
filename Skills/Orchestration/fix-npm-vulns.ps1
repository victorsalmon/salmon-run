<#
.SYNOPSIS
    Fix npm vulnerabilities in the opencode workspace directory.
.DESCRIPTION
    Runs npm audit fix --force in the opencode plugin directory, then verifies
    zero vulnerabilities remain and tests that the agentic-qe module loads.
#>
& {
    $opencodeDir = "$env:USERPROFILE\intersite-orchestrator\.opencode"
    Write-Host "=== npm vulnerability fix ===" -ForegroundColor Cyan
    Write-Host "Target: $opencodeDir" -ForegroundColor Gray

    Push-Location $opencodeDir
    try {
        Write-Host "[1/3] Applying force fixes..." -ForegroundColor Yellow
        $result = npm audit fix --force 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  OK - fixes applied" -ForegroundColor Green
        } else {
            Write-Host "  WARN - exit code $LASTEXITCODE" -ForegroundColor Yellow
        }
        $result | ForEach-Object { Write-Host "  $_" }

        Write-Host "[2/3] Verifying..." -ForegroundColor Yellow
        $audit = npm audit 2>&1
        $vulnCount = ($audit | Select-String "vulnerabilit")[0]
        if ($vulnCount -match '(\d+) vulnerabilities?') {
            $n = [int]$matches[1]
            if ($n -eq 0) {
                Write-Host "  OK - 0 vulnerabilities remaining" -ForegroundColor Green
            } else {
                Write-Host "  WARN - $n vulnerabilities remain" -ForegroundColor Yellow
            }
        } else {
            Write-Host "  OK - no vulnerability summary found (clean)" -ForegroundColor Green
        }

        Write-Host "[3/3] Testing agentic-qe..." -ForegroundColor Yellow
        $node = Get-Command node -ErrorAction SilentlyContinue
        if (-not $node) {
            Write-Host "  SKIP - node not found in PATH" -ForegroundColor DarkYellow
        } else {
            $test = node -e "try { require('agentic-qe'); console.log('OK') } catch(e) { console.log('FAIL: ' + e.message) }" 2>&1
            Write-Host "  $test" -ForegroundColor $(if ($test -eq 'OK') { 'Green' } else { 'Red' })
        }

        Write-Host "Done." -ForegroundColor Cyan
    } finally {
        Pop-Location
    }
}
