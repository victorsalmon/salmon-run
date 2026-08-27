---
name: autocode-quality
description: Review an AutoCode change against its plan, run relevant tests, and produce regression, security, and delivery evidence.
---

Use this skill when implementation is complete or the user asks for testing, review, regression analysis, or security checks.

1. Read the approved plan, acceptance criteria, repository instructions, git diff, and changed-file list.
2. Run the narrowest relevant unit, integration, lint, type, build, and regression checks required by the repository. Expand to the full suite when the change has broad blast radius.
3. Check for missing tests, changed behavior without acceptance coverage, secrets, unsafe logging, authorization gaps, dependency risk, and accidental unrelated edits.
4. Review the diff as a skeptical maintainer. Distinguish confirmed failures from recommendations and environmental limitations.
5. If a quality gate fails, return actionable findings and block delivery. Do not silently weaken tests or rewrite unrelated code.
6. If all required gates pass, produce a verification record listing commands, results, acceptance-criteria mapping, and residual risk.

Do not claim a test passed unless it actually ran successfully. Do not approve production deployment; this skill only establishes evidence for delivery review.

Output `Status: green-for-delivery` or `Status: blocked`, with severity-ranked findings when blocked.
