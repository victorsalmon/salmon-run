#!/usr/bin/env python3
"""hash-csv.py — Anonymize bank CSV by hashing descriptions with per-session salt.

Replaces transaction descriptions with full SHA-256 hex digests salted with
a per-session random salt. Each row gets a UUID v4. Recurring detection in
income-forecast.py still works (same merchant → same hash) but no human-readable
merchant names appear in the anonymized output.

Output:
  - Anonymized CSV:  row_id, date, description, amount, category, type
  - Lookup JSON:     {salt, rows: {uuid: {original_description, ...}}}
  The lookup JSON stays on the USB drive — never given to the agent.

Usage:
  python hash-csv.py --csv raw1.csv,raw2.csv --output anonymized.csv
  python hash-csv.py --csv raw.csv --salt <hex>   # deterministic re-hash
"""

import csv
import sys
import argparse
import json
import hashlib
import secrets
import uuid as uuid_mod
from datetime import datetime, date
from pathlib import Path

# ── Helpers (standalone — same detection logic as income-forecast.py)

AMOUNT_FIELDS = {'amount', 'value', 'total', 'sum'}
DATE_FIELDS = {'date', 'txn_date', 'transaction_date', 'posting_date', 'posted_date'}
DESC_FIELDS = {'description', 'desc', 'payee', 'name', 'memo', 'notes', 'vendor'}
CAT_FIELDS = {'category', 'cat', 'account', 'type_label'}
TYPE_FIELDS = {'type', 'txn_type', 'transaction_type', 'debit_or_credit', 'sign'}


def find_column(headers, candidates):
    hl = [h.strip().lower() for h in headers]
    for i, h in enumerate(hl):
        for c in candidates:
            if h == c or h.startswith(c):
                return i
    return None


def parse_date(value):
    value = value.strip()
    fmts = [
        '%Y-%m-%d', '%Y/%m/%d',
        '%m/%d/%Y', '%m/%d/%y',
        '%d/%m/%Y', '%d/%m/%y',
        '%b %d %Y', '%b %d, %Y',
        '%B %d %Y', '%B %d, %Y',
        '%d-%b-%Y', '%d-%b-%y',
    ]
    for fmt in fmts:
        try:
            return datetime.strptime(value, fmt).date()
        except ValueError:
            continue
    return None


def parse_amount(value):
    if isinstance(value, (int, float)):
        return float(value)
    v = value.strip().replace('$', '').replace(',', '').strip()
    if v.startswith('(') and v.endswith(')'):
        return -float(v[1:-1])
    if v.startswith('-'):
        return -float(v[1:])
    try:
        return float(v)
    except ValueError:
        return 0.0


def infer_type_from_debit_credit(row, debit_col, credit_col):
    debit = parse_amount(row[debit_col]) if debit_col is not None else 0
    credit = parse_amount(row[credit_col]) if credit_col is not None else 0
    if credit and credit > 0:
        return 'income', credit
    if debit and debit > 0:
        return 'expense', -debit
    return 'expense', 0.0


