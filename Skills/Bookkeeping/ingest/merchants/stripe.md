# Stripe — Invoice & Receipt Rubric

## Detection

### Method A — Raw PDF metadata (fastest)

```
Select-String -Pattern "invoice\.stripe\.com" <file>.pdf
```

Stripe invoices embed a `https://invoice.stripe.com/i/...` link in the PDF annotation layer. Receipts and payout reports do not embed this URL but share the same layout DNA.

### Method B — pdfplumber text layout

```python
import pdfplumber

with pdfplumber.open(path) as pdf:
    text = pdf.pages[0].extract_text() or ''
    # Stripe documents have these distinct headers
    is_stripe_invoice = 'Invoice' in text and 'Bill to' in text and 'Date of issue' in text
    is_stripe_receipt = 'Receipt' in text and 'Bill to' and 'Receipt number' in text
```

## Document Types

### Type 1 — Invoice (payment request)
- Header: **"Invoice"**
- Fields: Invoice number, Date of issue, Date due
- Left column: Vendor name + address
- Right column: "Bill to" + customer name + address
- Payment link: "Pay online" or link to `invoice.stripe.com`
- **Has `invoice.stripe.com` URL in PDF metadata** — definitive detection

```
Invoice

Invoice number XXXXXXXX-0001

Date of issue April 14, 2026
Date due  April 14, 2026

Vendor Name                     Bill to
Vendor Address                  Customer Name
                                Customer Address
```

### Type 2 — Receipt (payment confirmation)
- Header: **"Receipt"**
- Fields: Invoice number, Receipt number, Date paid
- Left column: Vendor name + address
- Right column: "Bill to" + customer name + address
- "Payment history" section with payment method + date
- Shows amount paid (may differ from subtotal due to discounts/promos)
- Does NOT embed `invoice.stripe.com` in raw bytes — use text layout to detect

```
Receipt

Invoice number XXXXXXXX-0001
Receipt number 1234-5678
Date paid  April 15, 2026

Vendor Name                     Bill to
Vendor Address                  Customer Name
                                Customer Address
```

### Type 3 — Payout / Transaction Report (Stripe merchant)
- Contains "Stripe" in title, payout IDs (`po_...`), and Stripe dashboard URLs
- Does NOT have invoice/receipt header — has payout amounts and fee breakdowns
- Generated when you are the Stripe merchant (receiving payouts)

## Key Extraction Fields

| Field | How to find | pdfplumber hint |
|-------|------------|-----------|
| Invoice number | `re.search(r'Invoice number (\S+)', text)` | First `\S+` after "Invoice number" |
| Receipt number (receipts only) | `re.search(r'Receipt number (\S+)', text)` | |
| Vendor name | Text block left of "Bill to" column — first line | Vendor is the block before "\s{2,}Bill to" |
| Customer email | Last `\S+@\S+` before the line items table | In the "Bill to" address block |
| Line items | Table rows between "Description" header and "Subtotal" | Variable columns (Qty/Unit price/Amount) |
| Subtotal | `re.search(r'Subtotal\s+\$?([0-9,.]+)', text)` | |
| Total | `re.search(r'Total\s+\$?([0-9,.]+)', text)` | |
| Amount paid (receipts) | `re.search(r'Amount paid\s+\$?([0-9,.]+)', text)` | |
| FX conversion (receipts) | `re.search(r'Charged CA\$[0-9.]+ using \d+ USD = [0-9.]+ CAD', text)` | Receipts show CAD debit from USD invoice |

## Vendors Seen Using Stripe in Our Receipts

| Vendor | Stripe account | What for | Document types seen |
|--------|---------------|----------|-------------------|
| **KiloCode** (kilo.ai) | `acct_1R1ePOJ7A6SsvrfS` | AI coding credits | Invoice |
| **Anomaly** (anoma.ly — opencode.ai) | `acct_1RszBH2StuRr0lbX` | OpenCode Go subscription ($10/mo) | Invoice + Receipt |
| **Intersite Consulting Inc.** (self) | `acct_1M7UezF4sXqOKWRe` | Tenant coordination billing (TMH, FRA, MIL properties) | Invoice (outbound) + Payout report |

## Detection Script (pdfplumber)

```python
import pdfplumber, re

def classify_stripe_pdf(path):
    """Returns document type and extracted fields, or None if not Stripe."""
    with pdfplumber.open(path) as pdf:
        text = pdf.pages[0].extract_text() or ''

    # Check raw bytes for definitive Stripe invoice URL
    with open(path, 'rb') as f:
        raw = f.read()
    has_invoice_url = b'invoice.stripe.com' in raw

    result = {
        'processor': 'stripe' if has_invoice_url else None,
        'doc_type': None,
        'vendor': None,
        'invoice_number': None,
    }

    if has_invoice_url:
        result['processor'] = 'stripe'
        result['doc_type'] = 'invoice'

    if 'Receipt' in text and 'Bill to' in text and 'Receipt number' in text:
        result['processor'] = 'stripe'
        result['doc_type'] = 'receipt'

    if 'Stripe' in text and ('Payout' in text or 'payout' in text):
        result['processor'] = 'stripe'
        result['doc_type'] = 'payout_report'

    # Extract invoice number
    m = re.search(r'(?:Invoice|Receipt) number\s+(\S+)', text)
    if m:
        result['invoice_number'] = m.group(1)

    # Detect vendor from the "Vendor vs Bill to" layout
    # Vendor is the text block before 'Bill to'
    m = re.search(r'(?:^|\n)([A-Za-z][A-Za-z0-9 .\n]+?)\s{2,}(?:Bill to)', text)
    if m:
        vendor_raw = m.group(1).strip().split('\n')[0]
        result['vendor'] = vendor_raw

    return result
```

## Renaming Convention

```
{date} - {amount} - {vendor} - {product description}.pdf
```

Examples:
- `2026-04-09 - 10.0 - KiloCode - Balance Top Up.pdf`
- `2026-04-14 - 10.0 - Anomaly - OpenCode Go (Intersite Consulting).pdf`
- `2026-04-15 - 10.0 - Anomaly - OpenCode Go (***REMOVED-EMAIL***).pdf`

For duplicate receipts (same invoice #), append `duplicate N`:
- `2026-04-16 - 10.0 - Anomaly - OpenCode Go (email) duplicate 1.pdf`
