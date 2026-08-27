---
name: browserless
description: Browser automation via Browserless (headless Chrome) and local Playwright. READ THIS FIRST before using any browser automation in the fleet. Covers connection, session persistence, SPA navigation, Zoho sign-in limits, and prerequisites. Superseded by specific files in Sites/ for per-site details.
---

# Skill: Browser Automation — Generic Reference

> **READ THIS FIRST** before using any browser automation in the fleet. This is the canonical generic reference. Site-specific files in `Sites/` supersede this for their platform (e.g. `Infrastructure/Browserless/Sites/books.zoho.com/browserless-zoho-books-quick-categorize.md` for Zoho) and assume you've read this first.

## Overview

The fleet runs `FRAD_mcp_browserless` — a self-hosted headless Chrome container (`ghcr.io/browserless/chromium`) on the Docker overlay network. It supports **Playwright** (preferred), Puppeteer (deprecated), and Selenium protocols.

**Automation contexts:**

| Context | Engine | Where it runs |
|---------|--------|--------------|
| **Zoho Books** (API gaps) | Playwright via Browserless WebSocket | Docker container `FRAD_mcp_browserless` |
| **Amazon receipts** | Playwright (local, real Chrome, persistent profile) | User's Windows machine |
| **Home Depot Canada receipts** | Playwright via CDP to user's real Chrome | User's Windows machine |
| **Netflix billing receipts** (prototype) | Playwright (local, real Chrome, persistent profile) | User's Windows machine |
| **AliExpress receipts** (prototype) | Playwright (local, real Chrome, persistent profile) | User's Windows machine |

**Puppeteer is deprecated** — all new scripts should use Playwright. Existing Puppeteer scripts (e.g., `zoho-browserless.md`) may still work but will not be updated.

---

## Context 1: Browserless Container (Zoho, general web)

### Service

| Property | Value |
|----------|-------|
| Service name | `FRAD_mcp_browserless` |
| Docker network | `service_net` (overlay — not accessible from host) |
| Internal port | 3003 (upstream-dictated — see ADR 0014 §1 "Upstream-dictated internal ports") |
| Auth token | `BROWSERLESS_API_KEY` in AWS SM `Interclaw/FRAD/Provisioning` |
| Image | `ghcr.io/browserless/chromium:latest` |
| CONCURRENT | 5 (max parallel sessions) |
| TIMEOUT | 120000 (2 min, updated from default 30s) |

### Connection — Playwright

```javascript
const { chromium } = require('playwright');
const browser = await chromium.connectOverCDP(
  `ws://FRAD_mcp_browserless:3003?token=${TOKEN}`
);
const page = await browser.newPage();
```

### Connection — Puppeteer (deprecated)

```javascript
const pptr = require('puppeteer-core');
const browser = await pptr.connect({
  browserWSEndpoint: `ws://FRAD_mcp_browserless:3003?token=${TOKEN}`
});
```

### REST Endpoints (no-browser-needed operations)

| Endpoint | Method | Use |
|----------|--------|-----|
| `/scrape?token=TOKEN` | POST | Read-only page scraping (returns element text) |
| `/screenshot?token=TOKEN` | POST | Capture page screenshot |
| `/pdf?token=TOKEN` | POST | Generate PDF from page |
| `/pressure?token=TOKEN` | GET | Health check |

### Running Scripts via Helper Container

Browserless is on the overlay network, unreachable from the Windows host. Run automation scripts from a container on the same network:

```powershell
docker run --rm -i --network service_net `
  -e BROWSERLESS_API_KEY `
  -v "C:\path\to\scripts:/data" `
  -w /data `
  node:20-slim sh -c "npm install playwright && node /data/script.js"
```

**Playwright** is NOT pre-installed in the Browserless container (only `puppeteer-core`). You must `npm install playwright` in the helper container, or install it in a custom image.

## 🍪 Cookie Persistence — Mandatory for All Browser Automation

**All browser automation scripts — whether Browserless CDP or local headed Playwright — MUST implement cookie persistence.** This is not optional.

### Why

- **Zoho**: ~20 daily sign-in limit. Each new connection without cookies burns a slot.
- **Amazon**: CAPTCHA and device-claiming triggers on repeated logins.
- **General**: Every site with session limits, MFA, or login challenges wastes time and quota on re-authentication.

### Implementation Pattern

```javascript
const COOKIE_FILE = path.join(__dirname, '.session-cookies.json');

// Start: load saved cookies
if (fs.existsSync(COOKIE_FILE)) {
  const saved = JSON.parse(fs.readFileSync(COOKIE_FILE, 'utf8'));
  await context.addCookies(saved.cookies);
}

// After login: save cookies
const cookies = await context.cookies();
fs.writeFileSync(COOKIE_FILE, JSON.stringify({ cookies, savedAt: Date.now() }));

