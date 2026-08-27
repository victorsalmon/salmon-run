"""Tests for hash-csv.py, rename-csv.py, and income-forecast.py — pytest style.

Replicates all tests from test_privacy_pipeline.py using pytest fixtures
instead of unittest.TestCase setUp/tearDown.

These tests import the actual modules under test and exercise their internal
entry points (main_inner, build_parser, run).
"""

import csv
import importlib.util
import json
import pytest
from pathlib import Path

SKILL_DIR = Path(__file__).resolve().parent.parent


def _import_from_path(name, path):
    spec = importlib.util.spec_from_file_location(name, str(path))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


hash_csv = _import_from_path('hash_csv', SKILL_DIR / 'hash-csv.py')
income_forecast = _import_from_path('income_forecast', SKILL_DIR / 'income-forecast.py')
rename_csv = _import_from_path('rename_csv', SKILL_DIR / 'rename-csv.py')


def write_csv(path, headers, rows):
    with open(path, 'w', newline='', encoding='utf-8') as f:
        w = csv.writer(f)
        w.writerow(headers)
        for r in rows:
            w.writerow(r)


def read_csv(path):
    with open(path, 'r', encoding='utf-8') as f:
        return list(csv.DictReader(f))


CSV_HEADERS = ['date', 'description', 'amount', 'category', 'type']
SAMPLE_ROWS = [
    ('2025-01-15', 'Client A Payment', '5000.00', 'Consulting Revenue', 'income'),
    ('2025-01-20', 'Office Rent', '-2000.00', 'Office Lease', 'expense'),
    ('2025-02-15', 'Client A Payment', '5000.00', 'Consulting Revenue', 'income'),
    ('2025-02-20', 'Office Rent', '-2000.00', 'Office Lease', 'expense'),
    ('2025-03-15', 'Client A Payment', '5000.00', 'Consulting Revenue', 'income'),
    ('2025-03-20', 'Office Rent', '-2000.00', 'Office Lease', 'expense'),
    ('2025-04-10', 'Starbucks Coffee', '-5.50', 'Meals & Entertainment', 'expense'),
    ('2025-04-15', 'Client A Payment', '5000.00', 'Consulting Revenue', 'income'),
    ('2025-04-20', 'Office Rent', '-2000.00', 'Office Lease', 'expense'),
    ('2025-05-10', 'Starbucks Coffee', '-5.50', 'Meals & Entertainment', 'expense'),
    ('2025-05-15', 'Client A Payment', '5000.00', 'Consulting Revenue', 'income'),
    ('2025-05-20', 'Office Rent', '-2000.00', 'Office Lease', 'expense'),
]


# ── Fixtures ──────────────────────────────────────────────────────────────────

@pytest.fixture
def csv_path(tmp_path):
    """Create sample CSV for hash-csv tests."""
    path = tmp_path / 'test.csv'
    write_csv(path, CSV_HEADERS, SAMPLE_ROWS)
    return path


@pytest.fixture
def salt():
    return 'test-salt-001'


@pytest.fixture
def hash_output(csv_path, salt, tmp_path):
    """Run hash-csv and return (output_path, lookup_path)."""
    output_path = tmp_path / 'out.csv'
    hash_csv.main_inner([str(csv_path)], str(output_path), salt)
    lookup_path = output_path.with_name(output_path.stem + '-lookup.json')
    return output_path, lookup_path


@pytest.fixture
def lookup_data():
    """Return sample lookup JSON data for rename-csv tests."""
    return {
        'salt': 'test-salt',
        'rows': {
            'uuid-client-00001': {
                'original_description': 'Client A Payment',
                'original_date': '2025-01-15',
                'original_amount': 5000.0,
                'original_category': 'Consulting Revenue',
                'original_type': 'income',
            },
            'uuid-client-00002': {
                'original_description': 'Client A Payment',
                'original_date': '2025-02-15',
                'original_amount': 5000.0,
                'original_category': 'Consulting Revenue',
                'original_type': 'income',
            },
            'uuid-rent-00001': {
                'original_description': 'Office Rent',
                'original_date': '2025-01-20',
                'original_amount': -2000.0,
                'original_category': 'Office Lease',
                'original_type': 'expense',
            },
        },
    }


@pytest.fixture
def lookup_path(tmp_path, lookup_data):
    path = tmp_path / 'lookup.json'
    with open(path, 'w') as f:
        json.dump(lookup_data, f)
    return path


