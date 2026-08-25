# SalmonRun.Orchestrate.psm1
# Dual-loader: dot-sources Private/*.ps1 before Public/*.ps1

#Requires -Version 7.0
Set-StrictMode -Off

$script:ModuleRoot = $PSScriptRoot
$script:RootResolverPath = Join-Path $PSScriptRoot '..\..\Orchestration\Resolve-OrchestratorRepoRoot.ps1'
if (-not (Test-Path -LiteralPath $script:RootResolverPath -PathType Leaf)) {
    throw "Orchestrator root resolver not found: $script:RootResolverPath"
}
. $script:RootResolverPath
$script:RepoRoot = Resolve-OrchestratorRepoRoot -StartPath $PSScriptRoot

# Dot-source Private scripts in dependency order (Logging, ExecutorContract first)
$script:PrivateOrder = @(
    'Logging.ps1',
    'ExecutorContract.ps1',
    'RetryBudget.ps1',
    'Orphan.ps1',
    'Capacity.ps1',
    'Connascence.ps1',
    'State.ps1',
    'Cleanup.ps1',
    'Process.ps1',
    'Queue.ps1',
    'Stream.ps1',
    'Container.ps1',
    'OpenCodeKey.ps1',
    'HarnessConfig.ps1',
    'ModelRouter.ps1',
    'DeepSeekCacheFilter.ps1'
)
foreach ($__f in $script:PrivateOrder) {
    $__path = Join-Path $PSScriptRoot "Private/$__f"
    if (Test-Path $__path) { . $__path }
}

# Dot-source Public scripts
foreach ($__f in Get-ChildItem (Join-Path $PSScriptRoot 'Public/*.ps1') -ErrorAction SilentlyContinue | Sort-Object Name) {
    . $__f.FullName
}

$script:ExecutorPath = Join-Path $PSScriptRoot "Executors"
