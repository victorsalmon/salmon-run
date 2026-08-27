#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

Describe 'Opencode session API contract audit' {
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $ps1Files = Get-ChildItem -Path $repoRoot -Recurse -Filter '*.ps1' -File |
        Where-Object { $_.FullName -notlike '*\Tests\*' -and $_.FullName -notlike '*\node_modules\*' -and $_.FullName -notlike '*\.aws-sam\*' }

    It 'No fabricated { task = ... } body is sent to POST /session' {
        $bad = @()
        foreach ($file in $ps1Files) {
            $content = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction SilentlyContinue
            if (-not $content) { continue }
            # Fabricated contract: POST /session with a body containing @{ task = $... }
            if ($content -match '(?i)/session' -and
                $content -match 'ConvertTo-Json' -and
                $content -match '(?m)\btask\s*=\s*\$') {
                $bad += $file.FullName
            }
        }
        $bad | Should -BeNullOrEmpty -Because "files sending `{ task = ... `} to /session violate the opencode API contract"
    }

    It 'No .sessionId is read from an opencode session response' {
        $bad = @()
        foreach ($file in $ps1Files) {
            $content = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction SilentlyContinue
            if (-not $content) { continue }
            # $lockData.sessionId and similar lock metadata are legitimate; anything else is suspect
            $matches = [regex]::Matches($content, '(?i)\$([A-Za-z0-9_]+)\.sessionId')
            foreach ($m in $matches) {
                $varName = $m.Groups[1].Value
                if ($varName -notin @('lockData')) {
                    $bad += "$($file.FullName): `$$varName.sessionId"
                }
            }
        }
        $bad | Should -BeNullOrEmpty -Because "opencode POST /session returns .id, not .sessionId"
    }

    It 'POST /session callers read .id, not .sessionId' {
        $bad = @()
        foreach ($file in $ps1Files) {
            $content = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction SilentlyContinue
            if (-not $content) { continue }
            if ($content -match '(?i)Invoke-RestMethod.*\/session' -and
                $content -match '(?i)\.sessionId' -and
                $content -notmatch '\$lockData\.sessionId') {
                $bad += $file.FullName
            }
        }
        $bad | Should -BeNullOrEmpty -Because "callers of POST /session should use .id"
    }
}
