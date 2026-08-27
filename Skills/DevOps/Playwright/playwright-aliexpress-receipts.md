# AliExpress Receipt Retrieval — Selectors Discovered

## Status: Working — Selectors Discovered (2026-06-18)

DOM structure reverse-engineered from live inspection. AliExpress aggregates charges: a single bank statement charge (e.g. $10.77 on Mar 10) may be the sum of multiple orders from that day ($1.89 + $3.99 + $4.89). The individual order total on the AliExpress page often does NOT match the bank charge — the charge is a **batched settlement** of multiple orders.

---

## The Core Problem

Amazon gives you individual order detail pages where the amount matches the bank statement. **AliExpress does not.** It batches orders and settles them as a single charge to your card. The downloader must:

1. Scrape ALL orders from the AliExpress orders page
2. Parse each order's date + individual amount
3. For each bank-statement charge, find a date window (+/- 3 days) and identify which combination of individual orders sums to the charge total
4. Inject CSS highlight on matched order cards
5. Single full-page screenshot showing all matched orders highlighted together
6. Single JSON sidecar combining charge + matched orders with amounts

---

## Selectors (Discovered 2026-06-18)

| Element | Selector | Notes |
|---------|----------|-------|
| Order list URL | `https://www.aliexpress.com/p/order/index.html` | Main order list page |
| Order item | `a.order-item.order-item-mobile` | Each order card is a link |
| Order ID | `href` param `orderId=(\d+)` | Extracted from the link URL |
| Date | `span.order-item-header-date` | Text format: "Jun 13, 2026" |
| Store name | `span.order-item-store-name a span:first-child` | Store/brand name |
| Product name | `div.order-item-content-info-name span[title]` | Full product title in `title` attribute |
| SKU/Variant | `div.order-item-content-info-sku` | Product variant/size/color |
| Quantity | `span.order-item-content-info-number-quantity` | e.g. "x1" |
| Total price | `span.order-item-content-opt-price-total` | Contains `es--wrap--1Hlfkoj` with digit spans |
| Status | `span.order-item-header-status-text` | "Awaiting delivery", "Completed", etc. |
| Load more | `button.comet-btn-borderless` | Click to load next batch of orders |

### Price Format

Prices use digit-split rendering — `parsePrice()` extracts numbers from any format (`$1.89`, `C$30.66`, `CDN$10.77`).

---

## Aggregation Strategy

### Subset-Sum Matching

```
For each charge in manifest:
  1. Window = charge_date +/- 3 days
  2. Collect scraped orders in that window
  3. Subset-sum (brute force) to find combination = charge amount
  4. If matched: highlight orders with CSS, screenshot, save combined sidecar
  5. If unmatched: report for manual investigation
```

Tolerance: ±$0.02. Brute force over 2^N (N < 20 per window).

### Example

```
Bank: $10.77 on March 10  →  $1.89 (ring) + $3.99 (case) + $4.89 (cable) = $10.77 ✓
```

---

## Output Format

Each matched charge produces two files sharing the same base name:

```
{date} - {charge_amount} - AliExpress - {summary}.png   ← matched orders highlighted in red
{date} - {charge_amount} - AliExpress - {summary}.json   ← charge + matched orders + order URLs
```

The `.json` sidecar includes `orderUrl` for each matched order so you can open them manually if needed.

### Naming Example

```
2026-03-10 - 10.77 - AliExpress - MLM office supplies (ring+case+cable).png
2026-03-10 - 10.77 - AliExpress - MLM office supplies (ring+case+cable).json
```

All files sort together by date then amount.

---

## CSS Highlighting

Matched order cards on the AliExpress page get a **red outline + yellow background** via injected CSS before screenshot. The highlight is removed after each capture so the page stays clean for the next charge.

---

## Quick Test

The manifest already includes a March 10, 2026 MLM $10.77 charge. To test:

1. `node aliexpress-login.js` (first time only — sets up persistent profile)
2. `node aliexpress-persistent-downloader.js`

The script will load all orders, scrape them, find the $10.77 match, highlight the matched orders, and save the screenshot + JSON sidecar to `OUTPUT_DIR`.

---

## Usage Reference

| Command | Purpose |
|---------|---------|
| `node aliexpress-login.js` | First-time profile setup (headed Chrome, sign in once) |
| `node aliexpress-reauth.js` | Re-authenticate when session expires |
| `node aliexpress-persistent-downloader.js` | Load orders, match charges, screenshot |
| `node aliexpress-persistent-downloader.js --discover` | Dump page DOM for selector debugging |
| `node aliexpress-persistent-downloader.js --scrape-only` | Dump all orders as JSON, no screenshots |

---

## Known Limitations

- **Subset-sum non-unique**: First match wins if multiple combinations sum to same amount
- **Load-more cap**: Stops after 50 clicks or when no new orders appear
- **Date format**: Expects "Mon DD, YYYY" — non-English locale may need selector update

---

## Related Files

| File | Purpose |
|------|---------|
| `aliexpress-persistent-downloader.js` | **CANONICAL** — group-matching receipt downloader |
| `aliexpress-login.js` | First-time persistent profile login |
| `aliexpress-reauth.js` | Session re-authenticator |
| `aliexpress-orders-to-retrieve.json` | Charges manifest (bank statement cross-reference) |
| `Profile/` | Persistent Chrome profile directory |
