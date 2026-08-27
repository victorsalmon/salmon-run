#!/usr/bin/env python3
"""Extract statement period and closing/ending balance from bank statement PDFs.

Scans one or more directories for PDF bank statements, extracts the statement
period and ending balance from each using pdfplumber text extraction.

Output: JSON lines to stdout — one line per PDF with keys:
  file, account, statement_period, ending_balance, format

If text extraction returns empty (scanned PDF), emits "text_empty: true".
"""

import json
import os
import re
import sys
from pathlib import Path


PIPELINE_WARNINGS_FILE = '.pipeline-warnings.json'


def write_pipeline_warnings(base_dir, warnings):
    warnings_path = os.path.join(base_dir, PIPELINE_WARNINGS_FILE) if os.path.isdir(base_dir) else base_dir + '.pipeline-warnings.json'
    existing = []
    if os.path.exists(warnings_path):
        try:
            with open(warnings_path, 'r', encoding='utf-8') as f:
                existing = json.load(f)
        except (json.JSONDecodeError, IOError):
            pass
    existing = existing + warnings
    with open(warnings_path, 'w', encoding='utf-8') as f:
        json.dump(existing, f, indent=2)

try:
    import pdfplumber
except ImportError:
    print("ERROR: pdfplumber is required. Install: pip install pdfplumber", file=sys.stderr)
    sys.exit(1)


MONTHS_ABB = {
    'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4,
    'may': 5, 'jun': 6, 'jul': 7, 'aug': 8,
    'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12
}


def extract_text(pdf_path):
    with pdfplumber.open(pdf_path) as pdf:
        pages = []
        for page in pdf.pages:
            t = page.extract_text(keep_blank_chars=True, x_tolerance=3)
            pages.append(t or "")
    return pages


def detect_format(text):
    """Detect bank statement format from first-page text."""
    if 'Mastercard' in text or 'MASTERCARD' in text or 'MasterCard' in text or 'Cash Back Mastercard' in text:
        return 'mc'
    if 'Business Account Statement' in text or 'RBC personal banking' in text or 'RBC Royal Bank' in text:
        return 'rbc'
    if 'BBVA Bancomer' in text or 'ABBOTSFORD' in text:
        return 'abbotsford'
    if 'Scotiabank' in text or 'Scotia Bank' in text or 'SCOTIABANK' in text or 'scotiabank' in text:
        return 'scotia'
    if 'TD Canada Trust' in text or 'TDCT' in text:
        return 'abbotsford'
    return 'unknown'


def parse_ending_balance(text):
    """Find the closing/ending balance line in the text.

    Returns amount_str or None.
    """
    patterns = [
        # ABBOTSFORD/TD: "CLOSING BALANCE MAY29 4,496.21" or "CLOSINGBALANCE MAR31 5,090.89"
        re.compile(r'(?:Closing|closing|CLOSING)\s*(?:Balance|balance|BALANCE)\s+(?:\w+\s+)?[\$]?\s*([\d,]+\.\d{2})', re.MULTILINE),
        # "Closing Balance $1,702.25" (RBC)
        re.compile(r'(?:Closing|closing)\s*(?:Balance|balance)\s*[\$]?\s*([\d,]+\.\d{2})'),
        # "NEW BALANCE $81.28" (MC credit card)
        re.compile(r'(?:NEW|New|new)\s*(?:BALANCE|Balance|balance)\s*[\$]?\s*([\d,]+\.\d{2})'),
        # Scotia: "Closing Balance$2,875.72" (no space)
        re.compile(r'Closing\s*Balance\s*[\$]?\s*([\d,]+\.\d{2})'),
    ]
    for pat in patterns:
        m = pat.search(text)
        if m:
            return m.group(1).replace(',', '')
    return None


