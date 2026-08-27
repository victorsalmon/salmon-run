#!/usr/bin/env python3
"""Used by: Skills/Marketer/business-forecasting/income-forecasting.md

Income Forecast Engine — Monte Carlo with Seasonal Fallback

Predicts bank account balance by modeling recurring income/expense (deterministic)
and spontaneous transactions (probabilistic). Outputs a CSV with day-by-day balance.

Usage:
  python income-forecast.py ^
    --csv data/bank-2025.csv,data/bank-2026.csv ^
    --balance 25000.00 ^
    --horizon 365 ^
    --output forecast-2026-2027.csv

Input CSV format (any column name variation of Date/Description/Amount/Category/Type):
  date,description,amount,category,type
  2025-01-15,Client A Payment,5000.00,Consulting Revenue,income
  2025-01-20,Rent,-2000.00,Office Lease,expense

Output CSV columns:
  date,description,category,type,amount,adjustments,running_balance,p10_balance,p90_balance,confidence,rationale

Additional flags:
  --known-events / -k    JSON file of known future events (contracts, expenses)
  --cash-position / -c   Withdrawal amount — returns safe/caution/unsafe verdict

Model selection (auto):
  - 8+ spontaneous samples per category → Monte Carlo (lognormal + Poisson)
  - 3-7 samples → Seasonal (monthly averages, uniform sampling)
  - <3 samples → Simple average only
"""

import csv
import sys
import argparse
import json
import os
import re
import math
import random
import statistics
from datetime import datetime, timedelta, date
from collections import defaultdict
from pathlib import Path

# ============================================================
# CONFIGURATION
# ============================================================

RECURRING_AMOUNT_TOLERANCE = 0.05
RECURRING_DAY_TOLERANCE = 3
RECURRING_MIN_OCCURRENCES = 5
MONTE_CARLO_MIN_SAMPLES = 8
SEASONAL_MIN_SAMPLES = 3
MONTE_CARLO_RUNS = 1000
SEASONAL_MIN_MONTHS = 6

# ============================================================
# HELPERS
# ============================================================

AMOUNT_FIELDS = {'amount', 'value', 'total', 'sum'}
DATE_FIELDS = {'date', 'txn_date', 'transaction_date', 'posting_date', 'posted_date'}
DESC_FIELDS = {'description', 'desc', 'payee', 'name', 'memo', 'notes', 'vendor'}
CAT_FIELDS = {'category', 'cat', 'account', 'type_label'}
TYPE_FIELDS = {'type', 'txn_type', 'transaction_type', 'debit_or_credit', 'sign'}

MONTHS_ABB = {
    'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4,
    'may': 5, 'jun': 6, 'jul': 7, 'aug': 8,
    'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12
}


def find_column(headers, candidates):
    """Find the first header matching any candidate (case-insensitive, prefix)."""
    hl = [h.strip().lower() for h in headers]
    for i, h in enumerate(hl):
        for c in candidates:
            if h == c or h.startswith(c):
                return i
    return None


def parse_date(value):
    """Try multiple date formats, return date object or None."""
    value = value.strip()
    fmts = [
        '%Y-%m-%d', '%Y/%m/%d',
        '%m/%d/%Y', '%m/%d/%y',
        '%d/%m/%Y', '%d/%m/%y',
        '%b %d %Y', '%b %d, %Y',
        '%B %d %Y', '%B %d, %Y',
        '%d-%b-%Y', '%d-%b-%y',
    ]
    for fmt in fmts:
        try:
            return datetime.strptime(value, fmt).date()
        except ValueError:
            continue
    return None


def parse_amount(value):
    """Parse a numeric string, handling $, (), commas."""
    if isinstance(value, (int, float)):
        return float(value)
    v = value.strip().replace('$', '').replace(',', '').strip()
    if v.startswith('(') and v.endswith(')'):
        return -float(v[1:-1])
    if v.startswith('-'):
        return -float(v[1:])
    try:
        return float(v)
    except ValueError:
        return 0.0


def lognormal_mean_std(values):
    """Fit lognormal distribution to positive values. Returns (mu, sigma) or None."""
    pos = [v for v in values if v > 0]
    if len(pos) < 3:
        return None
    logs = [math.log(v) for v in pos]
    try:
        mu = statistics.mean(logs)
        sigma = statistics.stdev(logs)
        return (mu, max(sigma, 0.01))
    except statistics.StatisticsError:
        return None


def seasonal_factors(transactions, months):
    """Compute monthly seasonal factors: list of 12 multipliers (1.0 = average)."""
    monthly_totals = [0.0] * 12
    monthly_counts = [0] * 12
    for t in transactions:
        m = t.date.month - 1
        monthly_totals[m] += abs(t.amount)
        monthly_counts[m] += 1

    overall_avg_count = sum(monthly_counts) / max(months, 1)
    factors = []
    for m in range(12):
        if monthly_counts[m] > 0 and overall_avg_count > 0:
            factors.append(monthly_counts[m] / overall_avg_count)
        else:
            factors.append(1.0)
    return factors


def clamp(val, lo, hi):
    return max(lo, min(hi, val))


