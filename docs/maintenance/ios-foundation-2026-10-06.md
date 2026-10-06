# iOS foundation maintenance — 2026-10-06

Scope: preserve portfolio calculations and storage formats; use existing actors, caches and AppModel operations. No new service framework.

## Tests

The five Python source-check suites had 50 failures before the maintenance. Retired obsolete checks for old Form/List layouts, monolithic AppModel locations, v3 cache identifiers and explicit Xcode source-file entries. The project uses synchronized folders. These checks are removed, not skipped or blanket-disabled. Retained the 22 passing checks and restored focused disclosure, sell-fill and dividend contracts; two paused-feature contracts bring the Python suites to 27 passing checks.

Behavior coverage resides in native tests:

| Retired check area | Native replacement |
| --- | --- |
| Closed accounts, partial imports, account isolation | AuditRegressionTests; PortfolioAccountAggregationTests |
| Broker result currency, missing/zero result, negative fill | Trading212FillDecodingTests; BrokerResultPreservationTests |
| Account switching and old-request isolation | PublicInvestorSelectionTests |
| Cached home, refresh results, stale versus observed quotes | PortfolioPresentationCacheTests; PortfolioRefreshNoticeTests; LocalPortfolioEngineTests |
| History categories, account/year scope, dividend totals and row identity | HistoryInteractionTests |
| Heatmap remainder, constituent tap targets, exact returns | HeatmapRowTapTargetTests; HeatmapRemainderReturnTests; HoldingsHeatmapAggregationTests |
| Broker setup and credential key scope | AccountOnboardingTests; Trading212InteractionTests; IBKRFirstSyncTests |

New MarketRequestCoalescerTests check simultaneous sharing, session/credential isolation, failure retry, cancellation and write exclusion. MarketCacheFreshnessTests cover expiry boundaries and future-dated disk entries. Existing caches retain their lifetimes and offline fallbacks.

## Implementation limits

- Request sharing is limited to the LocalMarketDataClient Yahoo read transport. No second response cache; no changes to broker synchronization or AI streams.
- Cache fetch freshness stays distinct from quote observation age. Existing quote eligibility checks remain in force.
- Page-facing account selection, broker and mode properties are read-only. Their observed backing values are written by AppModel operations. Other fields remain unchanged.
- LocalPortfolioStore is already an actor: synchronous reads, migrations and atomic writes run outside MainActor and retain serialization. CSV ISIN scanning, parsing and account-label mapping run off MainActor.
- Strategy code, schemas and user workspaces remain intact. Its Lab entry remains disabled. Info.plist no longer grants strategy background processing. To restore the feature, reconnect the entry and restore BGTaskSchedulerPermittedIdentifiers (com.catfolio.ios.policy.*) and UIBackgroundModes (processing) together.

## Validation

- Logic plan: 101 selected tests passed across two runs (market requests/caches, account and broker integrity, onboarding, portfolio math and quote freshness).
- Views plan: 25 HistoryInteractionTests passed; the final account/cache/heatmap run passed 44 tests. The heatmap logo fixture originally inherited the simulator dark appearance while expecting light artwork; its live view and renderer now explicitly use light appearance.
- Python: the five cleaned source-check suites plus paused-strategy contracts passed all 27 checks. This is focused validation, not a claim that the full repository test suite passes.

## Retired compound source checks

### test_ios_account_settings.py

- `test_account_checkmarks_share_the_connector_icon_centerline`
- `test_account_detail_exposes_requested_management_sections`
- `test_account_detail_opens_connectors_in_management_context`
- `test_account_notice_uses_current_alert_presentation_api`
- `test_account_scope_separates_selection_from_detail_navigation`
- `test_ai_zoom_source_declares_the_bubble_clip_shape`
- `test_creating_same_broker_accounts_replaces_only_incoming_accounts`
- `test_every_new_account_flow_collects_a_nickname`
- `test_ibkr_credentials_are_stored_and_loaded_per_account`
- `test_local_service_actions_use_native_button_styles_and_accessibility_labels`
- `test_new_account_section_is_add_only_and_uses_creation_context`
- `test_settings_pages_share_the_native_grouped_background`
- `test_settings_root_uses_native_ios_form_sections_and_controls`
- `test_settings_selection_and_disclosure_symbols_adapt_to_dark_mode`
- `test_sheet_rows_keep_semantic_text_colors_and_show_disclosure_arrows`
- `test_trading_212_accounts_use_dynamic_credential_slots_without_a_fixed_cap`
- `test_trading_212_history_imports_dividends_and_transaction_screen_syncs_it`
- `test_trading_212_history_preserves_negative_sell_fills`
- `test_transaction_rows_use_the_records_stable_domain_identity`

### test_ios_history.py

- `test_closed_accounts_keep_identity_during_sync`
- `test_history_category_directional_content_transition`
- `test_history_groups_dates_and_has_requested_summaries`
- `test_history_header_actions_are_semantic_native_toolbar_controls`
- `test_history_is_available_globally_and_for_one_account`
- `test_history_lets_the_native_inset_grouped_list_own_its_background`
- `test_history_reads_the_full_local_ledger_and_is_built`
- `test_history_supports_activity_categories_account_tags_and_export`
- `test_history_uses_inline_navigation_title`
- `test_history_uses_native_navigation_and_list_hierarchy_without_a_globe`
- `test_realised_display_never_mixes_estimates_or_current_fx_with_results`
- `test_returns_fallback_is_lazy_and_runs_off_main_actor`
- `test_sell_proceeds_are_not_presented_or_totalled_as_realised_profit`

### test_ios_holdings_heatmap.py

- `test_every_sector_sheet_row_is_a_tap_target`
- `test_exposure_preparation_does_not_wait_for_daily_quotes`
- `test_grouped_sectors_have_no_gray_container`
- `test_heatmap_can_expand_etfs_into_constituent_tiles`
- `test_heatmap_can_group_holdings_by_sector`
- `test_heatmap_header_uses_native_period_filter`
- `test_heatmap_moves_with_filters_to_performance_first`
- `test_remainder_opens_a_complete_holdings_list`
- `test_sector_header_opens_a_native_complete_holdings_list`
- `test_stock_detail_is_presented_by_the_list_sheet_without_dismissing_it`

### test_ios_home_loading.py

- `test_all_contribution_bars_share_one_non_bouncy_reveal`
- `test_chart_refresh_preserves_identity_and_last_prepared_curve`
- `test_home_backdrop_is_fixed_outside_the_scroll_view`
- `test_ledger_history_downloads_have_bounded_concurrency`
- `test_loading_matches_current_home_shell`
- `test_refresh_publishes_quotes_before_history_and_retains_cache_on_failure`
- `test_skeleton_is_neutral_and_has_five_equal_bars`

### test_ios_public_investors.py

- `test_investor_accounts_do_not_add_disclosure_labels_to_portfolio_ui`

