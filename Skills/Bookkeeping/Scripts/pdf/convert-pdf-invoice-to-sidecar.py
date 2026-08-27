#!/usr/bin/env python3
"""Convert invoice PDFs to .md extraction dumps and .csv sidecars.

All three outputs (PDF, MD, CSV) share the same short base name:
  {date} - {amount} - {vendor}.{ext}

Usage:
    python convert-pdf-invoice-to-sidecar.py <pdf1.pdf> [pdf2.pdf ...]
    python convert-pdf-invoice-to-sidecar.py --dir <directory>
    python convert-pdf-invoice-to-sidecar.py --dir <directory> --recurse

Sidecar CSV fields:
  invoice_number, vendor, date_issued, date_due, date_paid,
  subtotal, tax, total, currency, status, tax_deduction_category,
  items, description_short, processor
"""

import pdfplumber
import csv
import json
import os
import re
import sys
import shutil
import base64
import io
import tempfile
import time
import datetime
from datetime import date
from concurrent.futures import ThreadPoolExecutor

import pypdfium2 as pdfium
import requests
from PIL import Image


VALID_YEAR_MIN = 2024
VALID_YEAR_MAX = 2027

MONTHS = {
    'jan': 1, 'january': 1,
    'feb': 2, 'february': 2,
    'mar': 3, 'march': 3,
    'apr': 4, 'april': 4,
    'may': 5,
    'jun': 6, 'june': 6,
    'jul': 7, 'july': 7,
    'aug': 8, 'august': 8,
    'sep': 9, 'september': 9,
    'oct': 10, 'october': 10,
    'nov': 11, 'november': 11,
    'dec': 12, 'december': 12,
}


def extract_all_text(pdf_path):
    """Extract text from all pages using pdfplumber. Returns list of (page_num, text)."""
    pages = []
    with pdfplumber.open(pdf_path) as pdf:
        for i, page in enumerate(pdf.pages, 1):
            t = page.extract_text() or ''
            pages.append((i, t))
    return pages


def write_md(base_path, pages, source_basename):
    """Write pdfplumber text dump as .md file using the short base name."""
    md_path = base_path + '.md'
    with open(md_path, 'w', encoding='utf-8') as f:
        f.write(f'# Invoice: {source_basename}\n\n')
        f.write(f'> Extracted: {date.today().isoformat()}\n')
        f.write(f'> Pages: {len(pages)}\n')
        f.write(f'> Processor: pdfplumber\n\n')
        f.write('---\n\n')
        for page_num, text in pages:
            f.write(f'## Page {page_num}\n\n')
            f.write(text.strip() + '\n\n')
            f.write('---\n\n')
    print(f'  MD  -> {os.path.basename(md_path)}')
    return md_path


def parse_amount_from_text(s):
    s = s.strip().replace(',', '')
    m = re.search(r'[\d]+\.[\d]{2}', s)
    if m:
        return float(m.group())
    m = re.search(r'[\d]+', s)
    if m:
        return float(m.group())
    return None


def parse_date(text):
    """Try to parse a date from text. Returns YYYY-MM-DD string or None."""
    patterns = [
        (r'(\d{4}-\d{2}-\d{2})', lambda m: m.group(1)),
        (r'(\w+)\s+(\d+),\s*(\d{4})', lambda m: _normalize_date(m.group(1), int(m.group(2)), int(m.group(3)))),
        (r'(\w+)\s+(\d+)\s+(\d{4})', lambda m: _normalize_date(m.group(1), int(m.group(2)), int(m.group(3)))),
        (r'(\d{2})/(\d{2})/(\d{4})', lambda m: f'{m.group(3)}-{m.group(1)}-{m.group(2)}'),
    ]
    for pat, formatter in patterns:
        m = re.search(pat, text)
        if m:
            try:
                return formatter(m)
            except (ValueError, IndexError):
                continue
    return None


def _normalize_date(month_str, day, year):
    month_str = month_str.strip().lower()[:3]
    month_num = MONTHS.get(month_str)
    if month_num and 1 <= month_num <= 12 and 1 <= day <= 31:
        return f'{year:04d}-{month_num:02d}-{day:02d}'
    return None


def validate_date(date_str):
    """Return date_str if valid YYYY-MM-DD with year in valid range, else None."""
    try:
        parts = date_str.split('-')
        if len(parts) == 3:
            y, m, d = int(parts[0]), int(parts[1]), int(parts[2])
            if VALID_YEAR_MIN <= y <= VALID_YEAR_MAX and 1 <= m <= 12 and 1 <= d <= 31:
                return date_str
    except:
        pass
    return None


def validate_business_year(date_str):
    """Strict year-range check for vision-extracted dates.
    Rejects dates outside 2024-2027 even if structurally valid YYYY-MM-DD."""
    return validate_date(date_str)


def detect_currency(text):
    if re.search(r'CA\$|CAD', text):
        return 'CAD'
    if re.search(r'US\$|USD', text):
        return 'USD'
    return ''


def clean_vendor_name(name):
    name = name.strip().rstrip(',').rstrip('.').rstrip(',').strip()
    # Strip "Vendu par" / "Sold by" labels and leading punctuation
    name = re.sub(r'^[/,\s]*(?:Vendu\s+par|Sold\s+by)\s*:?\s*', '', name, flags=re.IGNORECASE).strip()
    # Remove trailing "Inc" suffix and similar
    name = re.sub(r',\s*(Inc|Ltd|Limited|LLC|Corp|Corporation|LP)\.?$', '', name, flags=re.IGNORECASE)
    name = re.sub(r'\s+(Inc|Ltd|Limited|LLC|Corp|Corporation|LP)\.?$', '', name, flags=re.IGNORECASE)
    # Strip trailing punctuation again
    name = name.strip().rstrip(',').rstrip('.').strip()
    return name


def sanitise_filename(name):
    name = re.sub(r'[<>:"/\\|?*]', '', name)
    name = re.sub(r'\s+', ' ', name).strip()
    return name


def parse_amount_from_filename(source_basename):
    """Extract the transaction amount from a filename like '2025-06-25 - 33.6 - Vendor.pdf'."""
    m = re.search(r'-\s*([\d]+\.?\d*)\s*-', source_basename)
    if m:
        return m.group(1)
    m = re.search(r'([\d]+\.?\d*)', source_basename)
    if m:
        return m.group(1)
    return ''


