# Catfolio iCloud sync

Implementation and release notes, 2026-10-16. The production schema is deployed, and signed Production builds run on Mac and iPhone. Basic live acceptance completed: portfolio restore, reverse name-change propagation, and restoration of the original names. Business data converged, and credential configuration fingerprints match across devices. The full fault-injection and offline hardware matrix was not run.

## User controls and data boundaries

Both new switches default to off and are enabled separately on each device. Their values and Apple-account ownership markers stay local.

| Switch | Local preference | Data path |
| --- | --- | --- |
| Sync API keys | `catfolio.iCloudCredentialsEnabled` | Synchronizable iCloud Keychain records, with device-local working copies |
| Sync accounts and holdings | `catfolio.iCloudPortfolioEnabled` | Locally encrypted portfolio → private CloudKit database; independent vault keys in iCloud Keychain |

Existing display-preference sync remains independent. Enabling portfolio sync does not enable API-key sync. Portfolio encryption necessarily uses its own synchronizable Keychain key even when API-key sync is off.

`CloudCredentialPolicy` permits FMP, Massive, DeepSeek, OpenRouter, Finnhub, Cloudflare Workers AI, complete Trading 212 key/secret pairs, and account-bound IBKR Flex token/query pairs. It includes Cloudflare account ID and selected DeepSeek/OpenRouter models so restored credentials retain their required configuration. ChatGPT OAuth tokens, refresh tokens, device-login sessions, setup drafts, pending IBKR credentials, and unbound legacy credentials are excluded. Initial broker uploads require a completed local account; a Trading 212 preview alone is insufficient. Existing cloud-restored broker credentials remain available when holdings sync is off.

Turning either switch off retains the current local copy and existing cloud data. It stops subsequent app synchronization for that feature; it does not erase other devices or retract a request already submitted to Apple. Previously submitted Keychain items remain under system synchronization. App consumers continue reading the local working copy while API-key sync is off. There is no “delete cloud vault” or account-rebinding action in this release.

## Encryption, ownership, and merge

`CloudPortfolioCrypto` encodes the document and seals it with AES-256-GCM before any `CKAsset` is created. The uploaded envelope contains only format version, immutable key UUID, and authenticated ciphertext. Authentication includes the Apple-account identity hash and key UUID. The 256-bit vault key travels through a separate synchronizable Keychain namespace; it is never stored in the CloudKit record and does not reuse an API key.

CloudKit and Keychain can arrive in either order. If the encrypted document arrives first, show “waiting for the decryption key,” retain both copies, and retry after Keychain delivery. **Never create a replacement key for an existing envelope, reset the vault, or overwrite the remote document to clear this state.** If the original key is permanently unavailable, that ciphertext cannot be recovered; retain any usable local portfolio and broker/CSV originals. Tampered, unsupported, synthetic, and public-disclosure documents are rejected.

Both managers bind the local working copy to a hash of the CloudKit user-record identity. Switching Apple accounts invalidates current operations and blocks sync with the old working copy, including explicit re-enabling. Return to the original Apple account to resume. Ownership survives turning sync off; API-key ownership is also recorded in device-local Keychain so reinstalling cannot upload retained keys to a different Apple account. Account-scoped credential namespaces, account-scoped portfolio record names, and authenticated encryption prevent another account's data from being accepted or overwriting its existing vault.

Portfolio merge uses per-account holdings snapshots, individual transactions, change clocks, and deletion/reset markers. It runs against the latest local file inside `LocalPortfolioStore`, with a local recovery backup before a material merge. CloudKit saves use `ifServerRecordUnchanged`; concurrent writers refetch and merge, with bounded retries. Immutable encryption-key UUIDs avoid replacing a first writer's key when two devices initialize concurrently. A failed first upload retains a nonsecret, account-scoped pending key UUID in local defaults and reuses that key after retry or relaunch. A readable remote winner supersedes the pending reference; a missing winner key still waits instead of falling back. Oversized documents are rejected before generating a key and receive a distinct size-limit status.

Trading 212 slot names such as `account-1` are device-local identifiers. Durable connection bindings prevent independently configured, incompatible slots from being merged as one broker account. The optional Trading 212 credential payload carries this stable binding across key rotations. Its local marker includes the current pair hash; a stale marker is ignored if the pair changes, while a fresh device can restore rotated keys with the original portfolio identity. Conflicting initial credentials are retained locally without overwriting the remote connection. Resolve the account/connection mismatch before retrying; do not clear a portfolio merely to silence the conflict.

After portfolio-sync opt-in, plaintext portfolio files and their local recovery backups are excluded from future system device backups. They remain local files protected by the app's file-protection settings. This does not remove copies already present in older device backups and does not turn local files into the CloudKit ciphertext format.

## Refresh and implementation entry points

