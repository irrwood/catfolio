# Web account sync

Settings → Accounts follows the iOS account workflow: create a connection, preview holdings, confirm, then manage that account. Supported connections are Trading 212 (read-only API key/secret), Moomoo OpenD, IBKR Client Portal Gateway, Longbridge OpenAPI (see [Longbridge](#longbridge)), and full-history CSV files. This does not introduce iOS OAuth or Flex transports on the web.

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

## Longbridge

Longbridge connections use the official `longbridge` Python SDK with API key authentication. The SDK is optional: install it in `v3_backend/` with `pip install -r requirements-longbridge.txt`. It is imported only when a Longbridge account is previewed, so the demo and other brokers do not need it; without it, a Longbridge preview shows that install command.

- **Credentials**: create an app on the [Longbridge OpenAPI portal](https://open.longbridge.com/), then paste its App Key, App Secret and Access Token into Settings → Accounts → Add account → Longbridge. They are stored like other connections, as one entry in the OS credential store. Access tokens expire; when a preview reports an expired token, generate a new one and save it on the same account.
- **Read-only calls**: Catfolio calls only `TradeContext.stock_positions()`, `TradeContext.account_balance()`, `QuoteContext.member_id()` and `QuoteContext.quote()`, and never an order method. Longbridge credentials can also place orders, so keep them private.
- **Account identity**: positions and balances carry no account number, so Catfolio uses the member ID returned by the quote connection. The same Longbridge login therefore cannot be connected twice. The optional Account ID field is used only when no member ID is returned.
- **Symbols**: `AAPL.US` → `AAPL`; `700.HK` → `0700.HK`, because Yahoo only resolves four-digit Hong Kong codes; `600519.SH` → `600519.SS`; `000001.SZ` is unchanged; `D05.SG` → `D05.SI`. The original Longbridge symbol is kept as `api_ticker`.
- **Prices and P/L**: positions include quantity, average cost and currency but no price. The preview uses the latest Longbridge quote, or the previous close before a security's first trade of the day. Unrealized P/L is quantity × (price − average cost) in the position's currency. If any position has no quote, the preview is reported as incomplete and existing holdings are kept.
- **Cash**: `account_balance()` returns one entry in the account's base currency, with per-currency detail in `cash_infos`. Catfolio stores its `total_cash` and `net_assets`. If Longbridge returns one entry per currency, Catfolio asks for a single consolidated currency instead of adding them up.
- **Errors**: an invalid or expired token, a permission or IP restriction, and an unreachable network each have their own message; other failures show a generic one. SDK error text can include request URLs and trace IDs and is never shown.
- **Why it is optional**: the SDK is published as compiled wheels only, and its Linux wheels need glibc 2.39 or newer (musl wheels are also published). Keeping it out of `requirements.txt` means installs on older systems, such as Debian bookworm or Ubuntu 22.04, are unaffected. The Docker image installs only `requirements.txt`, so it does not include the SDK; add `requirements-longbridge.txt` in a derived image to use Longbridge there.