// Periodic save: every N operations or at checkpoints
if (i % 5 === 0) {
  fs.writeFileSync(COOKIE_FILE, JSON.stringify({ cookies: await context.cookies(), savedAt: Date.now() }));
}
```

**After loading cookies, verify the session is alive** — if the page redirects to a sign-in page, the session expired and a fresh login is needed. Save cookies again after re-login.

**Scripts must NOT close the browser automatically** at the end — leave it open so the user can inspect and verify. A crash mid-batch with saved cookies means the next run can skip login entirely.

## 🧭 Page-Reading Protocol (When Selectors Fail)

When a script's element selectors or interactions fail — especially during login flows, session housekeeping, or form entry — **do NOT blindly retry or guess selectors**. Instead:

1. **Read the page content** — extract visible text to understand what's happening:
   ```javascript
   const text = await page.evaluate(() => document.body.innerText.substring(0, 2000));
   console.log('PAGE:', text);
   ```
2. **Check for overlay dialogs** — Zoho frequently shows:
   - "Maximum CONCURRENT sessions" → click blue "Terminate all sessions" button
   - "I Understand" / GDPR consent → accept
   - "Authorize" or consent pages → grant
   - Block-sessions page → wait 24h or use headed browser
3. **Inspect the URL** — `page.url()` may reveal redirects to login, block, or consent pages
4. **Check the page title** — `document.title` can confirm you're on the right page
5. **Dump key selectors** — check if expected elements actually exist:
   ```javascript
   const btn = document.querySelector('button.btn-primary');
   console.log('Save button exists:', !!btn);
   ```

This protocol is **mandatory** for:
- **Login workflows** (email page → password page → MFA → org selection)
- **Session housekeeping** (concurrent sessions, consent, cookie banners, "I Understand" modals)
- **Any unexpected redirect** (block-sessions, security verification, CAPTCHA)
- **Form submissions** where the Save button appears to work but no data is saved

### Common Zoho Housekeeping Dialogs

| Dialog | Detection | Action |
|--------|-----------|--------|
| Maximum CONCURRENT sessions | Page text: "maximum CONCURRENT sessions" | Click blue "Terminate all sessions" button at bottom |
| GDPR consent / I Understand | Page text: "I Understand" or "GDPR" | Click the accept/consent button |
| Sign-in limit reached | Page text: "sign-in limit" | Stop — headed browser only for remainder of day |
| Authorize app | Page text: "Authorize" | May need user to click manually in headed mode |
| Org selection | URL contains `/org` | Select the correct org (`925048093`) |

## Prerequisites Before Starting Zoho Workflows

Before any Zoho Books browser automation, verify these two prerequisites are ready:

1. **AWS SSO session active** — run `aws sso login --profile intersite` to authenticate. Needed to fetch Zoho credentials from AWS Secrets Manager.
2. **Persistent browser session** — Zoho blocks automated logins after ~8-10 per day. One continuous CDP session must handle all work.

**Agent workflow:** If either prerequisite is missing, run `aws sso login --profile intersite` (per the standard AWS SSO Login Procedure in AGENTS.md) to authenticate, then open Zoho once and keep the session alive for all operations.

### Known Limitations

**30-second session timeout:** Browserless kills WebSocket sessions after 30s cumulative activity. Extended via `TIMEOUT=120000` env var (already applied to `FRAD_mcp_browserless`).

**Detached frames on navigation:** Each `page.goto()` replaces the main frame. After ~7 navigations the frame reference is lost. **Fix:** Use fresh tabs per operation (`browser.newPage()` → process → `page.close()`).

**SPA frame detachment (CDP only):** When using `connectOverCDP`, Zoho Books (Ember.js SPA) invalidates all element handles on view transitions. The CDP WebSocket is tied to the page frame — hash navigation via `page.goto()` severs the connection. **Fix:** Use `page.evaluate(() => { window.location.hash = '#/route'; })` instead of `page.goto()` for SPA navigation. Or use `chromium.connect()` (Playwright protocol) if Browserless supports it.

**⚠️ Zoho daily sign-in limit:** After ~8-10 automated logins, Zoho blocks further login attempts for ~24h with a `/preannouncement/block-sessions` redirect. This is the most frequent cause of automation failure.

**Prevention — One Persistent Session:**
1. **Log in ONCE** per Zoho session — do all work in one continuous CDP connection
2. **Never disconnect and reconnect** between operations — every reconnect is a new login
3. **Navigate via hash changes** — `page.evaluate(() => { window.location.hash = '#/route'; })` stays on the SPA without re-login
4. **Recover dead pages** — if hash navigation kills the CDP frame, recover via `browser.contexts()[0]?.pages()` (see `Skills/DevOps/Playwright/browserless-browserless-fundamentals.md`)
5. **If blocked** — wait 24h for the counter to reset, then use a local headed browser as fallback

**Recovery if blocked:** `page.url()` shows `/preannouncement/block-sessions`. No workaround except waiting 24h or using a different browser fingerprint (local headed Chrome). Document the block in the session log so the next agent knows to wait.

### Zoho Books SPA Navigation

After logging in, stay on the SPA and navigate via hash changes:

```javascript
// WRONG — loses session:
await page.goto("https://books.zoho.com/app/925048093#/banking/...");