# ============================================================
# DATA MODEL
# ============================================================

class Transaction:
    __slots__ = ('date', 'description', 'amount', 'category', 'txn_type', 'row_id')

    def __init__(self, txn_date, description, amount, category='Uncategorized',
                 txn_type=None, row_id=None):
        self.date = txn_date if isinstance(txn_date, date) else parse_date(str(txn_date))
        self.description = description.strip()
        self.amount = float(amount)
        self.category = category or 'Uncategorized'
        self.row_id = row_id
        if txn_type:
            self.txn_type = txn_type.lower()
        else:
            self.txn_type = 'income' if self.amount >= 0 else 'expense'

    def __repr__(self):
        return f"<{self.date} {self.description} ${self.amount:.2f} [{self.category}]>"


class RecurringPattern:
    """A detected recurring income/expense pattern."""

    def __init__(self, description, amount, day_of_month, category,
                 txn_type, occurrences, amount_std=0.0, row_ids=None):
        self.description = description
        self.amount = round(amount, 2)
        self.day_of_month = day_of_month
        self.category = category
        self.txn_type = txn_type
        self.occurrences = occurrences
        self.amount_std = round(amount_std, 2)
        self.row_ids = row_ids or []

    def project(self, from_date, to_date):
        """Generate all occurrences from from_date to to_date."""
        results = []
        cur = date(from_date.year, from_date.month, 1)
        while cur <= to_date:
            target_day = min(self.day_of_month,
                             calendar_month_days(cur.year, cur.month))
            occ_date = date(cur.year, cur.month, target_day)
            if occ_date >= from_date:
                results.append(occ_date)
            cur = add_months(cur, 1)
        return results

    def confidence_label(self):
        if self.occurrences >= 12:
            return 'recurring'
        elif self.occurrences >= 8:
            return 'recurring'
        return 'recurring'


class SpontaneousModel:
    """Probabilistic model for a category of spontaneous transactions."""

    def __init__(self, category, txn_type, transactions, months_of_data):
        self.category = category
        self.txn_type = txn_type
        self.transactions = sorted(transactions, key=lambda t: t.date)
        self.count = len(transactions)
        self.months = months_of_data

        amounts = [abs(t.amount) for t in self.transactions]
        self.mean_amount = statistics.mean(amounts) if amounts else 0.0
        self.stdev_amount = statistics.stdev(amounts) if len(amounts) > 1 else self.mean_amount * 0.3
        self.min_amount = min(amounts) if amounts else 0.0
        self.max_amount = max(amounts) if amounts else 0.0

        self.avg_per_month = self.count / max(months_of_data, 1)
        self.lognormal_params = lognormal_mean_std(amounts)
        self.seasonal = seasonal_factors(transactions, months_of_data)

        if self.count >= MONTE_CARLO_MIN_SAMPLES and months_of_data >= 6:
            self.method = 'monte_carlo'
        elif self.count >= SEASONAL_MIN_SAMPLES:
            self.method = 'seasonal'
        else:
            self.method = 'simple_average'

    def sample_amount(self, month_idx=None):
        """Sample an amount from the fitted distribution."""
        if self.method == 'monte_carlo' and self.lognormal_params:
            mu, sigma = self.lognormal_params
            return math.exp(random.gauss(mu, sigma))
        return random.uniform(self.min_amount, self.max_amount)

    def expected_count(self, month_idx):
        """Expected number of events in given month (0-indexed)."""
        base = self.avg_per_month
        if self.months >= SEASONAL_MIN_MONTHS:
            base *= self.seasonal[month_idx]
        return base

    def confidence(self):
        if self.method == 'monte_carlo':
            return 'medium' if self.count >= 12 else 'medium'
        elif self.method == 'seasonal':
            return 'medium'
        return 'low'

    def rationale(self):
        parts = []
        if self.method == 'monte_carlo':
            parts.append(f'Monte Carlo ({self.count} historical samples')
        elif self.method == 'seasonal':
            parts.append(f'Seasonal model ({self.count} samples')
        else:
            parts.append(f'Simple avg ({self.count} samples')
        parts.append(f'~{self.avg_per_month:.1f}/mo')
        parts.append(f'avg ${self.mean_amount:.0f})')
        return ' '.join(parts)


# ============================================================
# PARSING
# ============================================================

def calendar_month_days(year, month):
    """Get number of days in a month."""
    if month == 12:
        return (date(year + 1, 1, 1) - date(year, 12, 1)).days
    return (date(year, month + 1, 1) - date(year, month, 1)).days


def add_months(d, n):
    """Add n months to date d."""
    total_months = d.year * 12 + d.month - 1 + n
    year = total_months // 12
    month = total_months % 12 + 1
    day = min(d.day, calendar_month_days(year, month))
    return date(year, month, day)


def infer_type_from_debit_credit(row, debit_col, credit_col):
    """Determine type from debit/credit columns."""
    debit = parse_amount(row[debit_col]) if debit_col is not None else 0
    credit = parse_amount(row[credit_col]) if credit_col is not None else 0
    if credit and credit > 0:
        return 'income', credit
    if debit and debit > 0:
        return 'expense', -debit
    return 'expense', 0.0


