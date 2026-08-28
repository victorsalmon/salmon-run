# Gates: project planning contract

OWNS: Modules/SalmonRun.PondEngine/Private/PondTasks/Invoke-PondTaskPlanProject.ps1, Modules/SalmonRun.PondEngine/Config/plan-header-schema.json, Tests/SalmonRun.ProjectPlanning.Tests.ps1

Scope: convert a project concept into substantive dependency-aware session plans whose estimated coding workload never exceeds 100,000 tokens

- [ ] PP1: every emitted session plan has an independently calculated implementation estimate at or below 100,000 tokens
  CHECK: pwsh -NoProfile -File Tools/QA/Invoke-OrchestratorAcceptance.ps1 -Mode PlanningBudget
  EXPECT: PLANNING_BUDGET_OK
  EVIDENCE: pending

- [ ] PP2: concept and explicit-child fixtures produce substantive plans with acceptance criteria, dependencies, and project identity
  CHECK: pwsh -NoProfile -File Tools/QA/Invoke-OrchestratorAcceptance.ps1 -Mode PlanningContent
  EXPECT: PLANNING_CONTENT_OK
  EVIDENCE: pending

