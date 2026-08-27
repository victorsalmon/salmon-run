#!/usr/bin/env python3
# DEPRECATED - This file is kept for backward compatibility.
# Use convert-pdf-statement-to-sidecar.py instead.
# Reason: Renamed to follow kebab-case convention per refactoring skill.

"""Parse RBC chequing and MC credit card PDF bank statements into sidecar CSVs.

Output format (API-compatible for POST /bankstatements):
  date,payee,description,debit_or_credit,amount

A metadata comment header is prepended to each CSV.
"""

import pdfplumber
import csv
import io
import os
import re
import sys

MONTHS_ABB = {
    'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4,
    'may': 5, 'jun': 6, 'jul': 7, 'aug': 8,
    'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12
}
MONTHS_SHORT = {v: k.capitalize() for k, v in MONTHS_ABB.items()}


def parse_year_from_header(header_text):
    """Extract the TO year from 'STATEMENT FROM ... TO MMM DD, YYYY'"""
    m = re.search(r'TO\s+[A-Za-z]+\s+\d+,\s*(\d{4})', header_text, re.IGNORECASE)
    if m:
        return int(m.group(1))
    # Try "March13,2025toApril11,2025" format (RBC)
    m = re.search(r'to([A-Za-z]+\d+,\d{4})', header_text, re.IGNORECASE)
    if m:
        m2 = re.search(r'(\d{4})', m.group(1))
        if m2:
            return int(m2.group(1))
    return None


def resolve_year(txn_month_num, header_month_num, header_year):
    """Given a transaction month number, the header's TO month, and the year,
    determine the correct year for the transaction.
    If txn month > header month, it's likely in the prior year (for Dec in Jan statements).
    """
    if header_month_num == 1 and txn_month_num == 12:
        return header_year - 1
    if txn_month_num > header_month_num:
        return header_year
    return header_year


