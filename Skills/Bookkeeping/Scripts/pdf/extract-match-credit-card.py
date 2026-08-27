#!/usr/bin/env python3
"""Composite orchestrator for credit card receipt extraction & matching.

Delegates PDF/image extraction to atomic scripts (convert-pdf-to-text.py,
convert-pdf-to-image.py, extract-receipt-ocr.py), then performs statement
matching and file organization.
"""

import argparse
import csv
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timedelta
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent


def load_entity_config(entity_name, card_suffix):
    entities_path = None
    candidates = [
        Path.cwd() / "Skills" / "Bookkeeping" / "cloud-books-entities.json",
        SCRIPT_DIR.parent.parent / "cloud-books-entities.json",
        SCRIPT_DIR / ".." / ".." / "cloud-books-entities.json",
    ]
    for c in candidates:
        resolved = c.resolve()
        if resolved.exists():
            entities_path = resolved
            break
    if not entities_path:
        print("ERROR: cloud-books-entities.json not found", file=sys.stderr)
        sys.exit(1)

    with open(entities_path, "r", encoding="utf-8") as f:
        config = json.load(f)

    entity = config.get("entities", {}).get(entity_name)
    if not entity:
        print(f"ERROR: Entity '{entity_name}' not found in config", file=sys.stderr)
        sys.exit(1)

    card = config.get("credit_cards", {}).get(card_suffix)
    if not card:
        print(f"ERROR: Card suffix '{card_suffix}' not found in config", file=sys.stderr)
        sys.exit(1)

    return config, entity, card


def run_script(script_name, *args):
    script_path = SCRIPT_DIR / script_name
    if not script_path.exists():
        print(f"ERROR: {script_path} not found", file=sys.stderr)
        sys.exit(1)
    result = subprocess.run(
        [sys.executable, str(script_path)] + list(args),
        capture_output=True, text=True, timeout=300
    )
    if result.returncode not in (0, 2):
        print(f"WARNING: {script_name} exited {result.returncode}", file=sys.stderr)
        print(result.stderr, file=sys.stderr)
    return result


def parse_date(s):
    if not s or s.strip() == "":
        return None
    s = s.strip()
    s = re.sub(r'(\d+)(st|nd|rd|th)\b', r'\1', s)
    for fmt in ["%Y-%m-%d", "%m/%d/%Y", "%Y/%m/%d", "%m-%d-%Y", "%d-%m-%Y",
                "%B %d, %Y", "%b %d, %Y", "%B %d %Y", "%b %d %Y",
                "%d %B %Y", "%d %b %Y", "%Y%m%d",
                "%d-%b-%Y", "%d/%b/%Y", "%d-%B-%Y"]:
        try:
            return datetime.strptime(s, fmt).strftime("%Y-%m-%d")
        except ValueError:
            continue
    m = re.match(r"(\d{1,2})/(\d{1,2})/(\d{4})", s)
    if m:
        try:
            return datetime(int(m.group(3)), int(m.group(1)), int(m.group(2))).strftime("%Y-%m-%d")
        except:
            pass
    m = re.match(r"(\d{1,2})\.(\d{1,2})\.(\d{4})", s)
    if m:
        try:
            return datetime(int(m.group(3)), int(m.group(1)), int(m.group(2))).strftime("%Y-%m-%d")
        except:
            pass
    return None


