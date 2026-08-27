#!/usr/bin/env python3
"""Phase 1: PDF re-extraction with improved pdfplumber patterns.

Strategy (from the process-receipts skill's Lessons Learned):
- Strategy 1: Keyword-labeled dates (date:, order date:, posted:, Date de:, Invoice date / Date de facturation:)
- Strategy 2: Scan entire text for ANY date pattern, filter by year (2024-2027)
- Strategy 3: Scan entire text for AMOUNT patterns (Total, Total a payer, Total payable, Grand Total)
- For each PDF, prefer pdfplumber text extraction over vision if text is sufficient
- Fall back to vision (pypdfium2 + GPT-4o) if pdfplumber returns empty/partial text

Outputs:
- Updates _manifest.csv with new date/amount/vendor
- Renames PDF to canonical name
- Creates .md and .csv sidecars
"""
import argparse
import csv
import hashlib
import json
import os
import re
import sys
import time
from datetime import datetime, date
from pathlib import Path

import pdfplumber
import pypdfium2 as pdfium
import requests

# Date patterns — multiple strategies
DATE_PATTERNS = [
    # Strategy 1: keyword-labeled dates
    (re.compile(r"(?:invoice\s*date|date\s*of\s*invoice|date\s*issued|order\s*date|date|posted|issued|billing\s*date|date\s*de\s*facturation|date\s*de\s*l.{1,3}facture)[\s:]*(\d{1,2}\s+\w+\s+\d{4})", re.I), "%d %B %Y"),
    (re.compile(r"(?:invoice\s*date|date\s*of\s*invoice|date\s*issued|order\s*date|date|posted|issued|billing\s*date|date\s*de\s*facturation|date\s*de\s*l.{1,3}facture)[\s:]*(\w+\s+\d{1,2},?\s+\d{4})", re.I), "%B %d, %Y"),
    (re.compile(r"(?:invoice\s*date|date\s*of\s*invoice|date\s*issued|order\s*date|date|posted|issued|billing\s*date|date\s*de\s*facturation|date\s*de\s*l.{1,3}facture)[\s:]*(\d{4}-\d{2}-\d{2})", re.I), "%Y-%m-%d"),
    (re.compile(r"(?:invoice\s*date|date\s*of\s*invoice|date\s*issued|order\s*date|date|posted|issued|billing\s*date|date\s*de\s*facturation|date\s*de\s*l.{1,3}facture)[\s:]*(\d{1,2}/\d{1,2}/\d{4})", re.I), "%m/%d/%Y"),
    (re.compile(r"(?:invoice\s*date|date\s*of\s*invoice|date\s*issued|order\s*date|date|posted|issued|billing\s*date|date\s*de\s*facturation|date\s*de\s*l.{1,3}facture)[\s:]*(\d{1,2}/\d{1,2}/\d{2})", re.I), "%m/%d/%y"),
    (re.compile(r"(?:invoice\s*date|date\s*of\s*invoice|date\s*issued|order\s*date|date|posted|issued|billing\s*date|date\s*de\s*facturation|date\s*de\s*l.{1,3}facture)[\s:]*(\d{1,2}-\d{1,2}-\d{4})", re.I), "%d-%m-%Y"),
    (re.compile(r"(?:invoice\s*date|date\s*of\s*invoice|date\s*issued|order\s*date|date|posted|issued|billing\s*date|date\s*de\s*facturation|date\s*de\s*l.{1,3}facture)[\s:]*(\d{1,2}\.\d{1,2}\.\d{4})", re.I), "%d.%m.%Y"),
    (re.compile(r"(?:invoice\s*date|date\s*of\s*invoice|date\s*issued|order\s*date|date|posted|issued|billing\s*date|date\s*de\s*facturation|date\s*de\s*l.{1,3}facture)[\s:]*(\d{4}\.\d{2}\.\d{2})", re.I), "%Y.%m.%d"),
    # Strategy 2: generic date patterns (no keyword)
    (re.compile(r"\b(\d{4}-\d{2}-\d{2})\b"), "%Y-%m-%d"),
    (re.compile(r"\b(\d{1,2}/\d{1,2}/\d{4})\b"), "%m/%d/%Y"),
    (re.compile(r"\b(\d{1,2}-\d{1,2}-\d{4})\b"), "%d-%m-%Y"),
    (re.compile(r"\b(\d{4}/\d{2}/\d{2})\b"), "%Y/%m/%d"),
    (re.compile(r"\b(\d{1,2}\s+(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\s+\d{4})\b", re.I), "%d %b %Y"),
    (re.compile(r"\b((?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\s+\d{1,2},?\s+\d{4})\b", re.I), "%b %d, %Y"),
]

