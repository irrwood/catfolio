# Catfolio Open-Source Release Checklist

Use this before publishing the repository or sharing a source archive.

## Required Files

- `README.md`: product overview, setup, privacy model, feature list.
- `LICENSE`: MIT license.
- `.env.example`: empty environment variable template.
- `.gitignore`: excludes local data, secrets, virtualenvs, and build output.
- `.dockerignore`: prevents local data and secrets from entering Docker build context.
- `SECURITY.md`: vulnerability and data-handling policy.
- `CONTRIBUTING.md`: setup and contribution checks.

## Private Data Rules

Never publish:

- `outputs/`
- `build/`
- `dist/`
- `.env`
- broker CSV exports
- generated HTML/XLSX reports
- local SQLite strategy databases
- screenshots from real accounts
- `.DS_Store`, caches, virtualenvs, or local tool settings

## Demo Mode

Run public demos with:

```bash
CATFOLIO_DEMO=1 uvicorn app.main:app --port 8787
```

The app should show the static sample portfolio from `v3_backend/app/demo_data.py`.
The audit report page must not read `outputs/portfolio_analysis_v2/portfolio_cost_basis_v2.html`
when demo mode is active.

## Pre-Publish Checks

```bash
python -m compileall -q v3_backend scripts
python -m pytest v3_backend/tests
python scripts/check_open_source_ready.py
git status --short
```

Review `git status` manually. Untracked files are not safe just because Git ignores them;
they are safe only if they are intentionally excluded from the source archive.
