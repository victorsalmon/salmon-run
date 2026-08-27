# InterServer — Invoice Rubric

## Detection

### pdfplumber text layout

```python
import pdfplumber

with pdfplumber.open(path) as pdf:
    text = pdf.pages[0].extract_text() or ''
    is_interserver = 'InterServer' in text or 'interserver' in text
```

InterServer invoices arrive as email forwards with "[InterServer] Invoice" in the subject line. The PDF text contains "InterServer" (or "INTERSERVER.NET" on the bank statement).

## Document Type

### Invoice (web hosting — monthly recurring)

- Header: **"Invoice"**
- Sender: **InterServer** / noreply@interserver.net
- Format: Email-forwarded PDF via Gmail
- Amount: **$5.00 USD** (fixed, every month)
- Service: **Standard Web Hosting**

```
Invoice
PO BOX 1707 Englewood Cliffs NJ 07632 . 201-605-1440
Name: Victor Salmon INVOICE DATE: December 2, 2025
Company: Intersite Web Consulting Ltd. LATE DATE: December 16, 2025
Address: ***REMOVED-ADDRESS*** Road, Unit 209
Richmond, Canada V6Y 1A2 PERIOD: Monthly

Description                                Amount
40723463 Standard Web Hosting
  Hostname: intersite.ca Username: intersit    $5
Totals
```

## Key Extraction Fields

| Field | How to find | Notes |
|-------|------------|-------|
| Invoice number | `(\d+)\s+Standard Web Hosting` | Leading number on the description line |
| Date issued | `INVOICE DATE:\s*(.+?)(?:\n|$)` | Format: "December 2, 2025" |
| Due date | `LATE DATE:\s*(.+?)(?:\n|$)` | Format: "December 16, 2025" |
| Total | Always `$5.00` USD | Fixed monthly rate |
| Currency | USD | Always USD — bank statement converts to CAD at varying FX rates |
| Hostname | `Hostname:\s*(\S+)` | e.g., `intersite.ca` |
| Account | `Username:\s*(\S+)` | Always `intersit` |

## Payment & Statement Matching

| Detail | Value |
|--------|-------|
| Bank statement description | `INTERSERVER.NET SECAUCUS` |
| USD amount on statement | `5.0 USD @ X.XXX` (FX rate varies monthly) |
| CAD amount posted | ~$7.00–$7.40 (varies with FX) |
| Typical posting date | ~3rd of each month |
| Payment account | **MC 6258** (RBC Business Cash Back Mastercard) |

**Matching hint:** Match by USD amount ($5.00) against the `Description 2` field which contains `5.0 USD @ X.XXX`. The CAD amount posted varies, so matching by CAD fails. Always match by the USD original amount.

## Renaming Convention

```
{date_issued} - 5.00 - InterServer.pdf
```

Example: `2025-12-02 - 5.00 - InterServer.pdf`

## Known Invoice Periods

| Invoice Date | Invoice # | Amount |
|-------------|-----------|--------|
| April 2, 2025 | (varies) | $5.00 |
| May 2, 2025 | (varies) | $5.00 |
| ... (monthly) | ... | $5.00 |
| December 2, 2025 | 40723463 | $5.00 |

## Default Deduction Category

`Software & IT Expenses` (Intersite Consulting — web hosting for business websites)

## See Also

- `Skills/Bookkeeping/Scripts/pdf/convert-pdf-invoice-to-sidecar.py` — automated extractor with `interserver` processor
- `Plugins/clock-lobster-books/account/ingest-pdf/SKILL.md` — master invoice/PDF ingest skill