def infer_category(description):
    """Keyword-based category inference for common business items."""
    d = description.lower()
    rules = [
        ('rent', 'Rent', 'expense'),
        ('lease', 'Lease', 'expense'),
        ('internet', 'Internet', 'expense'),
        ('hydro', 'Utilities', 'expense'),
        ('electric', 'Utilities', 'expense'),
        ('water', 'Utilities', 'expense'),
        ('gas', 'Utilities', 'expense'),
        ('phone', 'Telephone', 'expense'),
        ('software', 'Software & IT', 'expense'),
        ('subscription', 'Software & IT', 'expense'),
        ('hosting', 'Software & IT', 'expense'),
        ('domain', 'Software & IT', 'expense'),
        ('aws', 'Software & IT', 'expense'),
        ('azure', 'Software & IT', 'expense'),
        ('google cloud', 'Software & IT', 'expense'),
        ('insurance', 'Insurance', 'expense'),
        ('accounting', 'Professional Fees', 'expense'),
        ('legal', 'Professional Fees', 'expense'),
        ('lawyer', 'Professional Fees', 'expense'),
        ('consult', 'Professional Fees', 'expense'),
        ('contractor', 'Contractor', 'expense'),
        ('advertis', 'Advertising', 'expense'),
        ('marketing', 'Advertising', 'expense'),
        ('travel', 'Travel', 'expense'),
        ('hotel', 'Travel', 'expense'),
        ('flight', 'Travel', 'expense'),
        ('mileage', 'Automobile', 'expense'),
        ('fuel', 'Automobile', 'expense'),
        ('gas station', 'Automobile', 'expense'),
        ('parking', 'Automobile', 'expense'),
        ('restaurant', 'Meals & Entertainment', 'expense'),
        ('lunch', 'Meals & Entertainment', 'expense'),
        ('dinner', 'Meals & Entertainment', 'expense'),
        ('coffee', 'Meals & Entertainment', 'expense'),
        ('office', 'Office Supplies', 'expense'),
        ('supplies', 'Office Supplies', 'expense'),
        ('postage', 'Office Supplies', 'expense'),
        ('shipping', 'Office Supplies', 'expense'),
        ('bank fee', 'Bank Fees', 'expense'),
        ('interest', 'Bank Fees', 'expense'),
        ('service charge', 'Bank Fees', 'expense'),
        ('payment', 'Credit Card Payment', 'expense'),
        ('transfer', 'Transfer', 'expense'),
        ('salary', 'Payroll', 'expense'),
        ('payroll', 'Payroll', 'expense'),
        ('tax', 'Income Tax', 'expense'),
        ('consulting', 'Consulting Revenue', 'income'),
        ('retainer', 'Consulting Revenue', 'income'),
        ('freelance', 'Consulting Revenue', 'income'),
        ('rental', 'Rental Income', 'income'),
        ('room', 'Rental Income', 'income'),
        ('deposit', 'Rental Income', 'income'),
        ('dividend', 'Dividend Income', 'income'),
        ('interest', 'Interest Income', 'income'),
        ('refund', 'Refund', 'income'),
        ('hst', 'HST Collected', 'income'),
        ('gst', 'HST Collected', 'income'),
        ('tax refund', 'Tax Refund', 'income'),
    ]
    for keyword, category, txn_type in rules:
        if keyword in d:
            return category, txn_type
    return 'Uncategorized', None


def load_transactions(file_paths):
    """Load and normalize transactions from one or more CSV files."""
    transactions = []
    seen = set()

    for fp in file_paths:
        path = Path(fp)
        if not path.exists():
            print(f"WARNING: File not found: {fp}", file=sys.stderr)
            continue

        with open(path, 'r', encoding='utf-8-sig') as f:
            reader = csv.reader(f)
            headers = [h.strip().lower() for h in next(reader)]

        date_col = find_column(headers, DATE_FIELDS)
        amount_col = find_column(headers, AMOUNT_FIELDS)
        desc_col = find_column(headers, DESC_FIELDS)
        cat_col = find_column(headers, CAT_FIELDS)
        type_col = find_column(headers, TYPE_FIELDS)
        row_id_col = find_column(headers, {'row_id', 'id', 'uuid'})

        debit_col = None
        credit_col = None
        for i, h in enumerate(headers):
            if h in ('debit', 'withdrawal', 'debit_amount'):
                debit_col = i
            if h in ('credit', 'deposit', 'credit_amount'):
                credit_col = i

        if date_col is None:
            print(f"ERROR: Cannot find date column in {fp}. Headers: {headers}",
                  file=sys.stderr)
            continue

        with open(path, 'r', encoding='utf-8-sig') as f:
            reader = csv.DictReader(f)
            for row in reader:
                txn_date = parse_date(row[headers[date_col]])
                if txn_date is None:
                    continue

                if amount_col is not None:
                    amount = parse_amount(row[headers[amount_col]])
                    txn_type = None
                elif debit_col is not None or credit_col is not None:
                    txn_type, amount = infer_type_from_debit_credit(
                        [row.get(h, '') for h in headers],
                        debit_col, credit_col
                    )
                else:
                    continue

                if desc_col is not None:
                    desc = row[headers[desc_col]]
                elif date_col is not None:
                    desc = row[headers[date_col]]
                else:
                    desc = ''

                raw_row_id = row.get(headers[row_id_col]) if row_id_col is not None else None
                row_id = raw_row_id.strip() if raw_row_id and raw_row_id.strip() else None

                category = 'Uncategorized'
                inf_type = None
                if cat_col is not None and row[headers[cat_col]]:
                    category = row[headers[cat_col]]
                else:
                    cat_result = infer_category(desc)
                    if cat_result:
                        category, inf_type = cat_result

                if txn_type is None and type_col is not None:
                    raw = row[headers[type_col]].lower().strip()
                    if raw in ('income', 'credit', 'deposit', 'inflow', 'cr'):
                        txn_type = 'income'
                    elif raw in ('expense', 'debit', 'withdrawal', 'outflow', 'dr'):
                        txn_type = 'expense'
                if txn_type is None and inf_type:
                    txn_type = inf_type
                if txn_type is None:
                    txn_type = 'income' if amount > 0 else 'expense'

                if amount == 0:
                    continue

                dedup_key = (txn_date, desc.strip().lower(), round(amount, 2))
                if dedup_key in seen:
                    continue
                seen.add(dedup_key)

                transactions.append(Transaction(
                    txn_date=txn_date,
                    description=desc,
                    amount=amount,
                    category=category,
                    txn_type=txn_type,
                    row_id=row_id,
                ))

    transactions.sort(key=lambda t: t.date)
    return transactions


