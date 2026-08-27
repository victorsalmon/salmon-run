"""Dry-run categorization: applies vendor→account mapping to annual CSV.

Outputs a new CSV with a suggested_account column for manual proofing.
Does NOT write anything to Zoho.

Rules source: Skills/Bookkeeping/tx-categorization/categorization-rules.json
Edit the JSON file to change rules — do NOT edit hardcoded lists here.
"""

import argparse
import csv
import json
import os
import re

SHOW_INCOME = False  # Set via --show-income flag

DOCS_DIR = os.path.expanduser(r'~\intersite-docs')
BASE = os.path.join(DOCS_DIR, r'Taxes and Bookkeeping\intersite-consulting\2026 Fiscal Year - Bank Statements')
RBC_DIR = os.path.join(BASE, 'RBC-INTERSITE')
MC_DIR = os.path.join(BASE, 'MC 6241 (6258)')
MANIFEST_OLD = os.path.join(DOCS_DIR, r'Taxes and Bookkeeping\intersite-consulting\2026.05.21 - Receipts - intersite-consulting\Complete\manifest-enriched.csv')
MANIFEST_NEW = os.path.join(DOCS_DIR, r'Taxes and Bookkeeping\intersite-consulting\2026.05.28 - Receipts - intersite-consulting\Complete\manifest.csv')

# Load categorization rules from central JSON
RULES_PATH = os.path.join(os.path.dirname(__file__), 'categorization-rules.json')
with open(RULES_PATH, 'r', encoding='utf-8') as f:
    RULES = json.load(f)

ACCT_NAMES = RULES['acct_names']
DESCRIPTION_OVERRIDES = {r['match']: (r['account_name'], r['account_id'], r['note']) for r in RULES['description_overrides']}
INCOME_RULES = [(r['priority'], r['pattern'], r['account_name'], r['account_id'], r['income_type'], r.get('note', ''), r.get('amount_min'), r.get('amount_max'), r.get('amount_round_only', False)) for r in RULES.get('income_rules', [])]
INCOME_RULES.sort(key=lambda x: x[0])  # Sort by priority
INTERSITE_RULES = [(r['pattern'], r['account_name'], r['account_id'], r['note']) for r in RULES['vendor_keyword_rules']]
AMAZON_KEYWORD_RULES = [(r['pattern'], r['account_name'], r['account_id'], r['note']) for r in RULES['amazon_keyword_rules']]


def categorize_amazon_by_notes(notes, filename):
    """Match Amazon receipt notes/filename to account keyword rules."""
    text = (notes + ' ' + filename).lower()
    for pattern, acct_name, acct_id, note in AMAZON_KEYWORD_RULES:
        if re.search(pattern, text):
            return acct_id, acct_name, note
    return '93310000000000460', 'Other Expenses', 'Uncategorized Amazon item'


def lookup_receipt_from_manifest(amount, desc1, desc2, vendor_keywords):
    """Try to match a transaction (Amazon, AliExpress) to a receipt in the manifest."""
    full = (desc1 + ' ' + desc2).upper()
    found = False
    for kw in vendor_keywords:
        if kw.upper() in full:
            found = True
            break
    if not found:
        return None

    for (r_amt, r_vendor), entries in RECEIPT_LOOKUP.items():
        if abs(r_amt - amount) > 0.02:
            continue
        vendor_ok = False
        for kw in vendor_keywords:
            if kw.lower() in r_vendor:
                vendor_ok = True
                break
        if not vendor_ok:
            continue
        entry = entries[0]
        acct_name = ACCT_NAMES.get(entry['acct_id'], 'Other Expenses')
        return acct_name, entry['acct_id'], f'From receipt: {entry["filename"][:70]}'

    m = re.search(r'\*([A-Z0-9]+)', full)
    order_id = m.group(1) if m else 'unknown'
    vendor_label = vendor_keywords[0]
    return f'REVIEW-{vendor_label}', '', f'No receipt found — {vendor_label} order {order_id} ${amount:.2f}'


