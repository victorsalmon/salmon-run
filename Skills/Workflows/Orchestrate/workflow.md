## Orchestrate Workflow

**Mode**: Orchestrate — runs as the current opencode session (not detached).
**When**: User runs `/work` or says "orchestrate".
**Goal**: Dispatch and monitor agent subprocesses until all task queues are drained.

### Architecture

The orchestrator IS the current opencode agent. It does not detach. Each cycle:

1. **State check** — one short bash call (`Invoke-OrchestratorCycle.ps1`) returns JSON with queue counts and running agents
2. **Agent reasons** — decide what to do: handle completions, spawn new agents, rescue crashes
3. **Act** — short bash calls for each action (spawn, move, clean)
4. **Sleep** — bash `Start-Sleep -Seconds <interval>` (within 120s timeout)
5. **Report** — compact status line to user; full status to sticky file
6. **Loop** — repeat

### Prerequisites

- [ ] Agent identity registered (PID file, heartbeat) per workflow-primitives.md § Agent identity
- [ ] Stale-file pre-check run: `Invoke-StaleFilePreCheck` from workflow-primitives.md
- [ ] Stop signal not present

### Cycle interval

- **Standard**: 60s sleep between cycles (bash `Start-Sleep -Seconds 60` with `timeout=120000`)
- **Fast mode**: 30s if running agents are near completion
- **Slow mode**: 120s if queues are empty and only waiting for in-flight agents

### Cycle logic

Each cycle is one bash call that runs `Invoke-OrchestratorCycle.ps1`:

```powershell
$json = & (Resolve-Path "C:\\Repos\\Public\\salmon-run\\Tools\\Documentation\\Scripts\\Invoke-OrchestratorCycle.ps1") -LastCompletedFile (Join-Path $PWD "Tasks/Logs/.orchestrator-cycle-state.json")
Write-Host $json
```

The JSON output has:
- `queues.rootCoder`, `queues.review`, `queues.working` — file counts
- `running` — array of `{agentId, pid, role, elapsed}`
- `newSinceLast.completed` — agents that completed since last cycle
- `newSinceLast.stale` — agents that went stale since last cycle
- `hasCapacity` — true if files remain to dispatch
- `allEmpty` — true if all queues empty AND no agents running

### Per-cycle decision tree

1. **Stop signal check** — Before anything else, check for stop signals:
   ```powershell
   . (Resolve-Path "C:\\Repos\\Public\\salmon-run\\Tools\\Documentation\\Scripts\\Invoke-StopSignalCheck.ps1")
   if (Invoke-StopSignalCheck -Mode "code") { ... signal found, set stop flag ... }
   ```
   If stop signal found, break the loop and start Phase 4 — Completion.

2. **Read cycle state** from `Invoke-OrchestratorCycle.ps1` JSON output.

3. **Handle newly completed agents** — For each agent in `newSinceLast.completed`:
   - The agent's Working/ subdirectory may contain completed files
   - Check if files have Lock Header with `Status: released`
   - If released, files were already moved by the subagent — just clean up empty dirs
   - If still locked, rescue: `Handle-OrphanStatus` (move to Review/)

4. **Handle newly stale agents** — For each agent in `newSinceLast.stale`:
   - Rescue orphaned files from Working/ back to Code/ or Review/
   - Clean up agent PID/heartbeat files
   - Log the crash

5. **Check connascence groups** — If `hasCapacity`:
   ```powershell
   $cgJson = & (Resolve-Path "Orchestrator/Orchestration/Get-ConnascenceGroups.ps1") -PassThru
   Write-Host $cgJson
   ```
   Parse the JSON to find ready groups. The `readySet` array lists filenames ready for dispatch.

