"""Tests for dedup-nonmatching.py and deduplicate-manifest.py.

Tests pure logic: SHA256 comparison, filename date/amount parsing,
triple-match condition, manifest row selection heuristics.
"""

import hashlib
import re


# ── Replicated helpers from dedup-nonmatching.py ─────────────────────────────

DATE_RE = re.compile(r"^(20\d{2})[-_](\d{2})[-_](\d{2})")
AMT_RE = re.compile(r"(\d{1,4}(?:\.\d{2})?)")


def sha256_of_bytes(data: bytes) -> str:
    """Replicates dedup-nonmatching.py sha256_of for in-memory data."""
    return hashlib.sha256(data).hexdigest()


def parse_canonical_date_amt(canonical: str):
    """Replicates dedup-nonmatching.py parse_canonical_date_amt."""
    if "\\" in canonical or "/" in canonical:
        canonical = canonical.replace("\\", "/").rsplit("/", 1)[-1]
    stem = canonical
    for ext in (".pdf", ".jpg", ".jpeg", ".png"):
        if stem.lower().endswith(ext):
            stem = stem[: -len(ext)]
            break
    if stem.lower().startswith("unknown"):
        return None, None
    m = DATE_RE.match(stem)
    if not m:
        return None, None
    date_iso = f"{m.group(1)}-{m.group(2)}-{m.group(3)}"
    rest = stem[m.end():].lstrip(" -_")
    a = AMT_RE.match(rest)
    amount_str = a.group(1) if a else None
    return date_iso, amount_str


def parse_filename_date_amt(filename: str):
    """Replicates dedup-nonmatching.py parse_filename_date_amt."""
    stem = filename
    for ext in (".pdf", ".jpg", ".jpeg", ".png"):
        if stem.lower().endswith(ext):
            stem = stem[: -len(ext)]
            break
    if stem.lower().startswith("unknown"):
        return None, None
    m = DATE_RE.match(stem)
    if not m:
        return None, None
    date_iso = f"{m.group(1)}-{m.group(2)}-{m.group(3)}"
    rest = stem[m.end():].lstrip(" -_")
    a = AMT_RE.match(rest)
    amount_str = a.group(1) if a else None
    return date_iso, amount_str


def canonical_to_filename(canonical: str) -> str:
    """Replicates dedup-nonmatching.py canonical_to_filename."""
    if "\\" in canonical or "/" in canonical:
        return canonical.replace("\\", "/").rsplit("/", 1)[-1]
    return canonical


# ── Replicated helpers from deduplicate-manifest.py ──────────────────────────

def _row_is_newer(a: dict, b: dict) -> bool:
    """Replicates deduplicate-manifest.py _row_is_newer."""
    for field in ('LastModified', 'Modified', 'Date'):
        va = a.get(field, '')
        vb = b.get(field, '')
        if va and vb:
            return va >= vb
    return True


def _prefer_non_vendu(indices, rows):
    """Replicates deduplicate-manifest.py _prefer_non_vendu."""
    non_vendu = None
    for i in indices:
        vendor = rows[i].get('Vendor', rows[i].get('vendor', '')).lower()
        if 'vendu par' not in vendor:
            non_vendu = i
            break
    return non_vendu if non_vendu is not None else indices[0]


# ── Triple-match condition logic ──────────────────────────────────────────────

def _triple_match(hash_a: str, hash_b: str, date_a: str, date_b: str,
                  amount_a: str, amount_b: str) -> bool:
    """Same hash AND same date AND same amount -> duplicate."""
    return (hash_a == hash_b and date_a == date_b and amount_a == amount_b)


def _can_dedup_group(hash_val: str, manifest_entry: dict | None,
                     files: list) -> dict | None:
    """Determine if a group of files with same hash can be deduped.

    Returns dict with decision info, or None if can't dedup.
    """
    if manifest_entry is None:
        return None
    canonical = manifest_entry.get("filename", "")
    date_iso, amt_str = parse_canonical_date_amt(canonical)
    if date_iso is None or amt_str is None:
        return None
    return {
        "hash": hash_val,
        "date": date_iso,
        "amount": amt_str,
        "canonical": canonical,
        "file_count": len(files),
    }


# ═════════════════════════════════════════════════════════════════════════════
# SHA256 comparison tests
# ═════════════════════════════════════════════════════════════════════════════

def test_sha256_same_content():
    data = b"Hello, World!"
    assert sha256_of_bytes(data) == sha256_of_bytes(data)


