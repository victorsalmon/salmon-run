# Browserless Zoho Books — Automation Guide

> **Before reading this:** Read `Skills/DevOps/Playwright/browserless.md` (generic reference) and `Skills/DevOps/Playwright/browserless-browserless-fundamentals.md` first. Also read `Skills/DevOps/Playwright/browserless-zoho-session-management.md` for cookie persistence (prevents daily sign-in limit). This file adds Zoho Books-specific automation details.

## Overview

Zoho Books is an Ember.js SPA that uses hash-based routing. Automation through Browserless is needed for tasks the Zoho Books REST API does not support:

- **Categorizing statement-imported bank transactions** (API returns `code: 108003`)
- **Restoring excluded transactions** (no API endpoint)
- **Bulk operations** that the API blocks for statement-imported records

## Page Structure

### Quick Categorize Page

**Working URL pattern (no `group_by=payee`, individual rows):**
```
https://books.zoho.com/app/{ORG_ID}#/banking/quickcategorize?account_id={ACCT_ID}&account_name={NAME}&account_type={bank|credit_card}&from_date={DATE}&response_option=1&to_date={DATE}
```

| Parameter | Value | Purpose |
|-----------|-------|---------|
| `account_id` | Zoho account ID | Which bank/CC account |
| `account_name` | URL-encoded name | Display name header |
| `account_type` | `bank` or `credit_card` | Affects categorization direction |
| `from_date` / `to_date` | YYYY-MM-DD | Date range filter |

**Avoid:** `filter_by=TransactionDate.Custom` causes Zoho SPA error ("Invalid value passed with filter_by").  
**Avoid:** `group_by=payee` — with `filter_by` removed, the Zoho SPA may show 0 uncategorized count but still have rows.

**DOM structure** (from live inspection, 2026-06-29):
- Each row `<tr>` has multiple `<td>` cells at `data-col-index` positions
- **Account dropdown** (col-index=4): `.ac-box` inside `[data-auto-gen-binding-key="row.offset_account_id"]` — this is the category selector
- **Tax Rate dropdown** (col-index=6): `.ac-box` inside `[data-auto-gen-binding-key="row.tax_id"]` — **must NOT be targeted** (tax accounts reject expense category names)
- Categorize button: `button.btn.btn-primary.ember-view` with text "Categorize" (`type="submit"`)
- Pagination: `button[aria-label="Next Page"]`
- Row drag icon + checkbox per row: `.bulk-selection-cell`

**Key rule:** Target only `[data-auto-gen-binding-key="row.offset_account_id"] .ac-box` for account category selection. Do NOT use generic `.ac-box` selector (picks up Tax Rate dropdowns too, causing "No results found" errors).

**Batch pattern:** Set ALL account dropdowns on a page first, then click the single "Categorize" button once — saves all rows in one operation.

### TAS-Based Category Matching

The `TasMatcher` class in `lib/tas-matcher.js` looks up categories from the local TAS-2026.csv file by fuzzy-matching the transaction description text against previously categorized local transactions. This avoids hardcoded keyword rules for common merchants like Amazon.

**Precision guard:** The matcher requires at least 2 matching tokens (ignoring generic words like "payment", "fee", "misc") to return a match. Single-word matches are discarded to avoid false positives (e.g. "PAYMENT" matching bank fees instead of credit card payments).

**Fallback:** The script uses a `getCategory()` keyword function when TAS returns no match. Key mappings:

| Payee Pattern | Category | Zoho Account ID |
|--------------|----------|-----------------|
| PAYMENT - THANK YOU, AUTOMATIC PAYMENT | Credit Card Payments | `93310000000300002` |
| AMAZON | Other Expenses (→ TAS overrides to Office & General Expenses) | `93310000000000460` |
| CREDIT CARD, RBC CREDIT | Credit Card Payments | `93310000000300002` |
| (others) | Per keyword rules in `categorize-headed.js` | |

### Scripts

| Script | Purpose | Approach |
|--------|---------|----------|
| `categorize-headed.js` | **Canonical** — Quick Categorize with persistent Chrome profile | `launchPersistentContext` (headed), TAS matcher, batch Categorize click |
| `zoho-quick-categorize.js` | Legacy — fresh login, keyword-only | `chromium.launch()` (headless), `group_by=payee`, per-payee Categorize click |
| `zoho-one-time-login.js` | Set up persistent Chrome profile for session reuse | `launchPersistentContext` (headed), saves to Profile/ directory |

**Prefer `categorize-headed.js`** — it uses the persistent profile (avoids daily sign-in limit), batches Categorize clicks properly, and cross-references local TAS data for accurate categories.

### Reconciliation Script — Multi-Org

`zoho-reconcile.js` now covers **both orgs** in a single configuration-driven script:

