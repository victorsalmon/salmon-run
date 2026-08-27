# Skill: Hunter.io Email Finder

## Service Overview

Hunter.io is an email finding and verification service. It discovers professional email addresses by domain or name, verifies deliverability, and provides confidence scores. It is the primary email enrichment tool for the ORCHESTRATOR GTM stack.

**Website:** https://hunter.io

## How This Fits ORCHESTRATOR GTM

Hunter bridges the gap between scraped lead data and actionable contact information. When the agent scrapes a list of companies from a directory, Hunter finds the decision-maker emails so Smartlead/Instantly can actually reach them.

Typical workflow: Browserless scrapes company list → Hunter finds emails by domain → Dropcontact verifies deliverability → Attio stores enriched records → Smartlead sends campaign.

## Pricing Plans

| Plan | Monthly | Annual | Searches | Verifications | Best For |
|------|---------|--------|----------|---------------|----------|
| **Free** | $0 | $0 | 25 | 50 | Testing, tiny campaigns |
| **Starter** | $49 | $34 | 500 | 1,000 | Single client, moderate volume |
| **Growth** | $99 | $69 | 2,500 | 5,000 | Multiple clients, daily enrichment |
| **Pro** | $199 | $139 | 10,000 | 20,000 | Agency, high-volume |
| **Enterprise** | $399 | $279 | 30,000 | 60,000 | Large agency, bulk operations |
| **Business** | Custom | Custom | Custom | Custom | Enterprise with SLA |

**Note:** Free tier is 25 searches/month and 50 verifications/month. This is enough for testing but will be exhausted quickly in production.

**Recommendation for ORCHESTRATOR clients:** Start with **Starter ($49/mo)** for the first client. Upgrade to **Growth ($99/mo)** when managing 3+ clients or doing daily lead scraping.

## Required Secrets

These must be stored in AWS Secrets Manager under `ORCHESTRATOR/Production/<Project>`:

| Secret Name | Description | Example Value |
|-------------|-------------|---------------|
| `HUNTER_API_KEY` | Hunter.io API key | `a1b2c3d4e5f6g7h8i9j0` |

**How to obtain:**
1. Sign up at https://hunter.io/signup
2. Go to Dashboard > API > API Keys
3. Copy your API key
4. Add to AWS Secrets Manager under `ORCHESTRATOR/Production/<Project>` as `HUNTER_API_KEY`

## Agent Usage Instructions

### How to tell an ORCHESTRATOR agent to use Hunter

Say to the agent (via Signal/Telegram):

> "Verify the email list for the Ontario dispensaries campaign using Hunter. I need to make sure these emails are deliverable before we send."

The agent will:
1. Fetch the `HUNTER_API_KEY` from AWS Secrets Manager
2. Read the lead list from workspace or Attio
3. Call Hunter API for each email/domain
4. Filter out undeliverable emails (confidence < 80% or status != "deliverable")
5. Update Attio records with verification status
6. Report: "X of Y emails verified as deliverable. Z removed."

### Example agent prompts

**Domain search:**
```
Find email addresses for decision makers at these 20 cannabis companies:
/workspace/leads/ontario-dispensaries.csv
Use Hunter domain search. Get the highest-confidence emails.
```

**Email verification:**
```
Verify these 50 emails before the Smartlead campaign:
/workspace/leads/emails-to-verify.csv
Use Hunter Email Verifier. Remove any with status "undeliverable" or "risky".
```

**Single lookup:**
```
Find the email for John Smith at GreenLeaf Cannabis Co.
Use Hunter. If not found, try pattern guessing then verify.
```

### What the agent needs from you

- List of domains or emails to process
- Minimum confidence threshold (default: 80%)
- Whether to accept "risky" emails (default: no)
- Output destination (Attio list, CSV file, etc.)

## API Reference for Agents

**Base URL:** `https://api.hunter.io/v2`

**Authentication:** API key as query parameter `?api_key={HUNTER_API_KEY}`

**Key endpoints:**

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/domain-search` | GET | Find emails by domain |
| `/email-finder` | GET | Find email by name + domain |
| `/email-verifier` | GET | Verify deliverability of an email |
| `/email-count` | GET | Count emails for a domain |
| `/account` | GET | Check API usage and limits |

**Response fields the agent uses:**
- `data.emails[].value` -- The email address
- `data.emails[].confidence` -- Confidence score (0-100)
- `data.emails[].type` -- "personal" or "generic"
- `data.emails[].position` -- Job title
- `data.status` -- "deliverable", "undeliverable", "risky", "unknown"

## Integration Patterns

### With Browserless (scraping)
```
Scrape directory → Extract domains → Hunter domain-search → 
Get top 2-3 emails per company → Verify with Hunter → Store in Attio
```

### With Smartlead/Instantly
```
Attio export → Hunter verify → Filter deliverable → 
Smartlead add-leads → Campaign send
```

### Standalone enrichment
```
CSV upload → Hunter batch verify → Clean CSV → 
Download for manual import
```

## Rate Limits & Costs

- **Domain Search:** 1 credit per search
- **Email Finder:** 1 credit per search
- **Email Verifier:** 1 credit per verification
- **Rate limit:** 100 requests/minute on paid plans
- **The agent batches requests** to stay within limits and minimize cost.

## Troubleshooting

- **"No emails found"**: Domain may not be in Hunter's database. Try pattern guessing or LinkedIn scraping.
- **"API key invalid"**: Key may have been revoked. Generate a new one in Hunter dashboard.
- **"Rate limit exceeded"**: The agent automatically backs off and retries. If persistent, upgrade plan.
- **Low confidence scores**: For domains with <50% confidence, the agent will flag for manual review rather than auto-accept.

## Related Skills
- `smartlead.md` (campaign sending)
- `instantly.md` (campaign sending + lead finding)
- `Skills/DevOps/Playwright/browserless.md` (lead scraping)
- `attio.md` (CRM storage)
