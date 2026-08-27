#!/usr/bin/env python3
"""Scotia vendor-matching pass — propose categorizations for 83 uncategorized txns.

Reads:  Skills/Bookkeeping/tx-categorization/categorization-rules.json
        room-rentals/rent-register.csv
        room-rentals/room-rentals-status.json  (for exempt categories)
        room-rentals/2026 Bank Statements/.../2026.06.11-Present - SCOTIA-TMH ... - Zoho.csv

Outputs: room-rentals/scotia-categorization-proposal.csv

Rules:
- Apply vendor_keyword_rules (room-rentals entity) for keyword-based classification
- Apply description_overrides (e.g. WAVE PRO)
- For DEPOSIT E-Transfer: cross-reference rent-register.csv; match amount → Rent Revenue
- For WITHDRAWAL E-Transfer: flag as Shareholder Loan (likely owner)
- Apply exempt-category flags from status.json (mortgage, strata, intersite, etc.)
- Flag BC Hydro as new "Utilities" — no rule exists yet, suggest new account
- Amazon: flag for receipt match (cross-ref unmatched-receipts.csv)
"""
import csv
import json
import os
import re
from collections import defaultdict
from pathlib import Path

# Paths
ROOT = os.path.expanduser(r'~\intersite-docs\Taxes and Bookkeeping\room-rentals')
RULES_PATH = Path(__file__).resolve().parents[2] / 'tx-categorization' / 'categorization-rules.json'
STATUS_PATH = os.path.join(ROOT, 'room-rentals-status.json')
RENT_REGISTER = os.path.join(ROOT, 'rent-register.csv')
SCOTIA_CSV = os.path.join(
    ROOT,
    r'2026 Bank Statements\SCOTIA-TMH 406000697486\2026.06.11-Present - SCOTIA-TMH 406000697486 - Zoho.csv'
)
OUTPUT_PATH = os.path.join(ROOT, 'scotia-categorization-proposal.csv')

ENTITY = 'room-rentals'

# Exempt categories from room-rentals-status.json (treat as no-category, exempt from categorization)
EXEMPT = {
    'Strata Fees', 'Property Tax', 'Insurance', 'Bank Fees and Charges',
    'Credit Card Charges', 'Shareholder Loan', 'Owner Funding', 'Transfer Out',
    'Bank Fee', 'Credit Card Payment', 'Credit Card Payments', 'Automobile Expense',
    'Rent', 'Damage Deposit', 'Loan Payment', 'Mortgage', 'Intersite',
    'Intersite RBC Business Cash Back Mastercard',
}

# Map known exempt descriptions to category
# Exempt items — return N/A account_id; user knows these are exempt from categorization
EXEMPT_DESCRIPTION_MAP = [
    (r'MORTGAGE PAYMENT', 'Mortgage'),
    (r'STRATA FEES', 'Strata Fees'),
    (r'PROPERTY TAX', 'Property Tax'),
    (r'PROPERTY TAXES', 'Property Tax'),
    (r'INTERSITE', 'Intersite'),
    (r'MONTHLY FEES|MONTHLY FEE', 'Bank Fees and Charges'),
    (r'SERVICE CHARGE', 'Bank Fees and Charges'),
]

# Acct IDs for room-rentals entity
ACCT = {
    'Software & IT Expenses': '151803000000000427',
    'Automobile Expense': '151803000000000424',
    'Office & General Expenses': '151803000000000400',
    'Repairs and Maintenance': '151803000000000457',
    'Professional Fees': '151803000000000454',
    'Advertising And Marketing': '151803000000000403',
    'Bank Fees and Charges': '151803000000000409',
    'Credit Card Charges': '151803000000000412',
    'Other Expenses': '151803000000000460',
    'Rent Revenue': '151803000000000430',
    'Damage Deposits Held': '151803000000197002',
    'Utilities': '151803000000245013',  # created in Zoho 2026-06-17 for BC Hydro
    'Shareholder Loan': '93310000000146154',  # cross-entity ID for SHL
    'Exclude': '151803000000000460',  # not in acct_names but used in rules
}


