# Gates: integrated orchestrator

OWNS: Tools/QA/Invoke-OrchestratorAcceptance.ps1, Tests/SalmonRun.OrchestratorE2E.Tests.ps1, Tests/SalmonRun.PondEngine.Mutation.Tests.ps1, docs/orchestrator-architecture.md

Scope: prove the complete concept-to-project-output pipeline and its regression safety in an isolated runtime

- [ ] IN1: all child contracts reverify successfully
  CHECK: node C:/Repos/Skills/unlazy/scripts/gate-check.mjs --root . --cwd . --reverify --jobs 1 .unlazy/salmon-run-recovery/gates/leaf-planning.md .unlazy/salmon-run-recovery/gates/leaf-review.md .unlazy/salmon-run-recovery/gates/leaf-project-qa.md .unlazy/salmon-run-recovery/gates/leaf-scheduler.md
  EXPECT: ALL MET
  EVIDENCE: pending

- [ ] IN2: an isolated runtime transforms a project concept into reviewed, QA-proven, bundled project output
  CHECK: pwsh -NoProfile -File Tools/QA/Invoke-OrchestratorAcceptance.ps1 -Mode EndToEnd
  EXPECT: ORCHESTRATOR_E2E_OK
  EVIDENCE: pending

- [ ] IN3: mutation tests kill mutations in the new routing, budget, verdict, batching, and concurrency decisions
  CHECK: pwsh -NoProfile -File Tools/QA/Invoke-OrchestratorAcceptance.ps1 -Mode Mutation
  EXPECT: ORCHESTRATOR_MUTATION_OK
  EVIDENCE: pending

- [ ] IN4: the complete Salmon Run regression suite passes
  CHECK: pwsh -NoProfile -File Tools/QA/Invoke-OrchestratorAcceptance.ps1 -Mode Full
  EXPECT: SALMON_RUN_FULL_ACCEPTANCE_OK
  EVIDENCE: pending

