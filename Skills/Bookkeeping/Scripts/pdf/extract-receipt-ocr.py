#!/usr/bin/env python3
"""Extract receipt data from images using GPT-4o-mini vision via OpenRouter."""

import argparse
import base64
import hashlib
import json
import os
import re
import sys
import time
from datetime import datetime
from pathlib import Path

import requests

EXTRACTION_FIELDS = [
    "vendor", "date", "amount", "currency", "receipt_number",
    "items", "subtotal", "tax", "total", "summary",
]


def image_hash(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            h.update(chunk)
    return h.hexdigest()


def load_cache(cache_path):
    try:
        with open(cache_path, "r", encoding="utf-8") as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def save_cache(cache_path, cache):
    with open(cache_path, "w", encoding="utf-8") as f:
        json.dump(cache, f, indent=2, ensure_ascii=False)


def call_openrouter_vision(image_path, api_key, model):
    with open(image_path, "rb") as f:
        img_bytes = f.read()
    b64 = base64.b64encode(img_bytes).decode("utf-8")

    ext = Path(image_path).suffix.lower().lstrip(".")
    mime = {"jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png"}.get(ext, "image/jpeg")

    prompt = """Analyze this receipt image. Return ONLY valid JSON with these fields:
{
  "vendor": "merchant or company name",
  "date": "YYYY-MM-DD or empty string if not visible",
  "amount": 0.00,
  "currency": "CAD or USD or empty string",
  "receipt_number": "receipt/invoice number or empty string",
  "items": ["item description 1", "item description 2"],
  "subtotal": 0.00,
  "tax": 0.00,
  "total": 0.00,
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
                {"type": "image_url", "image_url": {"url": f"data:{mime};base64,{b64}"}}
            ]}
        ],
        "max_tokens": 1000,
        "temperature": 0.1,
    }

    max_retries = 2
    resp = None
    for attempt in range(max_retries):
        try:
            resp = requests.post(
                "https://openrouter.ai/api/v1/chat/completions",
                headers={
                    "Authorization": f"Bearer {api_key}",
                    "X-Title": "extract-receipt-ocr",
                    "Content-Type": "application/json",
                },
                json=body,
                timeout=60,
            )
            if resp.status_code == 429:
                wait = min(30, 5 * (attempt + 1))
                time.sleep(wait)
                continue
            resp.raise_for_status()
            break
        except requests.exceptions.RequestException as e:
            if attempt == max_retries - 1:
                return None, f"API error: {e}"
            time.sleep(2)
    else:
        if resp is None:
            return None, "API error: no response received after all retries"
        return None, "API error after retries"

    data = resp.json()
    content = data.get("choices", [{}])[0].get("message", {}).get("content", "")

    json_match = re.search(r"\{[^{}]*\}", content, re.DOTALL)
    if not json_match:
        return None, "No JSON in response"

    try:
        parsed = json.loads(json_match.group())
    except json.JSONDecodeError as e:
        return None, f"JSON parse error: {e}"

    return parsed, None


def write_sidecar(output_path, fields):
    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(fields, f, indent=2, ensure_ascii=False)


def main():
    parser = argparse.ArgumentParser(description="Extract receipt data from images via OpenRouter vision")
    parser.add_argument("paths", nargs="*", metavar="IMAGE", help="Image file(s) to process")
    parser.add_argument("--input-dir", help="Directory containing images (alternative to positional paths)")
    parser.add_argument("--output-dir", required=True, help="Output directory for JSON sidecars")
    parser.add_argument("--model", default="gpt-4o-mini", help="Vision model (default: gpt-4o-mini)")
    parser.add_argument("--api-key-env", default="OPENROUTER_ORCH_KEY",
                        help="Environment variable name for API key (default: OPENROUTER_ORCH_KEY, fallback: OPENROUTER_API_KEY)")
    parser.add_argument("--cache-file", help="Path to JSON cache file for hash-based dedup")
    args = parser.parse_args()

    api_key = os.environ.get(args.api_key_env)
    if not api_key:
        print(f"ERROR: {args.api_key_env} environment variable not set", file=sys.stderr)
        sys.exit(1)

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    images = []
    if args.input_dir:
        for ext in ("*.jpg", "*.jpeg", "*.png"):
            images.extend(sorted(Path(args.input_dir).glob(ext)))
    elif args.paths:
        images = [Path(p) for p in args.paths]
    else:
        print("ERROR: Provide --input-dir or positional image paths", file=sys.stderr)
        sys.exit(1)

    cache = load_cache(args.cache_file) if args.cache_file else {}
    cache_modified = False
    had_error = False

    for img_path in images:
        if not img_path.exists():
            print(f"SKIP Not found: {img_path}", file=sys.stderr)
            continue

        h = image_hash(img_path)

        if args.cache_file and h in cache:
            cached = cache[h]
            sidecar_path = output_dir / f"{img_path.stem}.json"
            write_sidecar(sidecar_path, cached)
            status = cached.get("error_status", "ok")
            if status == "ok":
                print(f"CACHED {img_path.name} -> {sidecar_path.name}")
            else:
                print(f"CACHED {img_path.name} (error: {status})")
            continue

        fields = {
            "vendor": "", "date": "", "amount": 0, "currency": "",
            "receipt_number": "", "items": [], "subtotal": 0, "tax": 0,
            "total": 0, "summary": "", "source": img_path.name,
            "extracted_at": datetime.now().isoformat(),
            "hash": h,
        }

        parsed, err = call_openrouter_vision(img_path, api_key, args.model)

        if err or not parsed:
            fields["error_status"] = err or "unknown error"
            had_error = True
            print(f"ERROR {img_path.name} - {fields['error_status']}", file=sys.stderr)
        else:
            for key in EXTRACTION_FIELDS:
                if key in parsed and parsed[key] not in (None, "", []):
                    fields[key] = parsed[key]

        sidecar_path = output_dir / f"{img_path.stem}.json"
        write_sidecar(sidecar_path, fields)

        if args.cache_file:
            cache[h] = fields
            cache_modified = True

        if "error_status" not in fields:
            total_display = fields.get("total") or fields.get("amount") or 0
            print(f"OK   {img_path.name} | {fields.get('vendor', '?')} | ${total_display}")

    if args.cache_file and cache_modified:
        save_cache(args.cache_file, cache)

    sys.exit(1 if had_error else 0)


if __name__ == "__main__":
    main()
