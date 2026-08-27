# Skill: Postal Self-Hosted Mail Server

## Service Overview

Postal is an open-source mail delivery platform that replaces services like Sendgrid, Mailgun, and Postmark. It handles both incoming and outgoing email with full control over sender reputation, IP warming, and data privacy. It is the sovereign email solution for ORCHESTRATOR clients in regulated industries.

**Website:** https://docs.postalserver.io
**GitHub:** https://github.com/postalserver/postal

## How This Fits ORCHESTRATOR GTM

Postal provides a zero-per-email-cost email infrastructure for clients who cannot risk third-party data exposure. It is particularly valuable for:
- Cannabis retailers (strict data handling requirements)
- Healthcare providers (PHI protection)
- Legal firms (client confidentiality)
- Any client requiring full data sovereignty

Typical workflow: n8n triggers transactional emails (order confirmations, compliance alerts) via Postal SMTP. Postal handles deliverability while keeping all email metadata on infrastructure the client controls.

## Pricing

**Software:** Free (MIT License)

**Infrastructure costs:**

| Component | Monthly Cost | Notes |
|-----------|-------------|-------|
| VPS (2 CPU, 4GB RAM) | $10-20 | Minimum for small volume |
| VPS (4 CPU, 8GB RAM) | $25-40 | Recommended for production |
| Dedicated IP | $0-5 | Often included with VPS |
| Domain registration | $1-2 | Per sending domain |

**Total:** $10-40/month depending on volume and VPS provider.

**Comparison to managed services:**
- Brevo: $9/mo for 20k emails
- SendGrid: $14.95/mo for 50k emails
- Postal: $20/mo for **unlimited** emails (infrastructure-limited only)

**Break-even point:** Postal becomes cheaper than managed services at ~25k emails/month.

## Required Secrets

These must be stored in AWS Secrets Manager under `ORCHESTRATOR/Production/<Project>`:

| Secret Name | Description | Example Value |
|-------------|-------------|---------------|
| `postal_api_key` | Postal API key for authentication | `live_api_abc123xyz` |
| `postal_smtp_password` | SMTP password for sending | `smtp_pass_def456uvw` |
| `postal_server_id` | Postal server identifier | `srv_12345` |
| `postal_base_url` | Your Postal instance URL | `https://mail.clientdomain.com` |

**How to obtain (after installation):**
1. Install Postal on a VPS (see installation guide below)
2. Create an organization and mail server in Postal admin UI
3. Go to Server Settings > API Keys > Create New Key
4. Go to Server Settings > SMTP Credentials > Create Credential
5. Add all values to AWS Secrets Manager

## Installation Guide

### Prerequisites
- VPS with Ubuntu 22.04 or Debian 12
- 2+ CPU cores, 4GB+ RAM
- Dedicated IP address (clean reputation)
- Domain name with DNS access

### Quick Install (Docker)
```bash
# 1. Install Docker
curl -fsSL https://get.docker.com | sh

# 2. Clone Postal
git clone https://github.com/postalserver/postal.git /opt/postal
cd /opt/postal

# 3. Create docker-compose.yml from examples
cp docker-compose.yml.example docker-compose.yml

# 4. Generate configuration
postal bootstrap postal.yourdomain.com

# 5. Start services
docker-compose up -d

# 6. Create admin user
postal make-user
```

### DNS Configuration
Add these records for your sending domain:

| Type | Name | Value | Purpose |
|------|------|-------|---------|
| A | `mail` | `your-server-ip` | Postal web UI |
| MX | `@` | `mail.yourdomain.com` | Incoming mail |
| TXT | `@` | `v=spf1 ip4:your-server-ip ~all` | SPF |
| TXT | `postal._domainkey` | `[DKIM key from Postal UI]` | DKIM |
| TXT | `_dmarc` | `v=DMARC1; p=quarantine; rua=mailto:dmarc@yourdomain.com` | DMARC |

## Agent Usage Instructions

### How to tell an ORCHESTRATOR agent to use Postal

Say to the agent (via Signal/Telegram):

> "Send a transactional email to the customer list using Postal. Subject: 'Your order has shipped'. Use the template at /workspace/templates/shipping-confirmation.html."

The agent will:
1. Fetch `postal_api_key`, `postal_smtp_password`, and `postal_base_url` from AWS Secrets Manager
2. Read the email template from workspace
3. Connect to Postal via SMTP or REST API
4. Send emails to the recipient list
5. Log delivery status and any bounces

### Example agent prompts

**Send transactional email:**
```
Send an order confirmation email via Postal.
To: {{ $json.customer_email }}
From: orders@clientstore.com
Subject: "Order #{{ $json.order_id }} Confirmed"
Template: /workspace/templates/order-confirmation.html
Variables: order_id, customer_name, items, total
```

**Check delivery status:**
```
Check Postal delivery status for emails sent in the last 24 hours.
Show: sent, delivered, bounced, opened.
Report any bounces to me immediately.
```

**Create new sending domain:**
```
Add a new sending domain to Postal: "promotions.clientstore.com"
Generate DKIM keys.
Show me the DNS records I need to add.
```

### What the agent needs from you

- Recipient list or criteria
- Email subject and body (or template path)
- Sending domain (must be configured in Postal)
- Whether to track opens/clicks
- Priority (transactional vs marketing)

## API Reference for Agents

**Base URL:** `{postal_base_url}/api/v1`

**Authentication:** API key in `X-Server-API-Key: {postal_api_key}` header

**SMTP settings:**
- Host: `{postal_base_url}` (or mail subdomain)
- Port: `587` (STARTTLS) or `465` (SSL/TLS)
- Username: `{postal_server_id}` or SMTP credential username
- Password: `{postal_smtp_password}`

**Key endpoints:**

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/messages` | POST | Send email via API |
| `/messages/{id}` | GET | Get message status |
| `/messages/{id}/deliveries` | GET | Get delivery attempts |
| `/send/raw` | POST | Send raw MIME message |
| `/domains` | GET | List configured domains |
| `/domains` | POST | Add new domain |

## n8n Integration

Use the core **Send Email** node with SMTP credentials, or the **HTTP Request** node for REST API access.

**SMTP node configuration:**
- SMTP server: `{postal_base_url}`
- Port: `587`
- SSL/TLS: `true`
- User: `{postal_server_id}`
- Password: `{postal_smtp_password}`

## Troubleshooting

- **"Connection refused"**: Postal may not be running. SSH to VPS and run `docker-compose ps`.
- **"Authentication failed"**: Check SMTP credentials in Postal admin UI.
- **"Emails landing in spam"**: Verify SPF, DKIM, and DMARC records. Check IP reputation on MXToolbox.
- **"High bounce rate"**: Stop sending immediately. Verify list quality. Check if IP is blacklisted.
- **"Postal UI inaccessible"**: Check firewall rules. Port 80/443 must be open.

## Maintenance Tasks

The agent can be asked to perform these maintenance tasks:

- **IP reputation check**: "Check our Postal IP reputation on Spamhaus and Barracuda"
- **Log rotation**: "Archive Postal logs older than 30 days"
- **Certificate renewal**: "Verify Postal SSL certificate is valid and auto-renewing"
- **Update**: "Check for Postal updates and plan upgrade window"

## Related Skills
- `brevo.md` (managed email alternative)
- `smartlead.md` (cold email campaigns)
- `instantly.md` (cold email campaigns)
