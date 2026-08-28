# Gates: scheduler parallelism and recovery

OWNS: Modules/SalmonRun.PondEngine/Private/Select-PondGroups.ps1, Modules/SalmonRun.PondEngine/Private/Get-PondCapacity.ps1, Modules/SalmonRun.PondEngine/Private/Invoke-PondRescue.ps1, Tests/SalmonRun.PondScheduling.Tests.ps1

Scope: respect global pond concurrency, prevent simultaneous writers to one repository, and recover orphaned work and stale locks safely

- [ ] SR1: selection never exceeds configured parallelism and never selects two write groups for the same repository
  CHECK: pwsh -NoProfile -File Tools/QA/Invoke-OrchestratorAcceptance.ps1 -Mode Parallelism
  EXPECT: PARALLELISM_OK
  EVIDENCE: pending

- [ ] SR2: orphaned working plans return to their source queue and stale claims are removed while live claims remain untouched
  CHECK: pwsh -NoProfile -File Tools/QA/Invoke-OrchestratorAcceptance.ps1 -Mode Recovery
  EXPECT: RECOVERY_OK
  EVIDENCE: pending

