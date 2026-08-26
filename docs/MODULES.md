# salmon-run module catalog

The `salmon-run` package is organized into two module trees:

- `Orchestrator/Modules/` — control-plane modules used by the pond engine and runtime.
- `Skills/Docker/Modules/` — cross-cutting utility modules used by setup, display, and git/CI helpers.

## Orchestrator/Modules

| Module | Purpose |
| :--- | :--- |
| `SalmonRun.AgentLifecycle` | Tracks agent birth, heartbeat, and death; cleans stale lanes. |
| `SalmonRun.Audit` | JSONL audit logging with hash-chain signing, tamper detection, secret redaction, and an API-call wrapper. |
| `SalmonRun.Config` | Loads and validates `install.json` and user configuration. |
| `SalmonRun.Constants` | Environment, port, path, and exit-code constants. |
| `SalmonRun.Credentials` | Modular credential resolution from `~/.salmon/.env`: Env, File, AWS, GitHub, Worktree, and custom resolvers. |
| `SalmonRun.Core` | Shared helper functions (logging, backoff, native command wrappers). |
| `SalmonRun.Locking` | File and namespace locking for multi-agent safe queues. |
| `SalmonRun.ModuleLoader` | Loads Salmon Run modules with legacy-name fallbacks. |
| `SalmonRun.PondEngine` | Kanban pond/stream engine: class definitions, dispatch, model routing, and executor registry. |
| `SalmonRun.Process` | Safe `cmd`/`docker` invocation helpers. |
| `SalmonRun.WorkflowEvents` | Event journal and mutation/property testing for workflow actions. |

## Skills/Docker/Modules

| Module | Purpose |
| :--- | :--- |
| `SalmonRun.DeployState` | Setup checkpoint state for install/upgrade runs. |
| `SalmonRun.Diagnostics` | Step-by-step diagnostic result capture and reporting. |
| `SalmonRun.Display` | Console output helpers: parallel section headers and summaries. |
| `SalmonRun.GitCloud` | Git-hosting abstraction for token resolution, authenticated push, CI status, and repo secrets. Supports GitHub and worktree.ca. |
| `SalmonRun.Paths` | Resolves canonical Salmon Run paths and repo roots. |
| `SalmonRun.Ports` | Port allocation and registry helpers. |

## Adding a module

1. Place the module under the appropriate `Modules` tree.
2. Provide a `*.psd1` manifest, a `*.psm1` loader, and `Public/` / `Private/` scripts.
3. Add Pester tests in the matching `Tests` directory.
4. Run the module import and the targeted test file before committing.
