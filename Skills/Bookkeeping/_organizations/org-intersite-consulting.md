# Intersite Consulting Inc.

> **DEPRECATED** — Org data moved to `~/intersite-docs/Taxes and Bookkeeping/intersite-consulting/REFERENCE-intersite-consulting.md`. This file is kept for script compatibility. Update scripts to reference the intersite-docs path.
>
> **Generic rules:** See `generic-rules.md` for shared categorization rules and `categorization-rules.json` for the machine-readable keyword→account mappings. This file contains entity-specific overrides only.

## Chart of Accounts

| Account | ID |
|---------|----|
| [8962] Motor vehicles repairs and maintenance | `93310000000000424` |
| Software & IT Expenses | `93310000000000427` |
| Office & General Expenses | `93310000000000400` |
| Repairs and Maintenance | `93310000000000457` |
| Professional Fees | `93310000000135091` |
| Advertising And Marketing | `93310000000000403` |
| Other Expenses | `93310000000000460` |
| Lease Expense | `93310000000217488` |
| Insurance | `93310000000151096` |
| Credit Card Charges | `93310000000000412` |
| Bank Fees and Charges | `93310000000000409` |
| Consulting Revenue | `93310000000149102` |
| Shareholder Loan | `93310000000146154` |
| Dividends Paid | `93310000000146151` |
| Share Capital | `93310000000125064` |
| [2680] Taxes Payable GST | `93310000000129094` |
| Corporate Income Tax Payable | `93310000000138058` |

## Vendor corrections
- "Intersite Consulting Inc." → "Intersite Consulting Inc." [corporate, category:management fees]
- "Intersite Consulting" → "Intersite Consulting Inc." [corporate, category:management fees]
- "Amazon.ca ULC" → "Amazon.ca" [corporate, category:office supplies]
- "Amazon.com.ca LLC" → "Amazon.ca" [corporate, category:office supplies]
- "Amazon.com.ca ULC" → "Amazon.ca" [corporate, category:office supplies]
- "Amazon" → "Amazon.ca" [corporate, category:office supplies]
- "amazon.ca" → "Amazon.ca" [corporate, category:office supplies]
- "Meta" → "Meta Platforms Inc." [corporate, category:advertising]
- "Meta Platforms, Inc." → "Meta Platforms Inc." [corporate, category:advertising]
- "Windsor Greene" → "Windsor Greene Strata" [corporate, category:rent]
- "RBC Business Cash Back Mastercard" → "MC 6258" [bank account]
- "Auromaitreyi Salmon" → "Auromaitreyi Salmon" [corporate, category:lease — property co-owner sibling]
- "[Brother]" → "Brother's Name" [corporate, category:lease — property co-owner; arrears owing when his taxes are filed]

## Expected amounts
- $183.75/month for property management fees (FRA services)
- $257.25/month for additional FRA services (as of Jan 2026)
- $105.00 for ensuite light fixture & wall repair (one-time, Jan 12 2026)
- $55.95/month for Lightspeed internet service
- $16.80/month for Lightspeed router rental
- $59.08 for marketplace listing ads (Meta, Feb 2026)
- $172.20 for marketplace listing ads (Meta, Feb 2026)
- $0.00 for strata fees disclosure (Windsor Greene — informational only)

## Caveats
- All room rental expenses are corporate/business expenses
- PST does not apply to rent or management fees, only to goods
- GST/HST applies to management fees but not to rent itself
- Lightspeed internet includes router rental separate from service
- Amazon purchases are corporate office supplies unless explicitly marked personal
- Page 2 of Amazon invoices (shipping summary) always shows $0.00 or duplicate totals — use page 1 for the real total
- Some Amazon Marketplace sellers show unusual company names — category is still office supplies
- Meta ads for marketplace listings are corporate advertising expenses
- USD amounts need conversion to CAD for bookkeeping
- Windsor Greene property is a room rental location managed by Intersite Consulting
- Receipts showing $0.00 (Windsor Greene) are informational notices, not invoices

## Tax rules
- PST exemption: management fees, rent, strata fees
- GST applies to: management fees, internet, repairs
- No tax on: rent payments to strata
- PST + GST applies to goods (Amazon purchases)
- No tax on digital services (Amazon Web Services)
- GST/HST does not apply to cross-border digital ads (Meta)
- No PST/GST on strata fees or rent (Windsor Greene)

## Flags
- Any amount > $500 should be reviewed
- Any amount that doesn't match expected monthly amounts within $0.50 should be flagged
- Dates that differ from the photo EXIF by more than 30 days should be reviewed
- Negative amounts on Amazon purchases indicate refunds — flag for review
- Meta ad spend exceeding $200/month requires budget approval review
- Any positive dollar amount on a Windsor Greene document requires review