# Amount patterns
AMOUNT_PATTERNS = [
    # Total patterns (most reliable)
    re.compile(r"(?:grand\s*total|total\s*due|amount\s*due|total\s*amount|total\s*\(?cad\)?|total\s*\(?usd\)?|total\s*payable|total\s*a\s*payer|total)[\s:$]*(\d{1,4}(?:[,.]\d{3})*[.,]\d{2})", re.I),
    re.compile(r"(?:balance\s*due|amount\s*charged|amount\s*paid|paid)[\s:$]*(\d{1,4}(?:[,.]\d{3})*[.,]\d{2})", re.I),
    re.compile(r"(?:subtotal|sub-total|sub\s*total)[\s:$]*(\d{1,4}(?:[,.]\d{3})*[.,]\d{2})", re.I),
]

# Vendor patterns
VENDOR_PATTERNS = [
    # Amazon invoice pattern: "Sold by: VENDOR" or "Vendu par: VENDOR"
    re.compile(r"(?:sold\s*by|vendu\s*par)[\s:]+([^\n\r]+?)(?=\s*(?:$|\n|\r|GST|HST|Tax|Invoice))", re.I),
    # Common header patterns
    re.compile(r"^(?:from|merchant|vendor)[\s:]+([^\n\r]+?)(?=\s*(?:$|\n|\r|Invoice|Receipt))", re.I),
]


def extract_with_pdfplumber(pdf_path: Path):
    """Extract date, amount, vendor from a PDF using pdfplumber.

    Returns dict with: date (str YYYY-MM-DD or ''), amount (float or 0), vendor (str),
    raw_text (str), page_count (int), extraction_method (str).
    """
    result = {
        "date": "",
        "amount": 0.0,
        "vendor": "",
        "raw_text": "",
        "page_count": 0,
        "extraction_method": "pdfplumber",
    }

    try:
        with pdfplumber.open(pdf_path) as pdf:
            result["page_count"] = len(pdf.pages)
            full_text = "\n".join(p.extract_text() or "" for p in pdf.pages)
            result["raw_text"] = full_text
    except Exception as e:
        result["error"] = f"pdfplumber error: {e}"
        return result

    if not full_text.strip():
        result["extraction_method"] = "pdfplumber-empty"
        return result

    # Extract date
    for pattern, fmt in DATE_PATTERNS:
        match = pattern.search(full_text)
        if match:
            date_str = match.group(1).strip()
            try:
                dt = datetime.strptime(date_str, fmt).date()
                # Year filter: only accept 2024-2027 (active period)
                if 2024 <= dt.year <= 2027:
                    result["date"] = dt.isoformat()
                    break
            except ValueError:
                continue

    # Extract amount — prefer "Total" matches, fall back to largest number
    amount_candidates = []
    for pattern in AMOUNT_PATTERNS:
        for match in pattern.finditer(full_text):
            amt_str = match.group(1).replace(",", "")
            try:
                amt = float(amt_str)
                amount_candidates.append(amt)
            except ValueError:
                continue

    if amount_candidates:
        # Take the largest amount (most likely the total)
        result["amount"] = max(amount_candidates)

    # Extract vendor
    for pattern in VENDOR_PATTERNS:
        match = pattern.search(full_text)
        if match:
            vendor = match.group(1).strip()
            # Clean up
            vendor = re.sub(r"\s+", " ", vendor).strip()
            # Remove common leading patterns
            vendor = re.sub(r"^[/\s\\]+", "", vendor)
            # Remove common trailing patterns
            vendor = re.sub(r"\s*\(.*?\)\s*$", "", vendor)
            # Skip generic vendor names
            if vendor.lower() not in ("amazon.com.ca ulc", "amazon.ca"):
                result["vendor"] = vendor
                break
            else:
                # Generic "Amazon" — try to get a more specific seller
                result["vendor"] = vendor
                # Continue trying other patterns to get a more specific vendor
                continue

    return result


