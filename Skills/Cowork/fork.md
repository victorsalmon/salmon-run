# Skill: Fork — Fork session context into a parallel TUI window

**Type**: skill-entrypoint
**Owner**: Cowork mode
**Container**: opencode (CLI, user-invoked)
**Loaded via**: `/fork` command, or read from this file when the user invokes "fork"

**Output locations**:
- `Tasks/Handoff/fork-stub-<date>-<topic>.md` — Fork-Stub document with all transferred context

**Related**:
- `Skills/Cowork/cowork.md` — Cowork workflow (parent skill)
- `Skills/Cowork/Scripts/New-ForkStub.ps1` — writes the Fork-Stub document
- `Skills/Cowork/Scripts/Invoke-Fork.ps1` — launches the forked terminal
- `Skills/Cowork/handoff.md` — Handoff format reference

---

## Overview

Forking lets you "branch" your current session context into a parallel interactive OpenCode window. Use it mid-session when a secondary goal arises — write a Fork-Stub capturing all context for the offloaded goal, then open a new terminal with `opencode --continue --fork`.

Both sessions compress after the fork:
- **Forked session**: The `--prompt` message tells it to read the Fork-Stub and discard everything not relevant to its goal.
- **Original session**: The model explicitly announces the offloaded scope and compresses away that context to stay focused.

---

## When to use

- A secondary goal arises mid-session that you want to pursue in parallel
- You need to partition context cleanly between two workstreams
- The secondary goal shares some context with the current goal (Fork-Stub duplicates shared context so nothing is lost)

---

## Modes

### Full fork (default) — `fork <goal>`
Writes the Fork-Stub and immediately launches `opencode --continue --fork` in a new terminal window.

### Stub-only — `fork --stub-only <goal>`
Writes the Fork-Stub to disk without opening a new terminal. The stub sits in `Tasks/Handoff/` for later pickup. Launch it later with:
```
Invoke-Fork -StubPath "Tasks/Handoff/fork-stub-..." -Goal "your goal"
```

---

## How it works

### Fork-Stub

A Fork-Stub (`Tasks/Handoff/fork-stub-<date>-<topic>.md`) captures ALL context needed for the offloaded goal — not just a summary. The model composes the body containing:
- Goal description
- Relevant files and their current state
- Decisions made so far
- Unresolved questions
- Dependencies and constraints
- Any shared context that the offloaded goal needs (even if it overlaps with the original session)

The Fork-Stub is **prospective** (forward-looking) — unlike a Cowork Stub which is **retrospective** (what happened). Every piece of context the forked session could need goes into the stub so it can operate independently.

### Execution model — single `!` command

The `/fork` command template in `opencode.json` is intentionally minimal. It uses **one `!` command** that runs `Fork-Session.ps1` **before** the model sees the prompt. The script creates the Fork-Stub, writes a context file, and launches the new terminal. The model receives the script output and then compresses the original session.

Why this approach:
- Multi-step model-instruction templates were unreliable. The model skipped steps or the template content was stripped during processing.
- A single `!` command is processed by opencode's shell-injection mechanism and actually executes.
- The PowerShell script is the single source of truth for the fork behavior, making it testable outside opencode.

### Compression protocol

After a fork, both sessions compress:

1. **Original session** — immediately after the fork verifies, the model says:
   > "Offloaded `<goal>`. Now focused on `<remaining>`. Compressing away offloaded context."
   This explicitly acknowledges what was shed and what remains, keeping the session sharp.

2. **Forked session** — receives a `--prompt` message on launch:
   > "Forked for: `<goal>`. Read the Fork-Stub at `<path>`, then compress away everything not relevant to this goal. Proceed."
   The model reads the stub, identifies what matters, and compresses the rest.

---

## Scripts reference

All scripts in `Skills/Cowork/Scripts/`.

| Script | When | Output |
|--------|------|--------|
| `Fork-Session.ps1` | **Universal entry point** — creates stub/context file and launches fork | Resolved stub path |
| `Invoke-ForkFlow.ps1` | Original combined flow (model-supplied context file) | Resolved stub path |
| `Fork-OpenCodeSession.ps1` | Manual PowerShell fallback — dot-source and run `Fork-OpenCodeSession -Goal "..."` | Resolved stub path |
| `New-ForkStub.ps1` | Writing the Fork-Stub document | `Tasks/Handoff/fork-stub-<date>-<topic>.md` |
| `Invoke-Fork.ps1` | Launching the forked terminal | Confirmation with stub path |

---

## Invocation

### Primary: `/fork <goal>`

The `/fork` command in `opencode.json` runs one `!` command:

```
!`powershell -NoProfile -ExecutionPolicy Bypass -File Skills/Cowork/Scripts/Fork-Session.ps1 -Goal "$ARGUMENTS"`
```

The script creates the Fork-Stub and context file, then launches a new `opencode --continue --fork` window. The original session model receives the script output and compresses context related to the goal.

### Alternative: `/fork-session <goal>`

If the JSON `/fork` command fails due to template processing, use the markdown command at `.opencode/commands/fork-session.md`. It contains the same `!` command but is read from a markdown file instead of a JSON string.

### Manual fallback: `Fork-OpenCodeSession` PowerShell function

If both TUI commands fail, dot-source the helper and run it directly from PowerShell:

```powershell
. Skills/Cowork/Scripts/Fork-OpenCodeSession.ps1
Fork-OpenCodeSession -Goal "fix the build"
Fork-OpenCodeSession -Goal "fix the build" -StubOnly
```

### Lessons Learned — 2026-06-15

**What Worked**:
- Single `!` command in the opencode template — the shell command actually executes, the model cannot narrate past it
- `Fork-Session.ps1` as a universal PowerShell entry point — handles topic slugging, stub creation, context file writing, and terminal launch in one script
- `-ExecutionPolicy Bypass` — required because Windows PowerShell 5.1 defaults to `Restricted`
- ASCII-only characters in PowerShell scripts — avoids encoding parse errors with PS 5.1's ANSI default
- `ProcessStartInfo` with explicit `WindowStyle`, `UseShellExecute`, and `WorkingDirectory` — reliable new-window creation on Windows
- Multiple invocation paths (JSON `/fork`, markdown `/fork-session`, PowerShell `Fork-OpenCodeSession`) — covers TUI and manual fallback

**What Didn't Work**:
- Multi-step model-instruction templates — the model skipped steps or the template content was stripped during processing
- Fenced code blocks (` ``` `), inline backticks, and angle brackets in opencode.json templates — stripped before reaching the model
- `Invoke-ForkFlow.ps1` with function-only definition — when run via `powershell -File`, it defined the function but never called it. Fixed by adding script-level `param()` block and explicit invocation at script end.
- Em-dash character (U+2014) in `Invoke-Fork.ps1` and `Invoke-ForkFlow.ps1` — PowerShell 5.1 with ANSI encoding can't parse it. Replaced with `--`.

**Improvements for next run**:
- Consider adding `opencode` PATH resolution via `Get-Command opencode` before launching the new terminal, with fallback to the known install location
- Consider extending `Fork-Session.ps1` to read an optional pre-written context file if the model supplies one

**Helpful Information**:
- The `!` prefix in opencode.json templates is best used for a **single shell command** whose output is injected into the prompt. Complex multi-step logic should live in the called script.
- `$PSScriptRoot` path resolution in `Fork-Session.ps1` resolves 2 levels up from `Skills/Cowork/Scripts/` to reach the repo root.
- Always use ASCII-only characters in PowerShell scripts to avoid encoding issues with PS 5.1's ANSI default
