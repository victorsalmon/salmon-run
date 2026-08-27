# Home Depot Canada Receipt Retrieval

## The Core Problem

**Browserless (headless Chrome) cannot automate Home Depot Canada.** Like Amazon, Home Depot blocks headless Chrome — the Pro dashboard (`/pro/purchase-history`) redirects headless sessions to sign-in. Cookie persistence helps but initial login requires a real browser.

**Working approach:** Run Playwright on the **Windows host** with a **persistent Chrome profile** (`headless: false`). The user logs in once via the two-step email→password modal; the script saves the session and navigates the purchase history page on subsequent runs.

---

## Scripts

| Script | Purpose |
|--------|---------|
| `homedepot-login.js` | Standalone login + cookie persistence (prototype) |
| `homedepot-receipt-downloader.js` | **CANONICAL** — full receipt downloader with persistent profile |
| `Invoke-HomeDepotLogin.ps1` | PowerShell driver (fetches creds from AWS SM) |

---

## How the Downloader Works

1. **Opens visible Chrome** via `chromium.launchPersistentContext(DATA_DIR)` — profile saved to `./Profile/`
2. **Navigates** to `https://www.homedepot.ca/pro/purchase-history`
3. **Auto-login** (or waits for manual): fills email → clicks Sign In → fills password → submits
4. **Applies date filter** "Last 24 Months" so purchase history shows all orders
5. **Scans visible orders** matching by order ID, amount, and optionally card suffix
6. **Clicks matching order**, saves page as PDF with semantic filename
7. **Goes back**, processes next order
8. **Checkpoint file** (`download-checkpoint.json`) enables resume if interrupted

### Login Flow on homedepot.ca

The Home Depot Pro login uses a two-step Angular modal:
1. Click "Sign In" (header button) — modal opens with email field
2. Enter email address → click "Sign In" or "Continue"
3. Password field appears in same modal
4. Enter password → click "Sign In"
5. May redirect to purchase history or MFA/verification

### Date Filter

The purchase history page at `/pro/purchase-history` often shows nothing until a date range is selected.
The filter element for "Last 24 Months" looks like:
```html
<li acl-list-item="" classname="acl-mt--medium"
    _nghost-fe_angular-c671618459=""
    class="acl-list-item acl-mt--medium acl-text-size--small ng-star-inserted">
  <a tabindex="0" class="ng-star-inserted">Last 24 Months</a>
</li>
```

---

## One-Time Setup

1. **Install dependencies:**
   ```bash
   cd Infrastructure/Browserless/Sites/homedepot.ca
   npm init -y
   npm install playwright
   ```

2. **Set credentials in AWS SM** (or env vars):
   - `INTERSITE_HOME_DEPOT_EMAIL` — Pro account email
   - `INTERSITE_HOME_DEPOT_PASSWORD` — Pro account password
   - These are added to the `Interclaw/FRAD/Provisioning` secret and the Bookkeeping bundle

3. **Run the downloader:**
   ```bash
   node homedepot-receipt-downloader.js
   ```

4. **First run:** Chrome opens headed. Sign in to Home Depot Pro in the visible window. The script auto-detects the logged-in state and proceeds.

---

## Credential Sources

The Bookkeeping container gets Home Depot credentials via the `bookkeeping_secrets_bundle` Docker Swarm secret:
- `homedepot_email` → env var `INTERSITE_HOME_DEPOT_EMAIL`
- `homedepot_password` → env var `INTERSITE_HOME_DEPOT_PASSWORD`

These are hydrated from AWS SM `Interclaw/FRAD/Provisioning` at deploy time by `Publish-FleetStack.ps1`.

---

## Order Manifest Format

```json
{"homedepot_orders": [
  {
    "order_id": "HD-123456",
    "date": "1/15/2026",
    "amount": 89.99,
    "description": "Order #HD123456 - Home Depot Canada",
    "card_suffix": "1234",
    "account": "INTERSITE-HD",
    "is_credit": false,
    "seller": "Home Depot Canada",
    "summary": "Sample Order"
  }
]}
```

| Field | Required | Description |
|-------|----------|-------------|
| `order_id` | Yes | Unique identifier (e.g., HD- prefix + order number) |
| `date` | Yes | Transaction date in M/D/YYYY format |
| `amount` | Yes | Dollar amount |
| `description` | Yes | Human-readable label |
| `card_suffix` | No | Last 4 digits of payment card (for amount+card matching) |
| `account` | No | Source account reference |
| `is_credit` | No | True if this is a refund/credit |
| `seller` | No | Vendor name for PDF filename |
| `summary` | No | Short description for PDF filename |

