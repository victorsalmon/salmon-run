#!/usr/bin/env python3
"""rename-csv.py — Restore original transaction descriptions to a forecast CSV.

Takes a forecast CSV (produced by income-forecast.py with --row-ids) and a
lookup JSON (produced by hash-csv.py) and writes a restored CSV with original
merchant descriptions back in place of hashed descriptions.

Usage:
  python rename-csv.py --forecast forecast.csv --lookup anonymized-lookup.json
                       --output forecast-restored.csv
"""

import csv
import sys
import argparse
import json
from pathlib import Path


def main_inner(forecast_path, lookup_path, output_path, _quiet=False):
    """Core logic: restore original descriptions and write restored CSV.

    Args:
        forecast_path: Path to forecast CSV (from income-forecast.py --row-ids).
        lookup_path: Path to lookup JSON (from hash-csv.py).
        output_path: Path for output restored CSV.
        _quiet: Suppress stderr output.

    Returns:
        (output_path, restored_count)
    """
    output_path = Path(output_path)

    with open(lookup_path, 'r', encoding='utf-8') as f:
        lookup = json.load(f)

    lookup_rows = lookup.get('rows', {})
    salt = lookup.get('salt', '')
    if not _quiet:
        print(f"Loaded lookup: {len(lookup_rows)} rows (salt: {salt[:12]}...)", file=sys.stderr)

    with open(forecast_path, 'r', encoding='utf-8-sig') as f:
        reader = csv.DictReader(f)
        fieldnames = reader.fieldnames
        rows = list(reader)

    if not rows:
        print("ERROR: Forecast CSV is empty.", file=sys.stderr)
        raise SystemExit(1)

    has_row_ids = 'row_ids' in fieldnames
    if not has_row_ids and not _quiet:
        print("WARNING: No 'row_ids' column found in forecast CSV. "
              "Re-run income-forecast.py with --row-ids.", file=sys.stderr)

    out_fieldnames = []
    for fn in fieldnames:
        out_fieldnames.append('original_descriptions' if fn == 'row_ids' else fn)

    restored_count = 0
    out_rows = []
    for row in rows:
        out_row = dict(row)

        raw_ids = (row.get('row_ids') or '').strip()
        if has_row_ids and raw_ids:
            uuids = [u.strip() for u in raw_ids.split(',') if u.strip()]
            descriptions = []
            for uid in uuids:
                entry = lookup_rows.get(uid)
                if entry:
                    desc = entry.get('original_description', '').strip()
                    if desc and desc not in descriptions:
                        descriptions.append(desc)
                else:
                    descriptions.append(f'[unknown row_id: {uid[:8]}...]')

            out_row.pop('row_ids', None)
            out_row['original_descriptions'] = '; '.join(descriptions) if descriptions else ''
            restored_count += 1
        elif 'row_ids' in out_row:
            out_row.pop('row_ids', None)
            out_row['original_descriptions'] = ''

        out_rows.append(out_row)

    with open(output_path, 'w', newline='', encoding='utf-8') as f:
        writer = csv.DictWriter(f, fieldnames=out_fieldnames)
        writer.writeheader()
        writer.writerows(out_rows)

    if not _quiet:
        print(f"Processed {len(out_rows)} forecast rows", file=sys.stderr)
        print(f"Restored {restored_count} rows with original descriptions", file=sys.stderr)
        print(f"Wrote → {output_path}", file=sys.stderr)

    return str(output_path), restored_count


def main():
    parser = argparse.ArgumentParser(
        description='Restore original descriptions to a forecast CSV using a hash-csv lookup')
    parser.add_argument('--forecast', required=True,
                        help='Path to forecast CSV from income-forecast.py --row-ids')
    parser.add_argument('--lookup', required=True,
                        help='Path to lookup JSON from hash-csv.py')
    parser.add_argument('--output', '-o', default=None,
                        help='Output restored CSV path (default: <forecast-stem>-restored.csv)')
    args = parser.parse_args()

    forecast_path = Path(args.forecast)
    if not forecast_path.exists():
        print(f"ERROR: Forecast file not found: {args.forecast}", file=sys.stderr)
        sys.exit(1)

    lookup_path = Path(args.lookup)
    if not lookup_path.exists():
        print(f"ERROR: Lookup file not found: {args.lookup}", file=sys.stderr)
        sys.exit(1)

    output_path = args.output if args.output else \
        str(forecast_path.with_name(forecast_path.stem + '-restored.csv'))

    main_inner(str(forecast_path), str(lookup_path), output_path)


if __name__ == '__main__':
    main()
