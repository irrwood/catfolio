# Market symbol repairs (2026-10-19)

Portfolio identifiers and quote-provider identifiers are different. `LocalMarketDataClient.yahooSymbol` selects a quote source; only `TickerRenames` changes stored position and transaction identifiers. Alternate venues below are restricted to EUR so the caller never consumes a euro quote as dollars or pounds.

| Broker symbol | Quote symbol | Security / identity |
| --- | --- | --- |
| ANAE | ANA.MC | Acciona, ES0125220311; raw Trading 212 identifier ANAe_EQ |
| IBEE | IBE.MC | Iberdrola, ES0144580Y14; raw Trading 212 identifier IBEe_EQ |
| DHER | DHER.DE | Delivery Hero, DE000A2E4K43; legacy broker export confirms EUR |
| ENL1 / ENL1.DE | ENL.DE | Enel; matches the existing Python importer override |
| MIH.DE | MIH.F | Mitsubishi Heavy Industries, JP3900000005 |
| FOT.DE | FOT.F | Fortum, FI0009007132 |
| SDV1.DE | SDV1.F | Saab B, SE0021921269 |

For the first two, the source is the same security's Madrid listing. For the last three, Frankfurt provides usable history where Yahoo's Xetra symbol is empty or has only one daily close. These are alternate venue prices, not a reconstruction of the broker's execution venue.

Identity sources: [broker instrument list with both Spanish ISINs and Cboe symbols](https://www.aliorbank.pl/dam/jcr:49d11fd3-8f24-4895-98ac-9516466b4596/lista-instrumentow-RZ.pdf), [Cboe's IBEe identity](https://cdn.cboe.com/resources/participant_resources/TD-Email-Spanish-Promo.pdf), [Iberdrola's Madrid listing](https://www.iberdrola.com/shareholders-investors/share/price), [Fortum Frankfurt listing](https://live.deutsche-boerse.com/equity/fortum), [Saab Frankfurt announcement](https://www.cashmarket.deutsche-boerse.com/cash-en/Stay-Informed/newsroom/Xetra-Frankfurt-Newsboard/XFRA-DIVIDEND-INTEREST-INFORMATION-02.04.2026-SE0021921269-5057410), [Mitsubishi Heavy Frankfurt announcement](https://www.xetra.com/xetra-en/newsroom/xetra-newsboard/XFRA-DIVIDEND-INTEREST-INFORMATION-28.03.2025-JP3900000005-4348448).

## Legacy currency inference

Trading 212's older payloads can omit the instrument currency. ANAe_EQ and IBEe_EQ must fall back to EUR, not the account's GBP or the generic USD default. DHER_EQ also falls back to EUR. Explicit API currency values take precedence.

Existing `LocalPortfolioStore` migration already corrects Trading 212 BUY/SELL price currencies, using current holdings where present and `InstrumentCurrencyRules.inferredPriceCurrency` otherwise. The suffixless ANAE, IBEE and DHER entries now infer EUR. This corrects old DHER records after the position has been sold. Other brokers, dividend cash currencies, broker results, FX rates, quantities, prices and settlement postings are preserved. Tests exercise a saved document through `load`, including idempotence.

## Former symbols after corporate actions

`BRLI → NUKK → DFNS` is flattened to the final symbol for market-data and catalog lookup; rights, warrants and units are excluded. Yahoo's DFNS history begins 2020-07-22 and reports the 2023 distribution, 2024 reverse split and 2026 reverse split. The account ledger already processes provider split events and reconstructs contemporaneous prices. The affected local trades are dated 2026-07-30, after those events.

`PMO.L → HBR.L` follows the retained issuer after the Premier Oil/Chrysaor merger. Yahoo's HBR.L coverage starts 2021-04-01 and includes the June 2021 1:20 consolidation. It covers the affected 2025 trades. It does **not** restore Premier Oil prices before April 2021.

Sources: [Brilliant/Nukkleus closing](https://www.sec.gov/Archives/edgar/data/1592782/000121390023099910/ea190904ex99-1_nukkleus.htm), [T3 Defense filing](https://www.sec.gov/Archives/edgar/data/1787518/000121390026097287/ea0304078-s1_t3defense.htm), [Harbour 2021 annual report](https://www.harbourenergy.com/media/3avj2cjr/hrb-ar21-web.pdf).

## CyberArk historical archive

`CYBR` is not a rename of `PANW`. Its [acquisition consideration](https://www.paloaltonetworks.com/company/press/2026/palo-alto-networks-completes-acquisition-of-cyberark-to-secure-the-ai-era) includes both shares and cash. Keep its identity and trading history separate.

`Resources/cybr_delisted_daily_history.json` contains 2,541 historical daily bars from 2016-01-04 through the final trading day 2026-02-10, retrieved 2026-10-19 from Alpaca SIP. The query used `start=2014-09-01`, `end=2026-02-11`, `asof=2026-02-10`, `timeframe=1Day`, `limit=10000`; returned coverage starts in 2016. Prices use the API's default raw/USD basis. A corporate-actions query through 2026-02-10 returned no split, dividend or spin-off announcements for CYBR. The archive is valid for the raw and adjusted close paths on that verified basis; other securities with corporate actions need their own adjustment handling. [Alpaca API basis and as-of documentation](https://docs.alpaca.markets/us/reference/stockbars).

`DelistedPriceArchive` validates the security, currency, basis, date ordering, count and OHLC values before use. Daily charts, account-ledger history and historical volume data can read it offline. Date filtering returns no values after delisting; intraday requests return no bars. The archive never creates a current quote, extends the last close to today, or appends PANW prices. Broker settlement records after delisting are preserved and are not rewritten into inferred merger transactions.

This repairs price availability. It is not an audit of the portfolio's corporate-action cash or share accounting. Regression coverage lives in `MarketDataListingAliasesTests`, `TickerRenamesTests` and `DelistedPriceArchiveTests`.
