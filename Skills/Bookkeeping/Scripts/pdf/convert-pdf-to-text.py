#!/usr/bin/env python3
"""Extract text from PDFs using pdfplumber with consistent settings."""

import argparse
import sys
from pathlib import Path

try:
    import pdfplumber
except ImportError:
    print("ERROR: pdfplumber is required. Install: pip install pdfplumber", file=sys.stderr)
    sys.exit(1)


def extract_text(pdf_path):
    pages = []
    with pdfplumber.open(pdf_path) as pdf:
        for i, page in enumerate(pdf.pages):
            t = page.extract_text(keep_blank_chars=True, x_tolerance=3)
            pages.append((i + 1, t or ""))
    return pages


def write_md(output_path, pages, source_name):
    with open(output_path, "w", encoding="utf-8") as f:
        f.write(f"# Text extraction: {source_name}\n\n")
        for page_num, text in pages:
            f.write(f"## Page {page_num}\n\n")
            f.write(text.strip() + "\n\n")


def main():
    parser = argparse.ArgumentParser(description="Extract text from PDFs using pdfplumber")
    parser.add_argument("paths", nargs="*", metavar="PDF", help="PDF file(s) to process")
    parser.add_argument("--input-dir", help="Directory containing PDFs (alternative to positional paths)")
    parser.add_argument("--output-dir", required=True, help="Output directory for .md extraction files")
    parser.add_argument("--ocr-fallback", action="store_true",
                        help="If pdfplumber returns empty text, call extract-receipt-ocr.py")
    args = parser.parse_args()

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    pdfs = []
    if args.input_dir:
        pdfs = sorted(Path(args.input_dir).glob("*.pdf"))
    elif args.paths:
        pdfs = [Path(p) for p in args.paths]
    else:
        print("ERROR: Provide --input-dir or positional PDF paths", file=sys.stderr)
        sys.exit(1)

    found_text = False
    for pdf_path in pdfs:
        if not pdf_path.exists():
            print(f"SKIP Not found: {pdf_path}", file=sys.stderr)
            continue

        pages = extract_text(pdf_path)
        has_text = any(t.strip() for _, t in pages)

        md_path = output_dir / f"{pdf_path.stem}.md"
        write_md(md_path, pages, pdf_path.name)

        if has_text:
            found_text = True
            print(f"OK  {pdf_path.name} -> {md_path.name}")
        else:
            print(f"EMPTY {pdf_path.name} - no extractable text", file=sys.stderr)
            if args.ocr_fallback:
                print(f"  OCR fallback requested for {pdf_path.name}", file=sys.stderr)

    sys.exit(0 if found_text else 2)


if __name__ == "__main__":
    main()
