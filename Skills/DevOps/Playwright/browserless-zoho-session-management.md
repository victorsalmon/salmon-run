---
name: infrastructure/zoho-session-management
description: Zoho session lifecycle management — persistent cookies across Browserless CDP connections to avoid daily sign-in limits. Use whenever Zoho Books browser automation is needed.
---

# Zoho Session Management — Avoiding the Daily Sign-In Limit

## ⛔ THE PROBLEM

### Daily Sign-In Limit

Zoho enforces a **~8-10 logins per day** limit. Each Browserless `connectOverCDP` + re-login burns one of these slots. Once exhausted, Zoho blocks ALL automation for 24h with `/preannouncement/block-sessions`.

**This is the #1 cause of Zoho automation failure.**

Every agent that reconnects and re-logs-in consumes a slot. If 3 agents reconnect 3 times each, that's 9 logins — blocked for the day.

### Maximum CONCURRENT Sessions Dialog

Separate from the daily limit, Zoho may show a **"maximum CONCURRENT sessions"** dialog during login. This is a dismissible overlay — NOT a block. It contains a blue "Terminate all sessions" button:

```javascript
// If body text contains "CONCURRENT", click the terminate button
const txt = await page.evaluate(() => document.body.innerText.substring(0, 1000));
if (txt.includes('CONCURRENT')) {
  await page.evaluate(() => {
    const btns = document.querySelectorAll('button');
    for (const b of btns) { if (b.textContent.includes('Terminate')) { b.click(); return; } }
  });
  await sleep(5000);
}
```

This dialog only appears when there are existing sessions from other devices/browsers. After terminating, login proceeds normally. **Do not confuse this with the daily sign-in limit block.**

## ✅ THE SOLUTION — Cookie Persistence

After login, save Zoho's session cookies (including httpOnly) via CDP `Network.getAllCookies`. Before each new CDP connection, inject saved cookies via `Network.setCookies` to restore the session without re-logging in.

The state file at `.zoho-session.json` records:
- All cookies (httpOnly + secure)
- localStorage
- Session age (2h TTL)

## Mandatory Session Check — Before Any Zoho Browser Work

**YOU MUST CHECK** whether a valid session exists before doing ANY Zoho browser automation:

```javascript
import { ZohoSession } from '/data/lib/zoho-session.mjs';

const session = new ZohoSession('/data/.zoho-session.json');
const saved = session.load();

if (saved && session.isSessionValid()) {
  console.log(`Valid session found (${(session.sessionAge()/60000).toFixed(0)}min old) — reusing`);
} else {
  console.log('No valid session — will login');
}
```

## Session Lifecycle

```
Initial run:
  connect → login once → save cookies → do work → disconnect
  
Subsequent runs (same day):
  connect → inject saved cookies → verify Zoho loaded (no signin page)
  → if session valid: do work (NO LOGIN)
  → if expired: re-login, save new cookies, do work
  
If blocked:
  "⛔ Zoho daily sign-in limit reached. Wait 24h."
  Delete .zoho-session.json and try again tomorrow.
```

## Using ZohoSession Helper

The session manager at `Skills/Bookkeeping/Scripts/zoho/zoho-session.mjs` handles all of this:

```javascript
import { ZohoSession } from '/data/lib/zoho-session.mjs';

const ws = `ws://FRAD_mcp_browserless:3003?token=${TOKEN}`;
const session = new ZohoSession('/data/.zoho-session.json');

// Connect — auto-restores session if valid
const { browser, page, blocked } = await session.connect(ws);
if (blocked) { process.exit(1); }

// Login if needed
if (page === null || page.url().includes('signin')) {
  const ok = await session.login(page, email, password, orgId);
  if (!ok) { process.exit(1); }
}

// Do work using `page`

// Disconnect — saves session state
await session.disconnect();
```

## ⚠️ CRITICAL RULES

1. **NEVER login more than once per day** — reuse saved cookies
2. **NEVER disconnect Browserless mid-work** — keep one session for all operations
3. **ALWAYS check `.zoho-session.json`** before starting any Zoho browser work
4. **ALWAYS verify `page.url()` doesn't contain `block-sessions`** after login/session restore
5. **If blocked, stop immediately** — do not retry. Delete session file. Wait 24h.

## Related

- `Skills/DevOps/Playwright/browserless.md` — Generic browserless reference (read first)
- `browserless-fundamentals.md` — CDP gotchas, SPA navigation
- `Infrastructure/Browserless/Sites/books.zoho.com/browserless-zoho-books-quick-categorize.md` — Zoho-specific automation details
