# Amazon Receipt Retrieval — Browserless Cannot Do It

## The Core Problem

**Browserless (headless Chrome) cannot automate Amazon.** Amazon blocks headless Chrome with CAPTCHA, passkey challenges (`ax/claim`), and device-claiming pages after ~3-5 attempts. Cookie export/import doesn't help — Amazon sessions expire and trigger OTP.

**Working approach:** Run Puppeteer on the **Windows host** with the user's **real installed Chrome** (`headless: false`). The user logs in once, the script navigates the Transactions page and saves order PDFs.

---

## What Does NOT Work (all tried, all failed)

| Approach | Why it failed |
|----------|---------------|
| Browserless `connectOverCDP` | Headless detection → CAPTCHA + `ax/claim` loop |
| Browserless Puppeteer `connect` | Same headless detection issue |
| Cookie export/import to Browserless | Sessions expire, OTP triggered, `ax/claim` on each deep-link |
| Batch via CDP with stealth params | `&stealth=true` helps initially but still fails after a few orders |
| `fetch()` from authenticated homepage | CORS/session mismatch — returns sign-in page |
| v1 batch-of-6 with Puppeteer+CDP | Unreliable, session lost mid-batch, OTP on every new connection |
| v2 hybrid (auth then fetch+setContent) | `fetch` returns sign-in, CDP frame issues |
| Cookie-based validator + batch | Session validation passes but batch still fails partway |
| Cookies pasted via chat/CLI | Chat UIs truncate long session token values silently — always verify length vs DevTools export |

---

## What Works: Local Real Chrome

**One canonical script:** `amazon-persistent-downloader.js`. This is the ONLY working version. All other Amazon scripts have been deprecated and moved to `Infrastructure/Browserless/Archived/amazon.ca/` with a `DEPRECATED-` prefix.

| Script | Profile | Session | Status |
|---|---|---|---|
| `amazon-persistent-downloader.js` | **Persistent** (`Profile/`) | Survives restarts | **CANONICAL — use this** |
| `amazon-persistent-downloader.js` | Fresh each run | Lost on restart | **DEPRECATED — archived.** Broken with Playwright v1.60 (`networkidle2` removed, multi-arg `evaluate` removed). |

### Persistent Downloader

**File:** `Infrastructure/Browserless/Sites/amazon.ca/amazon-persistent-downloader.js`

Uses `chromium.launchPersistentContext(DATA_DIR)` — Chrome profile saves to disk. On subsequent runs, the login session is already there. The session check (`body.includes('Hello')`) detects this and skips the login wait.

All other details (matching, pagination, output) are identical to `amazon-persistent-downloader.js` below.

### amazon-persistent-downloader.js

**Script:** `Infrastructure/Browserless/Sites/amazon.ca/amazon-persistent-downloader.js` (Playwright, `headless: false`)

### How It Works

1. **Opens visible Chrome** via `puppeteer.launch({ headless: false })`
2. **Navigates** to `https://www.amazon.ca/cpe/yourpayments/transactions`
3. **Waits for manual login** — polls for "Hello" in body text (not "Sign in")
4. **Scans paginated transaction cards** matching by **amount + card suffix** (`****6258`)
5. **Clicks the order link**, saves page as PDF with semantic filename
6. **Goes back**, continues scanning from current position (newest→oldest)
7. **Checkpoint file** (`download-checkpoint.json`) enables resume if interrupted

### Transaction Matching in the DOM

```html
<div class="apx-transactions-line-item-component-container">
  <div>Mastercard ****6258</div>           <!-- card suffix -->
  <div>-$31.35</div>                        <!-- amount (debit = minus sign) -->
  <a href="...orderID=702-1121679-3593054">Order #702-1121679-3593054</a>
  <span>AMZN Mktp CA</span>                <!-- merchant description -->
</div>
```

Match by **amount + card suffix together in the same container**. Amount format is `-$31.35` (negative, no comma). Amount alone is insufficient (multiple orders may have the same total). Card suffix alone is insufficient (all transactions share the card).

