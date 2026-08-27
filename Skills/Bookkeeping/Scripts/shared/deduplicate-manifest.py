#!/usr/bin/env python3
"""Deduplicate a CSV manifest file.

For rows with the same OriginalFilename, keeps only the latest.
For rows with the same Date+Amount, prefers the one without "Vendu par" in vendor.
Saves the deduplicated result to a new file.
"""

import csv
import os
import sys


def deduplicate_manifest(input_path):
    rows = []
    with open(input_path, 'r', encoding='utf-8') as f:
        reader = csv.DictReader(f)
        fieldnames = reader.fieldnames
        for row in reader:
            rows.append(row)

    if not rows:
        print('No rows found in manifest.')
        return

    seen_filename = {}
    for i, row in enumerate(rows):
        fn = row.get('OriginalFilename', '')
        if fn:
            if fn in seen_filename:
                prev_idx = seen_filename[fn]
                if _row_is_newer(row, rows[prev_idx]):
                    seen_filename[fn] = i
            else:
                seen_filename[fn] = i

    keep_indices = set(seen_filename.values())

    date_amount_groups = {}
    for i in keep_indices:
        row = rows[i]
        key = (row.get('Date', ''), row.get('Amount', ''))
        if key not in date_amount_groups:
            date_amount_groups[key] = []
        date_amount_groups[key].append(i)

    final_indices = set()
    for key, indices in date_amount_groups.items():
        if len(indices) > 1:
            chosen = _prefer_non_vendu(indices, rows)
            final_indices.add(chosen)
        else:
            final_indices.add(indices[0])

    deduped = [rows[i] for i in sorted(final_indices)]
    base, ext = os.path.splitext(input_path)
    output_path = f'{base}-deduped{ext}'

    with open(output_path, 'w', newline='', encoding='utf-8') as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(deduped)

    removed = len(rows) - len(deduped)
    print(f'Deduplicated {input_path}: {len(rows)} -> {len(deduped)} rows ({removed} removed)')
    print(f'Output: {output_path}')
    return output_path


def _row_is_newer(a, b):
    for field in ('LastModified', 'Modified', 'Date'):
        va = a.get(field, '')
        vb = b.get(field, '')
        if va and vb:
            return va >= vb
    return True


def _prefer_non_vendu(indices, rows):
    non_vendu = None
    for i in indices:
        vendor = rows[i].get('Vendor', rows[i].get('vendor', '')).lower()
        if 'vendu par' not in vendor:
            non_vendu = i
            break
    return non_vendu if non_vendu is not None else indices[0]


def main():
    if len(sys.argv) < 2:
        print('Usage: python deduplicate-manifest.py <manifest.csv> [manifest2.csv ...]')
        sys.exit(1)

    for path in sys.argv[1:]:
        if not os.path.isfile(path):
            print(f'Skipping: not a file — {path}', file=sys.stderr)
            continue
        deduplicate_manifest(path)


if __name__ == '__main__':
    main()
