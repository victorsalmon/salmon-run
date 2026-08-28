# Gates: Salmon Run functional recovery

OWNS: .unlazy/salmon-run-recovery/**

Scope: deliver and independently verify a functional quality-first concept-to-complete orchestrator

- [ ] ROOT1: every leaf and integration gate is freshly verified
  CHECK: node C:/Repos/Skills/unlazy/scripts/gate-check.mjs --root . --cwd . --reverify --jobs 1 .unlazy/salmon-run-recovery/gates/leaf-planning.md .unlazy/salmon-run-recovery/gates/leaf-review.md .unlazy/salmon-run-recovery/gates/leaf-project-qa.md .unlazy/salmon-run-recovery/gates/leaf-scheduler.md .unlazy/salmon-run-recovery/gates/node-integration.md
  EXPECT: ALL MET
  EVIDENCE: pending

- [ ] ROOT2: live queue recovery and a bounded smoke cycle preserve every plan and show forward progress or an actionable blocked reason
  CHECK: pwsh -NoProfile -File Tools/QA/Invoke-OrchestratorAcceptance.ps1 -Mode LiveQueue
  EXPECT: LIVE_QUEUE_OK
  EVIDENCE: pending