def parse_date_from_filename(fname):
    name = os.path.splitext(fname)[0]
    m = re.search(r'(\d{4})[.-](\d{1,2})[.-](\d{1,2})', name)
    if m:
        try:
            return datetime(int(m.group(1)), int(m.group(2)), int(m.group(3))).strftime("%Y-%m-%d")
        except:
            pass
    m = re.search(r'(\d{1,2})[.-](\d{1,2})[.-](\d{4})', name)
    if m:
        y, mo, d = int(m.group(3)), int(m.group(1)), int(m.group(2))
        if 2024 <= y <= 2027 and 1 <= mo <= 12 and 1 <= d <= 31:
            return datetime(y, mo, d).strftime("%Y-%m-%d")
    m = re.search(r'(202[4-7])(0[1-9]|1[0-2])(0[1-9]|[12]\d|3[01])', name)
    if m:
        try:
            return datetime(int(m.group(1)), int(m.group(2)), int(m.group(3))).strftime("%Y-%m-%d")
        except:
            pass
    months = {'jan':1,'feb':2,'mar':3,'apr':4,'may':5,'jun':6,'jul':7,'aug':8,'sep':9,'oct':10,'nov':11,'dec':12,
              'january':1,'february':2,'march':3,'april':4,'june':6,'july':7,'august':8,'september':9,'october':10,'november':11,'december':12}
    m = re.search(r'(?i)(\w+)\s+(\d{1,2})\s*,?\s*(202[4-7])', name)
    if m:
        mon = months.get(m.group(1).lower()[:3])
        if mon:
            try:
                return datetime(int(m.group(3)), mon, int(m.group(2))).strftime("%Y-%m-%d")
            except:
                pass
    m = re.match(r'(\d{1,2})[.-](\d{1,2})\s', name)
    if m:
        mo, d = int(m.group(1)), int(m.group(2))
        if 1 <= mo <= 12 and 1 <= d <= 31:
            return f"2025-{mo:02d}-{d:02d}"
    return None


def parse_amount(s):
    if not s:
        return 0.0
    s = str(s).replace(",", "").replace("$", "").replace("CAD", "").replace("USD", "").strip()
    m = re.search(r"-?[\d]+\.?\d*", s)
    if m:
        return abs(float(m.group()))
    return 0.0


def extract_card_number(text):
    patterns = [
        r'(?:card|mastercard|mc|visa)[:\s]*[*x]{0,4}(\d{4})',
        r'[*x]{4}[\s-]?(\d{4})',
        r'ending\s+(?:in\s+)?(\d{4})',
        r'\*{4}\s*(\d{4})',
        r'(?:xxxx|XXXX)[\s-]?(\d{4})',
    ]
    text_lower = text.lower()
    for pat in patterns:
        m = re.search(pat, text_lower)
        if m:
            return m.group(1)
    return None


def has_card_ref(text, card_suffix):
    if not text:
        return False
    for m in re.finditer(card_suffix, text):
        start = max(0, m.start() - 30)
        end = min(len(text), m.end() + 30)
        context = text[start:end]
        if re.search(r'(?:total|amount|balance|payment|due)\s*[:=]?\s*\$?\s*\d+\.?\d*.*' + card_suffix, context, re.I):
            continue
        if re.search(card_suffix + r'.*\$\s*\d+\.?\d*', context):
            continue
        return True
    return False


def is_credit_note(text, amount_str=""):
    if not text and not amount_str:
        return False
    if text and re.search(r'Credit\s+Note', text, re.I):
        return True
    if amount_str and re.match(r'^[cC]\$?\s*[\d]', amount_str.strip()):
        return True
    if amount_str and re.match(r'^[rR][\d]', amount_str.strip()):
        return True
    return False


