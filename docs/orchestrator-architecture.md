# Orchestrator architecture

Salmon Run is a file-oriented workflow engine for agentic development. Its design follows a small-tools pipeline: plans flow through interchangeable **ponds**, executors perform one bounded role, and a single coordinator owns control-plane state.

```text
immutable plan specification
          |
          v
 Code -> Review -> Audit -> QA -> Complete
   ^         |        |      |
   +---------+--------+------+  bounded semantic rework

executor -> result sidecar -> coordinator -> atomic transition -> sync outbox
                         \-> event journal / health model
```

## Design boundaries

A plan is the data packet. A pond is a stage with the same conceptual interface:

1. accept eligible plans;
2. claim them under a generation-scoped lease;
3. run one role-specific executor;
4. emit a typed result;
5. let the coordinator choose the next pond.

Ponds do not own Git synchronization, recovery policy, or queue routing. That separation keeps stages replaceable: a local smoke-test executor, OpenCode, Devin, DSH, or Codex can implement a role without changing the orchestration protocol.

The coordinator is the only control-plane writer. It validates results, updates bounded current evidence, moves queue artifacts, renews/reaps leases, writes health events, and serializes Git synchronization.

## Durable state

| State | Location | Owner |
| --- | --- | --- |
| Plan specification and current semantic headers | `~/.salmon/Tasks/<Pond>/*.md` | Coordinator |
| Attempt result | `~/.salmon/Results/<PlanId>/<Gate>/<AttemptId>.json` | Executor writes; coordinator validates |
| Current gate result pointer | `~/.salmon/Results/<PlanId>/<Gate>/current.json` | Coordinator |
| Lane lease | `~/.salmon/Tasks/Working/<Lane>/.lease.json` | Coordinator/executor heartbeat |
| Retry and circuit-breaker state | `~/.salmon/State/plan-*.json` | Coordinator |
| Operational events | `~/.salmon/Logs/workflow-events.jsonl` | Coordinator and adapters |
| Pending Git synchronization | `~/.salmon/SyncOutbox/*.json` | Coordinator |

The plan specification is not an event log. Operational claim, spawn, heartbeat, checkpoint, push, and recovery events stay outside the agent packet. Semantic `PondLog` evidence is normalized to one block and bounded to the latest 32 outcomes.

## Attempt and result protocol

Every gate attempt has stable `PlanId`, `AttemptId`, and `GateAttempt` values. A result record contains the gate, verdict, failure kind, timestamps, evidence summary, failed checks, fix actions, and changed-file scope.

Verdict precedence is attempt-scoped: the latest valid result is authoritative. Historical failures remain auditable but cannot override a later pass. Failure classification is total and uses these values:

- `success`
- `semantic-failure`
- `transport-failure`
- `timeout`
- `decision-required`
- `engine-error`

Parser or transition exceptions fail closed to `Paused` with `engine-error`; they never become implicit Code retries.

## Scheduling and writer isolation

Streams correspond to Git worktrees, while ponds correspond to roles. Scheduling resolves every repository/worktree to Git's common directory and uses that canonical identity as the writer lock.

Code, Audit, QA, Investigator, and code-changing recovery are mutually exclusive for a repository. Review can scale independently because it is read-only. A selected stream may only use a lane bound to the same canonical repository; there is no cross-repository fallback.

## Recovery

Recovery is deliberately narrower than retry. A lane is recoverable only when all of the following are true:

- its PID is dead;
- its typed heartbeat is stale;
- the lease generation is unchanged across two observations;
- no completed result sentinel exists.

Recovery preserves the source pond, attempt identity, and lease generation. Missing or malformed leases fail closed to `Paused/EngineError`. Completed lane envelopes are removed recursively before checkpoint work, so recovery can never observe a plan after its lease has been removed.

Retry budgets persist across restarts. Transport failures receive at most two backed-off retries; semantic failures receive at most two rework attempts. A repeated identical signature trips the breaker on its second occurrence. Six transitions without forward progress in 30 minutes pause the family.

## Git and synchronization

Claims, locks, and heartbeats are local atomic operations; they are not Git commits. Stable pond transitions are checkpointed as one move and placed in a serialized sync outbox. Fetch/reconcile/push happens outside lane execution.

An outbox request is idempotent. If its commit is already reachable from the remote branch, the coordinator acknowledges and removes it before considering backoff or working-tree state. Repeated sync failure opens dispatch backpressure rather than redispatching an agent.

## Health model

Process liveness is necessary but not sufficient. Health measures useful work: a unique plan advancing to a higher gate or completing. Claims, retries, rescues, heartbeat writes, and filename churn do not count as progress.

The health report includes unique completions, forward/backward transitions, cycles, transition errors, sync backlog/failures, duplicate families, largest prompt size, useful-run ratio, working-lane state, and coordinator heartbeat. Repeated cycling, transition exceptions, unsafe writer overlap, stale leases, prompt growth, or sync failure makes health fail closed.

## Extension contract

A new pond should be a narrow stage, not a second coordinator. Define its role, eligibility gate, executor contract, typed result, and success/failure destinations. Reuse the shared lease, result, repository identity, transition, journal, and outbox services. See [EXTENDING.md](./EXTENDING.md) for configuration examples.