---

## Output Format

PDFs are saved to `OUTPUT_DIR` with semantic filenames:
```
YYYY-MM-DD - amount - Seller - Summary.pdf
2026-01-15 - 89.99 - Home Depot Canada - Sample Order.pdf
```

The default output directory is `intersite-docs/Taxes and Bookkeeping/intersite-consulting/2026 Receipts/homedepot-ingest/`.

---

## Debugging

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| 0 orders found | Date filter not applied | Run again, check if "Last 24 Months" appeared |
| Sign-in page after navigation | Session expired | Delete `./Profile/` and re-login |
| "Email input not found" | Sign-in modal structure changed | Check page text dump, update selectors |
| PDF blank or partial | Order detail page didn't load | Add more sleep after click |
| Amount not matching | Amount format differs from manifest | Check exact format in page text dump |

---

## Lessons Learned

### 2026-06-12 — Persistent profile, popups, and process management

**Never blindly kill Chrome processes.** The user may have their own Chrome session open (e.g., signed into Gmail). Killing all `chrome.exe` processes destroys the user's active browsing session. If you need to clear a Playwright persistent profile, delete the `Profile/` directory while Chrome is NOT running — don't kill processes programmatically.

**Popups must be dismissed before the `#` route works.** The Home Depot Pro page (`pro.html#`) relies on Angular hash routing. Two popups block it:
1. OneTrust cookie banner — accept via `#onetrust-accept-btn-handler`
2. "Select My Store" modal — dismiss via the X button (`.acl-modal__close`)
After both are dismissed, the page silently redirects to `pro.html` (no hash). Re-navigate to `pro.html#` to restore the sign-in modal trigger.

**Home Depot blocks automated logins with CAPTCHA.** Like Amazon, HD cannot be auto-logged-in via Playwright. Use `chromium.launchPersistentContext` with a persistent profile (`./Profile/`). The user logs in manually once; subsequent runs reuse the session.

**Selectors incompatible with `page.evaluate()`.** Playwright pseudo-selectors like `:has-text()` don't work inside `document.querySelectorAll()` in `page.evaluate()`. Use native text matching by iterating `querySelectorAll('button, a')` and checking `el.textContent`.

**Native dispatchEvent vs el.click().** `dispatchEvent(new MouseEvent('click'))` doesn't always trigger Angular event handlers. Prefer native `el.click()` when dispatching from within `page.evaluate()`. Use `dispatchEvent` only when a backdrop overlay intercepts Playwright's `.click()`.

## Related Files

| File | Purpose |
|------|---------|
| `homedepot-receipt-downloader.js` | **CANONICAL** — Playwright downloader |
| `homedepot-login.js` | Standalone login + cookie persistence (prototype) |
| `Invoke-HomeDepotLogin.ps1` | PowerShell credential driver |
| `homedepot-orders-to-retrieve.json` | Order manifest |
| `Infrastructure/Browserless/Sites/amazon.ca/amazon-persistent-downloader.js` | Amazon mirror (same pattern) |
| `Skills/DevOps/Playwright/playwright-aliexpress-downloader.js` | AliExpress mirror (group matching pattern) |
| `Skills/DevOps/Playwright/browserless-browserless-fundamentals.md` | General Browserless patterns |
| `Skills/Docker/Modules/SalmonRun.Secrets/Private/bundle-manifest.ps1` | Credential bundle manifest |
| `Skills/Docker/Modules/SalmonRun.Deploy/Public/Publish-FleetStack.ps1` | Deploy-time bundle hydration |

## Selector Recovery

If the Home Depot Pro page layout changes and the downloader stops working:

1. Run the downloader with a discovery script to dump DOM structure:
   ```bash
   node homedepot-login.js --discover 2>&1 | head -100
   ```
2. Compare key selectors (popup buttons, purchase history links) with the DOM output.
3. Update selectors in `homedepot-receipt-downloader.js` and test again.

The downloader now uses `lib/selector-utils.js` which emits `SELECTOR_NOT_FOUND` errors with element descriptions when key selectors fail, making rot diagnosis faster.