**Clicking the order link** (not navigating via `page.goto()`) preserves the session because the click originates from within Amazon's own UI. Direct URL navigation triggers CSRF protection and redirects to sign-in.

### Order ID Formats

Amazon uses two order ID formats:
- **Short alphanumeric** (e.g., `WH5Z81VG3`) — appears in bank statement descriptions: `AMZN Mktp CA*WH5Z81VG3 TORONTO`
- **Long numeric** (e.g., `702-1121679-3593054`) — appears on the Transactions page and order links

The short IDs from statements are NOT directly searchable — you must match by amount + date + card.

### Pagination Details

The "Next page" button HTML:
```html
<input name="ppw-widgetEvent:DefaultNextPageNavigationEvent:{...}" class="a-button-input" type="submit">
```
Select by `input[name^="ppw-widgetEvent:DefaultNextPageNavigationEvent"]`. A "Previous page" button uses `DefaultPreviousPageNavigationEvent`.

### Order Processing Order — Newest First

**Process orders newest-first** (reverse chronological). The Transactions page starts at the most recent statement and paginates backward. Processing newest→oldest means:
- Multiple orders from the same statement period are found on the current page without re-paginating
- Each next order is on the same page or one page deeper — never going back
- The fallback (reload page, paginate from top) still works if anything fails

### After-Download Navigation — Back Button, Not Reload

After saving an order PDF, **use `page.goBack()`** to return to the transactions list. Then scan from **page 1** for the next order.

**IMPORTANT — page counting fix (2026-06-03):** Amazon's SPA may reset the transaction pagination to page 1 after `goBack()`. The script used to track `currentPage` and assume goBack returned to the same position, but this was unreliable — orders were silently skipped when the counter drifted. The fix: **always reset to page 1** after goBack. This is slightly slower (re-scans already-viewed pages) but reliable. The script now has no pagination position tracking.

If `goBack()` returns 0 containers (Amazon sometimes loses context), fall back to `page.goto()` the transactions URL, which resets to page 1.

### Script Auto-Exit

The script auto-closes the browser 2 seconds after completing all orders. Press Ctrl+C to abort the close if you need to inspect the browser.

### Persistent Session Between Runs

The script uses `chromium.launchPersistentContext(DATA_DIR)` — Chrome profile saves to `Infrastructure/Browserless/Sites/amazon.ca/Profile/`. On subsequent runs, the login session persists. The session detection and re-navigation (`page.url()` check for `transactions` in URL) skips the login wait if the session is still alive.

**One-time setup:** Run the script once. When Chrome opens, sign in to Amazon.ca. The session is saved. Future runs skip login entirely.

**Session loss recovery:** If the script reports "Session lost", Amazon's session expired. Close Chrome, delete `Infrastructure/Browserless/Sites/amazon.ca/Profile/` (or sign out and back in), and re-run.

### Debugging Matching Failures

If a transaction isn't found, dump the actual page text and container count:
```javascript
const containerCount = await page.evaluate(() => document.querySelectorAll('.apx-transactions-line-item-component-container').length);
const sample = await page.evaluate(() => document.body.innerText.substring(0, 800));
console.log(`Containers: ${containerCount}, Text: "${sample.substring(0, 200)}..."`);
```

Common failure patterns:
| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `0 containers found` | Wrong page loaded, or page structure changed | Navigate to `cpe/yourpayments/transactions` manually |
| Amount format mismatch | Amount shows as `$31.35` not `-$31.35` | Check page text and adjust pattern |
| `No more pages` immediately | Only 1 page of transactions visible | Change date filter in Amazon UI to show full fiscal year |
| "Sign in" in page text | Session expired | Re-login in the browser window |
| Not found on any of 30 pages | Too far back (early fiscal year) | Change date filter or reduce pagination start page |

### Limitations

