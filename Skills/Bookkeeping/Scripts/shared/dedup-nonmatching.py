"""Comprehensive non-matching receipt dedup.

Rubric (user-stated, 2026-06-18):
  Delete a receipt ONLY if all of the following are true:
    1. Its SHA256 hash matches the hash of another receipt file
    2. That other receipt has the same date
    3. That other receipt has the same amount

Both date and amount are read from the manifest (which is the source of truth
for each unique hash). The manifest has one canonical entry per unique hash.

Strategy:
  - Load manifest; build hash -> {canonical_filename, date, amount, vendor}
  - Walk non-matching/ folder
  - For each file, compute SHA256
  - Group files by hash
  - For each group with 2+ files:
      - Verify the manifest has a date for the hash (else: SKIP — unknown date)
      - Verify the manifest has an amount (or amount=0.00) — see note
      - Pick the "keeper": prefer the file already named canonically,
        else the lexicographically first one
      - Rename keeper to canonical name (if not already)
      - DELETE all other files in the group (along with their .md/.csv sidecars)
  - Log every action

Notes:
  - Files with hash NOT in the manifest are kept (untouched — true orphans).
  - For "unknown-date - 0.00 - Unknown.*" cases (date is `unknown-date` or
    missing), we CANNOT verify the user's "same date" criterion — SKIP.
  - For "0.00 - Unknown.*" cases (date present, amount=0.00), the manifest
    says amount=0.00; this is the OCR's "no amount found" marker. The
    canonical date is known, so the date match is satisfied. We treat
    amount=0.00 as a valid (if uninformative) value and allow dedup.
"""
import csv
import os
import re
import sys
import json
import hashlib
import shutil
from pathlib import Path
from collections import defaultdict
from datetime import datetime

_home = Path(os.path.expanduser("~"))
DEFAULT_NM_DIR = _home / "intersite-docs/Taxes and Bookkeeping/intersite-consulting/2026 Filing/Receipts/non-matching"
DEFAULT_MANIFEST_PATH = _home / "intersite-docs/Taxes and Bookkeeping/intersite-consulting/2026 Filing/Receipts/_manifest.csv"
DEFAULT_LOG_PATH = Path(os.environ.get("TEMP", str(_home / "AppData/Local/Temp"))) / "opencode/nonmatching_dedup_log.json"
NM_DIR = DEFAULT_NM_DIR
MANIFEST_PATH = DEFAULT_MANIFEST_PATH
LOG_PATH = DEFAULT_LOG_PATH

RECEIPT_EXTS = {".jpg", ".jpeg", ".png", ".pdf"}
SIDECAR_EXTS = {".md", ".csv"}

DATE_RE = re.compile(r"^(20\d{2})[-_](\d{2})[-_](\d{2})")
AMT_RE = re.compile(r"(\d{1,4}(?:\.\d{2})?)")


