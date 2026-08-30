# Extending salmon-run

salmon-run is built to be extended without forking the core. This guide covers
the two most common extensions: **harness adapters** (new backends) and
**ponds** (new workflow stations). Both are data-driven — you add a file and
register it; you do not edit the pond engine loop.

## Concepts

A pond attempt resolves a complete `PondExecutionProfile`:

| Term | Meaning | Example |
| :--- | :------ | :------ |
| **Harness** | Backend family | `local`, `opencode`, `devin`, `deepseek`, `codex` |
| **Provider** | CLI/API that talks to the model | `local`, `opencode-go`, `opencode`, `devin`, `dsh`, `openrouter`, `deepinfra`, `codex` |
| **Model** | Provider-specific slug | `opencode-go/deepseek-v4-flash` |
| **Challenge** | Capability tier | `Daily`, `Complex`, `Frontier` |
| **Effort** | Provider-supported reasoning setting | `default`, `max` |
| **TimeoutMinutes** | Hard attempt deadline | `60` |
| **CostCeiling** | Maximum resolved model cost | `25.0` |

Defaults live in
`Modules/SalmonRun.PondEngine/Config/model-router-catalog.json`.
Runtime defaults and pond-specific values live under `execution.defaults` and
`execution.ponds.<PondName>` in `~/.salmon/config.json`. Confirmed plan overrides
win field by field; adapters must not implement their own precedence rules.

## Adding a harness adapter

An *adapter* is the executor that actually launches a session on a backend.

1. **Create the executor.** Add a PowerShell script to
   `Modules/SalmonRun.PondEngine/Executors/MyBackend.ps1`. It must accept
   a `PondExecutionProfile` and expose a consistent result record. Model the
   boundary on the existing `PublicLocal.ps1`, `Opencode.ps1`, `Devin.ps1`,
   `Dsh.ps1`, or `Codex.ps1` executor files.

2. **Register it.** Add a harness and provider to
   `Modules/SalmonRun.PondEngine/Config/harness-defaults.json` and add a
   corresponding model entry to
   `Modules/SalmonRun.PondEngine/Config/model-router-catalog.json`.

3. **Verify interchangeability.** Run the same deterministic plan through
   PublicLocal and the new adapter. Add contract tests for command construction,
   redaction, success/failure sentinels, timeout, human-decision routing, typed
   result binding, and the full pond lifecycle. An adapter remains beta until
   its live canary and soak evidence meet the release standard.

> The harness-neutral control plane makes executors fully interchangeable: no
> harness may own task state, and credentials are resolved only through broker
> services or environment variables. Adapter authors must not read secrets
> directly.

## Adding a pond

A *pond* is a station that watches a queue folder and runs a task sequence.

1. **Add the folder.** Create a directory under `~/.salmon/Tasks/<PondName>/`
   (or register a source folder).
2. **Add the pond definition.** Add the class definitions in
   `Modules/SalmonRun.PondEngine/Classes/Pond.ps1` if needed, then edit
   `Modules/SalmonRun.PondEngine/Public/Get-SalmonRunPonds.ps1` to define the
   pond's folder, role, operators, tasks, and transitions.
3. **Add task functions.** Create `Invoke-PondTask<MyTask>` scripts under
   `Modules/SalmonRun.PondEngine/Private/PondTasks/` and register
   them in the pond definition.

## Adding a skill

The canonical content for any skill lives in exactly one place
(`Skills/<name>/SKILL.md` in its owning public or product repository).
Harness pointers in `.devin/skills/`, `.agents/skills/`, `.claude/skills/` are
thin redirects — never duplicate the skill body.

## Adding or changing a quality gate

Agent-written Markdown is descriptive, not authoritative. New gates must define
a versioned typed artifact or sidecar, bind it to the current plan/attempt/gate,
validate it in coordinator code, reject stale or forged evidence, and add tests
for success, semantic failure, transport failure, timeout, decision-required,
Investigate, and Paused routing. Gate logic belongs outside provider adapters.

## Secrets & credentials

Never commit credentials. The pond engine resolves credential *references*
through environment variables and broker services; adapters receive a short-lived
lease, not a secret. For local development, export provider keys as environment
variables (`OPENROUTER_API_KEY`, etc.) — they are read as overrides, never
written to the queue.
