# Investor disclosure supplements

The iOS catalog combines the persisted Core export with these dated, archived
public-source supplements. coreSHA256 and coreReleaseId retain the original
Core lineage; releaseId hashes the supplemented catalog and invalidates the
app's disclosure cache.

Run python3 scripts/export_ios_public_investors.py with the Core volume mounted.
When it is unavailable, pass
--base-catalog CatfolioIOS/CatfolioIOS/Resources/public_investors.json.
Both routes apply updates/*.json, verify archived source checksums, and merge
by activity ID. Repeating an export does not duplicate the records.

The 2026-10-20 update includes House PTR 20035553 (filed October 2; transaction
September 8) and 12 ARK fund trade notifications dated October 19. ARK's live XLS
URL changes, so its exact bytes are archived in sources/. TRADE_FILE_DATE
identifies the date on that file, not an SEC filing date. Notifications are
unreconciled and incomplete. They appear in the activity feed and do not replace
quarterly snapshots or enter the reconstructed ARK portfolio ledger.

The Pelosi transaction is a spouse's private LLC investment, with only the
reported USD 500,001–1,000,000 range retained. No listed ticker, quantity or exact
amount is inferred. The other investors' quarterly snapshots are unchanged.
