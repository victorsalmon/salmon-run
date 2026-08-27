# Browserless Fundamentals — Agentic Web Automation

> **Before reading this:** Read `Skills/DevOps/Playwright/browserless.md` (generic reference) first — it covers prerequisites, session persistence, Zoho sign-in limits, and the inheritance chain. This file adds fundamental-level detail on CDP gotchas, SPA navigation, and Playwright patterns.

## Overview

Browserless provides headless Chrome automation for tasks REST APIs cannot do: login flows, form filling, SPA navigation, PDF generation, screenshots.

The fleet supports **two modes** — choose the right one:

| Mode | Image/Provider | Reachable from | Use for |
|------|---------------|----------------|---------|
| **Self-hosted** | `ghcr.io/browserless/chromium` on overlay network | Docker containers on `service_net` | Zoho Books, internal tools |
| **Cloud SaaS** | `chrome.browserless.io` (not provisioned) | Anywhere with API key | Stealth/anti-bot scenarios |

---

## Mode 1: Self-Hosted Container (`FRAD_mcp_browserless`)

| Property | Value |
|----------|-------|
| Service | `FRAD_mcp_browserless` |
| Image | `ghcr.io/browserless/chromium:latest` |
| Network | `service_net` (overlay — not reachable from host) |
| Port | 3003 (upstream-dictated — see ADR 0014 §1 "Upstream-dictated internal ports") |
| Auth | `BROWSERLESS_TOKEN` in AWS SM `Interclaw/FRAD/Provisioning` |
| CONCURRENT | 5 |
| TIMEOUT | 120000 (2 min) |
| Pre-installed | `puppeteer-core` only — `playwright` is NOT in this image |

### Connection — Playwright (Recommended)

```javascript
const { chromium } = require('playwright');
const browser = await chromium.connectOverCDP(`ws://FRAD_mcp_browserless:3003?token=${TOKEN}`);
const page = await browser.newPage();
```

`connectOverCDP` uses Chrome DevTools Protocol — the **only** method Browserless supports. Returns a Browser object with limited API (no `browser.pages()`, no `browser.contexts()`).

### Connection — Puppeteer (Deprecated)

```javascript
const pptr = require('puppeteer-core');
const browser = await pptr.connect({ browserWSEndpoint: `ws://FRAD_mcp_browserless:3003?token=${TOKEN}` });
```

Works with Browserless but all new scripts should use Playwright.

### Connection — Playwright `connect()` (WRONG)

```javascript
const browser = await chromium.connect(`ws://FRAD_mcp_browserless:3003?token=${TOKEN}`); // HANGS
```

Uses Playwright's proprietary protocol, not CDP. Hangs indefinitely.

### REST Endpoints (no browser needed)

| Endpoint | Method | Use |
|----------|--------|-----|
| `/scrape?token=TOKEN` | POST | Read-only page scraping |
| `/screenshot?token=TOKEN` | POST | Screenshot capture |
| `/pdf?token=TOKEN` | POST | PDF generation |
| `/pressure?token=TOKEN` | GET | Health check |

---

## Running Scripts

### Via Docker Helper Container (Browserless on overlay network)

```powershell
docker run --rm -i --network service_net `
  -e BROWSERLESS_TOKEN="your-token" `
  -e PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 `
  -v "C:\path\to\scripts:/data" `
  -w /data `
  node:20-slim sh -c "npm install playwright --no-audit --no-fund && node /data/script.js"
```

Notes:
- `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1` — we use remote Browserless, not local Chromium
- `node:20-slim` is the lightest Node image
- Playwright must be `npm install`-ed each run (ephemeral container). Build a custom image to cache it.
- `npm install` separately from script execution — `&&` hides install failures

### Locally (Debugging on Windows)

```powershell
$env:BROWSERLESS_TOKEN = "..."
npm install playwright
node script.js
```

### Locally with Real Chrome (not Browserless)

For sites that block headless Chrome (Amazon, etc.):

```powershell
npm install puppeteer (or playwright)
node Infrastructure/Browserless/Sites/amazon.ca/amazon-persistent-downloader.js
```