def load_rules():
    with open(RULES_PATH, 'r', encoding='utf-8') as f:
        return json.load(f)


def is_round(amount):
    return abs(amount - round(amount)) < 0.01


def load_rent_register():
    """Return set of (date_str, amount) for all rent register payments."""
    rows = []
    with open(RENT_REGISTER, 'r', encoding='utf-8-sig') as f:
        for r in csv.DictReader(f):
            try:
                amt = float(r['amount'])
                rows.append((r['payment_date'], amt, r.get('room_id', ''), r.get('paid_for_month', '')))
            except (ValueError, KeyError):
                continue
    return rows


def match_rent_register(deposit_date, amount, rent_rows, tolerance=0.02):
    """Match E-Transfer deposit against rent register (amount-based, date within 30 days)."""
    from datetime import datetime, timedelta
    try:
        d = datetime.strptime(deposit_date, '%Y-%m-%d')
    except ValueError:
        return None
    for rdate, ramt, room, paid_for in rent_rows:
        try:
            rd = datetime.strptime(rdate, '%Y-%m-%d')
        except ValueError:
            continue
        if abs(d - rd) > timedelta(days=120):  # widen window to cover 2025-12 paid for 2026-01
            continue
        if abs(ramt - amount) < tolerance:
            return (rdate, ramt, room, paid_for)
    return None


def load_status():
    with open(STATUS_PATH, 'r', encoding='utf-8') as f:
        return json.load(f)


def classify_by_rules(description, amount, debit_or_credit, rules, rent_rows):
    """Returns (account_name, account_id, classification_note, confidence, receipt_status)."""
    upper = description.upper()
    is_debit = (debit_or_credit == 'debit')
    is_credit = (debit_or_credit == 'credit')

    # 1. Exempt description check
    for pattern, exempt_name in EXEMPT_DESCRIPTION_MAP:
        if re.search(pattern, upper):
            if exempt_name in EXEMPT:
                # Return empty account_id for true exempt items; user knows they're exempt
                # For Bank Fees and Charges, return the actual account_id since it has one
                if exempt_name == 'Bank Fees and Charges':
                    return (exempt_name, ACCT['Bank Fees and Charges'], 'EXEMPT (per status.json)', 'high', 'N/A — exempt')
                return (exempt_name, '', 'EXEMPT (per status.json) — no account_id', 'high', 'N/A — exempt')

    # 2. Vendor keyword rules (filter by entity)
    for r in rules['vendor_keyword_rules']:
        if ENTITY not in r.get('entities', []):
            continue
        if re.search(r['pattern'], upper):
            return (r['account_name'], r['account_id'], r['note'], 'high', None)

    # 3. Description overrides
    for r in rules['description_overrides']:
        if ENTITY not in r.get('entities', []):
            continue
        if r['match'].upper() in upper:
            return (r['account_name'], r['account_id'], r['note'], 'high', None)

    # 4. E-Transfer handling
    if 'INTERAC E-TRANSFER' in upper:
        if 'DEPOSIT' in upper and is_debit:  # DEBIT in zoho schema = money IN
            # Try to match against rent register (date+amount proximity)
            txn_date = classify_by_rules.last_date
            m = match_rent_register_by_date_and_amount(txn_date, amount, rent_rows)
            if m:
                rdate, ramt, room, paid_for = m
                return ('Rent Revenue', ACCT['Rent Revenue'],
                        f'Rent register match: {room} for {paid_for} (paid {rdate})',
                        'high', 'N/A — rent register')
            return ('Shareholder Loan', ACCT['Shareholder Loan'],
                    'DEPOSIT E-Transfer, no rent register match — likely owner contribution',
                    'medium', 'N/A — transfer')
        if 'WITHDRAWAL' in upper and is_credit:  # CREDIT in zoho schema = money OUT
            # User-confirmed categorizations (2026-06-17):
            # - 4×$2000, $1000, $1835.29 → Shareholder Loan (owner distribution)
            # - $994 on 2026-05-11 → Damage Deposits Held (refund to Shawntell)
            zoho_id = classify_by_rules.last_zoho_id
            if zoho_id == '151803000000101170' and amount == 994.00:
                return ('Damage Deposits Held', ACCT['Damage Deposits Held'],
                        'Damage deposit refund to Shawntell (tmh-diamond) — balance sheet',
                        'high', 'N/A — DD refund')
            return ('Shareholder Loan', ACCT['Shareholder Loan'],
                    'WITHDRAWAL E-Transfer — owner distribution (user confirmed 2026-06-17)',
                    'high', 'N/A — transfer')

    # 5. BC Hydro — handled by vendor_keyword_rules now (Utilities account added 2026-06-17)
    # If not matched by rules above (e.g., rule wasn't loaded), fall through to vendor rules below.

    # 6. Amazon / AliExpress / unknown → needs receipt
    if 'AMAZON' in upper or 'AMZN' in upper or 'ALIEXPRESS' in upper:
        txn_date = classify_by_rules.last_date

        # Special case: in-and-out reversal (debit + credit same amount, similar date)
        # If a refund/correction is detected, mark as Exclude (in-and-out)
        if 'CORRECTION' in upper or ('REFUND' in upper and is_credit):
            return ('Exclude', ACCT['Exclude'],
                    'Amazon in-and-out reversal (debit + credit cancel) — exempt per rules',
                    'high', 'N/A — in-and-out reversal')

        # Try to match against unmatched-receipts.csv by amount+date
        receipt_match = match_amazon_receipt(txn_date, amount, description)
        if receipt_match:
            return ('Amazon: ' + receipt_match['vendor'], '',
                    f'Receipt match: {receipt_match["filename"]} (date {receipt_match["date"]})',
                    'medium', f'Receipt: {receipt_match["filename"][:60]}')

        # Try to match against all receipts (FANMAIKEJI special case)
        fan_match = match_fanmaikeji_receipt(txn_date, amount, description)
        if fan_match:
            return ('Repairs and Maintenance', ACCT['Repairs and Maintenance'],
                    f'FANMAIKEJI dishwasher rollers — Receipt: {fan_match["filename"]} (date {fan_match["date"]})',
                    'high', f'Receipt: {fan_match["filename"]}')

        return ('UNMATCHED', '', 'Amazon/AliExpress — needs receipt match', 'low', 'NEEDS_RECEIPT')

    # 7. Google *Sweepy
    if 'GOOGLE' in upper and 'SWEEPY' in upper:
        return ('Software & IT Expenses', ACCT['Software & IT Expenses'],
                'Google *Sweepy — likely smart home subscription',
                'low', None)

    # 8. Fallthrough
    return ('UNMATCHED', '', 'No rule matched — manual review needed', 'low', None)


