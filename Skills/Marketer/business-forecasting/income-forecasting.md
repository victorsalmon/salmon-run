---
name: marketer/business-forecasting/income-forecast
description: Full income forecast workflow — ingest bank CSVs, detect recurring patterns, run Monte Carlo simulation (or seasonal fallback), output a daily balance CSV. Use when the client needs a cash-flow projection for any time horizon (30/90/365 days or custom).
---

# Income Forecasting Workflow

## Requirements

| Item | Source |
|------|--------|
| Historical bank transactions (≥12 months ideal) | Bank CSV, QuickBooks export, or prior forecast CSV |
| Most recent statement balance | Bank portal or last statement |
| Forecast horizon | User specifies in days (30, 90, 365, or custom) |
| Known upcoming contracts (optional) | User provides as override JSON |

## Step 1 — Gather Historical Data

Collect transaction CSVs. The engine auto-detects column names:
- `date`, `description`, `amount`, `category`, `type`
- Or: `date`, `description`, `debit`, `credit` (debit/credit columns)

**QuickBooks export:** Export Transactions → CSV with columns: Date, Description, Amount. QuickBooks uses split debits/credits — the engine handles both formats.

**Bank CSV:** Export transactions from your bank portal (3 months to 2+ years).

> **Data minimums:**
> | Data span | Method | Accuracy |
> |-----------|--------|----------|
> | ≥12 months + ≥8 events/category | Monte Carlo (lognormal + Poisson) | Best — captures variance |
> | 3–11 months or 3–7 events/category | Seasonal (monthly averages) | Moderate — no variance |
> | <3 months or <3 events/category | Simple average only | Low — use as rough guide |

## Step 2 — Run the Forecast Engine

```powershell
python Skills/Marketer/business-forecasting/income-forecast.py ^
    --csv data/bank-2025.csv,data/bank-2026.csv ^
    --balance 25000.00 ^
    --horizon 365 ^
    --output Skills/Marketer/business-forecasting/forecast-2026-2027.csv ^
    --seed 42
```

| Flag | Required | Default | Purpose |
|------|----------|---------|---------|
| `--csv` | Yes | — | Comma-separated list of CSV file paths |
| `--balance` / `-b` | Yes | — | Most recent bank statement balance |
| `--statement-date` / `-s` | No | Last CSV date | Date of most recent statement (YYYY-MM-DD) |
| `--horizon` / `-n` | No | 365 | Forecast horizon in days |
| `--known-events` / `-k` | No | — | JSON file of known future contracts/expenses |
| `--cash-position` / `-c` | No | — | Withdrawal amount to check safety against forecast |
| `--output` / `-o` | No | `income-forecast.csv` | Output CSV path |
| `--runs` | No | 1000 | Monte Carlo simulation count (higher = smoother percentiles) |
| `--seed` | No | random | Seed for reproducible results |
| `--row-ids` | No | off | Emit `row_ids` column in output CSV for traceability with `hash-csv.py`/`rename-csv.py` |

### What the Engine Does

1. **Load** CSVs, normalize column names, deduplicate
2. **Detect recurring patterns** — same amount ±5% on same day-of-month ±3 days, ≥5 occurrences. These become deterministic (100% confidence)
3. **Build spontaneous models** per category:
   - Monte Carlo: lognormal amount distribution + Poisson arrival + seasonal factors (≥8 samples, ≥12 months data)
   - Seasonal: monthly averages with uniform sampling (3–7 samples or 3–11 months)
   - Simple average: mean amount per month (<3 samples or <3 months)
4. **Simulate** 1000 independent paths; aggregate to P10/P50/P90 balance per day
5. **Output** CSV with balance-forward row + recurring event rows + monthly spontaneous summaries

## Step 3 — Read the Output

### CSV Columns

| Column | Meaning |
|--------|---------|
| `date` | Date of event |
| `description` | Transaction description or "Est. {Category}" |
| `category` | Assigned category (Consulting Revenue, Rent, etc.) |
| `type` | income / expense / balance_forward / adjustment |
| `amount` | Transaction amount (positive = income, negative = expense) |
| `adjustments` | **User-input column** — enter unexpected changes here (starts as 0.0) |
| `running_balance` | P50 (median) bank balance on this date |
| `p10_balance` | P10 (pessimistic) balance — only 10% of scenarios are worse |
| `p90_balance` | P90 (optimistic) balance — 90% of scenarios are at or below |
| `confidence` | `recurring` / `high` / `medium` / `low` |
| `rationale` | Explanation: how many historical samples, detection method |

