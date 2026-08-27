# PROJECTS.md - Shared Project & Client Registry

<!--
  This file gives all agents a common view of active projects, client contexts,
  and business objectives. Each agent reads this at startup alongside USER.md
  and ENVIRONMENT.md. Role-specific lessons stay in each agent's own MEMORY.md;
  this file is for cross-pollination of business context.

  Update this file when projects change status, new clients onboard, or business
  priorities shift. {OWNER_SHORT_NAME} owns the priority order; agents suggest additions but
  do not reorder without approval.
-->

## Active Projects

### ORCHESTRATOR Deployments
* **Owner:** {OWNER_SHORT_NAME}
* **Status:** Active — learning mode
* **Priority:** Primary
* **Description:** Self-hosted and cloud-hosted ORCHESTRATOR deployments for business clients. Revenue through setup fees, hosting, and ongoing support.
* **Current Focus:** Sales and marketing outreach to acquire first 5 paying clients.
* **Key Metrics:** Client count, MRR per deployment, support ticket volume.
* **Agent Notes:** ORCH coordinates outreach and follow-up. CODE/BASE builds landing pages and automation. VERI audits deliverables before client delivery.

---

## Client Registry

<!--
  Add new clients as they onboard. Remove archived clients to the Done section.
  Each entry should have enough context for any agent to pick up a task without
  asking {OWNER_SHORT_NAME} "who is this?"
-->

*No clients yet. Add entries as clients are acquired.*

<!-- Template for new client entries:
### [Client Name]
* **Industry:** [e.g., Real estate, Legal, E-commerce]
* **Onboarded:** [YYYY-MM-DD]
* **Deployment Type:** [Self-hosted mini PC / Cloud instance]
* **Primary Contact:** [Name and preferred channel]
* **Pain Points:** [What problem they're solving with automation]
* **Pricing:** [Monthly or one-time, amount]
* **Open Tasks:** [Active deliverables]
* **Agent Notes:** [Any role-specific context]
-->

---

## Business Objectives

* **Primary:** Grow revenue through ORCHESTRATOR deployments. First milestone: 5 paying clients.
* **Learning Mode:** Currently prioritizing sales and marketing skills. Agents should actively suggest lead generation strategies and help craft outreach.

---

## Sales Pipeline

<!--
  Track leads and outreach status. ORCH owns this pipeline; other agents
  contribute execution (landing pages, copy, data) but do not contact leads
  directly unless ORCH delegates.
-->

| Stage | Description |
|-------|-------------|
| **Prospect** | Identified as a potential client. No contact made. |
| **Outreach** | Initial contact sent (email, DM, referral intro). |
| **Conversation** | Responded and in active dialogue. |
| **Proposal** | Offer sent with pricing and scope. |
| **Closed-Won** | Contract signed, deployment scheduled. |
| **Closed-Lost** | Declined or went dark. Move to archive. |

*No pipeline entries yet. Populate as leads are identified.*

### Beta/Production List Segregation

The sales pipeline uses separate Attio lists for beta testing and production:

| List Name (Production) | List Name (Beta) | Purpose |
|------------------------|------------------|---------|
| `Uncontacted Prospects` | `BETA - Uncontacted Prospects` | Leads identified but not yet contacted |
| `Outreach In Progress` | `BETA - Outreach In Progress` | Leads currently in an outreach sequence |
| `Warm Leads` | `BETA - Warm Leads` | Leads that have engaged positively |
| `Lost Leads` | `BETA - Lost Leads` | Leads that declined or went cold |

**Convention**: Beta lists are prefixed with `BETA - `. Production lists have no prefix.

**Environment parameter**: All sales pipeline endpoints accept an `environment` parameter (`"beta"` | `"production"`, default `"beta"`). This determines which list prefix is used.

**Agent rule**: When creating or querying lists, always specify the environment explicitly. Never assume a default.

---

## Done / Archive

<!--
  Completed projects and churned clients. Keep brief — full context moves
  to individual agent MEMORY.md files.
-->

*None yet.*