// CORRECT — stays in SPA:
await page.evaluate(() => {
  window.location.hash = "#/banking/transactions?account_id=93310000000100013";
});
await sleep(5000);
```

Key hash routes:

| Page | Hash Route |
|------|-----------|
| Banking overview | `#/banking` |
| Account transactions | `#/banking/transactions?account_id={id}` |
| Quick categorize | `#/banking/quickcategorize?account_id={id}&account_name={name}&account_type={bank\|credit_card}&from_date={date}&to_date={date}` |
| Reconciliation | `#/banking/reconciliations/{account_id}?per_page=200` |

---

## Context 2: Local Real Chrome (Amazon Receipts)

Browserless **cannot** automate Amazon — it blocks headless Chrome with CAPTCHA, passkey challenges (`ax/claim`), and device-claiming pages.

**Working approach:** Run a Playwright (or Puppeteer) script on the user's machine using their **installed Chrome** with `headless: false`. The user logs in once, then the script navigates the Transactions page.

### Script Location
`Infrastructure/Browserless/Sites/amazon.ca/amazon-persistent-downloader.js` (Playwright) — preferred

### Persistent Profile Location
`Sites/amazon.ca/Profile/` — Chrome profile survives restarts, login persists across runs.

### How It Works

1. Opens `https://www.amazon.ca/cpe/yourpayments/transactions` in a visible Chrome window
2. Searches paginated transactions by amount + card suffix (`****6258`)
3. Clicks matching `Order #...` link
4. Saves order summary as PDF

### Transaction Matching HTML
```html
<div class="apx-transactions-line-item-component-container">
  <div>Mastercard ****6258</div>
  <div>-$31.35</div>
  <a href="...orderID=702-1121679-3593054">Order #702-1121679-3593054</a>
</div>
```

### Key Details
- Match by **amount + card suffix** together in same container
- Process **newest-first** (Transactions page starts at present, paginates backward)
- Checkpoint file (`download-checkpoint.json`) enables resume after interruption
- Debug matching failures by dumping `document.body.innerText` substring

---

## Skill File Hierarchy (Inheritance Chain)

Read files in this order — each assumes you've read the one above:

| Order | File | Scope |
|-------|------|-------|
| 1 | **`Skills/DevOps/Playwright/browserless.md`** (this file) | **Generic** — connection, session persistence, Zoho limits, prerequisites |
| 2 | `Skills/DevOps/Playwright/browserless-browserless-fundamentals.md` | **Fundamentals** — CDP gotchas, SPA navigation patterns, Playwright API differences |
| 3 | `Skills/DevOps/Playwright/browserless-browserless-zoho-books.md` | **Zoho Books-specific** — Quick Categorize, Card Payment, hash routes, account mapping |
| 4 | `Skills/DevOps/Playwright/playwright-amazon-receipts.md` | **Amazon-specific** — local Chrome, not Browserless |
| 5 | `Skills/DevOps/Playwright/browserless-cloudtax-autofill.md` | **CloudTax-specific** — T2 schedule autofill via Playwright |
| 6 | `Archived/Skills/Infrastructure/Browserless/Skills/browserless-lessons-learned.md` | **Historical** — non-duplicate troubleshooting entries |

## Playwright Version Compatibility

The `amazon-persistent-downloader.js` script uses Playwright. Playwright v1.52+ requires `page.evaluate()` calls with multiple arguments to be wrapped in an object:

```javascript
// OLD (Playwright <1.52) — broken in newer versions:
await page.evaluate((amt, card) => { ... }, amtStr, cardSuffix);

// NEW (Playwright 1.52+):
await page.evaluate(({ amt, card }) => { ... }, { amt: amtStr, card: cardSuffix });
```

If a script fails with "Too many arguments", this is the cause. Fix all `page.evaluate()` calls that pass more than one argument after the function.

## Fetching Credentials for Automation

When a script needs credentials (Zoho login, email IMAP, etc.):

1. **AWS SSO** — ensure active session: `aws sso login --profile intersite`
2. **Fetch from SM** — `aws secretsmanager get-secret-value --secret-id Interclaw/FRAD/Provisioning --profile intersite --region ca-central-1 --query "SecretString" --output text | ConvertFrom-Json`
3. **Set env vars** — scripts read from env vars or CLI flags, never hardcoded values

