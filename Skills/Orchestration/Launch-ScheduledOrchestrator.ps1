Set-Location -LiteralPath "C:\Users\Victor\intersite-orchestrator"
$env:OC_ORCHESTRATOR_BACKGROUND = '1'
& "C:\Users\Victor\intersite-orchestrator\Skills\\Orchestration\LocalOrchestrator.ps1" -Detach -NoAuditPrompt -MaxIterations 50 -SubprocessTimeoutMinutes 120
