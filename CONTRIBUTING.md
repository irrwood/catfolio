# Contributing

Thanks for considering a contribution to Catfolio.

## Local Setup

```bash
cd v3_backend
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
CATFOLIO_DEMO=1 uvicorn app.main:app --port 8787 --reload
```

Open `http://localhost:8787`.

## Before Opening a PR

```bash
python -m compileall -q v3_backend scripts
python -m pytest v3_backend/tests
python scripts/check_open_source_ready.py
```

Do not commit personal portfolio exports, generated reports, screenshots from real accounts,
API keys, keychain dumps, or anything from `outputs/`.

## Development Notes

- Keep demo mode deterministic and free of real account data.
- Prefer adding tests for route behavior and data-loading changes.
- Keep user-facing text available to the i18n catalog when practical.
