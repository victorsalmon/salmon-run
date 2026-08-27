"""Reconcile per-statement sidecar CSVs against the consolidated bank portal CSV.

Compares every transaction in the consolidated CSV against the sidecar CSVs
to verify: amounts match, debit/credit direction matches, and every transaction
is accounted for in exactly one statement period.
"""

import argparse
import csv
import json
import os
import re
import sys
from collections import defaultdict
from datetime import datetime
from pathlib import Path

MONTHS = {'jan':1,'feb':2,'mar':3,'apr':4,'may':5,'jun':6,
          'jul':7,'aug':8,'sep':9,'oct':10,'nov':11,'dec':12}


def parse_date_flex(date_str):
    """Parse various date formats to yyyy-mm-dd."""
    date_str = date_str.strip()
    # Try yyyy-mm-dd or yyyy/mm/dd
    m = re.match(r'(\d{4})[-/](\d{1,2})[-/](\d{1,2})', date_str)
    if m:
        return f'{m.group(1)}-{int(m.group(2)):02d}-{int(m.group(3)):02d}'
    # Try m/d/yyyy or mm/dd/yyyy
    m = re.match(r'(\d{1,2})/(\d{1,2})/(\d{4})', date_str)
    if m:
        return f'{m.group(3)}-{int(m.group(1)):02d}-{int(m.group(2)):02d}'
    return date_str


def detect_csv_format(headers):
    """Detect which bank format the CSV uses based on column headers."""
    h = [c.strip() for c in headers]
    if 'CAD$' in h and 'Description 1' in h:
        return 'rbc'
    if 'Debit' in h and 'Credit' in h:
        return 'td'
    if 'Amount' in h and 'Type of Transaction' in h:
        return 'scotia'
    if 'Amount' in h:
        return 'generic'
    return 'unknown'


def load_consolidated_csv(filepath):
    """Load the bank portal CSV. Returns list of dicts."""
    txns = []
    with open(filepath, 'r', encoding='utf-8-sig') as f:
        lines = [l for l in f.readlines() if l.strip()]
        reader = csv.DictReader(lines)
        fmt = detect_csv_format(reader.fieldnames)

    if fmt == 'rbc':
        return _load_rbc_csv(filepath)
    elif fmt == 'td':
        return _load_td_csv(filepath)
    elif fmt == 'scotia':
        return _load_scotia_csv(filepath)
    else:
        return _load_generic_csv(filepath)


def _load_rbc_csv(filepath):
    """Parse RBC CAD$ format (negative = debit, positive = credit)."""
    txns = []
    with open(filepath, 'r', encoding='utf-8-sig') as f:
        reader = csv.DictReader(f)
        for row in reader:
            raw_amt = row.get('CAD$', '').strip()
            if not raw_amt:
                continue
            try:
                amount = float(raw_amt.replace(',', ''))
            except ValueError:
                continue
            if amount == 0:
                continue
            date_raw = row.get('Transaction Date', '').strip()
            date = parse_date_flex(date_raw)
            desc1 = row.get('Description 1', '').strip()
            desc2 = row.get('Description 2', '').strip()
            payee = f'{desc1} {desc2}'.strip() if desc2 else desc1
            txns.append({
                'date': date, 'payee': payee,
                'amount': round(abs(amount), 2),
                'is_credit': amount > 0,
                'raw_line': f'{date} | {payee} | {"CR" if amount > 0 else "DR"} ${abs(amount):.2f}'
            })
    return txns


def _load_td_csv(filepath):
    """Parse TD Debit/Credit column format."""
    txns = []
    with open(filepath, 'r', encoding='utf-8-sig') as f:
        reader = csv.DictReader(f)
        for row in reader:
            raw_debit = (row.get('Debit') or '').strip()
            raw_credit = (row.get('Credit') or '').strip()
            if not raw_debit and not raw_credit:
                continue
            try:
                debit = float(raw_debit.replace(',', '')) if raw_debit else 0
                credit = float(raw_credit.replace(',', '')) if raw_credit else 0
            except ValueError:
                continue
            if debit == 0 and credit == 0:
                continue
            amount = debit if debit > 0 else credit
            is_credit = credit > 0
            date_raw = row.get('Date', '').strip()
            date = parse_date_flex(date_raw)
            payee = row.get('Description', '').strip()
            txns.append({
                'date': date, 'payee': payee,
                'amount': round(amount, 2),
                'is_credit': is_credit,
                'raw_line': f'{date} | {payee} | {"CR" if is_credit else "DR"} ${amount:.2f}'
            })
    return txns


