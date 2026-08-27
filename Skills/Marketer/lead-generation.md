# Lead Generation Strategy — ORCHESTRATOR Intersite

**Owner:** Marketer bundle  
**Scope:** Attio CRM + api-proxy + external enrichment APIs  
**Last Updated:** 2026-04-30

---

## 1. Current Capabilities (Deployed)

The api-proxy service currently handles 4 workflow integrations with Attio. These are configured via `Scripts/0config.ps1` post-deploy.

### Active Workflows

| Workflow | Trigger | Attio Action | Keys Used |
|----------|---------|--------------|-----------|
| **Lead Scraping Pipeline** | Schedule (every 6h) | Creates Company + Person records | `ATTIO_WRITE_KEY` |
| **Cold Email Campaign** | Schedule (daily) + Smartlead webhook | Reads prospects, archives bounced/invalid | `ATTIO_READ_KEY`, `ATTIO_ARCHIVE_KEY` |
| **AI Email Reply** | Support email webhook | Reads customer context for drafting | `ATTIO_READ_KEY` |
| **Photo-to-Inventory** | S3 image upload | Creates product records | `ATTIO_WRITE_KEY` |

### Current Pipeline: Lead Scraping

```
Schedule (every 6h)
    |
    v
Browserless (headless browser) — scrape target directory
    |
    v
Extract domains from company websites
    |
    v
Hunter.io API — find emails by domain (confidence score)
    |
    v
Filter — only keep emails >= 80% confidence
    |
    v
Attio Write API — create Company + Person records
    |
    v
Signal notification
```

**What this gives you:** Automated list building from any public directory (trade associations, Clutch, Yelp, AngelList, etc.) with verified contact data.

---

## 2. Selected Software Stack

**Decision made:** Best-of-breed approach — each tool chosen for its specific strength.

### Active Configuration (Keys in AWS SM)

| Tool | Role | Why Selected | Free Tier | Paid Cost |
|------|------|-------------|-----------|-----------|
| **Browserless** | Headless browser scraping | Best for automated directory scraping | 1,000 sessions/mo | $20/mo |
| **Apollo.io** | Email finding + enrichment | Largest B2B database, dual-key flexibility | 50 requests/mo | $59/mo |
| **ZeroBounce** | Email verification | Industry-standard accuracy, protects sender reputation | 100 credits/mo | $16/2k credits |
| **Signal** | Pipeline notifications | Team alerts on pipeline events | End-to-end encrypted | Free tier |

### Pending Configuration

| Tool | Role | Why Needed | Cost |
|------|------|-----------|------|
| **Smartlead** | Cold email sending + reply tracking | Best-in-class deliverability + warmup. No viable alternative for cold outreach automation. | $37/mo |

### Rejected Alternatives

| Tool | Why Rejected |
|------|-------------|
| **Hunter.io** | Apollo `APOLLO_SEARCH` key provides equivalent domain-based email finding with additional firmographic context. No additional signup needed. |
| **Snov.io** | All-in-one approach compromises on deliverability. Smartlead's warmup and multi-inbox rotation are superior for cold email. |
| **Instantly** | Comparable to Smartlead in performance, but existing `attio-cold-email.json` workflow is already built for Smartlead. |
| **Apollo sequences** | Built-in sender lacks dedicated warmup and deliverability optimization. Risky for cold outreach at scale. |
| **AWS SES DIY** | Requires 2-3 weeks of custom development (warmup, bounce handling, suppression). Not viable for immediate use. |

---

## 2a. Hunter Alternatives (Email Discovery)

Since Hunter.io is not currently configured, here are alternatives — including some that may already be covered by Apollo:

### Option 1: Use Apollo.io (Already Have Keys)

Apollo's `APOLLO_SEARCH` key can find emails as part of its people search. This is the **zero-additional-cost option**.

**Pros:** Already configured, no extra signup  
**Cons:** 50 requests/mo free limit (same as Hunter), slightly less focused on email-only discovery  
**When to use:** If your primary need is finding emails + firmographics in one call

**Example API call:**
```
Method: POST
URL: https://api.apollo.io/v1/mixed_people/search
Headers: Authorization: Bearer {{$env.APOLLO_SEARCH}}
Body: {"q_organization_domains": ["example.com"], "person_titles": ["CEO", "Founder"]}
```

### Option 2: Snov.io (Best Free Tier)

| Feature | Details |
|---------|---------|
| Free tier | 50 credits/mo (1 credit = 1 email found) |
| Paid | $39/mo for 1,000 credits |
| API | REST API with good documentation |
| Special | Chrome extension for LinkedIn email finding |