def parse_rbc_statement(pdf_path):
    """Parse an RBC chequing statement PDF.
    
    Format:
    - Header: "March13,2025toApril11,2025" or similar
    - Transaction section starts with "AccountActivityDetails"
    - Columns: Date(y)  Description  Cheques&Debits  Deposits&Credits  Balance
    - Date format: DDMMM (e.g., 17Mar, 01Apr)
    """
    year = None
    txns = []
    current = None
    in_detail = False
    date_pat = re.compile(r'^(\d{1,2})(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)$', re.IGNORECASE)

    with pdfplumber.open(pdf_path) as pdf:
        all_text = ''
        for page in pdf.pages:
            all_text += page.extract_text() + '\n'

        # Extract year from header
        m = re.search(r'([A-Za-z]+)\d+,\d{4}\s*to\s*([A-Za-z]+)\d+,\s*(\d{4})', all_text)
        if m:
            end_month_str = m.group(2).lower()[:3]
            year = int(m.group(3))
            end_month_num = MONTHS_ABB.get(end_month_str, 1)
        else:
            print(f'WARNING: Could not determine year from {pdf_path}', file=sys.stderr)
            year = 2025
            end_month_num = 1

        for page in pdf.pages:
            words = page.extract_words(keep_blank_chars=True, x_tolerance=3)
            rows = {}
            for w in words:
                y_key = round(w['top'] / 10) * 10
                if y_key not in rows:
                    rows[y_key] = []
                rows[y_key].append(w)

            for y in sorted(rows.keys()):
                ws = sorted(rows[y], key=lambda w: w['x0'])
                desc_words = [w for w in ws if w['x0'] < 310]
                wt_words = [w for w in ws if 310 <= w['x0'] < 420]   # debits column
                dep_words = [w for w in ws if 420 <= w['x0'] < 500]  # deposits column
                desc = ' '.join(w['text'] for w in desc_words).strip()
                fl = ' '.join(w['text'] for w in ws).strip()

                if 'AccountActivityDetails' in fl.replace(' ', ''):
                    in_detail = True
                    continue
                fl_nosp = fl.replace(' ', '')
                if 'ClosingBalance' in fl_nosp or 'Closingbalance' in fl_nosp or 'Important information' in fl or 'AccountFees' in fl:
                    in_detail = False
                    if current:
                        txns.append(current)
                        current = None
                    continue
                if not in_detail:
                    continue
                if fl.startswith('Date Description') or fl.startswith('OpeningBalance'):
                    continue
                if not desc:
                    continue

                fw = desc.split()[0] if desc else ''
                dm = date_pat.match(fw)

                # Get amounts from columns
                wt = 0.0
                for w in reversed(wt_words):
                    try:
                        wt = float(w['text'].replace(',', ''))
                        break
                    except ValueError:
                        pass
                dep = 0.0
                for w in reversed(dep_words):
                    try:
                        dep = float(w['text'].replace(',', ''))
                        break
                    except ValueError:
                        pass

                if dm:
                    if current:
                        txns.append(current)
                    dt = ' '.join(desc.split()[1:])
                    day = int(dm.group(1))
                    month_abb = dm.group(2).lower()[:3]
                    txn_month_num = MONTHS_ABB[month_abb]
                    txn_year = resolve_year(txn_month_num, end_month_num, year)

                    amount = dep if dep > 0 else wt
                    is_debit = wt > 0
                    current = {
                        'desc': dt,
                        'amount': amount,
                        'is_debit': is_debit,
                        'got_amount': dep > 0 or wt > 0,
                        'raw_date': f'{txn_year}-{txn_month_num:02d}-{day:02d}',
                        'txn_month': txn_month_num,
                        'last_date_desc': desc  # store the date description for continuation lines
                    }
                elif current:
                    # Continuation line: detect new transaction on same date
                    has_balance = any(w for w in ws if w['x0'] >= 500)  # balance column
                    has_amt = (dep > 0 or wt > 0)

                    # Known transaction-starting prefixes (continuation with these is a new txn)
                    txn_starters = ['e-Transfer', 'OnlineBanking', 'MiscPayment',
                                    'Monthlyfee', 'PAD', 'PADCCRA']
                    is_new_txn_desc = any(desc.startswith(s) for s in txn_starters)

                    # Detect reference-number continuation (single hex/digit string)
                    is_ref_num = bool(re.match(r'^[0-9a-fA-F]{10,}$', desc.replace(' ', '')))

                    should_split = (
                        is_new_txn_desc
                        or (current['got_amount'] and has_amt and has_balance)
                        or (current['got_amount'] and has_amt and not is_ref_num and not is_new_txn_desc and not desc.startswith('Foreign'))
                    )

                    if should_split:
                        # Store the old transaction if it has data
                        if current['got_amount']:
                            txns.append(current)
                        current = {
                            'desc': desc,
                            'amount': dep if dep > 0 else wt,
                            'is_debit': wt > 0,
                            'got_amount': has_amt,
                            'raw_date': current['raw_date'],
                            'txn_month': current['txn_month'],
                            'last_date_desc': current.get('last_date_desc', '')
                        }
                    else:
                        # Continuation of previous transaction's description
                        if desc and not is_ref_num:
                            current['desc'] += ' ' + desc
                        if not current['got_amount'] and has_amt:
                            current['amount'] = dep if dep > 0 else wt
                            current['is_debit'] = wt > 0
                            current['got_amount'] = True

    # Finalize remaining
    if current:
        txns.append(current)

    # Filter and normalize
    result = []
    for t in txns:
        if not t.get('got_amount'):
            continue
        desc_clean = re.sub(r'\s+', ' ', t['desc']).strip()
        if not desc_clean or t['amount'] <= 0:
            continue
        result.append({
            'date': t['raw_date'],
            'payee': desc_clean,
            'description': desc_clean,
            'debit_or_credit': 'debit' if t['is_debit'] else 'credit',
            'amount': round(float(t['amount']), 2)
        })

    return result