`CatfolioIOSApp` starts both managers and refreshes enabled features on foreground activation, then every 60 seconds while active. Credential edits are debounced by 500 ms; portfolio commits by 2 seconds. The settings page can retry immediately. Backgrounding ends foreground polling; this release does not depend on CloudKit push subscriptions. A successful Keychain write confirms local submission, not delivery to every other device.

Core sources: `CloudCredentialSync.swift`, `KeychainStore.swift`, `CloudSyncAccount.swift`, `CloudPortfolioCrypto.swift`, `CloudPortfolioTransport.swift`, `CloudPortfolioSync.swift`, `PortfolioDocumentMerge.swift`, and `LocalPortfolioStore.swift`. UI entry: `CloudDataSettingsSection.swift` in app settings.

## CloudKit release configuration

See [管理凭据、生产部署与双设备验收](icloud-production-deployment.md) for the operator workflow and current deployment status.

The production schema was deployed through CloudKit Console on 2026-10-16 for team `2G5PCQU652`. Current configuration:

- Container: `iCloud.com.catfolio.ios`; database: private.
- Record type: `CatfolioEncryptedPortfolio`.
- Field: `encryptedPayload`, type **Asset**. Do not add plaintext financial fields or a key field.
- Record name: `portfolio.v1.<SHA256 of CloudKit user-record name>`, generated dynamically for the active account.
- Both Debug and Release use `CatfolioIOS/CatfolioIOS.entitlements`, which requests the container, `CloudKit`, and the existing ubiquity key-value-store identifier. The app target enables the iCloud capability and uses bundle ID `com.catfolio.ios`.

Deployment added `CatfolioEncryptedPortfolio.encryptedPayload ASSET`, with no public-database `GRANT` on the new record type; the existing `Users` type was unchanged. The [development backup](../CloudKit/development-before-2026-10-16.ckdb), [production backup](../CloudKit/production-before-2026-10-16.ckdb), [final production schema](../CloudKit/production.ckdb), and [Console deployment confirmation](../CloudKit/production-deployed-2026-10-16.jpg) are retained. Deployment copies the schema, not development records. No query index is required for the direct record-ID fetch used here.

The iPhone and Mac Catalyst test builds have signed access to the Production environment and the same container, App ID, and default Keychain access group. The Mac provisioning profile includes the Mac used for testing. TestFlight also uses production. Before TestFlight, finish the live two-device acceptance below; a successful schema deployment and a single-device sync do not prove delivery to the other device. Do not copy production user data or secrets into test fixtures or logs.

## Manual two-device acceptance matrix

Use two authorized devices with the same test Apple account, iCloud and iCloud Keychain enabled, and non-production/read-only broker credentials where possible. Record OS/build, environment, result, and any delivery delay. These cases are release acceptance work, not claims of completed hardware testing.

| Case | Expected result |
| --- | --- |
| Fresh install on both devices | Both new switches off; no credential or portfolio transfer until that feature is enabled on each device. |
| Keys only | Allowed service/broker keys and binding configuration become usable on the other device; holdings switch remains off; OAuth/device login still requires authorization. |
| Portfolio only | Accounts, positions, and history restore; API keys remain local; independent vault key enables decryption. |
| Both switches | Empty second device restores holdings and reuses corresponding static credentials without typing them again. |
| Key arrives late or Keychain unavailable | Portfolio remains intact; waiting/error state; later retry succeeds without replacing keys or clearing records. |
| Offline edits on both devices | Different accounts/trades survive reconnection; repeated refresh converges without duplicates. |
| Delete trade/account or reset, then reconnect stale device | Deletion/reset markers prevent stale records from returning. |
| Independent Trading 212 accounts occupy the same slot | Conflict blocks unsafe merge; neither connection or portfolio is silently substituted. |
| Both devices enable an empty vault simultaneously | CAS retry preserves both sets of eligible records; missing winner key waits for delivery. |
| Disable during download; change local data while off | Late result does not replace local data; no subsequent app transfers; existing local/cloud copies remain. Already submitted requests may finish. |
| Sign out or switch to another Apple account | Existing local data stays available; sync blocks; re-enable cannot publish it to the new account. Returning to the original account permits resuming. |
| Locked device, network failure, quota exhaustion, unavailable container | Actionable status and successful retry; no local data loss or secret-bearing logs. |
| Inspect backup attributes after opt-in | Current plaintext portfolio and recovery backups have backup exclusion; older device backups are not represented as deleted. |
| Production/TestFlight pair | Record type/Asset schema and entitlements work in production; repeat restore and key-delay cases. |

Automated coverage belongs to the `Logic` plan: `CloudCredentialSyncTests`, `CloudPortfolioCryptoTests`, `CloudPortfolioSyncTests`, `PortfolioDocumentMergeTests`, `LocalPortfolioSyncStoreTests`, `CloudPreferencesTests`, `BrokerCredentialPrefillTests`. `CloudDataSettingsTests` belongs to `Views`. Run both complete plans before committing or producing a TestFlight build, as required by `AGENTS.md`; keep build logs in files and report only summaries. Tests use injectable stores/transports and exercise behavior rather than inspecting Swift source text.