def test_sha256_different_content():
    assert sha256_of_bytes(b"foo") != sha256_of_bytes(b"bar")


def test_sha256_length():
    h = sha256_of_bytes(b"test")
    assert len(h) == 64
    assert all(c in '0123456789abcdef' for c in h)


def test_sha256_empty_content():
    h = sha256_of_bytes(b"")
    # Known SHA-256 of empty string
    assert h == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"


def test_sha256_deterministic():
    assert sha256_of_bytes(b"consistent") == sha256_of_bytes(b"consistent")


# ═════════════════════════════════════════════════════════════════════════════
# Triple-match condition tests
# ═════════════════════════════════════════════════════════════════════════════

def test_triple_match_all_match():
    h = "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890"
    assert _triple_match(h, h, "2026-01-15", "2026-01-15", "33.60", "33.60") is True


def test_triple_match_diff_hash():
    h1 = "a" * 64
    h2 = "b" * 64
    assert _triple_match(h1, h2, "2026-01-15", "2026-01-15", "33.60", "33.60") is False


def test_triple_match_diff_date():
    h = "a" * 64
    assert _triple_match(h, h, "2026-01-15", "2026-01-16", "33.60", "33.60") is False


def test_triple_match_diff_amount():
    h = "a" * 64
    assert _triple_match(h, h, "2026-01-15", "2026-01-15", "33.60", "45.00") is False


def test_triple_match_empty_hash():
    assert _triple_match("", "", "2026-01-15", "2026-01-15", "33.60", "33.60") is True


def test_triple_match_empty_date():
    h = "a" * 64
    assert _triple_match(h, h, "", "2026-01-15", "33.60", "33.60") is False


def test_triple_match_zero_amount():
    h = "a" * 64
    assert _triple_match(h, h, "2026-01-15", "2026-01-15", "0.00", "0.00") is True


def test_triple_match_missing_date_against_present():
    """Missing date in one entry means they don't match."""
    h = "a" * 64
    assert _triple_match(h, h, "", "", "33.60", "33.60") is True


# ═════════════════════════════════════════════════════════════════════════════
# parse_canonical_date_amt tests
# ═════════════════════════════════════════════════════════════════════════════

def test_parse_canonical_standard():
    date_iso, amt = parse_canonical_date_amt("2025-03-01 - 33.60 - Freedom Mobile.pdf")
    assert date_iso == "2025-03-01"
    assert amt == "33.60"


def test_parse_canonical_with_folder():
    date_iso, amt = parse_canonical_date_amt(
        "non-matching\\2025-07-31 - 11.19 - Lines One.pdf"
    )
    assert date_iso == "2025-07-31"
    assert amt == "11.19"


def test_parse_canonical_unknown_date():
    assert parse_canonical_date_amt("unknown-date - 0.00 - Unknown.pdf") == (None, None)


def test_parse_canonical_no_date():
    assert parse_canonical_date_amt("receipt.pdf") == (None, None)


def test_parse_canonical_no_amount():
    date_iso, amt = parse_canonical_date_amt("2025-03-01 - NoAmount.pdf")
    assert date_iso == "2025-03-01"
    assert amt is None


def test_parse_canonical_jpg_extension():
    date_iso, amt = parse_canonical_date_amt("2025-06-15 - 45.00 - Netflix.jpg")
    assert date_iso == "2025-06-15"
    assert amt == "45.00"


def test_parse_canonical_png_extension():
    date_iso, amt = parse_canonical_date_amt("2025-06-15 - 45.00 - Netflix.png")
    assert date_iso == "2025-06-15"
    assert amt == "45.00"


def test_parse_canonical_underscore_date():
    date_iso, amt = parse_canonical_date_amt("2025_06_15 - 45.00 - Netflix.pdf")
    assert date_iso == "2025-06-15"
    assert amt == "45.00"


def test_parse_canonical_strips_unknown_prefix():
    assert parse_canonical_date_amt("unknown - 0.00 - foo.pdf") == (None, None)


def test_parse_canonical_unknown_prefix_capitalized():
    assert parse_canonical_date_amt("Unknown-date - 0.00 - foo.pdf") == (None, None)


# ═════════════════════════════════════════════════════════════════════════════
# parse_filename_date_amt tests
# ═════════════════════════════════════════════════════════════════════════════

def test_parse_filename_standard():
    d, a = parse_filename_date_amt("2025-03-01 - 33.60 - Freedom Mobile.pdf")
    assert d == "2025-03-01"
    assert a == "33.60"


