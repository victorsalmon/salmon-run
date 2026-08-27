# Business Forecasting Memory Architecture

## Overview

Forecasting state is organized per-entity (client or business). Each session reads the state snapshot first, runs the forecast, and writes a new snapshot + session log entry.

## Files

| File | Path | Update |
|------|------|--------|
| State snapshot | `mem-{entity}-forecasting-state.md` | Overwritten each session |
| Session log | `mem-{entity}-forecaster-sessions.md` | Append-only, newest first |
| Forecast CSV | `forecast-{entity}-{period}.csv` | Per-run |
| Summary JSON | `forecast-{entity}-{period}-summary.json` | Per-run |

## State Snapshot Format

```markdown
# Forecasting State — {Entity Name}

**Last forecast:** YYYY-MM-DD
**Data span:** {N} months (YYYY-MM-DD to YYYY-MM-DD)
**Method:** monte_carlo | seasonal | simple_average
**Total transactions loaded:** {N}

## Recurring Patterns Detected ({N})
| Description | Amount | Day | Occurrences | Type |
|---|---|---|---|---|
| Client A Retainer | +$5,000 | 15th | 12 | income |

## Spontaneous Categories ({N})
| Category | Type | Method | Samples | Avg/Month | Avg Amount |
|---|---|---|---|---|---|
| Consulting Revenue | income | monte_carlo | 14 | 1.8 | $3,736 |

## Last Forecast Summary
- **Start balance:** $25,000.00
- **Horizon:** 365 days
- **End balance (P50):** $94,617.68
- **80% CI:** $77,399 – $115,228
- **Lowest P50:** $15,000.00
- **Output:** forecast-{entity}-2026-2027.csv
```

## Session Log Format

Append to `mem-{entity}-forecaster-sessions.md`:

```
### YYYY-MM-DD — {summary}
- Horizon: {N} days
- Method: {method}
- End P50: ${N}
- Overrides: {none | N contracts added}
- Notes: {anything unusual}
```

## Staleness Detection

A handoff or state snapshot is stale if:
1. More than 30 days have passed since `Last forecast` date
2. A new bank CSV or QuickBooks export is available that covers a later period
3. A known contract or recurring event has changed

When stale: re-run the forecast with updated data before making withdrawal decisions.