def extract_from_text(full_text, card_suffix):
    result = {
        "vendor": None, "date": None, "amount": None, "currency": None,
        "card_last4": None, "has_card_ref": False, "raw_text": "",
        "date_source": None, "is_credit_note": False, "source": "pdfplumber"
    }

    result["raw_text"] = full_text[:3000]
    result["is_credit_note"] = is_credit_note(full_text)
    card = extract_card_number(full_text)
    result["card_last4"] = card
    result["has_card_ref"] = (card == card_suffix) or has_card_ref(full_text, card_suffix)

    accent_map = str.maketrans('àâäéèêëîïôöùûüçÀÂÄÉÈÊËÎÏÔÖÙÛÜÇ',
                                'aaaeeeeiioouuucAAAEEEEIIOOUUUC')
    normalized = full_text.translate(accent_map) if full_text else ""

    date_patterns = [
        r'Invoice\s+date\s*(?:/\s*Date\s+de\s+\w+)?\s*:\s*(\d{1,2}\s+\w+\s+\d{4})',
        r'Invoice\s+Date\s+(\d{1,2}\s+\w+\s+\d{4})',
        r'Order\s+date\s*(?:/\s*Date\s+de\s+\w+)?\s*:\s*(\d{1,2}\s+\w+\s+\d{4})',
        r'(?:date|posted|transaction)[:\s]*(\d{4}[-/]\d{1,2}[-/]\d{1,2})',
        r'(\d{1,2}\s+\w+\s+\d{4})',
        r'(\w+\s+\d{1,2},?\s*\d{4})',
        r'(\d{4}-\d{2}-\d{2})',
    ]
    for pat in date_patterns:
        for m in re.finditer(pat, normalized, re.I):
            ofs = m.start(1)
            raw_date = full_text[ofs:ofs + len(m.group(1))]
            d = parse_date(raw_date)
            if d:
                yr = int(d[:4])
                if 2024 <= yr <= 2027:
                    result["date"] = d
                    break
        if result["date"]:
            break

    amount_patterns = [
        r'Total\s+[^:]*[:\s]*\$?\s*([\d,]+\.?\d*)',
        r'Invoice\s+subtotal[^:]*[:\s]*\$?\s*([\d,]+\.?\d*)',
        r'(?:total|amount\s+charged|order\s+total|grand\s+total|payment\s+amount)[:\s]*\$?\s*([\d,]+\.?\d*)',
        r'(?:CAD|USD)\s*\$?\s*([\d,]+\.?\d*)',
        r'\$\s*([\d,]+\.\d{2})\b',
    ]
    amounts_found = []
    for pat in amount_patterns:
        for m in re.finditer(pat, normalized, re.I):
            amt = parse_amount(m.group(1))
            if amt > 0:
                amounts_found.append(amt)
    if amounts_found:
        result["amount"] = max(amounts_found)

    if re.search(r'\bUSD\b|\bUS\s*Dollar', normalized, re.I):
        result["currency"] = "USD"
    elif re.search(r'\bCAD\b|\bCA\$|\bCND', full_text, re.I):
        result["currency"] = "CAD"
    elif result["amount"]:
        result["currency"] = "CAD"

    vendor_patterns = [
        r'(?:sold\s+by|from|merchant|biller|payee|vendor)[:\s]*(.+?)(?:\n|$)',
        r'(?:amazon\.ca|amazon\.com)',
        r'(?:temu|aliexpress|squarespace|interserver|namecheap|bitwarden|openrouter|skool)',
    ]
    for pat in vendor_patterns:
        m = re.search(pat, full_text, re.I)
        if m:
            v = m.group(1).strip() if m.lastindex else m.group().strip()
            if len(v) > 3:
                result["vendor"] = v[:80]
                break

    if not result["vendor"]:
        for line in full_text.split("\n"):
            line = line.strip()
            if len(line) > 5 and not re.match(r'^[\d\s/\-:]+$', line):
                result["vendor"] = line[:80]
                break

    return result


def load_statement(path):
    transactions = []
    with open(path, "r", encoding="utf-8-sig") as f:
        reader = csv.DictReader(f)
        for row in reader:
            date_str = row.get("Transaction Date", "").strip()
            desc1 = row.get("Description 1", "").strip()
            desc2 = row.get("Description 2", "").strip()
            cad_str = row.get("CAD$", "").strip()
            usd_str = row.get("USD$", "").strip()

            d = None
            for fmt in ["%m/%d/%Y", "%Y-%m-%d", "%d/%m/%Y"]:
                try:
                    d = datetime.strptime(date_str, fmt)
                    break
                except:
                    pass

            cad_amt = 0.0
            if cad_str:
                try:
                    cad_amt = float(cad_str.replace(",", ""))
                except:
                    pass

            usd_amt = 0.0
            if usd_str:
                try:
                    usd_amt = float(usd_str.replace(",", ""))
                except:
                    pass

            transactions.append({
                "date": d,
                "date_str": date_str,
                "desc1": desc1,
                "desc2": desc2,
                "cad": cad_amt,
                "usd": usd_amt,
                "associated_receipt": "",
                "renamed_file": ""
            })
    return transactions