- **Slow for old orders** — orders from early fiscal year (Apr 2025) may require 10+ pages of pagination, several minutes each
- **Requires visible Chrome** — the browser window must stay open during the entire run
- **Amount collisions** — if two transactions have the same amount on the same card, the script may click the wrong one. Date proximity filter mitigates but isn't foolproof

### Key Details

| Detail | Value |
|--------|-------|
| Page URL | `https://www.amazon.ca/cpe/yourpayments/transactions` |
| Card suffix | `****6258` (MC 6258 Mastercard) |
| Sort order | Newest first (page starts at present, paginates backward) |
| Pagination | Click "Next Page" button, max 30 pages |
| Session check | `!body.includes('Sign in') && body.includes('Hello')` |
| Resume | Checkpoint writes `completed` order IDs as JSON array |
| Output dir | `rbc-6258-ingest/` (set via `OUTPUT_DIR` env) |
| Output format | `{date} - {amount} - {seller} - {summary}.pdf` |
| Orders JSON | `amazon-orders-to-retrieve.json` — array of `{order_id, amount, date, description, seller?, summary?}` |
| Seller extraction | After download, open each PDF and extract **"Sold by / Vendu par:"** vendor name. Never use "Amazon.ca" as a generic vendor — use the actual seller entity from the invoice. |

### Session Keepalive

- Script runs in visible Chrome window
- User logged in via normal browser session
- No OTP, no CAPTCHA as long as session stays alive
- If session lost, script breaks with "Session lost" message

### Script Evolution (for reference)

| Script | Approach | Status |
|--------|----------|--------|
| `amazon-persistent-downloader.js` | **Persistent Chrome profile (working, Playwright v1.52+)** | **CANONICAL — use this** |
| `amazon-persistent-downloader.js` | Local real Chrome, fresh profile | **DEPRECATED — archived.** Broken with Playwright v1.60. Use persistent version. |

### 2026-06-03 fixes applied:
- **`networkidle2` → `networkidle`**: Playwright v1.52+ removed `networkidle2`. Use `networkidle` or omit `waitUntil`.
- **`page.evaluate()` multi-arg syntax**: Playwright v1.52+ requires object-wrapped args: `page.evaluate(({amt, card}) => {...}, {amt, card})` instead of `page.evaluate((a,b) => {...}, a, b)`
- **`page.goto()` error swallowing**: `.catch(() => {})` was hiding navigation failures. Always log the error, then fall back without `waitUntil`.
- **`browser.pages()[0]` vs `browser.newPage()`**: `launchPersistentContext` opens Chrome with a visible default page. Use `pages[0]` (existing tab), not `newPage()` (hidden tab).
- **`page.goBack()` for navigation**: After saving a PDF, use `goBack()` to return to the transactions list at the same pagination position. Fall back to `goto()` if containers don't load.
- **date format**: Convert from `M/D/YYYY` to `YYYY-MM-DD` for filenames.
- **seller field**: Allow dots in seller name regex `[^\w\s.-]` so `Amazon.ca` doesn't become `Amazonca`.
- **Max pages**: Increased to 60 (older orders may be 30+ pages deep). Now configurable via `MAX_PAGES` env var (default 200).
- **Page counting fix**: `page.goBack()` may reset Amazon's SPA to page 1. Script now always resets `currentPage = 1` after goBack instead of assuming position is preserved. This is slightly slower (re-scans already-viewed pages) but eliminates silent order-skipping.
- **Auto-close**: Script closes browser automatically 2s after completion. Ctrl+C to abort.
| `amazon-invoice-downloader.js` | v1 — CDP batch of 6, cookie persistence | Failed (session unreliable) |
| `amazon-invoice-downloader-v2.js` | v2 — CDP+fetch hybrid | Failed (fetch returns sign-in) |
| `amazon-interactive-downloader.js` | Interactive login + `window.location` via CDP | Failed (hash nav kills CDP) |
| `amazon-cookie-downloader.js` | Cookie export→batch | Failed (session expires mid-batch) |
| `amazon-login-debug.js` | Element dump helper | Debug tool only |

