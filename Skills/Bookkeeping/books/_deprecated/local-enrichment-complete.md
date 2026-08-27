---
name: bookkeeping/books/local-enrichment-complete
description: DEPRECATED — superseded by bookkeeping/books/enrich-match-complete. Definition-of-done for Enrich & Match — receipt metadata is validated, enriched, and ready for upload.
---

# Local Enrichment Complete — Definition of Done

## Checklist

- [ ] `manifest-enriched.csv` exists with all columns populated
- [ ] Every receipt has a `suggested_account_id`
- [ ] Vendor names are normalized according to entity-specific rules
- [ ] All amounts pass validation (no Infinity, suspicious $0.00 flagged)
- [ ] All dates pass validation (no off-by >30 days without explanation)
- [ ] Filename collisions resolved
- [ ] Classification notes explain every category assignment
- [ ] Any enrichment issues have been presented to the user and resolved

## What "Complete" Means

Receipt Phase 2 is complete when every receipt's metadata is trustworthy. The enrichment pipeline has run successfully, all data quality checks pass, and any ambiguous cases have been resolved with the user.

## Exit Criteria

All checklist items are checked. Proceed to `bookkeeping/processing/cloud-match-and-upload`.
