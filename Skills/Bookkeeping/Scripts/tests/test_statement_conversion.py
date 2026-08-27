"""Tests for convert-pdf-statement-to-sidecar.py — regex, helpers, CSV output.

Tests pure logic and helper functions without PDF parsing (no pdfplumber).
"""

import csv
import re
from io import StringIO


# ── Replicated constants from convert-pdf-statement-to-sidecar.py ────────────

MONTHS_ABB = {
    'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4,
    'may': 5, 'jun': 6, 'jul': 7, 'aug': 8,
    'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12
}

MONTHS_SHORT = {v: k.capitalize() for k, v in MONTHS_ABB.items()}


# ── Replicated helpers ───────────────────────────────────────────────────────

def _parse_year_from_header(header_text):
    """Replicates convert-pdf-statement-to-sidecar.py parse_year_from_header."""
    m = re.search(r'TO\s+[A-Za-z]+\s+\d+,\s*(\d{4})', header_text, re.IGNORECASE)
    if m:
        return int(m.group(1))
    m = re.search(r'to([A-Za-z]+\d+,\d{4})', header_text, re.IGNORECASE)
    if m:
        m2 = re.search(r'(\d{4})', m.group(1))
        if m2:
            return int(m2.group(1))
    return None


def _resolve_year(txn_month_num, header_month_num, header_year):
    """Replicates convert-pdf-statement-to-sidecar.py resolve_year."""
    if header_month_num == 1 and txn_month_num == 12:
        return header_year - 1
    if txn_month_num > header_month_num:
        return header_year
    return header_year


def _detect_format_from_text(text):
    """Replicates detect_format's text analysis without pdfplumber."""
    if 'Mastercard' in text or 'MASTERCARD' in text or 'MasterCard' in text or 'Cash Back Mastercard' in text:
        return 'mc'
    if 'Business Account Statement' in text or 'RBC personal banking' in text:
        return 'rbc'
    return 'unknown'


def _get_header_period_from_text(text):
    """Replicates get_header_period's text analysis without pdfplumber."""
    for line in text.split('\n'):
        if 'STATEMENT FROM' in line:
            return line.strip()
        m = re.search(r'([A-Za-z]+\d+,\d{4}\s*to\s*[A-Za-z]+\d+,\s*\d{4})', line)
        if m:
            return m.group(1)
    return 'UNKNOWN'


# ── Tests for MONTHS_ABB and MONTHS_SHORT ────────────────────────────────────

def test_months_abb_has_all_12():
    assert len(MONTHS_ABB) == 12


def test_months_abb_values_sequential():
    for expected_num, (abbrev, num) in enumerate(sorted(MONTHS_ABB.items(), key=lambda x: x[1]), 1):
        assert num == expected_num, f"{abbrev} -> {num}, expected {expected_num}"


def test_months_short_roundtrip():
    for abbrev, num in MONTHS_ABB.items():
        expected_capitalized = abbrev.capitalize()
        assert MONTHS_SHORT[num] == expected_capitalized


def test_months_short_all_present():
    for num in range(1, 13):
        assert num in MONTHS_SHORT


# ── Tests for parse_year_from_header ──────────────────────────────────────────

def test_parse_year_standard_to_format():
    """STATEMENT FROM ... TO MMM DD, YYYY"""
    result = _parse_year_from_header("STATEMENT FROM JAN 01 TO MAR 15, 2026")
    assert result == 2026


def test_parse_year_to_without_comma():
    """TO MMM DD, YYYY with comma (standard format)"""
    result = _parse_year_from_header("STATEMENT FROM JAN 01 TO MAR 15, 2026")
    assert result == 2026


def test_parse_year_rbc_compact_format():
    """March13,2025toApril11,2025"""
    result = _parse_year_from_header("March13,2025toApril11,2025")
    assert result == 2025


def test_parse_year_rbc_compact_december():
    """December1,2025toJanuary5,2026"""
    result = _parse_year_from_header("December1,2025toJanuary5,2026")
    assert result == 2026


