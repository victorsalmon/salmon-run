# Python Testing

## Quick start
```powershell
python -m pytest                                # all unit tests (fast)
python -m pytest -v                             # verbose
python -m pytest --cov                          # with coverage
python -m pytest -m integration                 # integration tests only
python -m pytest <path> -k <keyword>            # filtered
```

## Dependency install
```powershell
pip install -r requirements.txt
```

## Test tiers
| Tier | Description | Mark | Default | Files |
|------|-------------|------|---------|-------|
| 1 | Pure logic | (none) | Runs | `test_statement_conversion.py`, `test_dedup.py`, `test_matching.py`, `test_parse_filename.py`, `test_tas_loading.py` |
| 2 | File I/O (tmp_path) | (none) | Runs | `test_reconciliation.py` |
| 3 | Integration (Docker/AWS) | `integration` | Skipped | (future) |

## Adding tests
1. Place `test_*.py` in the nearest `tests/` directory
2. Add `__init__.py` if the directory doesn't have one
3. If the test needs Docker/AWS, mark it `@pytest.mark.integration`
4. Update `testpaths` in `pyproject.toml` if the test dir is new

## Test structure
- Tests use `pytest` style (functions with assertions, not `unittest.TestCase`)
- Shared fixtures in `conftest.py`
- File I/O tests use `tmp_path` fixtures
- Integration tests require `@pytest.mark.integration` and are skipped by default
