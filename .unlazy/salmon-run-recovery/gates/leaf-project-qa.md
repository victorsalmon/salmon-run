# Gates: project QA and completion lifecycle

OWNS: Modules/SalmonRun.PondEngine/Public/Get-SalmonRunPonds.ps1, Modules/SalmonRun.PondEngine/Private/PondTasks/Invoke-PondTaskProjectQa.ps1, Modules/SalmonRun.PondEngine/Private/PondTasks/Invoke-PondTaskProjectComplete.ps1, Modules/SalmonRun.PondEngine/Private/PondTasks/Get-PondProjectState.ps1, Tests/SalmonRun.ProjectLifecycle.Tests.ps1

Scope: batch quality work by project, track milestones, perform final whole-project review, and archive one complete evidence bundle

- [ ] PQ1: QA starts once only after every project child is QA-ready and records aggregate test and mutation evidence
  CHECK: pwsh -NoProfile -File Tools/QA/Invoke-OrchestratorAcceptance.ps1 -Mode ProjectQaBatch
  EXPECT: PROJECT_QA_BATCH_OK
  EVIDENCE: pending

- [ ] PQ2: project completion requires final project review and writes a self-contained Complete project subfolder with manifest, plans, feedback, and QA evidence
  CHECK: pwsh -NoProfile -File Tools/QA/Invoke-OrchestratorAcceptance.ps1 -Mode ProjectCompletion
  EXPECT: PROJECT_COMPLETION_OK
  EVIDENCE: pending

