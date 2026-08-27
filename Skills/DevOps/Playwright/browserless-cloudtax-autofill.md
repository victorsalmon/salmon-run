# CloudTax Browser Automation — Website Interaction

> **Single source of truth** for all CloudTax website interaction: URLs, HTML selectors, click sequences, navigation flows, Playwright scripts, and field-finding strategies.
>
> This skill is owned by the **Browserless** container domain. The **Bookkeeper** domain (`Skills/Bookkeeping/tax-filing/cloudtax/`) owns the data preparation (which forms, what data, how to map).

## Prerequisites

1. **Node.js** v18+ with Playwright: `npm install playwright` in this directory
2. **Environment**: `$env:CLOUDTAX_INTERSITE_T2_URL` (from AWS SM Bookkeeping bundle)
3. **Session**: First run requires manual login + MFA; subsequent runs reuse `.cloudtax-session.json`

---

## Portal URLs

| Page | URL |
|------|-----|
| Business Profile | `https://app.cloudtax.ca/{year}_1/profile/business-info` |
| Forms List | `https://app.cloudtax.ca/{year}_1/forms` |
| Form Detail | `https://app.cloudtax.ca/{year}_1/forms/{formId}` |

Where `{year}` is the tax year (e.g., `2026`) and `{formId}` is the lowercase form ID (e.g., `s1`, `s8`, `s50`).

---

## Env Vars

| Variable | Source | Description |
|----------|--------|-------------|
| `CLOUDTAX_INTERSITE_T2_URL` | AWS SM Bookkeeping bundle | Full T2 profile URL |
| `CLOUDTAX_EMAIL` | — | Login email (optional) |
| `CLOUDTAX_PASS` | — | Login password (optional) |
| `CLOUDTAX_COOKIE_FILE` | — | Custom cookie path (default: `.cloudtax-session.json`) |

---

## HTML / DOM Reference

### Forms Page (`/forms`)

**Form list** — displays already-added schedules:
```html
<div class="ct-slip-list">
  <div class="ct-slip" tabindex="0">
    <div class="ct-slip__bar"></div>
    <div class="ct-slip__content">
      <div class="ct-slip__title">
        <span>S1</span> - Net Income (Loss) for Income Tax Purposes
      </div>
    </div>
    <i tabindex="0" role="button" class="icon-trash"></i>
    <i class="icon2-angle-right"></i>
  </div>
</div>
```

**Delete form**: Click `.icon-trash` → confirm dialog with:
```html
<button cdkfocusinitial="" class="ct-btn--danger"> Yes, Delete It </button>
```

### Add Forms Modal

Triggered by clicking:
```html
<button id="ct-tour-search" class="ct-btn--outline ct-search">
  <i class="icon-add"></i> Add forms
</button>
```

Modal structure:
```html
<div class="ct-search-result ps ps--active-y">
  <div class="popular-wrapper">...</div>
  <!-- Sections: Dashboard, Business Info, Import, My Forms, Review, File -->
  <div class="ct-search-result__item">
    <div class="ct-search-result__section">
      <div class="ct-search-result__section--title">
        <i class="icon2-slip"></i> My Forms
      </div>
      <div class="ct-search-result__section--content">
        <div tabindex="0" role="button" class="ct-search-result__item--item">
          <span class="result-wrapper">
            <span style="margin-left: 24px;">S1 - Net Income (Loss) for Income Tax Purposes</span>
          </span>
        </div>
      </div>
    </div>
  </div>
</div>
```

**Available forms in "My Forms":**

| Form ID | Modal Item Text |
|---------|-----------------|
| S1 | S1 - Net Income (Loss) for Income Tax Purposes |
| S8 | S8 - Capital Cost Allowance (CCA) |
| S50 | S50 - Shareholder Information |
| S11 | S11 - Transactions with Shareholders, Officers, or Employees |
| S3 | S3 - Dividends Received, Taxable Dividends Paid, and Part IV Tax Calculation |
| S5 | S5 - Tax Calculation Supplementary - Corporations |
| S7 | S7 - Aggregate Investment Income |
| S100 | S100 - Balance Sheet Information |
| S125 | S125 - Income Statement |
| S141 | S141 - General Index of Financial Information (GIFI) |
| S4 | S4 - Corporation Loss Continuity and Application |
| S6 | S6 - Summary of Dispositions of Capital Property |
| S9 | S9 - Related and Associated Corporations |
| S19 | S19 - Non-resident Shareholder Information |
| S24 | S24 - First-time Filer After Incorporation/Acquisition of Control |
| S88 | S88 - Internet Web Page or Website Income |

### Form Detail Page (`/forms/{formId}`)

Each form page has 4 sibling child divs:
1. **Page Header** — form title/instructions (no data entry)
2. **Additions** — income/revenue lines (typically lines 103–254)
3. **Deductions** — expense/deduction lines (typically lines 300–418)
4. **Footer** — navigation buttons

**Save / Next button:**
```html
<button type="button" class="ct-btn">Next</button>
```
Clicking Next saves progress and redirects back to `/forms`.

---

## Click Sequences

### Login (headed, MFA-capable)

```
1. Open headed Chrome
2. Navigate to CLOUDTAX_INTERSITE_T2_URL
3. If credentials provided: fill email input → password → submit
4. If MFA page detected (URL contains /mfa, /verify, /2fa, /auth):
     → Wait for user to complete in browser
     → User presses Enter in terminal
5. Save cookies to .cloudtax-session.json
6. Keep browser open for verification
```

### Add Forms

