"""Cross-org receipt matching for Intersite Consulting FY2026.

Strategy:
- Read TAS-2026.csv (skipping # comment lines)
- Filter to expense transactions (amount < 0) for intersite accounts
- For each transaction, scan filenames in both orgs for matches by (date, abs(amount))
- Report per-transaction: matched path, or missing
- Also flag "stranded" room-rentals files that look like intersite candidates
"""
from collections import defaultdict
from pathlib import Path

from receipt_utils import (
    parse_filename_meta, matches_tx, vendor_plausible, load_tas,
    INTERSITE_ACCOUNTS, EXEMPT_CATEGORIES, SKIP_DIRS,
    DATE_TOLERANCE_DAYS, AMOUNT_TOLERANCE_PCT,
)

DEFAULT_INTER_ROOT = Path(r"C:\Users\Victor\intersite-docs\Taxes and Bookkeeping\intersite-consulting")
DEFAULT_RR_ROOT    = Path(r"C:\Users\Victor\intersite-docs\Taxes and Bookkeeping\room-rentals")
INTER_ROOT = DEFAULT_INTER_ROOT
RR_ROOT    = DEFAULT_RR_ROOT
TAS_PATH   = INTER_ROOT / "TAS-2026.csv"


def walk_receipts(root: Path):
    """Yield (path, meta) for every receipt-shaped file under root."""
    for p in root.rglob("*"):
        if not p.is_file():
            continue
        # skip files in excluded dirs
        rel = p.relative_to(root)
        if any(part in SKIP_DIRS for part in rel.parts):
            continue
        meta = parse_filename_meta(p.name)
        if meta is None:
            continue
        yield (p, meta)


