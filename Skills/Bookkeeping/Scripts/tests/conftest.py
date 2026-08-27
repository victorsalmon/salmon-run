"""Shared pytest fixtures for receipt processing tests."""

import csv
import pytest
from pathlib import Path


SAMPLE_TAS_ROWS = [
    {"date": "2026-01-15", "bank_account": "RBC Intersite (Chequing 6632)", "amount": "33.60",
     "description": "Freedom Mobile", "category": "Software & IT Expenses",
     "receipt_filename": "rbc-6258/2026-01-15 - 33.60 - Freedom.pdf"},
    {"date": "2026-01-20", "bank_account": "MC 6258 (MasterCard 6241)", "amount": "100.00",
     "description": "Amazon.ca", "category": "Office & General Expenses",
     "receipt_filename": ""},
    {"date": "2026-02-01", "bank_account": "RBC Intersite (Chequing 6632)", "amount": "-500.00",
     "description": "Shareholder Loan Transfer", "category": "Shareholder Loan",
     "receipt_filename": ""},
    {"date": "2026-02-15", "bank_account": "MC 6258 (MasterCard 6241)", "amount": "45.00",
     "description": "Netflix", "category": "Office & General Expenses",
     "receipt_filename": "rbc-6258/2026-02-15 - 45.00 - Netflix.pdf"},
    {"date": "2026-03-01", "bank_account": "RBC Intersite (Chequing 6632)", "amount": "150.00",
     "description": "Interserver", "category": "Software & IT Expenses",
     "receipt_filename": ""},
    {"date": "2026-03-10", "bank_account": "MC 6258 (MasterCard 6241)", "amount": "75.50",
     "description": "Home Depot", "category": "Repairs and Maintenance",
     "receipt_filename": ""},
    {"date": "2026-03-20", "bank_account": "RBC Intersite (Chequing 6632)", "amount": "200.00",
     "description": "Consulting Revenue", "category": "Consulting Revenue",
     "receipt_filename": ""},
    {"date": "2026-04-01", "bank_account": "MC 6258 (MasterCard 6241)", "amount": "12.99",
     "description": "OpenRouter API", "category": "Software & IT Expenses",
     "receipt_filename": "rbc-6258/2026-04-01 - 12.99 - OpenRouter.pdf"},
    {"date": "2026-04-15", "bank_account": "RBC Intersite (Chequing 6632)", "amount": "89.00",
     "description": "Strata Fees", "category": "Strata Fees",
     "receipt_filename": ""},
    {"date": "2026-05-01", "bank_account": "MC 6258 (MasterCard 6241)", "amount": "33.60",
     "description": "Freedom Mobile", "category": "Software & IT Expenses",
     "receipt_filename": "rbc-6258/2026-05-01 - 33.60 - Freedom.pdf"},
]

SAMPLE_MANIFEST_ROWS = [
    {"filename": "rbc-6258/2026-01-15 - 33.60 - Freedom.pdf", "date": "2026-01-15",
     "amount": "33.60", "vendor": "Freedom Mobile", "account": "rbc-6258",
     "sha256": "a" * 64, "status": "matched"},
    {"filename": "rbc-6258/2026-02-15 - 45.00 - Netflix.pdf", "date": "2026-02-15",
     "amount": "45.00", "vendor": "Netflix", "account": "rbc-6258",
     "sha256": "b" * 64, "status": "uploaded"},
    {"filename": "rbc-6258/2026-04-01 - 12.99 - OpenRouter.pdf", "date": "2026-04-01",
     "amount": "12.99", "vendor": "OpenRouter", "account": "rbc-6258",
     "sha256": "c" * 64, "status": "archived"},
    {"filename": "rbc-6258/2026-05-01 - 33.60 - Freedom.pdf", "date": "2026-05-01",
     "amount": "33.60", "vendor": "Freedom Mobile", "account": "rbc-6258",
     "sha256": "d" * 64, "status": "promoted"},
    {"filename": "rbc-intersite/2026-03-01 - 150.00 - Interserver.pdf", "date": "2026-03-01",
     "amount": "150.00", "vendor": "Interserver", "account": "rbc-intersite",
     "sha256": "e" * 64, "status": "matched"},
    {"filename": "rbc-intersite/2026-03-20 - 200.00 - Revenue.pdf", "date": "2026-03-20",
     "amount": "200.00", "vendor": "Revenue", "account": "rbc-intersite",
     "sha256": "f" * 64, "status": "orphan"},
    {"filename": "rbc-6258/2026-06-01 - 0.00 - Unknown.pdf", "date": "",
     "amount": "0.00", "vendor": "Unknown", "account": "rbc-6258",
     "sha256": "g" * 64, "status": "orphan"},
    {"filename": "rbc-intersite/unknown-date - 0.00 - Unknown.pdf", "date": "",
     "amount": "0.00", "vendor": "Unknown", "account": "rbc-intersite",
     "sha256": "h" * 64, "status": "scan-rebuild"},
]


@pytest.fixture
def sample_tas_csv(tmp_path):
    """Write sample TAS CSV to a temp directory and return the path."""
    path = tmp_path / "sample_tas.csv"
    with open(path, "w", newline="") as f:
        f.write("# Transaction Annual Statement\n")
        writer = csv.DictWriter(f, fieldnames=list(SAMPLE_TAS_ROWS[0].keys()))
        writer.writeheader()
        writer.writerows(SAMPLE_TAS_ROWS)
    return path


@pytest.fixture
def sample_manifest_csv(tmp_path):
    """Write sample manifest CSV to a temp directory and return the path."""
    path = tmp_path / "sample_manifest.csv"
    with open(path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=list(SAMPLE_MANIFEST_ROWS[0].keys()))
        writer.writeheader()
        writer.writerows(SAMPLE_MANIFEST_ROWS)
    return path


@pytest.fixture
def empty_tmp_dir(tmp_path):
    """Return an empty temp directory for walk_receipts testing."""
    return tmp_path