def match_receipt(receipt, transactions):
    if not receipt["amount"] or receipt["amount"] == 0:
        return None, "NO_AMOUNT"

    r_amt = receipt["amount"]
    r_date = None
    if receipt["date"]:
        try:
            r_date = datetime.strptime(receipt["date"], "%Y-%m-%d")
        except:
            pass

    is_usd = (receipt["currency"] == "USD")

    best_match = None
    best_score = 999999

    for tx in transactions:
        if tx["date"] is None:
            continue

        if r_date:
            day_diff = abs((tx["date"] - r_date).days)
            if day_diff > 2:
                continue
        else:
            day_diff = 0

        tx_amt = abs(tx["cad"])
        if is_usd and tx["usd"] > 0:
            amt_diff = abs(tx["usd"] - r_amt)
        elif is_usd:
            amt_diff = abs(tx_amt - r_amt * 1.42)
        else:
            amt_diff = abs(tx_amt - r_amt)

        if amt_diff > 2.0:
            continue

        score = day_diff * 100 + amt_diff * 10
        if score < best_score:
            best_score = score
            best_match = tx

    if best_match:
        return best_match, "STATEMENT_MATCH"
    return None, "NO_MATCH"


def vendor_hint_match(fname_lower, desc1, desc2):
    desc_full = (desc1 + " " + desc2).lower()
    rules = [
        (['interserver','interserver.net','po box 1707'], ['interserver']),
        (['freedom mobile','freedom','bill_'], ['freedom mobile','freedom']),
        (['amazon','amzn'], ['amazon','amzn']),
        (['home depot','the home depot', 'mulch', 'yard'], ['home depot']),
        (['temu'], ['temu']),
        (['paypal'], ['paypal']),
        (['civil resolution'], ['civil resolution']),
        (['esso','7-eleven'], ['esso','7-eleven']),
        (['petro-canada','petro canada','petro'], ['petro']),
        (['shell'], ['shell']),
        (['squarespace','sqsp'], ['sqsp','squarespace']),
        (['appsumo'], ['appsumo']),
        (['reinvestwealth','reinvest'], ['reinvestwealth','reinvest']),
        (['namecheap','name-cheap'], ['namecheap','name-cheap']),
        (['bugman','the bugman'], ['bugman']),
        (['legalshield'], ['legalshield']),
        (['udemy'], ['udemy']),
        (['boldsign'], ['boldsign']),
        (['wpforms'], ['wpforms']),
        (['moz'], ['mozseo','moz']),
        (['ozerty'], ['ozerty']),
        (['myclaw'], ['myclaw']),
    ]
    for fname_kw, desc_kw in rules:
        desc_kw_list = desc_kw if isinstance(desc_kw, list) else [desc_kw]
        if any(kw in fname_lower for kw in fname_kw):
            return any(kw in desc_full for kw in desc_kw_list)
    return False


def read_md_text(text_md_path):
    """Extract raw text from a .md file produced by convert-pdf-to-text.py."""
    if not text_md_path.exists():
        return ""
    with open(text_md_path, "r", encoding="utf-8") as f:
        content = f.read()
    text_parts = []
    in_page = False
    for line in content.split("\n"):
        if line.startswith("## Page "):
            in_page = True
            continue
        if in_page and line.strip():
            text_parts.append(line.strip())
    return "\n".join(text_parts)