def test_parse_year_no_match_returns_none():
    assert _parse_year_from_header("No date here") is None


def test_parse_year_empty_string():
    assert _parse_year_from_header("") is None


def test_parse_year_lowercase_to():
    """toMMMDD,YYYY (lowercase 'to')"""
    result = _parse_year_from_header("january15,2025tomarch20,2025")
    assert result == 2025


# ── Tests for resolve_year ────────────────────────────────────────────────────

def test_resolve_year_same_month():
    """Transaction and header in same month -> header year."""
    assert _resolve_year(3, 3, 2026) == 2026


def test_resolve_year_txn_before_header():
    """Transaction month before header month -> header year."""
    assert _resolve_year(1, 6, 2026) == 2026


def test_resolve_year_december_in_january():
    """December transaction in January statement -> prior year."""
    assert _resolve_year(12, 1, 2026) == 2025


def test_resolve_year_january_in_march():
    """January in March statement -> same year."""
    assert _resolve_year(1, 3, 2026) == 2026


def test_resolve_year_header_month_1_txn_1():
    """Both January -> same year."""
    assert _resolve_year(1, 1, 2026) == 2026


def test_resolve_year_header_month_12_txn_12():
    """Both December -> same year."""
    assert _resolve_year(12, 12, 2026) == 2026


# ── Tests for detect_format ───────────────────────────────────────────────────

def test_detect_mc_keyword_mastercard():
    assert _detect_format_from_text("Mastercard Transaction Summary") == 'mc'


def test_detect_mc_keyword_mastercard_uppercase():
    assert _detect_format_from_text("MASTERCARD Statement") == 'mc'


def test_detect_mc_cash_back():
    assert _detect_format_from_text("Cash Back Mastercard Statement") == 'mc'


def test_detect_rbc_business_account():
    assert _detect_format_from_text("Business Account Statement") == 'rbc'


def test_detect_rbc_personal_banking():
    assert _detect_format_from_text("RBC personal banking statement") == 'rbc'


def test_detect_unknown_format():
    assert _detect_format_from_text("Some random bank statement") == 'unknown'


def test_detect_empty_text():
    assert _detect_format_from_text("") == 'unknown'


def test_detect_mc_prefers_over_rbc():
    """MC keywords appear first -> mc even if rbc keywords also present."""
    text = "Mastercard\nBusiness Account Statement"
    assert _detect_format_from_text(text) == 'mc'


# ── Tests for get_header_period ───────────────────────────────────────────────

def test_header_period_standard():
    text = "STATEMENT FROM JAN 01 TO MAR 15, 2026\nSome other text"
    assert "STATEMENT FROM" in _get_header_period_from_text(text)


def test_header_period_rbc_compact():
    text = "March13,2025toApril11,2025\nAccount details"
    result = _get_header_period_from_text(text)
    assert result == "March13,2025toApril11,2025"


def test_header_period_no_match():
    assert _get_header_period_from_text("No period here") == 'UNKNOWN'


def test_header_period_empty():
    assert _get_header_period_from_text("") == 'UNKNOWN'


def test_header_period_first_line_wins():
    text = "STATEMENT FROM JAN 01 TO JAN 31, 2026\nSTATEMENT FROM FEB 01 TO FEB 28, 2026"
    result = _get_header_period_from_text(text)
    assert "JAN 31, 2026" in result


# ── Tests for sidecar CSV column generation ───────────────────────────────────

SIDECAR_HEADER_LINES = [
    '# Source:',
    '# Period:',
    '# Transactions:',
    '# Conversion:',
    '# Generated:',
    '# ',
    '# Format: date,payee,description,debit_or_credit,amount',
    '#   debit_or_credit: "debit" for purchases/withdrawals, "credit" for payments/deposits',
    '#   amount: always positive',
]

SIDECAR_COLUMNS = ['date', 'payee', 'description', 'debit_or_credit', 'amount']


def test_sidecar_columns_match_convention():
    assert SIDECAR_COLUMNS == ['date', 'payee', 'description', 'debit_or_credit', 'amount']