def test_parse_filename_no_ext():
    d, a = parse_filename_date_amt("2025-03-01 - 33.60 - Freedom Mobile")
    assert d == "2025-03-01"
    assert a == "33.60"


def test_parse_filename_unknown_prefix():
    assert parse_filename_date_amt("unknown-date - 0.00 - Unknown.pdf") == (None, None)


def test_parse_filename_non_standard_format():
    d, a = parse_filename_date_amt("2025_03_01_-_33.60_-_Freedom_Mobile.pdf")
    assert d == "2025-03-01"
    assert a == "33.60"


def test_parse_filename_no_amount():
    d, a = parse_filename_date_amt("2025-03-01 - Vendor.pdf")
    assert d == "2025-03-01"
    assert a is None


def test_parse_filename_no_date():
    assert parse_filename_date_amt("receipt.pdf") == (None, None)


def test_parse_filename_matches_canonical():
    """Identical filename should produce identical results from both parsers."""
    name = "2025-06-01 - 12.99 - OpenRouter.pdf"
    d1, a1 = parse_canonical_date_amt(name)
    d2, a2 = parse_filename_date_amt(name)
    assert d1 == d2
    assert a1 == a2


# ═════════════════════════════════════════════════════════════════════════════
# canonical_to_filename tests
# ═════════════════════════════════════════════════════════════════════════════

def test_canonical_to_filename_windows():
    result = canonical_to_filename("non-matching\\2025-07-31 - 11.19 - Test.pdf")
    assert result == "2025-07-31 - 11.19 - Test.pdf"


def test_canonical_to_filename_unix():
    result = canonical_to_filename("non-matching/2025-07-31 - 11.19 - Test.pdf")
    assert result == "2025-07-31 - 11.19 - Test.pdf"


def test_canonical_to_filename_no_prefix():
    result = canonical_to_filename("2025-07-31 - 11.19 - Test.pdf")
    assert result == "2025-07-31 - 11.19 - Test.pdf"


def test_canonical_to_filename_mixed_separators():
    result = canonical_to_filename("rbc-6258\\2025-07-31 - 11.19 - Test.pdf")
    assert result == "2025-07-31 - 11.19 - Test.pdf"


def test_canonical_to_filename_only_basename():
    result = canonical_to_filename("receipt.pdf")
    assert result == "receipt.pdf"


# ═════════════════════════════════════════════════════════════════════════════
# _can_dedup_group tests
# ═════════════════════════════════════════════════════════════════════════════

def test_dedup_group_valid():
    manifest = {"filename": "2025-03-01 - 33.60 - Freedom.pdf", "vendor": "Freedom"}
    result = _can_dedup_group("abc123", manifest, ["f1.pdf", "f2.pdf"])
    assert result is not None
    assert result["date"] == "2025-03-01"
    assert result["amount"] == "33.60"
    assert result["file_count"] == 2


def test_dedup_group_no_manifest():
    assert _can_dedup_group("abc123", None, ["f1.pdf", "f2.pdf"]) is None


def test_dedup_group_unknown_date():
    manifest = {"filename": "unknown-date - 0.00 - Unknown.pdf", "vendor": "Unknown"}
    assert _can_dedup_group("abc123", manifest, ["f1.pdf", "f2.pdf"]) is None


def test_dedup_group_single_file():
    """A group of 1 file is not a duplicate, but logic should still handle it."""
    manifest = {"filename": "2025-03-01 - 33.60 - Freedom.pdf", "vendor": "Freedom"}
    result = _can_dedup_group("abc123", manifest, ["f1.pdf"])
    assert result is not None
    assert result["file_count"] == 1


# ═════════════════════════════════════════════════════════════════════════════
# _row_is_newer tests (deduplicate-manifest.py)
# ═════════════════════════════════════════════════════════════════════════════

def test_row_is_newer_lastmodified():
    older = {"LastModified": "2025-01-01", "Vendor": "Amazon"}
    newer = {"LastModified": "2025-06-01", "Vendor": "Amazon"}
    assert _row_is_newer(newer, older) is True
    assert _row_is_newer(older, newer) is False


def test_row_is_newer_modified_field():
    older = {"Modified": "2025-01-01"}
    newer = {"Modified": "2025-06-01"}
    assert _row_is_newer(newer, older) is True


def test_row_is_newer_date_field():
    older = {"Date": "2025-01-01"}
    newer = {"Date": "2025-06-01"}
    assert _row_is_newer(newer, older) is True


