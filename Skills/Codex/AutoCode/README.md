# AutoCode pipeline for Codex

This directory is the canonical, source-controlled home for the AutoCode plugin stack used by Codex. Each child directory is one installable plugin in the pipeline and contains its own `.codex-plugin/plugin.json`.

## Pipeline

```text
Asana task
   ↓
autocode-intake
   ↓ approved plan
autocode-implementation
   ↓ code + tests
autocode-quality
   ↓ green evidence
autocode-delivery
   ↓ reviewable branch / PR / Asana handoff
```

The plugins are intentionally separated by authority boundary. Intake may clarify and plan; implementation may change repository files; quality may block delivery; delivery may prepare a branch or PR. Production deployment, destructive migrations, secret handling, and irreversible external actions remain approval-gated.

## External accounts

### Required for the first milestone

1. A free Asana account with one workspace for engineering tasks.
2. A project in that workspace, for example `AutoCode`, with sections such as `Inbox`, `Ready`, `In Progress`, `Review`, `Blocked`, and `Done`.
3. Your Codex/ChatGPT account, which is already active for this session.

For the normal Asana connector, you should only need to authorize the connector when it is installed. Do not create an Asana developer app or copy a personal access token unless we decide to build a custom Asana MCP server.

### Optional later

- GitHub account/repository access for branches, pull requests, and reviews.
- Sentry account for runtime error triage.
- PostHog account for product telemetry.
- Cloud or hosting credentials for deployment stages.

The first milestone does not require OpenAI API keys, a database account, or deployment credentials.

## Installation model

These folders are canonical source, not automatically active Codex installations. During development, install each plugin from a local marketplace or wire the skill folders into the Codex skill discovery path. Keep the source here under version control and validate every plugin before installation.

## Account setup checklist

- [ ] Create or choose the Asana Free workspace.
- [ ] Create the `AutoCode` project and workflow sections.
- [ ] Add a task containing a clear user outcome and acceptance criteria.
- [ ] Install/connect the Asana plugin in Codex.
- [ ] Test `autocode-intake` with one non-production task.
- [ ] Add GitHub only when delivery should create pull requests.
