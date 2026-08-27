"""Tests for reconcile-sidecars-vs-csv.py."""

import importlib.util
import sys
from pathlib import Path

import pytest

# Load the module directly since the filename has hyphens (not a valid Python identifier)
_module_path = Path(__file__).resolve().parent.parent / "recon" / "reconcile-sidecars-vs-csv.py"
_spec = importlib.util.spec_from_file_location("reconcile_sidecars_vs_csv", str(_module_path))
_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_mod)
sys.modules["reconcile_sidecars_vs_csv"] = _mod

parse_date_flex = _mod.parse_date_flex
detect_csv_format = _mod.detect_csv_format
fuzzy_match = _mod.fuzzy_match
load_consolidated_csv = _mod.load_consolidated_csv
load_sidecar_csvs = _mod.load_sidecar_csvs
_load_rbc_csv = _mod._load_rbc_csv
_load_td_csv = _mod._load_td_csv
_load_scotia_csv = _mod._load_scotia_csv
_load_generic_csv = _mod._load_generic_csv
reconcile_account = _mod.reconcile_account
main = _mod.main


# ---- parse_date_flex ----

class TestParseDateFlex:
    def test_yyyy_mm_dd_hyphen(self):
        assert parse_date_flex("2026-01-15") == "2026-01-15"

    def test_yyyy_mm_dd_slash(self):
        assert parse_date_flex("2026/01/15") == "2026-01-15"

    def test_m_d_yyyy(self):
        assert parse_date_flex("1/15/2026") == "2026-01-15"

    def test_mm_dd_yyyy(self):
        assert parse_date_flex("01/15/2026") == "2026-01-15"

    def test_single_digit_month_day(self):
        assert parse_date_flex("1/5/2026") == "2026-01-05"

    def test_already_normalized(self):
        assert parse_date_flex("  2026-01-15  ") == "2026-01-15"

    def test_unrecognized_format_returns_as_is(self):
        assert parse_date_flex("Jan 15, 2026") == "Jan 15, 2026"

    def test_empty_string(self):
        assert parse_date_flex("") == ""


# ---- detect_csv_format ----

class TestDetectCsvFormat:
    def test_rbc_format(self):
        assert detect_csv_format(["CAD$", "Description 1", "Transaction Date"]) == "rbc"

    def test_td_format(self):
        assert detect_csv_format(["Date", "Description", "Debit", "Credit"]) == "td"

    def test_scotia_format(self):
        assert detect_csv_format(["Date", "Amount", "Type of Transaction"]) == "scotia"

    def test_generic_amount_only(self):
        assert detect_csv_format(["Date", "Amount", "Payee"]) == "generic"

    def test_unknown_format(self):
        assert detect_csv_format(["Col1", "Col2", "Col3"]) == "unknown"

    def test_empty_headers(self):
        assert detect_csv_format([]) == "unknown"

    def test_headers_whitespace_trimmed(self):
        assert detect_csv_format(["  CAD$  ", "  Description 1  "]) == "rbc"


# ---- fuzzy_match ----

class TestFuzzyMatch:
    def test_exact_match(self):
        ct = {"amount": 100.00, "is_credit": False}
        st = {"amount": 100.00, "is_credit": False}
        assert fuzzy_match(ct, st) is True

    def test_credit_match(self):
        ct = {"amount": 50.00, "is_credit": True}
        st = {"amount": 50.00, "is_credit": True}
        assert fuzzy_match(ct, st) is True

    def test_amount_mismatch(self):
        ct = {"amount": 100.00, "is_credit": False}
        st = {"amount": 200.00, "is_credit": False}
        assert fuzzy_match(ct, st) is False

    def test_direction_mismatch(self):
        ct = {"amount": 100.00, "is_credit": False}
        st = {"amount": 100.00, "is_credit": True}
        assert fuzzy_match(ct, st) is False

    def test_within_rounding_tolerance(self):
        ct = {"amount": 100.01, "is_credit": False}
        st = {"amount": 100.00, "is_credit": False}
        assert fuzzy_match(ct, st) is True

    def test_amount_boundary(self):
        ct = {"amount": 100.03, "is_credit": False}
        st = {"amount": 100.00, "is_credit": False}
        assert fuzzy_match(ct, st) is False