def parse_date_from_filename(source_basename):
    """Extract an ISO date from a filename like '2025-06-25 - 33.6 - Vendor.pdf'."""
    m = re.search(r'(\d{4}-\d{2}-\d{2})', source_basename)
    if m:
        return m.group(1)
    return ''


def build_base_name(fields, source_basename):
    """Build the short base name shared by all three files.
    Falls back to filename-based values when model returns bad data."""
    date_str = validate_date(fields.get('date_issued', '')) or parse_date_from_filename(source_basename)
    amt = fields.get('total', '') or fields.get('subtotal', '') or parse_amount_from_filename(source_basename)
    vendor = fields.get('vendor', 'Unknown')
    if _is_bad_vendor(vendor):
        # Extract vendor from original filename
        fn_parts = os.path.splitext(source_basename)[0].split(' - ')
        if len(fn_parts) >= 3:
            vendor = fn_parts[-1]  # Last segment of filename is usually vendor
        elif len(fn_parts) == 2:
            vendor = fn_parts[-1]
    parts = [p for p in [date_str, amt, vendor] if p]
    return sanitise_filename(' - '.join(parts))


# ---- Processor: Stripe ----

def try_stripe(pdf_path, pages):
    text = '\n'.join(t for _, t in pages)

    try:
        with open(pdf_path, 'rb') as f:
            raw = f.read()
    except OSError as e:
        print(f"  ERROR reading {pdf_path}: {e}", file=sys.stderr)
        return None
    has_invoice_url = b'invoice.stripe.com' in raw

    is_invoice = has_invoice_url or (
        'Invoice' in text and 'Bill to' in text and 'Date of issue' in text
    )
    is_receipt = 'Receipt' in text and 'Bill to' in text and 'Receipt number' in text

    if not is_invoice and not is_receipt:
        return None

    fields = {
        'invoice_number': '',
        'vendor': '',
        'date_issued': '',
        'date_due': '',
        'date_paid': '',
        'subtotal': '',
        'tax': '',
        'total': '',
        'currency': detect_currency(text),
        'status': '',
        'tax_deduction_category': '',
        'items': '',
        'description_short': '',
        'processor': 'stripe',
    }

    m = re.search(r'(?:Invoice|Receipt) number\s+(\S+)', text)
    if m:
        fields['invoice_number'] = m.group(1)

    # Vendor: find line ending just before "Bill to" (may be on same line with spacing)
    m = re.search(r'([A-Za-z][\w\s.\',&-]+?)\s{2,}(?:Bill to)', text)
    if m:
        raw = m.group(1).strip().split('\n')[0]
        fields['vendor'] = clean_vendor_name(raw)
    if not fields.get('vendor'):
        # Fallback: text before "Bill to" on same line
        m = re.search(r'(.+?)\s*Bill to', text)
        if m:
            raw = m.group(1).strip().split('\n')[-1]
            if raw and not re.match(r'^[\d\s,]+$', raw):
                fields['vendor'] = clean_vendor_name(raw)

    m = re.search(r'Date of issue\s+(.+?)(?:\n|$)', text)
    if m:
        d = parse_date(m.group(1))
        if d:
            fields['date_issued'] = d

    m = re.search(r'Date due\s+(.+?)(?:\n|$)', text)
    if m:
        d = parse_date(m.group(1))
        if d:
            fields['date_due'] = d

    m = re.search(r'Date paid\s+(.+?)(?:\n|$)', text)
    if m:
        d = parse_date(m.group(1))
        if d:
            fields['date_paid'] = d

    m = re.search(r'Subtotal\s+\$?([\d,]+\.?\d*)', text)
    if m:
        fields['subtotal'] = m.group(1).replace(',', '')

    m = re.search(r'Total\s+\$?([\d,]+\.?\d*)', text)
    if m:
        fields['total'] = m.group(1).replace(',', '')

    m = re.search(r'Amount paid\s+\$?([\d,]+\.?\d*)', text)
    if m:
        fields['total'] = m.group(1).replace(',', '')

    fields['status'] = 'paid' if is_receipt else ('unpaid' if is_invoice else '')

    # Extract line items
    items = []
    lines = text.split('\n')
    in_items = False
    for line in lines:
        if 'Description' in line and ('Qty' in line or 'Unit price' in line):
            in_items = True
            continue
        if in_items and line.strip():
            if 'Subtotal' in line or 'Total' in line:
                break
            parts = re.split(r'\s{2,}', line.strip())
            if parts:
                desc = parts[0].strip()
                amt_raw = parts[-1].strip() if len(parts) > 1 else ''
                amt = parse_amount_from_text(amt_raw) if amt_raw else None
                items.append({'description': desc, 'amount': amt})
                if not fields['description_short'] and not re.match(r'^[\d.,]+$', desc):
                    fields['description_short'] = desc
    if items:
        fields['items'] = json.dumps(items, ensure_ascii=False)

    return fields


# ---- Processor: Freedom Mobile ----