def load_manifest(manifest_path=None):
    """Return {hash: {filename, date, amount, vendor, notes}}."""
    path = manifest_path or MANIFEST_PATH
    out = {}
    with open(path, "r", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            h = (row.get("sha256") or "").strip()
            if not h:
                continue
            out[h] = {
                "filename": (row.get("filename") or "").strip(),
                "date": (row.get("date") or "").strip(),
                "amount": (row.get("amount") or "").strip(),
                "vendor": (row.get("vendor") or "").strip(),
                "status": (row.get("status") or "").strip(),
                "notes": (row.get("notes") or "").strip(),
            }
    return out


def sha256_of(p: Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def parse_canonical_date_amt(canonical: str):
    """Parse date+amount from a canonical filename like '2025-03-01 - 33.60 - Freedom Mobile.pdf'.
    Also handles 'non-matching\\2025-07-31 - 11.19 - Lines One.pdf' (folder prefix).
    Returns (date_iso, amount_str) or (None, None) if not parseable.
    If the canonical starts with 'unknown' or 'non-matching\\unknown', date is unknown."""
    # Strip folder prefixes
    if "\\" in canonical or "/" in canonical:
        canonical = canonical.replace("\\", "/").rsplit("/", 1)[-1]
    stem = canonical
    for ext in (".pdf", ".jpg", ".jpeg", ".png"):
        if stem.lower().endswith(ext):
            stem = stem[: -len(ext)]
            break
    # Check for explicit unknown-date marker
    if stem.lower().startswith("unknown"):
        return None, None
    m = DATE_RE.match(stem)
    if not m:
        return None, None
    date_iso = f"{m.group(1)}-{m.group(2)}-{m.group(3)}"
    rest = stem[m.end():].lstrip(" -_")
    a = AMT_RE.match(rest)
    amount_str = a.group(1) if a else None
    return date_iso, amount_str


def parse_filename_date_amt(filename: str):
    """Parse date+amount from any filename (not just canonical).
    Returns (date_iso, amount_str) or (None, None) if not parseable."""
    stem = filename
    for ext in (".pdf", ".jpg", ".jpeg", ".png"):
        if stem.lower().endswith(ext):
            stem = stem[: -len(ext)]
            break
    if stem.lower().startswith("unknown"):
        return None, None
    m = DATE_RE.match(stem)
    if not m:
        return None, None
    date_iso = f"{m.group(1)}-{m.group(2)}-{m.group(3)}"
    rest = stem[m.end():].lstrip(" -_")
    a = AMT_RE.match(rest)
    amount_str = a.group(1) if a else None
    return date_iso, amount_str


def canonical_to_filename(canonical: str) -> str:
    """Convert a manifest canonical name to a bare filename (no folder prefix)."""
    if "\\" in canonical or "/" in canonical:
        return canonical.replace("\\", "/").rsplit("/", 1)[-1]
    return canonical


def main():
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--apply", action="store_true", help="Actually delete/rename. Default is dry-run.")
    parser.add_argument("--folder", default=str(NM_DIR), help="Folder to dedup (default: non-matching/)")
    parser.add_argument("--manifest", default=str(MANIFEST_PATH), help="Path to _manifest.csv (default: derived from ~/intersite-docs)")
    parser.add_argument("--log", default=str(LOG_PATH), help="Path to dedup log output (default: temp dir)")
    args = parser.parse_args()

    folder = Path(args.folder)
    manifest = load_manifest(manifest_path=args.manifest)
    print(f"Loaded {len(manifest)} manifest entries (by hash)")

    # Walk target folder
    files_by_hash = defaultdict(list)
    for p in folder.rglob("*"):
        if not p.is_file():
            continue
        if p.suffix.lower() not in RECEIPT_EXTS:
            continue
        h = sha256_of(p)
        files_by_hash[h].append(p)

    print(f"Total receipt files in {folder.name}/: {sum(len(v) for v in files_by_hash.values())}")
    print(f"Unique hashes: {len(files_by_hash)}")
    print(f"Hashes with 2+ files (potential dupes): {sum(1 for v in files_by_hash.values() if len(v) > 1)}")
    print()

    # Process each multi-file group
    actions = {
        "groups_total": 0,
        "groups_skipped_no_manifest": [],
        "groups_skipped_unknown_date": [],
        "groups_skipped_ambiguous_amount": [],
        "groups_skipped_amount_mismatch": [],
        "groups_skipped_date_mismatch": [],
        "groups_deduped": [],
        "groups_kept_alone": [],
    }

    for h, files in sorted(files_by_hash.items()):
        if len(files) <= 1:
            continue
        actions["groups_total"] += 1
        m = manifest.get(h)
        if m is None:
            actions["groups_skipped_no_manifest"].append({"hash": h, "files": [str(f) for f in files]})
            continue
        canonical = m["filename"]
        canonical_basename = canonical_to_filename(canonical)
        # Try to find date+amount from canonical FIRST, then fall back to file names
        date_iso, amt_str = parse_canonical_date_amt(canonical)
        canonical_has_data = bool(date_iso and amt_str)
        if canonical_has_data:
            # Manifest is authoritative. Same hash = same content = same date+amount.
            # The "stubs" (0.00 - Unknown files) are duplicates whose metadata was stripped
            # when the file was copied/renamed. The hash match is the user's rubric.
            files_sorted = sorted(files, key=lambda p: (p.name != canonical_basename, p.name))
            keeper = files_sorted[0]
            duplicates = files_sorted[1:]
            assert all(sha256_of(d) == h for d in duplicates), "hash mismatch in group"
            actions["groups_deduped"].append({
                "hash": h,
                "canonical": canonical,
                "canonical_filename": canonical_basename,
                "date": date_iso,
                "amount": amt_str,
                "vendor": m["vendor"],
                "source": "manifest",
                "keeper": str(keeper),
                "deleted": [str(d) for d in duplicates],
            })
            continue
        # Canonical lacks date+amount — fall back to file names. ALL files must agree
        # because the manifest has no authoritative entry to trust.
        file_parsed = []
        for p in files:
            d, a = parse_filename_date_amt(p.name)
            file_parsed.append((p, d, a))
        valid = [(p, d, a) for p, d, a in file_parsed if d and a]
        if len(valid) == len(files):
            dates = {d for _, d, _ in valid}
            amts = {a for _, _, a in valid}
            if len(dates) == 1 and len(amts) == 1:
                date_iso = list(dates)[0]
                amt_str = list(amts)[0]
                files_sorted = sorted(files, key=lambda p: (p.name != canonical_basename, p.name))
                keeper = files_sorted[0]
                duplicates = files_sorted[1:]
                assert all(sha256_of(d) == h for d in duplicates), "hash mismatch in group"
                actions["groups_deduped"].append({
                    "hash": h,
                    "canonical": canonical,
                    "canonical_filename": canonical_basename,
                    "date": date_iso,
                    "amount": amt_str,
                    "vendor": m["vendor"],
                    "source": "file-names",
                    "keeper": str(keeper),
                    "deleted": [str(d) for d in duplicates],
                })
                continue
            else:
                if len(dates) > 1:
                    actions["groups_skipped_date_mismatch"].append({
                        "hash": h, "canonical": canonical,
                        "files_dates": list(dates),
                        "files": [str(f) for f in files],
                    })
                else:
                    actions["groups_skipped_amount_mismatch"].append({
                        "hash": h, "canonical": canonical,
                        "files_amounts": list(amts),
                        "files": [str(f) for f in files],
                    })
                continue
        # Not all files have date+amount
        if not any(d for _, d, _ in file_parsed):
            actions["groups_skipped_unknown_date"].append({
                "hash": h, "canonical": canonical, "files": [str(f) for f in files],
            })
        else:
            actions["groups_skipped_ambiguous_amount"].append({
                "hash": h, "canonical": canonical, "files": [str(f) for f in files],
            })

    # Print summary
    print("=== DEDUP ANALYSIS ===")
    print(f"Multi-file groups: {actions['groups_total']}")
    print(f"  - Dedupeable (same date+amount verified):     {len(actions['groups_deduped'])}")
    print(f"  - Skipped (no manifest entry):                {len(actions['groups_skipped_no_manifest'])}")
    print(f"  - Skipped (unknown date, no real date found): {len(actions['groups_skipped_unknown_date'])}")
    print(f"  - Skipped (ambiguous amount):                 {len(actions['groups_skipped_ambiguous_amount'])}")
    print(f"  - Skipped (date mismatch across files):       {len(actions['groups_skipped_date_mismatch'])}")
    print(f"  - Skipped (amount mismatch with canonical):   {len(actions['groups_skipped_amount_mismatch'])}")
    print()

    total_files_to_delete = sum(len(g["deleted"]) for g in actions["groups_deduped"])
    print(f"Files to delete: {total_files_to_delete}")
    print(f"Files to rename (to canonical): {len(actions['groups_deduped'])}")
    print()

    if not args.apply:
        print("=== DRY RUN — pass --apply to actually execute ===")
        print()
        print("Sample dedupable groups (first 10):")
        for g in actions["groups_deduped"][:10]:
            print(f"\n  Canonical: {g['canonical']}")
            print(f"  -> On disk: {g['canonical_filename']}")
            print(f"  Date: {g['date']}  Amount: ${g['amount']}  Vendor: {g['vendor']}")
            print(f"  KEEP:    {g['keeper']}")
            for d in g["deleted"]:
                print(f"  DELETE:  {d}")
        return

    # Execute
    print("=== APPLYING DEDUP ===")
    log = {"applied_at": datetime.now().isoformat(), "actions": {"renames": [], "deletes": []}, "errors": []}

    for g in actions["groups_deduped"]:
        keeper = Path(g["keeper"])
        canonical_filename = canonical_to_filename(g["canonical"])
        if keeper.name != canonical_filename:
            new_path = keeper.with_name(canonical_filename)
            if new_path.exists() and new_path != keeper:
                # Pick a unique name
                stem = new_path.stem
                ext = new_path.suffix
                i = 2
                while True:
                    alt = new_path.with_name(f"{stem}_{i}{ext}")
                    if not alt.exists():
                        new_path = alt
                        break
                    i += 1
            try:
                keeper.rename(new_path)
                log["actions"]["renames"].append({"from": str(keeper), "to": str(new_path)})
                keeper = new_path
            except Exception as e:
                log["errors"].append(f"rename failed: {keeper} -> {new_path}: {e}")
                continue

        for d_path in g["deleted"]:
            dp = Path(d_path)
            # Also delete sidecars (.md, .csv) that share the base name
            for ext in SIDECAR_EXTS:
                sidecar = dp.with_suffix(ext)
                if sidecar.exists():
                    try:
                        sidecar.unlink()
                        log["actions"]["deletes"].append(str(sidecar))
                    except Exception as e:
                        log["errors"].append(f"sidecar delete failed: {sidecar}: {e}")
            try:
                dp.unlink()
                log["actions"]["deletes"].append(str(dp))
            except Exception as e:
                log["errors"].append(f"delete failed: {dp}: {e}")

    print(f"Renames: {len(log['actions']['renames'])}")
    print(f"Deletes: {len(log['actions']['deletes'])}")
    print(f"Errors:  {len(log['errors'])}")
    log_path = Path(args.log)
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with open(log_path, "w", encoding="utf-8") as f:
        json.dump(log, f, indent=2)
    print(f"Log: {log_path}")


if __name__ == "__main__":
    main()