Known credential keys for automation:
| Key | Purpose |
|-----|---------|
| `RECEIPTS_INTERSITE_EMAIL` / `RECEIPTS_INTERSITE_PASS` | Email IMAP for receipt inbox |
| `ZOHO_BOOKS_ID` / `ZOHO_BOOKS_SECRET` / `ZOHO_BOOKS_REFRESH` | Zoho Books OAuth |
| `BROWSERLESS_API_KEY` | Browserless WebSocket auth |
| `INTERSITE_HOME_DEPOT_EMAIL` / `INTERSITE_HOME_DEPOT_PASSWORD` | Home Depot Canada Pro account login |

## Known Limitations — Home Depot Canada

**Date:** 2026-06-12

| Approach | Result |
|----------|--------|
| Playwright bundled Chromium | `ERR_HTTP2_PROTOCOL_ERROR` — HD's server is incompatible with Chromium's HTTP/2 |
| Real Chrome via `channel: 'chrome'` | Same HTTP/2 error with fresh Playwright-managed profile |
| `--disable-http2` | Not supported on Windows, crashes browser |
| `--no-sandbox` / `--disable-setuid-sandbox` | Linux-only flags — rejected on Windows Chrome |
| Auto-login (fill form → submit) | HD triggers CAPTCHA on automated input |
| **CDP connection** to user's real Chrome | **Works** — user signs in manually in their own browser, no bot detection |
| Persistent profile (`launchPersistentContext` with Channel) | Works for Amazon.ca; HTTP/2 issues on HD |

**Key selectors:** Cookie accept: `#onetrust-accept-btn-handler`. Store modal close: `.acl-modal__close`. Confirm store: `button.acl-button--theme--primary` with text "Confirm Store".

**Key observations:**
1. `pro.html#` hash triggers Angular sign-in modal — popups redirect away from `#`, must re-navigate after dismissal
2. Playwright `:has-text()` pseudo-selectors don't work inside `page.evaluate()` (native `querySelectorAll` doesn't support them)
3. Windows Chrome doesn't support `--no-sandbox` or `--disable-setuid-sandbox`
4. Never blindly kill all `chrome.exe` processes — user may have their own Chrome session. Target only Playwright's `chromium.exe` by name.

See `Skills/DevOps/Playwright/playwright-homedepot-receipts.md` for full docs.

## Related Files

| File | Purpose |
|------|---------|
| `Infrastructure/mcp_browserless.Dockerfile` | Container definition (port 3003, HEALTHCHECK) |
| `Infrastructure/Browserless/Archived/books.zoho.com/zoho-browserless.md` | Legacy Zoho-specific automation (Puppeteer, deprecated) |
| `docs/Reference/Decisions/0014-port-allocation-scheme.md` | Port 3003 for mcp_browserless (upstream-dictated) |
| `docs/Reference/Decisions/0036-sidecar-network-topology.md` | Sidecar network topology conventions |
| `docs/Reference/ARCHITECTURE.md` | Fleet topology |
| `Infrastructure/Browserless/Sites/books.zoho.com/zoho-quick-categorize.js` | Playwright script for Quick Categorize |
| `Infrastructure/Browserless/Sites/books.zoho.com/zoho-reconcile.js` | Playwright script for monthly reconciliation |
| `Infrastructure/Browserless/Sites/cloudtax.ca/cloudtax-autofill.js` | Playwright autofill for CloudTax T2 schedules |
| `Skills/DevOps/Playwright/playwright-homedepot-receipts.md` | Home Depot Canada receipt retrieval docs |
| `Infrastructure/Browserless/Sites/homedepot.ca/homedepot-receipt-downloader.js` | Home Depot Canada receipt downloader (canonical) |
| `Skills/DevOps/Playwright/playwright-netflix-receipts.md` | Netflix billing receipt retrieval docs (selectors discovered 2026-06-18) |
| `Infrastructure/Browserless/Sites/netflix.com/netflix-receipt-downloader.js` | Netflix receipt downloader (canonical) |
| `Skills/DevOps/Playwright/playwright-netflix-login.js` | Netflix persistent profile login |
| `Skills/DevOps/Playwright/playwright-netflix-reauth.js` | Netflix session re-authenticator |
| `Skills/DevOps/Playwright/playwright-aliexpress-receipts.md` | AliExpress receipt retrieval docs (prototype, selectors not yet discovered) |
| `Skills/DevOps/Playwright/playwright-aliexpress-downloader.js` | AliExpress receipt downloader (prototype, --discover mode) |
| `Skills/DevOps/Playwright/playwright-aliexpress-login.js` | AliExpress persistent profile login |
| `Skills/DevOps/Playwright/playwright-aliexpress-reauth.js` | AliExpress session re-authenticator |