See `playwright-amazon-receipts.md` for the full approach.

---

## Session Management — Critical

**Browser sessions carry authenticated state (cookies, tokens, passkeys). Each new connection to Browserless creates a fresh, empty browser context with no cookies.**

### The Golden Rule

**Keep one browser session alive for the entire duration of work on a website.** Do not disconnect and reconnect between operations — every new connection requires re-authentication, which:
- Consumes daily sign-in limits (Zoho blocks after ~20 logins per day)
- Triggers CAPTCHA and device-claiming flows (Amazon `ax/claim`)
- Invalidates MFA trust tokens

```javascript
// GOOD — single session, all operations in sequence:
const browser = await chromium.connectOverCDP(WEB_SOCKET);
const page = await browser.newPage();
await login(page);
await operation1(page);  // same page
await operation2(page);  // same page
await browser.close();

// BAD — new session per operation:
const op1 = async () => {
  const b = await chromium.connectOverCDP(WS);  // new session!
  await login(b.newPage());                      // must re-login
  await b.close();
};
```

### Sign-In Limits

| Service | Limit | Recovery |
|---------|-------|----------|
| Zoho Books | ~20 logins/day/account | 24h reset |
| Amazon | ~3-5 headless attempts | CAPTCHA + device-claim |
| General SaaS | varies | Check before automating |

---

## CDP Connection — Critical Gotchas

### `connectOverCDP` Limitations

When using `connectOverCDP`:
- `browser.pages()` is **NOT available** — cannot list existing pages
- `browser.contexts()` is **NOT available** — CDP doesn't expose Playwright contexts
- The WebSocket is tied to the page's frame — certain navigations sever it
- If the only page dies, you must close the browser and create a new connection (re-login required)

### Hash Navigation Kills the Connection

`page.goto()` to a URL with a hash fragment (e.g., `https://app.com#/route`) triggers a frame detachment that severs the CDP WebSocket. The behavior is **non-deterministic** — may work once, fail the next run.

### Workaround: Run Playwright Inside the Container (instead of CDP)

When CDP connections keep dying on SPA navigation, the most reliable fix is to run Playwright **inside the browserless container itself** using `chromium.launch()` instead of `chromium.connectOverCDP()`. The browserless container ships with Node.js and Playwright pre-installed — you can copy your script in and execute it directly, launching a fresh Chromium instance that's not subject to frame-detachment issues.

```javascript
// ❌ Unreliable: CDP connection to Browserless — SPA nav kills page
const browser = await chromium.connectOverCDP('ws://FRAD_mcp_browserless:3003?token=...');

// ✅ Reliable: Launch Chromium directly inside the container
const browser = await chromium.launch({
  headless: true,
  args: ['--no-sandbox', '--disable-setuid-sandbox']
});
```

**Workflow:**
```powershell
# Copy script to the browserless container
docker cp ./script.js FRAD_mcp_browserless.1.xxx:/tmp/script.js

# Run inside container (avoids CDP entirely)
docker exec FRAD_mcp_browserless.1.xxx sh -c "node /tmp/script.js"
```

The downside is that each `chromium.launch()` burns a Zoho login, so you must batch ALL operations for a single account into one script to stay within the 20-login/day limit.

```javascript
// KILLS CONNECTION:
await page.goto('https://books.zoho.com/app/ORG_ID#/banking/quickcategorize');

// SAFE — stays on same page, changes hash only:
await page.evaluate(() => { window.location.hash = '#/banking/quickcategorize'; });
await sleep(8000);  // SPA render time
```

**Navigations that kill the connection:**
- `page.goto()` to a URL with a hash fragment
- `page.goto()` to the same base URL already on (triggers full reload)
- Any navigation causing full page reload in an SPA

**Navigations that are safe:**
- `page.evaluate()` to change `window.location.hash`
- `page.goto()` to a completely different domain
- `page.goto()` to a URL without a hash fragment

### `page.url()` Returns Stale Data