# ============================================================
# PATTERN DETECTION
# ============================================================

def detect_recurring(transactions):
    """Find recurring patterns in transaction history.

    Groups transactions by normalized description, then checks if
    amount and day-of-month are stable across ≥5 occurrences.
    """
    grouped = defaultdict(list)
    for t in transactions:
        norm = re.sub(r'[^a-zA-Z0-9\s]', '', t.description).strip().lower()
        norm = re.sub(r'\s+', ' ', norm)
        grouped[norm].append(t)

    patterns = []
    for norm_desc, txns in grouped.items():
        txns.sort(key=lambda t: t.date)
        if len(txns) < RECURRING_MIN_OCCURRENCES:
            continue

        amounts = [abs(t.amount) for t in txns]
        mean_amt = statistics.mean(amounts)
        if mean_amt == 0:
            continue

        amounts_pct = [abs(a - mean_amt) / mean_amt for a in amounts]
        if max(amounts_pct) > RECURRING_AMOUNT_TOLERANCE:
            continue

        days = [min(abs(t.date.day - d), abs(t.date.day - d + 30),
                    abs(t.date.day - d - 30)) for d in [txns[0].date.day]]
        target_day = txns[0].date.day
        all_close = all(
            min(abs(t.date.day - target_day),
                31 - abs(t.date.day - target_day)) <= RECURRING_DAY_TOLERANCE
            for t in txns
        )
        if not all_close:
            continue

        best_day = statistics.mode([t.date.day for t in txns])
        if len(txns) >= RECURRING_MIN_OCCURRENCES and len(set(
                (t.date.year, t.date.month) for t in txns)) >= min(3, len(txns)):
            best_desc = txns[0].description
            try:
                amt_std = statistics.stdev(amounts)
            except statistics.StatisticsError:
                amt_std = 0.0

            pattern_row_ids = list(dict.fromkeys(
                t.row_id for t in txns if t.row_id
            ))

            patterns.append(RecurringPattern(
                description=best_desc,
                amount=mean_amt * (1 if txns[0].amount > 0 else -1),
                day_of_month=best_day,
                category=txns[0].category,
                txn_type=txns[0].txn_type,
                occurrences=len(txns),
                amount_std=amt_std,
                row_ids=pattern_row_ids,
            ))

    return patterns


def build_spontaneous_models(transactions, recurring_patterns, months_of_data):
    """Build SpontaneousModel for each category of non-recurring transactions."""
    recurring_descs = set()
    for p in recurring_patterns:
        norm = re.sub(r'[^a-zA-Z0-9\s]', '', p.description).strip().lower()
        norm = re.sub(r'\s+', ' ', norm)
        recurring_descs.add(norm)

    spontaneous = {'income': defaultdict(list), 'expense': defaultdict(list)}
    for t in transactions:
        norm = re.sub(r'[^a-zA-Z0-9\s]', '', t.description).strip().lower()
        norm = re.sub(r'\s+', ' ', norm)
        if norm in recurring_descs:
            continue
        ttype = t.txn_type if t.txn_type in ('income', 'expense') else (
            'income' if t.amount >= 0 else 'expense')
        spontaneous[ttype][t.category].append(t)

    models = {'income': {}, 'expense': {}}
    for ttype in ('income', 'expense'):
        for cat, txns in spontaneous[ttype].items():
            if len(txns) >= 1:
                models[ttype][cat] = SpontaneousModel(
                    cat, ttype, txns, months_of_data)
    return models


# ============================================================
# SIMULATION
# ============================================================

