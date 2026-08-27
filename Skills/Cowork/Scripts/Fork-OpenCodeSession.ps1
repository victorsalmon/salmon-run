# Used by: manual fallback when /fork command fails in Opencode TUI
function Fork-OpenCodeSession {
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Goal,
        [Parameter(Mandatory = $false)]
        [switch]$StubOnly
    )

    $repoRoot = Resolve-Path -LiteralPath "$PSScriptRoot\..\..\.." -ErrorAction Stop
    $scriptPath = Join-Path -Path $repoRoot -ChildPath "Skills/Cowork/Scripts/Fork-Session.ps1"

    if (-not (Test-Path -LiteralPath $scriptPath)) {
        throw "Fork-Session.ps1 not found at $scriptPath"
    }

    $extra = if ($StubOnly) { "-StubOnly" } else { "" }
    $params = @{
        FilePath = "powershell"
        ArgumentList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $scriptPath, "-Goal", $Goal) + @($extra)
        WindowStyle = "Normal"
        PassThru = $true
    }
    Write-Host "Running: powershell -NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -Goal `"$Goal`" $extra"
    $proc = Start-Process @params
}

# Usage:
# . Skills/Cowork/Scripts/Fork-OpenCodeSession.ps1
# Fork-OpenCodeSession -Goal "fix the build"
# Fork-OpenCodeSession -Goal "fix the build" -StubOnly
