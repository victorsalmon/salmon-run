---
name: bookkeeping/books/preparation-complete
description: Definition-of-done for the Reconciliation Track's source validation — all source data is gathered and ready for reconciliation. Use when gathering is done and you need to verify nothing was missed before proceeding.
---

# Preparation Complete — Definition of Done

## Checklist

- [ ] All annual transaction CSVs downloaded from bank portals — one per account
- [ ] All monthly statement PDFs downloaded — one per month, per account, for the full fiscal or calendar year
- [ ] All available receipts gathered into the entity's `{Year} Receipts/` folder
- [ ] Entity bookkeeping state document updated with source data inventory
- [ ] Access credentials verified for bank portals and remote books

## What "Complete" Means

Phase 0 is complete when you have every source document you will need for the full pipeline. You may not have every receipt yet (that's handled in Find & Download), but you have:

- The complete set of bank transaction records (annual CSVs)
- The complete set of bank statements (monthly PDFs)
- A clear inventory of what receipts you already have

## Exit Criteria

All checklists items are checked. Proceed to `bookkeeping/sources/reconcile`.