6. **Dispatch new agents** — For each ready group (up to `$script:orcCapacity`):
   a. Create stream directory: `Tasks/Working/stream-<nextId>/`
   b. Move ready files into it
   c. Write `stream.json` metadata
   d. Spawn: `Start-Process -FilePath opencode -ArgumentList "run", "--command", "work-stream" -NoNewWindow -PassThru -RedirectStandardOutput <outFile> -RedirectStandardError <errFile>`
   e. Write PID file: `$procId > Tasks/Logs/agents/stream-<nextId>.pid`
   e. Write heartbeat: `Get-Date -Format o > Tasks/Logs/agents/stream-<nextId>.heartbeat`

   Use `opencode.cmd` (the Windows cmd wrapper) not `opencode` directly, since it's a .exe from npm that needs the cmd shim.

   ```powershell
   $opencodeCmd = (Get-Command opencode.cmd -ErrorAction SilentlyContinue).Source
   if (-not $opencodeCmd) { $opencodeCmd = (Get-Command opencode -ErrorAction SilentlyContinue).Source }
   $env:OC_STREAM_ID = "stream-$nextId"
   $env:OC_PROJECT_ROOT = $PWD
   $proc = Start-Process -FilePath $opencodeCmd -ArgumentList "run", "--command", "work-stream" -NoNewWindow -PassThru -RedirectStandardOutput "$agentDir/stream-$nextId.stdout" -RedirectStandardError "$agentDir/stream-$nextId.stderr"
   ```

7. **Write heartbeat**:
   ```powershell
   $PID.ToString() | Out-File -FilePath "Tasks/Logs/agents/orchestrator-$PID.pid" -Encoding utf8 -NoNewline
   [datetime]::UtcNow.ToString('o') | Out-File -FilePath "Tasks/Logs/agents/orchestrator-$PID.heartbeat" -Encoding utf8 -NoNewline
   ```

8. **Report status** — Write a compact status line to the user:
   ```
   Cycle <N> | <running> agents | <queue> files | <newlyDone> done this cycle
   ```
   Every 5 cycles (or when state changes), write a full status table:
   ```
   Agent            | Role    | Elapsed
   stream-1         | coder   | 4m32s
   stream-2         | reviewer| 2m15s
   ```

   Also write the full status to `Tasks/Logs/orchestrator-live.json` (done by Invoke-OrchestratorCycle.ps1 automatically).

9. **Sleep** — `Start-Sleep -Seconds <interval>` with `timeout=<interval+60>000`.

10. **Check exit** — If `allEmpty` is true and no agents running, break to Phase 4.

### Phase 4 — Completion

When queues are empty and no agents running:

1. Rescue any remaining files in Working/ (safety net)
2. Clean up agent PID/heartbeat files
3. Run the Completion Checklist (CC) per workflow-primitives.md § Complete CC
4. Report elapsed time
5. Emit: `Status: Completed orchestration`

### Capacity and parallel count

- Default parallel capacity: **6** concurrent agents
- Mix of coders and reviewers based on queue ratio
- If only coder work exists: 6 coders
- If only review work exists: 6 reviewers
- If mixed: proportional split

### Output compression

- Each cycle produces at most 2 lines of user-facing output
- Full status table only when state changes (agent completed/crashed or new dispatch)
- All detailed state goes to `Tasks/Logs/orchestrator-live.json` (read with `Get-Content Tasks/Logs/orchestrator-live.json`)
- Old cycle output is acknowledged with "Same state — <N> running" rather than repeating the table
- Every 5th cycle always shows the full table as a heartbeat

### Stop signal

<!-- doc-lint: exempt -->
Place `Tasks/stop` or `Tasks/stop.code` to signal the orchestrator to stop after the current cycle. The orchestrator checks at the start of each cycle.

### Key files

| File | Purpose |
|------|---------|
| `Tasks/Logs/orchestrator-live.json` | Live status, updated every cycle |
<!-- doc-lint: exempt -->
| `Tasks/Logs/.orchestrator-cycle-state.json` | Cross-cycle state tracking (completed agents) |
| `Tasks/Logs/agents/` | Agent PID/heartbeat files |
| `Tasks/Working/stream-*/` | Active stream directories |
| `C:\\Repos\\Public\\salmon-run\\Tools\\Documentation\\Scripts\\Invoke-OrchestratorCycle.ps1` | Cycle state check helper |

### Exit codes

| Code | Meaning |
|------|---------|
| 0 | All queues drained successfully |
| 10 | File locked by another agent |
| 99 | Context gate triggered — graceful handoff to next orchestrator |