def try_freedom_mobile(pdf_path, pages):
    """Detect and extract from Freedom Mobile invoice PDFs.

    Layout (page 1):
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
    """
    text = '\n'.join(t for _, t in pages)

    if not re.search(r'Freedom\s*(?:Mobile|Network)', text, re.IGNORECASE):
        return None

    fields = {
        'invoice_number': '',
        'vendor': 'Freedom Mobile',
        'date_issued': '',
        'date_due': '',
        'date_paid': '',
        'subtotal': '',
        'tax': '',
        'total': '',
        'currency': 'CAD',
        'status': '',
        'tax_deduction_category': 'Telecommunications',
        'items': '',
        'description_short': '',
        'processor': 'freedom-mobile',
    }

    # Bill No. 817485756
    m = re.search(r'Bill\s*(?:No\.?|Number)\s*(\S+)', text)
    if m:
        fields['invoice_number'] = m.group(1)

    # Date Issued Oct 25, 2025
    m = re.search(r'Date\s+Issued\s+(.+?)(?:\n|$)', text)
    if m:
        d = parse_date(m.group(1))
        if d:
            fields['date_issued'] = d

    # DUE DATE: find date on line after "DUE DATE" header
    # Line pattern: $X + $Y = $Z <due_date>
    m = re.search(r'\$[\d,]+\.?\d*\s*\+\s*\$[\d,]+\.?\d*\s*=\s*\$([\d,]+\.?\d*)\s+(.+?)(?:\n|$)', text)
    if m:
        fields['total'] = m.group(1).replace(',', '')
        d = parse_date(m.group(2))
        if d:
            fields['date_due'] = d

    # TOTAL CURRENT CHARGES $33.60
    m = re.search(r'TOTAL\s+CURRENT\s+CHARGES\s+\$?([\d,]+\.?\d*)', text)
    if m:
        if not fields['total']:
            fields['total'] = m.group(1).replace(',', '')

    # Current Charges Sub-total $30.00
    m = re.search(r'Sub-total\s+\$?([\d,]+\.?\d*)', text)
    if m:
        fields['subtotal'] = m.group(1).replace(',', '')

    # GST-BC 5% ... $1.50  and  PST-BC 7% ... $2.10
    taxes = []
    for line in text.split('\n'):
        m = re.search(r'(GST|HST|PST|QST)-\w+\s+[\d%]+\s+\S*\s*\$?([\d,]+\.\d{2})', line, re.IGNORECASE)
        if m:
            taxes.append(parse_amount_from_text(m.group(2)))
    if taxes:
        fields['tax'] = str(sum(taxes))

    # Line items: charge-level items, excluding summaries and taxes
    items = []
    exclude_patterns = [
        r'\bTOTAL\b', r'\bSub-total\b', r'\bPrevious\b', r'\bPayment Received\b',
        r'\bCurrent Invoice\b', r'\bGST-', r'\bHST-', r'\bPST-', r'\bQST-',
        r'^Total$', r'Page\s+\d', r'AMOUNT DUE', r'DUE DATE',
    ]
    exclude_re = re.compile('|'.join(exclude_patterns), re.IGNORECASE)
    for line in text.split('\n'):
        line = line.strip()
        if not line or exclude_re.search(line):
            continue
        m = re.search(r'^(.+?)\s+\$?([\d,]+\.\d{2})\s*$', line)
        if m:
            desc = m.group(1).strip()
            amt = parse_amount_from_text(m.group(2))
            if amt and amt > 0:
                items.append({'description': desc, 'amount': amt})

    if items:
        fields['items'] = json.dumps(items, ensure_ascii=False)
        # Best description: the plan/line item, not the phone number
        for item in items:
            desc = item['description']
            if not re.match(r'^[\d-]+$', desc) and len(desc) > 5:
                fields['description_short'] = desc
                break
        if not fields['description_short']:
            fields['description_short'] = items[0]['description']
    else:
        for line in text.split('\n'):
            line = line.strip()
            if re.search(r'plan|service|monthly|wireless|talk|text|data', line, re.IGNORECASE):
                fields['description_short'] = line
                break

    return fields


# ---- Processor: Amazon.ca ----

def try_amazon(pdf_path, pages):
    """Detect and extract from Amazon.ca order summary PDFs.

    Layout:
      Order Summary
      Order placed October 9, 2025 Order number 701-...
      Ship to Payment method Order Summary
      Intersite Consulting Inc. RBC Cash Back Mastercard****6258 Item(s) Subtotal: $299.99
      ...
      Grand Total: $335.99
      Sold by: Amazon.ca
    """
    text = '\n'.join(t for _, t in pages)

    if not re.search(r'Order\s+(?:placed|Summary)', text, re.IGNORECASE):
        return None
    if not re.search(r'(?:Grand\s+)?Total\s*:?\s*\$', text):
        return None
    if not re.search(r'(?:RBC|Mastercard|AMZN|Amazon\.ca)', text):
        return None

    fields = {
        'invoice_number': '',
        'vendor': 'Amazon.ca',
        'date_issued': '',
        'date_due': '',
        'date_paid': '',
        'subtotal': '',
        'tax': '',
        'total': '',
        'currency': 'CAD',
        'status': 'paid',
        'tax_deduction_category': '',
        'items': '',
        'description_short': '',
        'processor': 'amazon',
    }

    m = re.search(r'Order\s+(?:placed|number)\s+(.+?)(?:\s+Order\s+number|$)', text)
    if not m:
        m = re.search(r'Order\s+placed\s+(.+?)(?:\n|$)', text)
    if m:
        d = parse_date(m.group(1))
        if d:
            fields['date_issued'] = d

    m = re.search(r'Grand\s+Total\s*:?\s*\$?([\d,]+\.?\d*)', text)
    if m:
        fields['total'] = m.group(1).replace(',', '')

    m = re.search(r'(?:Item\(s\)\s+)?Subtotal\s*:?\s*\$?([\d,]+\.?\d*)', text)
    if m:
        fields['subtotal'] = m.group(1).replace(',', '')

    # Tax: sum GST/HST + PST/RST/QST
    taxes = re.findall(r'(?:Estimated\s+)?(?:GST|HST|PST|RST|QST).*?\$?([\d,]+\.?\d*)', text)
    if taxes:
        fields['tax'] = str(sum(float(t.replace(',','')) for t in taxes))

    # Detect card suffix for routing
    m = re.search(r'Mastercard[^*]*\*{2,}(\d{4})', text)
    if not m:
        m = re.search(r'\*{2,}(\d{4})', text)
    if m:
        fields['description_short'] = f'MC *{m.group(1)}'

    # Extract line items
    # Amazon order PDFs put the product name on its own line(s), then the price on a separate line.
    # Pattern: product desc line(s) followed later by $XX.XX on its own line.
    items = []
    lines = [l.strip() for l in text.split('\n') if l.strip()]

    # First pass: find standalone price lines (like "$299.99" or "299.99")
    price_lines = []
    for i, line in enumerate(lines):
        m = re.match(r'^\$?([\d,]+\.\d{2})\s*$', line)
        if m:
            amt = float(m.group(1).replace(',', ''))
            price_lines.append((i, amt))

    # For each price, look backwards to find the product description
    NON_PRODUCT_STOP = [
        'conditions of use', 'privacy notice', 'shipping address', 'payment method',
        'order summary', 'item(s) subtotal', 'shipping & handling', 'total before tax',
        'estimated', 'grand total', 'order placed', 'order number', 'payment information',
        'billing address', 'credit card', 'mastercard', 'visa',
        'buy it again', 'view your item', 'write a product review',
        'pick up where you left off', 'back to top', 'www.amazon',
        '© 1996', 'amazon.com.ca ulc', 'page ', '\\*\\*\\*\\*',
        'your coupon savings',
    ]
    # Lines that can appear between product description and price — skip and continue
    NON_PRODUCT_SEPARATOR = [
        'sold by', 'delivered', 'package was',
        'return', 'eligible', 'refund',
    ]

    for price_idx, amt in price_lines:
        if amt > 10000 or amt < 0.01:
            continue
        # Walk backwards from price line to find product description
        desc_lines = []
        for j in range(price_idx - 1, -1, -1):
            candidate = lines[j]
            # Skip separator lines (sold by, return, delivered) — keep walking
            if any(re.search(kw, candidate, re.IGNORECASE) for kw in NON_PRODUCT_SEPARATOR):
                continue
            # Stop at hard boundaries
            if any(re.search(kw, candidate, re.IGNORECASE) for kw in NON_PRODUCT_STOP):
                break
            # Stop at dates/time patterns
            if re.match(r'^\d{1,2}/\d{1,2}/\d{2}', candidate):
                break
            # Stop at pure dollar amounts (another product's price)
            if re.match(r'^\$?\d+\.?\d*$', candidate):
                break
            # Stop at standalone card numbers or payment info
            if re.match(r'^\*{2,}\d{4}', candidate):
                break
            desc_lines.insert(0, candidate)

        if desc_lines:
            desc = ' '.join(desc_lines).strip()
            # Filter out non-product descriptions
            skip = any(re.search(kw, desc, re.IGNORECASE) for kw in NON_PRODUCT_STOP + NON_PRODUCT_SEPARATOR)
            if desc and len(desc) > 5 and not skip:
                items.append({'description': desc[:200], 'amount': amt})

    # Fallback: try same-line format (older Amazon invoice style, French invoices)
    if not items:
        for line in lines:
            m = re.search(r'^(.+?)\s{2,}\$?([\d,]+\.\d{2})\s*$', line)
            if m:
                desc = m.group(1).strip()
                amt = float(m.group(2).replace(',', ''))
                if 'Sold by' not in desc and 'Conditions' not in desc and 'Delivered' not in desc:
                    items.append({'description': desc, 'amount': amt})

    # Detect payment card for routing hint
    m = re.search(r'RBC\s+Cash\s+Back\s+Mastercard.*?(\d{4})', text)
    if m:
        card = m.group(1)
        for item in items:
            item['card'] = f'*{card}'
        if not fields['description_short']:
            fields['description_short'] = f'MC *{card}'

    if items:
        # Only keep items with positive amounts and reasonable descriptions
        charge_items = [i for i in items if i['amount'] > 0 and len(i['description']) > 5]
        if charge_items:
            fields['items'] = json.dumps(charge_items, ensure_ascii=False)
            if not fields['description_short']:
                fields['description_short'] = charge_items[0]['description'][:80]

    return fields