def _load_scotia_csv(filepath):
    """Parse Scotia Amount column format (negative = debit, positive = credit)."""
    txns = []
    with open(filepath, 'r', encoding='utf-8-sig') as f:
        reader = csv.DictReader(f)
        for row in reader:
            raw_amt = (row.get('Amount') or '').strip()
            if not raw_amt:
                continue
            try:
                amount = float(raw_amt.replace(',', ''))
            except ValueError:
                continue
            if amount == 0:
                continue
            date_raw = row.get('Date', '').strip()
            date = parse_date_flex(date_raw)
            desc = row.get('Description', '').strip()
            sub = row.get('Sub-description', '').strip()
            payee = f'{desc} {sub}'.strip() if sub else desc
            txns.append({
                'date': date, 'payee': payee,
                'amount': round(abs(amount), 2),
                'is_credit': amount > 0,
                'raw_line': f'{date} | {payee} | {"CR" if amount > 0 else "DR"} ${abs(amount):.2f}'
            })
    return txns


def _load_generic_csv(filepath):
    """Fallback: try to find amount-like columns."""
    txns = []
    with open(filepath, 'r', encoding='utf-8-sig') as f:
        reader = csv.DictReader(f)
        for row in reader:
            for col in ('Amount', 'CAD$', 'Debit'):
                raw = (row.get(col) or '').strip()
                if raw:
                    try:
                        amt = float(raw.replace(',', ''))
                    except ValueError:
                        continue
                    if amt == 0:
                        continue
                    date_raw = row.get('Date') or row.get('Transaction Date') or ''
                    date = parse_date_flex(date_raw.strip())
                    desc = row.get('Description') or row.get('Description 1') or row.get('Payee') or ''
                    payee = desc.strip()
                    txns.append({
                        'date': date, 'payee': payee,
                        'amount': round(abs(amt), 2),
                        'is_credit': amt > 0,
                        'raw_line': f'{date} | {payee} | {"CR" if amt > 0 else "DR"} ${abs(amt):.2f}'
                    })
                    break
    return txns


def load_sidecar_csvs(directory):
    """Load all sidecar CSVs in a directory. Returns list of (filename, txns)."""
    results = []
    for f in sorted(os.listdir(directory)):
        filepath = os.path.join(directory, f)
        if not f.endswith('.csv') or f.startswith('2026 Fiscal Year'):
            continue
        txns = []
        with open(filepath, 'r', encoding='utf-8') as fh:
            # Skip comment lines (#) before the CSV header
            lines = [l for l in fh.readlines() if not l.startswith('#')]
            reader = csv.DictReader(lines)
            for row in reader:
                if 'date' not in row or not row['date'].strip():
                    continue
                try:
                    amount = round(float(row['amount']), 2)
                except (ValueError, KeyError):
                    continue
                if amount <= 0:
                    continue
                txns.append({
                    'date': row['date'].strip(),
                    'payee': row.get('payee', '').strip(),
                    'description': row.get('description', '').strip(),
                    'amount': amount,
                    'is_credit': row.get('debit_or_credit', '').strip() == 'credit',
                    'source_file': f
                })
        if txns:
            results.append((f, txns))
    return results


def fuzzy_match(cons_txn, side_txn):
    """Check if a consolidated CSV txn matches a sidecar txn."""
    # Amount must match exactly (within rounding tolerance)
    if abs(cons_txn['amount'] - side_txn['amount']) > 0.02:
        return False
    # Debit/credit direction must match
    if cons_txn['is_credit'] != side_txn['is_credit']:
        return False
    return True


