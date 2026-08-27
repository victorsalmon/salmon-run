---
name: marketer/business-forecasting
description: Business Forecasting track for the Marketer Domain — cash flow prediction, income forecasting, and withdrawal-safety analysis. Accepts historical bank CSVs, detects recurring income/expense patterns, and runs Monte Carlo (or seasonal fallback) to project future daily bank balances.
---

# Business Forecasting Track

## Track Overview

One workflow with two entry modes:

```
INGEST ──→ CLASSIFY ──→ SIMULATE ──→ OUTPUT
  │            │            │           │
  │    Recurring detection    │     Forecast CSV
  │    Spontaneous modeling   │     Summary JSON
  │    Category assignment    │     Cash-safe answer
```

| Phase | Step | What happens |
|-------|------|-------------|
| Ingest | Collect bank CSVs, QuickBooks export, or prior forecast | Load transaction history |
| Classify | Run `income-forecast.py --csv ...` | Detect recurring patterns; categorize spontaneous |
| Simulate | Monte Carlo (1000 runs) or Seasonal fallback | Compute P10/P50/P90 balance trajectories |
| Output | Read `forecast.csv` + `forecast-summary.json` | CSV with day-by-day P50/P10/P90 balance; plain-English cash position |

## Cadence

| Trigger | Action |
|---------|--------|
| Start of month / quarter | Full forecast with updated data |
| Before major withdrawal | Cash-position check |
| New contract signed | Add to recurring list, re-forecast |
| General curiosity | Ad-hoc, any horizon |

## Entry Points

| Task | Start Here |
|------|------------|
| Full forecast for client | `marketer/business-forecasting/income-forecast` |
| Withdrawal safety check | `Income Forecast Workflow § Cash Position` |
| Add known recurring contract | `Income Forecast Workflow § Manual Override` |
| Interpret existing forecast | Read `*-summary.json` adjacent CSV |

## Script Reference

| Script | Location | Purpose |
|--------|----------|---------|
| `income-forecast.py` | `Skills/Marketer/business-forecasting/income-forecast.py` | Core engine: load, classify, simulate, output. Supports `--row-ids` for traceability with companion scripts. |
| `hash-csv.py` | `Skills/Marketer/business-forecasting/hash-csv.py` | Pre-processor: anonymize raw bank CSV before agent sees it. Replaces descriptions with SHA-256 hashes (per-session salt), assigns UUIDs. Outputs anonymized CSV + `-lookup.json`. |
| `rename-csv.py` | `Skills/Marketer/business-forecasting/rename-csv.py` | Post-processor: restore original descriptions to forecast CSV using `-lookup.json` from `hash-csv.py`. Run on USB drive after agent returns results. |

### Privacy Pipeline

```
USB (stays with client)              Laptop (agent sees only anonymized data)
─────────────────────────             ─────────────────────────────────────
raw-bank.csv
    │
    ├─ python hash-csv.py --csv raw-bank.csv --output anonymized.csv
    │
    │  Produces:                      Agent reads:
    │  anonymized.csv  ─────────────→  row_id, date, hash, amount, category, type
    │  anonymized-lookup.json          (no merchant names — only SHA-256 hashes)
    │  (stays on USB)                     │
    │                                  Agent runs:
    │                                  income-forecast.py --csv anonymized.csv
    │                                                    --balance X --row-ids
    │                                                    --output forecast.csv
    │                                              │
    │  ←────────────────────────────── forecast.csv (with row_ids column)
    │
    ├─ python rename-csv.py --forecast forecast.csv --lookup anonymized-lookup.json
    │
    │  Produces: forecast-restored.csv (original merchant names restored)
    │
    └─ Client reviews forecast-restored.csv with full context
```

> **No raw transaction description ever enters the agent's context.** The lookup JSON stays on the USB drive. Rename runs after the agent session is complete.

## Memory Architecture

See `marketer/business-forecasting/memory` for state snapshot format, session logs, and handoff cleanup rules.
