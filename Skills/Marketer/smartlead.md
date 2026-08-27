# Skill: Smartlead Cold Email Platform

## Service Overview

Smartlead is an AI-native outbound platform for cold email campaigns. It provides unlimited email account connections, built-in warmup, unified inbox management, and AI-powered email writing. It is the recommended entry-level cold email platform for ORCHESTRATOR GTM clients.

**Website:** https://www.smartlead.ai

## How This Fits ORCHESTRATOR GTM

Smartlead is the primary cold email execution layer for the ORCHESTRATOR Go-To-Market stack. It handles:
- Multi-mailbox campaign sending with automatic rotation
- Email warmup to build sender reputation
- Reply tracking and unified inbox management
- AI-powered subject line and body copy generation
- API access for n8n integration

Typical use: n8n pulls leads from Attio CRM, enriches them via Hunter/Dropcontact, then pushes them to Smartlead campaigns via API. Replies flow back through Smartlead webhooks to n8n, which updates Attio and notifies the sales team.

## Pricing Plans

| Plan | Monthly | Annual | Sends/Month | Contacts | Key Features |
|------|---------|--------|-------------|----------|--------------|
| **Base** | $39 | $32.50 | 6,000 | 2,000 | Unlimited accounts, warmup, basic sequences |
| **Pro** | $94 | $78.30 | 90,000 | 30,000 | + CRM access, CSM call |
| **Smart** | $174 | $144.50 | 150,000 | Unlimited | + Premium warmup, full API |
| **Prime** | $379 | $314.60 | 500,000 | Unlimited | + 3 SmartServers, private infra |

**Add-ons:**
- SmartSenders (mailbox setup): $4.50-9/mailbox/month
- Email Verification: $32/6k credits
- SmartDelivery (inbox placement): $49-599/month
- White-label: $29/workspace/month (Pro+)

**Recommendation for ORCHESTRATOR clients:** Start with **Base ($39/mo)** for proof-of-concept. Upgrade to **Pro ($94/mo)** when the client needs CRM integration or exceeds 6k sends.

## Environment Handling

Smartlead integration supports a beta/production environment switch via the `SALES_ENV` environment variable or the `environment` parameter in API requests:

| Environment | Campaign Naming | Behavior |
|-------------|----------------|----------|
| `production` (default) | Campaign name as provided | Full execution — leads imported, campaigns created, emails sent |
| `beta` | Prefixed with `[BETA]` | Dry-run mode — skips Attio imports, tags campaigns for easy identification |

**Setting the environment:**
```powershell
# Per-request (api-proxy POST body)
{ "environment": "beta", "list_id": "..." }

# Global default
$env:SALES_ENV = "beta"
```

**Agent guidance:** When testing new Smartlead workflows, use `environment: "beta"` to avoid accidentally reaching real leads. Switch to `"production"` only after the pipeline has been verified end-to-end.

---

## Required Secrets

These must be stored in AWS Secrets Manager under `ORCHESTRATOR/Production/<Project>`:

| Secret Name | Description | Example Value |
|-------------|-------------|---------------|
| `smartlead_api_key` | Smartlead API key for authentication | `sl_api_abc123xyz` |
| `smartlead_webhook_secret` | Secret for validating inbound webhooks | `whsec_def456uvw` |

**How to obtain:**
1. Sign up at https://app.smartlead.ai/sign-up
2. Complete onboarding (add at least one sending mailbox)
3. Go to Settings > API Keys > Generate New Key
4. Copy the API key and add to AWS Secrets Manager

## Agent Usage Instructions

### How to tell an ORCHESTRATOR agent to use Smartlead

Say to the agent (via Signal/Telegram):

> "Set up a cold email campaign for [Client Name] targeting [industry]. Use Smartlead. The campaign name should be '[Campaign Name]'. Pull leads from Attio list '[List Name]'. Schedule 3 follow-ups over 2 weeks."

The agent will:
1. Fetch the `smartlead_api_key` from AWS Secrets Manager
2. Query Attio for leads in the specified list
3. Create a Smartlead campaign via API
4. Add leads to the campaign
5. Configure follow-up sequences
6. Store campaign ID in memory for tracking

### Example agent prompts

**Create campaign:**
```
Use Smartlead to create a campaign named "Cannabis Retailers Q2".
Target leads from Attio list "Ontario Dispensaries".
Use the email template from /workspace/templates/cannabis-intro.md.
Set 3 follow-ups at days 3, 7, and 14.
```

**Add leads:**
```
Add the 47 leads from yesterday's Attio scrape to Smartlead campaign ID 12345.
Verify emails with Hunter first.
```

**Check replies:**
```
Check Smartlead campaign 12345 for replies in the last 24 hours.
Update Attio records for anyone who replied.
Send me a summary of positive replies.
```

### What the agent needs from you

- Campaign name
- Target audience (Attio list or criteria)
- Email template or copy direction
- Number of follow-ups and timing
- Sending mailbox to use (must be pre-warmed in Smartlead)

## API Reference for Agents

**Base URL:** `https://api.smartlead.ai/v1`

**Authentication:** Bearer token in `Authorization: Bearer {smartlead_api_key}` header

**Key endpoints:**

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/campaigns` | GET | List all campaigns |
| `/campaigns` | POST | Create new campaign |
| `/campaigns/{id}/leads` | POST | Add leads to campaign |
| `/campaigns/{id}/leads` | GET | List leads in campaign |
| `/campaigns/{id}/sequences` | POST | Create email sequence |
| `/inbox/replies` | GET | Fetch replies |
| `/leads/{id}` | GET | Get lead details |

**Webhook events:**
- `lead_replied` -- Lead sent a reply
- `email_opened` -- Lead opened an email
- `email_clicked` -- Lead clicked a link
- `lead_unsubscribed` -- Lead unsubscribed

Webhook URL should be configured in Smartlead dashboard to point at: `https://frad.clocklobster.com/webhook/smartlead`

## Troubleshooting

- **"API key invalid"**: Key may be expired. Regenerate in Smartlead settings.
- **"Mailbox not warmed"**: Campaign will fail. Ensure mailbox has been warming for at least 2 weeks.
- **"Rate limit exceeded"**: Smartlead API allows 100 requests/minute. The agent batches requests automatically.
- **No replies showing**: Check that the webhook URL is correctly configured and the n8n webhook workflow is active.

## Telegram Approval Queue

When an agent needs approval to send a cold email:

1. **You receive a Telegram notification** with the draft content
2. **Review the draft** — check recipient, personalization, call to action
3. **Respond**:
   - `approve` — agent sends the email and logs the result
   - `reject` — agent notes the rejection and closes the request
   - `reject <reason>` — agent logs the reason for future reference
   - `edit <new body>` — agent updates the draft and re-sends for approval
4. **No response within 24h** → agent sends an escalation reminder

All approved sends are logged to Attio as `email_outreach` notes.
All rejected requests are logged as `follow_up` notes with the rejection reason.

## Related Skills
- `attio.md` (CRM integration)
- `hunter.md` (email enrichment)
- `Skills/DevOps/Playwright/browserless.md` (lead scraping)
