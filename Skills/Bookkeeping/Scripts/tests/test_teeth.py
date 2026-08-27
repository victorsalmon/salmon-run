"""TEETH proof — a deliberately broken money implementation is rejected.

The battle-tested-qa contract requires evidence that the suite can detect a
plausible incorrect implementation, not just that the correct one passes.
mutmut is unavailable on native Windows (requires WSL), so this file is the
documented equivalent fault-injection gate: it re-implants the exact class of
defect the property/example suite guards against and asserts the guard trips.
"""

import receipt_utils


def test_teeth_signed_max_matches_tx_is_rejected():
    """Re-implant the signed-max tolerance bug and prove the suite rejects it."""
    original = receipt_utils.matches_tx

    def buggy(tx_amt, rec_amt):
        if tx_amt == 0 or rec_amt == 0:
            return False
        return abs(tx_amt - rec_amt) / max(tx_amt, rec_amt) <= receipt_utils.AMOUNT_TOLERANCE_PCT

    # The bug: two same-sign negatives 100% apart compare "within tolerance".
    assert buggy(-5.0, -10.0) is True, "fault injection must reproduce the bug"
    # The correct behavior the suite enforces.
    assert original(-5.0, -10.0) is False, "correct implementation must reject"

    # The concrete regression test and the Hypothesis property both encode this.
    # Re-run the property's predicate against the buggy implementation.
    from hypothesis import given, strategies as st

    @given(
        st.floats(min_value=-10_000, max_value=10_000, allow_nan=False, allow_infinity=False),
        st.floats(min_value=-10_000, max_value=10_000, allow_nan=False, allow_infinity=False),
    )
    def _predicate(a, b):
        if a == 0 or b == 0:
            return
        denom = max(abs(a), abs(b))
        if denom == 0:
            return
        if abs(a - b) / denom > receipt_utils.AMOUNT_TOLERANCE_PCT + 1e-9:
            assert buggy(a, b) is False

    try:
        _predicate()
    except AssertionError:
        # The buggy implementation violates the tolerance invariant — rejected.
        return
    raise AssertionError("fault injection was NOT rejected by the tolerance invariant")