**Why Snov.io:** Better free tier than Hunter (same 50 requests but includes verification), Chrome extension is useful for manual prospecting, good API for automation.

**Signup:** snov.io → Free account → API section in dashboard  
**Secret name:** `SNOV_API_KEY`  
**Credential type:** `httpHeaderAuth` with `Authorization: Bearer {V}`

### Option 3: Anymailfinder

| Feature | Details |
|---------|---------|
| Free tier | 20 searches/mo |
| Paid | $49/mo for 1,000 searches |
| API | Simple REST API |
| Special | Focused purely on email discovery — no bloat |

**Why Anymailfinder:** Laser-focused on email discovery, good accuracy, simple API. Good if you want a lightweight Hunter replacement.

### Option 4: RocketReach

| Feature | Details |
|---------|---------|
| Free tier | 5 lookups/mo (very limited) |
| Paid | $49/mo for 125 lookups |
| API | REST API |
| Special | Massive database (700M+ contacts), includes phone numbers |

**Why RocketReach:** Best data coverage, includes direct dials. Expensive but worth it for hard-to-find executives.

### Recommendation

| Scenario | Tool | Reason |
|----------|------|--------|
| **Start now, zero cost** | Apollo.io | Already configured, 50 free searches/mo |
| **Better free tier + LinkedIn** | Snov.io | Same free limit as Hunter, Chrome extension, verification included |
| **Best accuracy, budget available** | RocketReach | Largest database, includes phones |
| **Simple, focused** | Anymailfinder | No extra features, just emails |

---

### Beta/Production Environment Support

All api-proxy email endpoints (`/email.leads.scrape`, `/email.cold.start`, `/email.draft-reply`) accept an optional `environment` parameter:

| Value | Behavior | Use Case |
|-------|----------|----------|
| `"production"` (default) | Full execution — scrapes, enriches, imports to Attio, creates Smartlead campaigns | Live data processing |
| `"beta"` | Dry-run mode — scrapes but skips Attio import, prefixes campaign names with `[BETA]`, tags drafts with `[BETA DRAFT]` | Testing, pipeline validation |

The environment defaults to `$SALES_ENV` if not provided in the request body.

**Example POST to `/email.leads.scrape` (beta):**
```json
{
  "url": "https://example.com/directory",
  "waitForMs": 5000,
  "environment": "beta"
}
```

**Example POST to `/email.cold.start` (beta):**
```json
{
  "list_id": "123e4567-e89b-12d3-a456-426614174000",
  "campaign_name": "Q2 Outreach",
  "environment": "beta"
}
```

**Example POST to `/email.draft-reply` (beta):**
```json
{
  "email_content": "I'm interested in your services",
  "context": "Prospect from Q2 pipeline",
  "tone": "professional",
  "environment": "beta"
}
```

---

## 2b. Smartlead Alternatives (Cold Email Sender)

Smartlead is currently **not configured**. If you sign up for one, here are the best options:

### Option 1: Instantly (Recommended)

| Feature | Details |
|---------|---------|
| Free tier | 50 emails/mo |
| Paid | $37/mo for 10,000 emails |
| API | Good REST API |
| Strengths | Better deliverability than Smartlead, simpler UI, excellent warmup |

**Why Instantly:** Often rated #1 for deliverability. Their warmup algorithm is industry-leading. If you only pick one sender, this is it.

**Signup:** instantly.ai → Free trial → API key in settings  
**Secret name:** `INSTANTLY_API_KEY`  
**Credential type:** `httpHeaderAuth` with `Authorization: Bearer {V}`

### Option 2: Smartlead (Already in Workflows)

| Feature | Details |
|---------|---------|
| Free tier | 100 emails/mo (most generous) |
| Paid | $37/mo for 6,000 emails |
| API | Good REST API |
| Strengths | Already integrated, good multi-inbox rotation |

**Why Smartlead:** Already referenced in your `attio-cold-email.json` workflow. Free tier is 2x Instantly's. Good if you want to use existing workflow templates without modification.

**Signup:** smartlead.ai → Free account → Integrations → API key  
**Secret name:** `SMARTLEAD_API_KEY`  
**Credential type:** `httpHeaderAuth` with `Authorization: Bearer {V}`

### Option 3: Woodpecker

| Feature | Details |
|---------|---------|
| Free tier | 50 emails/mo |
| Paid | $49/mo for 1,500 emails |
| API | REST API (more limited than Instantly/Smartlead) |
| Strengths | Excellent for agencies (white-label), strong deliverability |

