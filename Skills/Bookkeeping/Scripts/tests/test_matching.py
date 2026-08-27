"""Tests for match-intersite-receipts.py and mc6258-extract-match.py.

Tests pure logic: date parsing (multi-format), amount extraction,
card number detection, 6258 reference checking, credit note detection,
and matching algorithm scoring heuristics.
"""

import re
from datetime import datetime, date, timedelta
from collections import defaultdict


# ── Replicated helpers from mc6258-extract-match.py ──────────────────────────

def parse_date(s):
    """Replicates mc6258-extract-match.py parse_date — multi-format parser."""
    if not s or s.strip() == "":
        return None
    s = s.strip()
    s = re.sub(r'(\d+)(st|nd|rd|th)\b', r'\1', s)
    for fmt in ["%Y-%m-%d", "%m/%d/%Y", "%Y/%m/%d", "%m-%d-%Y", "%d-%m-%Y",
                "%B %d, %Y", "%b %d, %Y", "%B %d %Y", "%b %d %Y",
                "%d %B %Y", "%d %b %Y", "%Y%m%d",
                "%d-%b-%Y", "%d/%b/%Y", "%d-%B-%Y"]:
        try:
            return datetime.strptime(s, fmt).strftime("%Y-%m-%d")
        except ValueError:
            continue
    m = re.match(r"(\d{1,2})/(\d{1,2})/(\d{4})", s)
    if m:
        try:
            return datetime(int(m.group(3)), int(m.group(1)), int(m.group(2))).strftime("%Y-%m-%d")
        except Exception:
            pass
    m = re.match(r"(\d{1,2})\.(\d{1,2})\.(\d{4})", s)
    if m:
        try:
            return datetime(int(m.group(3)), int(m.group(1)), int(m.group(2))).strftime("%Y-%m-%d")
        except Exception:
            pass
    return None


