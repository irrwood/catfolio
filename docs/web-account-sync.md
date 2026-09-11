# Web account sync

Settings → Accounts follows the iOS account workflow: create a connection, preview holdings, confirm, then manage that account. Supported connections are Trading 212 (read-only API key/secret), Moomoo OpenD, IBKR Client Portal Gateway, and full-history CSV files. This does not introduce iOS OAuth or Flex transports on the web.

- Each broker connection must resolve to one stable broker account ID. Connecting the same broker account twice is rejected at confirmation.
- Credentials are stored as a per-account entry in the server device's OS credential store. They are never returned by the API or written to the account JSON file.
- Saving a connection creates an account awaiting its first sync. A read-only preview does not modify holdings. Confirmation applies the exact preview, without a second network fetch.
- Previews expire after 15 minutes and are invalidated by edits or a previous confirmation. Failed or partial fetches leave existing holdings unchanged. Verified empty snapshots require confirmation before clearing that account.
- Names, portfolio inclusion, and deletion are independent account operations. Unchecked accounts remain stored. A deleted account's linked legacy holdings do not reappear.
- Link a new connection to its existing holdings when migrating a legacy account; otherwise it is treated as an additional account. Legacy source files remain intact. Account overlays and selection are applied by `current_snapshot()` and used by quote/fundamental refreshes.
- CSV imports use the existing parser and weighted-average-cost calculation. Each import replaces that account's full CSV history, so reimporting the same file does not append duplicates. Unknown market prices require quote refresh. Broker sync currently supplies positions/cash, not a complete transaction ledger.
- Public and local demo modes reject account writes and live previews.

State is stored in `CATFOLIO_DATA_DIR/portfolio_analysis_v2/accounts.json`. The existing single-process FastAPI deployment is supported; preview tokens are in process memory and disappear on restart. Multi-worker deployment requires a shared preview store and cross-process write coordination before use.

Verification uses synthetic data and mocked brokers/keychain; no real broker credentials are required by the tests. Real connection success still depends on the supplied credentials and local gateways.
