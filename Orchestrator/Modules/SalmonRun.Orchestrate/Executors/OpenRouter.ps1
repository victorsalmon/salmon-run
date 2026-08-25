# Executors/OpenRouter.ps1
# Placeholder for an OpenRouter provider. The harness-defaults.json already
# reserves the provider/model mapping; this file prevents a missing-executor
# load error and gives a clear message until the executor is implemented.

function Initialize-Executor {
    throw "OpenRouter executor is not yet implemented. Use -Harness opencode -Provider opencode-go or -Harness devin."
}

function Test-ExecutorPreflight { param([string]$AgentPath); return $true }
function Start-StreamCoder { throw "OpenRouter executor is not yet implemented." }
function New-ExecutorTask { return $null }
function Stop-ExecutorTask { param($Task) }
function Get-ExecutorTaskStatus { param($Task) }
function Clear-AgentArtifacts { param([string]$AgentId, [string]$RepoDir) }
function Invoke-ExecutorMerge { throw "OpenRouter merge is not yet implemented." }
