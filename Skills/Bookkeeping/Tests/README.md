# Bookkeeper Tests

## Running Tests

### Unit tests (no external dependencies)
```powershell
Invoke-Pester -Path Skills/Docker/Tests/bookkeeping/ -Tag "Bookkeeper","Unit"
```

### Integration tests (require scripts to be present)
```powershell
Invoke-Pester -Path Skills/Docker/Tests/bookkeeping/ -Tag "Bookkeeper","Integration"
```

### Full Bookkeeper suite
```powershell
Invoke-Pester -Path Skills/Docker/Tests/bookkeeping/ -Tag "Bookkeeper"
```

## Fixture Data

Test data is generated dynamically in `BeforeAll` blocks and cleaned up in `AfterAll`:

| Fixture | Location | Format |
|---------|----------|--------|
| Sample CSVs | `$env:TEMP/AcctTests-*/fixtures/` | Date,Description,Amount,Account |
| Sample TAS | `$env:TEMP/AcctTests-*/fixtures/` | date,description,amount,account,category,... |
| Rent register | `$env:TEMP/AcctTests-*/fixtures/` | Room,Date,Amount,Note,Status |

## Adding New Tests

1. Choose the right file:
   - `Bookkeeper.Scripts.Tests.ps1` — per-script syntax and logic tests
   - `Bookkeeper.Pipeline.Tests.ps1` — multi-step pipeline flows
   - `Bookkeeper.PrpPipeline.Tests.ps1` — PRP org-pipeline and atomic TAS-write regression tests (currentsbk reconciliation scripts)

2. Tag appropriately:
   - `-Tag "Bookkeeper","Unit"` — for mocked / syntax-only tests
   - `-Tag "Bookkeeper","Integration"` — for tests requiring real scripts

3. Use `$env:TEMP` fixture directories with `BeforeAll`/`AfterAll` cleanup.

4. For scripts requiring live APIs (Zoho, AWS SM), skip with `Set-ItResult -Skipped` and document the external dependency.