## Using the Adjustments Column in Sheets / Excel

The `adjustments` column is pre-filled with `0.0` — it's your manual override space. When an unexpected event happens (late payment, surprise expense, early invoice), enter the amount there and the spreadsheet recalculates:

**Google Sheets formula for a recalculated balance:**

In a new column (e.g., `L`), add:
```
=L2 + IF(K3="balance_forward", 0, E3 + F3)
```
Where `E` is `amount`, `F` is `adjustments`, `K` is `type`, `L` is the recalculated balance column. This formula skips the balance-forward row (which is a starting snapshot, not a delta) and sums `amount + adjustments` for every subsequent row.

**Simpler approach** — add a `recalculated` column with:
```
=G2 + E3 + F3
```
(where `G` = running_balance, `E` = amount, `F` = adjustments), then drag down. The first row's `recalculated` matches the balance forward; every row below adds the day's events + any manual adjustments.

> **Reading the confidence range:** If `running_balance` is $22,000 and `p10_balance` is $12,000, then withdrawing $8,000 leaves $14,000 which is still above the P10 floor — low risk. Withdrawing $15,000 leaves $7,000 below P10 — higher risk.

### Summary JSON

Adjacent `*-summary.json` contains:

```json
{
  "forecast": {
    "start_date": "2026-01-01",
    "end_date": "2026-12-31",
    "method": "monte_carlo",
    "start_balance": 25000.00
  },
  "p50": {
    "end_balance": 94617.68,
    "peak_balance": 95911.54,
    "trough_balance": 15000.00
  },
  "safety": {
    "minimum_p90_balance": 15000.00,
    "minimum_p10_balance": 14500.00,
    "p10_end_balance": 77399.12,
    "p90_end_balance": 115228.58
  }
}
```

## Step 4 — Cash Position ("Can I withdraw?")

**Rule of thumb:** A withdrawal is safe when the P50 balance minus the withdrawal amount ≥ P10 balance for the entire period after withdrawal.

Example: If P50 on Nov 15 is $22,000 and P10 on that date is $12,000:

| Withdrawal | Safe? | Why |
|------------|-------|-----|
| $5,000 on Nov 10 | Yes | Remaining $17,000 > P10 of $12,000 |
| $10,000 on Nov 10 | Yes | Remaining $12,000 = P10 — exactly at threshold |
| $15,000 on Nov 10 | No | Remaining $7,000 < P10 of $12,000 — 10% chance of overdraft |

**Conservative rule:** Only withdraw if post-withdrawal balance ≥ P10 minimum for all remaining dates.

**Aggressive rule:** Only withdraw if post-withdrawal balance never goes negative (allow using P50).

## Step 5 — Manual Override (New Contracts / Known Events)

Create a JSON file with known future events and pass it via `--known-events`:

```json
[
  {"date": "2026-07-01", "description": "New Retainer - Client D", "amount": 3000.00, "category": "Consulting Revenue", "confidence": "recurring"},
  {"date": "2026-08-15", "description": "Annual Insurance Premium", "amount": -1200.00, "category": "Insurance", "confidence": "high"}
]
```

The engine merges known events into the recurring projection with `high` confidence. They appear in the CSV alongside detected recurring patterns.

## Frequently Asked Questions

**Q: How much history does Monte Carlo require?**
A: Minimum 12 months of data with at least 8 spontaneous events in a category. With less data, the engine automatically falls back to Seasonal or Simple Average. Each additional year of data improves the distribution fit and seasonal factor accuracy.

**Q: What if I use QuickBooks instead of bank CSVs?**
A: Export QuickBooks transactions as CSV — the engine auto-detects column headers including `amount`, `debit`/`credit`. Works with any format that has date + amount columns.

**Q: How are expenses categorized?**
A: The engine uses keyword-based inference (e.g., "rent" → "Rent", "aws" → "Software & IT") plus your CSV's `category` column if present. Unmatched items get "Uncategorized".

**Q: What does "P50" mean?**
A: P50 = median outcome. 50% of simulations ended at or below this balance, 50% above. P10 is the 10th percentile (worse case, 10% chance of being lower). P90 is the 90th percentile (90% chance of being at or below).

**Q: Do I need to clean the CSV data first?**
A: The engine auto-deduplicates identical (date, description, amount) combos and skips zero-amount rows. It's best to provide raw exports without manual cleaning.

---

## Changelog

- 2026-06-08: Fixed daily probability threshold bug; fixed mid-month date ordering; added `--known-events` flag; documented 3-tier model selection and seasonal determinism