# ---- _load_rbc_csv ----

class TestLoadRbcCsv:
    def test_basic_debit(self, tmp_path):
        p = tmp_path / "rbc.csv"
        p.write_text(
            "CAD$,Transaction Date,Description 1,Description 2\n"
            "-33.60,2026-01-15,Freedom Mobile,\n"
        )
        txns = _load_rbc_csv(str(p))
        assert len(txns) == 1
        assert txns[0]["amount"] == 33.60
        assert txns[0]["is_credit"] is False
        assert txns[0]["payee"] == "Freedom Mobile"

    def test_basic_credit(self, tmp_path):
        p = tmp_path / "rbc_credit.csv"
        p.write_text(
            "CAD$,Transaction Date,Description 1,Description 2\n"
            "200.00,2026-01-20,Consulting Revenue,\n"
        )
        txns = _load_rbc_csv(str(p))
        assert len(txns) == 1
        assert txns[0]["amount"] == 200.00
        assert txns[0]["is_credit"] is True

    def test_empty_amount_skipped(self, tmp_path):
        p = tmp_path / "rbc_empty.csv"
        p.write_text(
            "CAD$,Transaction Date,Description 1,Description 2\n"
            ",2026-01-15,Empty,\n"
            "-33.60,2026-01-16,Freedom Mobile,\n"
        )
        txns = _load_rbc_csv(str(p))
        assert len(txns) == 1

    def test_zero_amount_skipped(self, tmp_path):
        p = tmp_path / "rbc_zero.csv"
        p.write_text(
            "CAD$,Transaction Date,Description 1,Description 2\n"
            "0.00,2026-01-15,Nothing,\n"
            "-33.60,2026-01-16,Freedom Mobile,\n"
        )
        txns = _load_rbc_csv(str(p))
        assert len(txns) == 1

    def test_invalid_amount_skipped(self, tmp_path):
        p = tmp_path / "rbc_invalid.csv"
        p.write_text(
            "CAD$,Transaction Date,Description 1,Description 2\n"
            "not-a-number,2026-01-15,Bad,\n"
            "-33.60,2026-01-16,Freedom Mobile,\n"
        )
        txns = _load_rbc_csv(str(p))
        assert len(txns) == 1

    def test_comma_in_amount(self, tmp_path):
        p = tmp_path / "rbc_comma.csv"
        p.write_text(
            'CAD$,Transaction Date,Description 1,Description 2\n'
            '"-1,234.56",2026-01-15,Big Purchase,\n'
        )
        txns = _load_rbc_csv(str(p))
        assert len(txns) == 1
        assert txns[0]["amount"] == 1234.56

    def test_multiple_descriptions_joined(self, tmp_path):
        p = tmp_path / "rbc_multi_desc.csv"
        p.write_text(
            "CAD$,Transaction Date,Description 1,Description 2\n"
            "-33.60,2026-01-15,Freedom,Mobile\n"
        )
        txns = _load_rbc_csv(str(p))
        assert txns[0]["payee"] == "Freedom Mobile"


# ---- _load_td_csv ----

class TestLoadTdCsv:
    def test_debit_row(self, tmp_path):
        p = tmp_path / "td.csv"
        p.write_text(
            "Date,Description,Debit,Credit\n"
            "2026-01-15,Electric Bill,150.00,\n"
        )
        txns = _load_td_csv(str(p))
        assert len(txns) == 1
        assert txns[0]["amount"] == 150.00
        assert txns[0]["is_credit"] is False

    def test_credit_row(self, tmp_path):
        p = tmp_path / "td_credit.csv"
        p.write_text(
            "Date,Description,Debit,Credit\n"
            "2026-01-20,Deposit,,500.00\n"
        )
        txns = _load_td_csv(str(p))
        assert len(txns) == 1
        assert txns[0]["amount"] == 500.00
        assert txns[0]["is_credit"] is True

    def test_both_empty_skipped(self, tmp_path):
        p = tmp_path / "td_empty.csv"
        p.write_text(
            "Date,Description,Debit,Credit\n"
            "2026-01-15,Empty,,\n"
            "2026-01-16,Electric Bill,150.00,\n"
        )
        txns = _load_td_csv(str(p))
        assert len(txns) == 1