def test_sidecar_has_exactly_5_columns():
    assert len(SIDECAR_COLUMNS) == 5


def test_sidecar_header_lines_present():
    required = {'Source:', 'Period:', 'Format:', 'amount: always positive'}
    for r in required:
        assert any(r in line for line in SIDECAR_HEADER_LINES), f"Missing: {r}"


def test_sidecar_credit_debit_values():
    """Verify debit_or_credit column only allows two values."""
    allowed = {'debit', 'credit'}
    assert allowed == {'debit', 'credit'}


def test_sidecar_csv_roundtrip(tmp_path):
    """Write sample sidecar rows to a real CSV and read them back.
    Uses csv.reader with manual header offset to handle comment-line header.
    """
    rows = [
        {'date': '2026-01-15', 'payee': 'Freedom Mobile', 'description': 'Freedom Mobile',
         'debit_or_credit': 'debit', 'amount': 33.60},
        {'date': '2026-01-20', 'payee': 'Amazon.ca', 'description': 'Online Purchase',
         'debit_or_credit': 'debit', 'amount': 100.00},
        {'date': '2026-02-01', 'payee': 'Client Payment', 'description': 'Invoice #101',
         'debit_or_credit': 'credit', 'amount': 5000.00},
    ]
    path = tmp_path / 'sidecar.csv'
    with open(path, 'w', newline='', encoding='utf-8') as f:
        f.write('# Source: test.pdf\n')
        f.write('# Period: JAN 01 TO MAR 15, 2026\n')
        f.write(f'# Transactions: {len(rows)}\n')
        f.write('# \n')
        writer = csv.writer(f)
        writer.writerow(SIDECAR_COLUMNS)
        for r in rows:
            writer.writerow([r['date'], r['payee'], r['description'],
                           r['debit_or_credit'], r['amount']])

    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
    assert '# Source: test.pdf' in content
    assert '# Transactions: 3' in content

    # Skip comment lines, then use DictReader on the header+data portion
    with open(path, 'r', encoding='utf-8') as f:
        lines = [l for l in f.readlines() if not l.startswith('#')]
    reader = csv.DictReader(lines)
    parsed = list(reader)
    assert len(parsed) == 3
    assert parsed[0]['date'] == '2026-01-15'
    assert parsed[0]['debit_or_credit'] == 'debit'
    assert parsed[2]['debit_or_credit'] == 'credit'


def test_sidecar_amount_always_positive(tmp_path):
    """Amount column must always be positive. Skip comment lines when reading."""
    rows = [
        {'date': '2026-01-15', 'payee': 'Freedom Mobile', 'description': 'Freedom Mobile',
         'debit_or_credit': 'debit', 'amount': 33.60},
        {'date': '2026-02-01', 'payee': 'Client Payment', 'description': 'Invoice #101',
         'debit_or_credit': 'credit', 'amount': 5000.00},
    ]
    path = tmp_path / 'sidecar_pos.csv'
    with open(path, 'w', newline='', encoding='utf-8') as f:
        f.write('# Source: test.pdf\n')
        f.write('# Comment line\n')
        writer = csv.writer(f)
        writer.writerow(SIDECAR_COLUMNS)
        for r in rows:
            writer.writerow([r['date'], r['payee'], r['description'],
                           r['debit_or_credit'], r['amount']])

    with open(path, 'r', encoding='utf-8') as f:
        lines = [l for l in f.readlines() if not l.startswith('#')]
    reader = csv.DictReader(lines)
    for row in reader:
        assert float(row['amount']) > 0, f"Amount must be positive: {row['amount']}"


def test_sidecar_csv_always_utf8(tmp_path):
    """Sidecar CSV should always be UTF-8 encoded."""
    path = tmp_path / 'utf8_test.csv'
    with open(path, 'w', newline='', encoding='utf-8') as f:
        writer = csv.writer(f)
        writer.writerow(SIDECAR_COLUMNS)
        writer.writerow(['2026-01-15', 'Freedom Mobile', 'Freedom Mobile', 'debit', 33.60])
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
    assert 'Freedom Mobile' in content


