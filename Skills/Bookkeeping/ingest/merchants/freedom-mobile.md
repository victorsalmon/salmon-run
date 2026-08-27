# Freedom Mobile — Invoice Rubric

## Detection

### pdfplumber text layout

```python
import pdfplumber

with pdfplumber.open(path) as pdf:
    text = pdf.pages[0].extract_text() or ''
    is_freedom = 'Freedom Mobile' in text or 'Freedom Network' in text
```

Freedom Mobile invoices contain "Freedom Mobile" or "Freedom Network" in the page text. The account number pattern is `DBC\d+-\d+`.

## Document Type

### Invoice (monthly wireless bill)

- Header: **"Freedom Mobile"** logo / text
- Fields: Bill No., Date Issued, Due Date
- Account: `DBC\d+-\d+` (account number in page header)
- Phone line: `***REMOVED-PHONE***` (or similar 10-digit number)
- Tax: GST-BC 5% + PST-BC 7%

```
***REMOVED-NAME*** Salmon Account No. DBC000-9590-7978
... Bill No. 817485756
Date Issued Oct 25, 2025

PREVIOUS BALANCE CURRENT CHARGES AMOUNT DUE DUE DATE
$0.00 + $33.60 = $33.60 Nov 07, 2025

CURRENT CHARGES
***REMOVED-PHONE*** $30.00
Freedom 6 GB 30 Care (Oct 25 to Nov 24) $30.00
TOTAL CURRENT CHARGES $33.60
Current Charges Sub-total $30.00
GST-BC 5% 822527412 $1.50
PST-BC 7% 10140369 $2.10
```

## Key Extraction Fields

| Field | How to find | Notes |
|-------|------------|-------|
| Invoice number | `re.search(r'Bill No\. (\d+)', text)` | Label is "Bill No." not "Invoice #" |
| Date issued | `re.search(r'Date Issued (.+)', text)` | "Date Issued" header, not "Invoice Date" |
| Due date | `re.search(r'= \$[\d.]+ (.+)', text)` | On same line as amount due after "=" |
| Current charges | `re.search(r'TOTAL CURRENT CHARGES \$?([\d.]+)', text)` | The actual invoice total |
| Sub-total | `re.search(r'Sub-total \$?([\d.]+)', text)` | Charges before tax |
| GST | `re.search(r'GST-BC.+?(\d+\.\d{2})', text)` | GST line |
| PST | `re.search(r'PST-BC.+?(\d+\.\d{2})', text)` | PST line |
| Phone line | Phone number like `***REMOVED-PHONE***` before first $ amount | Primary subscriber line |
| Plan name | `re.search(r'Freedom \d+ GB.+?Care', text)` | Plan description with billing period |
| Previous balance | `re.search(r'Previous Amount Due \$?([\d.]+)', text)` | Last month's total |
| Payment received | `re.search(r'Payment Received \$?([\d.]+)', text)` | Amount paid since last bill |

## Renaming Convention

```
{date_issued} - {total} - {vendor}.pdf
```

- `2025-10-25 - 33.60 - Freedom Mobile.pdf`
- `2025-06-25 - 33.60 - Freedom Mobile.pdf`

Add `duplicate N` suffix if the same (date, amount, vendor) triplet already exists:
- `2025-10-25 - 33.60 - Freedom Mobile duplicate 1.pdf`

## Known Invoice Numbers Seen

| Date | Bill No. | Amount |
|------|----------|--------|
| 2025-06-25 | 799421495 | $33.60 |
| 2025-07-25 | 803974727 | $33.65 |
| 2025-08-25 | 808500435 | $61.60 |
| 2025-09-25 | 813009616 | $33.60 |
| 2025-10-25 | 817485756 | $33.60 |

## Default Deduction Category

`Telecommunications`

## See Also

- `Skills/Bookkeeping/Scripts/pdf/convert-pdf-invoice-to-sidecar.py` — automated extractor with `freedom-mobile` processor
- `Plugins/clock-lobster-books/account/ingest-pdf/SKILL.md` — master invoice/PDF ingest skill
