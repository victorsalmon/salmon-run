# Used by: Skills/Cowork/fork.md (via Invoke-ForkFlow.ps1)
function Invoke-Fork {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StubPath,
        [Parameter(Mandatory = $true)]
        [string]$Goal,
        [Parameter(Mandatory = $false)]
        [switch]$DryRun,
        [Parameter(Mandatory = $false)]
        [switch]$StubOnly
    )

    if (-not $DryRun -and -not (Test-Path -LiteralPath $StubPath)) {
        throw "Fork-Stub not found at '$StubPath'"
    }

    $repoRoot = Resolve-Path -LiteralPath "$PSScriptRoot\..\..\.." -ErrorAction Stop
    $resolvedStub = Resolve-Path -LiteralPath $StubPath -ErrorAction Stop
    $promptMsg = "Forked for: $Goal. Read the Fork-Stub at $resolvedStub, then compress away everything not relevant to this goal. Proceed."

    if ($DryRun) {
        Write-Host "[fork] Would launch: start pwsh -NoProfile -Command 'opencode --continue --fork --prompt ""$promptMsg""'"
        Write-Host "[fork] Prompt message: $promptMsg"
        return $StubPath
    }

    if ($StubOnly) {
        $msg = "[fork] Fork-Stub written at $resolvedStub. No terminal launched -- launch later with: Invoke-Fork -StubPath '$resolvedStub' -Goal '$Goal'"
        Write-Host $msg
        return $StubPath
    }

    # Escape single quotes in the prompt message for the command line
    $escapedPrompt = $promptMsg -replace "'", "''"

    Write-Host "[fork] Launching new terminal window with opencode --continue --fork..."
    Write-Host "[fork] CWD: $repoRoot"
    Write-Host "[fork] Command: opencode --continue --fork --prompt '<prompt>'"

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "pwsh"
    $psi.Arguments = "-NoProfile -Command opencode --continue --fork --prompt '$escapedPrompt'"
    $psi.WorkingDirectory = $repoRoot
    $psi.UseShellExecute = $true
    $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Normal

    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        Write-Host "[fork] New terminal launched (PID: $($proc.Id)). Stub at $resolvedStub."
    } catch {
        Write-Error "[fork] Failed to launch new terminal: $_"
        Write-Host "[fork] Fallback: Fork-Stub written at $resolvedStub. Launch manually:"
        Write-Host "  cd '$repoRoot' && opencode --continue --fork --prompt '$escapedPrompt'"
    }

    return $StubPath
}
