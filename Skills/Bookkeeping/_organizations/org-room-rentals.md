# Victor Salmon — Room Rentals

> **DEPRECATED** — Org data moved to `~/intersite-docs/Taxes and Bookkeeping/room-rentals/REFERENCE-room-rentals.md`. This file is kept for script compatibility. Update scripts to reference the intersite-docs path.
>
> **Generic rules:** See `generic-rules.md` for shared categorization rules and `categorization-rules.json` for the machine-readable keyword→account mappings. This file contains entity-specific overrides only.

## Chart of Accounts

### Liability Accounts

| Account | ID | Notes |
|---------|-----|-------|
| Damage Deposits Held | `151803000000197002` | Refundable tenant deposits. Incoming deposits credit this account; outgoing returns debit it. Created 2026-06-13. |

### Income Accounts

| Account | ID | Notes |
|---------|-----|-------|
| Rent Revenue | `151803000000000430` | All tenant rent payments, work-deducted amounts. Damage deposits now go to Damage Deposits Held (liability). Note: uses same ID as legacy "Rent Expense" label — Zoho org uses this for income. |

### Expense Accounts

| Account | ID |
|---------|-----|
| Mortgage and HELOC Payments | `(user-created in Zoho)` |
| Automobile Expense | `151803000000000424` |
| IT and Internet Expenses | `151803000000000427` |
| Rent Expense (see Income) | `151803000000000430` | This ID is used as Rent Revenue (income) — see Income Accounts above |
| Office Supplies | `151803000000000400` |
| Advertising And Marketing | `151803000000000403` |
| Repairs and Maintenance | `151803000000000457` |
| Other Expenses | `151803000000000460` |
| Janitorial Expense | `151803000000000433` |
| Postage | `151803000000000436` |
| Telephone Expense | `151803000000000421` |
| Travel Expense | `151803000000000418` |
| Meals and Entertainment | `151803000000000448` |
| Credit Card Charges | `151803000000000412` |
| Bank Fees and Charges | `151803000000000409` |
| Consultant Expense | `151803000000000454` |

## Expected amounts
- $183.75/month for property management fees
- $257.25/month for FRA services (Jan 2026 onward)
- $55.95/month for Lightspeed internet
- $16.80/month for Lightspeed router rental
- $105.00 for ensuite light fixture & wall repair (one-time)

## Caveats
- Room rental expenses are personal/rental-property expenses, not corporate
- Internet and utilities for rental units are deductible against rental income
- Property taxes are paid separately per property (Vernon ~$1,301.99, Abbotsford ~$578.20)
- Strata fees at Windsor Greene building are the tenant's responsibility
- Home Depot purchases for repairs are rental property expenses
- Kal Tire and vehicle expenses are personal unless vehicle is used for rental property management
- The two property tax notices ($1,301.99 Vernon and $578.20 Abbotsford) are informational — actual payment dates differ
- Lightspeed internet is two line items: $55.95 service + $16.80 router = $72.75/month total

## Tax rules
- Rental income: report on T776
- Rental expenses: deductible against rental income (repairs, internet, property taxes, insurance)
- PST/GST on repair materials (Home Depot) — input tax credits available if GST-registered
- No PST/GST on rent collected or strata fees

## Income identification
See `bookkeeping/books/reconciliation/pre-recon/categorization/categorize-income` § Rental Income Classification for the full rental situations catalog covering split payments, late months, work deductions, damage deposits, late fees, and owner funding.

### Rent Income Ledger

Single-source of truth: `rent-register.csv` → `Get-RentIncomeLedger.ps1`.

| What | Where | Purpose |
|------|-------|---------|
| Register | `room-rentals/rent-register.csv` | Authoritative payment-to-month mapping (edit this) |
| Ledger script | `Skills/Bookkeeping/Scripts/Get-RentIncomeLedger.ps1` | One script, multiple views |

**Usage:**
- `Get-RentIncomeLedger.ps1` — console per-room/month status matrix
- `Get-RentIncomeLedger.ps1 -Export` — generates `2026-rent-income-ledger.md` (summary table)
- `Get-RentIncomeLedger.ps1 -Export -View Account` — by-account transaction list
- `Get-RentIncomeLedger.ps1 -Export -View Monthly` — monthly recap
- `Get-RentIncomeLedger.ps1 -Export -Room tmh-emerald` — single room history

## Flags
- Any amount > $500 requires review
- Vehicle expenses (Kal Tire, fuel) — verify business vs personal use percentage
- Any Home Depot purchase > $200 requires receipt photo verification
- Property tax amounts should match expected values within $10
