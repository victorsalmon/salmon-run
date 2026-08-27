#!/usr/bin/env python3
"""Tests for hash-csv.py, rename-csv.py, and income-forecast.py --row-ids.

Usage:
    python -m unittest test_privacy_pipeline.py
    python -m unittest test_privacy_pipeline.TestHashCsv
"""

import csv
import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

SKILL_DIR = Path(__file__).parent

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

CSV_HEADERS = ['date', 'description', 'amount', 'category', 'type']


class TestHashCsv(unittest.TestCase):
    """Tests for hash-csv.py"""

    def setUp(self):
        self.tmpdir = Path(tempfile.mkdtemp())
        self.csv_path = self.tmpdir / 'test.csv'
        write_csv(self.csv_path, CSV_HEADERS, SAMPLE_ROWS)
        self.salt = 'test-salt-001'

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmpdir)

    def _run_hash(self, csv_path=None, output_path=None, salt=None, extra_files=None):
        csv_path = csv_path or self.csv_path
        output_path = output_path or (self.tmpdir / 'out.csv')
        salt = salt or self.salt
        files = [str(csv_path)]
        if extra_files:
            files.extend(str(f) for f in extra_files)
        hash_csv.main_inner(files, str(output_path), salt)
        lookup_path = output_path.with_name(output_path.stem + '-lookup.json')
        return output_path, lookup_path

    def test_basic_anonymization(self):
        """Output has correct columns and all rows are present."""
        out, lookup = self._run_hash()
        rows = read_csv(out)
        self.assertEqual(len(rows), len(SAMPLE_ROWS))
        for r in rows:
            self.assertIn('row_id', r)
            self.assertIn('date', r)
            self.assertIn('description', r)
            self.assertIn('amount', r)
            self.assertIn('category', r)
            self.assertIn('type', r)
            # row_id should be a valid UUID v4
            self.assertEqual(len(r['row_id']), 36)
            # description should be a 64-char hex hash
            self.assertEqual(len(r['description']), 64)
            all(c in '0123456789abcdef' for c in r['description'])

    def test_same_description_same_hash(self):
        """Identical descriptions produce identical hashes."""
        out, _ = self._run_hash()
        rows = read_csv(out)
        client_hashes = [r['description'] for r in rows if 'Client A Payment' in
                         json.loads(open(self.tmpdir / 'out-lookup.json').read())['rows'][r['row_id']]['original_description']]
        self.assertGreater(len(client_hashes), 1)
        self.assertEqual(len(set(client_hashes)), 1)

    def test_different_description_different_hash(self):
        """Different descriptions produce different hashes."""
        out, _ = self._run_hash()
        rows = read_csv(out)
        all_hashes = list(set(r['description'] for r in rows))
        # At minimum, Client A, Rent, and Starbucks should be different hashes
        self.assertGreaterEqual(len(all_hashes), 3)

    def test_lookup_contains_originals(self):
        """Lookup JSON contains original descriptions mapped by UUID."""
        _, lookup_path = self._run_hash()
        with open(lookup_path) as f:
            lookup = json.load(f)
        self.assertEqual(lookup['salt'], self.salt)
        self.assertEqual(len(lookup['rows']), len(SAMPLE_ROWS))
        # Check first row
        first_uuid = list(lookup['rows'].keys())[0]
        row = lookup['rows'][first_uuid]
        self.assertEqual(row['original_description'], 'Client A Payment')
        self.assertEqual(row['original_date'], '2025-01-15')
        self.assertEqual(row['original_amount'], 5000.0)

    def test_salt_determinism(self):
        """Same salt produces identical hashes across runs."""
        out1, _ = self._run_hash(salt='fixed-salt')
        out2, _ = self._run_hash(salt='fixed-salt',
                                 output_path=self.tmpdir / 'out2.csv')
        rows1 = read_csv(out1)
        rows2 = read_csv(out2)
        for r1, r2 in zip(rows1, rows2):
            self.assertEqual(r1['description'], r2['description'])

    def test_different_salt_different_hashes(self):
        """Different salts produce different hashes for same description."""
        out1, _ = self._run_hash(salt='salt-a')
        out2, _ = self._run_hash(salt='salt-b',
                                 output_path=self.tmpdir / 'out2.csv')
        rows1 = read_csv(out1)
        rows2 = read_csv(out2)
        # At least one hash should differ
        hashes_match = all(
            r1['description'] == r2['description']
            for r1, r2 in zip(rows1, rows2)
        )
        self.assertFalse(hashes_match)

    def test_category_inference(self):
        """Category is inferred from description when no category column."""
        simple_rows = [
            ('2025-01-15', 'aws hosting', '150.00', '', 'expense'),
            ('2025-01-20', 'starbucks coffee', '-5.50', '', 'expense'),
        ]
        p = self.tmpdir / 'simple.csv'
        write_csv(p, ['date', 'description', 'amount', 'category', 'type'], simple_rows)

        out, _ = self._run_hash(csv_path=p)
        rows = read_csv(out)
        self.assertEqual(rows[0]['category'], 'Software & IT')
        self.assertEqual(rows[1]['category'], 'Meals & Entertainment')

    def test_multiple_input_files(self):
        """Multiple CSVs are merged into single output."""
        p2 = self.tmpdir / 'test2.csv'
        extra_rows = [('2025-06-01', 'Extra Payment', '3000.00', 'Consulting Revenue', 'income')]
        write_csv(p2, CSV_HEADERS, extra_rows)

        out, _ = self._run_hash(extra_files=[p2])
        rows = read_csv(out)
        self.assertEqual(len(rows), len(SAMPLE_ROWS) + 1)

    def test_debit_credit_columns(self):
        """Handles CSV with separate debit/credit columns."""
        dc_rows = [
            ('2025-01-15', 'Payment Received', '0', '5000.00'),
            ('2025-01-20', 'Office Rent', '2000.00', '0'),
        ]
        p = self.tmpdir / 'dc.csv'
        write_csv(p, ['date', 'description', 'debit', 'credit'], dc_rows)

        out, _ = self._run_hash(csv_path=p)
        rows = read_csv(out)
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[0]['type'], 'income')
        self.assertEqual(rows[1]['type'], 'expense')
        self.assertEqual(rows[0]['amount'], '5000.00')
        self.assertEqual(rows[1]['amount'], '-2000.00')


