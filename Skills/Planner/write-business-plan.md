# Skill: Write Business Plan & SaaS Architecture

**Purpose:** Transform a SaaS or service business idea into a structured business plan + technical architecture document. Produces two files in the `Business Plans/<business-name>/` tree and follows a consistent template.

> **Location note (2026-07-27):** The `Business Plans/` directory now lives in the **`intersite-docs` repo**, not in `salmon-orchestrator`. All `Business Plans/…` paths below are relative to `C:\Repos\intersite-docs\` — i.e. `../../../../intersite-docs/Business Plans/` from this skill file's location.

**Prerequisites:** Write access to `../../../../intersite-docs/Business Plans/` directory. Familiarity with the ORCHESTRATOR proxy and fleet architecture if the SaaS integrates with it.

**Output rule:** Always create two files (under `intersite-docs/Business Plans/`):
- `Business Plans/<business-name>/<business-name>-plan.md` — Business strategy (market, pricing, GTM, ops)
- `Business Plans/<business-name>/<business-name>-saas.md` — Technical architecture (infra, data flow, security, scaling)

---

## Phase 1 — Discover

When told "write this business plan" or similar, first ask or infer:

1. **Business name** — What is this venture called? (e.g., "cannabis-farmgate", "compliance-bot")
2. **Core product** — One-line description of what it does
3. **Customer** — Who pays? (ICP)
4. **Integration** — Does this use ORCHESTRATOR proxy/fleet or is it standalone?
5. **Differentiation** — Why not existing solutions?

If the user described the idea in conversation, extract these from context rather than asking again.

## Phase 2 — Research

Check existing reference files for pricing and categorization conventions (in the `intersite-docs` repo):

<!-- doc-lint: exempt -->
- `Business Plans/Research/Categorized-Business-Ideas.md` — Existing category structure
- `Business Plans/<Research|Development>/` — Follow the same format as similar past plans

Before generating files, determine plan status: **Research** (theoretical, low interest) or **Development** (actively pursued). Default to Research if user has not indicated. Confirm with the user before creating files.

## Phase 3 — Write Plan File

Create `<business-name>-plan.md` with these sections:

```markdown
# <Title> — Business Plan

> **Date:** <today>
> **Product:** <one-line>
> **Tech Stack:** <key technologies>

---

## 1. Executive Summary & Value Proposition

Problem → Solution → Unique advantage. 3–5 sentences.

## 2. Ideal Customer Profile (ICP)

Table with: Industry, company size, location, pain points, tech comfort, revenue range.

## 3. Revenue Model

Pricing tiers as a table (setup fee, monthly, annual prepay). Include add-ons.

## 4. GTM Strategy

Primary/secondary channels with specific tactics (e.g., "LinkedIn outbound targeting production managers at licensed producers").

## 5. Operational Milestones

Month-by-month roadmap (Months 1–12). Key deliverables and growth targets.

## 6. Cost Breakdown

Per-client costs (monthly + one-time). Gross margin at each price tier. Shared infrastructure costs.

## 7. Service Delivery Flow

Input → Process → Deliverable. Bullet lists or ASCII diagram.

## 8. Risks & Mitigation

Table: Risk, Mitigation. 4–6 rows covering: payment, security, platform dependency, competition, scaling.

## 9. Pricing Reference

<!-- doc-lint: exempt -->
Cross-reference `Business Plans/Pricing-Reference.md`.
```

## Phase 4 — Write SaaS Architecture File

Create `<business-name>-saas.md` with these sections:

```markdown
# <Title> — Technical Architecture

> **Date:** <today>

---

## 1. Core Infrastructure

### Cloud Provider & Data Residency
Table: Component, Provider, Region, Rationale. Cover: hosting, AI services, storage, DNS.

### Containerization
Describe what runs in Docker vs. bare metal vs. managed services.

### CI/CD
How updates flow from commit to production.

## 2. AI & Automation Layer

### Orchestration Engine
Table: Component, Tool, Role.

### Model Selection
Table: Task, Service, Model/API. Note any LLM dependencies and token cost estimates.

### API Management
Table: API, Endpoint, Auth, Rate Limits. Then Secret registry table.

## 3. Core Data Flow

ASCII or bullet-step diagram of the primary workflow. Document failure modes and fallbacks in a table.

## 4. Environment Configuration

- `.env` variables table (scope: proxy, client site, etc.)
- Docker/secret management approach

## 5. Monitoring & Observability

Table: Signal, Tool, What We Watch. Include sample log entry format if applicable.

## 6. Scaling Strategy

Table: Scale Level, Clients, Infrastructure. Describe horizontal scaling considerations.

## 7. Security & Compliance

Table: Requirement, Implementation. Cover: data residency, encryption, auth, regulatory compliance.
```

## Phase 5 — Finalize

1. Ensure directory `Business Plans/<Research|Development>/<business-name>/` exists in the **`intersite-docs` repo** (create the status subfolder if needed)
2. Write both files using the templates above
3. If this business uses a new `store_api_key`-style secret pattern, update the relevant `ORCHESTRATOR.Secrets` module and `Deploy` module optional-secrets list
4. If the business plan is significant enough, add a reference to it in `intersite-docs/AGENTS.md` under the Local project files table

---

## Example Usage Prompts

| User says | Action |
|-----------|--------|
| "Write this as a business plan" | Discover context from conversation, generate both files |
| "Please write this as a business plan for cannabis farmgate" | Use inferred business name "cannabis-farmgate", generate both files in `Business Plans/Research/` (in `intersite-docs`) |
| "Write a business plan for a compliance bot SaaS" | Ask: Research or Development? Then create `Business Plans/\<Research\|Development\>/compliance-bot/` (in `intersite-docs`) with both files |

## Related Skills & References

- `intersite-docs/Business Plans/Pricing-Reference.md` — Canonical pricing
- `intersite-docs/Business Plans/Research/Categorized-Business-Ideas.md` — Existing business categories
- `docs/Reference/Architecture.md` — ORCHESTRATOR fleet architecture patterns
