# Used by: workflow-primitives.md (context-gated exit) -- spawns a fresh opencode TUI
# with no context and a mode-specific drain-queue prompt.
function Invoke-FreshModeSession {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('code', 'review')]
        [string]$Mode,

        [Parameter(Mandatory = $false)]
        [switch]$DryRun
    )

    $repoRoot = Resolve-Path -LiteralPath "$PSScriptRoot\..\..\..\..\.." -ErrorAction Stop
    $modeLabel = if ($Mode -eq 'code') { 'Code' } else { 'Review' }
    $promptMsg = "$modeLabel Mode and drain queue"

    if ($DryRun) {
        Write-Host "[fresh-mode] Would launch: start pwsh -NoProfile -Command 'opencode --prompt ""$promptMsg""'"
        Write-Host "[fresh-mode] Mode: $Mode"
        Write-Host "[fresh-mode] CWD: $repoRoot"
        return
    }

    $escapedPrompt = $promptMsg -replace "'", "''"

    Write-Host "[fresh-mode] Launching new $Mode-mode opencode session..."
    Write-Host "[fresh-mode] CWD: $repoRoot"
    Write-Host "[fresh-mode] Command: opencode --prompt '<prompt>'"

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "pwsh"
    $psi.Arguments = "-NoProfile -Command opencode --prompt '$escapedPrompt'"
    $psi.WorkingDirectory = $repoRoot
    $psi.UseShellExecute = $true
    $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Normal

    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        Write-Host "[fresh-mode] New $Mode-mode TUI launched (PID: $($proc.Id))."
    } catch {
        Write-Error "[fresh-mode] Failed to launch new TUI: $_"
        Write-Host "[fresh-mode] Fallback -- launch manually: cd '$repoRoot' && opencode --prompt '$escapedPrompt'"
    }
}