def main():
    parser = argparse.ArgumentParser(
        description="Credit card receipt extraction & matching pipeline"
    )
    parser.add_argument("--card-suffix", required=True,
                        help="Card suffix (e.g., 6258)")
    parser.add_argument("--entity", default="intersite-consulting",
                        help="Entity name in cloud-books-entities.json")
    parser.add_argument("--csv-dir", required=True,
                        help="Directory containing CC statement CSV files")
    parser.add_argument("--ingest-dir", required=True,
                        help="Directory for raw receipt images/PDFs")
    parser.add_argument("--output-dir", required=True,
                        help="Directory for matched results")
    parser.add_argument("--manifest", required=True,
                        help="Path to output manifest CSV")
    parser.add_argument("--vendor-hint", action="store_true",
                        help="Enable filename-based vendor matching")
    args = parser.parse_args()

    card_suffix = args.card_suffix
    ingest_dir = Path(args.ingest_dir)
    output_dir = Path(args.output_dir)
    manifest_path = Path(args.manifest)
    csv_dir = Path(args.csv_dir)

    config, entity, card_config = load_entity_config(args.entity, card_suffix)
    csv_pattern = card_config.get("csv_pattern", "2026 Fiscal Year - Intersite MC {suffix}.csv")
    csv_filename = csv_pattern.replace("{suffix}", card_suffix)
    statement_csv = csv_dir / csv_filename

    print("=" * 60)
    print(f"Credit Card Receipt Pipeline (card suffix: {card_suffix})")
    print(f"Entity: {entity.get('display_name', args.entity)}")
    print("=" * 60)

    if not statement_csv.exists():
        print(f"ERROR: Statement CSV not found: {statement_csv}", file=sys.stderr)
        sys.exit(1)

    transactions = load_statement(str(statement_csv))
    print(f"Statement: {len(transactions)} transactions loaded")

    files = sorted([
        f for f in os.listdir(ingest_dir)
        if (ingest_dir / f).is_file()
        and f.lower().endswith(('.pdf', '.jpg', '.jpeg', '.png'))
    ])
    print(f"Files to process: {len(files)}")

    with tempfile.TemporaryDirectory(prefix="ocr-text-") as text_tmpdir:
        text_dir = Path(text_tmpdir)
        with tempfile.TemporaryDirectory(prefix="ocr-img-") as img_tmpdir:
            img_dir = Path(img_tmpdir)
            with tempfile.TemporaryDirectory(prefix="ocr-results-") as ocr_tmpdir:
                ocr_dir = Path(ocr_tmpdir)

                pdf_files = [f for f in files if Path(f).suffix.lower() == ".pdf"]
                image_files = [f for f in files if Path(f).suffix.lower() in (".jpg", ".jpeg", ".png")]

                if pdf_files:
                    print(f"\n=== PDF text extraction ({len(pdf_files)} files) ===")
                    run_script("convert-pdf-to-text.py",
                               "--input-dir", str(ingest_dir),
                               "--output-dir", str(text_dir),
                               "--ocr-fallback")

                textless_pdfs = []
                for f in pdf_files:
                    md_path = text_dir / f"{Path(f).stem}.md"
                    raw_text = read_md_text(md_path)
                    if raw_text.strip():
                        print(f"  Text OK: {f}")
                    else:
                        textless_pdfs.append(f)
                        print(f"  No text: {f}")

                pdf_images = []
                if textless_pdfs:
                    print(f"\n=== Image rendering ({len(textless_pdfs)} textless PDFs) ===")
                    textless_dir = Path(tempfile.mkdtemp(dir=img_tmpdir))
                    for f in textless_pdfs:
                        shutil.copy2(ingest_dir / f, textless_dir / f)

                    run_script("convert-pdf-to-image.py",
                               "--input-dir", str(textless_dir),
                               "--output-dir", str(img_dir),
                               "--dpi", "200")

                    for img_f in sorted(img_dir.iterdir()):
                        if img_f.suffix.lower() in (".jpg", ".jpeg", ".png"):
                            pdf_images.append(img_f.name)

                all_ocr_images = list(pdf_images)

                if image_files:
                    print(f"\n=== Image OCR ({len(image_files)} image files) ===")
                    all_ocr_images.extend(image_files)

                if all_ocr_images:
                    print(f"\n=== OCR on all images ({len(all_ocr_images)} images) ===")
                    run_script("extract-receipt-ocr.py",
                               "--input-dir", str(img_dir),
                               "--output-dir", str(ocr_dir))

                print(f"\n=== Processing results ===")
                receipts = []

                for fname in files:
                    if Path(fname).suffix.lower() == ".pdf":
                        md_path = text_dir / f"{Path(fname).stem}.md"
                        raw_text = read_md_text(md_path)

                        if raw_text.strip():
                            data = extract_from_text(raw_text, card_suffix)
                            data["original_filename"] = fname
                        else:
                            json_path = ocr_dir / f"{Path(fname).stem}_p1.json"
                            if not json_path.exists():
                                json_path = ocr_dir / f"{Path(fname).stem}.json"
                            if json_path.exists():
                                with open(json_path, "r", encoding="utf-8") as jf:
                                    parsed = json.load(jf)
                                data = {
                                    "vendor": parsed.get("vendor"),
                                    "date": parse_date(parsed.get("date", "")),
                                    "amount": parse_amount(str(parsed.get("amount", 0))),
                                    "currency": parsed.get("currency"),
                                    "card_last4": None,
                                    "has_card_ref": False,
                                    "raw_text": json.dumps(parsed, ensure_ascii=False)[:2000],
                                    "source": "gpt-4o-mini",
                                    "date_source": None,
                                    "is_credit_note": False,
                                    "original_filename": fname,
                                }
                                card = parsed.get("card_last4")
                                if card:
                                    data["card_last4"] = card
                                    data["has_card_ref"] = (card == card_suffix)
                                if parsed.get("is_receipt") is False:
                                    pass
                            else:
                                data = {
                                    "vendor": None, "date": None, "amount": None,
                                    "currency": None, "card_last4": None,
                                    "has_card_ref": False, "raw_text": "",
                                    "source": "pdf-vision", "date_source": None,
                                    "is_credit_note": False,
                                    "original_filename": fname,
                                }
                    else:
                        json_path = ocr_dir / f"{Path(fname).stem}.json"
                        if not json_path.exists():
                            json_path = ocr_dir / f"{Path(fname).stem}_p1.json"
                        if json_path.exists():
                            with open(json_path, "r", encoding="utf-8") as jf:
                                parsed = json.load(jf)
                            data = {
                                "vendor": parsed.get("vendor"),
                                "date": parse_date(parsed.get("date", "")),
                                "amount": parse_amount(str(parsed.get("amount", 0))),
                                "currency": parsed.get("currency"),
                                "card_last4": None,
                                "has_card_ref": False,
                                "raw_text": json.dumps(parsed, ensure_ascii=False)[:2000],
                                "source": "gpt-4o-mini",
                                "date_source": None,
                                "is_credit_note": False,
                                "original_filename": fname,
                            }
                            card = parsed.get("card_last4")
                            if card:
                                data["card_last4"] = card
                                data["has_card_ref"] = (card == card_suffix)
                        else:
                            data = {
                                "vendor": None, "date": None, "amount": None,
                                "currency": None, "card_last4": None,
                                "has_card_ref": False, "raw_text": "",
                                "source": "unknown", "date_source": None,
                                "is_credit_note": False,
                                "original_filename": fname,
                            }

                    if not data.get("date"):
                        fname_date = parse_date_from_filename(fname)
                        if fname_date:
                            data["date"] = fname_date
                            data["date_source"] = "filename"
                        else:
                            data["date_source"] = "none"
                    elif data.get("date"):
                        data["date_source"] = data.get("source", "unknown")

                    if card_suffix in fname:
                        data["has_card_ref"] = True
                        data["filename_has_card_ref"] = True
                    else:
                        data["filename_has_card_ref"] = False

                    receipts.append(data)

                print(f"\nProcessed {len(receipts)} receipts")

                print("\n=== Matching against statement ===")
                matched_count = 0
                no_match_count = 0
                non_mc_count = 0
                no_amount_count = 0

                for r in receipts:
                    vendor = (r.get("vendor") or "").lower()
                    is_receipt = True
                    reason = ""

                    if "intersite consulting" in vendor and not r.get("has_card_ref"):
                        is_receipt = False
                        reason = "OUTGOING_INVOICE"
                    elif "stripe" in vendor and "transaction" in (r.get("raw_text") or "").lower():
                        is_receipt = False
                        reason = "STRIPE_REPORT"
                    elif r.get("vendor") == "NOT_A_RECEIPT":
                        is_receipt = False
                        reason = "NOT_A_RECEIPT"
                    elif r.get("source") == "gpt-4o-mini" and not r.get("vendor") and not r.get("amount"):
                        is_receipt = False
                        reason = "UNREADABLE"

                    if not is_receipt:
                        r["match_type"] = reason
                        r["destination"] = f"rbc-{card_suffix}/non-matching/"
                        non_mc_count += 1
                        continue

                    tx, match_type = match_receipt(r, transactions)
                    r["match_type"] = match_type

                    if tx:
                        r["destination"] = f"rbc-{card_suffix}/"
                        r["matched_tx_date"] = tx["date_str"]
                        r["matched_tx_desc"] = tx["desc1"]
                        r["matched_tx_cad"] = tx["cad"]
                        tx["associated_receipt"] = r["original_filename"]
                        matched_count += 1
                    elif r.get("has_card_ref") or r.get("filename_has_card_ref"):
                        r["destination"] = f"rbc-{card_suffix}/"
                        r["match_type"] = "CARD_CONFIRMED"
                        matched_count += 1
                    elif not r.get("amount") or r["amount"] == 0:
                        r["destination"] = f"rbc-{card_suffix}/non-matching/"
                        r["match_type"] = "NO_AMOUNT"
                        no_amount_count += 1
                    else:
                        r["destination"] = f"rbc-{card_suffix}/non-matching/"
                        no_match_count += 1

                print(f"\n=== Writing manifest ===")
                with open(manifest_path, "w", newline="", encoding="utf-8") as f:
                    writer = csv.writer(f)
                    writer.writerow([
                        "OriginalFilename", "Vendor", "Date", "Date_Source", "Amount", "Currency",
                        "Card_Last4", "Has_Card_Ref", "Is_Credit_Note", "MatchType", "Destination",
                        "RenamedFilename", "MatchedTxDate", "MatchedTxDesc", "Notes"
                    ])
                    for r in receipts:
                        date = r.get("date") or "unknown-date"
                        amt = r.get("amount") or 0
                        vendor_str = re.sub(r'[\\/:*?"<>|]', '', (r.get("vendor") or "Unknown")).strip()[:60]
                        ext = Path(r["original_filename"]).suffix
                        r["renamed_file"] = f"{date} - {amt:.2f} - {vendor_str}{ext}"

                    seen_names = {}
                    for r in receipts:
                        name = r["renamed_file"]
                        if name in seen_names:
                            seen_names[name] += 1
                            base = Path(name).stem
                            ext = Path(name).suffix
                            r["renamed_file"] = f"{base}_{seen_names[name]}{ext}"
                        else:
                            seen_names[name] = 1

                    for r in receipts:
                        writer.writerow([
                            r["original_filename"],
                            r.get("vendor", ""),
                            r.get("date", ""),
                            r.get("date_source", ""),
                            r.get("amount", 0),
                            r.get("currency", ""),
                            r.get("card_last4", ""),
                            r.get("has_card_ref", False),
                            r.get("is_credit_note", False),
                            r.get("match_type", ""),
                            r.get("destination", ""),
                            r.get("renamed_file", ""),
                            r.get("matched_tx_date", ""),
                            r.get("matched_tx_desc", ""),
                            (r.get("raw_text", "") or "")[:200]
                        ])
                print(f"Manifest: {manifest_path} ({len(receipts)} rows)")

                print("=== Copying files ===")
                non_match_dir = output_dir / "non-matching"
                output_dir.mkdir(parents=True, exist_ok=True)
                non_match_dir.mkdir(parents=True, exist_ok=True)

                copied = 0
                moved = 0
                errors = 0

                for r in receipts:
                    src = ingest_dir / r["original_filename"]
                    if not src.exists():
                        errors += 1
                        continue

                    if r.get("destination") == f"rbc-{card_suffix}/":
                        dst = output_dir / r["renamed_file"]
                    else:
                        dst = non_match_dir / r["renamed_file"]

                    if dst.exists() and os.path.abspath(str(src)) != os.path.abspath(str(dst)):
                        base = Path(r["renamed_file"]).stem
                        ext = Path(r["renamed_file"]).suffix
                        counter = 2
                        while dst.exists():
                            dst = dst.parent / f"{base}_{counter}{ext}"
                            counter += 1

                    if os.path.abspath(str(src)) != os.path.abspath(str(dst)):
                        shutil.copy2(str(src), str(dst))
                        if r.get("destination") == f"rbc-{card_suffix}/":
                            copied += 1
                        else:
                            moved += 1

                print(f"\n{'=' * 60}")
                print(f"SUMMARY")
                print(f"{'=' * 60}")
                print(f"Total receipts processed: {len(receipts)}")
                print(f"Copied to rbc-{card_suffix}/:      {copied}")
                print(f"Moved to non-matching/:   {moved}")
                print(f"Errors:                   {errors}")
                print(f"")
                print(f"Match breakdown:")
                match_types = {}
                for r in receipts:
                    mt = r.get("match_type", "UNKNOWN")
                    match_types[mt] = match_types.get(mt, 0) + 1
                for mt, count in sorted(match_types.items(), key=lambda x: -x[1]):
                    print(f"  {mt}: {count}")
                print(f"")
                print(f"Statement coverage: {sum(1 for t in transactions if t['associated_receipt'])}/{len(transactions)} transactions have receipts")


if __name__ == "__main__":
    main()
