"""Figma 282:2003 layout and explicit, interval-scoped AI entry contracts."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2] / "CatfolioIOS" / "CatfolioIOS"


def test_header_keeps_currency_font_and_shared_time_picker():
    source = (ROOT / "VolumeProfileView.swift").read_text()
    header = source[source.index("struct HoldingDetailHeader: View"):source.index("private struct HoldingPositionDetails")]
    assert 'size: 44' in header
    assert 'holding-detail-close' not in header
    assert 'Typography.number(size: priceSize' in header
    assert 'VStack(alignment: .leading, spacing: 12)' in header
    assert 'ChartTimeRangePicker(selection: $range' in source
    assert 'HoldingDetailHeaderBackdrop()' in source
    assert 'HoldingDetailModalHandle()' not in source


def test_close_button_is_fixed_outside_the_detail_scroll_content():
    source = (ROOT / "VolumeProfileView.swift").read_text()
    detail = source[source.index("struct HoldingDetailView: View"):source.index("private func loadVolumeProfile")]
    scroll_content, viewport = detail.split('.accessibilityIdentifier("holding-detail-scroll")', 1)
    assert 'holding-detail-close' not in scroll_content
    assert '.overlay(alignment: .topTrailing)' in viewport
    assert 'Button { dismiss() }' in viewport
    assert '.accessibilityIdentifier("holding-detail-close")' in viewport
    assert '.modifier(HoldingHeaderButtonStyle())' in viewport
    assert source.count('.accessibilityIdentifier("holding-detail-close")') == 1


def test_analysis_is_only_presented_by_a_tap_and_freezes_the_price_window():
    source = (ROOT / "VolumeProfileView.swift").read_text()
    section = source[source.index("struct HoldingDetailPriceSection"):source.index("private struct HoldingHeaderActionLabel")]
    assert 'SecurityDailyMovePresentation.withoutSystemTransition { explanation = movement }' in section
    assert '.fullScreenCover(item: $explanation)' in section
    assert 'SecurityDailyMovePaper(context: context)' in section
    assert 'SecurityPriceMoveContext.latestSession(history: priceHistory' in section
    assert 'startDate: selection.startDate' not in section
    assert 'store.start' not in section
    assert '.disabled(movement == nil)' in section
    sheet = (ROOT / "SecurityDebateView.swift").read_text()
    assert 'await store.restore()' in sheet
    assert 'store.start(context)' in sheet
    assert 'store.cancel(context)' in sheet


def test_move_cache_does_not_share_generic_debate_keys_or_send_portfolio_data():
    source = (ROOT / "SecurityDebateStore.swift").read_text()
    context = source[source.index("struct SecurityPriceMoveContext"):source.index("final class SecurityPriceMoveStore")]
    for field in ['let shares:', 'let account', 'let averageCost:', 'let unrealized:']:
        assert field not in context
    assert 'let startDate: Date' in context and 'let endDate: Date' in context
    assert 'ContentLanguage.cacheKey(id, language: language)' in context
    assert 'scope.includes($0.source.publishedAt)' in source
    assert 'security-price-moves-v1.json' in source
    assert 'guard tasks[key] == nil' in source


def test_account_cards_use_truthful_optional_pnl_and_keep_multi_select():
    source = (ROOT / "VolumeProfileView.swift").read_text()
    selector = source[source.index("private struct HoldingDetailAccountSelector"):source.index("private struct HoldingDetailModalHandle")]
    assert 'in: .rect(cornerRadius: 22)' in selector
    assert 'minWidth: 128, minHeight: 74' in selector
    assert 'isSelected: selectedAccountKeys.contains(option.id)' in selector
    assert 'currency: currency, signed: true, fractionDigits: 0' in selector
    assert 'unrealized.map' in selector and '?? "—"' in selector


def test_figma_action_assets_are_vector_templates():
    import json
    for name in ['HoldingWhyMove', 'HoldingRefreshQuote']:
        folder = ROOT / 'Assets.xcassets' / f'{name}.imageset'
        metadata = json.loads((folder / 'Contents.json').read_text())
        assert metadata['properties']['template-rendering-intent'] == 'template'
        assert '<svg' in (folder / 'icon.svg').read_text()