def project_recurring(patterns, start_date, end_date):
    """Project all recurring patterns across the forecast period."""
    events = []
    for pattern in patterns:
        occ_dates = pattern.project(start_date, end_date)
        for d in occ_dates:
            events.append({
                'date': d,
                'description': pattern.description,
                'amount': pattern.amount,
                'category': pattern.category,
                'type': pattern.txn_type,
                'confidence': 'recurring',
                'rationale': (
                    f"Recurring — due ~{pattern.day_of_month}th "
                    f"({pattern.occurrences} of last {pattern.occurrences} months)"
                ),
                'row_ids': pattern.row_ids,
            })
    return events


def _daily_probability(model, month_idx, year, month):
    """Convert monthly expected count to per-day probability."""
    monthly = model.expected_count(month_idx)
    dim = calendar_month_days(year, month)
    return monthly / dim if dim > 0 else 0.0


def run_monte_carlo(models, start_balance, start_date, end_date, recurring_events):
    """Run Monte Carlo simulation — Poisson arrivals with lognormal amounts.

    Each day gets a probability = λ_month / days_in_month for spontaneous events.
    1000 independent runs; returns P10/P50/P90 balance per day.
    """
    days = (end_date - start_date).days + 1
    date_list = [start_date + timedelta(days=i) for i in range(days)]
    all_runs = []

    recurring_by_date = defaultdict(list)
    for ev in recurring_events:
        recurring_by_date[ev['date']].append(ev)

    categories = [(ttype, cat, model)
                  for ttype in ('income', 'expense')
                  for cat, model in models[ttype].items()]

    for _ in range(MONTE_CARLO_RUNS):
        balance = start_balance
        run_path = []
        for d in date_list:
            for ev in recurring_by_date.get(d, []):
                balance += ev['amount']

            for ttype, cat, model in categories:
                prob = _daily_probability(model, d.month - 1, d.year, d.month)
                if prob > 0 and random.random() < prob:
                    amt = model.sample_amount(d.month - 1)
                    if ttype == 'expense':
                        amt = -amt
                    balance += amt

            run_path.append(balance)

        all_runs.append(run_path)

    p10_path = []
    p50_path = []
    p90_path = []
    for day_idx in range(days):
        values = sorted(run[day_idx] for run in all_runs)
        idx10 = max(0, min(len(values) - 1, int(MONTE_CARLO_RUNS * 0.10)))
        idx50 = max(0, min(len(values) - 1, int(MONTE_CARLO_RUNS * 0.50)))
        idx90 = max(0, min(len(values) - 1, int(MONTE_CARLO_RUNS * 0.90)))
        p10_path.append(values[idx10])
        p50_path.append(values[idx50])
        p90_path.append(values[idx90])

    return {
        'p10': p10_path,
        'p50': p50_path,
        'p90': p90_path,
        'dates': date_list,
    }


def run_seasonal(models, start_balance, start_date, end_date, recurring_events):
    """Run seasonal model — deterministic monthly averages placed mid-month.

    Instead of smooth daily drift, this concentrates monthly spontaneous totals
    on the 15th of each month for a more realistic step-change pattern.
    """
    days = (end_date - start_date).days + 1
    date_list = [start_date + timedelta(days=i) for i in range(days)]

    recurring_by_date = defaultdict(list)
    for ev in recurring_events:
        recurring_by_date[ev['date']].append(ev)

    monthly_totals = {}
    cur = date(start_date.year, start_date.month, 1)
    while cur <= end_date:
        dim = calendar_month_days(cur.year, cur.month)
        mid_month = min(15, dim)
        month_key = (cur.year, cur.month)
        total = 0.0
        for ttype in ('income', 'expense'):
            for cat, model in models[ttype].items():
                expected = model.expected_count(cur.month - 1)
                if expected > 0:
                    avg_amt = model.mean_amount
                    if ttype == 'expense':
                        avg_amt = -avg_amt
                    total += avg_amt * expected
        monthly_totals[month_key] = (total, date(cur.year, cur.month, mid_month))
        cur = add_months(cur, 1)

    path = []
    balance = start_balance
    for d in date_list:
        for ev in recurring_by_date.get(d, []):
            balance += ev['amount']

        month_key = (d.year, d.month)
        if month_key in monthly_totals:
            total, drop_date = monthly_totals[month_key]
            if d == drop_date:
                balance += total

        path.append(balance)

    return {
        'p50': path,
        'dates': date_list,
    }


# ============================================================
# OUTPUT
# ============================================================

def _monthly_spontaneous_summary(models, year, month):
    """Return dict of expected monthly spontaneous totals by category."""
    items = []
    for ttype in ('income', 'expense'):
        for cat, model in models[ttype].items():
            expected = model.expected_count(month - 1)
            if expected > 0:
                total_amt = model.mean_amount * expected
                if ttype == 'expense':
                    total_amt = -total_amt
                items.append({
                    'description': f'Est. {cat} ({expected:.1f}/mo)',
                    'category': cat,
                    'type': ttype,
                    'amount': round(total_amt, 2),
                    'confidence': model.confidence(),
                    'rationale': (
                        f'{model.method.replace("_", " ").title()}: '
                        f'{expected:.1f}/mo × ${model.mean_amount:.0f} avg. '
                        f'({model.count} historical samples)'
                    ),
                })
    return items


