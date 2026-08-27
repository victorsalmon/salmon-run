#!/usr/bin/env python3
"""Render PDF pages to JPEG images using PyMuPDF (fitz)."""

import argparse
import hashlib
import json
import os
import sys
from pathlib import Path

try:
    import fitz
except ImportError:
    print("ERROR: PyMuPDF (fitz) is required. Install: pip install PyMuPDF", file=sys.stderr)
    sys.exit(1)


def render_pdf(pdf_path, output_dir, dpi):
    pages = []
    try:
        doc = fitz.open(pdf_path)
    except Exception as e:
        print(f"FAILED: {pdf_path} - {e}", file=sys.stderr)
        return pages

    base = Path(pdf_path).stem
    for i, page in enumerate(doc):
        pix = page.get_pixmap(dpi=dpi)
        fn = f"{base}_p{i+1}.jpg"
        outpath = Path(output_dir) / fn
        pix.save(str(outpath))
        with open(outpath, "rb") as fh:
            h = hashlib.sha256(fh.read()).hexdigest()
        pages.append({"source": Path(pdf_path).name, "page": i + 1, "file": fn, "hash": h})

    doc.close()
    return pages


def main():
    parser = argparse.ArgumentParser(description="Render PDF pages to JPEG images")
    parser.add_argument("--input-dir", required=True, help="Directory containing source PDFs")
    parser.add_argument("--output-dir", required=True, help="Directory for output JPEGs")
    parser.add_argument("--dpi", type=int, default=200, help="Render DPI (default: 200)")
    parser.add_argument("--hash-file", help="Path to write JSON hash manifest")
    args = parser.parse_args()

    input_dir = Path(args.input_dir)
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    all_results = []
    for f in sorted(input_dir.iterdir()):
        if f.suffix.lower() == ".pdf":
            pages = render_pdf(f, output_dir, args.dpi)
            all_results.extend(pages)
            for p in pages:
                print(f"  {p['file']}")

    if args.hash_file:
        with open(args.hash_file, "w") as fh:
            json.dump(all_results, fh)

    print(f"Done: {len(all_results)} page(s) from {input_dir}")


if __name__ == "__main__":
    main()
