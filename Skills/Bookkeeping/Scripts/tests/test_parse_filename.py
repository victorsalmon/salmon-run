"""Tests for receipt filename parsing and matching logic."""

from receipt_utils import parse_filename_meta, matches_tx, vendor_plausible


def test_standard_date_amt_vendor():
    """2025-04-09 - 33.60 - Freedom Mobile.pdf"""
    meta = parse_filename_meta("2025-04-09 - 33.60 - Freedom Mobile.pdf")
    assert meta is not None
    assert meta["date"] == "2025-04-09"
    assert meta["amount"] == 33.60
    assert meta["vendor"] == "Freedom Mobile"


def test_account_prefix():
    """rbc-6258~2025-04-09 - 10.00 - Kilo Code.pdf"""
    meta = parse_filename_meta("rbc-6258~2025-04-09 - 10.00 - Kilo Code.pdf")
    assert meta is not None
    assert meta["date"] == "2025-04-09"
    assert meta["amount"] == 10.00
    assert meta["vendor"] == "Kilo Code"


def test_large_amount_with_comma():
    """2025-09-16 - 654.00 - Intersite Consulting Inc. (704730...).pdf"""
    meta = parse_filename_meta("2025-09-16 - 654.00 - Intersite Consulting Inc. (704730...).pdf")
    assert meta is not None
    assert meta["amount"] == 654.00
    assert "Intersite" in meta["vendor"]


def test_underscore_separators():
    """2026-01-12_-_183.75_-_Intersite_Consulting_Services.jpg"""
    meta = parse_filename_meta("2026-01-12_-_183.75_-_Intersite_Consulting_Services.jpg")
    assert meta is not None
    assert meta["amount"] == 183.75
    assert meta["vendor"] == "Intersite Consulting Services"


def test_underscore_date():
    """2025_04_09 - 33.60 - Freedom Mobile.pdf"""
    meta = parse_filename_meta("2025_04_09 - 33.60 - Freedom Mobile.pdf")
    assert meta is not None
    assert meta["date"] == "2025-04-09"


def test_no_date_in_filename():
    """receipt.jpg"""
    meta = parse_filename_meta("receipt.jpg")
    assert meta is None


def test_unknown_vendor_no_amount():
    """2025-04-09 - Unknown Vendor.pdf (no decimal in tail)"""
    meta = parse_filename_meta("2025-04-09 - Unknown Vendor.pdf")
    assert meta is None


def test_zero_amount_unknown():
    """2025-04-09 - 0.00 - Unknown.pdf"""
    meta = parse_filename_meta("2025-04-09 - 0.00 - Unknown.pdf")
    assert meta is not None
    assert meta["amount"] == 0.00
    assert meta["vendor"] == "Unknown"


def test_camera_filename_no_match():
    """IMG_20250409_123456.jpg — date pattern wrong (not YYYY-MM-DD)"""
    meta = parse_filename_meta("IMG_20250409_123456.jpg")
    assert meta is None


def test_thousands_separator():
    """2025-04-09 - 1,234.56 - Amazon.ca.pdf"""
    meta = parse_filename_meta("2025-04-09 - 1,234.56 - Amazon.ca.pdf")
    assert meta is not None
    assert meta["amount"] == 1234.56
    assert meta["vendor"] == "Amazon.ca"


def test_no_vendor_after_amount():
    """2025-04-09 - 10.00.pdf"""
    meta = parse_filename_meta("2025-04-09 - 10.00.pdf")
    assert meta is not None
    assert meta["amount"] == 10.00
    assert meta["vendor"] == ""


def test_double_extension():
    """2025-04-09 - 33.60 - Vendor.pdf.jpg"""
    meta = parse_filename_meta("2025-04-09 - 33.60 - Vendor.pdf.jpg")
    assert meta is not None
    assert meta["amount"] == 33.60
    assert meta["vendor"] == "Vendor"


def test_unknown_date_prefix():
    """unknown-date - 0.00 - Unknown"""
    meta = parse_filename_meta("unknown-date - 0.00 - Unknown")
    assert meta is None


def test_rbc_prefix():
    """RBC-2025-04-09 - 100.00 - Interac e-Transfer.pdf"""
    meta = parse_filename_meta("RBC-2025-04-09 - 100.00 - Interac e-Transfer.pdf")
    assert meta is not None
    assert meta["date"] == "2025-04-09"
    assert meta["amount"] == 100.00


def test_amazon_vendor():
    """2025-04-09 - 33.60 - Amazon.ca.pdf"""
    meta = parse_filename_meta("2025-04-09 - 33.60 - Amazon.ca.pdf")
    assert meta is not None
    assert meta["vendor"] == "Amazon.ca"


# ── matches_tx tests ──────────────────────────────────────────────────────

def test_amount_exact_match():
    assert matches_tx(33.60, 33.60) is True


def test_amount_within_tolerance():
    assert matches_tx(100.00, 105.00) is True


def test_amount_just_over_tolerance():
    assert matches_tx(100.00, 105.27) is False


def test_amount_zero_edge_case():
    assert matches_tx(0.0, 33.60) is False


def test_amount_both_zero():
    assert matches_tx(0.0, 0.0) is False


def test_amount_negative():
    assert matches_tx(-100.00, 105.00) is False


def test_amount_both_negative_outside_tolerance():
    # Refunds/credits: both negative, well outside 5% — must NOT match.
    assert matches_tx(-5.00, -10.00) is False


def test_amount_both_negative_within_tolerance():
    # Two negative amounts within 5% of the larger magnitude DO match.
    assert matches_tx(-100.00, -105.00) is True


# ── vendor_plausible tests ────────────────────────────────────────────────

def test_known_vendor_matching_category():
    assert vendor_plausible("Software & IT Expenses", "OpenRouter API") is True


def test_known_vendor_wrong_category():
    assert vendor_plausible("Automobile Expense", "OpenRouter API") is False


def test_unknown_vendor():
    assert vendor_plausible("Office & General Expenses", "RandomStore") is False


def test_amazon_any_category():
    assert vendor_plausible("Office & General Expenses", "Amazon.ca") is True
    assert vendor_plausible("Software & IT Expenses", "Amazon.ca") is True
    assert vendor_plausible("Repairs and Maintenance", "Amazon.ca") is True