```
1. Navigate to /forms
2. Read existing forms from .ct-slip-list > .ct-slip__title
3. For each form to add:
   a. If already in existing list → skip
   b. Click #ct-tour-search (+ Add forms)
   c. Wait for modal (.ct-search-result)
   d. Find span with matching form text under .ct-search-result__item--item
   e. Click the parent [tabindex] element
   f. Wait 2s for modal to update/close
4. Report added vs skipped forms
```

### Fill Form

```
1. Navigate to /forms/{formId}
2. Wait for page to load (3s)
3. For each line in data:
   a. Find input via label text (see Field Finding below)
   b. Click the input
   c. Fill with the formatted amount
4. Click button.ct-btn:has-text("Next")
5. Wait 2.5s for save + redirect
```

### Delete Form

```
1. Find the form's .ct-slip in the list
2. Click its .icon-trash element
3. In confirmation dialog, click button:has-text("Yes, Delete It")
```

---

## Field Finding Strategy

Inputs are located in priority order:

1. **Label `for` attribute**: `<label for="inputId">Line 8299</label>` → `#inputId`
2. **Label wrapping input**: `<label>Line 8299 <input name="..."></label>`
3. **Name attribute matching**: `input[name*="8299"]` — line numbers as substrings
4. **Sibling text**: `div:has(input:visible)` whose text content contains the line number
5. **Generic**: Any `input:visible` near text matching the label

---

## Form → Form ID Mapping

| CloudTax Form ID | Script Key |
|-----------------|------------|
| s1 | s1 |
| s8 | s8 |
| s50 | s50 |
| s11 | s11 |
| s3 | s3 |
| s5 | s5 |
| s7 | s7 |
| s100 | s100 |
| s125 | s125 |
| s141 | s141 |

---

## Scripts

| Script | Purpose |
|--------|---------|
| `cloudtax-login.js` | Authenticate, persist cookies, handle MFA |
| `cloudtax-add-form.js` | Add forms via modal. CLI: `--form "S1 - Net Income"` or `--all` |
| `cloudtax-fill-form.js` | Fill a single form from `{ form, lines }` JSON. CLI: `--form s1 --data path/to/data.json` |
| `cloudtax-autofill.js` | Full pipeline: parse .md → add forms → fill all. Entry point for end-to-end runs. |
| `cloudtax-field-map.js` | CRA line number → form field selectors, organized by form ID |
| `cloudtax-schedule-parser.js` | Parses .md worksheet into structured schedule data |

## Cookie Persistence

`.cloudtax-session.json` stores browser cookies. All scripts auto-load this file. Delete it to force a fresh login.

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|-------------|------|
| Session expired | Cookie file stale | Delete `.cloudtax-session.json` and re-login |
| MFA page hangs | MFA not completed | Complete in browser, press Enter |
| "+ Add forms" not found | Already on wrong page | Check page URL is `/forms` |
| Form search fails | Modal not loaded | Increase sleep after clicking #ct-tour-search |
| "Next" not visible | Form has validation error | Check field values, run with `--debug` |
| Input not found | Selector mismatch | Update `cloudtax-field-map.js` with correct selectors |

---

## Lessons Learned — 2026-06-10

**What Worked**:
- Capturing the full CloudTax Angular DOM structure (`.ct-slip`, `.ct-slip__title`,
  `#ct-tour-search`, `.ct-search-result__item--item`, `button.ct-btn` with text
  `"Next"`) in a single skill file so all agents can reference the same selectors.
- Cookie persistence via `.cloudtax-session.json` — avoids re-login and MFA on
  subsequent runs, critical since Zoho Books has a ~20 logins/day limit and
  CloudTax likely has similar constraints.
- Delegating form ID → name mappings to this skill (Browserless domain) while
  keeping form-selection logic in the Bookkeeping Domain. Clear boundary prevents
  duplicated selector knowledge.

**What Didn't Work**:
- Attempting to write `.ps1` wrapper scripts in the cloudtax.ca directory was
  blocked by Windows Defender/antivirus for certain filename patterns
  (`Invoke-CloudTaxAutofill.ps1`). Script content with backtick-quoting in
  Invoke-Expression patterns also triggered removal. Resolution: document
  `node` commands directly instead of wrapping in PowerShell.
- The initial autofill design assumed a wizard-style section navigation
  (income-statement → cca → sbd pages). CloudTax is form-list based: each
  schedule is a separate form accessible via `/forms/{formId}`. The script had
  to be restructured around form-level navigation instead of section-level.

**Improvements for next run**:
- When adding a new form-type field to CloudTax, first inspect the actual DOM
  for the input's `name`, `data-line`, or surrounding label structure, then add
  the selector to `cloudtax-field-map.js`. Don't guess selectors.
- The Angular app uses `_ngcontent-ng-*` attributes that change between builds.
  Never use these in selectors — use stable class names (`.ct-btn`, `.ct-slip`,
  `.ct-search-result__item--item`) instead.
- All Playwright scripts should use `headed: true` by default for CloudTax
  since MFA is likely required. Headless mode is only safe after session
  cookies are established.

**Helpful Information**:
- CloudTax URL format: `https://app.cloudtax.ca/{year}_1/forms/{formId}` where
  `{year}` is the tax year (e.g., `2026`) and `{formId}` is lowercase (e.g.,
  `s1` for Schedule 1). Do NOT use uppercase in URL paths.
- The T2 profile URL is stored in AWS SM as `CLOUDTAX_INTERSITE_T2_URL` under
  `Interclaw/FRAD/Provisioning`. It's hydrated into the Bookkeeping container
  bundle at deploy time by `Publish-FleetStack.ps1`.
- CloudTax schedule numbering differs from CRA numbering. E.g., CRA Schedule 3
  (Shareholder Information) is CloudTax form S50. CRA SBD is handled through
  CloudTax form S5, not a dedicated S4 or SBD form.