def infer_category(description):
    d = description.lower()
    rules = [
        ('rent', 'Rent', 'expense'),
        ('lease', 'Lease', 'expense'),
        ('internet', 'Internet', 'expense'),
        ('hydro', 'Utilities', 'expense'),
        ('electric', 'Utilities', 'expense'),
        ('water', 'Utilities', 'expense'),
        ('gas', 'Utilities', 'expense'),
        ('phone', 'Telephone', 'expense'),
        ('software', 'Software & IT', 'expense'),
        ('subscription', 'Software & IT', 'expense'),
        ('hosting', 'Software & IT', 'expense'),
        ('domain', 'Software & IT', 'expense'),
        ('aws', 'Software & IT', 'expense'),
        ('azure', 'Software & IT', 'expense'),
        ('google cloud', 'Software & IT', 'expense'),
        ('insurance', 'Insurance', 'expense'),
        ('accounting', 'Professional Fees', 'expense'),
        ('legal', 'Professional Fees', 'expense'),
        ('lawyer', 'Professional Fees', 'expense'),
        ('consult', 'Professional Fees', 'expense'),
        ('contractor', 'Contractor', 'expense'),
        ('advertis', 'Advertising', 'expense'),
        ('marketing', 'Advertising', 'expense'),
        ('travel', 'Travel', 'expense'),
        ('hotel', 'Travel', 'expense'),
        ('flight', 'Travel', 'expense'),
        ('mileage', 'Automobile', 'expense'),
        ('fuel', 'Automobile', 'expense'),
        ('gas station', 'Automobile', 'expense'),
        ('parking', 'Automobile', 'expense'),
        ('restaurant', 'Meals & Entertainment', 'expense'),
        ('lunch', 'Meals & Entertainment', 'expense'),
        ('dinner', 'Meals & Entertainment', 'expense'),
        ('coffee', 'Meals & Entertainment', 'expense'),
        ('office', 'Office Supplies', 'expense'),
        ('supplies', 'Office Supplies', 'expense'),
        ('postage', 'Office Supplies', 'expense'),
        ('shipping', 'Office Supplies', 'expense'),
        ('bank fee', 'Bank Fees', 'expense'),
        ('interest', 'Bank Fees', 'expense'),
        ('service charge', 'Bank Fees', 'expense'),
        ('payment', 'Credit Card Payment', 'expense'),
        ('transfer', 'Transfer', 'expense'),
        ('salary', 'Payroll', 'expense'),
        ('payroll', 'Payroll', 'expense'),
        ('tax', 'Income Tax', 'expense'),
        ('consulting', 'Consulting Revenue', 'income'),
        ('retainer', 'Consulting Revenue', 'income'),
        ('freelance', 'Consulting Revenue', 'income'),
        ('rental', 'Rental Income', 'income'),
        ('room', 'Rental Income', 'income'),
        ('deposit', 'Rental Income', 'income'),
        ('dividend', 'Dividend Income', 'income'),
        ('interest', 'Interest Income', 'income'),
        ('refund', 'Refund', 'income'),
        ('hst', 'HST Collected', 'income'),
        ('gst', 'HST Collected', 'income'),
        ('tax refund', 'Tax Refund', 'income'),
    ]
    for keyword, category, txn_type in rules:
        if keyword in d:
            return category, txn_type
    return 'Uncategorized', None


# ── Hashing

def hash_description(salt, description):
    return hashlib.sha256((salt + description).encode('utf-8')).hexdigest()


# ── Internal entry point (callable from tests)