@pytest.fixture
def anonymized_csv(tmp_path):
    """Create anonymized CSV with row_ids for income-forecast tests."""
    rows_6mo = [
        ('2025-01-15', 'MERCHANT_A', '5000.00', 'Consulting Revenue', 'income', 'id-a-0001'),
        ('2025-01-20', 'MERCHANT_B', '-2000.00', 'Office Lease', 'expense', 'id-b-0001'),
        ('2025-02-15', 'MERCHANT_A', '5000.00', 'Consulting Revenue', 'income', 'id-a-0002'),
        ('2025-02-20', 'MERCHANT_B', '-2000.00', 'Office Lease', 'expense', 'id-b-0002'),
        ('2025-03-15', 'MERCHANT_A', '5000.00', 'Consulting Revenue', 'income', 'id-a-0003'),
        ('2025-03-20', 'MERCHANT_B', '-2000.00', 'Office Lease', 'expense', 'id-b-0003'),
        ('2025-04-10', 'MERCHANT_C', '-5.50', 'Meals & Entertainment', 'expense', 'id-c-0001'),
        ('2025-04-15', 'MERCHANT_A', '5000.00', 'Consulting Revenue', 'income', 'id-a-0004'),
        ('2025-04-20', 'MERCHANT_B', '-2000.00', 'Office Lease', 'expense', 'id-b-0004'),
        ('2025-05-10', 'MERCHANT_C', '-5.50', 'Meals & Entertainment', 'expense', 'id-c-0002'),
        ('2025-05-15', 'MERCHANT_A', '5000.00', 'Consulting Revenue', 'income', 'id-a-0005'),
        ('2025-05-20', 'MERCHANT_B', '-2000.00', 'Office Lease', 'expense', 'id-b-0005'),
        ('2025-06-10', 'MERCHANT_C', '-5.50', 'Meals & Entertainment', 'expense', 'id-c-0003'),
        ('2025-06-12', 'MERCHANT_D', '-150.00', 'Software & IT', 'expense', 'id-d-0001'),
    ]
    path = tmp_path / 'anonymized.csv'
    headers = ['date', 'description', 'amount', 'category', 'type', 'row_id']
    write_csv(path, headers, rows_6mo)
    return path


# ═════════════════════════════════════════════════════════════════════════════
# hash-csv tests
# ═════════════════════════════════════════════════════════════════════════════