# Load receipt manifest: maps (amount, vendor_lower) → account_id
# Used for Amazon lookups where the receipt filename tells us what was actually bought
RECEIPT_LOOKUP = {}
def load_manifest(path, is_enriched=False):
    try:
        count = 0
        with open(path, 'r', encoding='utf-8-sig') as f:
            for row in csv.DictReader(f):
                amt_str = row.get('amount', '').strip()
                vendor = row.get('vendor', '').strip().lower()
                filename = row.get('filename', '').strip()
                notes = row.get('notes', row.get('original_filename', '')).strip()
                if is_enriched:
                    acct_id = row.get('suggested_account_id', '').strip()
                else:
                    # Try keyword classification on notes/filename
                    acct_id, acct_name, _ = categorize_amazon_by_notes(notes, filename)
                if not amt_str or not acct_id:
                    continue
                try:
                    amt = round(float(amt_str), 2)
                except ValueError:
                    continue
                if amt <= 0:
                    continue
                key = (amt, vendor)
                if key not in RECEIPT_LOOKUP:
                    RECEIPT_LOOKUP[key] = []
                RECEIPT_LOOKUP[key].append({'acct_id': acct_id, 'filename': filename})
                count += 1
        return count
    except Exception as e:
        print(f'[WARN] Could not load {path}: {e}')
        return 0

total_old = load_manifest(MANIFEST_OLD, is_enriched=True)
total_new = load_manifest(MANIFEST_NEW, is_enriched=False)
print(f'[LOADED] {total_old} receipt entries from old manifest, {total_new} from new manifest')
print(f'[LOADED] {len(RECEIPT_LOOKUP)} unique (amount, vendor) entries total')


def is_round_amount(amount):
    """Check if amount is a round number (no fractional cents)."""
    return abs(amount - round(amount)) < 0.01


def classify_income(payee, amount=0):
    """Classify a credit using income_rules first. Returns (acct_name, acct_id, note) or None."""
    upper = payee.upper()
    for priority, pattern, acct_name, acct_id, income_type, note, amt_min, amt_max, amt_round in INCOME_RULES:
        if re.search(pattern, upper):
            # Check amount constraints
            if amt_min is not None and amount < amt_min:
                continue
            if amt_max is not None and amount > amt_max:
                continue
            if amt_round and not is_round_amount(amount):
                continue
            return acct_name, acct_id, note, income_type
    return None


def classify(payee, amount=0, desc1='', desc2=''):
    """Classify a payee/vendor into an account."""
    upper = payee.upper()
    use_income_classify = SHOW_INCOME  # Whether to use income_rules for this run
    
    # Check description overrides first
    for key, (acct_name, acct_id, note) in DESCRIPTION_OVERRIDES.items():
        if key.upper() in upper:
            return acct_name, acct_id, note
    
    # Apply income_rules to credits if enabled
    if use_income_classify:
        income_result = classify_income(payee, amount)
        if income_result:
            acct_name, acct_id, note, income_type = income_result
            return acct_name, acct_id, note
    
    # Amazon & AliExpress: check receipt manifest first, then flag for review
    vendor_keywords = None
    if 'AMAZON' in upper or 'AMZN' in upper:
        vendor_keywords = ['amazon', 'amzn']
    elif 'ALIEXPRESS' in upper:
        vendor_keywords = ['aliexpress', 'alibaba']
    if vendor_keywords:
        result = lookup_receipt_from_manifest(amount, desc1, desc2, vendor_keywords)
        if result:
            return result
    
    # Check keyword rules
    for pattern, acct_name, acct_id, note in INTERSITE_RULES:
        if re.search(pattern, upper):
            return acct_name, acct_id, note
    
    return 'Other Expenses', '93310000000000460', 'UNMATCHED — review needed'


