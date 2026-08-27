# Extending salmon-run

salmon-run is built to be extended without forking the core. This guide covers
the two most common extensions: **harness adapters** (new backends) and
**ponds** (new workflow stations). Both are data-driven — you add a file and
register it; you do not edit the pond engine loop.

## Concepts

A run is resolved to a single `PondExecutionProfile` selecting three dimensions:

| Term | Meaning | Example |
| :--- | :------ | :------ |
| **Harness** | Backend family | `opencode`, `devin`, `deepseek`, `codex` |
| **Provider** | CLI/API that talks to the model | `opencode-go`, `dsh`, `openrouter`, `deepinfra` |
| **Model** | Provider-specific slug | `opencode-go/deepseek-v4-flash` |

Defaults live in
`Modules/SalmonRun.PondEngine/Config/model-router-catalog.json`.

## Adding a harness adapter

An *adapter* is the executor that actually launches a session on a backend.

1. **Create the executor.** Add a PowerShell script under the executor
   registry, e.g.
   `Modules/SalmonRun.PondEngine/Private/Executor/MyBackend.ps1`.
   It must accept a `PondExecutionProfile` and expose a consistent result
   record. Model the boundary on the existing `Local.ps1` / `Opencode.ps1`
   executor files.

2. **Register it.** Add an entry to
   `Modules/SalmonRun.PondEngine/Config/model-router-catalog.json`.

3. **Verify.** Run `Start-PondEngine -PondFilter Code`. The dispatcher resolves
   the harness, loads the executor, and dispatches the same plan an existing
   adapter would.

> The harness-neutral control plane makes executors fully interchangeable: no
> harness may own task state, and credentials are resolved only through broker
> services or environment variables. Adapter authors must not read secrets
> directly.

## Adding a pond

A *pond* is a station that watches a queue folder and runs a task sequence.

1. **Add the folder.** Create a directory under `~/.salmon/Tasks/<PondName>/`
   (or register a source folder).
2. **Add the pond definition.** Edit
   `Modules/SalmonRun.PondEngine/Classes/Pond.ps1` and the
   `Get-SalmonRunPonds` function to define the pond's folder, role, operators,
   tasks, and transitions.
3. **Add task functions.** Create `Invoke-PondTask<MyTask>` scripts under
   `Modules/SalmonRun.PondEngine/Private/PondTasks/` and register
   them in the pond definition.

## Adding a skill

The canonical content for any skill lives in exactly one place
(`Skills/<name>/SKILL.md` or the canonical path in `salmon-orchestrator`).
Harness pointers in `.devin/skills/`, `.agents/skills/`, `.claude/skills/` are
thin redirects — never duplicate the skill body.

## Secrets & credentials

Never commit credentials. The pond engine resolves credential *references*
through environment variables and broker services; adapters receive a short-lived
lease, not a secret. For local development, export provider keys as environment
variables (`OPENROUTER_API_KEY`, etc.) — they are read as overrides, never
written to the queue.