def parse_mc_statement(pdf_path):
    """Parse an MC credit card statement PDF.
    
    Format:
    - Header: "STATEMENT FROM MMM DD TO MMM DD, YYYY"
    - Two sections: card 6241 (payments+interest) and card 6258 (transactions)
    - Transaction rows have line with dates at x=58 (txn date) and x=98 (posting date)
    - Amount at x=317-326, description between x=130-310
    - Reference number lines at x=130 with no dates
    """
    header_period = None
    year = None
    end_month_num = 1
    txns = []

    date_row_pat = re.compile(
        r'(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+(\d{1,2})',
        re.IGNORECASE
    )

    # Lines that should never be treated as transactions (header/structural)
    skip_structural = [
        'STATEMENT FROM', 'PREVIOUS STATEMENT BALANCE', 'NEW BALANCE',
        'SUBTOTAL OF MONTHLY', 'IMPORTANT INFORMATION',
        'Customer Service', 'Lost & Stolen', 'Collect Outside',
        'PAYMENTS & INTEREST RATES', 'Minimum payment',
        'Payment due date', 'Credit limit', 'Available credit',
        'Annual interest rates:', 'CALCULATING YOUR BALANCE',
        'Previous Statement Balance', 'Payments & credits',
        'Purchases & debits', 'Cash advances', 'Interest',
        'Fees', 'Your account is currently', 'Based on the option',
        'RBC ROYAL BANK', 'CREDIT CARD PAYMENT', 'P.O. BOX',
        'TORONTO, ONTARIO', 'INTERSITE CONSULTING LTD.',
        'MR VICTOR SALMON', '5526 12**', 'RBC\uFFFD',
        'For complete terms', 'or by visiting', 'RBC Royal Bank Card Services',
        'INTEREST RATE CHART', 'Description Rate',
        'Purchases & Fees', 'The "Determination', 'of interest',
        'Applying your payments', 'REVIEW YOUR Account',
        'Make your payment', 'How to make a payment',
        'Report a lost or stolen', 'Reading Your Account',
        'Interest is always charged', 'We do not charge',
        'To calculate the interest', 'Foreign currency',
        'IMPORTANT INFORMATION ABOUT', 'Statement Period.',
        'Your Account Statement', 'Link your RBC', 'card and instantly',
        'earn 20%', 'rbc.com/linkbusiness',
        'RBC\uFFFD Business Cash Back',
        'Quick, convenient and secure',
        'Other payment options include:', 'SUITE 209', '7600 FRANCIS',
        'for terms & conditions.',
    ]

    with pdfplumber.open(pdf_path) as pdf:
        all_text = ''
        for page in pdf.pages:
            all_text += page.extract_text() + '\n'

        # Extract statement period
        m = re.search(
            r'STATEMENT\s+FROM\s+([A-Za-z]+)\s+(\d+)(?:,\s*\d{4})?\s+TO\s+([A-Za-z]+)\s+(\d+),\s*(\d{4})',
            all_text, re.IGNORECASE
        )
        if m:
            end_month_str = m.group(3).lower()[:3]
            end_month_num = MONTHS_ABB.get(end_month_str, 1)
            year = int(m.group(5))
            header_period = f'{m.group(1).upper()} {m.group(2)} TO {m.group(3).upper()} {m.group(4)}, {year}'
        else:
            print(f'WARNING: Could not find statement period in {pdf_path}', file=sys.stderr)
            year = 2025
            end_month_num = 1
            header_period = 'UNKNOWN'

        for page in pdf.pages:
            words = page.extract_words(keep_blank_chars=True, x_tolerance=3)
            rows = {}
            for w in words:
                y_key = round(w['top'] / 10) * 10
                if y_key not in rows:
                    rows[y_key] = []
                rows[y_key].append(w)

            for y in sorted(rows.keys()):
                ws = sorted(rows[y], key=lambda w: w['x0'])

                # Split words into columns
                # Description: 126-305 (some start at 127.6)
                # Amount: 305-360 (wide negative amounts like -$1,372.79 start at 306.6)
                col1_words = [w for w in ws if w['x0'] < 90]     # txn date
                col2_words = [w for w in ws if 90 <= w['x0'] < 128]  # posting date
                col3_words = [w for w in ws if 126 <= w['x0'] < 305]  # description
                col4_words = [w for w in ws if 305 <= w['x0'] < 360]  # amount
                col5_words = [w for w in ws if w['x0'] >= 390]   # right annotations

                col1_text = ' '.join(w['text'] for w in col1_words).strip()
                col3_text = ' '.join(w['text'] for w in col3_words).strip()
                col4_text = ' '.join(w['text'] for w in col4_words).strip()
                col5_text = ' '.join(w['text'] for w in col5_words).strip()

                # Check if this is a transaction row (has date in col1)
                # Use search() not match() — header text can collide at same y-coord as txn dates
                dm1 = date_row_pat.search(col1_text) if col1_text else None

                if not dm1:
                    continue

                # Only use description (col3) for structural skip check,
                # NOT the full line — right-side annotations should not filter transactions
                if any(skip in col3_text or skip in col1_text for skip in skip_structural):
                    continue

                # Parse transaction date
                txn_month_abb = dm1.group(1).lower()[:3]
                txn_day = int(dm1.group(2))
                txn_month_num = MONTHS_ABB[txn_month_abb]
                txn_year = resolve_year(txn_month_num, end_month_num, year)
                txn_date = f'{txn_year}-{txn_month_num:02d}-{txn_day:02d}'

                # Parse description from col3
                desc = re.sub(r'\s+', ' ', col3_text).strip()

                # Parse amount from col4
                amt_text = col4_text.replace('$', '').replace(',', '')
                if not amt_text:
                    continue

                try:
                    amount = abs(float(amt_text))
                except ValueError:
                    continue

                if amount <= 0:
                    continue

                if not desc:
                    continue

                # Negative sign in col4 means it's a credit (payment received)
                is_credit = col4_text.startswith('-')

                txns.append({
                    'date': txn_date,
                    'payee': desc,
                    'description': desc,
                    'debit_or_credit': 'credit' if is_credit else 'debit',
                    'amount': round(amount, 2)
                })

    return txns, header_period