| Org | Slug | Zoho Org ID | Accounts |
|-----|------|-------------|----------|
| Intersite Consulting | `intersite-consulting` | `925048093` | RBC-INTERSITE, MC 6258 |
| Room Rentals | `room-rentals` | `925004567` | RBC-FRA, RBC-VISA, TD-MLM, SCOTIA-TMH |

Statement balances are hardcoded in the `CONFIG` array (sourced from `~/intersite-docs/Taxes and Bookkeeping/reconciliation-periods.md`, which is regenerated from PDF bank statements via `Update-ReconciliationPeriods.ps1`).

**Filtering env vars** (optional):
- `ORG_FILTER` — run only one org (e.g., `room-rentals`)
- `ACCT_FILTER` — run only one account by name or ID
- `PERIOD_START` / `PERIOD_END` — run a subset of statement periods (1-indexed)

**Wrapper**: `Invoke-ZohoReconcile.ps1 -Org room-rentals -Account RBC-FRA`

### Key Zoho Books Hash Routes

| Page | Hash Route |
|------|-----------|
| Banking overview | `#/banking` |
| Account transactions | `#/banking/transactions?account_id={id}` |
| Quick Categorize | `#/banking/quickcategorize?account_id={id}&group_by=payee` |
| Reconciliation | `#/banking/reconciliations/{account_id}` |
| Chart of Accounts | `#/bookkeeping/chartofaccounts` |
| Bulk Update | `#/bookkeeping/bulkupdateaccounts` |

## SPA Navigation

Zoho Books is an Ember.js SPA. Navigating via `page.goto()` with a hash URL **kills the CDP WebSocket connection** to Browserless.

### Correct Navigation

```javascript
// Navigate to the app first
await page.goto(`https://books.zoho.com/app/${ORG_ID}`, { waitUntil: 'domcontentloaded' });
await sleep(5000);

