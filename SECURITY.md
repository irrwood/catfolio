# Security Policy

Catfolio is a local-first portfolio tool. Treat broker exports, generated reports,
SQLite files, screenshots, and anything under `outputs/` as private user data.

## Supported Versions

Security fixes are handled on the main branch until formal releases exist.

## Reporting a Vulnerability

Please open a private security advisory on GitHub, or contact the maintainer
privately before publishing details. Include reproduction steps, affected files,
and whether any user data or credentials could be exposed.

## Data Handling

- API keys should live in `.env`, environment variables, or the system keychain.
- `.env`, `outputs/`, `build/`, and `dist/` are intentionally excluded from source releases.
- Demo mode (`CATFOLIO_DEMO=1`) uses only static sample data bundled in the app.
- The audit report route does not read generated local report HTML while demo mode is active.
