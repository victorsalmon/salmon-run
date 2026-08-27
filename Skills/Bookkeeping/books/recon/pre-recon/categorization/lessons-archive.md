---
name: bookkeeping/books/recon/pre-recon/categorization/lessons-archive
description: Archived Lessons Learned from income categorization skill development. This file preserves the full historical record; the active skill file (categorize-income.md) keeps only current workflow guidance.
---

# Lessons Learned — Income Categorization (Archived)

This file captures all Lessons Learned from income categorization sessions. New lessons should be added to this archive and kept out of the active skill files.

---

## 2026-06-17 (Scotia Vendor-Matching Pass + Utilities Account)

**What Worked:**
- Created `scotia-categorization-proposal.py` (one-off) to apply `categorization-rules.json` to the 83 uncategorized Scotia TMH Zoho export. Combined: vendor rules + E-Transfer DEPOSIT → rent register cross-ref (date+amount proximity) + E-Transfer WITHDRAWAL → Shareholder Loan + exempt-category flags + receipt matching from `room-rentals-unmatched-receipts.csv` AND from `2026 Receipts/` (broader match catches chequing-paid Amazon orders like FANMAIKEJI). Output: 76 high-confidence / 6 medium / 1 low — ready for batch UI application.
- Created **Utilities** expense account in Zoho via `POST /zoho/chartofaccounts?org_id=925004567` with `account_type: "expense"`. Returned `AccountId: 151803000000245013`. Then updated `cloud-books-entities.json` (room-rentals accounts + categories) and added a `B\.?C\.?\s*HYDRO` rule to `vendor_keyword_rules` (room-rentals entity) in `categorization-rules.json`.
- Used `aws sso login --profile intersite` then `aws secretsmanager get-secret-value` to fetch ZOHO creds for the Quick Categorize Playwright run.

