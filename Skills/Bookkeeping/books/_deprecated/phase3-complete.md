---
name: bookkeeping/books/phase3-complete
description: DEPRECATED — renamed to bookkeeping/books/upload-complete. Definition-of-done for Upload — every receipt is uploaded and attached to its correct transaction in Cloud Books.
---

# DEPRECATED — Use `bookkeeping/books/upload-complete`

> This file is kept for backward compatibility. New code should reference `bookkeeping/books/upload-complete`.

# Upload Complete — Definition of Done

## Checklist

- [ ] Cloud Match complete — `status_cloud_match = done` for all receipts
- [ ] Every receipt in `manifest-enriched.csv` is uploaded to Cloud Books
- [ ] Every receipt is attached to its correct transaction (or created as an expense for future matching)
- [ ] For Path A receipts (existing transactions): attachment is confirmed via Cloud Books API or UI
- [ ] For Path B receipts (new expenses): `paid_through_account_id` is set to the correct account
- [ ] No failed uploads remain (batch state shows 100% complete)
- [ ] Circuit breaker was respected — no silent failures or retries on un-fixed errors
- [ ] Receipt count in Cloud Books equals receipt count in `manifest-enriched.csv`

## What "Complete" Means

Receipt Phase 3 is complete when every receipt you have is uploaded and linked to the transaction it belongs to in Cloud Books. A reviewer looking at any transaction in Cloud Books can find its supporting receipt.

## Exit Criteria

All checklist items are checked. Proceed to `bookkeeping/milestone/ready-for-bookkeeper` if you're done with the full pipeline.