class TestRenameCsv(unittest.TestCase):
    """Tests for rename-csv.py"""

    def setUp(self):
        self.tmpdir = Path(tempfile.mkdtemp())

        # Build a lookup JSON
        self.lookup_data = {
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
        self.lookup_path = self.tmpdir / 'lookup.json'
        with open(self.lookup_path, 'w') as f:
            json.dump(self.lookup_data, f)

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmpdir)

    def _run_rename(self, forecast_rows, output_path=None):
        forecast_path = self.tmpdir / 'forecast.csv'
        headers = ['date', 'description', 'category', 'type', 'amount',
                   'adjustments', 'running_balance', 'p10_balance', 'p90_balance',
                   'confidence', 'rationale', 'row_ids']
        write_csv(forecast_path, headers, forecast_rows)
        output_path = output_path or (self.tmpdir / 'restored.csv')
        rename_csv.main_inner(str(forecast_path), str(self.lookup_path), str(output_path))
        return read_csv(output_path)

    def test_restore_single_uuid(self):
        """Single UUID is restored to its original description."""
        rows = self._run_rename([
            ('2025-07-15', 'hash123', 'Consulting Revenue', 'income', '5000.00',
             '0.0', '30000.00', '29000.00', '31000.00',
             'recurring', 'Due ~15th', 'uuid-client-00001'),
        ])
        self.assertEqual(rows[0]['original_descriptions'], 'Client A Payment')

    def test_restore_multiple_uuids(self):
        """Multiple UUIDs are restored as semicolon-separated unique descriptions."""
        rows = self._run_rename([
            ('2025-07-15', 'hash123', 'Consulting Revenue', 'income', '5000.00',
             '0.0', '30000.00', '29000.00', '31000.00',
             'recurring', 'Due ~15th', 'uuid-client-00001,uuid-client-00002'),
        ])
        # Both UUIDs map to same description, so unique set has 1 entry
        self.assertEqual(rows[0]['original_descriptions'], 'Client A Payment')

    def test_restore_different_uuids(self):
        """Multiple UUIDs from different merchants produce combined descriptions."""
        rows = self._run_rename([
            ('2025-07-15', 'hash789', 'Mixed', 'expense', '-2000.00',
             '0.0', '28000.00', '27000.00', '29000.00',
             'recurring', 'Due ~20th', 'uuid-client-00001,uuid-rent-00001'),
        ])
        descs = rows[0]['original_descriptions'].split('; ')
        self.assertIn('Client A Payment', descs)
        self.assertIn('Office Rent', descs)

    def test_empty_row_ids(self):
        """Rows without row_ids pass through unchanged."""
        rows = self._run_rename([
            ('2025-06-12', 'Balance Forward', '', 'balance_forward', '0.0',
             '0.0', '25000.00', '25000.00', '25000.00',
             'high', 'Starting balance', ''),
        ])
        self.assertEqual(rows[0]['original_descriptions'], '')

    def test_unknown_uuid(self):
        """Unknown UUIDs get a fallback placeholder."""
        rows = self._run_rename([
            ('2025-07-15', 'hashX', 'Unknown', 'income', '100.00',
             '0.0', '25100.00', '25000.00', '25200.00',
             'low', 'Unknown event', 'nonexistent-uuid-12345'),
        ])
        self.assertIn('unknown', rows[0]['original_descriptions'].lower())


