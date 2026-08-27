"""
Tests for Invoke-FillT5Slip.py — verifies field filling, multi-slip, and output integrity.
"""

import os, sys, tempfile, unittest

script_dir = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, script_dir)

assets_dir = os.path.join(script_dir, "..", "assets")
blank_pdf = os.path.join(assets_dir, "t5-fill-25e.pdf")


class TestFillT5Slip(unittest.TestCase):

    def setUp(self):
        if not os.path.exists(blank_pdf):
            self.skipTest(f"Blank PDF not found at {blank_pdf}")
        self.tmp = tempfile.mkdtemp()
        self.output = os.path.join(self.tmp, "test-t5.pdf")

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _load_mod(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("fillmod", os.path.join(script_dir, "Invoke-FillT5Slip.py"))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod

    def _fill(self, **kwargs):
        mod = self._load_mod()
        field_map = {}
        for k, v in kwargs.items():
            mapped = {
                "year": "Slip1Year",
                "payer": "Slip1PayersName",
                "recipient": "Slip1RecipientNameAdd",
                "box10": "Slip1Box10",
                "box11": "Slip1Box11",
                "box24": "Slip1Box24",
                "box25": "Slip1Box25",
                "box26": "Slip1Box26",
                "box27": "Slip1Box27",
            }.get(k)
            if mapped and v is not None:
                field_map[mapped] = str(v)
        return mod.fill_t5_slip(blank_pdf, self.output, field_map)

    def _verify(self, expected):
        import fitz
        doc = fitz.open(self.output)
        fields = {}
        for page in doc:
            for w in page.widgets():
                if w.field_value:
                    fields[w.field_name] = w.field_value
        doc.close()
        for key, val in expected.items():
            found = any(key in k and str(v) == str(val) for k, v in fields.items())
            self.assertTrue(found, f"Expected {key}={val} not found among {len(fields)} filled fields")
        return fields

    def _count_filled_per_slip(self):
        import fitz
        doc = fitz.open(self.output)
        counts = {1: 0, 2: 0, 3: 0}
        for page in doc:
            for w in page.widgets():
                if not w.field_value:
                    continue
                for s in [1, 2, 3]:
                    if f"Slip{s}[0]" in w.field_name:
                        counts[s] += 1
        doc.close()
        return counts

    def test_fills_dividend_boxes_across_all_slips(self):
        filled = self._fill(year="2026", payer="Test Corp", recipient="Test Person",
                            box24="1959.36", box25="2155.30")
        self.assertGreater(filled, 0)
        counts = self._count_filled_per_slip()
        for s in [1, 2, 3]:
            self.assertGreater(counts[s], 0, f"Slip{s} has no filled fields")

    def test_each_slip_has_same_fields(self):
        self._fill(year="2026", payer="Test Corp", recipient="Test Person",
                   box24="1959.36", box25="2155.30", box10="0.00")
        counts = self._count_filled_per_slip()
        self.assertEqual(counts[1], counts[2], "Slip1 and Slip2 field counts differ")
        self.assertEqual(counts[2], counts[3], "Slip2 and Slip3 field counts differ")

    def test_eligible_dividends(self):
        filled = self._fill(year="2026", payer="Test Corp", recipient="Test Person",
                            box10="1000.00", box11="1380.00")
        self._verify({"Slip1Box10": "1000.00", "Slip1Box11": "1380.00"})
        self.assertGreater(filled, 0)

    def test_output_is_valid_pdf(self):
        import fitz
        self._fill(year="2026", payer="Test Corp", recipient="Test Person",
                   box24="1959.36", box25="2155.30")
        doc = fitz.open(self.output)
        self.assertEqual(len(doc), 2, "T5 PDF should have 2 pages")
        doc.close()

    def test_empty_fields_remain_empty(self):
        import fitz
        self._fill(year="2026", payer="X", recipient="Y")
        doc = fitz.open(self.output)
        for page in doc:
            for w in page.widgets():
                name = w.field_name
                if "Slip1" in name and "Box" in name:
                    self.assertIn(w.field_value, [None, ""],
                                  f"Field '{name}' should be empty but got '{w.field_value}'")
        doc.close()


if __name__ == "__main__":
    unittest.main()