# ---- Processor: InterServer ----

def try_interserver(pdf_path, pages):
    """Detect and extract from InterServer web hosting invoice PDFs.

    Layout (email-forwarded invoice):
      [InterServer] Invoice for Websites Standard Web Hosting
      Invoice
      PO BOX 1707 Englewood Cliffs NJ 07632 . 201-605-1440
      Name: Victor Salmon INVOICE DATE: December 2, 2025
      Company: Intersite Web Consulting Ltd. LATE DATE: December 16, 2025
      ...
      Description Amount
      40723463 Standard Web Hosting Hostname: intersite.ca Username: intersit $5
      Totals
    """
    text = '\n'.join(t for _, t in pages)
    basename = os.path.basename(pdf_path)

    # Check visible text, raw PDF bytes (email headers), and filename
    in_text = bool(re.search(r'InterServer|interserver|INTERSERVER|interserver\.net', text))
    in_raw = False
    try:
        with open(pdf_path, 'rb') as f:
            in_raw = b'InterServer' in f.read() or b'interserver' in f.read()
    except:
        pass
    in_name = bool(re.search(r'[Ii]nter[Ss]erver|[Ii]nter-server', basename))

    if not (in_text or in_raw or in_name):
        return None

    fields = {
        'invoice_number': '',
        'vendor': 'InterServer',
        'date_issued': '',
        'date_due': '',
        'date_paid': '',
        'subtotal': '',
        'tax': '',
        'total': '5.00',
        'currency': 'USD',
        'status': 'unpaid',
        'tax_deduction_category': 'Software & IT Expenses',
        'items': '',
        'description_short': 'Standard Web Hosting',
        'processor': 'interserver',
    }

    # Invoice number from description line
    m = re.search(r'(\d+)\s+Standard Web Hosting', text)
    if m:
        fields['invoice_number'] = m.group(1)

    m = re.search(r'INVOICE DATE:\s*(.+?)(?:\n|$)', text)
    if m:
        d = parse_date(m.group(1))
        if d:
            fields['date_issued'] = d

    m = re.search(r'LATE DATE:\s*(.+?)(?:\n|$)', text)
    if m:
        d = parse_date(m.group(1))
        if d:
            fields['date_due'] = d

    # Extract total from "Description Amount" line + "$5"
    m = re.search(r'Standard Web Hosting.*?\$?([\d]+\.?\d*)', text)
    if m:
        fields['total'] = m.group(1)

    # Extract hostname for description
    m = re.search(r'Hostname:\s*(\S+)', text)
    if m:
        fields['description_short'] = f'Standard Web Hosting - {m.group(1)}'

    items = []
    m = re.search(r'(\d+)\s+(Standard Web Hosting.*?)\$?([\d]+\.?\d*)', text)
    if m:
        items.append({
            'description': m.group(2).strip()[:60],
            'amount': float(m.group(3))
        })
        fields['items'] = json.dumps(items, ensure_ascii=False)

    return fields


# ---- Processor: Generic (heuristic fallback) ----

