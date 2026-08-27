"""Property-based tests for receipt processing money/date/parser invariants.

Uses Hypothesis to prove general invariants that example tests cannot. Each
property guards a real domain invariant (money tolerance, date parsing
round-trips, categorization consistency). Replay seeds are recorded in the
battle-tested-qa evidence artifact.
"""

from datetime import date

from hypothesis import given, settings, strategies as st

from receipt_utils import (
    AMOUNT_TOLERANCE_PCT,
    matches_tx,
    parse_filename_meta,
    vendor_plausible,
)


# ── matches_tx — money tolerance invariants ────────────────────────────────


@given(st.floats(min_value=-10_000, max_value=10_000, allow_nan=False, allow_infinity=False))
def test_matches_tx_reflexive_for_nonzero(a):
    if a == 0:
        return
    assert matches_tx(a, a) is True


@given(
    st.floats(min_value=-10_000, max_value=10_000, allow_nan=False, allow_infinity=False),
    st.floats(min_value=-10_000, max_value=10_000, allow_nan=False, allow_infinity=False),
)
def test_matches_tx_is_symmetric(a, b):
    assert matches_tx(a, b) == matches_tx(b, a)


@given(st.floats(min_value=-10_000, max_value=10_000, allow_nan=False, allow_infinity=False))
def test_matches_tx_zero_never_matches(b):
    assert matches_tx(0.0, b) is False
    assert matches_tx(b, 0.0) is False


@given(
    st.floats(min_value=-10_000, max_value=10_000, allow_nan=False, allow_infinity=False),
    st.floats(min_value=-10_000, max_value=10_000, allow_nan=False, allow_infinity=False),
)
def test_matches_tx_outside_tolerance_is_false(a, b):
    """Two amounts differing by more than AMOUNT_TOLERANCE_PCT of the larger
    magnitude can never match — including same-sign negative amounts (refunds)."""
    if a == 0 or b == 0:
        return
    denom = max(abs(a), abs(b))
    if denom == 0:
        return
    if abs(a - b) / denom > AMOUNT_TOLERANCE_PCT + 1e-9:
        assert matches_tx(a, b) is False


# ── parse_filename_meta — parser round-trip ────────────────────────────────


@given(
    st.dates(min_value=date(2000, 1, 1), max_value=date(2099, 12, 31)),
    st.floats(min_value=0.01, max_value=9999.99, allow_nan=False, allow_infinity=False),
    st.text(
        alphabet=st.characters(whitelist_categories=("L", "N")),
        min_size=1,
        max_size=20,
    ),
)
@settings(max_examples=300)
def test_parse_filename_round_trip(day, amount, vendor):
    date_str = day.strftime("%Y-%m-%d")
    amount_str = f"{amount:.2f}"
    name = f"{date_str} - {amount_str} - {vendor}.pdf"
    meta = parse_filename_meta(name)
    assert meta is not None
    assert meta["date"] == date_str
    assert abs(meta["amount"] - float(amount_str)) < 0.005


@given(
    st.text(alphabet=st.characters(whitelist_categories=("L", "N", "Z")), max_size=80),
)
@settings(max_examples=200)
def test_parse_filename_amount_never_negative(text):
    meta = parse_filename_meta(text)
    if meta is not None:
        assert meta["amount"] >= 0.0


# ── vendor_plausible — categorization consistency ──────────────────────────


@given(st.text(min_size=1, max_size=20))
def test_amazon_vendor_always_plausible(category):
    assert vendor_plausible(category, "Amazon.ca") is True


@given(st.text(min_size=1, max_size=20))
def test_unknown_vendor_not_plausible_for_known_category(vendor):
    # A random all-numeric vendor can never match the substring hints.
    if any(c.isalpha() for c in vendor):
        return
    assert vendor_plausible("Software & IT Expenses", vendor) is False
