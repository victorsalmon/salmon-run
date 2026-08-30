# MVP implementation status

## Current architecture

`Modules/SalmonRun.PondEngine` owns pond definitions, configuration resolution, task execution, transitions, typed attempts, bounded retries, QA evidence validation, and provider adapters. Runtime queues live under `~/.salmon`; repository source contains no live queue state.

Execution settings are read from `~/.salmon/config.json`. Every field resolves independently from a confirmed plan override, pond configuration, global defaults, then the provider catalog. Invalid combinations, unconfirmed overrides, and cost-ceiling violations become `decision-required` typed failures and route to Intake without spawning an agent.

Audit and QA responsibilities follow [`../vision.md`](../vision.md). QA proof conforms to [`../schemas/qa-evidence.schema.json`](../schemas/qa-evidence.schema.json). The coordinator validates the artifact location, behavior mapping, required command results, raw mutation arithmetic, unresolved outcomes, equivalent-mutant dispositions, and absence of waivers before writing a passing sidecar.

`scripts/Sync-ToPrivate.ps1` and `scripts/Test-PrivateParity.ps1` make this repository canonical. Their manifest copies only public shared core; private deployment state is never a sync target.

## Evidence already automated

- Focused profile, prompt, QA evidence, and synchronization contract tests.
- Existing property and mutation-oriented PondEngine regression suites.
- Documentation lint, leak scan, installer, Docker, and PublicLocal test entry points.

## Evidence required before publication

Passing code is not itself release proof. The release commit still needs fresh results for the complete Pester suite, public leak and docs checks, installer/Docker validation, PublicLocal lifecycle, real OpenCode Go lifecycle and controlled failures, private-consumer integration/parity, strict changed-code mutation, and the four-hour unattended soak. Results belong in versioned release evidence; guarded or unavailable external checks remain blockers rather than inferred passes.
