# Skill: Attio CRM

## Service Overview

Attio is a data-driven, customizable CRM built around objects (People, Companies, Deals, Notes) and lists. Unlike traditional CRMs, Attio is designed to be molded to your specific business process. It has a full REST API, webhooks, and an App SDK for embedded React applications.

**Website:** https://attio.com

## How This Fits ORCHESTRATOR GTM

Attio is the central nervous system of the ORCHESTRATOR Go-To-Market stack. It stores all leads, contacts, companies, and deals. Every other tool (Smartlead, Hunter, Browserless) pushes data into Attio or pulls data from it.

**Typical data flow:**
- Browserless scrapes leads → Attio stores companies and contacts
- Hunter enriches emails → Attio updates contact records
- Smartlead sends cold emails → Attio tracks "Contacted" / "Replied" status
- n8n workflows read/write Attio records to orchestrate the entire pipeline

## Pricing Plans

| Plan | Price | Users | Records | API | Best For |
|------|-------|-------|---------|-----|----------|
| **Free** | $0 | Unlimited | Unlimited | Full API | Solo operators, testing |
| **Plus** | $29/user/mo | Unlimited | Unlimited | Full API + webhooks | Small teams |
| **Pro** | $59/user/mo | Unlimited | Unlimited | Everything + App SDK | Growing agencies |
| **Enterprise** | Custom | Unlimited | Unlimited | Everything + SLA | Large teams |

**Recommendation for ORCHESTRATOR clients:** Start with **Free** ($0). It includes unlimited records and full API access. Upgrade to **Plus ($29/user)** only when you need webhooks or have multiple team members.

## Required Secrets

These must be stored in AWS Secrets Manager under `ORCHESTRATOR/Production/<Project>`:

| Secret Name | Description | Example Value |
|-------------|-------------|---------------|
| `attio_api_key` | Attio REST API key | `api_key_abc123def456` |

**How to obtain:**
1. Sign up at https://app.attio.com (use your work email)
2. Go to Settings > API & Integrations > API Keys
3. Click "Generate new key"
4. Copy the key and add to AWS Secrets Manager:
   ```bash
   aws secretsmanager create-secret \
     --name "ORCHESTRATOR/Production/FRAD/attio_api_key" \
     --secret-string "your_key_here"
   ```

## Agent Usage Instructions

### How to tell an ORCHESTRATOR agent to use Attio

Say to the agent (via Signal/Telegram):

> "Add the 20 leads from /workspace/leads/ontario-dispensaries.csv to Attio. Create company records for each, then create contact records with their emails. Tag them all with source 'Web Scrape - Ontario'."

The agent will:
1. Fetch the `attio_api_key` from AWS Secrets Manager
2. Read the CSV file
3. Create company records via `POST /v2/objects/companies/records`
4. Create people records via `POST /v2/objects/people/records`
5. Add them to a list via `POST /v2/lists/{list_id}/entries`
6. Report back with created record IDs

### Example agent prompts

**Create a company:**
```
Create a company in Attio:
Name: GreenLeaf Cannabis Co.
Domain: greenleafcannabis.ca
Address: 123 Main St, Toronto, ON
Source: Cold Email Campaign Q2
```

**Create a contact:**
```
Create a person in Attio:
Name: John Smith
Email: ***REMOVED-EMAIL***
Company: GreenLeaf Cannabis Co.
Title: Store Manager
Source: Hunter.io enrichment
```

**Update lead status:**
```
Update the status of ***REMOVED-EMAIL*** to "Replied" in Attio.
Add a note: "Interested in compliance consulting. Wants to schedule call next week."
```

**Query records:**
```
Fetch all contacts from Attio list "Cold Prospects" where status is "Uncontacted".
Limit to 50 records.
Export to /workspace/leads/uncontacted-prospects.csv.
```

**Create a note:**
```
Add a note to GreenLeaf Cannabis Co. in Attio:
"Called on 2026-04-28. Spoke with John. They are expanding to 3 new locations and need compliance help. Budget confirmed. Follow up in 1 week."
```

#### Note Type Taxonomy

Always specify a `type` when creating notes. This enables continuity queries.