# ---- _load_scotia_csv ----

class TestLoadScotiaCsv:
    def test_debit_row(self, tmp_path):
        p = tmp_path / "scotia.csv"
        p.write_text(
            "Date,Description,Sub-description,Amount,Type of Transaction\n"
            "2026-01-15,Rent Payment,, -1200.00,Payment\n"
        )
        txns = _load_scotia_csv(str(p))
        assert len(txns) == 1
        assert txns[0]["amount"] == 1200.00
        assert txns[0]["is_credit"] is False

    def test_credit_row(self, tmp_path):
        p = tmp_path / "scotia_credit.csv"
        p.write_text(
            "Date,Description,Sub-description,Amount,Type of Transaction\n"
            "2026-01-20,Deposit,,500.00,Deposit\n"
        )
        txns = _load_scotia_csv(str(p))
        assert len(txns) == 1
        assert txns[0]["is_credit"] is True

    def test_sub_description_joined(self, tmp_path):
        p = tmp_path / "scotia_sub.csv"
        p.write_text(
            "Date,Description,Sub-description,Amount,Type of Transaction\n"
            "2026-01-15,Costco,WHSE,-75.50,Purchase\n"
        )
        txns = _load_scotia_csv(str(p))
        assert txns[0]["payee"] == "Costco WHSE"


# ---- _load_generic_csv ----

class TestLoadGenericCsv:
    def test_amount_column(self, tmp_path):
        p = tmp_path / "generic.csv"
        p.write_text(
            "Date,Description,Amount\n"
            "2026-01-15,Coffee,-5.50\n"
        )
        txns = _load_generic_csv(str(p))
        assert len(txns) == 1
        assert txns[0]["amount"] == 5.50
        assert txns[0]["is_credit"] is False

    def test_no_amount_columns_returns_empty(self, tmp_path):
        p = tmp_path / "generic_noamt.csv"
        p.write_text(
            "Col1,Col2\n"
            "A,B\n"
        )
        txns = _load_generic_csv(str(p))
        assert txns == []


# ---- load_consolidated_csv ----

class TestLoadConsolidatedCsv:
    def test_missing_file(self, tmp_path):
        with pytest.raises(FileNotFoundError):
            load_consolidated_csv(str(tmp_path / "nonexistent.csv"))

    def test_empty_file(self, tmp_path):
        p = tmp_path / "empty.csv"
        p.write_text("CAD$,Transaction Date,Description 1,Description 2\n")
        txns = load_consolidated_csv(str(p))
        assert txns == []

    def test_routed_to_rbc_format(self, tmp_path):
        p = tmp_path / "rbc.csv"
        p.write_text(
            "CAD$,Transaction Date,Description 1,Description 2\n"
            "-33.60,2026-01-15,Freedom Mobile,\n"
        )
        txns = load_consolidated_csv(str(p))
        assert len(txns) == 1

    def test_routed_to_td_format(self, tmp_path):
        p = tmp_path / "td.csv"
        p.write_text(
            "Date,Description,Debit,Credit\n"
            "2026-01-15,Electric Bill,150.00,\n"
        )
        txns = load_consolidated_csv(str(p))
        assert len(txns) == 1


# ---- load_sidecar_csvs ----