def main():
    import argparse
    global INTER_ROOT, RR_ROOT, TAS_PATH
    parser = argparse.ArgumentParser(description="Cross-org receipt matching for Intersite Consulting FY2026")
    parser.add_argument("--tas-path", default=str(DEFAULT_INTER_ROOT / "TAS-2026.csv"), help="Path to TAS-2026.csv")
    parser.add_argument("--inter-root", default=str(DEFAULT_INTER_ROOT), help="Intersite docs root")
    parser.add_argument("--rr-root", default=str(DEFAULT_RR_ROOT), help="Room-rentals docs root")
    args = parser.parse_args()
    INTER_ROOT = Path(args.inter_root)
    RR_ROOT = Path(args.rr_root)
    TAS_PATH = Path(args.tas_path)
    rows = load_tas(TAS_PATH)
    print(f"Loaded {len(rows)} TAS rows")

    # Filter: intersite accounts, expense, not exempt
    candidates = []
    for date, account, amount, desc, category in rows:
        if account not in INTERSITE_ACCOUNTS:
            continue
        if amount >= 0:  # only expenses
            continue
        if category in EXEMPT_CATEGORIES:
            continue
        candidates.append({
            "date": date,
            "account": account,
            "amount": abs(amount),
            "amount_str": f"{abs(amount):.2f}",
            "description": desc,
            "category": category,
        })

    print(f"Expense transactions requiring receipt (intersite, non-exempt): {len(candidates)}")
    print()

    # Build lookups: (date, amount) -> [(path, meta), ...] AND (date) -> [(path, meta), ...]
    inter_by_key = defaultdict(list)
    inter_by_date = defaultdict(list)
    rr_by_key = defaultdict(list)
    rr_by_date = defaultdict(list)
    inter_all = []
    rr_all = []

    for root, by_key, by_date, all_list in (
        (INTER_ROOT, inter_by_key, inter_by_date, inter_all),
        (RR_ROOT,    rr_by_key,    rr_by_date,    rr_all),
    ):
        for path, meta in walk_receipts(root):
            key = (meta["date"], round(meta["amount"], 2))
            by_key[key].append((path, meta))
            by_date[meta["date"]].append((path, meta))
            all_list.append((path, meta))

    print(f"Intersite receipt files with parseable date+amount: {len(inter_all)}")
    print(f"Room-rentals receipt files with parseable date+amount: {len(rr_all)}")
    print()

    # Per-transaction matching: strict date+amount, no loose fuzz
    from datetime import date as date_cls, timedelta

    matched = 0
    intersite_only_matched = 0
    missing = []
    for tx in candidates:
        tx_date = date_cls.fromisoformat(tx["date"])
        tx_amt = round(tx["amount"], 2)
        found_anywhere = False
        found_intersite = False
        for offset in range(0, DATE_TOLERANCE_DAYS + 1):
            for d in (tx_date + timedelta(days=offset), tx_date - timedelta(days=offset)):
                if offset == 0 and d != tx_date:
                    continue
                ds = d.isoformat()
                for path, meta in inter_by_date.get(ds, []):
                    if matches_tx(tx_amt, round(meta["amount"], 2)):
                        found_intersite = True
                        found_anywhere = True
                        break
                if found_anywhere:
                    break
                for path, meta in rr_by_date.get(ds, []):
                    if matches_tx(tx_amt, round(meta["amount"], 2)):
                        found_anywhere = True
                        break
                if found_anywhere:
                    break
            if found_anywhere:
                break
        if found_anywhere:
            matched += 1
        else:
            missing.append(tx)
        if found_intersite:
            intersite_only_matched += 1

    print(f"Matched (strict: ±{DATE_TOLERANCE_DAYS} days, ±{int(AMOUNT_TOLERANCE_PCT*100)}%): {matched} / {len(candidates)} ({100*matched/max(1,len(candidates)):.1f}%)")
    print(f"  - matched by INTERSITE-side receipt:  {intersite_only_matched}")
    print(f"  - matched by ROOM-RENTALS-side only:  {matched - intersite_only_matched}")
    print(f"Missing: {len(missing)}")
    print()

    # Stranded: room-rentals files that match an intersite transaction (i.e. misfiled)
    # Only flag if amount matches exactly OR vendor matches intersite vendor pattern
    print("=== MISFILED: receipt files in ROOM-RENTALS that match an INTERSITE transaction ===")
    print("    (amount match ±5%, vendor plausibility required)")
    stranded = []
    for tx in candidates:
        tx_date = date_cls.fromisoformat(tx["date"])
        tx_amt = round(tx["amount"], 2)
        for offset in range(0, DATE_TOLERANCE_DAYS + 1):
            for d in (tx_date + timedelta(days=offset), tx_date - timedelta(days=offset)):
                if offset == 0 and d != tx_date:
                    continue
                ds = d.isoformat()
                for path, meta in rr_by_date.get(ds, []):
                    if not matches_tx(tx_amt, round(meta["amount"], 2)):
                        continue
                    # require vendor plausibility OR receipt is already known to be intersite (rbc-6258 prefix)
                    plausible = vendor_plausible(tx["category"], meta["vendor"]) or "rbc-6258" in path.name.lower()
                    if not plausible:
                        continue
                    # skip if already covered by an intersite file
                    if any(inter_by_date.get(ds, [])):
                        continue
                    stranded.append((tx, path, meta, offset))
                    break  # one match per tx
            else:
                continue
            break

    if stranded:
        for tx, path, meta, off in stranded:
            print(f"  {tx['date']}  ${tx['amount']:>8.2f}  {tx['description'][:40]:40}  ->  {path.relative_to(RR_ROOT)}")
    else:
        print("  (none)")
    print(f"Total misfiled: {len(stranded)}")
    print()

    # Print all missing transactions
    print("=== STILL MISSING (intersite expense transactions with no file in either org) ===")
    print(f"Date       Amount   Account                     Description")
    for tx in missing:
        print(f"  {tx['date']}  ${tx['amount']:>7.2f}  {tx['account'][:26]:26}  {tx['description'][:50]}")
    print()
    print(f"Missing count: {len(missing)}")

    # Save full report
    with open("C:\\Users\\Victor\\AppData\\Local\\Temp\\opencode\\intersite_match_report.md", "w", encoding="utf-8") as f:
        f.write("# Intersite FY2026 receipt match report\n\n")
        f.write(f"Generated: {__import__('datetime').datetime.now().isoformat()}\n\n")
        f.write(f"**Coverage (strict)**: {matched}/{len(candidates)} ({100*matched/max(1,len(candidates)):.1f}%) matched\n")
        f.write(f"  - matched by INTERSITE-side receipt:  {intersite_only_matched}\n")
        f.write(f"  - matched by ROOM-RENTALS-side only:  {matched - intersite_only_matched}\n")
        f.write(f"**Date tolerance**: ±{DATE_TOLERANCE_DAYS} days\n")
        f.write(f"**Amount tolerance**: ±{int(AMOUNT_TOLERANCE_PCT*100)}% (FX conversions)\n\n")
        f.write(f"## Misfiled in room-rentals ({len(stranded)} files — possible candidates)\n\n")
        for tx, path, meta, off in stranded:
            f.write(f"- `{tx['date']} ${tx['amount']:.2f}` — {tx['description']}  \n  → `room-rentals/{path.relative_to(RR_ROOT)}`\n")
        f.write(f"\n## Still-missing receipts ({len(missing)} transactions)\n\n")
        for tx in missing:
            f.write(f"- `{tx['date']} ${tx['amount']:.2f}` — {tx['account']} — {tx['description']} ({tx['category']})\n")
        f.write("\n## Raw misfile candidates (vendor name only — not date+amount matched)\n\n")

    # Also report room-rentals files whose vendor matches a known intersite vendor
    # These are "soft" candidates — receipt vendor looks like an intersite expense vendor
    intersite_vendors = {
        "openrouter", "moz", "interserver", "namecheap", "name-cheap", "name cheap",
        "creative fabrica", "stripe", "zai", "anomaly", "kilocode", "kilo code",
        "squarespace", "boldsign", "bold sign", "roomies", "fongo", "google",
        "pixella", "myclaw", "ignition", "freedom mobile", "bitwarden",
        "artem", "opencode", "opencode go",
    }
    soft_candidates = []
    for path, meta in rr_all:
        vl = meta["vendor"].lower()
        for v in intersite_vendors:
            if v in vl:
                soft_candidates.append((path, meta, v))
                break

    with open("C:\\Users\\Victor\\AppData\\Local\\Temp\\opencode\\intersite_match_report.md", "a", encoding="utf-8") as f:
        f.write(f"Vendor-keyword candidates in room-rentals: {len(soft_candidates)} files\n\n")
        for path, meta, v in soft_candidates:
            f.write(f"- `{meta['date']} ${meta['amount']:.2f} {meta['vendor']}`  \n  → `room-rentals/{path.relative_to(RR_ROOT)}`  (matched keyword: `{v}`)\n")


if __name__ == "__main__":
    main()
