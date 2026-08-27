# Git Repository Registry

<!--
  Human- and agent-readable registry of all git repositories cloned into the
  shared workspace. Each repo entry describes its purpose, which agents use it,
  branch conventions, and any secret handling rules.

  Keep this file in sync with workspace.repos in <project-root>/install.json
  (the machine-readable comma-separated list consumed by deployment scripts).

  {OWNER_SHORT_NAME} owns the registry; agents may suggest additions but do not remove
  entries without approval.
-->

## Active Repositories

### intersite-orchestrator
* **URL:** https://github.com/{OWNER_GITHUB}/intersite-orchestrator
* **Purpose:** ORCHESTRATOR fleet orchestration, deployment scripts, agent configs, Pester tests, and infrastructure definitions.
* **Agents:** All (ORCH, VERI, BASE, CODE)
* **Branch:** `main`
* **Secrets:** None committed; all credentials injected via AWS Secrets Manager → Docker Swarm secrets → container env vars.
* **Notes:**
  * This is the **control repo** — contains `AGENTS-Code.md`, workflow definitions in `Skills/Workflows/`, and all 41 ADRs in `docs/Reference/Decisions/`.
  * Cloned into the shared workspace volume so fleet agents can access its documentation at runtime.
  * `mcp_opencode` entrypoint automatically prefers this repo as its working directory, making `AGENTS-Code.md` and workflow files resolvable by relative path.
  * Contains `Modules/ORCHESTRATOR.Deprecated/` for preserved legacy patterns.

---

### clocklobster-site
* **URL:** https://github.com/{OWNER_GITHUB}/clocklobster-site
* **Purpose:** {OWNER_BUSINESS_NAME} public website (business presence, contact info, service descriptions).
* **Agents:** CODE/BASE (builds, content updates), ORCH (strategy, copy review)
* **Branch:** `main`
* **Secrets:** None
* **Notes:** Static site.

---

### intersite-docs
* **URL:** https://github.com/{OWNER_GITHUB}/intersite-docs
* **Purpose:** Shared documentation and knowledge base for the intersite project.
* **Agents:** CODE (writing), VERI (audit, accuracy checks)
* **Branch:** `main`
* **Secrets:** None
* **Notes:** Markdown-based docs.

---

### resume
* **URL:** https://github.com/{OWNER_GITHUB}/resume
* **Purpose:** Personal resume / CV.
* **Agents:** CODE (updates, formatting), ORCH (job-application coordination)
* **Branch:** `main`
* **Secrets:** None
* **Notes:** Static site or PDF generation.

---

## Synchronization Checklist

When adding or removing a repo:
1. Update **this file** (`Skills/ORCHESTRATOR/Personas/Shared/git-repos.md`).
2. Update `workspace.repos` in `<project-root>/install.json`.
3. Re-run `Scripts/0setup.ps1` (or manually `docker service update` the relevant service env vars) so the fleet picks up the change.

## Historical / Archived

*None yet.*