def extract_with_vision(pdf_path: Path, api_key: str, model: str = "openai/gpt-4o"):
    """Fallback: convert PDF to image, then send to vision model."""
    result = {
        "date": "",
        "amount": 0.0,
        "vendor": "",
        "raw_text": "",
        "page_count": 0,
        "extraction_method": f"vision-{model}",
    }

    # Convert first page to image
    try:
        pdf = pdfium.PdfDocument(str(pdf_path))
        result["page_count"] = len(pdf)
        if len(pdf) == 0:
            return result
        page = pdf[0]
        pil_image = page.render(scale=2).to_pil()
        # Save to bytes
        import io
        img_bytes_io = io.BytesIO()
        pil_image.save(img_bytes_io, format="JPEG", quality=85)
        img_bytes = img_bytes_io.getvalue()
    except Exception as e:
        result["error"] = f"pdf-to-image error: {e}"
        return result

    # Call vision API
    import base64
    b64 = base64.b64encode(img_bytes).decode("utf-8")

    prompt = """Analyze this receipt/invoice image. Return ONLY valid JSON with these fields:
{
  "vendor": "merchant or company name (the SELLER if Amazon, look for 'Sold by' or 'Vendu par')",
  "date": "YYYY-MM-DD or empty string if not visible",
  "amount": 0.00,
  "currency": "CAD or USD or empty string",
  "summary": "brief description under 50 chars"
}
Rules:
- amount must be the TOTAL charged (including tax)
- If this is not a receipt/invoice, set vendor to empty string
- Return ONLY the JSON object, no other text"""

    body = {
        "model": model,
        "messages": [
            {"role": "system", "content": prompt},
            {"role": "user", "content": [
                {"type": "text", "text": "Extract receipt data from this image."},
                {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{b64}"}}
            ]}
        ],
        "max_tokens": 500,
        "temperature": 0.1,
    }

    try:
        resp = requests.post(
            "https://openrouter.ai/api/v1/chat/completions",
            headers={
                "Authorization": f"Bearer {api_key}",
                "X-Title": "phase1-pdf-vision",
                "Content-Type": "application/json",
            },
            json=body,
            timeout=60,
        )
        resp.raise_for_status()
        data = resp.json()
        content = data.get("choices", [{}])[0].get("message", {}).get("content", "")

        json_match = re.search(r"\{[^{}]*\}", content, re.DOTALL)
        if json_match:
            parsed = json.loads(json_match.group())
            result["vendor"] = parsed.get("vendor", "")
            result["date"] = parsed.get("date", "")
            result["amount"] = float(parsed.get("amount", 0) or 0)
    except Exception as e:
        result["error"] = f"vision API error: {e}"

    return result


def process_pdf(pdf_path: Path, api_key: str, vision_model: str = "openai/gpt-4o"):
    """Process a single PDF. Try pdfplumber first, vision as fallback."""
    result = extract_with_pdfplumber(pdf_path)

    # If pdfplumber failed (empty text, no date, no amount), try vision
    if (not result.get("date") or result.get("amount", 0) == 0) and api_key:
        vision_result = extract_with_vision(pdf_path, api_key, vision_model)
        # Only use vision result if it has more data
        if vision_result.get("date") or vision_result.get("amount", 0) > 0 or vision_result.get("vendor"):
            # Merge: prefer vision's data where pdfplumber didn't find anything
            if not result.get("date") and vision_result.get("date"):
                result["date"] = vision_result["date"]
            if result.get("amount", 0) == 0 and vision_result.get("amount", 0) > 0:
                result["amount"] = vision_result["amount"]
            if not result.get("vendor") and vision_result.get("vendor"):
                result["vendor"] = vision_result["vendor"]
            if vision_result.get("error"):
                result["vision_error"] = vision_result["error"]
            result["extraction_method"] = f"pdfplumber+vision-{vision_model}"

    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input-dir", required=True, help="Directory with PDFs to re-process")
    parser.add_argument("--manifest", required=True, help="Path to _manifest.csv")
    parser.add_argument("--output", help="Output JSON for results (default: stdout)")
    parser.add_argument("--vision-model", default="openai/gpt-4o", help="Vision model for PDF fallback")
    parser.add_argument("--skip-vision", action="store_true", help="Skip vision fallback (PDF-only)")
    args = parser.parse_args()

    api_key = os.environ.get("OPENROUTER_API_KEY") if not args.skip_vision else None
    if not args.skip_vision and not api_key:
        print("WARNING: OPENROUTER_API_KEY not set, vision fallback disabled", file=sys.stderr)
        api_key = None

    input_dir = Path(args.input_dir)
    pdfs = sorted(input_dir.glob("*.pdf"))
    print(f"Found {len(pdfs)} PDFs to process", file=sys.stderr)

    results = []
    for i, pdf in enumerate(pdfs, 1):
        if i % 20 == 0 or i == len(pdfs):
            print(f"  [{i}/{len(pdfs)}] processing {pdf.name}...", file=sys.stderr)
        result = process_pdf(pdf, api_key, args.vision_model)
        result["filename"] = pdf.name
        result["path"] = str(pdf)
        results.append(result)

    if args.output:
        with open(args.output, "w", encoding="utf-8") as f:
            json.dump(results, f, indent=2, ensure_ascii=False)
        print(f"Results written to {args.output}", file=sys.stderr)
    else:
        print(json.dumps(results, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
