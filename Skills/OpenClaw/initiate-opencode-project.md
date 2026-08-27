# Skill: Initiate Coding Project

## Purpose
Guide the Verifier (VERI) agent through initiating a new project inside a CODE container.

## Prerequisites
- CODE containers have coding API keys (`opencode_go_key1-4`) mounted at `/run/secrets/`. VERI does NOT mount coding keys — it dispatches tasks to CODE containers.
- The VERI agent has access to the `CODE_REPOS` environment variable listing repositories to clone.
- The target CODE container (`code-1` through `code-5`) is running and healthy.

## Workflow

### 1. Choose a CODE container and key
Select an available CODE container (check `/workspace/code_{N}_outbox/status.json` for idle state) and pick one of the four coding keys:
```bash
# Read mounted secrets
cat /run/secrets/opencode_go_key1
cat /run/secrets/opencode_go_key1_email
```

### 2. Prepare the workspace
CODE containers auto-clone repositories listed in `CODE_REPOS` into `/workspace/` on startup.
If new repositories are needed, write a `clone-repos.sh` task to the CODE container inbox:
```bash
mkdir -p /workspace/code_1_inbox
cat > /workspace/code_1_inbox/clone-repos.sh << 'EOF'
#!/bin/sh
cd /workspace
git clone https://github.com/<org>/<new-repo>.git
EOF
touch /workspace/code_1_inbox/clone-repos.sh.trigger
```

### 3. Write opencode.json (if the repo doesn't have one)
Each repository that uses opencode must contain an `opencode.json` at its root specifying the model and API key:
```json
{
  "provider": "openrouter",
  "model": "deepseek/deepseek-v4-flash",
  "apiKey": "${OPENCODE_GO_KEY}"
}
```
The CODE container's entrypoint exports the key as `OPENCODE_GO_KEY` from the mounted secret.

### 4. Dispatch a task
Write a task file to the CODE container inbox:
```bash
cat > /workspace/code_1_inbox/project-init.md << 'EOF'
# Project: <Name>

## Objective
Describe the task here.

## Context
Repository path: /workspace/<repo>
Key to use: opencode_go_key1

## Deliverables
- Updated code in the repository
- Commit message prefixed with [CODE-1]
EOF
touch /workspace/code_1_inbox/project-init.md.trigger
```

### 5. Monitor completion
The CODE container will:
1. Detect the `.trigger` file
2. Set status to "busy"
3. Run `opencode run --file task.md`
4. Write results to `/workspace/code_1_outbox/`
5. Commit and push (if git credentials are configured)
6. Set status to "idle"

Monitor the outbox for results:
```bash
ls -la /workspace/code_1_outbox/
cat /workspace/code_1_outbox/status.json
```

## Key Rotation Strategy
When delegating work across multiple CODE containers, cycle through keys 1-4 to distribute rate limits:
- CODE-1 → key 1
- CODE-2 → key 2
- CODE-3 → key 3
- CODE-4 → key 4
- CODE-5 → key 1 (cycle)

## Security Notes
- Never log the raw key value.
- The keys are mounted as Docker secrets (read-only, in-memory).
- Each CODE container auto-rotates through all available coding keys internally. VERI does not need to coordinate key selection.