def generate_forecast_csv(models, recurring_events, mc_results,
                           start_balance, start_date, end_date,
                           method, output_path, emit_row_ids=False):
    """Generate CSV using P50 path from simulation.

    First row: Balance Forward.
    Subsequent rows: recurring events (discrete), then monthly spontaneous
    summaries placed mid-month. Balance sourced from P50 path.

    When emit_row_ids is True, recurring event rows include a row_ids column
    with comma-separated UUIDs that rename-csv.py can restore via lookup.
    """
    recurring_by_date = defaultdict(list)
    for ev in recurring_events:
        recurring_by_date[ev['date']].append(ev)

    days = (end_date - start_date).days + 1
    date_list = [start_date + timedelta(days=i) for i in range(days)]
    balance_path = mc_results['p50']

    last_balance = start_balance
    written_dates = set()

    with open(output_path, 'w', newline='', encoding='utf-8') as f:
        writer = csv.writer(f)
        p10_path = mc_results.get('p10', balance_path)
        p90_path = mc_results.get('p90', balance_path)

        headers = [
            'date', 'description', 'category', 'type',
            'amount', 'adjustments', 'running_balance', 'p10_balance', 'p90_balance',
            'confidence', 'rationale',
        ]
        if emit_row_ids:
            headers.append('row_ids')
        writer.writerow(headers)

        # Row 1: Balance Forward (all three equal — known amount)
        writer.writerow([
            start_date.isoformat(),
            'Balance Forward', '', 'balance_forward',
            0.0, 0.0, f'{start_balance:.2f}', f'{start_balance:.2f}', f'{start_balance:.2f}',
            'high',
            f'Starting balance from {start_date.isoformat()} statement'
        ])
        written_dates.add(start_date)

        # Build monthly spontaneous buckets
        monthly_spontaneous = {}
        cur = date(start_date.year, start_date.month, 1)
        while cur <= end_date:
            key = (cur.year, cur.month)
            dim = calendar_month_days(cur.year, cur.month)
            mid = min(15, dim)
            mid_date = date(cur.year, cur.month, mid)
            monthly_spontaneous[key] = {
                'items': _monthly_spontaneous_summary(models, cur.year, cur.month),
                'display_date': mid_date,
            }
            cur = add_months(cur, 1)

        # Look up P50/P10/P90 balance at any date
        def balances_on(d):
            idx = (d - start_date).days
            if 0 <= idx < len(balance_path):
                return (balance_path[idx], p10_path[idx], p90_path[idx])
            return (balance_path[-1], p10_path[-1], p90_path[-1])

        # Collect all emission events sorted by date
        emission_events = []

        for d in date_list:
            for ev in recurring_by_date.get(d, []):
                emission_events.append((d, ev, 'recurring'))

        for key, bucket in monthly_spontaneous.items():
            display_date = bucket['display_date']
            if display_date < start_date:
                continue
            if bucket['items']:
                for item in bucket['items']:
                    emission_events.append((
                        display_date, item, 'spontaneous'
                    ))

        emission_events.sort(key=lambda x: (x[0], 0 if x[2] == 'recurring' else 1))
        seen_for_date = defaultdict(set)
        final_events = []
        for d, ev, etype in emission_events:
            dedup_key = (ev.get('description', ''), round(ev.get('amount', 0), 2))
            dedup_set = seen_for_date[d]
            if dedup_key in dedup_set:
                continue
            dedup_set.add(dedup_key)
            final_events.append((d, ev, etype))

        for d, ev, etype in final_events:
            bal, bal10, bal90 = balances_on(d)
            last_balance = bal
            row = [
                d.isoformat(),
                ev.get('description', 'Unknown'),
                ev.get('category', ''),
                ev.get('type', ''),
                f'{ev.get("amount", 0):.2f}',
                0.0,
                f'{bal:.2f}', f'{bal10:.2f}', f'{bal90:.2f}',
                ev.get('confidence', 'medium'),
                ev.get('rationale', ''),
            ]
            if emit_row_ids:
                row_ids = ev.get('row_ids', [])
                row.append(','.join(row_ids) if row_ids else '')
            writer.writerow(row)
            written_dates.add(d)

    return output_path


