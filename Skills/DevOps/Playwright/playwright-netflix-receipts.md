# Netflix Billing Receipt Retrieval — Discovered

## Status: Working — Selectors Discovered (2026-06-18)

DOM structure reverse-engineered from live inspection. Two Netflix accounts exist for room-rentals properties (see § Account Details below). The scripts use `launchPersistentContext` (Amazon pattern) — headed Chrome with persistent profile, no headless detection.

---

## The Core Problem

Netflix does not offer a "download all receipts" button. Each charge has an individual HTML invoice accessible from the Billing History page. Netflix blocks headless Chrome — the persistent profile approach is the only reliable method.

---

## Account Details

| Account | Property | Card | Billing Day | Charge | Tax Breakdown | Bank Account |
|---------|----------|------|-------------|-------|---------------|-------------|
| **Netflix MLM** | Mill Lake Manor (Abbotsford) | `*4371` | 7th of month | $8.95 | $7.99 + $0.96 ($0.56 GST + $0.40 PST) | TD-MLM-6467010 |
| **Netflix TMH** | Turtle Mountain Home (Vernon) | `*5303` | 8th of month | $8.95 | $7.99 + $0.96 ($0.56 GST + $0.40 PST) | Scotia-TMH-406000697486 |

Both accounts are on the **Standard with ads** plan at $7.99 + tax = $8.95/month. Invoices are the source of truth for exact billing dates — the bank statement date may differ by a few days.

---

## URLs (Discovered)

| Page | URL |
|------|-----|
| Account (membership) | `https://www.netflix.com/account/membership` |
| Billing history | `https://www.netflix.com/billingActivity` |
| Invoice | Opens in new tab via `div[data-uia="billDate"]` |

---

## Selectors (Discovered)

| Element | Selector |
|---------|----------|
| Billing link | `a[href="/billingActivity"]` ("View payment history") |
| Invoice row | `tr[data-uia*="billing-details-invoice-history"]` |
| Date | `td:first-child p` (YYYY-MM-DD format) |
| Description | second `td p` |
| View button | `div[data-uia="billDate"]` → opens invoice in **new tab** |
| Amount | `p[data-uia="invoice-total"]` |
| Card suffix | third `td` `div[data-uia="payment-details"]` |

Invoice matching is done by **date + amount** — Netflix does not expose an invoice/charge ID on the billing page.

---

## Output Format

Each charge produces two files:

| File | Purpose |
|------|---------|
| `{date} - {amount} - Netflix - {summary}.png` | Screenshot of the invoice page (visual reference, vision fallback) |
| `{date} - {amount} - Netflix - {summary}.html` | Raw HTML markup of the invoice page (sidecar — text readability) |

The HTML sidecar is the primary source for text extraction. If the HTML lacks sufficient information (e.g., dynamically rendered content), the screenshot serves as a fallback for vision-based extraction.

### Invoice Detail

- Simple HTML page (no PDF download link)
- Opens in a **new browser tab** when clicking "View"
- The script listens for the new tab (`browser.on('page')`), extracts the HTML, screenshots it, closes the tab, and resumes

---

## Order Manifests

| File | Account | Default? |
|------|---------|----------|
| `netflix-orders-mlm.json` | Netflix MLM | Yes (default) |
| `netflix-orders-tmh.json` | Netflix TMH | Use `--orders netflix-orders-tmh.json` |

Usage:
```powershell
# MLM (default)
$env:OUTPUT_DIR = "$env:USERPROFILE\intersite-docs\Taxes and Bookkeeping\room-rentals\2026 Receipts\netflix-mlm"
node netflix-receipt-downloader.js

# TMH
$env:OUTPUT_DIR = "$env:USERPROFILE\intersite-docs\Taxes and Bookkeeping\room-rentals\2026 Receipts\netflix-tmh"
node netflix-receipt-downloader.js --orders netflix-orders-tmh.json
```

---

## Related Files

| File | Purpose |
|------|---------|
| `netflix-login.js` | First-time login (persistent profile setup) |
| `netflix-reauth.js` | Session re-authenticator |
| `netflix-receipt-downloader.js` | **CANONICAL** — receipt downloader |
| `netflix-orders-mlm.json` | MLM orders manifest (7th of month, *4371) |
| `netflix-orders-tmh.json` | TMH orders manifest (15th of month, *5303) |
| `~/intersite-docs/Taxes and Bookkeeping/room-rentals/REFERENCE-room-rentals.md` | Room-rentals entity reference (Netflix listed under Internet/Software) |

---

## Sidecar Policy

When generating receipt sidecars for text readability, the following priority applies:

1. **HTML from Playwright** (`.html`) — preferred. Preserves original page structure, CSS, and markup. Richer than any extracted format. Used when Playwright captures an invoice page as part of the downloader.

2. **Vision-generated `.md` + `.csv`** — fallback when Playwright didn't capture HTML (e.g., existing PNGs without sidecars, or batch processing of previously downloaded receipts via vision pipeline).

3. **Raw markdown extraction** (`.md` only) — last resort when neither Playwright nor vision is available.

**Rationale**: HTML from Playwright preserves the full document structure including tables, styling, and layout. Converting back to text via vision is lossy and introduces hallucination risk (incorrect dates, amounts). Only use vision when the source HTML was not captured at download time.

## Selector Recovery

If the Netflix billing page layout changes and the downloader stops working:

1. Run the downloader in `--discover` mode to dump the current page DOM:
   ```bash
   node netflix-receipt-downloader.js --discover
   ```
2. The `--discover` flag opens the billing page and dumps all links, buttons, and text content to stdout.
3. Compare the output with the SELECTORS object in `netflix-receipt-downloader.js` (line 45).
4. Update the selector strings to match the new DOM structure, then test again.

## Changelog
- 2026-06-30: Added selector-rot detection utility (`lib/selector-utils.js`). Downloader now emits `SELECTOR_NOT_FOUND` errors with element description when key selectors fail. Added `--discover` DOM dump mode instructions.
- 2026-06-18: Discovered billing DOM selectors, new-tab invoice pattern, and two-account setup (MLM/TMH). Established sidecar policy (HTML > vision > raw).