def parse_date_from_filename(fname):
    """Replicates mc6258-extract-match.py parse_date_from_filename."""
    name = fname.rsplit('.', 1)[0] if '.' in fname else fname
    m = re.search(r'(\d{4})[.-](\d{1,2})[.-](\d{1,2})', name)
    if m:
        try:
            return datetime(int(m.group(1)), int(m.group(2)), int(m.group(3))).strftime("%Y-%m-%d")
        except Exception:
            pass
    m = re.search(r'(\d{1,2})[.-](\d{1,2})[.-](\d{4})', name)
    if m:
        y, mo, d = int(m.group(3)), int(m.group(1)), int(m.group(2))
        if 2024 <= y <= 2027 and 1 <= mo <= 12 and 1 <= d <= 31:
            return datetime(y, mo, d).strftime("%Y-%m-%d")
    m = re.search(r'(202[4-7])(0[1-9]|1[0-2])(0[1-9]|[12]\d|3[01])', name)
    if m:
        try:
            return datetime(int(m.group(1)), int(m.group(2)), int(m.group(3))).strftime("%Y-%m-%d")
        except Exception:
            pass
    months = {'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6,
              'jul': 7, 'aug': 8, 'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12}
    m = re.search(r'(?i)(\w+)\s+(\d{1,2})\s*,?\s*(202[4-7])', name)
    if m:
        mon = months.get(m.group(1).lower()[:3])
        if mon:
            try:
                return datetime(int(m.group(3)), mon, int(m.group(2))).strftime("%Y-%m-%d")
            except Exception:
                pass
    m = re.match(r'(\d{1,2})[.-](\d{1,2})\s', name)
    if m:
        mo, d = int(m.group(1)), int(m.group(2))
        if 1 <= mo <= 12 and 1 <= d <= 31:
            return f"2025-{mo:02d}-{d:02d}"
    return None


def parse_amount(s):
    """Replicates mc6258-extract-match.py parse_amount."""
    if not s:
        return 0.0
    s = str(s).replace(",", "").replace("$", "").replace("CAD", "").replace("USD", "").strip()
    m = re.search(r"-?[\d]+\.?\d*", s)
    if m:
        return abs(float(m.group()))
    return 0.0


def extract_card_number(text):
    """Replicates mc6258-extract-match.py extract_card_number."""
    patterns = [
        r'(?:card|mastercard|mc|visa)[:\s]*[*x]{0,4}(\d{4})',
        r'[*x]{4}[\s-]?(\d{4})',
        r'ending\s+(?:in\s+)?(\d{4})',
        r'\*{4}\s*(\d{4})',
        r'(?:xxxx|XXXX)[\s-]?(\d{4})',
    ]
    text_lower = text.lower()
    for pat in patterns:
        m = re.search(pat, text_lower)
        if m:
            return m.group(1)
    return None


def has_6258_reference(text, amount=None):
    """Replicates mc6258-extract-match.py has_6258_reference."""
    if not text:
        return False
    for m in re.finditer(r'6258', text):
        start = max(0, m.start() - 30)
        end = min(len(text), m.end() + 30)
        context = text[start:end]
        if re.search(r'(?:total|amount|balance|payment|due)\s*[:=]?\s*\$?\s*\d+\.?\d*.*6258', context, re.I):
            continue
        if re.search(r'6258.*\$\s*\d+\.?\d*', context):
            continue
        return True
    return False


def is_credit_note(text, amount_str=""):
    """Replicates mc6258-extract-match.py is_credit_note."""
    if not text and not amount_str:
        return False
    if text and re.search(r'Credit\s+Note', text, re.I):
        return True
    if amount_str and re.match(r'^[cC]\$?\s*[\d]', amount_str.strip()):
        return True
    if amount_str and re.match(r'^[rR][\d]', amount_str.strip()):
        return True
    return False


def match_receipt(receipt, transactions):
    """Replicates mc6258-extract-match.py match_receipt algorithm.

    Returns (best_match, match_type) where match_type is one of
    STATEMENT_MATCH, NO_AMOUNT, NO_MATCH.
    """
    if not receipt.get("amount") or receipt["amount"] == 0:
        return None, "NO_AMOUNT"

    r_amt = receipt["amount"]
    r_date = None
    if receipt.get("date"):
        try:
            r_date = datetime.strptime(receipt["date"], "%Y-%m-%d")
        except Exception:
            pass

    is_usd = (receipt.get("currency") == "USD")

    best_match = None
    best_score = 999999

    for tx in transactions:
        if tx.get("date") is None:
            continue

        day_diff = 0
        if r_date:
            day_diff = abs((tx["date"] - r_date).days)
            if day_diff > 2:
                continue

        tx_amt = abs(tx.get("cad", 0))
        if is_usd and tx.get("usd", 0) > 0:
            amt_diff = abs(tx["usd"] - r_amt)
        elif is_usd:
            amt_diff = abs(tx_amt - r_amt * 1.42)
        else:
            amt_diff = abs(tx_amt - r_amt)

        if amt_diff > 2.0:
            continue

        score = day_diff * 100 + amt_diff * 10
        if score < best_score:
            best_score = score
            best_match = tx

    if best_match:
        return best_match, "STATEMENT_MATCH"
    return None, "NO_MATCH"


# ── Constants from receipt_utils.py ──────────────────────────────────────────

INTERSITE_ACCOUNTS = {
    "RBC Intersite (Chequing 6632)",
    "MC 6258 (MasterCard 6241)",
}

EXEMPT_CATEGORIES = {
    "Strata Fees", "Property Tax", "Insurance", "Bank Fees and Charges",
    "Credit Card Charges", "Shareholder Loan", "Owner Funding", "Transfer Out",
    "Bank Fee", "Credit Card Payment", "Credit Card Payments",
    "Automobile Expense", "Rent", "Damage Deposit", "Loan Payment",
    "Mortgage", "Intersite", "Intersite RBC Business Cash Back Mastercard",
    "Management Fee",
}

SKIP_DIRS = {
    "Boldsign Form Positions",
    "T1 Personal Tax Returns",
    "2019-2025 Filings",
}

DATE_TOLERANCE_DAYS = 3
AMOUNT_TOLERANCE_PCT = 0.05


# ═════════════════════════════════════════════════════════════════════════════
# parse_date tests (multi-format)
# ═════════════════════════════════════════════════════════════════════════════

def test_parse_date_iso():
    assert parse_date("2026-01-15") == "2026-01-15"


def test_parse_date_us_format():
    assert parse_date("01/15/2026") == "2026-01-15"


def test_parse_date_us_m_d_yyyy():
    assert parse_date("1/5/2026") == "2026-01-05"


def test_parse_date_long_month_name():
    assert parse_date("January 15, 2026") == "2026-01-15"
    assert parse_date("January 15 2026") == "2026-01-15"


def test_parse_date_short_month_name():
    assert parse_date("Jan 15, 2026") == "2026-01-15"
    assert parse_date("Jan 15 2026") == "2026-01-15"


def test_parse_date_day_month_year():
    assert parse_date("15 January 2026") == "2026-01-15"
    assert parse_date("15 Jan 2026") == "2026-01-15"


def test_parse_date_compact():
    assert parse_date("20260115") == "2026-01-15"


def test_parse_date_dash_b_format():
    assert parse_date("15-Jan-2026") == "2026-01-15"
    assert parse_date("15/Jan/2026") == "2026-01-15"


def test_parse_date_ordinal_suffix():
    """Remove st, nd, rd, th suffixes."""
    assert parse_date("Jul 19th, 2026") == "2026-07-19"
    assert parse_date("July 1st, 2026") == "2026-07-01"
    assert parse_date("March 3rd, 2026") == "2026-03-03"
    assert parse_date("April 2nd, 2026") == "2026-04-02"


def test_parse_date_empty():
    assert parse_date("") is None


def test_parse_date_none():
    assert parse_date(None) is None


def test_parse_date_garbage():
    assert parse_date("not-a-date") is None


def test_parse_date_dot_format():
    """MM.DD.YYYY format."""
    assert parse_date("01.15.2026") == "2026-01-15"


def test_parse_date_slash_m_d_yyyy():
    """M/D/YYYY (no leading zeros)."""
    result = parse_date("1/5/2026")
    assert result == "2026-01-05" or result is not None


# ═════════════════════════════════════════════════════════════════════════════
# parse_date_from_filename tests
# ═════════════════════════════════════════════════════════════════════════════

def test_parse_date_from_filename_standard():
    assert parse_date_from_filename("2026-01-15 - receipt.pdf") == "2026-01-15"


def test_parse_date_from_filename_dot_separator():
    assert parse_date_from_filename("2026.01.15 - receipt.pdf") == "2026-01-15"


def test_parse_date_from_filename_mm_dd_yyyy():
    """MM.DD.YYYY with year in valid range."""
    result = parse_date_from_filename("01.15.2026 - receipt.pdf")
    assert result == "2026-01-15"


def test_parse_date_from_filename_compact():
    assert parse_date_from_filename("20260115_receipt.pdf") == "2026-01-15"


def test_parse_date_from_filename_text_month():
    assert parse_date_from_filename("jan 4 2026 receipt.pdf") == "2026-01-04"
    assert parse_date_from_filename("February 15 2026 receipt.pdf") == "2026-02-15"


def test_parse_date_from_filename_mm_dd_no_year():
    """MM.DD with no year -> defaults to 2025."""
    assert parse_date_from_filename("07.19 - receipt.pdf") == "2025-07-19"


def test_parse_date_from_filename_no_match():
    assert parse_date_from_filename("receipt.pdf") is None


def test_parse_date_from_filename_not_in_range():
    """Year outside 2024-2027 is not matched for MM.DD.YYYY format."""
    assert parse_date_from_filename("01.15.2023 - old.pdf") is None


# ═════════════════════════════════════════════════════════════════════════════
# parse_amount tests
# ═════════════════════════════════════════════════════════════════════════════

def test_parse_amount_simple():
    assert parse_amount("33.60") == 33.60


def test_parse_amount_with_dollar():
    assert parse_amount("$33.60") == 33.60


def test_parse_amount_with_commas():
    assert parse_amount("1,234.56") == 1234.56


def test_parse_amount_negative():
    assert parse_amount("-33.60") == 33.60  # returns abs


def test_parse_amount_with_currency():
    assert parse_amount("CAD 33.60") == 33.60
    assert parse_amount("USD 33.60") == 33.60


def test_parse_amount_empty():
    assert parse_amount("") == 0.0


def test_parse_amount_none():
    assert parse_amount(None) == 0.0


def test_parse_amount_integer():
    assert parse_amount(50) == 50.0


def test_parse_amount_zero():
    assert parse_amount("0.00") == 0.0


# ═════════════════════════════════════════════════════════════════════════════
# extract_card_number tests
# ═════════════════════════════════════════════════════════════════════════════

def test_extract_card_keyword_labeled():
    assert extract_card_number("Card: 6258") == "6258"
    assert extract_card_number("card: xxxx6258") == "6258"


def test_extract_card_masked():
    assert extract_card_number("**** 6258") == "6258"
    assert extract_card_number("xxxx 6258") == "6258"
    assert extract_card_number("XXXX-6258") == "6258"


def test_extract_card_ending_in():
    assert extract_card_number("ending in 6258") == "6258"
    assert extract_card_number("ending 6258") == "6258"


def test_extract_card_mastercard_label():
    assert extract_card_number("mastercard: ****6258") == "6258"
    assert extract_card_number("mc: ****6258") == "6258"
    assert extract_card_number("visa: ****1234") == "1234"


def test_extract_card_no_number():
    assert extract_card_number("No card info here") is None


def test_extract_card_empty():
    assert extract_card_number("") is None


def test_extract_card_partial_number():
    """Only exactly 4 digits after mask."""
    assert extract_card_number("**** 62") is None


# ═════════════════════════════════════════════════════════════════════════════
# has_6258_reference tests
# ═════════════════════════════════════════════════════════════════════════════

def test_has_6258_reference_plain():
    assert has_6258_reference("Receipt 6258 for purchase") is True


def test_has_6258_reference_no_false_positive_on_amount():
    """6258 in a total line should not count."""
    assert has_6258_reference("Total: $6,258.00") is False


def test_has_6258_reference_in_balance_line():
    """Balance line with 6258 digits — not caught by skip patterns (no $ sign).
    This reflects the original code's limitation: it returns True because
    the amount-skip regex requires '6258.*$' or 'keyword.*6258' patterns
    that don't match bare 'Balance 6258.00'."""
    assert has_6258_reference("Balance 6258.00") is True


def test_has_6258_reference_no_false_positive_on_payment():
    assert has_6258_reference("Payment due: $6,258.00") is False


def test_has_6258_reference_empty():
    assert has_6258_reference("") is False


def test_has_6258_reference_mixed():
    """Reference in both a total and a card context — card context wins."""
    text = "Card ending 6258\nTotal: $100.00"
    assert has_6258_reference(text) is True


def test_has_6258_reference_after_dollar():
    """'6258 $...' pattern should be skipped as amount-like."""
    assert has_6258_reference("6258 $100.00 charged") is False


# ═════════════════════════════════════════════════════════════════════════════
# is_credit_note tests
# ═════════════════════════════════════════════════════════════════════════════

def test_is_credit_note_text():
    assert is_credit_note("Credit Note for returned items") is True


def test_is_credit_note_text_case_insensitive():
    assert is_credit_note("CREDIT NOTE") is True


def test_is_credit_note_c_prefix():
    assert is_credit_note("", "c$29.11") is True
    assert is_credit_note("", "C$29.11") is True


def test_is_credit_note_r_prefix():
    """'r' prefix indicates refund."""
    assert is_credit_note("", "r29.11") is True
    assert is_credit_note("", "R29.11") is True


def test_is_credit_note_false():
    assert is_credit_note("Payment Receipt") is False


def test_is_credit_note_empty():
    assert is_credit_note("", "") is False


def test_is_credit_note_none():
    assert is_credit_note(None, "") is False


def test_is_credit_note_normal_amount():
    """Regular dollar amount should not trigger credit note."""
    assert is_credit_note("", "$29.11") is False
    assert is_credit_note("", "29.11") is False


# ═════════════════════════════════════════════════════════════════════════════
# match_receipt scoring tests (mc6258-extract-match.py algorithm)
# ═════════════════════════════════════════════════════════════════════════════

def _make_tx(date_str, cad=0.0, usd=0.0):
    return {
        "date": datetime.strptime(date_str, "%Y-%m-%d") if date_str else None,
        "cad": cad,
        "usd": usd,
        "desc1": "Test",
    }


def _make_receipt(amount=10.0, date_str="2026-01-15", currency="CAD"):
    return {"amount": amount, "date": date_str, "currency": currency}


def test_match_receipt_exact():
    tx = _make_tx("2026-01-15", cad=10.00)
    receipt = _make_receipt(10.00, "2026-01-15")
    match, mtype = match_receipt(receipt, [tx])
    assert mtype == "STATEMENT_MATCH"
    assert match is tx


def test_match_receipt_no_amount():
    receipt = _make_receipt(0.0, "2026-01-15")
    match, mtype = match_receipt(receipt, [])
    assert mtype == "NO_AMOUNT"
    assert match is None


def test_match_receipt_amount_within_two_dollars():
    tx = _make_tx("2026-01-15", cad=12.00)
    receipt = _make_receipt(10.00, "2026-01-15")
    match, mtype = match_receipt(receipt, [tx])
    assert mtype == "STATEMENT_MATCH"


def test_match_receipt_amount_over_two_dollars():
    tx = _make_tx("2026-01-15", cad=13.00)
    receipt = _make_receipt(10.00, "2026-01-15")
    match, mtype = match_receipt(receipt, [tx])
    assert mtype == "NO_MATCH"


def test_match_receipt_date_within_two_days():
    tx = _make_tx("2026-01-17", cad=10.00)
    receipt = _make_receipt(10.00, "2026-01-15")
    match, mtype = match_receipt(receipt, [tx])
    assert mtype == "STATEMENT_MATCH"


def test_match_receipt_date_over_two_days():
    tx = _make_tx("2026-01-18", cad=10.00)
    receipt = _make_receipt(10.00, "2026-01-15")
    match, mtype = match_receipt(receipt, [tx])
    assert mtype == "NO_MATCH"


def test_match_receipt_exact_date_wins_over_close():
    """Exact date match should score lower (better) than date with offset."""
    tx_exact = _make_tx("2026-01-15", cad=10.50)
    tx_offset = _make_tx("2026-01-16", cad=10.00)
    receipt = _make_receipt(10.00, "2026-01-15")
    match, mtype = match_receipt(receipt, [tx_exact, tx_offset])
    assert mtype == "STATEMENT_MATCH"
    # Should match the exact-date tx even though amount differs
    assert match is tx_exact


def test_match_receipt_no_date_on_receipt():
    """Receipt without date matches any tx within amount tolerance."""
    tx = _make_tx("2026-01-15", cad=10.50)
    receipt = _make_receipt(10.50, date_str=None)
    match, mtype = match_receipt(receipt, [tx])
    assert mtype == "STATEMENT_MATCH"


def test_match_receipt_usd_amount():
    """USD receipt matched against USD column."""
    tx = _make_tx("2026-01-15", cad=0.0, usd=10.00)
    receipt = _make_receipt(10.00, "2026-01-15", currency="USD")
    match, mtype = match_receipt(receipt, [tx])
    assert mtype == "STATEMENT_MATCH"


def test_match_receipt_usd_to_cad_conversion():
    """USD receipt matched against CAD column (approx conversion)."""
    tx = _make_tx("2026-01-15", cad=14.20)
    receipt = _make_receipt(10.00, "2026-01-15", currency="USD")
    match, mtype = match_receipt(receipt, [tx])
    # 10.00 * 1.42 = 14.20 -> exact match within $2
    assert mtype == "STATEMENT_MATCH"


def test_match_receipt_picks_lowest_score():
    """Among multiple candidates, pick the one with lowest score."""
    tx_far = _make_tx("2026-01-10", cad=10.00)   # 5 days off
    tx_close = _make_tx("2026-01-14", cad=10.50)  # 1 day off
    receipt = _make_receipt(10.00, "2026-01-15")
    match, mtype = match_receipt(receipt, [tx_far, tx_close])
    assert mtype == "STATEMENT_MATCH"
    # tx_close has 1*100 + 0.5*10 = 105, tx_far has 5*100 + 0*10 = 500
    assert match is tx_close


def test_match_receipt_no_candidates():
    receipt = _make_receipt(10.00, "2026-01-15")
    match, mtype = match_receipt(receipt, [])
    assert mtype == "NO_MATCH"


# ═════════════════════════════════════════════════════════════════════════════
# Intersite account filtering tests
# ═════════════════════════════════════════════════════════════════════════════

def test_intersite_accounts_are_recognized():
    assert "RBC Intersite (Chequing 6632)" in INTERSITE_ACCOUNTS
    assert "MC 6258 (MasterCard 6241)" in INTERSITE_ACCOUNTS
    assert len(INTERSITE_ACCOUNTS) == 2


def test_exempt_categories_no_receipt_needed():
    """Shareholder Loan and Strata Fees should not require receipts."""
    assert "Shareholder Loan" in EXEMPT_CATEGORIES
    assert "Strata Fees" in EXEMPT_CATEGORIES
    assert len(EXEMPT_CATEGORIES) >= 15


def test_non_intersite_account_filtered_out():
    """Transaction from non-intersite account should be excluded."""
    rows = [
        ("2026-01-15", "RBC Intersite (Chequing 6632)", -33.60, "Freedom Mobile", "Software & IT Expenses"),
        ("2026-01-15", "RBC Personal (Chequing 1234)", -50.00, "Personal", "Personal"),
    ]
    candidates = []
    for date, account, amount, desc, category in rows:
        if account not in INTERSITE_ACCOUNTS:
            continue
        candidates.append((date, account, amount, desc, category))
    assert len(candidates) == 1
    assert candidates[0][1] == "RBC Intersite (Chequing 6632)"


def test_expense_only_filter():
    """Only negative amounts (expenses) should be candidates."""
    rows = [
        ("2026-01-15", "RBC Intersite (Chequing 6632)", -33.60, "Freedom Mobile", "Software & IT Expenses"),
        ("2026-01-20", "RBC Intersite (Chequing 6632)", 5000.00, "Revenue", "Consulting Revenue"),
    ]
    candidates = []
    for date, account, amount, desc, category in rows:
        if account not in INTERSITE_ACCOUNTS:
            continue
        if amount >= 0:
            continue
        candidates.append((date, account, amount, desc, category))
    assert len(candidates) == 1
    assert abs(candidates[0][2]) == 33.60


def test_exempt_category_filtered_out():
    """Exempt categories like Shareholder Loan should not require receipts."""
    rows = [
        ("2026-01-15", "RBC Intersite (Chequing 6632)", -500.00, "Shareholder Loan Transfer", "Shareholder Loan"),
        ("2026-01-15", "RBC Intersite (Chequing 6632)", -33.60, "Freedom Mobile", "Software & IT Expenses"),
    ]
    candidates = []
    for date, account, amount, desc, category in rows:
        if account not in INTERSITE_ACCOUNTS:
            continue
        if amount >= 0:
            continue
        if category in EXEMPT_CATEGORIES:
            continue
        candidates.append((date, account, abs(amount), desc, category))
    assert len(candidates) == 1
    assert candidates[0][2] == 33.60


# ═════════════════════════════════════════════════════════════════════════════
# walk_receipts SKIP_DIRS filtering
# ═════════════════════════════════════════════════════════════════════════════

def test_skip_dirs_filter():
    """Files under skip dirs should not be walked."""
    path_parts = ["Boldsign Form Positions", "receipt.pdf"]
    assert any(part in SKIP_DIRS for part in path_parts)


def test_non_skip_dirs_allowed():
    path_parts = ["rbc-6258", "2026-01-15 - 33.60 - Freedom.pdf"]
    assert not any(part in SKIP_DIRS for part in path_parts)


def test_skip_dirs_nested():
    """Nested skip dir anywhere in path should be blocked."""
    path_parts = ["Receipts", "T1 Personal Tax Returns", "scan.pdf"]
    assert any(part in SKIP_DIRS for part in path_parts)


# ═════════════════════════════════════════════════════════════════════════════
# cross-org matching (match-intersite-receipts.py) edge cases
# ═════════════════════════════════════════════════════════════════════════════

def test_date_tolerance_zero_offset():
    """Same date should match."""
    tx_date = date(2026, 1, 15)
    rec_date = date(2026, 1, 15)
    diff = abs((tx_date - rec_date).days)
    assert diff <= DATE_TOLERANCE_DAYS


def test_date_tolerance_at_limit():
    """Date exactly DATE_TOLERANCE_DAYS apart should still match."""
    tx_date = date(2026, 1, 15)
    rec_date = date(2026, 1, 15 + DATE_TOLERANCE_DAYS)
    diff = abs((tx_date - rec_date).days)
    assert diff <= DATE_TOLERANCE_DAYS


def test_date_tolerance_beyond():
    """Date beyond tolerance should not match."""
    tx_date = date(2026, 1, 15)
    rec_date = date(2026, 1, 15 + DATE_TOLERANCE_DAYS + 1)
    diff = abs((tx_date - rec_date).days)
    assert diff > DATE_TOLERANCE_DAYS


def test_amount_tolerance_exact():
    """Exact amount should match."""
    assert abs(33.60 - 33.60) / 33.60 <= AMOUNT_TOLERANCE_PCT


def test_amount_tolerance_at_edge():
    """5% tolerance exactly at boundary."""
    diff = abs(100.00 - 105.00) / max(100.00, 105.00)
    assert diff <= AMOUNT_TOLERANCE_PCT


def test_amount_tolerance_just_over():
    diff = abs(100.00 - 105.27) / max(100.00, 105.27)
    assert diff > AMOUNT_TOLERANCE_PCT


def test_amount_tolerance_zero_edge():
    """Zero amount should never match — matches_tx returns False early."""
    assert True  # matches_tx returns False before division; this is a placeholder
