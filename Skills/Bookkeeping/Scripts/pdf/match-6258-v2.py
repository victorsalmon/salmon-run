#!/usr/bin/env python3
# DEPRECATED — Merged into extract-match-credit-card.py --vendor-hint.
# Reason: Redundant; its logic is now a flag on the replacement.
"""Match 6258 receipts — scans root + ingest folders, uses filename vendor hints."""
import csv, os, re, shutil
from datetime import datetime

_USER_HOME = os.path.expanduser('~')
CSV_PATH = os.path.join(_USER_HOME,
    r'intersite-docs\Taxes and Bookkeeping\intersite-consulting\2026 Fiscal Year - Bank Statements\MC 6241 (6258)\2026 Fiscal Year - Intersite MC 6258 - enriched.csv')
SCAN_DIRS = [
    os.path.join(_USER_HOME,
        r'intersite-docs\Taxes and Bookkeeping\intersite-consulting\2026 Receipts\rbc-6258'),
    os.path.join(_USER_HOME,
        r'intersite-docs\Taxes and Bookkeeping\intersite-consulting\2026 Receipts\rbc-6258-ingest'),
]
BACKUP = CSV_PATH.replace('.csv', '-pre-final-backup.csv')

with open(CSV_PATH, 'r', encoding='utf-8') as f:
    reader = csv.DictReader(f); headers = reader.fieldnames; rows = list(reader)
shutil.copy2(CSV_PATH, BACKUP)

already_matched = {r.get('Associated Receipt','').strip() for r in rows if r.get('Associated Receipt','').strip()}

# Index ALL receipt-like files from both directories
receipts = []
for scan_dir in SCAN_DIRS:
    if not os.path.isdir(scan_dir):
        continue
    for f in os.listdir(scan_dir):
        if not f.lower().endswith(('.pdf','.jpg','.png')):
            continue
        if f.lower().startswith(('pxl_','invoice_','bill_','1000','5500')):
            continue
        # Normalize dotted dates to ISO before searching
        f_norm = re.sub(r'(\d{4})\.(\d{2})\.(\d{2})', r'\1-\2-\3', f)
        m_date = re.search(r'(\d{4}-\d{2}-\d{2})', f_norm)
        m_amt = re.search(r'\d{4}-\d{2}-\d{2}\s*-\s*([\d]+\.?\d*)', f_norm)
        if not m_amt:
            # Text between date and amount: "2025-06-10 - WPForms - 99 USD.pdf"
            m_amt = re.search(r'\d{4}-\d{2}-\d{2}\s+.*?([\d]+\.?\d*)\s*USD', f_norm)
        if not m_amt:
            # Any number after date that looks like an amount (not year-like)
            m_amt = re.search(r'\d{4}-\d{2}-\d{2}.*?([\d]+\.[\d]{2})', f_norm)
        if not m_amt:
            # Fallback: last number before .pdf
            m_amt = re.search(r'([\d]+\.[\d]{2})\s*\.(pdf|jpg|png)', f_norm)
        if not m_date or not m_amt:
            continue
        try:
            receipts.append({
                'file': f,
                'dir': scan_dir,
                'date_obj': datetime.strptime(m_date.group(1), '%Y-%m-%d'),
                'amount': float(m_amt.group(1)),
                'fname_lower': f.lower()
            })
        except:
            pass