def main_inner(csv_files, output_path, salt=None, _quiet=False):
    """Core logic: hash descriptions and write anonymized CSV + lookup.

    Args:
        csv_files: List of raw CSV file paths.
        output_path: Path for output anonymized CSV.
        salt: Salt string (generated if None).
        _quiet: Suppress stderr output.

    Returns:
        (output_path, lookup_path, salt)
    """
    salt = salt if salt else secrets.token_hex(16)
    output_path = Path(output_path)
    lookup_path = output_path.with_name(output_path.stem + '-lookup.json')

    rows_out = []
    lookup_rows = {}
    total_loaded = 0

    for fp in csv_files:
        path = Path(fp)
        if not path.exists():
            if not _quiet:
                print(f"WARNING: File not found: {fp}", file=sys.stderr)
            continue

        with open(path, 'r', encoding='utf-8-sig') as f:
            reader = csv.reader(f)
            headers = [h.strip().lower() for h in next(reader)]

        date_col = find_column(headers, DATE_FIELDS)
        amount_col = find_column(headers, AMOUNT_FIELDS)
        desc_col = find_column(headers, DESC_FIELDS)
        cat_col = find_column(headers, CAT_FIELDS)
        type_col = find_column(headers, TYPE_FIELDS)

        debit_col = None
        credit_col = None
        for i, h in enumerate(headers):
            if h in ('debit', 'withdrawal', 'debit_amount'):
                debit_col = i
            if h in ('credit', 'deposit', 'credit_amount'):
                credit_col = i

        if date_col is None:
            if not _quiet:
                print(f"ERROR: Cannot find date column in {fp}. Headers: {headers}",
                      file=sys.stderr)
            continue

        with open(path, 'r', encoding='utf-8-sig') as f:
            reader = csv.DictReader(f)
            for row in reader:
                txn_date = parse_date(row[headers[date_col]])
                if txn_date is None:
                    continue

                if amount_col is not None:
                    amount = parse_amount(row[headers[amount_col]])
                    txn_type = None
                elif debit_col is not None or credit_col is not None:
                    txn_type, amount = infer_type_from_debit_credit(
                        [row.get(h, '') for h in headers],
                        debit_col, credit_col,
                    )
                else:
                    continue

                if desc_col is not None:
                    desc = row[headers[desc_col]]
                else:
                    desc = ''

                category = 'Uncategorized'
                if cat_col is not None and row[headers[cat_col]]:
                    category = row[headers[cat_col]]
                else:
                    cat_result = infer_category(desc)
                    if cat_result:
                        category, _ = cat_result

                if txn_type is None and type_col is not None:
                    raw = row[headers[type_col]].lower().strip()
                    if raw in ('income', 'credit', 'deposit', 'inflow', 'cr'):
                        txn_type = 'income'
                    elif raw in ('expense', 'debit', 'withdrawal', 'outflow', 'dr'):
                        txn_type = 'expense'
                if txn_type is None:
                    txn_type = 'income' if amount > 0 else 'expense'

                if amount == 0:
                    continue

                row_id = str(uuid_mod.uuid4())
                desc_hash = hash_description(salt, desc)

                rows_out.append({
                    'row_id': row_id,
                    'date': txn_date.isoformat(),
                    'description': desc_hash,
                    'amount': f'{amount:.2f}',
                    'category': category,
                    'type': txn_type,
                })

                lookup_rows[row_id] = {
                    'original_description': desc,
                    'original_date': txn_date.isoformat(),
                    'original_amount': amount,
                    'original_category': category,
                    'original_type': txn_type,
                }

                total_loaded += 1

    if not rows_out:
        print("ERROR: No transactions loaded.", file=sys.stderr)
        raise SystemExit(1)

    fieldnames = ['row_id', 'date', 'description', 'amount', 'category', 'type']
    with open(output_path, 'w', newline='', encoding='utf-8') as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows_out)

    lookup = {
        'salt': salt,
        'rows': lookup_rows,
    }
    with open(lookup_path, 'w', encoding='utf-8') as f:
        json.dump(lookup, f, indent=2, ensure_ascii=False)

    if not _quiet:
        print(f"Loaded {total_loaded} transactions from {len(csv_files)} file(s)", file=sys.stderr)
        print(f"Wrote {len(rows_out)} rows → {output_path}", file=sys.stderr)
        print(f"Wrote lookup   → {lookup_path}", file=sys.stderr)
        print(f"Salt: {salt}  (keep this with your lookup to re-hash consistently)", file=sys.stderr)

    return str(output_path), str(lookup_path), salt


def main():
    parser = argparse.ArgumentParser(
        description='Anonymize bank CSV by hashing descriptions with per-session salt')
    parser.add_argument('--csv', required=True,
                        help='Comma-separated list of raw CSV file paths')
    parser.add_argument('--output', '-o', default=None,
                        help='Output anonymized CSV path (default: <first-input-stem>-anonymized.csv)')
    parser.add_argument('--salt', default=None,
                        help='Salt for hashing (default: random 16-byte hex). '
                             'Reuse to produce identical hashes across runs.')
    args = parser.parse_args()

    csv_files = [f.strip() for f in args.csv.split(',')]
    salt = args.salt

    if args.output:
        output_path = args.output
    else:
        first = Path(csv_files[0])
        output_path = str(first.with_name(first.stem + '-anonymized.csv'))

    main_inner(csv_files, output_path, salt)


if __name__ == '__main__':
    main()
