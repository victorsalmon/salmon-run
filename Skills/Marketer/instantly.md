# Skill: Instantly Cold Email Platform

## Service Overview

Instantly is an all-in-one cold email and lead generation platform. It features unlimited email account connections, built-in warmup, a 450M+ B2B lead database, AI-powered copywriting, and advanced deliverability tools. It is the premium option for ORCHESTRATOR GTM clients who need lead sourcing in addition to sending.

**Website:** https://instantly.ai

## How This Fits ORCHESTRATOR GTM

Instantly serves as both the lead source AND the cold email execution layer for clients who don't have their own prospect lists. Unlike Smartlead, Instantly includes a massive B2B database with 13+ filters, making it ideal for clients starting from zero.

Typical use: Use Instantly's Lead Finder to build a list of cannabis retailers in Ontario, export to Attio for enrichment, then push back to Instantly for campaign execution. Replies update Attio via n8n webhooks.

## Pricing Plans

### Outreach (Sending)

| Plan | Monthly | Annual | Sends/Month | Contacts | Key Features |
|------|---------|--------|-------------|----------|--------------|
| **Growth** | $47 | $37.60 | 5,000 | 1,000 | Unlimited accounts, warmup, basic sequences |
| **Hypergrowth** | $97 | $77.60 | 100,000 | 25,000 | + A/B testing, advanced scheduling, API |
| **Light Speed** | $358 | $286.30 | 500,000 | 100,000 | + SISR system (dedicated IPs), premium support |
| **Enterprise** | Custom | Custom | 500K+ | 100K+ | + Private deliverability network, dedicated manager |

### Lead Finder (Database)

| Plan | Monthly | Annual | Credits | Key Features |
|------|---------|--------|---------|--------------|
| **Growth** | $47 | $37.60 | 1,500-2,000 | 450M B2B database, 13 filters |
| **Supersonic** | $97 | $87.30 | 5,000-7,500 | + Full profile enrichment |
| **Hyper Credits** | $197 | $177.30 | 10K-200K | + Everything |

**Recommendation for ORCHESTRATOR clients:** 
- If client already has leads: Start with **Growth Outreach ($47/mo)**
- If client needs leads AND sending: Get **Growth Outreach + Growth Lead Finder ($47 + $47 = $94/mo)**
- Scale to **Hypergrowth ($97/mo)** when sending volume exceeds 5k/month.

## Required Secrets

These must be stored in AWS Secrets Manager under `ORCHESTRATOR/Production/<Project>`:

| Secret Name | Description | Example Value |
|-------------|-------------|---------------|
| `instantly_api_key` | Instantly API key for authentication | `inst_api_xyz789abc` |
| `instantly_webhook_secret` | Secret for validating inbound webhooks | `whsec_ghi789rst` |

**How to obtain:**
1. Sign up at https://app.instantly.ai/auth/signup
2. Complete onboarding (connect at least one mailbox)
3. Go to Settings > API > Generate API Key
4. Copy the key and add to AWS Secrets Manager

## Agent Usage Instructions

### How to tell an ORCHESTRATOR agent to use Instantly

Say to the agent (via Signal/Telegram):

> "Find cannabis retailers in Ontario using Instantly Lead Finder. Export the top 50 results to Attio. Then create a cold email campaign in Instantly targeting those leads. Use the template from /workspace/templates/ontario-cannabis.md."

The agent will:
1. Fetch the `instantly_api_key` from AWS Secrets Manager
2. Use Instantly Lead Finder API to search for leads
3. Export results to a temporary file
4. Import leads into Attio CRM
5. Create an Instantly campaign
6. Upload leads to the campaign
7. Configure sequence and follow-ups

### Example agent prompts

**Lead Finder search:**
```
Use Instantly Lead Finder to search for "cannabis dispensary owners" in Ontario, Canada.
Filter by: Company size 1-50 employees, Decision maker title.
Limit to 100 results.
Export to Attio list "Ontario Dispensaries".
```

**Create campaign:**
```
Create an Instantly campaign named "Ontario Cannabis Q2 Outreach".
Use leads from Attio list "Ontario Dispensaries".
Email template: /workspace/templates/cannabis-compliance.md
Schedule: Tuesday-Thursday, 9am EST.
3 follow-ups: day 3, day 7, day 14.
```

**Check performance:**
```
Get Instantly campaign stats for "Ontario Cannabis Q2 Outreach".
Show: sent, opened, replied, bounced.
Update Attio with reply status for each lead.
```

### What the agent needs from you

- Search criteria (industry, location, company size, titles)
- Campaign name
- Email template or copy direction
- Sending schedule and timezone
- Follow-up sequence timing
- Mailbox to use (must be pre-warmed)

## API Reference for Agents

**Base URL:** `https://api.instantly.ai/api/v1`

**Authentication:** Bearer token in `Authorization: Bearer {instantly_api_key}` header

**Key endpoints:**

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/lead/list` | GET | List leads in account |
| `/campaign/list` | GET | List campaigns |
| `/campaign/create` | POST | Create campaign |
| `/campaign/{id}/add-leads` | POST | Add leads to campaign |
| `/campaign/{id}/analytics` | GET | Get campaign stats |
| `/lead-finder/search` | POST | Search lead database |
| `/inbox/replies` | GET | Fetch replies |

**Webhook events:**
- `lead.replied` -- Lead replied to campaign
- `lead.opened` -- Lead opened email
- `lead.clicked` -- Lead clicked link
- `lead.bounced` -- Email bounced
- `lead.unsubscribed` -- Lead unsubscribed

Webhook URL should be configured in Instantly dashboard to point at: `https://frad.clocklobster.com/webhook/instantly`

## Troubleshooting

- **"Lead Finder credits exhausted"**: Upgrade plan or purchase additional credits.
- **"Campaign paused due to high bounce rate"**: Stop campaign immediately. Verify list with Hunter before restarting.
- **"Mailbox not authenticated"**: Reconnect mailbox in Instantly settings. Check OAuth permissions.
- **API rate limit**: 60 requests/minute. The agent automatically batches requests.

## Related Skills
- `attio.md` (CRM integration)
- `hunter.md` (email verification)
- `smartlead.md` (alternative platform)