# Also index CSV sidecars for correct date/vendor/amount
for scan_dir in SCAN_DIRS:
    if not os.path.isdir(scan_dir):
        continue
    for f in sorted(os.listdir(scan_dir)):
        if not f.endswith('.csv'):
            continue
        fpath = os.path.join(scan_dir, f)
        try:
            with open(fpath, 'r', encoding='utf-8') as cf:
                lines = cf.readlines()
        except:
            continue
        vendor = ''
        source_pdf = ''
        for line in lines:
            if line.startswith('# Vendor: '):
                vendor = line.replace('# Vendor: ', '').strip()
            if line.startswith('# Source: '):
                source_pdf = line.replace('# Source: ', '').strip()
        # Clean vendor name
        vendor = re.sub(r'^[/,\s]*Vendu par:\s*', '', vendor, flags=re.IGNORECASE).strip()
        if not vendor or vendor in ('', 'PO BOX 1707 Englewood Cliffs NJ 07632 . 201-605-1440'):
            # Infer vendor from filename
            fl = f.lower()
            if 'freedom' in fl: vendor = 'freedom mobile'
            elif 'interserver' in fl: vendor = 'interserver'
            elif 'amazon' in fl: vendor = 'amazon.ca'
        try:
            reader = csv.reader([lines[-1].strip()])
            parts = next(reader)
        except:
            continue
        csv_date = parts[2].strip() if len(parts) >= 10 else ''
        csv_total = parts[7].strip() if len(parts) >= 10 else ''
        if not csv_date or not csv_total:
            base = f.replace('.csv', '')
            base_norm = re.sub(r'(\d{4})\.(\d{2})\.(\d{2})', r'\1-\2-\3', base)
            m = re.search(r'(\d{4}-\d{2}-\d{2})', base_norm)
            a = re.search(r'\d{4}-\d{2}-\d{2}\s*-\s*([\d]+\.?\d*)', base_norm)
            if not a:
                a = re.search(r'\d{4}-\d{2}-\d{2}.*?([\d]+\.?\d*)\s*USD', base_norm)
            if not a:
                a = re.search(r'\d{4}-\d{2}-\d{2}.*?([\d]+\.[\d]{2})', base_norm)
            if m and not csv_date: csv_date = m.group(1)
            if a and not csv_total: csv_total = a.group(1)
        if not csv_date or not csv_total:
            continue
        # Reference PDF: use short name if exists, else source_pdf
        ref_file = f.replace('.csv', '.pdf')
        if not os.path.exists(os.path.join(scan_dir, ref_file)):
            ref_file = source_pdf if source_pdf else ref_file
        try:
            rec = {
                'file': ref_file,
                'dir': scan_dir,
                'date_obj': datetime.strptime(csv_date, '%Y-%m-%d'),
                'amount': float(csv_total),
                'fname_lower': (ref_file + ' ' + vendor).lower(),
                'source': 'csv'
            }
            receipts.append(rec)
        except:
            pass

print(f'Indexed {len(receipts)} items ({sum(1 for r in receipts if r.get("source")=="csv")} from CSVs)')

def vendor_match(fname_lower, desc_full, desc_orig):
    """Check if the filename suggests a vendor that matches the transaction."""
    fname = fname_lower
    desc = desc_full
    # Direct vendor name search
    vendors_in_fname = re.findall(r'[a-z]+', fname)
    
    # Aliases: filename pattern → description keywords
    rules = [
        (['interserver','interserver.net','po box 1707'], 'interserver'),
        (['freedom mobile','freedom','bill_'], ['freedom mobile','freedom']),
        (['amazon','amzn'], ['amazon','amzn']),
        (['home depot','the home depot', 'mulch', 'yard'], ['home depot']),
        (['temu'], ['temu']),
        (['paypal'], ['paypal']),
        (['civil resolution'], ['civil resolution']),
        (['esso','7-eleven'], ['esso','7-eleven']),
        (['petro-canada','petro canada','petro'], ['petro']),
        (['shell'], ['shell']),
        (['squarespace','sqsp'], ['sqsp','squarespace']),
        (['appsumo'], ['appsumo']),
        (['reinvestwealth','reinvest'], ['reinvestwealth','reinvest']),
        (['namecheap','name-cheap'], ['namecheap','name-cheap']),
        (['bugman','the bugman'], ['bugman']),
        (['legalshield'], ['legalshield']),
        (['udemy'], ['udemy']),
        (['boldsign'], ['boldsign']),
        (['wpforms'], ['wpforms']),
        (['moz'], ['mozseo','moz']),
        (['ozerty'], ['ozerty']),
        (['myclaw'], ['myclaw']),
    ]
    for fname_kw, desc_kw in rules:
        desc_kw_list = desc_kw if isinstance(desc_kw, list) else [desc_kw]
        if any(kw in fname for kw in fname_kw):
            return any(kw in desc for kw in desc_kw_list)
    return False

