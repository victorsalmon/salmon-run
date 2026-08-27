# CODE Container Revival Template

This document preserves the complete CODE container architecture so it can be restored if needed.

## Dockerfile and Image Build

The CODE worker image is built from `Infrastructure/opencode-worker.Dockerfile`:

```dockerfile
FROM openeuler/opencode:1.1.48-oe2403lts AS opencode-binary
FROM node:20-slim
RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates wget
COPY --from=opencode-binary /usr/local/lib/node_modules/opencode-ai /usr/local/lib/node_modules/opencode-ai
RUN ln -s /usr/local/lib/node_modules/opencode-ai/bin/opencode /usr/local/bin/opencode
COPY Infrastructure/opencode-worker.sh /usr/local/bin/opencode-worker.sh
RUN chmod +x /usr/local/bin/opencode-worker.sh
ENTRYPOINT ["/bin/sh", "/usr/local/bin/opencode-worker.sh"]
```

Build is triggered by `Invoke-OpencodeWorkerImageBuild` in `0setup.ps1` Phase 12. It computes a source hash from the Dockerfile and any COPY'd files to skip rebuilds when unchanged.

## Entrypoint Lifecycle

`opencode-worker.sh` performs:
1. Creates inbox/outbox directories
2. Starts HTTP health endpoint (port 3000, JSON status)
3. Configures git identity
4. Clones/pulls shared repos into `/workspace/`
5. Enters main loop watching `$INBOX/*.trigger`
6. On trigger: acquires file lock, runs `opencode run --file`, tries keys 1-4 on failure
7. Commits results to git, moves files to outbox

## Docker Compose Service

```yaml
services:
  code-1:
    image: opencode-worker:local
    hostname: PROJECT-code-1
    deploy:
      resources:
        limits:
          memory: 3G
    networks: [service_net, orchestration_net]
    environment:
      CODE_ID: "1"
      OPENCODE_GIT_NAME: "OpenCode 1"
      OPENCODE_GO_KEY: "${OPENCODE_GO_KEY1:-}"
    volumes:
      - interclaw_workspace:/workspace
      - code_1_inbox:/workspace/code_1_inbox
      - code_1_outbox:/workspace/code_1_outbox
    secrets:
      - code_1_aws_id
      - code_1_aws_secret
      - opencode_go_key1
      - opencode_go_key2
      - opencode_go_key3
      - opencode_go_key4
    ports:
      - "127.0.0.1:30200:3000"
```

## Key Cycling Pattern

The worker tries keys sequentially:
1. `OPENCODE_GO_KEY` (mapped key for this instance)
2. `OPENCODE_GO_KEY1`
3. `OPENCODE_GO_KEY2`
4. `OPENCODE_GO_KEY3`
5. `OPENCODE_GO_KEY4`

On auth/rate-limit errors (`401`, `429`, `quota exceeded`, etc.), it automatically tries the next key. This provides resilience against single-key rate limits.

## IAM User Lifecycle

CODE containers have their own IAM users:
- Name: `OC-<Project>-CODE-<Id>`
- Policy: `agent-global.json` (same as agents)
- Secrets: `<Prefix>_aws_id`, `<Prefix>_aws_secret`
- Created by `1Provision.ps1 -Phase AWS`

## Drone Scaling API

The maintenance drone exposes `POST /scale` at `http://maintenance-drone:29999/scale` for elastic CODE container scaling. ORCH agents call this endpoint instead of accessing docker.sock directly.

## Revival Checklist

- [ ] Copy worker files back to `Infrastructure/`
- [ ] Restore `Invoke-OpencodeWorkerImageBuild` to `Modules/ORCHESTRATOR.Deploy/Public/`
- [ ] Restore CODE service generation in `Generate-FleetCompose`
- [ ] Restore CODE IAM provisioning in `1Provision.ps1`
- [ ] Restore CODE volume creation in `Initialize-AgentVolumes.ps1`
- [ ] Restore `INSTALL_OPENCODE` toggle in identity wizard
- [ ] Restore drone scaling API in `Start-DroneHealthListener.ps1`
- [ ] Add CODE-specific tests back from `Modules/ORCHESTRATOR.Deprecated/Tests/`