# Date context (set by main before calling classify)
classify_by_rules.last_date = None
classify_by_rules.last_zoho_id = None


def match_rent_register_by_amt_only(amount, rent_rows, tolerance=0.05):
    """Match by amount only (date-agnostic) for E-Transfer deposits."""
    for rdate, ramt, room, paid_for in rent_rows:
        if abs(ramt - amount) < tolerance:
            return (rdate, ramt, room, paid_for)
    return None


def match_rent_register_by_date_and_amount(deposit_date, amount, rent_rows, tolerance=0.01):
    """Match E-Transfer deposit to rent register entry with closest date+exact amount."""
    from datetime import datetime, timedelta
    try:
        d = datetime.strptime(deposit_date, '%Y-%m-%d')
    except (ValueError, TypeError):
        return None
    # Find all amount matches first
    amt_matches = [(rdate, ramt, room, paid_for) for rdate, ramt, room, paid_for in rent_rows if abs(ramt - amount) < tolerance]
    if not amt_matches:
        return None
    # If only one, return it
    if len(amt_matches) == 1:
        return amt_matches[0]
    # Multiple — pick closest date
    def date_dist(m):
        try:
            rd = datetime.strptime(m[0], '%Y-%m-%d')
            return abs((rd - d).days)
        except ValueError:
            return 9999
    amt_matches.sort(key=date_dist)
    return amt_matches[0]