def test_row_is_newer_equal_dates():
    a = {"LastModified": "2025-06-01"}
    b = {"LastModified": "2025-06-01"}
    assert _row_is_newer(a, b) is True


def test_row_is_newer_no_date_fields():
    a = {"Vendor": "Amazon"}
    b = {"Vendor": "Amazon"}
    assert _row_is_newer(a, b) is True


def test_row_is_newer_first_field_wins():
    """LastModified takes priority over Modified."""
    a = {"LastModified": "2025-06-01", "Modified": "2025-01-01"}
    b = {"LastModified": "2025-01-01", "Modified": "2025-06-01"}
    assert _row_is_newer(a, b) is True


def test_row_is_newer_missing_date_on_one():
    a = {"Vendor": "Amazon"}
    b = {"LastModified": "2025-06-01"}
    # a has no date -> fall back to next field; both have no date -> return True
    assert _row_is_newer(a, b) is True


# ═════════════════════════════════════════════════════════════════════════════
# _prefer_non_vendu tests (deduplicate-manifest.py)
# ═════════════════════════════════════════════════════════════════════════════

def test_prefer_non_vendu():
    rows = [
        {"Vendor": "Vendu par Amazon.ca"},
        {"Vendor": "Amazon.ca"},
    ]
    result = _prefer_non_vendu([0, 1], rows)
    assert result == 1


def test_prefer_non_vendu_vendor_field():
    rows = [
        {"vendor": "vendu par amazon"},
        {"vendor": "Amazon.ca"},
    ]
    result = _prefer_non_vendu([0, 1], rows)
    assert result == 1


def test_prefer_non_vendu_all_vendu():
    rows = [
        {"Vendor": "Vendu par Amazon.ca"},
        {"Vendor": "Vendu par Shopify"},
    ]
    result = _prefer_non_vendu([0, 1], rows)
    assert result == 0  # falls back to first


def test_prefer_non_vendu_no_vendu():
    rows = [
        {"Vendor": "Amazon.ca"},
        {"Vendor": "Shopify"},
    ]
    result = _prefer_non_vendu([0, 1], rows)
    assert result == 0


def test_prefer_non_vendu_single_row():
    rows = [{"Vendor": "Vendu par Amazon.ca"}]
    result = _prefer_non_vendu([0], rows)
    assert result == 0


def test_prefer_non_vendu_no_vendor_key():
    rows = [
        {"Name": "Amazon"},
        {"Name": "Shopify"},
    ]
    result = _prefer_non_vendu([0, 1], rows)
    assert result == 0  # empty string doesn't contain 'vendu par'


def test_prefer_non_vendu_vendu_in_middle():
    """'vendu par' in the middle of a longer vendor name."""
    rows = [
        {"Vendor": "Some Company - Vendu par - Amazon.ca"},
        {"Vendor": "Amazon.ca"},
    ]
    result = _prefer_non_vendu([0, 1], rows)
    assert result == 1


# ═════════════════════════════════════════════════════════════════════════════
# Edge cases for all parsers
# ═════════════════════════════════════════════════════════════════════════════

def test_parse_canonical_leading_zeros_in_amount():
    date_iso, amt = parse_canonical_date_amt("2025-03-01 - 00.50 - Test.pdf")
    assert date_iso == "2025-03-01"
    assert amt == "00.50"


def test_parse_canonical_four_digit_amount():
    date_iso, amt = parse_canonical_date_amt("2025-03-01 - 1234.56 - Big Vendor.pdf")
    assert date_iso == "2025-03-01"
    assert amt == "1234.56"


def test_parse_canonical_vendor_with_parens():
    date_iso, amt = parse_canonical_date_amt(
        "2025-09-16 - 654.00 - Intersite Consulting Inc. (704730...).pdf"
    )
    assert date_iso == "2025-09-16"
    assert amt == "654.00"


def test_empty_string_returns_none():
    assert parse_canonical_date_amt("") == (None, None)
    assert parse_filename_date_amt("") == (None, None)


def test_underscore_date_filename():
    """Edge case: 2025_04_09 format."""
    d, a = parse_filename_date_amt("2025_04_09 - 33.60 - Test.pdf")
    assert d == "2025-04-09"
    assert a == "33.60"


def test_date_before_2000_not_matched():
    """DATE_RE only matches 20xx dates."""
    assert parse_canonical_date_amt("1999-12-31 - 10.00 - Old.pdf") == (None, None)
