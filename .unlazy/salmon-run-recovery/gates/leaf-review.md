# Gates: review verdict contract

OWNS: Modules/SalmonRun.PondEngine/Executors/**, Modules/SalmonRun.PondEngine/Private/PondTasks/Invoke-PondTaskTransition.ps1, Modules/SalmonRun.PondEngine/Private/PondTasks/Invoke-PondTaskPrepare.ps1, Tests/SalmonRun.ReviewVerdict.Tests.ps1

Scope: distinguish process success from review approval, persist feedback evidence, and route rejected work back for rework

- [ ] RV1: a zero-exit reviewer that records a failed verdict cannot create a successful completion sentinel
  CHECK: pwsh -NoProfile -File Tools/QA/Invoke-OrchestratorAcceptance.ps1 -Mode ReviewVerdict
  EXPECT: REVIEW_VERDICT_OK
  EVIDENCE: pending

- [ ] RV2: rejected plans contain decision, summary, reviewed artifact, and feedback-file headers and route to rework
  CHECK: pwsh -NoProfile -File Tools/QA/Invoke-OrchestratorAcceptance.ps1 -Mode ReviewFeedback
  EXPECT: REVIEW_FEEDBACK_OK
  EVIDENCE: pending