// Navigate within SPA via hash change
await page.evaluate(() => {
  window.location.hash = '#/banking/quickcategorize?account_id=...&group_by=payee';
});
await sleep(8000); // Critical: SPA needs time to render
```

### Incorrect Navigation (Kills Connection)

```javascript
await page.goto('https://books.zoho.com/app/123#/banking/quickcategorize?...'); // DEAD
```

## Account IDs

Intersite Consulting Inc. (org_id: `925048093`):

| Account | Zoho Account ID | Type |
|---------|----------------|------|
| RBC-INTERSITE Chequing | `93310000000100019` | bank |
| MC 6258 Mastercard | `93310000000100013` | credit_card |

## Categorization

### Statement-Imported Transaction Limitation

Transactions imported via `POST /bankstatements` **cannot be categorized via the REST API** — the endpoint `POST /banktransactions/uncategorized/{id}/categorize/expenses` returns `code: 108003: "The uncategorized transaction cannot be matched"`.

**Only the Zoho web UI can categorize statement-imported transactions.** Use Quick Categorize with Group By Payee.

### Category Mapping

See `Skills/Bookkeeping/tx-categorization/categorization-rules.json` for the full rule set.

| Payee Pattern | Category | Account ID |
|--------------|----------|------------|
| PETRO, SHELL, CHEVRON, ESSO | [8962] Motor vehicles repairs and maintenance | `93310000000000424` |
| ZOHO, INTERSERVER, ANOMALY, OPENROUTER | [9150] Tech repair, support, subscriptions, peripherals | `93310000000582161` |
| HOME DEPOT, DULUX, TEMU | Repairs and Maintenance | `93310000000000457` |
| FREEDOM, FONGO | Software & IT Expenses | `93310000000000427` |
| MONTHLY FEE, PAY-FILE | Bank Fees and Charges | `93310000000000409` |
| UPSCALE HAVENS (credit) | Consulting Revenue | `93310000000149102` |
| UPSCALE HAVENS (debit) | Other Expenses | `93310000000000460` |
| AMAZON (tech items) | [9150] Tech repair, support, subscriptions, peripherals | `93310000000582161` |
| PAYMENT - THANK YOU, AUTOMATIC PAYMENT | Exclude | `93310000000161002` |
| PAD CCRA | Exclude | `93310000000161002` |
| E-TRANSFER, ONLINE BANKING TRANSFER | Exclude | `93310000000161002` |
| BC REGISTRIES | Professional Fees | `93310000000135091` |
| LEGALSHIELD | Professional Fees | `93310000000135091` |
| KAL TIRE, LORDCO, IMPARK | [8962] Motor vehicles repairs and maintenance | `93310000000000424` |
| PURCHASE INTEREST | Credit Card Charges | `93310000000000412` |

### Exclude Account

The `Exclude` account (`93310000000161002`) was created to replace Zoho's native "Exclude" toggle. Categorizing transactions to this account keeps them visible and auditable while separating them from legitimate expenses. Created via `POST /chartofaccounts`.

## Known Issues

### Maximum CONCURRENT Sessions Dialog

Zoho may show a "maximum CONCURRENT sessions" dialog after login. It contains a blue "Terminate all sessions" button that must be clicked before proceeding:

```javascript
// After login, check for concurrent sessions dialog
const bodyText = await page.evaluate(() => document.body.innerText.substring(0, 1000));
if (bodyText.includes('CONCURRENT')) {
  console.log('Concurrent sessions dialog — terminating...');
  await page.evaluate(() => {
    const buttons = document.querySelectorAll('button');
    for (const btn of buttons) {
      if (btn.textContent.includes('Terminate')) { btn.click(); return; }
    }
  });
  await sleep(5000);
}
```

This is distinct from the daily sign-in limit (which blocks logins entirely). The CONCURRENT dialog is dismissible — click the blue button once and proceed.

### Daily Sign-In Limit

Zoho enforces ~20 logins per day per account. After exceeding:
> "You have signed in to your Zoho account several times today. The maximum daily sign-in limit for a Zoho account is 20 successful sign-ins."

**Prevention:** Keep one session alive. Do NOT disconnect and reconnect between operations. A single Browserless session should handle all tasks for an account.

**Recovery:** Wait 24 hours for the counter to reset.

### "Invalid Account" When Saving Card Payment

**Symptom:** The Card Payment Save button closes the modal and shows "Invalid account" error (or silently fails with no visible error) when "To Account" is not properly set.

**Root cause (two layers):**

1. **Primary: Playwright `.click()` intercepted by Zoho's Ember.js overlay.** The To Account combobox receives the click event but Zoho's sidebar overlay intercepts the coordinate-based hit-test, so the autocomplete never registers the click.

2. **Secondary: Even when the autocomplete opens, selecting an option fails.** The `[role="option"]` selector matches sidebar `<li>` elements instead of dropdown items, or the option list is empty because the autocomplete didn't fully activate.

**Fix — native dispatchEvent + three-phase autocomplete with verification:**

```javascript
// Phase 1: Open the autocomplete via native dispatchEvent (NOT Playwright .click())
await page.evaluate(() => {
  const labels = document.querySelectorAll('label');
  for (const l of labels) {
    if (l.textContent.trim() === 'To Account') {
      const row = l.closest('.form-group.row, div.form-group, [class*="form"]');
      if (row) {
        const siblingCol = row.querySelector('.col-lg-8');
        const box = siblingCol ? siblingCol.querySelector('.ac-box, [role="combobox"]') : row.querySelector('.ac-box, [role="combobox"]');
        if (box) {
          // dispatchEvent bypasses Zoho's overlay interception
          box.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true }));
          box.dispatchEvent(new MouseEvent('mouseup', { bubbles: true, cancelable: true }));
          box.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
        }
      }
    }
  }
});
await sleep(2000);

// Phase 2: Verify dropdown opened (aria-expanded should be "true")
const expanded = await page.evaluate(() => {
  const labels = document.querySelectorAll('label');
  for (const l of labels) {
    if (l.textContent.trim() === 'To Account') {
      const row = l.closest('.form-group.row, div.form-group, [class*="form"]');
      if (row) {
        const box = row.querySelector('.ac-box, [role="combobox"]');
        return box?.getAttribute('aria-expanded');
      }
    }
  }
  return 'unknown';
});
if (expanded !== 'true') {
  console.error('❌ Dropdown did not open — overlay may still be blocking');
}

// Phase 3: Type to filter results
await page.keyboard.type('Intersite', { delay: 100 });
await sleep(2000);