def parse_statement_period(text, fmt):
    """Extract the statement period from the text."""
    if fmt == 'abbotsford':
        m = re.search(r'([A-Za-z]+)\s+(\d+)\s*,\s*(\d{4})\s*[-to]+\s*([A-Za-z]+)\s+(\d+)\s*,\s*(\d{4})', text, re.IGNORECASE)
        if m:
            return f'{m.group(1)} {m.group(2)}, {m.group(3)} – {m.group(4)} {m.group(5)}, {m.group(6)}'
        # ABBOTSFORD packed format: "FEB27/26- MAR31/26" or "FEB27/26 - MAR31/26"
        m = re.search(r'([A-Z]{3})\s*(\d+)/(\d+)\s*[-to]+\s*([A-Z]{3})\s*(\d+)/(\d+)', text, re.IGNORECASE)
        if m:
            return f'{m.group(1).upper()} {m.group(2)}/{m.group(3)} – {m.group(4).upper()} {m.group(5)}/{m.group(6)}'
        # ABBOTSFORD dense: "APR30/26-MAY29/26" (no space at all)
        m = re.search(r'([A-Z]{3})(\d+)/(\d+)\s*[-]\s*([A-Z]{3})(\d+)/(\d+)', text, re.IGNORECASE)
        if m:
            return f'{m.group(1).upper()} {m.group(2)}/{m.group(3)} – {m.group(4).upper()} {m.group(5)}/{m.group(6)}'
    elif fmt == 'mc':
        m = re.search(
            r'STATEMENT\s+FROM\s+([A-Za-z]+)\s+(\d+)(?:,\s*\d{4})?\s*TO\s+([A-Za-z]+)\s+(\d+),\s*(\d{4})',
            text, re.IGNORECASE
        )
        if m:
            return f'{m.group(1).capitalize()} {m.group(2)} – {m.group(3).capitalize()} {m.group(4)}, {m.group(5)}'
        m = re.search(
            r'([A-Za-z]+)\s+(\d+),\s*\d{4}\s*[-to]+\s*([A-Za-z]+)\s+(\d+),\s*(\d{4})',
            text, re.IGNORECASE
        )
        if m:
            return f'{m.group(1)} {m.group(2)} – {m.group(3)} {m.group(4)}, {m.group(5)}'
    elif fmt == 'rbc':
        # Handle "FromDecember 19, 2025 to January 21, 2026" (no space after From)
        m = re.search(r'(?:From)?([A-Za-z]+)\s*(\d+),\s*(\d{4})\s*to\s*([A-Za-z]+)\s*(\d+),\s*(\d{4})', text, re.IGNORECASE)
        if m:
            return f'{m.group(1)} {m.group(2)}, {m.group(3)} – {m.group(4)} {m.group(5)}, {m.group(6)}'
    elif fmt == 'scotia':
        m = re.search(
            r'(?:Statement\s*period[:\s]*)?([A-Za-z]+)\s+(\d+),\s*(\d{4})\s*[-to]+\s*([A-Za-z]+)\s+(\d+),\s*(\d{4})',
            text, re.IGNORECASE
        )
        if m:
            return f'{m.group(1)} {m.group(2)}, {m.group(3)} – {m.group(4)} {m.group(5)}, {m.group(6)}'
        # Scotia: "OpeningBalanceonDecember21,2025 $6,893.70" (packed, no spaces)
        om = re.search(r'(?:Opening|opening)\s*(?:Balance|balance)\s*on\s*([A-Za-z]+)\s*(\d+),\s*(\d{4})', text, re.IGNORECASE)
        cm = re.search(r'(?:Closing|closing)\s*(?:Balance|balance)\s*on\s*([A-Za-z]+)\s*(\d+),\s*(\d{4})', text, re.IGNORECASE)
        if om and cm:
            return f'{om.group(1)} {om.group(2)}, {om.group(3)} – {cm.group(1)} {cm.group(2)}, {cm.group(3)}'
    else:
        # Generic fallback: find two dates
        m = re.search(
            r'([A-Za-z]+)\s+(\d+),\s*(\d{4})\s*[-–to]+\s*([A-Za-z]+)\s+(\d+),\s*(\d{4})',
            text, re.IGNORECASE
        )
        if m:
            return f'{m.group(1)} {m.group(2)}, {m.group(3)} – {m.group(4)} {m.group(5)}, {m.group(6)}'
    return None


def infer_account(pdf_name, parent_dir, fmt):
    """Try to infer the account name from the PDF filename or parent directory."""
    name_lower = pdf_name.lower()
    parent_lower = parent_dir.lower()
    if '5172549' in name_lower or '2549' in name_lower:
        return 'RBC-FRA (5172549)'
    if '6679' in name_lower or ('visa' in name_lower and 'rbc' in name_lower):
        return 'RBC-VISA (6679)'
    if '6467010' in name_lower or 'mlm' in name_lower or 'abbotsford' in name_lower:
        return 'TD-MLM (6467010)'
    if '406000697486' in name_lower or 'scotia' in name_lower or 'tmh' in name_lower or 'scotiabank' in name_lower:
        return 'SCOTIA-TMH (406000697486)'
    if '406000697486' in parent_lower or 'scotia' in parent_lower or 'tmh' in parent_lower:
        return 'SCOTIA-TMH (406000697486)'
    if '6632' in name_lower or ('rbc' in name_lower and 'intersite' in name_lower):
        return 'RBC-INTERSITE (6632)'
    if 'intersite' in name_lower or '6632' in name_lower:
        return 'RBC-INTERSITE (6632)'
    if '6258' in name_lower or '6241' in name_lower or 'mastercard' in name_lower:
        return 'MC 6258 (6241)'
    # Fall back to parent dir name
    return parent_dir