def try_generic(pdf_path, pages):
    text = '\n'.join(t for _, t in pages)

    signals = 0
    if re.search(r'\bInvoice\b', text):
        signals += 2
    if re.search(r'(?:Invoice|Inv\.?)\s*(?:#|No\.?|Number)\s*:?\s*\S', text, re.IGNORECASE):
        signals += 2
    if 'Bill to' in text:
        signals += 1
    if re.search(r'(?:Subtotal|Total|Amount Due)', text, re.IGNORECASE):
        signals += 1
    if re.search(r'Tax|GST|HST|VAT', text, re.IGNORECASE):
        signals += 1

    if signals < 3:
        return None

    fields = {
        'invoice_number': '',
        'vendor': '',
        'date_issued': '',
        'date_due': '',
        'date_paid': '',
        'subtotal': '',
        'tax': '',
        'total': '',
        'currency': detect_currency(text),
        'status': '',
        'tax_deduction_category': '',
        'items': '',
        'description_short': '',
        'processor': 'generic',
    }

    m = re.search(r'(?:Invoice|Inv\.?)\s*(?:#|No\.?|Number)\s*:?\s*(\S+)', text, re.IGNORECASE)
    if m:
        fields['invoice_number'] = m.group(1)

    # Try structured vendor patterns first
    m = re.search(r'(?:Vendu par|Sold by)\s*:?\s*(.+?)(?:\n|$)', text, re.IGNORECASE)
    if m:
        fields['vendor'] = clean_vendor_name(m.group(1))

    if not fields['vendor']:
        skip_vendor_keywords = [
            r'^Invoice', r'^Page\s+\d', r'^Date', r'^Order', r'^Commande',
            r'^Paid', r'^Pay[ée]', r'^Total', r'^Subtotal', r'^Amount',
            r'^Bill to', r'^Bill To', r'^Receipt', r'^Payment',
            r'^Thank you', r'^Merci', r'^\d', r'^[(\[]',
        ]
        skip_vendor_re = re.compile('|'.join(skip_vendor_keywords), re.IGNORECASE)
        first_lines = [l.strip() for l in text.split('\n')[:10] if l.strip()]
        for line in first_lines:
            if skip_vendor_re.search(line):
                continue
            if not re.match(r'^[A-Za-z]', line):
                continue
            fields['vendor'] = clean_vendor_name(line)
            break

    all_dates = []
    for line in text.split('\n'):
        d = parse_date(line)
        if d:
            all_dates.append(d)

    if all_dates:
        fields['date_issued'] = all_dates[0]
        if len(all_dates) > 1:
            fields['date_due'] = all_dates[1]

    total_patterns = [
        r'Grand\s+Total\s*:?\s*\$?([\d,]+\.?\d*)',
        r'Total\s+\$?([\d,]+\.?\d*)',
        r'Amount\s+Due\s*:?\s*\$?([\d,]+\.?\d*)',
        r'Balance\s+Due\s*:?\s*\$?([\d,]+\.?\d*)',
        r'Amount\s*:?\s*\$?([\d,]+\.?\d*)',
    ]
    for pat in total_patterns:
        m = re.search(pat, text, re.IGNORECASE)
        if m:
            fields['total'] = m.group(1).replace(',', '')
            break
    if not fields['total']:
        m = re.search(r'^\$?([\d,]+\.\d{2})\s*$', text, re.MULTILINE)
        if m:
            fields['total'] = m.group(1).replace(',', '')

    m = re.search(r'(?:Subtotal)\s*:?\s*\$?([\d,]+\.?\d*)', text, re.IGNORECASE)
    if m:
        fields['subtotal'] = m.group(1).replace(',', '')

    m = re.search(r'(?:GST|HST|VAT|Tax)\s*:?\s*\$?([\d,]+\.?\d*)', text, re.IGNORECASE)
    if m:
        fields['tax'] = m.group(1).replace(',', '')

    fields['currency'] = detect_currency(text) or 'CAD'

    if 'Paid' in text or 'Amount paid' in text.lower():
        fields['status'] = 'paid'
    elif 'Due' in text or 'Pay by' in text:
        fields['status'] = 'unpaid'

    return fields


# ---- Processors registry ----

PROCESSORS = [
    ('stripe', try_stripe),
    ('freedom-mobile', try_freedom_mobile),
    ('interserver', try_interserver),
    ('amazon', try_amazon),
    ('generic', try_generic),
]


def detect_and_extract(pdf_path, pages):
    for name, func in PROCESSORS:
        result = func(pdf_path, pages)
        if result is not None:
            return name, result
    return None, None


# ---- CSV sidecar ----

CSV_FIELDS = [
    'invoice_number', 'vendor', 'date_issued', 'date_due', 'date_paid',
    'subtotal', 'tax', 'total', 'currency', 'status', 'tax_deduction_category',
    'items', 'description_short', 'processor',
]


def write_csv(base_path, fields, source_basename):
    """Write structured CSV sidecar using the short base name."""
    csv_path = base_path + '.csv'

    with open(csv_path, 'w', newline='', encoding='utf-8') as f:
        f.write(f'# Generated: {datetime.datetime.now().isoformat()}\n')
        f.write(f'# Data source: {source_basename}\n')
        f.write(f'# Entity: {fields.get("entity", "")}\n')
        f.write(f'# Script: convert-pdf-invoice-to-sidecar.py\n')
        f.write(f'# Source: {source_basename}\n')
        f.write(f'# Vendor: {fields.get("vendor", "")}\n')
        f.write(f'# Invoice: {fields.get("invoice_number", "")}\n')
        f.write(f'# Processor: {fields.get("processor", "")}\n')
        f.write(f'# Generated: {date.today().isoformat()}\n')
        f.write('# \n')
        f.write(f'# Fields: {",".join(CSV_FIELDS)}\n')
        f.write('# \n')

        writer = csv.writer(f)
        writer.writerow(CSV_FIELDS)
        writer.writerow([fields.get(f, '') for f in CSV_FIELDS])

    print(f'  CSV -> {os.path.basename(csv_path)}')
    return csv_path


# ---- Vision Extraction (pypdfium2 → Dual-Model: GPT-4o-mini + Gemini 2.5 Flash) ----

