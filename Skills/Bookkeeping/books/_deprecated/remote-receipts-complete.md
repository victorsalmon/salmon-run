---
name: bookkeeping/books/remote-receipts-complete
description: DEPRECATED — superseded by bookkeeping/books/upload-complete. Definition-of-done for Upload — every receipt is uploaded and attached to its correct transaction.
---

# Remote Receipts Complete — Definition of Done

## Checklist

- [ ] Every receipt in `manifest-enriched.csv` is uploaded to the remote books
- [ ] Every receipt is attached to its correct transaction (or created as an expense for future matching)
- [ ] For Path A receipts (existing transactions): attachment is confirmed via remote books API or UI
- [ ] For Path B receipts (new expenses): `paid_through_account_id` is set to the correct account
- [ ] No failed uploads remain (batch state shows 100% complete)
- [ ] Circuit breaker was respected — no silent failures or retries on un-fixed errors
- [ ] Receipt count in remote books equals receipt count in `manifest-enriched.csv`

## What "Complete" Means

Receipt Phase 3 is complete when every receipt you have is uploaded and linked to the transaction it belongs to. A reviewer looking at any transaction in the remote books can find its supporting receipt.

## Exit Criteria

All checklist items are checked. Proceed to `bookkeeping/milestone/ready-for-bookkeeper` if you're done with the full pipeline.