def write_summary(mc_results, method, start_balance, start_date, end_date, output_path):
    """Write a JSON summary alongside the CSV."""
    summary_path = output_path.replace('.csv', '-summary.json')
    peak = max(mc_results['p50'])
    trough = min(mc_results['p50'])
    end_bal = mc_results['p50'][-1]
    min_safe = min(
        mc_results['p10'][i]
        for i in range(len(mc_results['p50']))
    )

    p10_end = mc_results['p10'][-1] if 'p10' in mc_results else end_bal
    p90_end = mc_results['p90'][-1] if 'p90' in mc_results else end_bal

    summary = {
        'forecast': {
            'start_date': start_date.isoformat(),
            'end_date': end_date.isoformat(),
            'horizon_days': (end_date - start_date).days,
            'method': method,
            'start_balance': start_balance,
        },
        'p50': {
            'end_balance': round(end_bal, 2),
            'peak_balance': round(peak, 2),
            'trough_balance': round(trough, 2),
            'lowest_balance_date': mc_results['dates'][
                mc_results['p50'].index(trough)].isoformat(),
        },
        'safety': {
            'minimum_p90_balance': round(
                min(mc_results['p90']), 2) if 'p90' in mc_results else None,
            'minimum_p10_balance': round(min_safe, 2),
            'p10_end_balance': round(p10_end, 2),
            'p90_end_balance': round(p90_end, 2),
        },
        'model_quality': {
            'simulations': MONTE_CARLO_RUNS if method == 'monte_carlo' else 0,
            'method': method,
        }
    }

    if 'p10' in mc_results and 'p90' in mc_results:
        summary['confidence_interval'] = {
            'p10_end': round(p10_end, 2),
            'p50_end': round(end_bal, 2),
            'p90_end': round(p90_end, 2),
            'spread_80pct': round(p90_end - p10_end, 2),
        }

    with open(summary_path, 'w', encoding='utf-8') as f:
        json.dump(summary, f, indent=2)
    return summary_path


# ============================================================
# MAIN
# ============================================================

def load_known_events(path):
    """Load known future events from a JSON file and return as event dicts."""
    with open(path, 'r', encoding='utf-8') as f:
        raw = json.load(f)
    events = []
    for item in raw:
        if not isinstance(item, dict):
            continue
        ev_date = parse_date(item.get('date', ''))
        if ev_date is None:
            print(f"WARNING: known-events entry missing valid date: {item}",
                  file=sys.stderr)
            continue
        amount = parse_amount(item.get('amount', 0))
        events.append({
            'date': ev_date,
            'description': item.get('description', 'Known Event'),
            'amount': amount,
            'category': item.get('category', 'Known'),
            'type': 'income' if amount >= 0 else 'expense',
            'confidence': item.get('confidence', 'high'),
            'rationale': item.get('rationale', 'User-provided known event'),
        })
    return events


def cash_position_verdict(withdrawal, balance, mc_results, date_list):
    """Return safe/unsafe verdict for a proposed withdrawal."""
    p50_path = mc_results['p50']
    p10_path = mc_results.get('p10', p50_path)

    p50_after = [b - withdrawal for b in p50_path]
    p10_after = [b - withdrawal for b in p10_path]
    min_p10_after = min(p10_after)
    min_p50_after = min(p50_after)
    end_after = p50_after[-1]

    if min_p10_after >= 0:
        verdict = 'safe'
        level = 'conservative (stays above P10 floor)'
    elif min_p50_after >= 0:
        verdict = 'caution'
        level = 'aggressive (stays above zero on P50, but P10 goes negative)'
    else:
        verdict = 'unsafe'
        level = 'P50 itself goes negative'

    return {
        'verdict': verdict,
        'level': level,
        'withdrawal_amount': round(withdrawal, 2),
        'post_withdrawal': {
            'min_p10_balance': round(min_p10_after, 2),
            'min_p50_balance': round(min_p50_after, 2),
            'end_balance_p50': round(end_after, 2),
        }
    }


def build_parser():
    """Build argument parser (exposed for tests)."""
    parser = argparse.ArgumentParser(
        description='Income Forecast Engine — Monte Carlo with Seasonal Fallback')
    parser.add_argument('--csv', required=True,
                        help='Comma-separated list of historical CSV file paths')
    parser.add_argument('--balance', '-b', type=float, required=True,
                        help='Most recent bank statement balance (balance forward)')
    parser.add_argument('--statement-date', '-s', default=None,
                        help='Date of the most recent statement (YYYY-MM-DD). '
                             'Defaults to last transaction date in CSV.')
    parser.add_argument('--horizon', '-n', type=int, default=365,
                        help='Forecast horizon in days (default: 365)')
    parser.add_argument('--known-events', '-k', default=None,
                        help='JSON file of known future events (contracts, expenses)')
    parser.add_argument('--cash-position', '-c', type=float, default=None,
                        help='Withdrawal amount to check safety against forecast')
    parser.add_argument('--output', '-o', default='income-forecast.csv',
                        help='Output CSV path (default: income-forecast.csv)')
    parser.add_argument('--runs', type=int, default=MONTE_CARLO_RUNS,
                        help=f'Monte Carlo simulation runs (default: {MONTE_CARLO_RUNS})')
    parser.add_argument('--seed', type=int, default=None,
                        help='Random seed for reproducibility')
    parser.add_argument('--row-ids', action='store_true',
                        help='Emit row_ids column in output CSV for traceability '
                             'with hash-csv.py/rename-csv.py')
    return parser


