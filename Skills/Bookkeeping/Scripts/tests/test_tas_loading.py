"""Tests for TAS CSV loading."""

import csv
from pathlib import Path
from receipt_utils import load_tas


def test_normal_tas_returns_all_rows(sample_tas_csv):
    rows = load_tas(sample_tas_csv)
    assert len(rows) == 10


def test_empty_tas_returns_empty_list(tmp_path):
    path = tmp_path / "empty.csv"
    with open(path, "w") as f:
        f.write('"date","bank_account","amount","description","category"\n')
    rows = load_tas(path)
    assert rows == []


def test_bom_prefixed_parses_correctly(tmp_path):
    path = tmp_path / "bom.csv"
    content = '\ufeff"date","bank_account","amount","description","category"\n2026-01-15,RBC,33.60,Freedom Mobile,Software\n'
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)
    rows = load_tas(path)
    assert len(rows) == 1
    assert rows[0][0] == "2026-01-15"


def test_exempt_categories_loaded(sample_tas_csv):
    rows = load_tas(sample_tas_csv)
    categories = {r[4] for r in rows}
    assert "Shareholder Loan" in categories
    assert "Strata Fees" in categories


def test_malformed_row_skipped(tmp_path):
    path = tmp_path / "malformed.csv"
    with open(path, "w") as f:
        f.write('"date","bank_account","amount","description","category"\n')
        f.write("2026-01-15,RBC,not-a-number,Freedom,Software\n")
        f.write("2026-01-16,MC,33.60,Netflix,Office\n")
    rows = load_tas(path)
    assert len(rows) == 1


def test_wrong_column_count_skipped(tmp_path):
    path = tmp_path / "wrongcols.csv"
    with open(path, "w") as f:
        f.write('"date","bank_account","amount","description","category"\n')
        f.write("too,few,cols\n")
        f.write("2026-01-15,RBC,33.60,Freedom,Software\n")
    rows = load_tas(path)
    assert len(rows) == 1


def test_file_not_found_propagates():
    import pytest
    with pytest.raises(FileNotFoundError):
        load_tas(Path("/nonexistent/path.csv"))


def test_tas_with_receipt_filename_column(sample_tas_csv):
    rows = load_tas(sample_tas_csv)
    non_empty_receipts = [r for r in rows if r[4] == "Software & IT Expenses"]
    assert len(non_empty_receipts) > 0


def test_comments_and_blank_lines_ignored(tmp_path):
    path = tmp_path / "comments.csv"
    with open(path, "w") as f:
        f.write("# This is a comment\n")
        f.write("\n")
        f.write("# Another comment\n")
        f.write('"date","bank_account","amount","description","category"\n')
        f.write("2026-01-15,RBC,33.60,Freedom,Software\n")
        f.write("\n")
        f.write("# Trailing comment\n")
    rows = load_tas(path)
    assert len(rows) == 1


def test_non_numeric_amount_skipped(tmp_path):
    path = tmp_path / "nan.csv"
    with open(path, "w") as f:
        f.write('"date","bank_account","amount","description","category"\n')
        f.write("2026-01-15,RBC,,invalid,Software\n")
        f.write("2026-01-16,MC,33.60,Netflix,Office\n")
    rows = load_tas(path)
    assert len(rows) == 1