| Type | Example Content |
|------|----------------|
| `email_outreach` | "Sent cold email re compliance consulting. Mentioned ROI benchmarks." |
| `email_reply` | "John replied — interested in a discovery call next week." |
| `call` | "Called John. Discussed compliance roadmap. Follow-up: send case studies." |
| `meeting` | "Discovery call completed. Demo scheduled for May 20." |
| `follow_up` | "Send case study PDF to John by Friday. He specifically asked about." |
| `outreach` | "Sent LinkedIn connection request." |

#### Continuity Queries

```markdown
## Restore context for session
## Attio: find last 5 email_reply notes from last 7 days
## Attio: find last 3 follow_up notes where action is not resolved
## Check memory/<last-active-date>.md for decision records
```

### What the agent needs from you

- Record type (company, person, deal, note)
- Field values (name, email, domain, etc.)
- List to add records to (optional)
- Any tags or custom attributes

## API Reference for Agents

**Base URL:** `https://api.attio.com`

**Authentication:** Bearer token in `Authorization: Bearer {attio_api_key}` header

**Key endpoints:**

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/v2/objects/people/records` | POST | Create a person/contact |
| `/v2/objects/people/records/query` | POST | Query/filter people |
| `/v2/objects/companies/records` | POST | Create a company |
| `/v2/objects/companies/records/query` | POST | Query/filter companies |
| `/v2/lists` | GET | List all lists |
| `/v2/lists/{id}/entries` | POST | Add record to list |
| `/v2/lists/{id}/entries/query` | POST | Query list entries |
| `/v2/notes` | POST | Create a note on a record |
| `/v2/webhooks` | POST | Subscribe to record change events |

**Standard objects:**
- `people` -- Contacts, leads, customers
- `companies` -- Organizations, accounts
- `deals` -- Opportunities, sales pipeline
- `notes` -- Activity logs, call notes

**Common attributes:**
- `email_addresses` -- Array of email objects
- `domains` -- Array of domain objects
- `name` -- Display name
- `job_title` -- Role/position
- `status` -- Custom status (Uncontacted, Contacted, Replied, etc.)

## n8n Integration

Attio does not have a native n8n node. Use the **HTTP Request** node with Header Auth.

**Credential setup:**
1. In n8n: Settings > Credentials > HTTP Header Auth
2. Name: `Attio API Key`
3. Header Name: `Authorization`
4. Header Value: `Bearer {attio_api_key}`

**Example HTTP Request node:**
- Method: `POST`
- URL: `https://api.attio.com/v2/objects/people/records`
- Authentication: HTTP Header Auth (Attio API Key)
- Body: JSON with record data

## Attio List Setup for GTM

Recommended lists for ORCHESTRATOR clients:

| List Name | Purpose | Typical Records |
|-----------|---------|----------------|
| **Cold Prospects** | Uncontacted leads for outbound | Companies + People |
| **Warm Leads** | Replied or engaged leads | People |
| **Customers** | Active paying customers | Companies |
| **Partners** | Strategic partners, vendors | Companies |
| **Lost Deals** | Archived opportunities | Companies + Deals |

### List Naming

Beta testing leads go to `BETA - <ListName>` lists. Production leads go to `<ListName>` lists. Use the `environment` parameter in api-proxy calls.

### Continuity Workflow

See `Skills/ORCHESTRATOR/Personas/Shared/protocols.md` § Continuity Protocol for the full protocol. In summary:

1. After any outreach: **log a note in Attio with type**
2. Before resuming: **query Attio for recent context**
3. Document decisions: **write to daily memory**
4. Never leave context in your head — if it's not in a file, it doesn't exist

## Troubleshooting

- **"API key invalid"**: Key may have been revoked. Generate a new one in Attio settings.
- **"Object not found"**: Check object slug. Use `people`, `companies`, `deals`, not custom names.
- **"Rate limit exceeded"**: Attio API allows 100 requests/minute. The agent batches requests automatically.
- **"Record already exists"**: Attio deduplicates by email for people and domain for companies. Update instead of create.
- **"Attribute not found"**: Custom attributes must be created in Attio UI first before the API can set them.

## Related Skills
- `smartlead.md` -- For sending campaigns to Attio leads
- `instantly.md` -- Alternative campaign platform
- `hunter.md` -- For enriching Attio records with emails
- `Skills/DevOps/Playwright/browserless.md` -- For scraping leads into Attio
- `postal.md` / `brevo.md` -- For transactional emails to Attio contacts

---

*Skill version 1.0. Update when Attio releases native n8n integration or new API features.*