def detect_format(pdf_path):
    """Detect whether this is an RBC or MC statement."""
    with pdfplumber.open(pdf_path) as pdf:
        text = pdf.pages[0].extract_text()
        if 'Mastercard' in text or 'MASTERCARD' in text or 'MasterCard' in text or 'Cash Back Mastercard' in text:
            return 'mc'
        if 'Business Account Statement' in text:
            return 'rbc'
    return 'unknown'


def get_header_period(pdf_path):
    """Extract the statement period text from the PDF header."""
    with pdfplumber.open(pdf_path) as pdf:
        text = pdf.pages[0].extract_text()
    for line in text.split('\n'):
        if 'STATEMENT FROM' in line:
            return line.strip()
        m = re.search(r'([A-Za-z]+\d+,\d{4}\s*to\s*[A-Za-z]+\d+,\s*\d{4})', line)
        if m:
            return m.group(1)
    return 'UNKNOWN'


def write_sidecar_csv(pdf_path, txns, header_period, conversion_method):
    """Write sidecar CSV alongside the PDF file."""
    csv_path = os.path.splitext(pdf_path)[0] + '.csv'

    with open(csv_path, 'w', newline='', encoding='utf-8') as f:
        # Metadata header
        f.write(f'# Source: {os.path.basename(pdf_path)}\n')
        f.write(f'# Period: {header_period}\n')
        f.write(f'# Transactions: {len(txns)}\n')
        f.write(f'# Conversion: {conversion_method}\n')
        f.write(f'# Generated: 2026-05-28\n')
        f.write('# \n')
        f.write('# Format: date,payee,description,debit_or_credit,amount\n')
        f.write('#   debit_or_credit: "debit" for purchases/withdrawals, "credit" for payments/deposits\n')
        f.write('#   amount: always positive\n')

        writer = csv.writer(f)
        writer.writerow(['date', 'payee', 'description', 'debit_or_credit', 'amount'])

        for t in txns:
            writer.writerow([
                t['date'],
                t['payee'],
                t['description'],
                t['debit_or_credit'],
                t['amount']
            ])

    return csv_path


def process_pdf(pdf_path):
    """Process a single PDF: detect format, parse, write sidecar CSV."""
    fmt = detect_format(pdf_path)
    header_period = get_header_period(pdf_path)

    if fmt == 'rbc':
        txns = parse_rbc_statement(pdf_path)
        method = 'pdfplumber-rbc-columns'
    elif fmt == 'mc':
        txns, hp = parse_mc_statement(pdf_path)
        if hp and hp != 'UNKNOWN':
            header_period = hp
        method = 'pdfplumber-mc-rows'
    else:
        print(f'SKIP Unknown format: {pdf_path}', file=sys.stderr)
        return 0, 'unknown'

    csv_path = write_sidecar_csv(pdf_path, txns, header_period, method)
    print(f'OK {fmt.upper():3s} {len(txns):3d} txns -> {os.path.basename(csv_path)}')
    return len(txns), fmt


def main():
    import glob as globmod

    base = r'C:\Users\Victor\intersite-docs\Taxes and Bookkeeping\intersite-consulting\2026 Fiscal Year - Bank Statements'

    # Find all PDFs
    pdfs = []
    for root, dirs, files in os.walk(base):
        for f in files:
            if f.lower().endswith('.pdf'):
                pdfs.append(os.path.join(root, f))

    pdfs.sort()
    print(f'Found {len(pdfs)} PDF statement files\n')

    total_txns = 0
    rbc_count = 0
    mc_count = 0

    for pdf_path in pdfs:
        n, fmt = process_pdf(pdf_path)
        total_txns += n
        if fmt == 'rbc':
            rbc_count += 1
        elif fmt == 'mc':
            mc_count += 1

    print(f'\nDone: {rbc_count} RBC + {mc_count} MC = {rbc_count + mc_count} statements')
    print(f'Total transactions extracted: {total_txns}')


if __name__ == '__main__':
    main()
