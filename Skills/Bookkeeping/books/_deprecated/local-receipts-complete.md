---
name: bookkeeping/books/local-receipts-complete
description: DEPRECATED — renamed to bookkeeping/books/find-download-complete. Definition-of-done for Find & Download — all missing receipts are retrieved, renamed, and placed in the receipts folder.
---

# DEPRECATED — Use `bookkeeping/books/find-download-complete`

> This file is kept for backward compatibility. New code should reference `bookkeeping/books/find-download-complete`.

# Local Receipts Complete — Definition of Done

## Checklist

- [ ] `required-receipts.md` was generated from `bookkeeping/ingest/ingest-images`
- [ ] Every missing receipt was attempted — either retrieved or acknowledged as unavailable
- [ ] Retrieved receipts are renamed to the standard convention: `{YYYY-MM-DD} - {amount} - {Vendor} - {summary}.{ext}`
- [ ] Vendor-by-vendor retrieval complete — no vendor left unaddressed
- [ ] User has confirmed the receipt set is complete (or acknowledged remaining gaps)
- [ ] Re-ran gap analysis — `required-receipts.md` updated to reflect current state
- [ ] Manifest Update complete — all receipts have `status_manifest_update = done`

## What "Complete" Means

Receipt Phase 1 is complete when every transaction that needs a receipt has either (a) a receipt file in the folder, or (b) a documented reason it cannot be obtained. The user has visibility into what's missing and why.

## Exit Criteria

All checklist items are checked. Proceed to `bookkeeping/processing/manifest-update`.
