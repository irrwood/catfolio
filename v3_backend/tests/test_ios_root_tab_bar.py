from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
ROOT_TABS = ROOT / "CatfolioIOS" / "CatfolioIOS" / "RootTabView.swift"


def test_custom_tab_bar_uses_the_system_bottom_safe_area_with_native_baseline():
    source = ROOT_TABS.read_text(encoding="utf-8")
    navigation_bar = source[
        source.index("private var navigationBar"):
        source.index("private func navigationButton")
    ]

    assert ".safeAreaInset(edge: .bottom, spacing: 0)" in source
    assert ".padding(.bottom" not in navigation_bar
    assert ".offset(y: TabBarMetrics.nativeVerticalOffset + (isTabBarCompact" in navigation_bar
    assert "static let nativeVerticalOffset: CGFloat = 6" in source


def test_custom_tab_bar_keeps_native_sized_controls_on_one_baseline():
    source = ROOT_TABS.read_text(encoding="utf-8")
    navigation_bar = source[
        source.index("private var navigationBar"):
        source.index("private func tabIcon")
    ]

    assert "HStack(spacing: isTabBarCompact ? 10 : 12)" in navigation_bar
    assert "static let regularControlSize: CGFloat = 56" in source
    assert "static let compactControlSize: CGFloat = 44" in source
    assert "static let compactTabButtonHeight: CGFloat = 40" in source
    assert ".padding(isTabBarCompact ? 2 : 4)" in navigation_bar
    assert '.matchedTransitionSource(id: "ai-bubble", in: assistantZoom)' in navigation_bar


def test_tab_bar_compacts_on_vertical_swipe_without_capturing_chart_drags():
    source = ROOT_TABS.read_text(encoding="utf-8")

    assert "DragGesture" not in source
    assert ".onScrollGeometryChange(for: CGFloat.self)" in source
    assert "isInteracting = phase == .interacting" in source
    assert ".environment(\\.rootTabBarCompact, $isTabBarCompact)" in source
    assert ".frame(height: TabBarMetrics.regularControlSize, alignment: .bottom)" in source
    for name in ["PortfolioView.swift", "ReturnsView.swift", "SettingsView.swift"]:
        assert ".tracksRootTabBarScroll" in (ROOT_TABS.parent / name).read_text(encoding="utf-8")
    assert ".smooth(duration: 0.28)" in source
    assert "accessibilityReduceMotion" in source


def test_navigation_bar_visibility_and_title_follow_the_selected_tab():
    source = ROOT_TABS.read_text(encoding="utf-8")
    root_stack = source[source.index("var body: some View"):source.index("private var rootTabs")]
    tabs = source[source.index("private var rootTabs"):source.index("private var navigationBar")]

    assert "rootTabs\n                .toolbarVisibility(.hidden, for: .navigationBar)" not in root_stack
    assert "AIAssistantPage()\n                        .toolbarVisibility(.hidden, for: .navigationBar)" in root_stack
    assert '.navigationTitle(selection == .settings ? L10n.text("设置") : (selection == .returns ? L10n.text("Performance") : ""))' in tabs
    assert ".toolbarVisibility(selection == .portfolio ? .hidden : .visible, for: .navigationBar)" in tabs
    assert "SettingsView()" in tabs