**Why Woodpecker:** Best if you plan to offer email outreach as a service to clients. Agency-friendly features.

### Option 4: Lemlist

| Feature | Details |
|---------|---------|
| Free tier | 50 emails/mo |
| Paid | $59/mo for unlimited |
| API | Good REST API |
| Strengths | Best-in-class personalization (images, videos, landing pages) |

**Why Lemlist:** If you need hyper-personalized outreach (custom images with recipient's name/logo), this is the tool. Overkill for basic cold email.

### Option 5: Mailshake

| Feature | Details |
|---------|---------|
| Free tier | None (paid only) |
| Paid | $58/mo for 5,000 emails |
| API | Limited API |
| Strengths | Strong native integrations (Salesforce, HubSpot, Pipedrive) |

**Why Mailshake:** If you already use Salesforce/HubSpot and want tight CRM integration.

### Option 6: AWS SES (Build-Your-Own)

**This is the question you actually asked.** Can you use AWS SES instead of Smartlead/Instantly?

**Short answer:** Yes, but with significant caveats. SES is excellent for transactional and warm email. For cold email, it's risky and requires substantial DIY work.

| Feature | AWS SES | Smartlead/Instantly | Verdict |
|---------|---------|-------------------|---------|
| Cost | **$0.10/1,000 emails** | $37/mo | SES wins by 100x on cost |
| Warmup | **None** — manual only | Automated | Smartlead/Instantly wins — warmup is critical |
| Account risk | **High** — spam complaints can suspend your entire AWS account | Low — they handle abuse mitigation | Smartlead/Instantly wins |
| Multi-inbox | **Manual** — configure each sending identity | Automatic rotation | Smartlead/Instantly wins |
| Reply tracking | **DIY** — SNS + S3 + lambda | Built-in webhooks | Smartlead/Instantly wins |
| Bounce handling | **DIY** — SNS notification, build suppression logic | Automatic suppression | Smartlead/Instantly wins |
| Sequencing/drip | **None** — build custom | Built-in campaign builder | Smartlead/Instantly wins |
| Template management | Basic (SES API) | Rich template editor | Smartlead/Instantly wins |
| Sending limits | Start at 200/day (sandbox), max 14/sec | Managed automatically | Tie |
| Compliance | **All on you** — CAN-SPAM, unsubscribe, opt-out | Built-in compliance helpers | Smartlead/Instantly wins |

### When SES Makes Sense

| Scenario | Recommendation |
|----------|---------------|
| **Warm email to existing contacts** (newsletter, follow-ups) | ✅ Use SES — cheap, reliable, no warmup needed |
| **Transactional email** (password resets, notifications) | ✅ Use SES — purpose-built for this |
| **Cold email to purchased/scraped lists** | ❌ Avoid SES — high spam risk, AWS account suspension |
| **Small pilot (<200 emails/day)** with manual warmup | ⚠️ Use SES cautiously — but build suppression + tracking first |
| **Any volume with no email reputation** | ❌ Use Smartlead/Instantly — warmup is non-negotiable |

### Building Cold Email on SES (If You Really Want To)

If you choose SES, here's the minimum viable setup:

```
Apollo (find leads)
    |
    v
ZeroBounce (verify emails)
    |
    v
Attio (store leads)
    |
    v
api-proxy (drip campaign scheduler)
    - Day 1: Send 10 emails via SES
    - Day 2: Send 12 emails
    - Day 3: Send 15 emails
    - ... ramp up 10% daily until 50/day
    - Track opens (SES open tracking + SNS)
    - Track replies (SES receipt rules + S3 + api-proxy)
    - Track bounces (SES bounce notifications + SNS + api-proxy -> Attio archive)
    - Auto-unsubscribe (api-proxy + Attio)
    |
    v
Signal (alert on replies)
```

**What you'd need to build:**
1. **Warmup script** — workflow that gradually increases daily send volume
2. **Bounce handler** — SNS topic subscription that updates Attio on hard bounces
3. **Reply parser** — SES receipt rule that stores replies in S3, api-proxy parses and updates Attio
4. **Suppression list** — Attio list of unsubscribed/bounced emails checked before every send
5. **DKIM/SPF/DMARC** — DNS records for your domain (required for SES, good practice regardless)

**Estimated effort:** 2-3 weeks of custom workflow development vs. 1 hour of Smartlead setup.

### Honest Cost Comparison

| Approach | Monthly Cost | Hidden Costs | Risk |
|----------|-------------|-------------|------|
| **Smartlead/Instantly** | $37 | None | Low |
| **SES DIY** | ~$0.50 (5,000 emails) | 20-30 hrs dev time, AWS account risk | High |
| **SES + Instantly** | $37 + $0.50 | None | Very low (best of both) |

### My Recommendation

| Your Situation | Recommendation |
|---------------|----------------|
| **You want it working this week** | Smartlead ($37/mo) — zero dev time |
| **You have dev time and want cheapest option** | SES DIY — but budget 2-3 weeks |
| **You want best deliverability** | Instantly ($37/mo) — better warmup than Smartlead |
| **You send warm email + cold email** | **Both:** SES for warm/transactional, Smartlead for cold |
| **You're testing, unsure if cold email works for your market** | Smartlead free tier (100/mo) — test before building |

**The truth:** For cold email specifically, the $37/mo for Smartlead/Instantly buys you:
- Automated warmup (would take weeks to replicate)
- Multi-inbox rotation (complex to manage manually)
- Abuse prevention (protects your AWS account and domain reputation)
- Built-in compliance (unsubscribe links, opt-out handling)

**That's worth $37 if cold email is part of your core strategy.** If it's a side experiment, build on SES and accept the deliverability hit.

---

## 2c. All-in-One vs. Best-of-Breed: Why Smartlead Was Selected

You asked about **Snov.io** — and more broadly, why Smartlead was the initial choice when alternatives exist. This is the core architectural decision for your stack.

### Two Stack Philosophies

| Approach | Philosophy | Tools | Cost | Complexity |
|----------|-----------|-------|------|------------|
| **Best-of-Breed** | Pick the best tool for each job | Apollo (find) + ZeroBounce (verify) + Smartlead (send) | ~$112/mo | High (more integrations) |
| **All-in-One** | One platform does everything | Snov.io or Apollo (find + verify + send) | ~$59/mo | Low (fewer integrations) |

### Smartlead Was Selected Because...

1. **It does one thing extremely well** — cold email sending + deliverability
2. **Best-in-class warmup** — their algorithm gradually builds sender reputation across multiple inboxes
3. **Multi-inbox rotation** — spreads sends across 10+ Gmail/Outlook accounts automatically
4. **API-first design** — every feature has a REST endpoint (webhooks, campaigns, leads, replies)
5. **Existing workflow** — `attio-cold-email.json` was already built for Smartlead

### But Snov.io Is a Viable Alternative

**What Snov.io does:**
- Email finder (Chrome extension, LinkedIn, domain search)
- Email verifier (built-in — replaces ZeroBounce)
- Drip campaigns (sender — replaces Smartlead)
- CRM-lite (basic pipeline management)
- AI email writer (generates subject lines and body copy)

| Feature | Snov.io | Smartlead | Winner |
|---------|---------|-----------|--------|
| Email finding | ✅ Built-in | ❌ Not included | Snov.io |
| Email verification | ✅ Built-in (unlimited) | ❌ Not included | Snov.io |
| Cold email sending | ✅ Basic campaigns | ✅ Advanced sequencing | Smartlead |
| Warmup | ⚠️ Basic | ✅ Excellent | Smartlead |
| Multi-inbox rotation | ⚠️ Limited | ✅ 10+ inboxes | Smartlead |
| Deliverability optimization | ⚠️ Moderate | ✅ Excellent | Smartlead |
| API quality | Good | Good | Tie |
| AI features | ✅ AI writer | ❌ None | Snov.io |
| Cost (entry) | $39/mo | $37/mo | Tie |
| Free tier | 50 credits + 100 sends | 100 sends | Snov.io |

### Is Snov.io AI-Forward?

**Partially.** Snov.io has:
- **AI Email Writer** — generates personalized email copy based on prospect data
- **AI Subject Line Generator** — A/B tests subject lines
- **Email Warmup AI** — basic algorithm (not as sophisticated as Smartlead)

**But it's not an "AI company."** The AI features are add-ons, not core to the product. If you want AI-first outreach, you'd need:
- **Clay.com** — AI enrichment + waterfall logic (finds emails across 50+ sources)
- **Luna.ai** — AI-generated personalized emails at scale
- **Smartlead/Instantly + OpenAI** — Build AI personalization via api-proxy using OpenAI API

### Other All-in-One Competitors

| Platform | What It Replaces | Cost | Best For |
|----------|-----------------|------|----------|
| **Apollo.io** | Hunter + ZeroBounce + Smartlead + Clearbit | $59/mo | Data-heavy teams — best database |
| **Snov.io** | Hunter + ZeroBounce + Smartlead | $39/mo | Budget-conscious — does everything adequately |
| **Hunter.io + Hunter Campaigns** | Hunter + Smartlead | $49/mo | If you already use Hunter |
| **Lemlist** | Smartlead + personalization | $59/mo | Creative campaigns — images, videos |
| **Reply.io** | Smartlead + Apollo lite | $60/mo | Sales teams — built-in CRM |

### Why Apollo Wasn't Selected as the "One Tool"

You already have Apollo keys. Could Apollo replace everything?

| Apollo Feature | Quality | Replaces? |
|---------------|---------|-----------|
| Email finding | Excellent | ✅ Replaces Hunter |
| Email verification | Moderate (built-in) | ⚠️ Partially replaces ZeroBounce |
| Cold email sending | Basic (sequences) | ⚠️ Replaces Smartlead for small volume |
| CRM | Good | ⚠️ Attio is better for CRM |

**Apollo's weakness:** Its email sender is functional but lacks Smartlead's deliverability optimization. Apollo sequences are fine for warm leads, risky for cold outreach at scale.

### Recommendation: Hybrid Stack

Given what you already have (Apollo + Browserless + ZeroBounce + Attio), the most efficient path is:

```
Current:     Apollo (find) → ZeroBounce (verify) → [GAP: sender]
Option A:    Add Smartlead ($37/mo) — best deliverability
Option B:    Add Snov.io ($39/mo) — replaces ZeroBounce + sender, keep Apollo for finding
Option C:    Use Apollo sequences ($0 extra) — basic, risky for cold
Option D:    Build on SES ($0.50/mo) — cheapest, highest dev time
```

| Scenario | Stack | Cost | Risk |
|----------|-------|------|------|
| **Best deliverability** | Apollo + ZeroBounce + Smartlead | $112/mo | Low |
| **Best value** | Apollo + Snov.io | $98/mo | Moderate (Snov sender weaker) |
| **Minimum viable** | Apollo + ZeroBounce + Apollo sequences | $59/mo | High (no warmup) |
| **Cheapest** | Apollo + SES DIY | $59.50/mo | Very high |

**My updated recommendation:**
- If you're serious about cold email → **Smartlead** (best deliverability)
- If you want to minimize tools → **Snov.io** (replaces Hunter + ZeroBounce + Smartlead)
- If you're testing the channel → **Apollo sequences** (free, accept lower deliverability)

---

## 3. Expanded Pipeline Architecture

### Full Lead Gen Flow (Recommended)

```
Source Layer
------------
Source A: Directory          Source B: LinkedIn          Source C: Website
(Browserless)                (PhantomBuster)             (Clearbit Reveal)
     |                             |                            |
     |                             |                            |
     +-----------------------------+----------------------------+
                                   |
                                   v
                    Deduplication Layer
                    (Attio Read API — check domain exists)
                                   |
                                   v
                    Enrichment Layer
                    (Apollo.io or Clearbit)
                    - Firmographics (revenue, employees, industry)
                    - Technographics (tech stack)
                    - Intent signals (hiring, funding)
                                   |
                                   v
                    Email Discovery
                    (Hunter.io — find by domain)
                                   |
                                   v
                    Email Verification
                    (ZeroBounce — validate deliverability)
                                   |
                                   v
                    Attio Import
                    (Write API — Company + Person records)
                                   |
                                   v
                    Campaign Push
                    (Smartlead — add to sequence)
                                   |
                                   v
                    Monitoring Loop
                    (Smartlead webhooks — replies, bounces)
                    - Reply -> Attio update + Signal alert
                    - Bounce -> Attio archive + flag for re-verification
```

### Use Cases Beyond Current Setup

| Use Case | Implementation | Tools |
|----------|---------------|-------|
| **LinkedIn prospecting** | PhantomBuster scrapes search/company -> enrich -> Attio | PhantomBuster, Apollo |
| **Email verification** | ZeroBounce validates before Smartlead import | ZeroBounce |
| **Company firmographics** | Apollo/Clearbit enriches employee count, revenue, industry | Apollo, Clearbit |
| **Web intent signals** | Clearbit Reveal identifies visiting companies -> push to Attio | Clearbit |
| **Lead scoring** | api-proxy logic scores on enrichment + behavior -> update Attio field | api-proxy + Attio Write |
| **Duplicate prevention** | Read Attio before create -> skip if domain/email exists | Attio Read API |
| **Two-way sync** | Smartlead webhooks update Attio on reply/bounce/unsusbscribe | Smartlead + Attio |
| **Calendar booking** | Attio contact -> Cal.com link -> update status to "Meeting Booked" | Cal.com + Attio |
| **Newsletter segmentation** | Attio lists filtered by tags -> push to Mailchimp/Beehiiv | Mailchimp/Beehiiv API |

---

## 4. Attio Object Schema Recommendations

To support the expanded pipeline, create these custom fields in Attio:

### Company Object

| Field | Type | Source | Purpose |
|-------|------|--------|---------|
| `lead_score` | Number | api-proxy calculated | Prioritization (0-100) |
| `enrichment_source` | Text | Apollo/Clearbit/Hunter | Traceability |
| `enrichment_date` | Date | api-proxy timestamp | Freshness check |
| `email_confidence` | Number | Hunter.io | Quality gate (filter < 80%) |
| `verification_status` | Select | ZeroBounce | valid / invalid / catch_all / unknown |
| `campaign_status` | Select | Smartlead webhook | uncontacted / contacted / replied / booked / archived |

### Person Object

| Field | Type | Source | Purpose |
|-------|------|--------|---------|
| `email_verified` | Checkbox | ZeroBounce | Filter unverified before campaign |
| `linkedin_url` | Text | PhantomBuster/Apollo | Source verification |
| `phone` | Text | Apollo | Secondary outreach channel |
| `job_function` | Select | Apollo | Segmentation (Sales, Marketing, Engineering, etc.) |

---

## 5. Implementation Roadmap

### Phase 1: Quality (Week 1-2)
**Goal:** Reduce bounce rate and improve data quality before scaling volume.

1. Add ZeroBounce verification node to Lead Scraping Pipeline (after Hunter, before Attio Write)
2. Add Attio Read check for duplicate prevention (check domain before create)
3. Create `verification_status` and `email_confidence` fields in Attio
4. Add conditional logic: only push `verification_status == "valid"` to Smartlead

**Secrets needed:** `ZEROBOUNCE_API_KEY`

### Phase 2: Enrichment (Week 3-4)
**Goal:** Add firmographic context for better targeting and segmentation.

1. Add Apollo.io enrichment node (after domain extraction, before Hunter)
2. Create `lead_score`, `enrichment_source`, `enrichment_date` fields in Attio
3. Add lead scoring logic in api-proxy (revenue + employee count + industry match = score)
4. Segment Smartlead campaigns by `job_function` or `lead_score`

**Secrets needed:** `APOLLO_API_KEY`

### Phase 3: LinkedIn (Week 5-6)
**Goal:** Add LinkedIn as a primary lead source for B2B outreach.

1. Create new workflow: `linkedin-prospecting.json`
2. PhantomBuster extracts LinkedIn search results -> Apollo enrichment -> Attio
3. Dedupe against existing Attio companies (domain match)
4. Push verified leads to separate Smartlead campaign (LinkedIn-specific messaging)

**Secrets needed:** `PHANTOMBUSTER_API_KEY`

### Phase 4: Intent (Week 7-8)
**Goal:** Identify companies already visiting your website.

1. Add Clearbit Reveal to website (javascript snippet)
2. Create webhook workflow: Clearbit Reveal -> api-proxy -> Attio
3. Tag visiting companies with "Website Visitor" + visit count
4. Prioritize these leads in Smartlead (warm intent)

**Secrets needed:** `CLEARBIT_API_KEY`

### Phase 5: Advanced Orchestration (Ongoing)
**Goal:** Full two-way sync and intelligent routing.

1. Smartlead reply webhook -> api-proxy -> update Attio `campaign_status` -> Signal alert to {OWNER_SHORT_NAME}
2. Bounce/invalid webhook -> api-proxy -> archive in Attio -> flag for re-verification
3. Cal.com booking webhook -> api-proxy -> update Attio status -> stop Smartlead sequence
4. Weekly sentry report: new leads, reply rates, bounce rates, pipeline value

---

## 6. Required Secrets & API Keys

### Already Present in AWS SM

| Secret Key | Tool | Purpose | Status |
|------------|------|---------|--------|
| `BROWSERLESS_API_KEY` | Browserless | Headless browser scraping | ✅ Present |
| `ZEROBOUNCE_API_KEY` | ZeroBounce | Email verification | ✅ Present |
| `APOLLO_SEARCH` | Apollo.io | Prospecting/search API | ✅ Present |
| `APOLLO_ENRICH` | Apollo.io | Data enrichment API | ✅ Present |

### Needed for Outreach (Pick One)

| Secret Key | Tool | Purpose | Recommended? |
|------------|------|---------|--------------|
| `SMARTLEAD_API_KEY` | Smartlead | Cold email sending + reply tracking | Yes — existing workflow support |
| `INSTANTLY_API_KEY` | Instantly | Cold email sending + reply tracking | Yes — best deliverability |
| `WOODPECKER_API_KEY` | Woodpecker | Cold email sending + reply tracking | Only if agency/white-label |

### Optional Additions

| Secret Key | Tool | Purpose | When to Add |
|------------|------|---------|-------------|
| `SNOV_API_KEY` | Snov.io | Email discovery (Hunter alternative) | If Apollo email finding insufficient |
| `ROCKETREACH_API_KEY` | RocketReach | Email + phone discovery | If you need phone numbers or hard-to-find contacts |
| `PHANTOMBUSTER_API_KEY` | PhantomBuster | LinkedIn scraping | Phase 3 — LinkedIn as primary source |
| `CLEARBIT_API_KEY` | Clearbit | Web intent + firmographics | Phase 4 — website visitor tracking |
| `cal_api_key` | Cal.com | Scheduling integration | Phase 5 — meeting booking automation |

**To add a secret:**
1. Retrieve current secret blob: `aws secretsmanager get-secret-value --secret-id ORCHESTRATOR/Production/FRAD`
2. Add new key-value pair to JSON
3. Update: `aws secretsmanager put-secret-value --secret-id ORCHESTRATOR/Production/FRAD --secret-string file://updated.json`
4. Configure api-proxy to use the new key

---

## 7. Cost Projections

### Current Monthly Stack (Free Tiers)

| Tool | Cost | Free Limit |
|------|------|------------|
| Browserless | $0 | 1,000 sessions/mo |
| Hunter.io | $0 | 50 requests/mo |
| Smartlead | $0 | 100 emails/mo |
| ZeroBounce | $0 | 100 credits/mo |
| **Current Total** | **$0/mo** | **Limited volume, proof-of-concept** |

### Paid Scaling Projections

| Tier | Tools | Cost | When to Upgrade |
|------|-------|------|-----------------|
| **Starter** | Browserless + Hunter + Smartlead | $106/mo | >1,000 scrapes/mo or >50 Hunter lookups/mo |
| **Growth** | + ZeroBounce + Apollo | $181/mo | >100 emails/mo sent, need firmographics |
| **Scale** | + PhantomBuster + Clearbit | $349/mo | LinkedIn as primary source, website visitor tracking |

**ROI benchmark:** At $106/mo (Starter), you need ~1 qualified lead/month to break even (LTV > $150). Free tier enables testing before any financial commitment.

**Free tier strategy:** Use free tiers for:
- Pipeline validation and workflow testing
- Small client pilots (< 50 leads/mo)
- Proof-of-concept before client commits to paid tools

**Upgrade triggers:**
- Browserless: > 800 sessions/mo (leave 20% buffer)
- Hunter: > 40 requests/mo
- Smartlead: > 80 emails/mo
- ZeroBounce: > 80 verifications/mo

---

## 8. Security & Compliance Notes

- **Attio keys:** Only api-proxy holds `ATTIO_WRITE_KEY` and `ATTIO_ARCHIVE_KEY`. ORCH/VERI have `ATTIO_READ_KEY` for audit only. CODE containers have no Attio access.
- **Data residency:** All enrichment APIs are US-based. If processing Canadian leads, ensure compliance with CASL (Canada's anti-spam law) — obtain consent or have a valid business relationship.
- **Rate limits:** Hunter.io (100 req/min), Apollo (200 req/min), ZeroBounce (batch API preferred). Build delays (150-300ms between requests).
- **No hard deletes:** All Attio "deletions" use `PATCH { "status": "Archived" }`. Never call DELETE endpoints.

---

## 9. Client Onboarding Automation (Future)

**Goal:** When a new client is added to Attio, automatically create accounts with all required enrichment services, store credentials in AWS Secrets Manager, and configure workflows.

### Proposed Architecture

```
New Client in Attio
    |
    v
Trigger: Attio webhook (new Company record tagged "New Client")
    |
    v
Browserless Agent (api-proxy endpoint or CODE container)
    - Navigates to signup pages
    - Fills forms with client business details
    - Solves CAPTCHAs (if any)
    - Retrieves API keys from confirmation pages/emails
    |
    v
Credential Storage
    - Store API keys in AWS SM: ORCHESTRATOR/Production/<ClientProject>
    - Create Docker Swarm secrets for the client's stack
    |
    v
Fleet Provisioning
    - Generate client-specific compose
    - Deploy sentry with pre-configured workflows
    - Inject credentials via 0config.ps1
    |
    v
Attio Update
    - Mark client status: "Onboarded"
    - Link to deployed stack
```

### Services to Automate

| Service | Signup URL | Credential Location | Notes |
|---------|------------|---------------------|-------|
| **Browserless** | browserless.io/signup | Dashboard API section | Free tier auto-approved |
| **Hunter.io** | hunter.io/sign-up | Dashboard API key | Requires email verification |
| **ZeroBounce** | zerobounce.net/register | Dashboard API key | Requires email verification |
| **Smartlead** | smartlead.ai/signup | Dashboard Integrations | Requires domain verification |
| **Apollo.io** | apollo.io/signup | Dashboard API key | Requires company email |
| **PhantomBuster** | phantombuster.com/signup | Dashboard API key | Requires email verification |
| **Clearbit** | clearbit.com/signup | Dashboard API key | Manual approval for free tier |

### Technical Challenges

1. **CAPTCHA solving:** Some signup forms use reCAPTCHA/hCaptcha. Options:
   - Browserless with stealth plugins
   - 2Captcha/anti-captcha service integration
   - Human-in-the-loop: queue to {OWNER_SHORT_NAME} for manual solve

2. **Email verification:** Most services require email confirmation.
   - Use client-provided email or create forwarding alias
   - CODE container polls email inbox for verification links
   - Browserless clicks verification links automatically

3. **Rate limits on signup:** Many services limit account creation by IP.
   - Rotate Browserless sessions through different proxies
   - Stagger account creation over time
   - Use residential proxies for high-success-rate signup

4. **Terms of Service:** Automated signup may violate ToS for some services.
   - Document which services permit automated signup
   - Fallback: generate signup links + pre-filled data for manual completion
   - Use client-owned accounts where possible (invite to existing team)

### Implementation Phases

**Phase A: Research & Documentation**
- Test automated signup for each service with Browserless
- Document form fields, CAPTCHA presence, email verification flow
- Build decision matrix: fully automated vs. human-in-the-loop

**Phase B: Browserless Signup Module**
- Create reusable workflow: `signup-service.json`
- Inputs: service name, client details, proxy config
- Outputs: API key (or manual completion link)

**Phase C: Credential Management**
- Extend `Set-SwarmSecretSafe` to support multi-project secrets
- Create client-specific secret namespaces in AWS SM
- Auto-generate Docker secrets for client stacks

**Phase D: Fleet Generation**
- Extend `Generate-FleetCompose` to accept client-specific configs
- Auto-deploy sentry with pre-loaded workflows per client
- Run `0config.ps1` automatically post-deploy

### Security Considerations

- **Client isolation:** Each client's secrets in separate AWS SM namespace
- **No shared keys:** Never reuse API keys across clients
- **Audit trail:** Log all automated signups in Attio activity feed
- **Revocation:** On client offboarding, disable all associated API keys

---

## 10. Next Actions

### Immediate (This Week)

1. **Sign up for Smartlead** — Only remaining tool needed:
   - Go to smartlead.ai → create account → Integrations → copy API key
   - Add to AWS SM as `SMARTLEAD_API_KEY`
   - Add to api-proxy configuration

2. **Re-run `0config.ps1`** — Inject all current credentials (Browserless, ZeroBounce, Apollo, Smartlead) into the api-proxy

### Short-Term (Next 2 Weeks)

4. **Create Attio custom fields:** `verification_status`, `email_confidence`, `lead_score`, `campaign_status`
5. **Update Lead Scraping Pipeline:**
   - Replace Hunter node with Apollo search node (or add conditional fallback)
   - Add ZeroBounce verification node after email discovery
   - Add duplicate check via Attio Read API before creating records
6. **Monitor free tier usage:** Track Browserless sessions, Apollo requests, ZeroBounce credits

### Research (Ongoing)

7. **Test Browserless on Hunter.io signup form** — Document form fields, CAPTCHA presence
8. **Decide on Hunter alternative** — Apollo (free, already have) vs. Snov.io (free, LinkedIn extension)
9. **Measure bounce rate** once cold email sender is active

---

*Generated by ORCH (Maestro) on 2026-04-30. Update this document as phases are implemented.*
