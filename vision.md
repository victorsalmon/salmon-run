# Salmon Run Vision

Salmon Run is a filesystem-backed, multi-agent software-delivery system. A coordinator moves durable plans through replaceable ponds while independently configurable harnesses, providers, models, and effort levels perform bounded roles.

The canonical product pipeline is:

`Intake / Print -> Code -> Review -> Audit -> QA -> Complete -> Archive`

Printing turns an idea into a decision-complete plan: acceptance criteria, exact validation commands, behavior and invariant risks, required test layers, mutation command and changed-code scope, environment prerequisites, dependencies, and resolved pond execution profiles. Any human choice is made during Printing or represented as `decision-required` work in Intake; unattended ponds do not improvise product decisions.

Code implements the plan and adds focused acceptance/regression tests for safe development. Review is independent and read-only. Audit runs secrets and documentation checks, lint/static analysis, build, the existing focused regression suite, and AQE assessment in that order. Audit invokes 4C only when those checks reveal an actual defect; changed production code returns through Review and Audit.

QA is the final proof-building pond. It may improve tests, QA configuration, or production source; production changes re-enter Review and Audit. QA inventories behavior and invariants, builds the applicable example/property/stateful/integration/E2E layers, reruns deterministic Audit checks and the full regression suite, and performs changed-code mutation testing. Completion requires a raw score of at least 95%, zero unresolved survivors/no-coverage/timeouts/compile errors, explicit proof for equivalent mutants, and no waivers.

Every gate is fail-closed and based on coordinator-written, attempt-bound typed sidecars rather than agent-written Markdown alone. Semantic churn is bounded to an initial attempt plus one targeted repair before Investigate. Transport gets two retries before Paused. Identical failures escalate immediately. Human decisions route to Intake.

Ponds, transitions, task pipelines, executors, providers, models, effort settings, timeouts, and cost ceilings are replaceable configuration. OpenCode Go is the first supported external golden path. PublicLocal remains a credential-free deterministic lifecycle canary; Codex, Devin, DSH, and future adapters are beta until they pass the same lifecycle, failure, decision, and soak gates.

This public repository is authoritative for the engine, schemas, shared modules, executor contracts, public tests, and product documentation. Private deployments consume only manifest-listed shared files in one direction and keep deployment extensions, credentials, queues, and internal documentation private.

The release standard is operational autonomy: no duplicate dispatches, stuck leases, residual Working lanes, unbounded retries, queue loss, or forged/stale evidence during representative external canaries and a four-hour unattended soak.