class TestLoadSidecarCsvs:
    def test_basic_load(self, tmp_path):
        f = tmp_path / "jan.csv"
        f.write_text(
            "date,payee,amount,debit_or_credit,description\n"
            "2026-01-15,Freedom Mobile,33.60,debit,Monthly\n"
        )
        results = load_sidecar_csvs(str(tmp_path))
        assert len(results) == 1
        fname, txns = results[0]
        assert fname == "jan.csv"
        assert len(txns) == 1
        assert txns[0]["amount"] == 33.60

    def test_skips_comment_lines(self, tmp_path):
        f = tmp_path / "jan.csv"
        f.write_text(
            "# Generated by convert-pdf-statement-to-sidecar.py\n"
            "# Date: 2026-01-31\n"
            "date,payee,amount,debit_or_credit,description\n"
            "2026-01-15,Freedom Mobile,33.60,debit,Monthly\n"
        )
        results = load_sidecar_csvs(str(tmp_path))
        assert len(results) == 1

    def test_skips_2026_fiscal_year_csv(self, tmp_path):
        p = tmp_path / "2026 Fiscal Year - Intersite Transactions.csv"
        p.write_text("date,payee,amount,debit_or_credit,description\n")
        f2 = tmp_path / "jan.csv"
        f2.write_text(
            "date,payee,amount,debit_or_credit,description\n"
            "2026-01-15,Freedom Mobile,33.60,debit,Monthly\n"
        )
        results = load_sidecar_csvs(str(tmp_path))
        assert len(results) == 1
        assert results[0][0] == "jan.csv"

    def test_skips_non_csv_files(self, tmp_path):
        (tmp_path / "readme.txt").write_text("not a csv")
        f = tmp_path / "jan.csv"
        f.write_text(
            "date,payee,amount,debit_or_credit,description\n"
            "2026-01-15,Freedom Mobile,33.60,debit,Monthly\n"
        )
        results = load_sidecar_csvs(str(tmp_path))
        assert len(results) == 1

    def test_skips_rows_with_empty_date(self, tmp_path):
        f = tmp_path / "jan.csv"
        f.write_text(
            "date,payee,amount,debit_or_credit,description\n"
            ",Empty,10.00,debit,\n"
            "2026-01-15,Freedom Mobile,33.60,debit,Monthly\n"
        )
        results = load_sidecar_csvs(str(tmp_path))
        assert len(results) == 1
        assert len(results[0][1]) == 1

    def test_skips_rows_with_non_positive_amount(self, tmp_path):
        f = tmp_path / "jan.csv"
        f.write_text(
            "date,payee,amount,debit_or_credit,description\n"
            "2026-01-15,Zero,0.00,debit,\n"
            "2026-01-15,Negative,-10.00,debit,\n"
            "2026-01-15,Freedom Mobile,33.60,debit,Monthly\n"
        )
        results = load_sidecar_csvs(str(tmp_path))
        assert len(results) == 1
        assert len(results[0][1]) == 1

    def test_invalid_amount_skipped(self, tmp_path):
        f = tmp_path / "jan.csv"
        f.write_text(
            "date,payee,amount,debit_or_credit,description\n"
            "2026-01-15,Bad,notanumber,debit,\n"
            "2026-01-15,Freedom Mobile,33.60,debit,Monthly\n"
        )
        results = load_sidecar_csvs(str(tmp_path))
        assert len(results) == 1
        assert len(results[0][1]) == 1

    def test_multiple_sidecar_files(self, tmp_path):
        (tmp_path / "jan.csv").write_text(
            "date,payee,amount,debit_or_credit,description\n"
            "2026-01-15,Freedom Mobile,33.60,debit,Monthly\n"
        )
        (tmp_path / "feb.csv").write_text(
            "date,payee,amount,debit_or_credit,description\n"
            "2026-02-15,Freedom Mobile,33.60,debit,Monthly\n"
        )
        results = load_sidecar_csvs(str(tmp_path))
        assert len(results) == 2

    def test_empty_sidecar_file_returns_no_results(self, tmp_path):
        f = tmp_path / "empty.csv"
        f.write_text("date,payee,amount,debit_or_credit,description\n")
        results = load_sidecar_csvs(str(tmp_path))
        assert results == []

    def test_missing_directory(self, tmp_path):
        with pytest.raises(FileNotFoundError):
            load_sidecar_csvs(str(tmp_path / "nonexistent"))


# ---- reconcile_account ----