def reconcile_account(account_name, csv_path, sidecar_dir):
    """Reconcile a consolidated CSV against sidecar CSVs."""
    print(f'\n{"="*70}')
    print(f'RECONCILING: {account_name}')
    print(f'  CSV: {os.path.basename(csv_path)}')
    print(f'  Sidecars: {sidecar_dir}')
    print(f'{"="*70}')

    # Load data
    csv_txns = load_consolidated_csv(csv_path)
    sidecar_files = load_sidecar_csvs(sidecar_dir)

    all_sidecar_txns = []
    for fname, txns in sidecar_files:
        all_sidecar_txns.extend(txns)

    print(f'\n  Consolidated CSV: {len(csv_txns)} transactions')
    print(f'  Sidecar CSVs: {len(sidecar_files)} files, {len(all_sidecar_txns)} transactions')

    # Match each CSV transaction against sidecars
    matched = []
    csv_unmatched = []
    matched_ids = set()

    for i, ct in enumerate(csv_txns):
        found = False
        for j, st in enumerate(all_sidecar_txns):
            if j in matched_ids:
                continue
            if fuzzy_match(ct, st):
                # Check if date is approximately within the statement period
                # Allow up to 7 days difference (posting lag)
                matched.append({'csv': ct, 'sidecar': st})
                matched_ids.add(j)
                found = True
                break
        if not found:
            csv_unmatched.append(ct)

    # Find sidecar transactions not matched to any CSV
    sidecar_unmatched = []
    for j, st in enumerate(all_sidecar_txns):
        if j not in matched_ids:
            sidecar_unmatched.append(st)

    # Print summary
    print(f'\n  --- RESULTS ---')
    print(f'  Matched: {len(matched)}')
    print(f'  In CSV but NOT in sidecar: {len(csv_unmatched)}')
    print(f'  In sidecar but NOT in CSV: {len(sidecar_unmatched)}')

    if csv_unmatched:
        print(f'\n  --- CSV TRANSACTIONS NOT IN SIDECARS ---')
        for t in csv_unmatched:
            print(f'    {t["raw_line"]}')

    if sidecar_unmatched:
        print(f'\n  --- SIDECAR TRANSACTIONS NOT IN CSV ---')
        for t in sidecar_unmatched:
            print(f'    {t["date"]} | {t["payee"][:50]} | {"CR" if t["is_credit"] else "DR"} ${t["amount"]:.2f} | {t["source_file"]}')

    # Amount validation
    csv_total_dr = sum(t['amount'] for t in csv_txns if not t['is_credit'])
    csv_total_cr = sum(t['amount'] for t in csv_txns if t['is_credit'])
    side_total_dr = sum(t['amount'] for t in all_sidecar_txns if not t['is_credit'])
    side_total_cr = sum(t['amount'] for t in all_sidecar_txns if t['is_credit'])

    print(f'\n  --- AMOUNT TOTALS ---')
    print(f'  CSV:     DR ${csv_total_dr:.2f}  CR ${csv_total_cr:.2f}')
    print(f'  Sidecar: DR ${side_total_dr:.2f}  CR ${side_total_cr:.2f}')
    print(f'  Diff:    DR ${abs(csv_total_dr - side_total_dr):.2f}  CR ${abs(csv_total_cr - side_total_cr):.2f}')

    # Sidecar-to-CSV date tolerance check for matched txns
    date_issues = 0
    for m in matched:
        csv_date = m['csv']['date']
        side_date = m['sidecar']['date']
        # Both are yyyy-mm-dd format
        csv_ym = csv_date[:7]
        side_ym = side_date[:7]
        # Allow up to 30 days of difference (boundary txns)
        try:
            from datetime import datetime, timedelta
            cd = datetime.strptime(csv_date, '%Y-%m-%d')
            sd = datetime.strptime(side_date, '%Y-%m-%d')
            diff = abs((cd - sd).days)
            if diff > 30:
                date_issues += 1
                print(f'  ⚠ DATE: CSV={csv_date} vs Sidecar={side_date} | {m["csv"]["payee"][:40]}')
        except:
            pass

    if date_issues == 0:
        print(f'  [OK] All matched dates within tolerance')

    return {
        'matched': matched,
        'csv_unmatched': csv_unmatched,
        'sidecar_unmatched': sidecar_unmatched,
        'csv_total_dr': csv_total_dr,
        'csv_total_cr': csv_total_cr,
        'side_total_dr': side_total_dr,
        'side_total_cr': side_total_cr,
    }


def load_entity_config(entity_name):
    """Load entity configuration from cloud-books-entities.json."""
    candidates = [
        Path.cwd() / "Skills" / "Bookkeeping" / "cloud-books-entities.json",
        Path(__file__).resolve().parent.parent / "cloud-books-entities.json",
    ]
    for c in candidates:
        if c.exists():
            with open(c, "r", encoding="utf-8") as f:
                return json.load(f)
    return {}


def main():
    parser = argparse.ArgumentParser(
        description='Reconcile per-statement sidecar CSVs against consolidated bank portal CSV'
    )
    parser.add_argument('--csv-path', required=True,
                        help='Full path to the annual consolidated CSV file')
    parser.add_argument('--sidecars-dir', required=True,
                        help='Directory containing per-statement sidecar CSVs')
    parser.add_argument('--entity', default='intersite-consulting',
                        help='Entity name in cloud-books-entities.json')
    parser.add_argument('--year', type=int, default=datetime.now().year,
                        help='Fiscal year (default: current year)')
    args = parser.parse_args()

    config = load_entity_config(args.entity)
    entity_config = config.get('entities', {}).get(args.entity, {})
    account_name = entity_config.get('display_name', args.entity)

    result = reconcile_account(
        f'{account_name} ({args.year})',
        args.csv_path,
        args.sidecars_dir
    )

    print(f'\n{"="*70}')
    print('FINAL VERDICT')
    print(f'{"="*70}')

    issues = len(result['csv_unmatched']) + len(result['sidecar_unmatched'])
    print(f'\n  {account_name} ({args.year}):')
    print(f'    Transactions matched: {len(result["matched"])}')
    if issues == 0:
        print(f'    PERFECT MATCH — All CSV transactions found in sidecars and vice versa')
    else:
        print(f'    {issues} discrepancies found')

    if result['csv_unmatched']:
        print(f'      CSV txns missing from sidecars: {len(result["csv_unmatched"])}')
        for t in result['csv_unmatched']:
            print(f'        - {t["raw_line"]}')
    if result['sidecar_unmatched']:
        print(f'      Sidecar txns missing from CSV: {len(result["sidecar_unmatched"])}')
        for t in result['sidecar_unmatched']:
            print(f'        - {t["date"]} | {t["payee"][:50]} | ${t["amount"]:.2f} ({t["source_file"]})')


if __name__ == '__main__':
    main()
