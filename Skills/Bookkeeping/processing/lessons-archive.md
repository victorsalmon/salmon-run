---
name: bookkeeping/processing/lessons-archive
description: Archived Lessons Learned from receipt processing pipeline development. This file preserves the full historical record; the active skill file (process-receipts.md) keeps only current workflow guidance.
---

# Lessons Learned — Receipt Processing (Archived)

This file captures all Lessons Learned from receipt pipeline sessions. New lessons should be added to this archive and kept out of the active skill files.

---

## 2026-06-01 — Initial Pipeline Development

**What Worked:**
- **pdfplumber for PDFs**: Extracts amounts and vendors reliably from Amazon.ca invoices. Zero API cost.
- **pypdfium2 + GPT-4o-mini for image-based PDFs**: Scanned/image PDFs rendered to JPEG via pypdfium2, then sent to GPT-4o-mini vision. Uses same OpenRouter key as image extraction.
- **GPT-4o-mini for images**: Correctly identifies vendors from PXL photos. ~$0.01/image on OpenRouter.
- **Filename date fallback**: Many files have dates in their filenames that extraction fails to find.
- **Amount-matched no-date folder**: Separates confidently-matched from needs-review files cleanly.
- **Cache file (.receipt-cache.json)**: Hash-deduplicates files across runs.
- **Enriched statement CSV**: Direct link between statement lines and receipt files.
- **Amazon Order Invoice pattern**: `Invoice date / Date de facturation: DD MonthName YYYY` in top-right of Amazon Order Invoices.
- **French accent normalization**: `str.maketrans('àâäéèêëîïôöùûüç', 'aaaeeeeiioouuuc')` for regex matching.
- **Persistent Chrome profile**: `chromium.launchPersistentContext(DATA_DIR)` saves Amazon login between runs.
- **Lightspeed Customer # mapping**: Customer # `48927` = FRA/room-rentals, `76837` = TMH/scotia.
- **Credit note pairing**: "c$"/"r" prefix or "Credit Note" text → refund, not expense.
- **Three-folder strategy**: `rbc-6258/`, `no-date/`, `non-matching/` — clean confidence separation.
- **Manual verify workflow**: User vetted files in `no-date/correct/` → agent moves to `rbc-6258/` + sets `Date_Source=MANUAL_VERIFY`.

**What Didn't Work:**
- Keyword-only date patterns missed Amazon's multi-format dates. Fix: Scan entire text for ALL date patterns, filter by year, fall back to filename.
- Single-pass copy creates duplicates. Fix: Clean folder and re-populate from manifest each time.
- Windows cp1252 console encoding crashes on Unicode. Fix: `PYTHONIOENCODING=utf-8`.
- pdfplumber picks up Amazon seller label lines. Fix: Vendor name cleanup rules.
- Credit notes treated as expenses. Fix: Detect and pair with original purchase.
- GPT-4o-mini hallucinated dates on PXL photos (2015/2023 vs 2025). Fix: Validate year against statement period.
- `amazon-persistent-downloader.js` fresh profile required re-login every run. Fix: Use `launchPersistentContext`.
- GPT-4o-mini fabricates card_last4 (Mobil $33.32: returned "1010"). Fix: Reject hallucinated last4, route to `hallucinated-card/` review folder.
- GPT-4o-mini returns "unknown" vendor on readable receipts. Fix: Flag for manual vendor review in `needs-vendor/` subfolder.
- No sidecars created for JPG/PNG images. Fix: Every processed file gets sidecars regardless of input format.
- Vision output never cross-referenced against bank statement. Fix: Bidirectional cross-reference after extraction.

---

## 2026-06-12 — Invoice Processing

**What Worked:**
- Verified Original triple convention (original + .md + .csv) cleanly separates evidence from metadata
- `convert-pdf-invoice-to-sidecar.py` works reliably for PDF invoices with extractable text
- Zoho API update via `PUT /expenses/{id}` with minimal payload correctly updates expense dates
- IMAP mailbox scanning with `uid` tracking prevents re-downloading duplicates

**What Didn't Work:**
- `convert-pdf-invoice-to-sidecar.py --images` crashes on JPG/PNG — `build_base_name()` receives string not dict
- PowerShell doesn't expand `*.jpg` glob before passing to Python
- Converter uses subtotal not total for canonical filename on some invoices
- Old `from-email` pipeline didn't handle JPG/PNG photos or text-only forwards

**Improvements for next run:**
- Fix `build_base_name()` to handle string input
- Prefer total amount over subtotal for canonical filename
- Add `--total` override flag

---

## 2026-06-16 — Pipeline Re-process

**What Worked:**
- `extract-match-credit-card.py --card-suffix 6258 --vendor-hint` re-processed 573 receipts without errors
- Manual MCP attachment worked for non-auto-matchable receipts
- Keeping non-matching receipts in `rbc-6258/non-matching/` preserved them for review

**What Didn't Work:**
- USD receipt ($5.00) didn't match CAD Zoho expense ($6.98) due to FX difference
- Fongo/Google Play PDF had no extractable amount
- Script summary misleadingly counted already-present files as "newly matched"

**Improvements for next run:**
- Add FX-aware matching for USD→CAD cross-references
- Improve OCR for forwarded email-body receipts
- Add "manual match" mode to attach without statement match
- Clarify summary output for already-present vs newly matched