class TestIncomeForecastRowIds(unittest.TestCase):
    """Tests for income-forecast.py --row-ids flag"""

    def setUp(self):
        self.tmpdir = Path(tempfile.mkdtemp())

        # Create an anonymized CSV with row_ids from hash-csv
        # We'll use 6 months of data with clear recurring patterns
        self.rows_6mo = [
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
        self.csv_path = self.tmpdir / 'anonymized.csv'
        headers = ['date', 'description', 'amount', 'category', 'type', 'row_id']
        write_csv(self.csv_path, headers, self.rows_6mo)

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmpdir)

    def test_row_ids_column_present(self):
        """Output CSV has row_ids column when --row-ids is enabled."""
        out = str(self.tmpdir / 'forecast.csv')

        # Parse CLI args programmatically
        import argparse
        parser = income_forecast.build_parser()
        args = parser.parse_args([
            '--csv', str(self.csv_path),
            '--balance', '25000',
            '--horizon', '90',
            '--output', out,
            '--seed', '42',
            '--row-ids',
        ])
        income_forecast.run(args)

        with open(out, encoding='utf-8') as f:
            reader = csv.reader(f)
            headers = next(reader)
        self.assertIn('row_ids', headers)

    def test_no_row_ids_without_flag(self):
        """Output CSV does NOT have row_ids column without flag."""
        out = str(self.tmpdir / 'forecast-no-ids.csv')

        parser = income_forecast.build_parser()
        args = parser.parse_args([
            '--csv', str(self.csv_path),
            '--balance', '25000',
            '--horizon', '90',
            '--output', out,
            '--seed', '42',
        ])
        income_forecast.run(args)

        with open(out, encoding='utf-8') as f:
            reader = csv.reader(f)
            headers = next(reader)
        self.assertNotIn('row_ids', headers)

    def test_recurring_events_have_row_ids(self):
        """Recurring event rows contain comma-separated source UUIDs."""
        out = str(self.tmpdir / 'forecast-ids.csv')

        parser = income_forecast.build_parser()
        args = parser.parse_args([
            '--csv', str(self.csv_path),
            '--balance', '25000',
            '--horizon', '90',
            '--output', out,
            '--seed', '42',
            '--row-ids',
        ])
        income_forecast.run(args)

        rows = read_csv(out)
        id_rows = [r for r in rows if (r.get('row_ids') or '').strip()]
        self.assertGreater(len(id_rows), 0)

        # Each row_ids cell should contain UUIDs we recognize
        for r in id_rows:
            ids = r['row_ids'].split(',')
            for rid in ids:
                rid = rid.strip('" ')
                # Should be one of our test IDs
                self.assertTrue(rid.startswith('id-') or rid == '')

    def test_balance_forward_no_row_ids(self):
        """Balance forward row has empty row_ids."""
        out = str(self.tmpdir / 'forecast-bf.csv')

        parser = income_forecast.build_parser()
        args = parser.parse_args([
            '--csv', str(self.csv_path),
            '--balance', '25000',
            '--horizon', '90',
            '--output', out,
            '--seed', '42',
            '--row-ids',
        ])
        income_forecast.run(args)

        rows = read_csv(out)
        bf = rows[0]
        self.assertEqual(bf['type'], 'balance_forward')
        self.assertEqual((bf.get('row_ids') or '').strip(), '')

    def test_recurring_detection_works_with_hashed(self):
        """Recurring detection finds patterns from hashed descriptions."""
        out = str(self.tmpdir / 'forecast-recur.csv')

        parser = income_forecast.build_parser()
        args = parser.parse_args([
            '--csv', str(self.csv_path),
            '--balance', '25000',
            '--horizon', '90',
            '--output', out,
            '--seed', '42',
            '--row-ids',
        ])
        income_forecast.run(args)

        rows = read_csv(out)
        recurring = [r for r in rows if r['confidence'] == 'recurring']
        # Should have MERCHANT_A (income ~15th) and MERCHANT_B (expense ~20th)
        self.assertGreaterEqual(len(recurring), 4)  # 2 patterns x 3 months
        incomes = [r for r in recurring if r['type'] == 'income']
        expenses = [r for r in recurring if r['type'] == 'expense']
        self.assertGreaterEqual(len(incomes), 2)
        self.assertGreaterEqual(len(expenses), 2)


if __name__ == '__main__':
    unittest.main()
