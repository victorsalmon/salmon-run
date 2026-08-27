# WORK Container Revival Template

This document preserves the WORK role container pattern for future revival.

## Role Definition

WORK (Artisan) is a general-purpose worker agent:
- Bootstrap: `Artisan` persona
- No Telegram interface
- No gateway password
- No n8n access
- Uses `Agents/WORK/<SOVEREIGNTY>/ORCHESTRATOR.json` for model routing

## Docker Compose Service

```yaml
services:
  oc-WORK-1:
    image: ${ORCHESTRATOR_IMAGE:-ORCHESTRATOR:local}
    hostname: PROJECT-work-1
    deploy:
      resources:
        limits:
          memory: 4G
    networks: [service_net, orchestration_net]
    environment:
      ORCHESTRATOR_INSTANCE_ID: "1"
      ORCHESTRATOR_PROJECT: "PROJECT"
      ORCHESTRATOR_ROLE: "WORK"
      ORCHESTRATOR_AGENT_NAME: "Agent-PROJECT-WORK-1"
    volumes:
      - agent_config_1:/app/.agent:ro
      - agent_persist_1:/home/node/.ORCHESTRATOR
    secrets:
      - instance_1_aws_id
      - instance_1_aws_secret
      - instance_1_gateway_token
```

## IAM Lifecycle

Same as ORCH/VERI:
- Name: `OC-<Project>-WORK-<Id>`
- Policy: sovereignty-specific (`agent-canada.json`, `agent-usa.json`, `agent-global.json`)
- Secrets: `<Prefix>_aws_id`, `<Prefix>_aws_secret`

## Revival Checklist

- [ ] Add WORK to role selection in identity wizard (`0setup.ps1`)
- [ ] Restore WORK service generation in `Generate-FleetCompose`
- [ ] Ensure `Agents/WORK/` directory exists with sovereignty configs
- [ ] Add WORK bootstrap file (bootstrap/WORK.md)