After the CDP connection drops, `page.url()` still returns the last known URL. **Always verify with `page.evaluate()`:**

```javascript
// UNRELIABLE:
console.log(page.url());  // May be stale

// RELIABLE:
try {
  const title = await page.evaluate(() => document.title);
  console.log('Page is alive:', title);
} catch (e) {
  console.log('Page is dead:', e.message);
  // Must reconnect
}
```

### Screenshots After SPA Navigation Crash

`page.screenshot()` and `page.pdf()` throw "Session closed" after SPA navigation via hash. Take screenshots BEFORE navigating, or use fresh tabs.

---

## SPA Navigation — Safe Patterns

Single Page Applications (Zoho Books/Ember.js, Amazon, etc.) manage routing via URL hash fragments.

### Safe Patterns

**1. Hash change via `evaluate` (safest):**
```javascript
await page.evaluate(() => { window.location.hash = '#/banking/quickcategorize?account_id=123'; });
await sleep(8000);
```

**2. Direct URL (non-hash only):**
```javascript
await page.goto('https://example.com/login', { waitUntil: 'networkidle0', timeout: 60000 });
```

**3. Two-step (base → hash):**
```javascript
await page.goto('https://app.example.com', { waitUntil: 'domcontentloaded' });
await sleep(3000);
await page.evaluate(() => { window.location.hash = '#/target-route'; });
await sleep(8000);
```

### What Kills the Session
- `page.goto()` with hash fragment
- `page.goto()` to same base URL
- `page.screenshot()` after SPA navigation
- Storing element handles across SPA view transitions

---

## Key API Differences: Playwright vs Puppeteer

| Feature | Playwright | Puppeteer |
|---------|-----------|-----------|
| Viewport | `page.setViewportSize({ w, h })` | `page.setViewport({ w, h })` |
| Connect to CDP | `chromium.connectOverCDP(wsUrl)` | `puppeteer.connect({ browserWSEndpoint })` |
| List pages | NOT available via CDP | `browser.pages()` |
| Type text | `page.fill(selector, text)` | `page.type(selector, text)` |
| New context | `browser.newContext()` | `browser.createIncognitoBrowserContext()` |
| Close browser | `browser.close()` | `browser.close()` |

---

## Zoho Ember.js — Click Interception by Overlay

Zoho Books' Ember.js SPA has a sidebar overlay (`div.main-nav-lhs`) and modal backdrop elements that intercept Playwright's `.click()` method. The click lands on the overlay instead of the target element, so the intended action never fires.

**Symptom:** Element is found, `.click()` returns success, but nothing happens on screen. The dropdown doesn't open, the modal doesn't appear, or the page doesn't navigate.

### Fix: Use Native `dispatchEvent` Instead of Playwright `click()`

For any Zoho Ember.js component — especially autocompletes, dropdown toggles, and buttons inside modals — use `page.evaluate()` with native `MouseEvent` dispatch:

```javascript
// ❌ BROKEN: Playwright .click() intercepted by Zoho overlay
await page.locator('[role="combobox"]').click();

// ✅ WORKS: Native event dispatch from within the page context
await page.evaluate(() => {
  const box = document.querySelector('[role="combobox"]');
  if (box) {
    box.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true }));
    box.dispatchEvent(new MouseEvent('mouseup', { bubbles: true, cancelable: true }));
    box.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
  }
});
```

**Why this works:** Playwright's `click()` simulates a mouse click at element coordinates. The CDP event traverses the hit-test system, which Zoho's sidebar overlay intercepts. `dispatchEvent` sends the event directly to the target element's event listeners, bypassing coordinate-based hit testing and overlay interception.

**Exception:** For standard HTML inputs (`<input>`, `<textarea>`, `<select>`), Playwright's `.click()` and `.fill()` work fine. The interception only affects Ember-custom components like `.ac-box`.

### Autocomplete Dropdowns (Zoho Books Pattern)

Zoho uses autocomplete inputs (not `<select>`):

