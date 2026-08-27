"""Receipt processing utilities — filename parsing, TAS loading, matching logic."""

import csv
import re
from pathlib import Path

# Intersite accounts per TAS
INTERSITE_ACCOUNTS = {
    "RBC Intersite (Chequing 6632)",
    "MC 6258 (MasterCard 6241)",
}

# Categories exempt from receipt requirement
EXEMPT_CATEGORIES = {
    "Strata Fees", "Property Tax", "Insurance", "Bank Fees and Charges",
    "Credit Card Charges", "Shareholder Loan", "Owner Funding", "Transfer Out",
    "Bank Fee", "Credit Card Payment", "Credit Card Payments",
    "Automobile Expense", "Rent", "Damage Deposit", "Loan Payment",
    "Mortgage", "Intersite", "Intersite RBC Business Cash Back Mastercard",
    "Management Fee",
}

# Skip folders that are clearly not receipts
SKIP_DIRS = {
    "Boldsign Form Positions",
    "T1 Personal Tax Returns",
    "2019-2025 Filings",
}

# Date tolerance: many receipts are dated a few days before/after the statement date
DATE_TOLERANCE_DAYS = 3

# Amount tolerance: allow FX-converted amounts to differ
AMOUNT_TOLERANCE_PCT = 0.05

# Vendor substring -> TAS category mapping
VENDOR_HINTS = {
    "openrouter": "Software & IT Expenses",
    "mo z": "Software & IT Expenses",
    "interserver": "Software & IT Expenses",
    "namecheap": "Software & IT Expenses",
    "name-cheap": "Software & IT Expenses",
    "creative": "Software & IT Expenses",
    "stripe": "Software & IT Expenses",
    "zai": "Software & IT Expenses",
    "anomaly": "Software & IT Expenses",
    "kilocode": "Software & IT Expenses",
    "kilo code": "Software & IT Expenses",
    "squarespace": "Software & IT Expenses",
    "bold": "Software & IT Expenses",
    "roomies": "Software & IT Expenses",
    "fongo": "Software & IT Expenses",
    "google": "Software & IT Expenses",
    "pixella": "Software & IT Expenses",
    "myclaw": "Software & IT Expenses",
    "ignition": "Software & IT Expenses",
    "amazon web services": "Software & IT Expenses",
    "freedom mobile": "Software & IT Expenses",
    "bitwarden": "Software & IT Expenses",
    "artem": "Software & IT Expenses",
    "govee": "Office & General Expenses",
    "anker": "Office & General Expenses",
    "internet lightspeed": "Office & General Expenses",
    "bc hydro": "Office & General Expenses",
    "kal tire": "Repairs and Maintenance",
    "home depot": "Repairs and Maintenance",
    "shell": "Automobile Expense",
    "petro": "Automobile Expense",
    "esso": "Automobile Expense",
    "super save": "Automobile Expense",
    "vernon co-op": "Office & General Expenses",
    "canco": "Office & General Expenses",
    "court services": "Professional Fees",
    "meta": "Software & IT Expenses",
    "facebook": "Software & IT Expenses",
}

DATE_RE = re.compile(r"(20\d{2})[-_](\d{2})[-_](\d{2})")
AMT_RE = re.compile(r"(\d{1,4}(?:[.,]\d{3})*[.,]\d{2})")


def load_tas(path: Path):
    """Return list of (date_iso, account, amount, description, category) tuples.

    Example:
        rows = load_tas(Path("TAS-2026.csv"))
        len(rows) > 0  # True for a valid TAS file
    """
    rows = []
    with open(path, "r", encoding="utf-8") as f:
        content = f.read()
    if content and content[0] == "\ufeff":
        content = content[1:]
    for line in content.splitlines():
        if line.startswith("#") or not line.strip():
            continue
        if line.startswith('"date"'):
            continue
        reader = csv.reader([line])
        cells = next(reader)
        if len(cells) < 5:
            continue
        date, account, amount, desc, category = cells[0], cells[1], cells[2], cells[3], cells[4]
        try:
            amt = float(amount)
        except ValueError:
            continue
        rows.append((date, account, amt, desc, category))
    return rows


def parse_filename_meta(name: str):
    """Extract (date_iso, amount, vendor) from a receipt filename.

    Patterns handled:
      2025-04-09 - 33.60 - Freedom Mobile.pdf
      rbc-6258~2025-04-09 - 10.00 - Kilo Code.pdf
      2025-09-16 - 654.00 - Intersite Consulting Inc. (704730...).pdf
      2026-01-12_-_183.75_-_Intersite_Consulting_Services.jpg

    Example:
        meta = parse_filename_meta("2025-04-09 - 33.60 - Freedom Mobile.pdf")
        meta["date"] == "2025-04-09"
        meta["amount"] == 33.60
        meta["vendor"] == "Freedom Mobile"
    """
    stem = name
    while True:
        stripped = False
        for ext in (".pdf", ".jpg", ".jpeg", ".png", ".csv", ".md", ".json", ".txt"):
            if stem.lower().endswith(ext):
                stem = stem[: -len(ext)]
                stripped = True
                break
        if not stripped:
            break

    m = DATE_RE.search(stem)
    if not m:
        return None
    yyyy, mm, dd = m.group(1), m.group(2), m.group(3)
    date_iso = f"{yyyy}-{mm}-{dd}"
    date_prefix = f"{yyyy}-{mm}-{dd}"

    tail = stem[m.end():]
    amt_m = AMT_RE.search(tail)
    if not amt_m:
        return None
    amt_str = amt_m.group(1).replace(",", "")
    try:
        amt = float(amt_str)
    except ValueError:
        return None

    vendor = tail[amt_m.end():].lstrip(" -_").strip()
    vendor = re.sub(r"[_\-]+", " ", vendor).strip()

    return {"date": date_iso, "amount": amt, "vendor": vendor, "date_prefix": date_prefix}


def matches_tx(tx_amt: float, rec_amt: float) -> bool:
    """Check if a transaction amount matches a receipt amount within tolerance.

    Example:
        matches_tx(33.60, 33.60)  # True — exact match
        matches_tx(100.00, 105.00)  # True — 5% tolerance exactly
        matches_tx(100.00, 105.01)  # False — just over 5%
        matches_tx(0.0, 33.60)  # False — zero edge case
    """
    if tx_amt == 0 or rec_amt == 0:
        return False
    diff = abs(tx_amt - rec_amt) / max(abs(tx_amt), abs(rec_amt))
    return diff <= AMOUNT_TOLERANCE_PCT


def vendor_plausible(tx_category: str, rec_vendor: str) -> bool:
    """Check if a receipt vendor is plausible for the given TAS category.

    Example:
        vendor_plausible("Software & IT Expenses", "OpenRouter API")  # True
        vendor_plausible("Automobile Expense", "OpenRouter API")  # False
        vendor_plausible("Office & General Expenses", "Amazon.ca")  # True (Amazon allowed anywhere)
    """
    rec_vendor_l = rec_vendor.lower()
    for k, cat in VENDOR_HINTS.items():
        if k in rec_vendor_l and cat == tx_category:
            return True
        if k in rec_vendor_l and k in ("amazon", "amazon.ca", "alibaba", "alibaba.com", "alipay"):
            return True
    universal = ("amazon", "amazon.ca", "amzn", "alibaba", "shopify", "alipay", "stripe")
    for u in universal:
        if u in rec_vendor_l:
            return True
    return False