class TestHashCsv:
    """Tests for hash-csv.py"""

    def test_basic_anonymization(self, hash_output):
        """Output has correct columns and all rows are present."""
        out, _ = hash_output
        rows = read_csv(out)
        assert len(rows) == len(SAMPLE_ROWS)
        for r in rows:
            assert 'row_id' in r
            assert 'date' in r
            assert 'description' in r
            assert 'amount' in r
            assert 'category' in r
            assert 'type' in r
            assert len(r['row_id']) == 36  # UUID v4
            assert len(r['description']) == 64  # SHA-256 hex
            assert all(c in '0123456789abcdef' for c in r['description'])

    def test_same_description_same_hash(self, hash_output, tmp_path):
        """Identical descriptions produce identical hashes."""
        out, lookup_path = hash_output
        with open(lookup_path) as f:
            lookup = json.load(f)
        rows = read_csv(out)
        client_hashes = [
            r['description'] for r in rows
            if 'Client A Payment' in lookup['rows'][r['row_id']]['original_description']
        ]
        assert len(client_hashes) > 1
        assert len(set(client_hashes)) == 1

    def test_different_description_different_hash(self, hash_output):
        """Different descriptions produce different hashes."""
        out, _ = hash_output
        rows = read_csv(out)
        all_hashes = list(set(r['description'] for r in rows))
        assert len(all_hashes) >= 3

    def test_lookup_contains_originals(self, hash_output, tmp_path):
        """Lookup JSON contains original descriptions mapped by UUID."""
        _, lookup_path = hash_output
        with open(lookup_path) as f:
            lookup = json.load(f)
        assert lookup['salt'] == 'test-salt-001'
        assert len(lookup['rows']) == len(SAMPLE_ROWS)
        first_uuid = list(lookup['rows'].keys())[0]
        row = lookup['rows'][first_uuid]
        assert 'original_description' in row
        assert 'original_date' in row
        assert 'original_amount' in row

    def test_salt_determinism(self, csv_path, tmp_path):
        """Same salt produces identical hashes across runs."""
        out1 = tmp_path / 'out1.csv'
        out2 = tmp_path / 'out2.csv'
        hash_csv.main_inner([str(csv_path)], str(out1), 'fixed-salt')
        hash_csv.main_inner([str(csv_path)], str(out2), 'fixed-salt')
        rows1 = read_csv(out1)
        rows2 = read_csv(out2)
        for r1, r2 in zip(rows1, rows2):
            assert r1['description'] == r2['description']

    def test_different_salt_different_hashes(self, csv_path, tmp_path):
        """Different salts produce different hashes for same description."""
        out1 = tmp_path / 'out1.csv'
        out2 = tmp_path / 'out2.csv'
        hash_csv.main_inner([str(csv_path)], str(out1), 'salt-a')
        hash_csv.main_inner([str(csv_path)], str(out2), 'salt-b')
        rows1 = read_csv(out1)
        rows2 = read_csv(out2)
        hashes_match = all(
            r1['description'] == r2['description']
            for r1, r2 in zip(rows1, rows2)
        )
        assert not hashes_match

    def test_category_inference(self, tmp_path):
        """Category is inferred from description when no category column."""
        simple_rows = [
            ('2025-01-15', 'aws hosting', '150.00', '', 'expense'),
            ('2025-01-20', 'starbucks coffee', '-5.50', '', 'expense'),
        ]
        p = tmp_path / 'simple.csv'
        write_csv(p, ['date', 'description', 'amount', 'category', 'type'], simple_rows)

        out = tmp_path / 'out.csv'
        hash_csv.main_inner([str(p)], str(out), 'test-salt')
        rows = read_csv(out)
        assert rows[0]['category'] == 'Software & IT'
        assert rows[1]['category'] == 'Meals & Entertainment'

    def test_multiple_input_files(self, csv_path, tmp_path):
        """Multiple CSVs are merged into single output."""
        p2 = tmp_path / 'test2.csv'
        extra_rows = [('2025-06-01', 'Extra Payment', '3000.00', 'Consulting Revenue', 'income')]
        write_csv(p2, CSV_HEADERS, extra_rows)

        out = tmp_path / 'out.csv'
        hash_csv.main_inner([str(csv_path), str(p2)], str(out), 'test-salt')
        rows = read_csv(out)
        assert len(rows) == len(SAMPLE_ROWS) + 1

    def test_debit_credit_columns(self, tmp_path):
        """Handles CSV with separate debit/credit columns."""
        dc_rows = [
            ('2025-01-15', 'Payment Received', '0', '5000.00'),
            ('2025-01-20', 'Office Rent', '2000.00', '0'),
        ]
        p = tmp_path / 'dc.csv'
        write_csv(p, ['date', 'description', 'debit', 'credit'], dc_rows)

        out = tmp_path / 'out.csv'
        hash_csv.main_inner([str(p)], str(out), 'test-salt')
        rows = read_csv(out)
        assert len(rows) == 2
        assert rows[0]['type'] == 'income'
        assert rows[1]['type'] == 'expense'
        assert rows[0]['amount'] == '5000.00'
        assert rows[1]['amount'] == '-2000.00'


# ═════════════════════════════════════════════════════════════════════════════
# rename-csv tests
# ═════════════════════════════════════════════════════════════════════════════

