# Skill: Brevo Managed Email Service

## Service Overview

Brevo (formerly Sendinblue) is a managed email service providing SMTP, API, and marketing automation. It offers a generous free tier and handles deliverability, IP reputation, and compliance automatically. It is the recommended managed email solution for ORCHESTRATOR clients who want zero infrastructure overhead.

**Website:** https://www.brevo.com

## How This Fits ORCHESTRATOR GTM

Brevo is the fastest path to transactional and marketing email for clients who don't need the sovereignty of self-hosted Postal. It integrates natively with n8n via a verified node, making it ideal for:
- Order confirmations and shipping notifications
- Password resets and account alerts
- Marketing newsletters and promotions
- SMS notifications (via Brevo SMS add-on)

Typical workflow: Shopify webhook → n8n → Brevo node sends order confirmation → Attio logs customer interaction.

## Pricing Plans

| Plan | Monthly | Emails/Month | Contacts | Best For |
|------|---------|-------------|----------|----------|
| **Free** | $0 | 9,000 | Unlimited | Testing, tiny clients |
| **Starter** | $9 | 20,000 | Unlimited | Small transactional volume |
| **Business** | $18 | 100,000 | Unlimited | Growing clients |
| **Enterprise** | Custom | 1M+ | Unlimited | High-volume senders |

**SMS Pricing:** $0.08-0.15 per SMS depending on destination country.

**Add-ons:**
- Landing pages: $15/month
- A/B testing: Included in Business+
- Advanced statistics: Included in Business+

**Recommendation for ORCHESTRATOR clients:** Start with **Free** for testing. Upgrade to **Starter ($9/mo)** when transactional volume exceeds 9k/month. Use **Business ($18/mo)** for clients with marketing email needs.

## Required Secrets

These must be stored in AWS Secrets Manager under `ORCHESTRATOR/Production/<Project>`:

| Secret Name | Description | Example Value |
|-------------|-------------|---------------|
| `brevo_api_key` | Brevo API v3 key | `xkeysib-abc123def456` |
| `brevo_smtp_password` | SMTP master password | `smtp_xyz789abc` |

**How to obtain:**
1. Sign up at https://app.brevo.com/register
2. Go to SMTP & API > API Keys
3. Create a new API v3 key
4. Also copy the SMTP master password
5. Add both to AWS Secrets Manager

## Agent Usage Instructions

### How to tell an ORCHESTRATOR agent to use Brevo

Say to the agent (via Signal/Telegram):

> "Set up a welcome email sequence in Brevo for new customers. Trigger: when a new contact is added to Attio list 'New Customers'. Send immediately, then a follow-up at day 3 and day 7."

The agent will:
1. Fetch `brevo_api_key` from AWS Secrets Manager
2. Design email templates (or read from workspace)
3. Create contact lists in Brevo
4. Set up automation workflows
5. Configure triggers (via n8n webhooks or Attio integration)
6. Test with a small group before full deployment

### Example agent prompts

**Send transactional email:**
```
Send an order shipped notification via Brevo.
To: {{ $json.customer_email }}
From: orders@clientstore.com
Subject: "Your order {{ $json.order_id }} has shipped!"
Template: /workspace/templates/shipping-notification.html
Track opens: yes
Track clicks: yes
```

**Create contact list:**
```
Create a Brevo contact list called "Newsletter Subscribers".
Import contacts from Attio list "Marketing Contacts".
Map Attio fields: email → email, first_name → FIRSTNAME, company → COMPANY.
```

**Send campaign:**
```
Send a newsletter campaign via Brevo to list "Newsletter Subscribers".
Subject: "April Updates from [Client Name]"
Content: /workspace/newsletters/april-2026.md
Schedule: Tomorrow at 10am EST.
```

**Check stats:**
```
Get Brevo campaign stats for the newsletter sent yesterday.
Show: delivered, opened, clicked, bounced, unsubscribed.
```

### What the agent needs from you

- Campaign name and purpose
- Recipient list or criteria
- Email subject and content (or template path)
- From name and email address
- Send timing (immediate or scheduled)
- Whether to track opens/clicks

## API Reference for Agents

**Base URL:** `https://api.brevo.com/v3`

**Authentication:** API key in `api-key: {brevo_api_key}` header

**Key endpoints:**

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/smtp/email` | POST | Send transactional email |
| `/contacts` | POST | Create/update contact |
| `/contacts/lists` | GET | List contact lists |
| `/contacts/lists/{id}/contacts` | POST | Add contacts to list |
| `/emailCampaigns` | POST | Create email campaign |
| `/emailCampaigns/{id}` | GET | Get campaign stats |
| `/senders` | GET | List verified senders |
| `/webhooks` | POST | Create webhook |

## n8n Integration

Brevo has a **native verified node** in n8n.

1. Search "Brevo" in the n8n node panel
2. Create credential:
   - Type: Brevo API
   - API Key: `{brevo_api_key}`
3. Supported operations:
   - Send transactional email
   - Create/update contact
   - Add contact to list
   - Send campaign
   - Get campaign stats

## SMTP Configuration

Use the core **Send Email** node with these settings:
- SMTP server: `smtp-relay.brevo.com`
- Port: `587`
- User: `{brevo_api_key}` (yes, the API key IS the SMTP username)
- Password: `{brevo_smtp_password}`

## Troubleshooting

- **"Invalid API key"**: Key may be expired or wrong version. Use API v3 key from Brevo dashboard.
- **"Sender not verified"**: All sending domains must be verified in Brevo. Go to Senders & IP > Domains.
- **"Daily limit exceeded"**: Free plan = 300 emails/day. Upgrade or wait.
- **"Contact already exists"**: Brevo deduplicates by email. Use update instead of create.
- **Emails in spam**: Check sender reputation. Ensure SPF/DKIM are set up for your domain.

## Comparison to Postal

| Feature | Brevo | Postal |
|---------|-------|--------|
| Cost structure | Per-email tiers | Flat infrastructure cost |
| Free tier | 9k emails/mo | None (infrastructure only) |
| Infrastructure | Managed by Brevo | Self-hosted |
| Data control | Data leaves your stack | Full data sovereignty |
| n8n node | Native verified | SMTP/HTTP only |
| Setup time | 5 minutes | 2-3 hours |
| Deliverability | Managed by Brevo | You manage it |
| Best for | Speed, convenience | Compliance, sovereignty |

## Related Skills
- `postal.md` (self-hosted email alternative)
- `smartlead.md` (cold email campaigns)
- `instantly.md` (cold email campaigns)
- `attio.md` (CRM integration)