def process_pdf(pdf_path, parent_dir):
    result = {
        'file': pdf_path.name,
        'path': str(pdf_path),
        'account': None,
        'statement_period': None,
        'ending_balance': None,
        'format': 'unknown',
        'text_empty': False,
    }

    pages = extract_text(pdf_path)
    full_text = '\n'.join(pages)
    has_text = any(t.strip() for t in pages)

    warnings = []
    if not has_text:
        result['text_empty'] = True
        result['account'] = infer_account(pdf_path.name, parent_dir, 'unknown')
        warnings.append({'stage': 'extract-statement-periods', 'file': str(pdf_path), 'severity': 'error', 'message': f'No text extracted from PDF — scanned image or empty file: {pdf_path.name}'})
        write_pipeline_warnings(parent_dir, warnings)
        return result

    fmt = detect_format(full_text)
    result['format'] = fmt
    result['account'] = infer_account(pdf_path.name, parent_dir, fmt)

    if fmt == 'unknown':
        result['statement_period'] = None
        result['ending_balance'] = None
        result['warning'] = 'Unknown bank format — no known text patterns matched. Balance and period set to null.'
        warnings.append({'stage': 'extract-statement-periods', 'file': str(pdf_path), 'severity': 'warning', 'message': f'Unknown bank format: {pdf_path.name}'})
        write_pipeline_warnings(parent_dir, warnings)
    else:
        misc_warnings = []
        period = parse_statement_period(full_text, fmt)
        if period:
            result['statement_period'] = period
        else:
            misc_warnings.append({'stage': 'extract-statement-periods', 'file': str(pdf_path), 'severity': 'warning', 'message': f'Could not extract statement period: {pdf_path.name}'})

        balance = parse_ending_balance(full_text)
        if balance:
            result['ending_balance'] = balance
        else:
            misc_warnings.append({'stage': 'extract-statement-periods', 'file': str(pdf_path), 'severity': 'warning', 'message': f'Could not extract ending balance: {pdf_path.name}'})

        if misc_warnings:
            write_pipeline_warnings(parent_dir, misc_warnings)

    return result


def main():
    import argparse

    parser = argparse.ArgumentParser(
        description='Extract statement period + ending balance from bank statement PDFs'
    )
    parser.add_argument('directories', nargs='+', metavar='DIR',
                        help='Directory(ies) containing PDF bank statements')
    args = parser.parse_args()

    pdfs = []
    for d in args.directories:
        base = Path(d)
        if not base.exists():
            print(f'WARNING: Directory not found: {d}', file=sys.stderr)
            continue
        for f in sorted(base.iterdir()):
            if f.suffix.lower() == '.pdf':
                parent_dir = base.name
                pdfs.append((f, parent_dir))

    print(f'Found {len(pdfs)} PDF(s)', file=sys.stderr)

    results = []
    for pdf_path, parent_dir in pdfs:
        r = process_pdf(pdf_path, parent_dir)
        results.append(r)
        if r['text_empty']:
            print(f'EMPTY {pdf_path.name}', file=sys.stderr)
        else:
            bal = r['ending_balance'] or 'NOT FOUND'
            period = r['statement_period'] or 'NOT FOUND'
            print(f'OK  {r["format"]:10s} {pdf_path.name} — {period} = ${bal}', file=sys.stderr)

    # Output JSONL
    for r in results:
        print(json.dumps(r))

    # Summary
    ok = sum(1 for r in results if not r['text_empty'] and r['ending_balance'])
    empty = sum(1 for r in results if r['text_empty'])
    no_balance = sum(1 for r in results if not r['text_empty'] and not r['ending_balance'])
    print(f'\nDone: {ok} extracted, {empty} empty (vision needed), {no_balance} missing balance', file=sys.stderr)


if __name__ == '__main__':
    main()