**What Didn't Work / Failure Modes:**
- The `Invoke-ZohoQuickCategorizeRR.ps1` wrapper originally used `??` (null-coalescing) operator — only works in PowerShell 7+. Replaced with `if ([string]::IsNullOrEmpty($profile)) { $profile = 'intersite' }` for PS 5.1 compatibility. **If you see "The term '??' is not recognized", the user is on PS 5.1.**
- Scotia E-Transfer DEPOSITS in Zoho have no payee information — only `WITHDRAWAL FREE INTERAC E-TRANSFER` / `DEPOSIT FREE INTERAC E-TRANSFER`. Cross-reference to rent register (date+amount proximity) is the only way to classify them.
- Scotia E-Transfer WITHDRAWALS to tenants (e.g., Diamond/Shawntell $994 DD refund on 5/11) look identical to owner SHL withdrawals. User must disambiguate per-transaction. The proposal script handles known cases via `zoho_transaction_id` hardcoding.
- Amazon purchases paid via Scotia chequing (`Opos Amazon.Ca`) do NOT appear on Amazon's Transactions page — Playwright Amazon downloader (`amazon-persistent-downloader.js`) cannot find them. The receipt is on disk in `2026 Receipts/`, but it's NOT in `room-rentals-unmatched-receipts.csv` (the OCR-sidecar's vendor field shows "Intersite Consulting Inc." even when the actual seller is e.g. FANMAIKEJI). The proposal script now searches both files.
- Zoho PDF e-statements show Interac e-Transfer **reference numbers** (e.g., `61839492`) but **NOT recipient names**. To get recipients, check Scotia online banking or Interac confirmation emails — not the PDF.

**Key Patterns Discovered:**
- For Plaid-imported bank transactions, `POST /banktransactions/uncategorized/{id}/categorize/expenses` fails (code 108003). However, `POST /expenses` with `transaction_id` **does work** as an API-based categorize (creates CR+DR duplicate bank entries that must be swept). Browser Quick Categorize remains the cleaner path. See `bookkeeping/zoho/categorize § API: First-Time Categorization (Plaid)`.
- Zoho Quick Categorize UI groups by payee. So per-payee rules work for vendors (Mortgage, Strata, BC Hydro, Lightspeed, etc.) but WITHDRAWAL E-Transfers all group together — a single category applies to ALL of them. Manually fix outliers (e.g., DD refunds) after.
- After user-side UI work, the Playwright Quick Categorize ran successfully and found **0 uncategorized** on Scotia TMH — confirming all 83 were applied via UI.

**Improvements for next run:**
- The `Invoke-DryRunCategorization.py` is hardcoded for Intersite; generalize with `--entity intersite-consulting|room-rentals` to make it work for room-rentals uncategorized runs.
- For room-rentals, add E-Transfer DEPOSIT → Rent Revenue and E-Transfer WITHDRAWAL → Shareholder Loan to `income_rules` (currently they're only in the Intersite `vendor_keyword_rules`).
- A reusable "uncategorized Zoho export → rules + rent register + receipts" pass should live in `Skills/Bookkeeping/Scripts/` as `Invoke-UncategorizedCategorization.py` (not in `Tasks/Working/`).

---

## 2026-06-13 (TAS, DD Ledger, ADRs, Full Income Reconciliation)

**New files created:**
- `Build-TAS.ps1` — TAS generator (cross-references bank CSVs, rent register, DD ledger, Zoho exports)
- `TAS-2026.csv` — Transaction Annual Statement with source manifest, checksums, sorted by account then date
- `damage-deposit-ledger-2026.csv` — independent DD tracking (separate from rent register per ADR-003)
- `ADR/0001`–`0004` — bookkeeping-level decisions (data hierarchy, rent policy, DD tracking, cycle convention)

**Rules confirmed:**
- Rent due last day of previous month; after 15th = next month occupancy
- $25 late fee 2nd–10th, waivable at owner's discretion
- DD ledger tracks deposit→application→refund lifecycle independently
- Journal entries for DD→rent transfers recorded at due date in register
- TAS is derived artifact (never manually edited); raw bank CSVs are ground truth

**Tenant history corrected for 2026:**
- Diamond: James (DD→Feb rent) → Shawntell (Mar $1,049, Apr $1,024, May $1,024) → Jayden (May $490.64 prorated, Jun $1,014)
- Garnet: Zachary ($1,080/mo, DD $1,050 resolved: $525 rent + $50 strata + $475 refund) → Joshua ($975/mo)

---

## 2026-06-12 (Room Config + Rental Income + Rent Register)

**What Worked:**
- Cross-referencing Scotia PDF statements against CSV exports to identify e-transfer senders
- Using amount + timing patterns to match split payments (partial end-of-month + remainder by 5th)
- Tracing owner funding by matching same-date credit/debit pairs across Scotia→TD accounts
- Single-source approach: `rent-register.csv` → `Get-RentIncomeLedger.ps1` replaced 4 separate scripts
- The after-15th rule consistently assigns Jan payments to Feb, Feb to Mar, matching tenant behavior
- Work deductions (Amethyst), prorated half-months (Diamond/Garnet), and agreed partials (Chrysocolla) count as full payment via register notes
- Split payments ($1,100 + $231 = $1,331) tracked as separate rows for the same month

**What Went Wrong / Didn't Work:**
- Agent didn't know about `Infrastructure/rent-tracking/rooms.json` — no cross-reference existed in the income skill (formerly `../intersite-docs/Upscale Havens/Leases/rooms-config.json`)
- TD Canada Trust e-transfer descriptions truncated to 15 chars — payer name not recoverable
- Assuming a Jan payment is for Jan — rent is frequently 1-3 months late. Payment timing ≠ period.
- Multiple scripts with overlapping concerns (Add-RentToManifest, Show-RentIncome, Show-RentTransactions) created confusion

**Fix Applied:**
- Prerequisite step added: "Read the Occupant Config" before classifying rent
- `categorize` + `gather-sources.md` + `org-room-rentals.md` now cross-reference `Infrastructure/rent-tracking/rooms.json` (was `../intersite-docs/Upscale Havens/Leases/rooms-config.json`)
- All scripts consolidated into single `Get-RentIncomeLedger.ps1` with `-View`/`-Export`/`-Room` flags
- Rent entries removed from manifest (expense-only); register is the sole income source

**Key Patterns Discovered:**
- Split months: Partial at month-end, remainder by 5th of next month
- Late payments: 1-3 months behind is normal — don't assign to current period
- Work deductions: Amethyst deducts ~$125-150/mo from $1,331 for property work
- Late fees: Garnet paid $25 late fee on $1,080 ($1,105 total)
- Alternative amounts: Same room can receive $994, $1,018, or $1,024 depending on occupant
- Owner funding: Scotia→TD $2K transfers, small Bonnie $160 credits

**Improvements for next run:**
- When a tenant's pattern doesn't match after-15th rule, add override to `rent-register.csv` with a note
- Run `Get-RentIncomeLedger.ps1 -Export` after each register edit to keep markdown current
- Manifest tracks expenses only — rent income is not duplicated there

---

## 2026-06-06 (Zoho Reconciliation)

**What Worked:**
- Cross-referencing bank CSV credits against Zoho banktransactions by date + amount to find misclassified deposits
- Using `debit_or_credit` field in banktransactions API to distinguish money-in vs money-out
- Checking GL account-level totals before diving into individual transactions
- Scanning all GL accounts for expense accounts with credit balances (hidden income)

**What Didn't Work:**
- `PUT /banktransactions/{id}` without `from_account_id` and `to_account_id` — offset account silently dropped

**Improvements for Next Run:**
- Read current state via `GET /banktransactions/{id}` before editing
- Always use ZohoAuth singleton to avoid burning OAuth refresh quota
- Batch reclassification into a single script with one session

**What Worked:**
- Single-source approach: `rent-register.csv` (register) → `Get-RentIncomeLedger.ps1` (script with -View/-Export flags) replaces 4 separate scripts
- The after-15th rule consistently assigns Jan payments to Feb, Feb to Mar, etc., matching real-world tenant behavior
- Register entries for "paid Dec 2025" cover January for all rooms without needing specific 2026 transactions
- Work deductions (Amethyst), prorated half-months (Diamond May, Garnet May), and agreed partials (Chrysocolla Feb $495) all count as full payment via register notes
- Split payments ($1,100 + $231 = $1,331 for Amethyst) are tracked as separate rows for the same month

**Improvements for next run:**
- When a tenant's payment pattern doesn't match the after-15th rule, add the override to `rent-register.csv` with a descriptive note
- Run `Get-RentIncomeLedger.ps1 -Export -View Summary` after each register edit to keep the markdown ledger current
- The manifest tracks expenses only — rent income is not duplicated there