Automatic pre-merge backups retain only the newest five `portfolio-cloud-merge-*.json` files; manual, import, reset, and corrupt-file recovery archives are not pruned.

Build configuration explicitly selects the CloudKit environment with `CATFOLIO_ICLOUD_ENVIRONMENT`: Debug defaults to Development; Release defaults to Production. The current Mac+iPhone acceptance builds use Debug with an explicit Production override and share `/tmp/catfolio-icloud-production` as the derived-data directory. Both devices in an acceptance run must use the same actual CloudKit environment; verify signed entitlements rather than inferring it from the configuration name. No Management Token was configured or needed for this Console deployment. The optional command-line token workflow is documented in [the deployment guide](icloud-production-deployment.md).

## Validation recorded on 2026-10-16

- 143 distinct related Logic tests and 38 related Views tests passed. These include independent switches, encrypted restore/deletion with two local stores, delayed keys, account switching, conflicting writers, key rotations, first-upload retries, and preservation of broker-reported profit/loss.
- Reviewed settings screenshots in Chinese and English, including accessibility text size and error states.
- Final signed Debug iOS build passed. Its signed entitlements contain the expected container, `CloudKit`, and `Development`; the provisioning profile authorizes the container.
- Subsequent Production-override Debug builds succeeded for iPhone and Mac Catalyst. The iPhone app was installed and launched successfully with `devicectl`. The Mac build used `-destination 'platform=macOS,variant=Mac Catalyst,arch=arm64' -allowProvisioningUpdates -allowProvisioningDeviceRegistration`; its provisioning profile includes the test Mac. These are signed development builds targeting Production, not TestFlight releases.
- During acceptance, the iPhone installation URL changed, indicating replacement by another build. That previous build's actual environment could not be read; it was not established to be Development. The current workspace was rebuilt for signed Production, installed, and launched again, preserving local data and opt-ins. The current installation URL was then confirmed unchanged. This round changed no source code, and the latest Production iOS build passed.
- Production schema deployment completed through Console. On Mac, both switches were enabled; at 22:28 local time the API-key status reported a successful local iCloud Keychain submission and the portfolio status reported “Synced.” The [Mac runtime screenshot](../CloudKit/mac-production-sync-2026-10-16.jpg) records these initial states. A portfolio retry also succeeded at 22:30 with API-key sync disabled; API-key sync was then re-enabled successfully, exercising the independent switches.
- The user enabled both iPhone opt-ins; stored preferences confirm both are on, and both Apple-account owner hashes match the Mac. Mac System Settings also confirms iCloud Passwords synchronization is on. Eight active credential-baseline fingerprint entries match between devices, and six services appear Configured in the Mac providers UI. No raw keys were read. These checks establish configuration consistency, not successful API authentication for every provider; the separate IBKR Flex Token format warning remains a connection issue.
- After restart and foreground polling, the previously empty Mac personal portfolio received 3 accounts, 140 positions, 3,870 transactions, and 46 snapshots. Final canonical contents of all four business collections (`knownAccounts`, `positions`, `transactions`, and `snapshots`) match between devices. The full documents differ only in `updatedAt` and `syncMetadata` clocks; business-data convergence is confirmed, not final whole-JSON equality. Both UIs report synced: the user confirmed iPhone, and the Mac status was inspected directly. Only counts and comparison results are recorded here, not account names, amounts, or ledger contents.
- Entitlements/localization property-list validation and `git diff --check` passed. The design checker still reports pre-existing violations in 26 files; none are in the sync UI files changed here.
- The user selected Mac+iPhone for hardware acceptance. The Mac test-name change reached the iPhone, and the complete decoded documents matched at that point. The Mac then restored the exact original account names. The latest phone copy confirms the test marker is absent and both devices' names match the saved originals. Device Hub had shown Catfolio outside the foreground during the earlier delay, pausing foreground polling; no further user action is needed for this check.
- The earlier phone copy with 3,871 transaction rows contained one byte-equivalent duplicate, leaving 3,870 unique transactions. A transaction-content set comparison ignoring only the test-affected `accountName` confirmed that all unique content survived restoration. No new unique transaction was lost; the earlier interpretation of an additional transaction awaiting convergence was corrected.
- A [nonsecret acceptance record](../CloudKit/sync-acceptance-2026-10-16.json) retains counts and results only. The full fault-injection/offline hardware matrix was not run, and matching credential fingerprints/configured-provider states do not authenticate every external API. The separate IBKR Flex Token format warning remains outside the passed sync checks.

Basic live Mac+iPhone forward restore, reverse propagation, and original-name restoration are complete. No source code changed during this acceptance round; the latest Production iOS build passed. No TestFlight upload or Git commit was performed.