def run(args):
    """Run the forecast given parsed args (exposed for tests)."""
    if args.seed is not None:
        random.seed(args.seed)

    csv_files = [f.strip() for f in args.csv.split(',')]

    print(f"Loading {len(csv_files)} CSV files...", file=sys.stderr)
    transactions = load_transactions(csv_files)
    print(f"Loaded {len(transactions)} transactions.", file=sys.stderr)

    if not transactions:
        print("ERROR: No transactions loaded.", file=sys.stderr)
        sys.exit(1)

    data_span = (transactions[-1].date - transactions[0].date).days
    months_of_data = data_span / 30.44
    print(f"Data span: {data_span} days ({months_of_data:.1f} months)", file=sys.stderr)

    print("Detecting recurring patterns...", file=sys.stderr)
    patterns = detect_recurring(transactions)
    print(f"Found {len(patterns)} recurring patterns.", file=sys.stderr)
    for p in patterns:
        sign = '+' if p.amount > 0 else ''
        print(f"  {sign}${p.amount:.2f} on ~{p.day_of_month}th — "
              f"{p.description} ({p.occurrences}x)", file=sys.stderr)

    print("Building spontaneous models...", file=sys.stderr)
    models = build_spontaneous_models(transactions, patterns, months_of_data)
    total_spontaneous = sum(len(m.transactions) for t in ('income', 'expense')
                            for m in models[t].values())
    print(f"Spontaneous: {total_spontaneous} txns across "
          f"{sum(len(models[t]) for t in ('income', 'expense'))} categories",
          file=sys.stderr)

    income_methods = set(m.method for m in models['income'].values())
    expense_methods = set(m.method for m in models['expense'].values())
    all_methods = income_methods | expense_methods

    if 'monte_carlo' in all_methods:
        method = 'monte_carlo'
    elif 'seasonal' in all_methods:
        method = 'seasonal'
    else:
        method = 'simple_average'
    print(f"Forecast method: {method}", file=sys.stderr)

    if args.statement_date:
        start_date = datetime.strptime(args.statement_date, '%Y-%m-%d').date()
    else:
        start_date = transactions[-1].date
    end_date = start_date + timedelta(days=args.horizon)
    print(f"Forecast period: {start_date} to {end_date} "
          f"({args.horizon} days)", file=sys.stderr)

    print("Projecting recurring events...", file=sys.stderr)
    recurring_events = project_recurring(patterns, start_date, end_date)

    if args.known_events:
        known_path = Path(args.known_events)
        if known_path.exists():
            known = load_known_events(args.known_events)
            recurring_events.extend(known)
            print(f"  + {len(known)} known events from {args.known_events}",
                  file=sys.stderr)
        else:
            print(f"WARNING: known-events file not found: {args.known_events}",
                  file=sys.stderr)
    print(f"  {len(recurring_events)} total projected events", file=sys.stderr)

    if method == 'monte_carlo':
        print(f"Running Monte Carlo ({args.runs} simulations)...", file=sys.stderr)
        mc_results = run_monte_carlo(
            models, args.balance, start_date, end_date, recurring_events)
    else:
        print("Running seasonal model...", file=sys.stderr)
        mc_results = run_seasonal(
            models, args.balance, start_date, end_date, recurring_events)
        mc_results['p10'] = mc_results['p50']
        mc_results['p90'] = mc_results['p50']

    print("Generating output CSV...", file=sys.stderr)
    generate_forecast_csv(
        models, recurring_events, mc_results,
        args.balance, start_date, end_date, method,
        args.output, emit_row_ids=args.row_ids)

    summary_path = write_summary(
        mc_results, method, args.balance, start_date, end_date, args.output)

    print(f"\nOutput: {args.output}", file=sys.stderr)
    print(f"Summary: {summary_path}", file=sys.stderr)
    print(f"Forecast end balance (P50): ${mc_results['p50'][-1]:.2f}", file=sys.stderr)

    if 'p10' in mc_results and 'p90' in mc_results:
        print(f"  80% confidence range: ${mc_results['p10'][-1]:.2f} "
              f"– ${mc_results['p90'][-1]:.2f}", file=sys.stderr)

    min_bal = min(mc_results['p50'])
    min_date = mc_results['dates'][mc_results['p50'].index(min_bal)]
    print(f"  Lowest P50 balance: ${min_bal:.2f} on {min_date}", file=sys.stderr)

    if args.cash_position is not None:
        verdict = cash_position_verdict(
            args.cash_position, args.balance, mc_results, mc_results['dates'])
        print(f"\nCash Position [--cash-position ${args.cash_position:.2f}]:",
              file=sys.stderr)
        print(f"  Verdict: {verdict['verdict'].upper()} — {verdict['level']}",
              file=sys.stderr)
        print(f"  Min P50 after withdrawal: ${verdict['post_withdrawal']['min_p50_balance']:.2f}",
              file=sys.stderr)
        print(f"  Min P10 after withdrawal: ${verdict['post_withdrawal']['min_p10_balance']:.2f}",
              file=sys.stderr)
        verdict_path = args.output.replace('.csv', '-cash-position.json')
        with open(verdict_path, 'w', encoding='utf-8') as f:
            json.dump(verdict, f, indent=2)
        print(f"  Cash position JSON: {verdict_path}", file=sys.stderr)

    print("Done.", file=sys.stderr)


def main():
    parser = build_parser()
    args = parser.parse_args()
    run(args)


if __name__ == '__main__':
    main()
