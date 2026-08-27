---
name: bookkeeping/books/phase2-complete
description: DEPRECATED — renamed to bookkeeping/books/enrich-match-complete. Definition-of-done for Enrich & Match — receipt metadata is validated, enriched, and ready for Cloud Books upload.
---

# DEPRECATED — Use `bookkeeping/books/enrich-match-complete`

> This file is kept for backward compatibility. New code should reference `bookkeeping/books/enrich-match-complete`.

# Enrich & Match Complete — Definition of Done

## Checklist

- [ ] PDF Data Extraction complete — `status_pdf_extracted = done` for all receipts
- [ ] Image Data Extraction complete — `status_image_extracted = done` for all receipts
- [ ] Metadata File Renaming complete — `status_metadata_renamed = done` for all receipts
- [ ] Manifest Data Correction complete — `status_manifest_corrected = done` for all receipts
- [ ] Overall Manifest Update complete — `status_manifest_update = done` for all receipts
- [ ] Vendor names are normalized according to entity-specific rules
- [ ] All amounts pass validation (no Infinity, suspicious $0.00 flagged)
- [ ] All dates pass validation (no off-by >30 days without explanation)
- [ ] Classification notes explain every category assignment
- [ ] Any enrichment issues have been presented to the user and resolved

## What "Complete" Means

Receipt Phase 2 is complete when every receipt's metadata is trustworthy. The Manifest Update pipeline has run successfully, all 4 sub-steps (i-iv) have completed, all data quality checks pass, and any ambiguous cases have been resolved with the user.

## Exit Criteria

All checklist items are checked. Proceed to `bookkeeping/processing/cloud-match-and-upload`.