OPENROUTER_KEY = os.environ.get("OPENROUTER_ORCH_KEY", os.environ.get("OPENROUTER_API_KEY", ""))
GPT_MODEL = "gpt-4o-mini"
GEMINI_MODEL = "google/gemini-2.5-flash"
VISION_MAX_RETRIES = 2

KNOWN_CARDS = {'6258', '549', '4699', '5820', '5303'}
KNOWN_BAD_VENDORS = {'unknown', 'company name or empty string', '', 'n/a', 'na', '-', 'null', 'none', 'nil', 'empty', 'blank'}


def _call_vision_model(pdf_input, model_name, api_key):
    """Render an image-based PDF and call a vision model via OpenRouter.
    pdf_input can be a file path (str) or PDF bytes (bytes).
    Returns (fields_dict, model_label) or (None, error_string)."""
    label = model_name.replace('/', '-')
    fields = {
        'invoice_number': '', 'vendor': '', 'date_issued': '', 'date_due': '',
        'date_paid': '', 'subtotal': '', 'tax': '', 'total': '',
        'currency': '', 'status': '', 'tax_deduction_category': '',
        'items': '', 'description_short': '', 'processor': f'vision-{label}',
    }

    try:
        doc = pdfium.PdfDocument(pdf_input)
    except Exception as e:
        return None, str(e)

    try:
        all_texts = []

        for i in range(len(doc)):
            page = doc[i]
            bitmap = page.render(scale=2)
            pil_img = bitmap.to_pil()

            buf = io.BytesIO()
            pil_img.save(buf, format="JPEG", quality=85)
            buf.seek(0)
            b64 = base64.b64encode(buf.read()).decode("utf-8")

            prompt = """Analyze this invoice/receipt image. Return ONLY valid JSON with these exact fields:
{
  "vendor": "",
  "date_issued": "",
  "subtotal": 0.0,
  "gst": 0.0,
  "pst": 0.0,
  "total": 0.0,
  "currency": "",
  "description": ""
}
Fill each field with the actual value from the image. Use empty string "" for unknown, 0.0 for missing amounts.
Rules:
- If not a receipt/invoice, set all fields to empty/null
- date_issued format: YYYY-MM-DD
- subtotal/gst/pst/total: numeric amounts only, no currency symbol
- gst and pst: individual tax amounts (not rates)
- currency: CAD or USD
- Return ONLY the JSON object, no other text"""

            body = {
                "model": model_name,
                "messages": [
                    {"role": "system", "content": prompt},
                    {"role": "user", "content": [
                        {"type": "text", "text": f"Extract data from this invoice page {i+1}."},
                        {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{b64}"}}
                    ]}
                ],
                "max_tokens": 500,
                "temperature": 0.1
            }

            for attempt in range(VISION_MAX_RETRIES):
                try:
                    resp = requests.post(
                        "https://openrouter.ai/api/v1/chat/completions",
                        headers={
                            "Authorization": f"Bearer {api_key}",
                            "X-Title": "convert-invoice-sidecar",
                            "Content-Type": "application/json"
                        },
                        json=body,
                        timeout=60
                    )
                    if resp.status_code == 429:
                        time.sleep(min(30, 5 * (attempt + 1)))
                        continue
                    resp.raise_for_status()
                    break
                except requests.exceptions.RequestException:
                    if attempt == VISION_MAX_RETRIES - 1:
                        return None, f"API error ({model_name})"
                    time.sleep(2)

            data = resp.json()
            content = data.get("choices", [{}])[0].get("message", {}).get("content", "")
            all_texts.append(content)

        if not all_texts:
            return None, f"No response ({model_name})"
        json_match = re.search(r'\{[^{}]*\}', all_texts[0], re.DOTALL)
        if json_match:
            parsed = json.loads(json_match.group())
            fields['vendor'] = parsed.get('vendor', '') or ''
            d = parsed.get('date_issued', '')
            if d:
                parsed_date = parse_date(str(d))
                if parsed_date and validate_business_year(parsed_date):
                    fields['date_issued'] = parsed_date
                else:
                    fields['date_issued'] = ''
            t = parsed.get('total', 0)
            try:
                fields['total'] = f"{float(t):.2f}" if t else ''
            except (ValueError, TypeError):
                fields['total'] = ''
            sub = parsed.get('subtotal', 0)
            try:
                fields['subtotal'] = f"{float(sub):.2f}" if sub else ''
            except (ValueError, TypeError):
                fields['subtotal'] = ''
            gst = parsed.get('gst', 0)
            pst = parsed.get('pst', 0)
            gst_f = 0.0
            pst_f = 0.0
            try:
                gst_f = float(gst) if gst else 0.0
            except (ValueError, TypeError):
                gst_f = 0.0
            try:
                pst_f = float(pst) if pst else 0.0
            except (ValueError, TypeError):
                pst_f = 0.0
            tax_total = gst_f + pst_f
            if tax_total > 0:
                fields['tax'] = f"{tax_total:.2f}"
            fields['currency'] = parsed.get('currency', '') or ''
            fields['description_short'] = parsed.get('description', '') or ''

        _sanitize_prompt_bled(fields)
        return 'vision', fields

    except Exception as e:
        return None, str(e)
    finally:
        doc.close()


def _valid_year(date_str):
    """Check if a YYYY-MM-DD date string has a year within the valid range."""
    if not date_str:
        return False
    try:
        y = int(date_str.split('-')[0])
        return VALID_YEAR_MIN <= y <= VALID_YEAR_MAX
    except (ValueError, IndexError):
        return False


def _is_bad_vendor(v):
    """Check if a vendor string is a hallucination / placeholder."""
    if not v:
        return True
    v_stripped = v.strip()
    if re.match(r'^[\d\s\.,\-_#@!?\(\)]+$', v_stripped):
        return True
    v_lower = v_stripped.lower()
    return v_lower in KNOWN_BAD_VENDORS


def _sanitize_prompt_bled(fields):
    """Clean prompt-bled placeholder text from all string fields.
    Vision models sometimes return instruction text instead of actual values:
    "company name", "unknown", "empty string", etc."""
    bled = {'company name', 'company name or empty string', 'unknown', 'empty string'}
    for key in fields:
        val = fields[key]
        if isinstance(val, str) and val.strip().lower() in bled:
            fields[key] = ''


def merge_vision_results(gpt_fields, gemini_fields):
    """Merge two vision model results, preferring non-hallucinated values.
    Returns a single fields dict with processor noting both models."""
    merged = dict(gpt_fields)

    # Vendor: prefer non-bad. If both valid and disagree, prefer Gemini.
    gpt_v = gpt_fields.get('vendor', '')
    gem_v = gemini_fields.get('vendor', '')
    gpt_bad = _is_bad_vendor(gpt_v)
    gem_bad = _is_bad_vendor(gem_v)
    if gpt_bad and not gem_bad:
        merged['vendor'] = gem_v
    elif not gpt_bad and gem_bad:
        merged['vendor'] = gpt_v
    elif not gpt_bad and not gem_bad and gpt_v != gem_v:
        merged['vendor'] = gem_v  # Gemini tends to be more accurate on blurry photos
        merged['description_short'] = f"GPT:{gpt_v} Gemini:{gem_v}"

    # Date: prefer valid year. If both valid, prefer the earlier year.
    gpt_d = gpt_fields.get('date_issued', '')
    gem_d = gemini_fields.get('date_issued', '')
    gpt_d_valid = _valid_year(gpt_d)
    gem_d_valid = _valid_year(gem_d)
    if not gpt_d_valid and gem_d_valid:
        merged['date_issued'] = gem_d
    elif gpt_d_valid and not gem_d_valid:
        merged['date_issued'] = gpt_d
    elif gpt_d_valid and gem_d_valid and gpt_d != gem_d:
        merged['date_issued'] = gem_d  # prefer Gemini on date disagreement

    # Total: prefer non-empty. If both, check proximity.
    gpt_t = gpt_fields.get('total', '')
    gem_t = gemini_fields.get('total', '')
    try:
        gpt_f = float(gpt_t) if gpt_t else None
    except (ValueError, TypeError):
        gpt_f = None
    try:
        gem_f = float(gem_t) if gem_t else None
    except (ValueError, TypeError):
        gem_f = None

    if gpt_f is None and gem_f is not None:
        merged['total'] = gem_t
    elif gpt_f is not None and gem_f is not None and abs(gpt_f - gem_f) > 2.0:
        merged['total'] = gpt_t
        existing_desc = merged.get('description_short', '') or ''
        dispute = f"total dispute: GPT=${gpt_t} Gemini=${gem_t}"
        merged['description_short'] = f"{existing_desc}; {dispute}" if existing_desc else dispute

    # Currency: prefer non-empty
    gpt_c = gpt_fields.get('currency', '')
    gem_c = gemini_fields.get('currency', '')
    if not gpt_c and gem_c:
        merged['currency'] = gem_c

    # Processor label
    merged['processor'] = 'vision-gpt4o-mini+gemini-2.5-flash'

    return merged


def extract_with_vision(pdf_input):
    """Extract data from an image-based PDF using both GPT-4o-mini and Gemini 2.5 Flash
    in parallel, then merge results. Returns (processor_label, merged_fields) or (None, error).
    pdf_input can be a file path (str) or PDF bytes (bytes)."""
    api_key = OPENROUTER_KEY
    if not api_key:
        return None, "No OPENROUTER_ORCH_KEY / OPENROUTER_API_KEY"

    # Call both models in parallel
    with ThreadPoolExecutor(max_workers=2) as executor:
        gpt_future = executor.submit(_call_vision_model, pdf_input, GPT_MODEL, api_key)
        gem_future = executor.submit(_call_vision_model, pdf_input, GEMINI_MODEL, api_key)
        gpt_result = gpt_future.result()
        gem_result = gem_future.result()

    gpt_ok = gpt_result[0] is not None
    gem_ok = gem_result[0] is not None

    if not gpt_ok and not gem_ok:
        return None, f"Both models failed: GPT={gpt_result[1]}, Gemini={gem_result[1]}"

    if gpt_ok and not gem_ok:
        _, gpt_fields = gpt_result
        gpt_fields['processor'] = 'vision-gpt4o-mini-only'
        return 'vision', gpt_fields

    if not gpt_ok and gem_ok:
        _, gemini_fields = gem_result
        gemini_fields['processor'] = 'vision-gemini-2.5-flash-only'
        return 'vision', gemini_fields

    # Both succeeded — merge
    _, gpt_fields = gpt_result
    _, gemini_fields = gem_result
    merged = merge_vision_results(gpt_fields, gemini_fields)
    return 'vision', merged


# ---- Main ----

def img_to_pdf(img_path, pdf_path):
    """Convert an image file to a single-page PDF using Pillow."""
    try:
        img = Image.open(img_path)
        img.convert('RGB').save(pdf_path, 'PDF')
    except Exception as e:
        raise RuntimeError(f"Failed to convert {img_path} to PDF: {e}") from e


def img_to_pdf_bytes(img_path):
    """Convert an image file to PDF bytes (in-memory)."""
    img = Image.open(img_path)
    buf = io.BytesIO()
    img.convert('RGB').save(buf, 'PDF')
    return buf.getvalue()


def process_one(file_path, rename_pdf=True, dest_dir=None, use_vision=False):
    """Process a single PDF or image: extract, detect, write .md, .csv, and rename.
    For images (.jpg/.jpeg/.png), converts to PDF in-memory and auto-forces vision."""
    source_basename = os.path.basename(file_path)
    ext = os.path.splitext(file_path)[1].lower()
    is_image = ext in ('.jpg', '.jpeg', '.png')
    print(f'\n{source_basename}')

    _tmpdir = tempfile.TemporaryDirectory(prefix='invsidecar_')
    try:
        if is_image:
            pdf_bytes = img_to_pdf_bytes(file_path)
            use_vision = True
            pages = []
            vision_input = pdf_bytes
        else:
            pdf_path = file_path
            pages = extract_all_text(pdf_path)
            vision_input = pdf_path

        if not pages or not any(t.strip() for _, t in pages):
            if use_vision:
                print(f'  (image-based, trying dual-model vision GPT-4o-mini + Gemini 2.5 Flash)...', end=' ', flush=True)
                proc_name, fields = extract_with_vision(vision_input)
                if fields and isinstance(fields, dict):
                    base = build_base_name(fields, source_basename)
                    out_dir = dest_dir or os.path.dirname(file_path)
                    out_base = os.path.join(out_dir, base)
                    write_md(out_base, pages or [(1, '(image-based — see csv for extracted data)')], source_basename)
                    write_csv(out_base, fields, source_basename)
                    if rename_pdf:
                        new_path = out_base + ext
                        src = file_path
                        if os.path.abspath(src) != os.path.abspath(new_path):
                            shutil.move(src, new_path)
                            print(f'  SRC -> {os.path.basename(new_path)}')
                    print(f'  DET {proc_name} | {fields.get("vendor", "?")} | ${fields.get("total", "?")}')
                    return True
                # Fallback: extract date from PXL_YYYYMMDD filename pattern
                fallback_fields = {
                    'invoice_number': '', 'vendor': '', 'date_issued': '',
                    'date_due': '', 'date_paid': '', 'subtotal': '', 'tax': '',
                    'total': '', 'currency': 'CAD', 'status': '',
                    'tax_deduction_category': '', 'items': '',
                    'description_short': '', 'processor': 'filename-fallback',
                }
                m = re.search(r'PXL_(\d{4})(\d{2})(\d{2})', source_basename)
                if m:
                    fallback_fields['date_issued'] = f'{m.group(1)}-{m.group(2)}-{m.group(3)}'
                elif not fallback_fields['date_issued']:
                    fallback_fields['date_issued'] = parse_date_from_filename(source_basename)
                base = build_base_name(fallback_fields, source_basename)
                out_dir = dest_dir or os.path.dirname(file_path)
                out_base = os.path.join(out_dir, base)
                write_md(out_base, pages or [(1, '(image-based — see csv for extracted data)')], source_basename)
                write_csv(out_base, fallback_fields, source_basename)
                if rename_pdf:
                    new_path = out_base + ext
                    src = file_path
                    if os.path.abspath(src) != os.path.abspath(new_path):
                        shutil.move(src, new_path)
                        print(f'  SRC -> {os.path.basename(new_path)}')
                print(f'  FALLBACK (vision failed) | {fallback_fields.get("date_issued", "?")}')
                return True
            else:
                print(f'  SKIP No extractable text (try --vision for image-based PDFs)')
            return False

        proc_name, fields = detect_and_extract(pdf_path, pages)
        if not fields:
            out_dir = dest_dir or os.path.dirname(file_path)
            md_base = os.path.splitext(file_path)[0]
            write_md(md_base, pages, source_basename)
            print(f'  --- No invoice format detected — .md written for manual review')
            return True

        base = build_base_name(fields, source_basename)
        out_dir = dest_dir or os.path.dirname(file_path)
        out_base = os.path.join(out_dir, base)

        write_md(out_base, pages, source_basename)
        write_csv(out_base, fields, source_basename)

        if rename_pdf:
            new_path = out_base + ext
            src = file_path
            if os.path.abspath(src) != os.path.abspath(new_path):
                shutil.move(src, new_path)
                print(f'  SRC -> {os.path.basename(new_path)}')
            else:
                print(f'  SRC  (already named correctly)')

        print(f'  DET {proc_name} | {fields.get("vendor", "?")} | ${fields.get("total", "?")} | {fields.get("invoice_number", "?")}')
        return True
    finally:
        _tmpdir.cleanup()


def main():
    import argparse

    parser = argparse.ArgumentParser(
        description='Convert invoice PDFs and images to .md + .csv sidecars'
    )
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument('files', nargs='*', help='Invoice PDF/image file(s) to process')
    group.add_argument('--dir', help='Directory containing invoice PDFs or images')
    parser.add_argument('--recurse', action='store_true', help='Scan directory recursively')
    parser.add_argument('--no-rename', action='store_true',
                        help='Write .md and .csv alongside the file without renaming it')
    parser.add_argument('--dest', help='Output directory (default: same as file)')
    parser.add_argument('--vision', action='store_true',
                        help='Use dual-model vision (GPT-4o-mini + Gemini 2.5 Flash) for image-based files (auto-enabled for JPG/PNG)')
    parser.add_argument('--images', action='store_true',
                        help='Process image files (.jpg, .jpeg, .png) converting to PDF in-memory (auto-enabled for image extensions)')

    args = parser.parse_args()

    IMAGE_EXTS = {'.pdf', '.jpg', '.jpeg', '.png'}
    VISION_EXTS = {'.jpg', '.jpeg', '.png'}

    if args.dir:
        file_dir = os.path.abspath(args.dir)
        if not os.path.isdir(file_dir):
            print(f'ERROR: Directory not found: {file_dir}', file=sys.stderr)
            sys.exit(1)
        files = []
        for root_dir, dirs, listed_files in os.walk(file_dir):
            for f in sorted(listed_files):
                ext = os.path.splitext(f)[1].lower()
                if ext in IMAGE_EXTS:
                    files.append(os.path.join(root_dir, f))
            if not args.recurse:
                break
        files.sort()
    else:
        files = []
        for f in args.files:
            ext = os.path.splitext(f)[1].lower()
            if ext in IMAGE_EXTS:
                files.append(os.path.abspath(f))

    if not files:
        print('No supported files found (accepts .pdf, .jpg, .jpeg, .png).')
        return

    dest_dir = os.path.abspath(args.dest) if args.dest else None
    if dest_dir and not os.path.isdir(dest_dir):
        os.makedirs(dest_dir, exist_ok=True)

    print(f'Found {len(files)} file(s)')
    has_vision_files = any(os.path.splitext(f)[1].lower() in VISION_EXTS for f in files)
    need_vision = args.vision or has_vision_files
    if need_vision and not OPENROUTER_KEY:
        print('WARNING: --vision requires OPENROUTER_ORCH_KEY or OPENROUTER_API_KEY env var. Vision disabled for image-based files.')
        need_vision = False

    count = 0
    for file_path in files:
        ext = os.path.splitext(file_path)[1].lower()
        use_vision_for_file = need_vision or (ext in VISION_EXTS)
        if process_one(file_path, rename_pdf=not args.no_rename, dest_dir=dest_dir, use_vision=use_vision_for_file):
            count += 1

    print(f'\nDone: {count} / {len(files)} processed')


if __name__ == '__main__':
    main()
