# Gates: Salmon Run public-ready MVP

OWNS: Modules/SalmonRun.PondEngine/**, Modules/SalmonRun.AQE/**, Tests/**, scripts/**, docs/**, README.md, AGENTS.md, vision.md, config.example.json, dot-salmon.example/**

Scope: make the public repository canonical and enforce the configured Audit and mutation-backed QA pipeline through typed coordinator evidence.

- [ ] G1: focused configuration, routing, gate, synchronization, and installer regressions pass
  CHECK: pwsh -NoProfile -File scripts/Verify-PublicMvp.ps1 -Focused
  EXPECT: SALMON_MVP_FOCUSED_PASS
  EVIDENCE: pending

- [ ] G2: the complete public Pester suite passes
  CHECK: pwsh -NoProfile -File scripts/Verify-PublicMvp.ps1 -FullSuite
  EXPECT: SALMON_MVP_FULL_PASS
  EVIDENCE: pending

- [ ] G3: documentation and public leak checks pass
  CHECK: pwsh -NoProfile -File scripts/Verify-PublicMvp.ps1 -Documentation
  EXPECT: SALMON_MVP_DOCS_PASS
  EVIDENCE: pending

- [ ] G4: a clean-install PublicLocal plan completes the full pipeline with typed QA proof
  CHECK: pwsh -NoProfile -File scripts/Verify-PublicMvp.ps1 -LocalCanary
  EXPECT: SALMON_MVP_LOCAL_CANARY_PASS
  EVIDENCE: pending

- [ ] G5: public-to-private manifest synchronization validates parity without overwriting private extensions
  CHECK: pwsh -NoProfile -File scripts/Verify-PublicMvp.ps1 -SyncParity
  EXPECT: SALMON_MVP_SYNC_PASS
  EVIDENCE: pending

- [ ] G6: changed control-plane behavior is mutation-proven at or above 95 percent with no unresolved outcomes
  CHECK: pwsh -NoProfile -File scripts/Verify-PublicMvp.ps1 -Mutation
  EXPECT: SALMON_MVP_MUTATION_PASS
  EVIDENCE: pending

- [ ] G7: a representative OpenCode Go plan traverses every pond and controlled failure routes to Intake
  CHECK: pwsh -NoProfile -File scripts/Verify-PublicMvp.ps1 -OpenCodeCanary
  EXPECT: SALMON_MVP_OPENCODE_PASS
  EVIDENCE: pending

- [ ] G8: the unattended engine completes a four-hour soak without duplicate dispatch, stuck leases, residual Working lanes, retry runaway, or queue loss
  CHECK: pwsh -NoProfile -File scripts/Verify-PublicMvp.ps1 -Soak -SoakHours 4
  EXPECT: SALMON_MVP_SOAK_PASS
  EVIDENCE: pending