---

## Receipt Renaming & Archiving

After Amazon PDFs are downloaded (and other vendor receipts collected), run:

### `Consolidate-Receipts.ps1`

Renames all receipts to semantic filenames and consolidates into `Complete/`.

**Semantic naming convention:**
```
YYYY-MM-DD - amount - Vendor - Summary.ext
2026-01-28 - 31.35 - Amazon.ca - Order Summary.pdf
2026-03-26 - 44.89 - BC Registry - BC Government Registration.pdf
2026-04-09 - 14.40 - Kilo Code Inc - Kilo Code AI Coding Service.pdf
```

**What it does:**
1. Amazon PDFs: parses original `M-D-YYYY` → `YYYY-MM-DD`
2. New receipts: matches against a hardcoded `$ReceiptMap` (vendor pattern → date/amount/vendor/summary)
3. Copies all renamed files to `Complete/` (doesn't move originals)
4. Generates `manifest.csv` with columns: `filename, original_filename, date, amount, vendor`

### `Invoke-BookkeepingArchive.ps1`

After processing is complete, archives to the permanent intersite-docs structure:
- Copies `Complete/` receipts to archive
- Copies bank statements
- Copies reconciliation reports
- Writes `_archive-manifest.json`

---

## Related Files

| File | Purpose |
|------|---------|
| `Infrastructure/Browserless/Sites/amazon.ca/amazon-persistent-downloader.js` | **CANONICAL — the only working Amazon receipt downloader** |
| `Infrastructure/Browserless/Sites/amazon.ca/amazon-persistent-downloader.js` | **DEPRECATED** — broken with Playwright v1.60 |
| `Infrastructure/Browserless/Archived/amazon.ca/DEPRECATED-amazon-invoice-downloader.js` | v1 — CDP batch (failed) |
| `Infrastructure/Browserless/Archived/amazon.ca/DEPRECATED-amazon-invoice-downloader-v2.js` | v2 — fetch hybrid (failed) |
| `Infrastructure/Browserless/Archived/amazon.ca/DEPRECATED-amazon-interactive-downloader.js` | Interactive CDP (failed) |
| `Infrastructure/Browserless/Archived/amazon.ca/DEPRECATED-amazon-cookie-downloader.js` | Cookie-based batch (failed) |
| `Infrastructure/Browserless/Sites/amazon.ca/amazon-reauth.mjs` | Standalone session re-authenticator (no order downloads) |
| `Scripts/Admin/Consolidate-Receipts.ps1` | Renames receipts to semantic filenames |
| `Scripts/Admin/Invoke-BookkeepingArchive.ps1` | Archives completed bookkeeping data |
| `Skills/DevOps/Playwright/browserless-browserless-fundamentals.md` | General Browserless patterns and CDP gotchas |
| `Plugins/clock-lobster-books/account/zoho-known-issues/SKILL.md` | Zoho known issues and workarounds |

## Persistent Session Re-Authentication

When the Amazon session expires (the downloader redirects to sign-in), re-authenticate without downloading orders:

```bash
node Infrastructure/Browserless/Sites/amazon.ca/amazon-reauth.mjs
```

This opens the persistent Chrome profile to the Transactions page and waits silently until sign-in completes. Once authenticated, the session cookie is saved to `./Profile/` for future downloader runs.

### Container endpoint

The re-auth script can be invoked from the Bookkeeping container:

```bash
docker exec FRAD_is-bookkeeping node /app/amazon-reauth.mjs
```

The script accepts:
- `--timeout=<seconds>` — max wait time (default: 600)
- `DATA_DIR` env var — path to persistent profile

**Tip:** If the passkey QR flow fails ("devices couldn't connect"), click "Use password instead" below the passkey prompt to sign in with email + password instead.

## Lessons Learned — 2026-06-09

**Critical fix — sign-in detection:**
The initial sign-in check only examined the URL for "signin" text. After Amazon's redirect chain, the URL was sometimes empty (`''`), causing the script to skip the login-wait loop entirely. Fixed by also checking `pageBody` for sign-in text patterns.

**CRITICAL — passkey vs password:**
Amazon's passkey (WebAuthn) cross-device flow on Amazon.ca is unreliable from a Playwright-controlled browser — the QR code connection between desktop and phone frequently fails. **Recommend users click "Use password instead"** to sign in with email + password. The session persists across restarts regardless of which method is used.

**OUT_DIR path fix (2026-06-12):**
The default path `../../../intersite-docs/...` from `__dirname` (at `Infrastructure/Browserless/Sites/amazon.ca/`) resolves to `C:\Users\Victor\intersite-orchestrator\Infrastructure\intersite-docs` — 2 levels too deep. Fixed to `../../../../../intersite-docs` to reach `C:\Users\Victor\intersite-docs`. When running, always set `OUTPUT_DIR` env var explicitly to avoid ambiguity.

## Full Receipt Processing Protocol

After downloading Amazon receipts, the following steps must be completed in order:

### 1. Verify Receipts in Directory
- Confirm receipts are in `2026 Receipts/` (canonical location), not just a staging subdirectory.
- No duplicate filenames. One copy per receipt.
- Each file named semantically: `{YYYY-MM-DD} - {amount} - {Vendor} - {summary}.pdf`

### 2. Add to Manifest
- Run `update-manifest.ps1` to scan the receipts directory and add new entries to `manifest.csv`.
- Populate `date`, `amount`, `vendor` fields from the filename (the script leaves these empty for new entries).
- Run `Invoke-BookkeepingEnrichment.ps1` to generate `manifest-enriched.csv` with vendor normalization and account IDs.

### 3. Link to Bank Statements
- Update the `receipt_filename` column in each bank statement CSV (`YYYY-MM-DD - Account.csv`) for every matching transaction.
- Match by date + amount (within $0.01 tolerance).
- **Refunds/credits**: Do NOT link a receipt to a credit. In-and-out pairs (debit + credit same amount same period) are exempt — mark as no-receipt-needed.
- **Personal card receipts**: If a receipt PDF shows a personal card (e.g., *7069), move to `non-matching/` — do NOT link to the entity's bank statement.

### 4. Verify Bank-Links Complete
- For each bank CSV, count Amazon-matching rows that have `receipt_filename` populated.
- Expected count = download count minus refund pairs.
- Any row still missing a link that is NOT a refund/credit needs investigation.

### 5. Upload to Zoho (blocked without credentials)
- Use the Bookkeeping container's `/zoho/expenses` endpoint to create expenses with receipt attachments.
- Each expense must reference the correct Zoho bank account ID via `paid_through_account_id`.
- See `Tasks/Manual/` for the credential setup task.

---

## Supporting Scripts
| Script | Location | Purpose |
|--------|----------|---------|
| `Invoke-LinkReceiptsToBankCSVs.ps1` | `Skills/Bookkeeping/Scripts/` | Links receipt filenames to bank statement CSVs by date+amount match. Run after manifest update. |

## Lessons Learned — 2026-06-12

### What Worked
- **Per-order card_suffix field**: Adding a per-order `card_suffix` field to `amazon-orders-to-retrieve.json` allowed the same script to handle orders from multiple payment methods (Visa ****6679 for RBC, no suffix for chequing/Scotia). When `CARD_SUFFIX` is empty, the script matches by amount only — useful for chequing-account and POS transactions that don't show a card number on Amazon's Transactions page.
- **Amount-only matching for chequing POS**: Setting `card_suffix: ""` (or omitting it) on orders paid via chequing account worked — those transactions appeared on Amazon's Transactions page without a card suffix, and amount-only matching found them. No false positives because the order amounts were all distinct within the date range.

### What Didn't Work
- **No date boundary check**: The script paginated 72+ pages (years back in time) for a $32.91 Scotia transaction that was never going to be found. The fix: after each page scan, extract the date from the first (newest) transaction container; if it's older than the target order's date, stop paginating immediately. This prevents runaway pagination past the target date.
- **Scotia chequing transactions may not appear**: The $32.91 Scotia POS transaction on 5/19/2026 was not found on any page, possibly because:
  - The transaction was placed from a different Amazon account or through Amazon Business checkout
  - The amount formatting on Amazon's page differs from bank CSV (`$32.91` vs `-$32.91`)
  - The payment method (Scotia chequing) uses a different display format in the transaction container
  - Some transactions may require a date-filter change in Amazon's UI to appear

### Improvements for Next Run
- **Add date-boundary check** (applied 2026-06-12): After scanning each page and finding no match, extract the date of the first transaction container. If it's before the target order's date, stop paginating and report "past target" instead of continuing through 200 pages.
- **Default OUTPUT_DIR** changed to room-rentals path (`rbc-6679-ingest`). For intersite-consulting runs, set `OUTPUT_DIR` env var explicitly.
- **Card suffix handling**: The global `CARD_SUFFIX` env var now defaults to empty (match by amount only). Provide per-order `card_suffix` in the JSON for credit card matching, or leave empty for amount-only matching.

### Helpful Information
- **Card confirmation via PDF**: After downloading, check each PDF for the actual card used. The Amazon invoice header shows the cardholder name and card suffix (e.g., "Victor Salmon Amazon.ca Rewards Mastercard 7069" or "RBC Visa Card 6679"). If a receipt shows a personal card (*7069), it does NOT belong in the entity's receipts folder — move to `non-matching/` with a descriptive suffix.
- **Per-order card_suffix doesn't guarantee correctness**: An order with `card_suffix: "6679"` in the JSON may show on Amazon as Mastercard 7069 or Visa 4371 due to stored-card drift. The most reliable indicator is the PDF itself.
- **2026-06-12 Debug discovery**: The date headers are `div.apx-transaction-date-container` elements, NOT inside the transaction containers (`apx-transactions-line-item-component-container`). Any date-boundary check must query `document.querySelector('.apx-transaction-date-container')`, not walk the DOM from a container.
- **goBack() leaves SPA mid-pagination**: Amazon's SPA does NOT reset to page 1 after `page.goBack()`. Always follow with `page.goto('https://www.amazon.ca/cpe/yourpayments/transactions')` to ensure fresh page-1 state. Also re-navigate after a not-found order to avoid leaking pagination position to the next search.
- **Stored card vs actual payment**: Amazon's Transactions page shows the CURRENT card on file, not necessarily the card used at purchase time. An order charged to RBC Visa 6679 might show as Mastercard 7069 if the user changed their default card. Use amount-only matching (`card_suffix: ""`) when the card displayed on Amazon doesn't match the bank statement card.
- **Personal cards on the account**: If personal cards share the Amazon account, amount-only matching will find those transactions too. The user's description field in `amazon-orders-to-retrieve.json` should distinguish entity (rr- vs ic- prefix) so the checkpoint can track separately. Receipts for personal-card orders can be excluded post-download.
- **In-and-Out transactions**: Refunded orders (debit + credit in same statement period) may not appear on Amazon's Transactions page at all — they get removed or hidden. Mark as exempt and move on.
- Amazon's `cpe/yourpayments/transactions` page shows ALL orders from ALL payment methods on the account — not just credit card transactions. Chequing account purchases appear there too, but without a card suffix identifier.
- The amount format in bank CSVs for chequing transactions may be positive (debit) while Amazon's Transactions page shows negative (`-$10.06`). The script looks for `-$${amount}` pattern which handles this.
- Scotia Bank POS purchases (`Opos Amazon.Ca` in the statement) may or may not show up on Amazon's Transactions page — depends on how the payment was processed. Some may require looking up by order number in Amazon's order history directly.
- The 2026-06-12 session downloaded 4/23 room-rentals Amazon receipts before hitting the pagination dead end. Resume from checkpoint: `download-checkpoint.json` tracks completed orders as `order_id` values.