class TestRenameCsv:
    """Tests for rename-csv.py"""

    @pytest.fixture
    def run_rename(self, lookup_path, tmp_path):
        """Factory fixture: returns a function that runs rename and reads output."""
        def _run(forecast_rows, output_path=None):
            forecast_path = tmp_path / 'forecast.csv'
            headers = [
                'date', 'description', 'category', 'type', 'amount',
                'adjustments', 'running_balance', 'p10_balance', 'p90_balance',
                'confidence', 'rationale', 'row_ids'
            ]
            write_csv(forecast_path, headers, forecast_rows)
            output_path = output_path or (tmp_path / 'restored.csv')
            rename_csv.main_inner(str(forecast_path), str(lookup_path), str(output_path))
            return read_csv(output_path)
        return _run

    def test_restore_single_uuid(self, run_rename):
        rows = run_rename([
            ('2025-07-15', 'hash123', 'Consulting Revenue', 'income', '5000.00',
             '0.0', '30000.00', '29000.00', '31000.00',
             'recurring', 'Due ~15th', 'uuid-client-00001'),
        ])
        assert rows[0]['original_descriptions'] == 'Client A Payment'

    def test_restore_multiple_uuids(self, run_rename):
        rows = run_rename([
            ('2025-07-15', 'hash123', 'Consulting Revenue', 'income', '5000.00',
             '0.0', '30000.00', '29000.00', '31000.00',
             'recurring', 'Due ~15th', 'uuid-client-00001,uuid-client-00002'),
        ])
        assert rows[0]['original_descriptions'] == 'Client A Payment'

    def test_restore_different_uuids(self, run_rename):
        rows = run_rename([
            ('2025-07-15', 'hash789', 'Mixed', 'expense', '-2000.00',
             '0.0', '28000.00', '27000.00', '29000.00',
             'recurring', 'Due ~20th', 'uuid-client-00001,uuid-rent-00001'),
        ])
        descs = rows[0]['original_descriptions'].split('; ')
        assert 'Client A Payment' in descs
        assert 'Office Rent' in descs

    def test_empty_row_ids(self, run_rename):
        rows = run_rename([
            ('2025-06-12', 'Balance Forward', '', 'balance_forward', '0.0',
             '0.0', '25000.00', '25000.00', '25000.00',
             'high', 'Starting balance', ''),
        ])
        assert rows[0]['original_descriptions'] == ''

    def test_unknown_uuid(self, run_rename):
        rows = run_rename([
            ('2025-07-15', 'hashX', 'Unknown', 'income', '100.00',
             '0.0', '25100.00', '25000.00', '25200.00',
             'low', 'Unknown event', 'nonexistent-uuid-12345'),
        ])
        assert 'unknown' in rows[0]['original_descriptions'].lower()


# ═════════════════════════════════════════════════════════════════════════════
# income-forecast row_ids tests
# ═════════════════════════════════════════════════════════════════════════════

class TestIncomeForecastRowIds:
    """Tests for income-forecast.py --row-ids flag"""

    def _run_forecast(self, csv_path, output_path, row_ids=False):
        parser = income_forecast.build_parser()
        args_list = [
            '--csv', str(csv_path),
            '--balance', '25000',
            '--horizon', '90',
            '--output', str(output_path),
            '--seed', '42',
        ]
        if row_ids:
            args_list.append('--row-ids')
        args = parser.parse_args(args_list)
        income_forecast.run(args)
        return read_csv(output_path)

    def test_row_ids_column_present(self, anonymized_csv, tmp_path):
        out = tmp_path / 'forecast.csv'
        rows = self._run_forecast(anonymized_csv, out, row_ids=True)
        with open(out, encoding='utf-8') as f:
            headers = next(csv.reader(f))
        assert 'row_ids' in headers

    def test_no_row_ids_without_flag(self, anonymized_csv, tmp_path):
        out = tmp_path / 'forecast-no-ids.csv'
        rows = self._run_forecast(anonymized_csv, out, row_ids=False)
        with open(out, encoding='utf-8') as f:
            headers = next(csv.reader(f))
        assert 'row_ids' not in headers

    def test_recurring_events_have_row_ids(self, anonymized_csv, tmp_path):
        out = tmp_path / 'forecast-ids.csv'
        rows = self._run_forecast(anonymized_csv, out, row_ids=True)
        id_rows = [r for r in rows if (r.get('row_ids') or '').strip()]
        assert len(id_rows) > 0
        for r in id_rows:
            ids = r['row_ids'].split(',')
            for rid in ids:
                rid = rid.strip('" ')
                assert rid.startswith('id-') or rid == ''

    def test_balance_forward_no_row_ids(self, anonymized_csv, tmp_path):
        out = tmp_path / 'forecast-bf.csv'
        rows = self._run_forecast(anonymized_csv, out, row_ids=True)
        bf = rows[0]
        assert bf['type'] == 'balance_forward'
        assert (bf.get('row_ids') or '').strip() == ''

    def test_recurring_detection_works_with_hashed(self, anonymized_csv, tmp_path):
        out = tmp_path / 'forecast-recur.csv'
        rows = self._run_forecast(anonymized_csv, out, row_ids=True)
        recurring = [r for r in rows if r['confidence'] == 'recurring']
        assert len(recurring) >= 4
        incomes = [r for r in recurring if r['type'] == 'income']
        expenses = [r for r in recurring if r['type'] == 'expense']
        assert len(incomes) >= 2
        assert len(expenses) >= 2
