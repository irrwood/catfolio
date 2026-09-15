"""Exercise the production cache actor without making AI/network requests."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2] / "CatfolioIOS" / "CatfolioIOS"
AI_VIEW = ROOT / "AIView.swift"


def test_research_cache_persistence_and_scope_isolation():
    source = (ROOT / "ResearchView.swift").read_text()
    actor = source.split("actor ResearchAnalysisCache {", 1)[1].split("/// Research is read-only", 1)[0]
    # The cache is generic Codable storage; use a minimal report envelope here.
    swift = '''import Foundation
import CryptoKit
struct PortfolioAttentionReport: Codable, Sendable { let value: String }
actor ResearchAnalysisCache {''' + actor + '''
@main struct Checks {
    static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let first = ResearchAnalysisCache(directory: directory)
        let empty = await first.load(scope: "real-invest")
        precondition(empty == nil)
        try await first.save(.init(value: "old"), scope: "real-invest")
        let reopened = ResearchAnalysisCache(directory: directory)
        let persisted = await reopened.load(scope: "real-invest")
        precondition(persisted?.value == "old")
        let otherAccount = await reopened.load(scope: "real-isa")
        let demo = await reopened.load(scope: "demo-invest")
        precondition(otherAccount == nil && demo == nil)
        try await reopened.save(.init(value: "new"), scope: "real-invest")
        let refreshed = await first.load(scope: "real-invest")
        precondition(refreshed?.value == "new")
        print("PASS: persistence, account isolation, demo isolation, refresh replacement")
    }
}
'''
    # iOS file protection is unavailable in the macOS test host.
    swift = swift.replace("[.atomic, .completeFileProtectionUnlessOpen]", "[.atomic]")
    with tempfile.TemporaryDirectory(prefix="catfolio-research-test-") as directory:
        binary = str(Path(directory) / "check")
        subprocess.run(["swiftc", "-parse-as-library", "-o", binary, "-"], input=swift, text=True, check=True)
        subprocess.run([binary, str(Path(directory) / "cache")], check=True)


def test_research_manual_refresh_and_independent_cards():
    source = (ROOT / "ResearchView.swift").read_text()
    assert '.task(id: accountScope)' in source
    assert 'ResearchAnalysisCache.shared.load(scope: scope)' in source
    assert 'ResearchAnalysisCache.shared.save(response, scope: scope)' in source
    assert 'Button(report == nil ? L10n.text("分析持仓") : L10n.text("刷新分析")' in source
    assert 'ResearchMarketRefreshModifier(enabled: !showsAttention, refresh: refreshMarkets)' in source
    assert 'ForEach(analysisRows) { row in\n                Section {' in source
    assert '.listRowBackground(Color.clear)' not in source
    assert '.listRowSeparator(.hidden)' not in source
    assert 'analysisRequestID == requestID' in source


def test_today_attention_has_its_own_performance_route():
    source = (ROOT / "ResearchView.swift").read_text()
    settings = (ROOT / "SettingsView.swift").read_text()
    returns = (ROOT / "ReturnsView.swift").read_text()
    assert 'struct TodayAttentionView: View' in source
    assert 'ResearchView(showsAttention: true)' in source
    performance = returns.split('SettingsSection(L10n.text("Performance")) {', 1)[1].split(
        'SettingsSection(L10n.text("行情与 AI"))', 1
    )[0]
    assert 'TodayAttentionView().environment(model)' in performance
    assert 'title: L10n.text("今天值得关注")' in performance
    assert 'performance.today-attention' in performance
    assert 'title: L10n.text("今天值得关注")' not in settings
    assert 'L10n.text("AI 持仓分析")' not in source
    assert '.task(id: accountScope) {\n            guard showsAttention else { return }' in source
    assert 'if showsAttention {\n            Section {' in source


def test_prominent_research_cards_use_the_native_list_section_surface():
    source = AI_VIEW.read_text()
    content = source.split("private struct PortfolioAttentionCardContent", 1)[1]

    assert ".frame(maxWidth: .infinity, alignment: .topLeading)" in content
    assert "if !prominent" in content
    assert "minHeight: prominent" not in content
    assert content.count("Color(uiColor: .tertiarySystemFill)") >= 2


if __name__ == "__main__":
    test_research_cache_persistence_and_scope_isolation()
    test_research_manual_refresh_and_independent_cards()
    test_prominent_research_cards_use_the_native_list_section_surface()
    print("PASS: manual refresh and independent card contracts")