```javascript
// 1. Open autocomplete
await page.evaluate(() => {
  const acBox = document.querySelector('.ac-box');
  const toggle = acBox?.querySelector('.ac-toggle-container');
  if (toggle) toggle.click();
});

// 2. Type to search
await page.keyboard.type('Search Text', { delay: 80 });
await sleep(1500);

// 3. Click matching result
await page.evaluate(() => {
  const items = document.querySelectorAll('.ac-list-item, .ac-option');
  for (const item of items) {
    if (item.textContent.includes('Target')) {
      item.click();
      break;
    }
  }
});
```

---

## Error Handling

Every operation after SPA navigation should be in try/catch — the page may die at any point:

```javascript
try {
  const result = await page.evaluate(() => document.body.innerText);
} catch (e) {
  console.error('Page unavailable:', e.message);
  // Reconnect needed
}
```

---

## Rate Limits & Best Practices

- **300ms minimum** between Zoho API calls
- **2000ms sleep** between rapid browser interactions
- **Use try/catch** around every `page.evaluate()` and `page.goto()` in SPAs
- **One sign-in per session** — do all work in one continuous connection
- **Write scripts to files** for Docker execution (PowerShell quoting mangles inline JS)
- **Build custom Docker image** with Playwright pre-installed to avoid 30-60s `npm install` per run

### Individual-Before-Batch Protocol

**Always test ONE item before processing a batch.** This is a default method for all API and browser automation, not an optional optimization:

```javascript
// ✅ CORRECT — test first, then batch:
const testItem = items[0];
const result = await process(testItem);
if (!result.success) {
  console.error('Test failed — fix before batching. Reason:', result.error);
  // Fix the issue, then retry the test
  return;
}
console.log('Test passed — processing remaining', items.length - 1, 'items');
for (const item of items.slice(1)) {
  await process(item);
}

// ❌ WRONG — batch immediately, waste rate limits:
for (const item of items) {           // First 5 fail — burned 5 API calls
  await process(item);
}
```

**Why this is mandatory:**
- Zoho API: Each failed call is wasted — you get ~5 OAuth refreshes before 15-30m block
- Zoho UI: Each failed login attempt burns one of ~20 daily sign-in slots
- Browserless: Each bad connection attempt may trigger concurrent sessions or block dialogs
- General API: Rate limits, daily quotas, and account bans escalate with call volume

**Stopping on first failure** is a circuit breaker that preserves your remaining quota for the fix attempt. After fixing, retry the single test item before resuming the batch.

---

## Downloading Browser Binary (Local Runs Only)

Not needed when connecting to Browserless:

```powershell
npm install playwright
npx playwright install chromium   # for local runs only
```

Set `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1` when using remote Browserless.

---

## Related Files

| File | Purpose |
|------|---------|
| `Skills/DevOps/Playwright/browserless-browserless-zoho-books.md` | Zoho Books automation — Quick Categorize, SPA, account mapping |
| `Skills/DevOps/Playwright/playwright-amazon-receipts.md` | Amazon receipt retrieval — local Chrome, what worked/didn't |
| `Skills/DevOps/Playwright/playwright-aliexpress-receipts.md` | AliExpress receipt retrieval — group matching, subset-sum aggregation |
| `Archived/Skills/Infrastructure/Browserless/Skills/browserless-lessons-learned.md` | Troubleshooting log — mistakes and solutions (non-duplicate entries) |
| `Skills/DevOps/Playwright/browserless.md` | Canonical fleet browser automation skill |
| `Infrastructure/mcp_browserless.Dockerfile` | Container definition |
| `Infrastructure/Browserless/Archived/books.zoho.com/zoho-browserless.md` | Legacy Zoho doc (Puppeteer, detailed SPA) |
| `Infrastructure/Browserless/Sites/books.zoho.com/zoho-quick-categorize.js` | Playwright script for Quick Categorize |
| `Infrastructure/Browserless/Sites/books.zoho.com/Invoke-ZohoQuickCategorize.ps1` | PowerShell wrapper for Docker-based execution |
| `docs/Reference/Decisions/0014-port-allocation-scheme.md` | Port 3003 for mcp_browserless (upstream-dictated) |