class TestReconcileAccount:
    def test_perfect_match(self, tmp_path):
        csv_p = tmp_path / "consolidated.csv"
        csv_p.write_text(
            "CAD$,Transaction Date,Description 1,Description 2\n"
            "-33.60,2026-01-15,Freedom Mobile,\n"
        )
        sidecar_dir = tmp_path / "sidecars"
        sidecar_dir.mkdir()
        (sidecar_dir / "jan.csv").write_text(
            "date,payee,amount,debit_or_credit,description\n"
            "2026-01-15,Freedom Mobile,33.60,debit,Monthly\n"
        )
        result = reconcile_account("Test", str(csv_p), str(sidecar_dir))
        assert len(result["matched"]) == 1
        assert result["csv_unmatched"] == []
        assert result["sidecar_unmatched"] == []

    def test_csv_unmatched(self, tmp_path):
        csv_p = tmp_path / "consolidated.csv"
        csv_p.write_text(
            "CAD$,Transaction Date,Description 1,Description 2\n"
            "-33.60,2026-01-15,Freedom Mobile,\n"
            "-150.00,2026-01-20,Electric Bill,\n"
        )
        sidecar_dir = tmp_path / "sidecars"
        sidecar_dir.mkdir()
        (sidecar_dir / "jan.csv").write_text(
            "date,payee,amount,debit_or_credit,description\n"
            "2026-01-15,Freedom Mobile,33.60,debit,Monthly\n"
        )
        result = reconcile_account("Test", str(csv_p), str(sidecar_dir))
        assert len(result["matched"]) == 1
        assert len(result["csv_unmatched"]) == 1
        assert result["sidecar_unmatched"] == []

    def test_sidecar_unmatched(self, tmp_path):
        csv_p = tmp_path / "consolidated.csv"
        csv_p.write_text(
            "CAD$,Transaction Date,Description 1,Description 2\n"
            "-33.60,2026-01-15,Freedom Mobile,\n"
        )
        sidecar_dir = tmp_path / "sidecars"
        sidecar_dir.mkdir()
        (sidecar_dir / "jan.csv").write_text(
            "date,payee,amount,debit_or_credit,description\n"
            "2026-01-15,Freedom Mobile,33.60,debit,Monthly\n"
            "2026-01-20,Extra Txn,50.00,debit,Unknown\n"
        )
        result = reconcile_account("Test", str(csv_p), str(sidecar_dir))
        assert len(result["matched"]) == 1
        assert result["csv_unmatched"] == []
        assert len(result["sidecar_unmatched"]) == 1

    def test_no_sidecar_files(self, tmp_path):
        csv_p = tmp_path / "consolidated.csv"
        csv_p.write_text(
            "CAD$,Transaction Date,Description 1,Description 2\n"
            "-33.60,2026-01-15,Freedom Mobile,\n"
        )
        sidecar_dir = tmp_path / "sidecars"
        sidecar_dir.mkdir()
        result = reconcile_account("Test", str(csv_p), str(sidecar_dir))
        assert result["matched"] == []
        assert len(result["csv_unmatched"]) == 1

    def test_missing_csv_raises(self, tmp_path):
        sidecar_dir = tmp_path / "sidecars"
        sidecar_dir.mkdir()
        with pytest.raises(FileNotFoundError):
            reconcile_account("Test", str(tmp_path / "nonexistent.csv"), str(sidecar_dir))

    def test_missing_sidecar_dir_raises(self, tmp_path):
        csv_p = tmp_path / "consolidated.csv"
        csv_p.write_text(
            "CAD$,Transaction Date,Description 1,Description 2\n"
            "-33.60,2026-01-15,Freedom Mobile,\n"
        )
        with pytest.raises(FileNotFoundError):
            reconcile_account("Test", str(csv_p), str(tmp_path / "nonexistent"))


# ---- Argument parsing ----

class TestArgparse:
    def test_custom_year_and_entity(self, tmp_path):
        csv_p = tmp_path / "a.csv"
        csv_p.write_text(
            "CAD$,Transaction Date,Description 1,Description 2\n"
            "-33.60,2026-01-15,Freedom Mobile,\n"
        )
        sidecar_dir = tmp_path / "sidecars"
        sidecar_dir.mkdir()
        from unittest.mock import patch
        with patch.object(
            sys, "argv",
            ["prog", "--csv-path", str(csv_p), "--sidecars-dir", str(sidecar_dir),
             "--entity", "room-rentals", "--year", "2026"],
        ):
            # Should not raise if args are valid
            main()

    def test_required_args_missing(self):
        from unittest.mock import patch
        with patch.object(sys, "argv", ["prog"]):
            with pytest.raises(SystemExit):
                main()
