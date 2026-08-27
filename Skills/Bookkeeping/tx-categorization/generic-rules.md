# Generic Transaction Categorization Rules

Shared categorization rules that apply across all entities.
Entity-specific overrides live in entity files (e.g., `intersite-consulting.md`, `room-rentals.md`).

## Machine-Readable Rules

**File:** `categorization-rules.json`

All keyword→account matching rules are defined in this JSON file. Three rule sets:

| Section | Purpose | Example |
|---------|---------|---------|
| `vendor_keyword_rules` | Match by payee/vendor name from bank CSV | `"PETRO" → [8962] Motor vehicles repairs and maintenance` |
| `amazon_keyword_rules` | Match by product name from receipt notes/filename | `"mouse\|keyboard" → [9150] Tech repair, support, subscriptions, peripherals` |
| `description_overrides` | Exact-match overrides for known ambiguous payees | `"WAVE SV9T" → Other Expenses` |

## Rule Application Order

1. **Description overrides** checked first (exact substring match, case-insensitive)
2. **Amazon/AliExpress** items → receipt manifest lookup (match by exact amount + vendor), fall through to generic keyword rules
3. **Generic vendor keyword rules** — regex pattern match against payee name
4. **Catch-all** — unmatched → "Other Expenses"

## Shared Account Categories

> **Entity-specific account IDs:** See `categorization-rules.json` — each rule has an `entities[]` array and an `account_id` field with the correct ID for that entity. For the full Chart of Accounts, see `~/intersite-docs/Taxes and Bookkeeping/intersite-consulting/REFERENCE-intersite-consulting.md` and `~/intersite-docs/Taxes and Bookkeeping/room-rentals/REFERENCE-room-rentals.md`.

| Category | Notes |
|----------|-------|
| [8962] Motor vehicles repairs and maintenance | Fuel, repairs, insurance, parking |
| [9150] Tech repair, support, subscriptions, peripherals | Software, SaaS, hardware, IT services, hosting (merged from Software & IT) |
| Office & General Expenses | Supplies, furniture, equipment |
| Repairs and Maintenance | Property repairs, maintenance, tools |
| Professional Fees | Legal, accounting, consulting, government fees |
| Advertising And Marketing | Ads, promotions, listings |
| Bank Fees and Charges | Monthly fees, transaction fees, CC interest |
| Credit Card Charges | CC-specific fees and charges |
| Insurance | Property, liability, auto insurance |
| Other Expenses | Catch-all for non-standard items |
| Shareholder Loan | Owner capital injections/withdrawals |
| Dividends Paid | Owner distributions |
| Consulting Revenue | Consulting service income |

## SKIP Prefixes

Transactions starting with `SKIP-` are not expenses:

| Prefix | Meaning |
|--------|---------|
| `SKIP-Income` | Income/refund (not an expense) |
| `SKIP-Internal Transfer` | Transfers between accounts |
| `REVIEW-amazon` | Amazon order — needs receipt to determine category |
| `REVIEW-aliexpress` | AliExpress order — needs receipt to determine category |
| `REVIEW-REFUND` | Refund — needs matching to original purchase |

## Editing Rules

**Do not edit the Python script for rule changes.** Edit `categorization-rules.json` instead — the Python script reads it automatically.