// Phase 4: Click matching visible option (using dispatchEvent)
await page.evaluate(() => {
  const items = document.querySelectorAll('[role="option"], .ac-list-item, .ac-option');
  for (const el of items) {
    if (el.offsetParent !== null) {
      const text = el.textContent.trim();
      if (text.includes('Intersite') && !text.includes('Mastercard')) {
        el.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true }));
        el.dispatchEvent(new MouseEvent('mouseup', { bubbles: true, cancelable: true }));
        el.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
        return;
      }
    }
  }
});
await sleep(1500);
```

### CDP Connection Drops During SPA Navigation

**Symptom:** `page.evaluate()` throws `Target page, context or browser has been closed` after navigating to a hash URL.

**Root cause:** Browserless CDP WebSocket connections are tied to the page frame. Hash navigation via `page.goto()` triggers a frame detach that severs the connection.

**Solution:** Use `page.evaluate(() => { window.location.hash = '#/route'; })` instead of `page.goto()` for SPA navigation.

### Screenshot Crashes After Navigation

**Symptom:** `page.screenshot()` throws "Session closed" error after SPA navigation.

**Root cause:** Same frame detachment issue as above.

**Solution:** Take screenshots BEFORE navigating, or avoid them entirely when working with SPAs.

### SPA Frame Detachment

**Symptom:** `Attempted to use detached Frame '...'` error after Ember.js view transitions.

**Solution:** Use sequential `page.evaluate()` calls for each interaction — never store element handles across navigations.

### Lessons Learned — 2026-06-09

**What Worked**:
- Running `zoho-quick-categorize.js` locally with Playwright (no Browserless container needed) — Chromium launched directly via `chromium.launch()`, no CDP connection, no WebSocket drops.
- Local Playwright is installed at `Infrastructure/Browserless/Sites/books.zoho.com/node_modules/playwright`.
- Zoho OAuth tokens obtained from AWS SM (`Interclaw/FRAD/Provisioning`) via `aws sso login --profile intersite` then `get-secret-value` — works without browser automation.
- Login with ZOHO_BOOKS_RWUSER (`Bookkeeper@clocklobster.com`) and ZOHO_BOOKS_RWPASS — Playwright fills `input#login_id` and `input#password`, presses Enter, waits for redirect.

**What Didn't Work**:
- Selecting payee groups via `.font-medium.text-medium.text-primary-black` CSS class — when no uncategorized transactions exist, the selector returns 0 elements, which is correct behavior (just reports "Found 0 payee groups").
- Quick Categorize hash route with `filter_by=TransactionDate.Custom&from_date=2026-04-01&to_date=2026-06-05` showed no uncategorized transactions — the books were already clean for that range.

**Improvements for next run**:
- When testing Quick Categorize, if 0 payee groups found, check wider date range or verify no uncategorized transactions exist via `GET /bankaccounts/{id}?filter_by=Status.Uncategorized`.
- Prefer local Playwright execution over Browserless for Zoho scripts — simpler debugging, no CDP connection fragility.

**Helpful Information**:
- Zoho login credentials are in AWS SM key `Interclaw/FRAD/Provisioning`: `ZOHO_BOOKS_RWUSER` and `ZOHO_BOOKS_RWPASS`.
- AWS SSO refresh: `aws sso login --profile intersite` (opens browser), then `aws secretsmanager get-secret-value --secret-id Interclaw/FRAD/Provisioning --profile intersite --region ca-central-1`.
- Local Node.js is available at `E:\Applications\Node.js\node.exe` v24.15.0.
- Playwright is available at `Infrastructure/Browserless/Sites/books.zoho.com/node_modules/playwright`.

## Related Files

| File | Purpose |
|------|---------|
| **`browserless-zoho-books-quick-categorize.md`** | **Dedicated Quick Categorize skill** — detailed workflow, selectors, batch pattern |
| `browserless-fundamentals.md` | General Browserless connection, SPA nav, session management |
| `browserless-lessons-learned.md` | Mistakes and solutions (Zoho API gap, login verification) |
| `playwright-amazon-receipts.md` | Amazon receipt retrieval (separate toolchain) |
| `Skills/DevOps/Playwright/playwright-aliexpress-receipts.md` | AliExpress receipt retrieval (separate toolchain, group matching) |
| `Infrastructure/Browserless/Archived/books.zoho.com/zoho-browserless.md` | Legacy Zoho Browserless doc (Puppeteer, SPA details) |
| `Plugins/clock-lobster-books/account/categorize-transactions/SKILL.md` | Categorization procedure and vendor mapping |
| `Skills/Bookkeeping/tx-categorization/categorization-rules.json` | Machine-readable keyword→account mapping |
| `Infrastructure/Browserless/Sites/books.zoho.com/categorize-headed.js` | **Canonical** Quick Categorize script (persistent session, TAS matcher, batch) |
| `Infrastructure/Browserless/Sites/books.zoho.com/zoho-quick-categorize.js` | Legacy Quick Categorize script (headless, group_by=payee) |
| `Infrastructure/Browserless/Sites/books.zoho.com/zoho-one-time-login.js` | One-time persistent profile setup |
| `Infrastructure/Browserless/Sites/books.zoho.com/lib/tas-matcher.js` | TAS cross-reference module for local category lookup |
| `Skills/Archive/bookkeeping-books-local-investigate-local-category.md` | Skill: look up category by cross-referencing local TAS |
| `Infrastructure/Browserless/Sites/books.zoho.com/zoho-reconcile.js` | Playwright script for monthly reconciliation |
| `~/intersite-docs/Documentation/Memory/mem-todo-browser-intersite.md` | Zoho navigation URLs and browser task list (path from `_project-map.json`) |
