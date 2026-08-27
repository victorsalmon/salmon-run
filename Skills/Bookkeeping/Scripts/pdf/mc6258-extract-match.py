#!/usr/bin/env python3
# DEPRECATED — Use extract-match-credit-card.py --card-suffix 6258 instead.
# Reason: Account-specific naming, hardcoded paths, inline extraction work.
# Kept for backward compatibility only.
"""
MC 6258 Receipt Extraction & Matching Pipeline
- PDFs: pdfplumber text extraction
- Images: GPT-4o-mini via OpenRouter
- Matching: ±$2 amount, ±2 days against MC 6258 statement
"""

import os, sys, json, re, csv, hashlib, shutil, base64, time
from datetime import datetime, timedelta
from pathlib import Path
import pdfplumber
import requests
from PIL import Image
import pypdfium2 as pdfium
import io

# ── Config ───────────────────────────────────────────────────────────────────
INGEST_DIR = r"C:\Users\Victor\intersite-docs\Taxes and Bookkeeping\intersite-consulting\2026 Receipts\rbc-6258-ingest"
DEST_DIR = r"C:\Users\Victor\intersite-docs\Taxes and Bookkeeping\intersite-consulting\2026 Receipts\rbc-6258"
STATEMENT_CSV = r"C:\Users\Victor\intersite-docs\Taxes and Bookkeeping\intersite-consulting\2026 Fiscal Year - Bank Statements\MC 6241 (6258)\2026 Fiscal Year - Intersite MC 6258.csv"
MANIFEST_OUT = r"C:\Users\Victor\intersite-docs\Taxes and Bookkeeping\intersite-consulting\2026 Receipts\rbc-6258-manifest.csv"
STATEMENT_OUT = r"C:\Users\Victor\intersite-docs\Taxes and Bookkeeping\intersite-consulting\2026 Fiscal Year - Bank Statements\MC 6241 (6258)\2026 Fiscal Year - Intersite MC 6258 - enriched.csv"
CACHE_FILE = os.path.join(os.path.dirname(__file__), "..", ".receipt-cache.json")

OPENROUTER_KEY = os.environ.get("OPENROUTER_ORCH_KEY", os.environ.get("OPENROUTER_API_KEY", ""))
MODEL = "gpt-4o-mini"
MAX_RETRIES = 2
BATCH_DELAY = 0.5  # seconds between API calls

# ── Helpers ──────────────────────────────────────────────────────────────────