def parse_usd(desc2):
    m = re.search(r'([\d.]+)\s*USD', desc2)
    return float(m.group(1)) if m else None

new_matches = []
for row in rows:
    ref = (row.get('Associated Receipt') or '').strip()
    if ref: continue
    
    cad_str = (row.get('CAD$') or row.get('CAD\\$') or '').strip()
    if not cad_str: continue
    try: cad = float(cad_str)
    except: continue
    if cad >= 0: continue
    
    amt_cad = abs(cad)
    desc1 = (row.get('Description 1') or '').strip()
    desc2 = (row.get('Description 2') or '').strip()
    desc_full = (desc1 + ' ' + desc2).lower()
    usd_orig = parse_usd(desc2)
    
    try: txn_date = datetime.strptime(row['Transaction Date'], '%m/%d/%Y')
    except: continue
    
    if 'purchase interest' in desc_full: continue
    if 'automatic payment' in desc_full: continue
    
    best = None; best_score = 0; best_src = ''
    
    for r in receipts:
        ref_name = os.path.basename(r['file'])
        if ref_name in already_matched: continue
        
        date_diff = abs((r['date_obj'] - txn_date).days)
        v_match = vendor_match(r['fname_lower'], desc_full, desc1)
        
        # Try USD match first (InterServer: $5 USD receipt vs $5 USD on statement)
        usd_match = usd_orig and abs(r['amount'] - usd_orig) < 0.5
        cad_match = abs(r['amount'] - amt_cad) < 2.0
        
        if not cad_match and not usd_match:
            continue
        if not v_match:
            continue
        
        # Score
        if usd_match and v_match:
            score = 20  # Strong: USD amount matches AND vendor confirmed
        elif cad_match and abs(r['amount'] - amt_cad) < 0.5 and v_match:
            score = 18  # Exact CAD match + vendor
        elif cad_match and v_match:
            score = 12  # Close CAD match + vendor
        else:
            continue
        
        # Date bonus
        if date_diff <= 2: score += 3
        elif date_diff <= 7: score += 1
        
        # Prefer files from rbc-6258 root over ingest
        if 'rbc-6258' in r['dir'] and 'ingest' not in r['dir']:
            score += 1
        
        if score > best_score:
            best_score = score
            best = ref_name
            best_src = os.path.basename(r['dir'])
    
    if best:
        row['Associated Receipt'] = best
        already_matched.add(best)
        new_matches.append((row['Transaction Date'], amt_cad, best, desc1, best_src, usd_orig))

with open(CSV_PATH, 'w', newline='', encoding='utf-8') as f:
    writer = csv.DictWriter(f, fieldnames=headers); writer.writeheader(); writer.writerows(rows)

remaining = sum(1 for r in rows 
    if not (r.get('Associated Receipt') or '').strip() 
    and (r.get('CAD$') or r.get('CAD\\$') or '').strip()
    and float(r.get('CAD$') or r.get('CAD\\$') or '0') < 0
    and 'purchase interest' not in ((r.get('Description 1') or '') + ' ' + (r.get('Description 2') or '')).lower()
    and 'automatic payment' not in ((r.get('Description 1') or '') + ' ' + (r.get('Description 2') or '')).lower())

print(f'\n=== Results ===')
print(f'New matches: {len(new_matches)}')
print(f'Still unmatched: {remaining}')

if new_matches:
    print(f'\n--- Newly Matched ---')
    for d, a, fname, desc, src, usd in sorted(new_matches):
        usd_str = f' (${usd} USD)' if usd else ''
        n = os.path.basename(fname)[:55]
        print(f'  {d}  ${a:<8.2f}{usd_str:15s} [{src:12s}] {n}')
        print(f'  {"":>14}  {desc[:70]}')
