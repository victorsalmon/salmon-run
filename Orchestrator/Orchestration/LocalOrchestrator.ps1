#Requires -Version 7.0
# Thin wrapper to the canonical LocalOrchestrator entry point in Skills/Orchestrator.
# Kept at Orchestrator/Orchestration so recovery preflight and legacy launchers can resolve it.

$repoRoot = (Get-Item $PSCommandPath).Directory.Parent.Parent.FullName
$canonical = Join-Path $repoRoot 'Skills\Orchestrator\LocalOrchestrator.ps1'
if (-not (Test-Path -LiteralPath $canonical -PathType Leaf)) {
    throw "LocalOrchestrator canonical path not found: $canonical"
}
. $canonical