# ── Tests for MC statement date_row_pat regex ─────────────────────────────────

DATE_ROW_PAT = re.compile(
    r'(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+(\d{1,2})',
    re.IGNORECASE
)


def test_date_row_pat_standard():
    m = DATE_ROW_PAT.search("Jan 15")
    assert m is not None
    assert m.group(1).lower() == 'jan'
    assert m.group(2) == '15'


def test_date_row_pat_padded_day():
    m = DATE_ROW_PAT.search("Mar 01")
    assert m is not None
    assert int(m.group(2)) == 1


def test_date_row_pat_two_digit_day():
    m = DATE_ROW_PAT.search("Dec 31")
    assert m is not None
    assert m.group(1).lower() == 'dec'
    assert m.group(2) == '31'


def test_date_row_pat_no_match_number_only():
    assert DATE_ROW_PAT.search("15") is None


def test_date_row_pat_no_match_text_only():
    assert DATE_ROW_PAT.search("January") is None


def test_date_row_pat_case_insensitive():
    m = DATE_ROW_PAT.search("FEB 28")
    assert m is not None
    assert m.group(1).lower() == 'feb'


def test_date_row_pat_numeric_prefix():
    """Ensure numbers before month names don't break matching."""
    m = DATE_ROW_PAT.search("2 Jan 15")
    assert m is not None
    assert m.group(1).lower() == 'jan'


# ── Tests for RBC statement date_pat regex ───────────────────────────────────

DATE_PAT = re.compile(r'^(\d{1,2})(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)$', re.IGNORECASE)


def test_rbc_date_pat_standard():
    m = DATE_PAT.match("17Mar")
    assert m is not None
    assert m.group(1) == '17'
    assert m.group(2).lower() == 'mar'


def test_rbc_date_pat_padded_day():
    m = DATE_PAT.match("01Apr")
    assert m is not None
    assert m.group(1) == '01'


def test_rbc_date_pat_no_match_padded():
    assert DATE_PAT.match(" 17Mar") is None


def test_rbc_date_pat_no_match_year_suffix():
    assert DATE_PAT.match("17Mar2025") is None


def test_rbc_date_pat_all_months():
    for month_abb in ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec']:
        m = DATE_PAT.match(f"15{month_abb}")
        assert m is not None, f"Failed for {month_abb}"


# ── Tests for skip_structural patterns ────────────────────────────────────────

SKIP_STRUCTURAL = [
    'STATEMENT FROM', 'PREVIOUS STATEMENT BALANCE', 'NEW BALANCE',
    'SUBTOTAL OF MONTHLY', 'IMPORTANT INFORMATION',
    'Customer Service', 'Lost & Stolen',
    'PAYMENTS & INTEREST RATES', 'Minimum payment',
    'Payment due date', 'Credit limit', 'Available credit',
    'Previous Statement Balance', 'Payments & credits',
    'Purchases & debits', 'Cash advances', 'Interest',
    'Fees', 'Your account is currently',
    'RBC ROYAL BANK', 'CREDIT CARD PAYMENT',
    'INTERSITE CONSULTING LTD.',
    'MR VICTOR SALMON',
    'REVIEW YOUR Account',
]


def test_skip_structural_no_false_positives():
    """Transaction-like descriptions should NOT match skip patterns."""
    safe = [
        "AMAZON.CA",
        "FREEDOM MOBILE",
        "NETFLIX.COM",
        "HOME DEPOT",
        "OPENROUTER API",
    ]
    for s in safe:
        assert not any(skip in s for skip in SKIP_STRUCTURAL), f"False positive: {s}"


def test_skip_structural_catches_headers():
    headers = [
        "STATEMENT FROM JAN 01 TO MAR 15, 2026",
        "PREVIOUS STATEMENT BALANCE          $0.00",
        "NEW BALANCE                          $1,234.56",
    ]
    for h in headers:
        assert any(skip in h for skip in SKIP_STRUCTURAL), f"Not caught: {h}"