def load_unmatched_receipts():
    """Load unmatched-receipts.csv for Amazon receipt matching."""
    path = os.path.join(ROOT, 'room-rentals-unmatched-receipts.csv')
    rows = []
    try:
        with open(path, 'r', encoding='utf-8-sig') as f:
            for r in csv.DictReader(f):
                try:
                    amt = float(r.get('amount', '0') or '0')
                    date = r.get('date', '')
                    vendor = r.get('vendor', '')
                    filename = r.get('filename', '')
                    if amt > 0 and date and vendor:
                        rows.append({'date': date, 'amount': amt, 'vendor': vendor, 'filename': filename})
                except (ValueError, KeyError):
                    continue
    except FileNotFoundError:
        pass
    return rows


def load_all_receipts():
    """Load all receipts from 2026 Receipts/ (CSV sidecars) — broader match for non-Amazon vendors."""
    receipts_dir = os.path.join(ROOT, '2026 Receipts')
    rows = []
    if not os.path.exists(receipts_dir):
        return rows
    for f in os.listdir(receipts_dir):
        if f.endswith('.csv') and f != 'manifest.csv' and f != 'manifest-enriched.csv':
            full_path = os.path.join(receipts_dir, f)
            try:
                with open(full_path, 'r', encoding='utf-8-sig') as fh:
                    # Skip comment lines (start with #)
                    lines = [line for line in fh if not line.startswith('#')]
                reader = csv.DictReader(lines)
                for r in reader:
                    if r.get('total') and r.get('date_issued'):
                        try:
                            amt = float(r['total'])
                            date = r['date_issued']
                            vendor = r.get('vendor', '').strip()
                            fname = f.replace('.csv', '.pdf')
                            if amt > 0 and vendor:
                                rows.append({'date': date, 'amount': amt, 'vendor': vendor, 'filename': fname, 'description': r.get('description_short', '')})
                        except (ValueError, KeyError):
                            continue
            except (OSError, UnicodeDecodeError):
                continue
    return rows


def match_fanmaikeji_receipt(txn_date, amount, desc):
    """Match Amazon charge to FANMAIKEJI receipt (special case — chequing-paid Amazon purchase)."""
    from datetime import datetime, timedelta
    receipts = match_fanmaikeji_receipt.receipts
    upper = desc.upper()
    for r in receipts:
        # FANMAIKEJI or "Intersite Consulting" (the vendor field on the receipt CSV)
        if 'FANMAIKEJI' not in r['vendor'].upper() and 'INTERSITE' not in r['vendor'].upper():
            continue
        if abs(r['amount'] - amount) > 0.02:
            continue
        try:
            rd = datetime.strptime(r['date'], '%Y-%m-%d')
            td = datetime.strptime(txn_date, '%Y-%m-%d')
            # Amazon typically charges 1-3 days after order
            if abs((rd - td).days) > 7:
                continue
        except (ValueError, TypeError):
            continue
        return r
    return None

match_fanmaikeji_receipt.receipts = load_all_receipts()


def match_amazon_receipt(date_str, amount, desc, tolerance=0.02, days_window=14):
    """Try to match an Amazon transaction to a receipt by amount+date proximity."""
    from datetime import datetime, timedelta
    receipts = match_amazon_receipt.receipts
    upper = desc.upper()
    if 'CORRECTION' in upper or 'REFUND' in upper:
        # Refunds/corrections are tricky — flag but don't auto-match
        return None
    for r in receipts:
        # Vendor must be Amazon
        if 'amazon' not in r['vendor'].lower() and 'amzn' not in r['vendor'].lower():
            continue
        # Amount must match
        if abs(r['amount'] - amount) > tolerance:
            continue
        # Date must be within window
        try:
            rd = datetime.strptime(r['date'], '%Y-%m-%d')
            td = datetime.strptime(date_str, '%Y-%m-%d')
            if abs((rd - td).days) > days_window:
                continue
        except (ValueError, TypeError):
            continue
        return r
    return None

# Load receipts at module level so match_amazon_receipt can access them
match_amazon_receipt.receipts = load_unmatched_receipts()


