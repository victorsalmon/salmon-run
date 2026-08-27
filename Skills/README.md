# Skills Taxonomy

This directory contains the canonical agent skills for the salmon-orchestrator project. Each skill is a markdown file, PowerShell utility, or thin pointer that tells an agent how to perform a specific task.

The `Skills/skills.json` manifest is the source of truth. The role each skill belongs to is determined by its `plugin` field. The interactive roles page at `C:\Users\RDP\salmon-orchestrator-roles.html` is generated from that manifest.

## Top-level roles

| Role | What it does |
|------|--------------|
| **Intake** | Gathers evidence and splits work into `Tasks/Code/` plans or `Tasks/Handoff/` cowork-resumption stubs before coding begins. |
| **Planner** | Discovers scope, resolves blocking decisions, writes session plans, and produces planning artifacts such as wayfinder maps and session-plan filenames. |
| **Coder** | Claims ready plans from `Tasks/Code/`, implements them, and moves the result to `Tasks/Review/`. |
| **Reviewer** | Audits completed session plans for correctness, integration, and professional grooming. Moves the result to `Tasks/Lint/` for the Linter pass. |
| **Reviewer / Linter** | Secondary lint-and-validate workflow under Reviewer. Drains `Tasks/Lint/`, applies `fix-code-smell` to remove code smell, runs documentation lint and `opencode/secret-audit`, builds the project, runs unit tests, then runs mutation testing on those unit tests. Moves passing work to `Tasks/Complete/` and failing work back to `Tasks/Code/`. |
| **Auditor** | Security, architecture, and operational audits; also code-health grooming such as `fix-code-smell`. |
| **Cowork** | Interactive, pair-work sessions with the user. Includes handoff generation, IQA, and the RunFix interactive fix loop. |
| **Orchestrator** | Drains task queues, spawns Coder/Reviewer agents, monitors fleet health, rescues stale work, and owns the shared operational references used by all agents (role routing, tool baseline, config, model-cost analysis, OpenRouter). |
| **Create** | Authoring and design work that is not product code. Sub-roles: **Write**, **Design**, **Skill-Authoring**. |
| **DevOps** | Building, deploying, and operating the fleet. Sub-roles: **Build**, **Fleet**, **Web**, **Playwright**, **Lifecycle**, **Output**. |
| **Research Tools** | Repo discovery, LLM appraisal, and general research tooling. |
| **MCP Tooling** | MCP catalog, server definitions, and cross-harness plugins. |
| **Infrastructure & AWS** | AWS CLI, Secrets Manager, IAM, SSO, and credential-safety conventions. |
| **Bookkeeper** | End-to-end bookkeeping: statements, receipts, categorization, Zoho operations, and tax filing. |
| **Reconcile Account** | Account-reconciliation entry point and bookkeeper-domain runbook plugin. |
| **Marketing Outreach** | Marketer workflows, cold outreach, and CRM/Attio operations. |
| **OpenClaw Agent** | OpenClaw project initiation and OpenClaw agent personas. Distinct from the orchestration personas used by the ORCHESTRATOR fleet. |
| **AQE** | Agentic Quality Engineering — 4C bug fixing, coverage, mutation testing, and quality gates. Sub-roles: **4C Quality & Bugfix**, **MCP**. |
| **Therapy** | Interactive therapeutic support. |

## Sub-roles

### Create

| Sub-role | What it does |
|----------|--------------|
| **Create/Write** | Documentation bundles and other written content. |
| **Create/Design** | Styling and visual design for app and site pages. |
| **Create/Skill-Authoring** | Writing new skills, maintaining workflow primitives, and keeping the skill registry healthy (stale-skill checks, index generation, installation). |

### DevOps

| Sub-role | What it does |
|----------|--------------|
| **DevOps/Build** | Building and deploying code, CI pipelines, deploy tests, and build-fix loops. |
| **DevOps/Fleet** | Docker/Swarm runtime, compose, container onboarding, fleet health, RDP, secrets, and fleet-side troubleshooting. |
| **DevOps/Web** | Web research, Tavily, Firecrawl, web MCPs, and non-browser web tooling. |
| **DevOps/Playwright** | Browserless and Playwright browser automation, receipt downloaders, and site-specific scripts. |
| **DevOps/Lifecycle** | Deprecating, retiring, or shelving components. |
| **DevOps/Output** | Compressed communication modes such as caveman. |

### AQE

| Sub-role | What it does |
|----------|--------------|
| **AQE/4C Quality & Bugfix** | Rigorous Concern-Cause-Countermeasure-Check bug fixing and AQE quality gates. |
| **AQE/MCP** | MCP server for Agentic Quality Engineering. |

### Reviewer

| Sub-role | What it does |
|----------|--------------|
| **Reviewer** | Interactive review workflow. Claims from `Tasks/Review/` and moves to `Tasks/Lint/`. |
| **Reviewer/Linter** | Lint-and-validate workflow. Applies `fix-code-smell`, runs docs/secret lint, builds, runs unit tests, and runs mutation testing. Moves from `Tasks/Lint/` to `Tasks/Complete/` on success or back to `Tasks/Code/` on failure. |

## External canonical roles (skills live in other repos)

| Role | What it does |
|------|--------------|
| **Payments (Public)** | VoPay EFT/card integration — canonical files live in `C:\Repos\Public\vopay-client\docs\`. |
| **Databases (upscale-havens)** | Upscale Havens Supabase access, schema sync, and RLS verification — canonical file lives in the `upscale-havens` repo. |

## Task queues

| Queue | Purpose |
|-------|---------|
| `Tasks/Code/` | Plans ready for a Coder. |
| `Tasks/Review/` | Coder output awaiting Reviewer. |
| `Tasks/Lint/` | Reviewer output awaiting the pre-audit Linter pass. |
| `Tasks/Complete/` | Final, linted archive. |

## Physical layout

Most canonical skill files live under `Skills/<role>/`, and mode-workflows live at `Skills/<role>/SKILL.md`.
Sub-role skills live one level deeper: `Skills/<role>/<sub-role>/`.
The legacy catch-alls `Skills/Workflows/`, `Skills/Shared/`, and `Skills/Orchestrator/Personas/Shared/` are split so that the directory tree echoes the role taxonomy.

Some whole domains — especially the bookkeeping pipeline — are best maintained as a runbook plugin under `Plugins/<domain>/` (e.g. `Plugins/Bookkeeping/`) with the same role taxonomy applied inside the plugin.

## Conventions

- Canonical skill content lives under `Skills/<domain>/` or, for full-domain runbook plugins, under `Plugins/<domain>/`.
- Harness-specific thin pointers live in `.devin/skills/`, `.agents/skills/`, `.claude/skills/`, and `.zcode/skills/`. They must not duplicate canonical content.
- When adding, removing, renaming, or reassigning a skill, update `Skills/skills.json` and run `Skills/Create/Skill-Authoring/Scripts/Build-SkillsIndex.ps1`.
