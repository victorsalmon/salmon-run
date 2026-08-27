---
name: bookkeeping/cloudtax
description: Master workflow for filing Intersite Consulting Inc.'s T2 corporate tax return through CloudTax. Covers data preparation — selecting forms, mapping lines, assembling data sources.
domain: Bookkeeper
track: cloudtax
workflow: t2-production-filing
---

# CloudTax T2 Production Filing — Workflow

## Domain Responsibilities

This workflow owns the **data preparation** side of CloudTax filing. It decides:

1. **Which forms** to include based on business activity (`t2-form-selection`)
2. **What data** to pull and from where (`t2-data-sources`)
3. **How to map** draft schedule values to form lines (`t2-line-preparation`)

The **website interaction** (login, clicking, filling fields, navigation) is owned by the Browserless skill at `Skills/DevOps/Playwright/browserless-cloudtax-autofill.md`.

## Skill Sequence

| Step | Skill | What It Produces |
|------|-------|------------------|
| 1 | `t2-data-sources` | Assembled draft worksheet, JSON schedules, Zoho reports |
| 2 | `t2-form-selection` | List of CloudTax form IDs to add and fill |
| 3 | `t2-line-preparation` | Per-form JSON data files with line→value mappings |

After these three steps, invoke the Browserless autofill pipeline to execute the data entry.

## Data Flow

```
Draft Filing Pipeline                CloudTax Workflow (this)
   → draft-filing-worksheet.md  ──►  t2-data-sources: locate & verify
   → draft-t2-schedules.json    ──►  t2-form-selection: decide which forms
   → Zoho reports               ──►  t2-line-preparation: map lines
                                         ↓
                              Per-form JSON files
                                         ↓
                              Browserless autofill (cloudtax-autofill-skill.md)
                                         ↓
                              CloudTax portal filled
```

## Related Skills

| Skill | File | Container Domain |
|-------|------|------------------|
| T2 Data Sources | `skills/t2-data-sources.md` | Bookkeeper (what data) |
| T2 Form Selection | `skills/t2-form-selection.md` | Bookkeeper (which forms) |
| T2 Line Preparation | `skills/t2-line-preparation.md` | Bookkeeper (how to map) |
| CloudTax Autofill | `Skills/DevOps/Playwright/browserless-cloudtax-autofill.md` | Browserless (how to click) |

## Prerequisites

1. Draft T2 filing complete — `bookkeeping/tax-filing/draft-financials`
2. Proofreading complete — `bookkeeping/tax-filing/proofread-draft`
3. Draft worksheet + JSON on disk
4. `CLOUDTAX_INTERSITE_T2_URL` provisioned in Bookkeeping bundle (AWS SM)

---

## Changelog

- 2026-06-10: Established Bookkeeper/Browserless domain boundary; renamed skills to `t2-` prefix; documented S50/Schedule 3 equivalence
