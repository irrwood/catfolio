# Longbridge and Alpaca accounts

Add Account → Longbridge / Alpaca connects directly from iPhone. Existing accounts expose the same connector under their sync action. The preview must be confirmed before positions are replaced. Credentials are stored in account-specific local Keychain records; they are not included in the iCloud credential allowlist.

## Scope

- Long stocks and ETFs only. No orders are submitted. Cash, mutual funds and transaction history are not imported.
- Missing cost, missing quotes, unsupported assets (including shorts, options and warrants), malformed numbers, authorization errors and incomplete HTTP responses reject the entire preview. Existing data stays intact.
- A verified empty response clears only that account's holdings after confirmation. Existing transaction history and other accounts are retained.
- Previews expire after 15 minutes and are discarded when credentials or Alpaca environment changes. An account returned by the API must match the account being managed.

## Longbridge

Use legacy App Key + App Secret + Access Token from the developer center. The existing quote credential can prefill creation; saving an account credential does not replace global market-data settings.

- Authenticated quote command 4 supplies a stable member ID, independent of credential rotation.
- Signed GET `/v1/asset/account?currency=USD` establishes the reporting currency. GET `/v1/asset/stock` supplies all stock channels. Quantity is total quantity, not available quantity.
- Stock channels for the same member are combined. Repeated securities across different channels use total shares and weighted average cost; duplicates within one channel are rejected.
- Quote commands 10 and 11 verify the security board, currency and latest price in batches of 100. US, HK and Shanghai/Shenzhen listings map to Catfolio symbols. Unknown boards fail closed.
- This requires Longbridge quote and account API permissions; API Key tokens are separate from OAuth tokens.

## Alpaca

Select Live or Paper and use that environment's API key and secret. Requests go only to `api.alpaca.markets` or `paper-api.alpaca.markets`; no automatic environment fallback occurs.

- GET `/v2/account` supplies the account UUID and USD denomination.
- GET `/v2/positions` supplies positions, average cost and current price, including fractional shares.
- Identity includes the environment, so live and paper never overwrite each other. Keys may be rotated without changing the account UUID.
- The positions endpoint has no exchange quote timestamp; the app displays the fetch time in the preview without inventing a trade timestamp.

## References

- https://open.longbridge.com/docs/getting-started
- https://open.longbridge.com/docs/trade/asset/stock
- https://open.longbridge.com/docs/trade/asset/account
- https://github.com/longbridge/openapi-protobufs/blob/main/quote/api.proto
- https://docs.alpaca.markets/docs/trading-api
- https://docs.alpaca.markets/docs/working-with-positions

The opt-in `DirectBrokerLiveTests` uses credentials already saved on the device, reads only, and does not log credential values or holdings. Set `CATFOLIO_TEST_BROKER_ACCOUNTS_LIVE=1` for that acceptance test.