def main():
    rules = load_rules()
    status = load_status()
    rent_rows = load_rent_register()
    print(f'Loaded {len(rent_rows)} rent register rows')

    with open(SCOTIA_CSV, 'r', encoding='utf-8') as f:
        # Skip comment lines (starting with #)
        lines = [line for line in f if not line.startswith('#')]
    reader = csv.DictReader(lines)
    rows = []
    for r in reader:
        if not r.get('date'):
            continue
        rows.append(r)

    print(f'Loaded {len(rows)} Scotia transactions')

    # Categorize each row
    output_rows = []
    for r in rows:
        date = r['date']
        classify_by_rules.last_date = date  # Make date available to classifier
        zoho_id = r.get('zoho_transaction_id', '')
        classify_by_rules.last_zoho_id = zoho_id
        payee = r.get('payee', '')
        desc = r.get('description', '')
        full_desc = f'{payee} {desc}'.strip()
        amount = float(r['amount'])
        debit_or_credit = r['debit_or_credit']

        acct_name, acct_id, note, confidence, receipt_status = classify_by_rules(
            full_desc, amount, debit_or_credit, rules, rent_rows
        )

        # Determine sign for display (debit = money in = +; credit = money out = -)
        signed_amount = amount if debit_or_credit == 'debit' else -amount
        direction = 'IN ' if debit_or_credit == 'debit' else 'OUT'

        output_rows.append({
            'date': date,
            'direction': direction,
            'amount': f'{abs(amount):.2f}',
            'payee': payee,
            'description': desc,
            'current_category': 'uncategorized',
            'suggested_account': acct_name,
            'suggested_account_id': acct_id,
            'confidence': confidence,
            'classification_note': note,
            'receipt_status': receipt_status or 'NEEDS_RECEIPT',
            'zoho_transaction_id': zoho_id,
        })

    # Write output
    fieldnames = [
        'date', 'direction', 'amount', 'payee', 'description',
        'current_category', 'suggested_account', 'suggested_account_id',
        'confidence', 'classification_note', 'receipt_status', 'zoho_transaction_id',
    ]
    with open(OUTPUT_PATH, 'w', newline='', encoding='utf-8-sig') as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        # Metadata header
        f.write(f'# Generated: 2026-06-17\n')
        f.write(f'# Generator: scotia-categorization-proposal.py\n')
        f.write(f'# Source: 2026.06.11-Present - SCOTIA-TMH 406000697486 - Zoho.csv (83 uncategorized txns)\n')
        f.write(f'# Entity: room-rentals\n')
        f.write(f'# Rules: Skills/Bookkeeping/tx-categorization/categorization-rules.json\n')
        writer.writeheader()
        writer.writerows(output_rows)

    print(f'\nWrote {len(output_rows)} proposed categorizations to: {OUTPUT_PATH}')

    # Summary by category
    by_cat = defaultdict(int)
    by_conf = defaultdict(int)
    for r in output_rows:
        by_cat[r['suggested_account']] += 1
        by_conf[r['confidence']] += 1

    print('\n=== Summary by Suggested Account ===')
    for cat, count in sorted(by_cat.items(), key=lambda x: -x[1]):
        print(f'  {cat:<40s} {count:3d}')
    print(f'  {"TOTAL":<40s} {len(output_rows):3d}')

    print('\n=== Summary by Confidence ===')
    for conf, count in sorted(by_conf.items()):
        print(f'  {conf:<15s} {count:3d}')

    # Flag: high-confidence items ready for batch upload
    high_conf = [r for r in output_rows if r['confidence'] == 'high']
    print(f'\n  Ready for batch upload (high-confidence): {len(high_conf)}')
    print(f'  Need review (low/medium):               {len(output_rows) - len(high_conf)}')

    # Show unmatched items
    unmatched = [r for r in output_rows if r['suggested_account'] == 'UNMATCHED']
    if unmatched:
        print(f'\n=== UNMATCHED items needing manual review ({len(unmatched)}) ===')
        for r in unmatched:
            print(f"  {r['date']} {r['direction']} {r['amount']:>8s}  {r['description'][:60]}")


if __name__ == '__main__':
    main()