def process_csv(filepath, account_label):
    """Process a CSV and add suggested_account column."""
    rows = []
    with open(filepath, 'r', encoding='utf-8-sig') as f:
        reader = csv.DictReader(f)
        fieldnames = list(reader.fieldnames) + ['suggested_account', 'suggested_account_id', 'receipt_status', 'classification_note']
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
            
            # Build payee string from Description 1 + Description 2
            desc1 = row.get('Description 1', '').strip()
            desc2 = row.get('Description 2', '').strip()
            payee = f'{desc1} {desc2}'.strip() if desc2 else desc1
            
            # Determine if debit or credit for the note
            txn_type = 'DR' if amount < 0 else 'CR'
            
            # Classify with full context
            acct_name, acct_id, note = classify(payee, abs(amount), desc1, desc2)
            
            # Debits assigned to income accounts → redirect to Other Expenses
            if txn_type == 'DR' and acct_id == '93310000000149102':
                acct_name = 'Other Expenses'
                acct_id = '93310000000000460'
                note = note + ' (DR → Other Expenses)'
            
            # Determine receipt status
            receipt_status = '-- No receipt'
            for (r_amt, r_vendor), entries in RECEIPT_LOOKUP.items():
                if abs(r_amt - amount) > 0.02:
                    continue
                rv_lower = r_vendor.lower()
                payee_lower = payee.lower()
                # Match: vendor name appears in payee OR payee keyword appears in vendor name
                rv_words = set(rv_lower.split())
                payee_words = set(payee_lower.split())
                common = rv_words & payee_words
                if common or rv_lower in payee_lower or payee_lower in rv_lower:
                    receipt_status = f'[OK] Receipt: {entries[0]["filename"][:50]}'
                    break
            
            row['suggested_account'] = acct_name
            row['suggested_account_id'] = acct_id
            row['receipt_status'] = receipt_status
            row['classification_note'] = f'{note} | {txn_type} ${abs(amount):.2f}'
            rows.append(row)
    
    return rows, fieldnames


def main():
    # Process Intersite CSVs
    for label, dirpath, filename in [
        ('RBC Chequing', RBC_DIR, '2026 Fiscal Year - Intersite Transactions.csv'),
        ('MC 6258', MC_DIR, '2026 Fiscal Year - Intersite MC 6258.csv'),
    ]:
        filepath = os.path.join(dirpath, filename)
        rows, fieldnames = process_csv(filepath, label)
        
        # Sort by date then by suggested_account
        rows.sort(key=lambda r: (r.get('Transaction Date', ''), r.get('suggested_account', '')))
        
        # Output
        output_path = os.path.join(dirpath, f'dry-run-{filename}')
        with open(output_path, 'w', newline='', encoding='utf-8-sig') as f:
            writer = csv.DictWriter(f, fieldnames=fieldnames)
            writer.writeheader()
            writer.writerows(rows)
        
        # Count by category
        from collections import Counter
        cat_counts = Counter(r['suggested_account'] for r in rows)
        skipped = sum(1 for r in rows if r['suggested_account'].startswith('SKIP'))
        unmatched = sum(1 for r in rows if 'UNMATCHED' in r['classification_note'])
        
        print(f'\n{"="*60}')
        print(f'{label}: {len(rows)} transactions')
        print(f'{"="*60}')
        for cat, count in sorted(cat_counts.items()):
            if cat.startswith('SKIP'):
                print(f'  {cat:<35s} {count:3d}')
            else:
                print(f'  {cat:<35s} {count:3d}')
        print(f'  {"-"*45}')
        print(f'  {"TOTAL":<35s} {len(rows):3d}')
        print(f'  Skipped (income/transfer): {skipped}')
        print(f'  Unmatched (needs review):  {unmatched}')
        
        # Receipt coverage
        with_receipt = sum(1 for r in rows if 'Receipt:' in r.get('receipt_status', ''))
        no_receipt = len(rows) - with_receipt
        print(f'  Receipt on file: {with_receipt}')
        print(f'  No receipt:      {no_receipt}')
        review_count = sum(1 for r in rows if r.get('suggested_account', '').startswith('REVIEW'))
        print(f'  Flagged for review (Amazon/Ali): {review_count}')
        print(f'\n  Output: dry-run-{filename}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Dry-run categorization of bank transactions')
    parser.add_argument('--show-income', action='store_true', help='Apply income_rules to credits before falling through to vendor_keyword_rules')
    parser.add_argument('--csv', help='Path to specific CSV file (alternative to default paths)')
    parser.add_argument('--entity', default='intersite-consulting', help='Entity slug')
    args, _ = parser.parse_known_args()
    global SHOW_INCOME
    SHOW_INCOME = args.show_income
    main()