def file_hash(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            h.update(chunk)
    return h.hexdigest()

def load_cache():
    if os.path.exists(CACHE_FILE):
        with open(CACHE_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    return {}

def save_cache(cache):
    with open(CACHE_FILE, "w", encoding="utf-8") as f:
        json.dump(cache, f, indent=2)

def parse_date(s):
    """Try multiple date formats, return YYYY-MM-DD or None."""
    if not s or s.strip() == "":
        return None
    s = s.strip()
    # Remove ordinal suffixes: Jul 19th -> Jul 19
    s = re.sub(r'(\d+)(st|nd|rd|th)\b', r'\1', s)
    for fmt in ["%Y-%m-%d", "%m/%d/%Y", "%Y/%m/%d", "%m-%d-%Y", "%d-%m-%Y",
                "%B %d, %Y", "%b %d, %Y", "%B %d %Y", "%b %d %Y",
                "%d %B %Y", "%d %b %Y", "%Y%m%d",
                "%d-%b-%Y", "%d/%b/%Y", "%d-%B-%Y"]:
        try:
            return datetime.strptime(s, fmt).strftime("%Y-%m-%d")
        except ValueError:
            continue
    # M/D/YYYY
    m = re.match(r"(\d{1,2})/(\d{1,2})/(\d{4})", s)
    if m:
        try:
            return datetime(int(m.group(3)), int(m.group(1)), int(m.group(2))).strftime("%Y-%m-%d")
        except:
            pass
    # MM.DD.YYYY or MM.DD.YY
    m = re.match(r"(\d{1,2})\.(\d{1,2})\.(\d{4})", s)
    if m:
        try:
            return datetime(int(m.group(3)), int(m.group(1)), int(m.group(2))).strftime("%Y-%m-%d")
        except:
            pass
    return None

def parse_date_from_filename(fname):
    """Extract date from filename using common patterns."""
    name = os.path.splitext(fname)[0]
    # YYYY.MM.DD
    m = re.search(r'(\d{4})[.-](\d{1,2})[.-](\d{1,2})', name)
    if m:
        try:
            return datetime(int(m.group(1)), int(m.group(2)), int(m.group(3))).strftime("%Y-%m-%d")
        except:
            pass
    # MM.DD.YYYY - 4-digit year at end
    m = re.search(r'(\d{1,2})[.-](\d{1,2})[.-](\d{4})', name)
    if m:
        y, mo, d = int(m.group(3)), int(m.group(1)), int(m.group(2))
        if 2024 <= y <= 2027 and 1 <= mo <= 12 and 1 <= d <= 31:
            return datetime(y, mo, d).strftime("%Y-%m-%d")
    # YYYYMMDD (no separators)
    m = re.search(r'(202[4-7])(0[1-9]|1[0-2])(0[1-9]|[12]\d|3[01])', name)
    if m:
        try:
            return datetime(int(m.group(1)), int(m.group(2)), int(m.group(3))).strftime("%Y-%m-%d")
        except:
            pass
    # "jan 4 2026" or "feb 4 2026" etc.
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
    # MM.DD as in "07.19 - 2014 - description" -> infers year from context (2025)
    m = re.match(r'(\d{1,2})[.-](\d{1,2})\s', name)
    if m:
        mo, d = int(m.group(1)), int(m.group(2))
        if 1 <= mo <= 12 and 1 <= d <= 31:
            return f"2025-{mo:02d}-{d:02d}"
    return None

def parse_amount(s):
    """Extract numeric amount from string."""
    if not s:
        return 0.0
    s = str(s).replace(",", "").replace("$", "").replace("CAD", "").replace("USD", "").strip()
    m = re.search(r"-?[\d]+\.?\d*", s)
    if m:
        return abs(float(m.group()))
    return 0.0

def extract_card_number(text):
    """Look for card number patterns (last 4 digits)."""
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

def has_6258_reference(text, amount=None):
    """Check if 6258 appears in text (not as part of the total amount)."""
    if not text:
        return False
    # Find all occurrences of 6258
    for m in re.finditer(r'6258', text):
        start = max(0, m.start() - 30)
        end = min(len(text), m.end() + 30)
        context = text[start:end]
        # Skip if it's in a total/amount line
        if re.search(r'(?:total|amount|balance|payment|due)\s*[:=]?\s*\$?\s*\d+\.?\d*.*6258', context, re.I):
            continue
        if re.search(r'6258.*\$\s*\d+\.?\d*', context):
            continue
        return True
    return False

def is_credit_note(text, amount_str=""):
    """Detect whether a document is a credit note / refund."""
    if not text and not amount_str:
        return False
    # Check text for "Credit Note" (Amazon/formal)
    if text and re.search(r'Credit\s+Note', text, re.I):
        return True
    # Check amount string for "c$" prefix (standard accounting notation)
    if amount_str and re.match(r'^[cC]\$?\s*[\d]', amount_str.strip()):
        return True
    # Check filename prefix "r" for refund
    if amount_str and re.match(r'^[rR][\d]', amount_str.strip()):
        return True
    return False

# ── PDF Extraction ───────────────────────────────────────────────────────────

def extract_pdf(path):
    """Extract receipt data from PDF using pdfplumber."""
    result = {
        "vendor": None, "date": None, "amount": None, "currency": None,
        "card_last4": None, "has_6258": False, "raw_text": "", "source": "pdfplumber",
        "date_source": None, "is_credit_note": False
    }
    try:
        texts = []
        with pdfplumber.open(path) as pdf:
            for page in pdf.pages:
                t = page.extract_text()
                if t:
                    texts.append(t)
        full_text = "\n".join(texts)
        result["raw_text"] = full_text[:3000]  # cap for storage

        if not full_text.strip():
            return result

        result["is_credit_note"] = is_credit_note(full_text)
        card = extract_card_number(full_text)
        result["card_last4"] = card
        result["has_6258"] = (card == "6258") or has_6258_reference(full_text)

        # Normalize French accented characters for matching
        accent_map = str.maketrans('àâäéèêëîïôöùûüçÀÂÄÉÈÊËÎÏÔÖÙÛÜÇ',
                                    'aaaeeeeiioouuucAAAEEEEIIOOUUUC')
        normalized = full_text.translate(accent_map) if full_text else ""

        # Date - aggressive: try keyword-labeled first, then scan entire text
        # Patterns handle: "Invoice date / Date de facturation: 01 August 2025"
        #                  "Invoice Date 21 May 2026" (Zoho)
        #                  "Order date / Date de commande: 31 July 2025"
        #                  Any date-like string
        date_patterns = [
            # Amazon Order Invoice: "Invoice date / Date de facturation: 01 August 2025"
            r'Invoice\s+date\s*(?:/\s*Date\s+de\s+\w+)?\s*:\s*(\d{1,2}\s+\w+\s+\d{4})',
            # Zoho: "Invoice Date 21 May 2026"
            r'Invoice\s+Date\s+(\d{1,2}\s+\w+\s+\d{4})',
            # "Order date / Date de commande: 31 July 2025"
            r'Order\s+date\s*(?:/\s*Date\s+de\s+\w+)?\s*:\s*(\d{1,2}\s+\w+\s+\d{4})',
            # Keyword-labeled YYYY-MM-DD
            r'(?:date|posted|transaction)[:\s]*(\d{4}[-/]\d{1,2}[-/]\d{1,2})',
            # DD MonthName YYYY (day-first like "01 August 2025")
            r'(\d{1,2}\s+\w+\s+\d{4})',
            # MonthName DD, YYYY
            r'(\w+\s+\d{1,2},?\s*\d{4})',
            # YYYY-MM-DD standalone
            r'(\d{4}-\d{2}-\d{2})',
        ]
        # Use normalized text for matching, but original for date parsing
        for pat in date_patterns:
            for m in re.finditer(pat, normalized, re.I):
                # Get the matched date string from the ORIGINAL text using span
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

        # Amount - handle both English and French labels
        amount_patterns = [
            # Amazon: "Total payable / Total a payer: $29.11"
            r'Total\s+[^:]*[:\s]*\$?\s*([\d,]+\.?\d*)',
            # "Invoice subtotal / Total partiel de la facture: $29.11"
            r'Invoice\s+subtotal[^:]*[:\s]*\$?\s*([\d,]+\.?\d*)',
            # Keyword-labeled
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
            result["amount"] = max(amounts_found)  # take the largest (likely the total)

        # Currency
        if re.search(r'\bUSD\b|\bUS\s*Dollar', normalized, re.I):
            result["currency"] = "USD"
        elif re.search(r'\bCAD\b|\bCA\$|\bCND', full_text, re.I):
            result["currency"] = "CAD"
        elif result["amount"]:
            result["currency"] = "CAD"  # default for Canadian merchants

        # Vendor - first meaningful line or known patterns
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

        # Fallback vendor from first non-empty line
        if not result["vendor"]:
            for line in full_text.split("\n"):
                line = line.strip()
                if len(line) > 5 and not re.match(r'^[\d\s/\-:]+$', line):
                    result["vendor"] = line[:80]
                    break

    except Exception as e:
        result["raw_text"] = f"ERROR: {e}"

    return result

# ── PDF Vision Fallback (pypdfium2 → GPT-4o-mini) ──────────────────────────

def extract_pdf_vision(path):
    """Extract receipt data from an image-based PDF using pypdfium2
    to render each page as a PIL image, then GPT-4o-mini vision via OpenRouter.
    Fallback when pdfplumber returns no extractable text (scanned/image PDFs).
    """
    result = {
        "vendor": None, "date": None, "amount": None, "currency": None,
        "card_last4": None, "has_6258": False, "raw_text": "", "source": "pdf-vision",
        "date_source": None, "is_credit_note": False
    }

    if not OPENROUTER_KEY:
        result["raw_text"] = "ERROR: No OPENROUTER_ORCH_KEY / OPENROUTER_API_KEY"
        return result

    try:
        doc = pdfium.PdfDocument(path)
        texts = []

        for i in range(len(doc)):
            page = doc[i]
            # Render page at 2x scale for good OCR quality
            bitmap = page.render(scale=2)
            pil_img = bitmap.to_pil()

            # Convert PIL image to base64 JPEG
            buf = io.BytesIO()
            pil_img.save(buf, format="JPEG", quality=85)
            buf.seek(0)
            b64 = base64.b64encode(buf.read()).decode("utf-8")
            mime = "image/jpeg"

            prompt = """Analyze this receipt image. Extract and return ONLY valid JSON with these fields:
{
  "vendor": "merchant/company name",
  "date": "YYYY-MM-DD or null",
  "amount": 0.00,
  "currency": "CAD or USD or null",
  "card_last4": "last 4 digits of card used, or null if not visible",
  "is_receipt": true/false,
  "summary": "brief description under 50 chars"
}
Rules:
- amount must be the TOTAL charged (including tax)
- If this is not a receipt/invoice (e.g. a photo, screenshot), set is_receipt=false
- If card number is visible, extract last 4 digits
- currency: CAD if Canadian vendor, USD if US/international, null if unclear
- Return ONLY the JSON object, no other text"""

            body = {
                "model": MODEL,
                "messages": [
                    {"role": "system", "content": prompt},
                    {"role": "user", "content": [
                        {"type": "text", "text": f"Extract receipt data from this image (page {i+1})."},
                        {"type": "image_url", "image_url": {"url": f"data:{mime};base64,{b64}"}}
                    ]}
                ],
                "max_tokens": 1000,
                "temperature": 0.1
            }

            for attempt in range(MAX_RETRIES):
                try:
                    resp = requests.post(
                        "https://openrouter.ai/api/v1/chat/completions",
                        headers={
                            "Authorization": f"Bearer {OPENROUTER_KEY}",
                            "X-Title": "mc6258-receipt-pipeline",
                            "Content-Type": "application/json"
                        },
                        json=body,
                        timeout=60
                    )
                    if resp.status_code == 429:
                        wait = min(30, 5 * (attempt + 1))
                        print(f"    Rate limited, waiting {wait}s...")
                        time.sleep(wait)
                        continue
                    resp.raise_for_status()
                    break
                except requests.exceptions.RequestException as e:
                    if attempt == MAX_RETRIES - 1:
                        result["raw_text"] = f"API ERROR on page {i+1}: {e}"
                        return result
                    time.sleep(2)

            data = resp.json()
            content = data.get("choices", [{}])[0].get("message", {}).get("content", "")
            texts.append(content)

        # Merge results across pages
        full_text = "\n".join(texts)
        result["raw_text"] = full_text[:3000]

        # Parse JSON from the first page (primary page)
        json_match = re.search(r'\{[^{}]*\}', texts[0], re.DOTALL) if texts else None
        if json_match:
            parsed = json.loads(json_match.group())
            result["vendor"] = parsed.get("vendor")
            result["date"] = parse_date(parsed.get("date"))
            result["amount"] = parse_amount(str(parsed.get("amount", 0)))
            result["currency"] = parsed.get("currency")
            result["card_last4"] = parsed.get("card_last4")
            result["has_6258"] = (result["card_last4"] == "6258")
            if not parsed.get("is_receipt", True):
                result["vendor"] = result["vendor"] or "NOT_A_RECEIPT"

        doc.close()

    except Exception as e:
        result["raw_text"] = f"ERROR: {e}"

    return result

# ── Image Extraction (GPT-4o-mini) ──────────────────────────────────────────

def extract_image(path):
    """Extract receipt data from image using GPT-4o-mini via OpenRouter."""
    result = {
        "vendor": None, "date": None, "amount": None, "currency": None,
        "card_last4": None, "has_6258": False, "raw_text": "", "source": "gpt-4o-mini",
        "date_source": None, "is_credit_note": False
    }

    if not OPENROUTER_KEY:
        result["raw_text"] = "ERROR: No OPENROUTER_ORCH_KEY / OPENROUTER_API_KEY"
        return result

    try:
        with open(path, "rb") as f:
            img_bytes = f.read()
        b64 = base64.b64encode(img_bytes).decode("utf-8")

        ext = Path(path).suffix.lower().lstrip(".")
        mime = {"jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png"}.get(ext, "image/jpeg")

        prompt = """Analyze this receipt image. Extract and return ONLY valid JSON with these fields:
{
  "vendor": "merchant/company name",
  "date": "YYYY-MM-DD or null",
  "amount": 0.00,
  "currency": "CAD or USD or null",
  "card_last4": "last 4 digits of card used, or null if not visible",
  "is_receipt": true/false,
  "summary": "brief description under 50 chars"
}
Rules:
- amount must be the TOTAL charged (including tax)
- If this is not a receipt/invoice (e.g. a photo, screenshot), set is_receipt=false
- If card number is visible, extract last 4 digits
- currency: CAD if Canadian vendor, USD if US/international, null if unclear
- Return ONLY the JSON object, no other text"""

        body = {
            "model": MODEL,
            "messages": [
                {"role": "system", "content": prompt},
                {"role": "user", "content": [
                    {"type": "text", "text": "Extract receipt data from this image."},
                    {"type": "image_url", "image_url": {"url": f"data:{mime};base64,{b64}"}}
                ]}
            ],
            "max_tokens": 1000,
            "temperature": 0.1
        }

        for attempt in range(MAX_RETRIES):
            try:
                resp = requests.post(
                    "https://openrouter.ai/api/v1/chat/completions",
                    headers={
                        "Authorization": f"Bearer {OPENROUTER_KEY}",
                        "X-Title": "mc6258-receipt-pipeline",
                        "Content-Type": "application/json"
                    },
                    json=body,
                    timeout=60
                )
                if resp.status_code == 429:
                    wait = min(30, 5 * (attempt + 1))
                    print(f"    Rate limited, waiting {wait}s...")
                    time.sleep(wait)
                    continue
                resp.raise_for_status()
                break
            except requests.exceptions.RequestException as e:
                if attempt == MAX_RETRIES - 1:
                    result["raw_text"] = f"API ERROR: {e}"
                    return result
                time.sleep(2)

        data = resp.json()
        content = data.get("choices", [{}])[0].get("message", {}).get("content", "")
        result["raw_text"] = content[:2000]

        # Parse JSON from response
        json_match = re.search(r'\{[^{}]*\}', content, re.DOTALL)
        if json_match:
            parsed = json.loads(json_match.group())
            result["vendor"] = parsed.get("vendor")
            result["date"] = parse_date(parsed.get("date"))
            result["amount"] = parse_amount(str(parsed.get("amount", 0)))
            result["currency"] = parsed.get("currency")
            result["card_last4"] = parsed.get("card_last4")
            result["has_6258"] = (result["card_last4"] == "6258")
            if not parsed.get("is_receipt", True):
                result["vendor"] = result["vendor"] or "NOT_A_RECEIPT"

    except Exception as e:
        result["raw_text"] = f"ERROR: {e}"

    return result

# ── Statement Loading ────────────────────────────────────────────────────────

def load_statement(path):
    """Load MC 6258 bank statement CSV."""
    transactions = []
    with open(path, "r", encoding="utf-8-sig") as f:
        reader = csv.DictReader(f)
        for row in reader:
            date_str = row.get("Transaction Date", "").strip()
            desc1 = row.get("Description 1", "").strip()
            desc2 = row.get("Description 2", "").strip()
            cad_str = row.get("CAD$", "").strip()
            usd_str = row.get("USD$", "").strip()

            # Parse date
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

# ── Matching ─────────────────────────────────────────────────────────────────

def match_receipt(receipt, transactions):
    """Match a receipt to a statement transaction (±$2 amount, ±2 days)."""
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

        # Date check: ±2 days
        if r_date:
            day_diff = abs((tx["date"] - r_date).days)
            if day_diff > 2:
                continue
        else:
            day_diff = 0  # no date = can't filter by date

        # Amount check
        tx_amt = abs(tx["cad"])
        if is_usd and tx["usd"] > 0:
            # Compare USD amounts directly
            amt_diff = abs(tx["usd"] - r_amt)
        elif is_usd:
            # Convert approximate: receipt USD, statement CAD
            amt_diff = abs(tx_amt - r_amt * 1.42)
        else:
            amt_diff = abs(tx_amt - r_amt)

        if amt_diff > 2.0:
            continue

        # Score: lower is better (date proximity + amount proximity)
        score = day_diff * 100 + amt_diff * 10
        if score < best_score:
            best_score = score
            best_match = tx

    if best_match:
        return best_match, "STATEMENT_MATCH"
    return None, "NO_MATCH"

# ── Main Pipeline ────────────────────────────────────────────────────────────

def main():
    print("=" * 60)
    print("MC 6258 Receipt Extraction & Matching Pipeline")
    print("=" * 60)

    # Load cache
    cache = load_cache()
    print(f"Cache: {len(cache)} previously processed files")

    # Load statement
    try:
        transactions = load_statement(STATEMENT_CSV)
        print(f"Statement: {len(transactions)} transactions loaded")
    except Exception as e:
        print(f"ERROR loading statement CSV: {e}", file=sys.stderr)
        sys.exit(1)

    # Gather files
    try:
        raw_files = os.listdir(INGEST_DIR)
    except OSError as e:
        print(f"ERROR reading ingest directory {INGEST_DIR}: {e}", file=sys.stderr)
        sys.exit(1)
    files = sorted([
        f for f in raw_files
        if os.path.isfile(os.path.join(INGEST_DIR, f))
        and f.lower().endswith(('.pdf', '.jpg', '.jpeg', '.png'))
    ])
    print(f"Files to process: {len(files)}")

    # Process each file
    receipts = []
    api_calls = 0
    cache_hits = 0

    for i, fname in enumerate(files):
        fpath = os.path.join(INGEST_DIR, fname)
        fhash = file_hash(fpath)

        # Check cache
        if fhash in cache:
            data = cache[fhash]
            data["original_filename"] = fname
            data["file_hash"] = fhash
            receipts.append(data)
            cache_hits += 1
            continue

        print(f"[{i+1}/{len(files)}] {fname[:70]}...", end=" ", flush=True)

        ext = Path(fname).suffix.lower()
        if ext == ".pdf":
            data = extract_pdf(fpath)
            # Fallback: if pdfplumber found no extractable text, try
            # pypdfium2 rendering + GPT-4o-mini vision for image-based PDFs
            if not data.get("vendor") and not data.get("amount") and not data.get("raw_text", "").strip():
                print("  (no extractable text, trying pypdfium2 + GPT-4o-mini vision)...", end=" ", flush=True)
                vision_data = extract_pdf_vision(fpath)
                if vision_data.get("vendor") or vision_data.get("amount"):
                    data = vision_data
                    api_calls += 1
                else:
                    print("  (vision also failed)", end=" ", flush=True)
        else:
            data = extract_image(fpath)
            api_calls += 1
            time.sleep(BATCH_DELAY)

        data["original_filename"] = fname
        data["file_hash"] = fhash
        data["file_size"] = os.path.getsize(fpath)

        # Fallback: parse date from filename if extraction failed
        if not data.get("date"):
            fname_date = parse_date_from_filename(fname)
            if fname_date:
                data["date"] = fname_date
                data["date_source"] = "filename"
            else:
                data["date_source"] = "none"
        elif data.get("date"):
            data["date_source"] = data.get("source", "unknown")

        # Check if 6258 appears in filename itself
        if "6258" in fname:
            data["has_6258"] = True
            data["filename_has_6258"] = True
        else:
            data["filename_has_6258"] = False

        # Cache the result
        cache[fhash] = {k: v for k, v in data.items() if k != "original_filename" and k != "file_hash"}
        receipts.append(data)

        status = "ok" if data.get("vendor") else "no-data"
        amt = data.get("amount", 0) or 0
        print(f"  -> {status} | ${amt:.2f} | {(data.get('vendor') or '?')[:40]}")

    # Save cache
    save_cache(cache)
    print(f"\nCache hits: {cache_hits}, API calls: {api_calls}")

    # ── Match against statement ──────────────────────────────────────────────
    print("\n=== Matching against MC 6258 statement ===")

    matched_count = 0
    no_match_count = 0
    non_mc_count = 0
    no_amount_count = 0

    for r in receipts:
        # Skip non-receipts (outgoing invoices, photos, etc.)
        vendor = (r.get("vendor") or "").lower()
        is_receipt = True
        reason = ""

        # Detect outgoing invoices (Intersite Consulting income)
        if "intersite consulting" in vendor and not r.get("has_6258"):
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
            r["destination"] = "rbc-6258/non-matching/"
            non_mc_count += 1
            continue

        # Try statement match
        tx, match_type = match_receipt(r, transactions)
        r["match_type"] = match_type

        if tx:
            r["destination"] = "rbc-6258/"
            r["matched_tx_date"] = tx["date_str"]
            r["matched_tx_desc"] = tx["desc1"]
            r["matched_tx_cad"] = tx["cad"]
            # Link receipt to statement
            tx["associated_receipt"] = r["original_filename"]
            matched_count += 1
        elif r.get("has_6258") or r.get("filename_has_6258"):
            r["destination"] = "rbc-6258/"
            r["match_type"] = "CARD_6258_CONFIRMED"
            matched_count += 1
        elif not r.get("amount") or r["amount"] == 0:
            r["destination"] = "rbc-6258/non-matching/"
            r["match_type"] = "NO_AMOUNT"
            no_amount_count += 1
        else:
            r["destination"] = "rbc-6258/non-matching/"
            no_match_count += 1

    # ── Build renamed filenames ──────────────────────────────────────────────
    for r in receipts:
        date = r.get("date") or "unknown-date"
        amt = r.get("amount") or 0
        vendor = re.sub(r'[\\/:*?"<>|]', '', (r.get("vendor") or "Unknown")).strip()[:60]
        ext = Path(r["original_filename"]).suffix
        r["renamed_file"] = f"{date} - {amt:.2f} - {vendor}{ext}"

    # Handle duplicate renamed filenames
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

    # ── Write manifest CSV ───────────────────────────────────────────────────
    print("\n=== Writing manifest ===")
    with open(MANIFEST_OUT, "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow([
            "OriginalFilename", "Vendor", "Date", "Date_Source", "Amount", "Currency",
            "Card_Last4", "Has_6258", "Is_Credit_Note", "MatchType", "Destination",
            "RenamedFilename", "MatchedTxDate", "MatchedTxDesc", "Notes"
        ])
        for r in receipts:
            writer.writerow([
                r["original_filename"],
                r.get("vendor", ""),
                r.get("date", ""),
                r.get("date_source", ""),
                r.get("amount", 0),
                r.get("currency", ""),
                r.get("card_last4", ""),
                r.get("has_6258", False),
                r.get("is_credit_note", False),
                r.get("match_type", ""),
                r.get("destination", ""),
                r.get("renamed_file", ""),
                r.get("matched_tx_date", ""),
                r.get("matched_tx_desc", ""),
                (r.get("raw_text", "") or "")[:200]
            ])
    print(f"Manifest: {MANIFEST_OUT} ({len(receipts)} rows)")

    # ── Write enriched statement CSV ────────────────────────────────────────
    print("=== Writing enriched statement ===")
    with open(STATEMENT_OUT, "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow([
            "Account Type", "Account Number", "Transaction Date",
            "Cheque Number", "Description 1", "Description 2",
            "CAD$", "USD$", "Associated Receipt", "Renamed File"
        ])
        for tx in transactions:
            # Reconstruct original line
            acct_type = "MasterCard"
            acct_num = "5526125000886241"
            writer.writerow([
                acct_type, acct_num,
                tx["date_str"], "",
                tx["desc1"], tx["desc2"],
                tx["cad"] if tx["cad"] != 0 else "",
                tx["usd"] if tx["usd"] != 0 else "",
                tx["associated_receipt"],
                tx["renamed_file"]
            ])
    print(f"Enriched statement: {STATEMENT_OUT}")

    # ── Copy files ───────────────────────────────────────────────────────────
    print("\n=== Copying files ===")
    non_match_dir = os.path.join(DEST_DIR, "non-matching")
    os.makedirs(DEST_DIR, exist_ok=True)
    os.makedirs(non_match_dir, exist_ok=True)

    copied = 0
    moved = 0
    errors = 0

    for r in receipts:
        src = os.path.join(INGEST_DIR, r["original_filename"])
        if not os.path.exists(src):
            errors += 1
            continue

        if r.get("destination") == "rbc-6258/":
            dst = os.path.join(DEST_DIR, r["renamed_file"])
        else:
            dst = os.path.join(non_match_dir, r["renamed_file"])

        # Handle collisions
        if os.path.exists(dst) and os.path.abspath(src) != os.path.abspath(dst):
            base = Path(r["renamed_file"]).stem
            ext = Path(r["renamed_file"]).suffix
            counter = 2
            while os.path.exists(dst):
                dst = os.path.join(os.path.dirname(dst), f"{base}_{counter}{ext}")
                counter += 1

        if os.path.abspath(src) != os.path.abspath(dst):
            shutil.copy2(src, dst)
            if r.get("destination") == "rbc-6258/":
                copied += 1
            else:
                moved += 1

    # ── Summary ──────────────────────────────────────────────────────────────
    print(f"\n{'=' * 60}")
    print(f"SUMMARY")
    print(f"{'=' * 60}")
    print(f"Total receipts processed: {len(receipts)}")
    print(f"Copied to rbc-6258/:      {copied}")
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
    print(f"API calls made: {api_calls}")

if __name__ == "__main__":
    main()
