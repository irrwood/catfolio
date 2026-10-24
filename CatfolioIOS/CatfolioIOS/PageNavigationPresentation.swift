import SwiftUI

/// Set by the presentation boundary, never inferred from screen size by a
/// content page. iPhone tabs always use .tabs, including landscape layouts.
enum PageNavigationPresentation {
    case tabs, workspace, sheet

    var hasExternalMarketSearch: Bool { self == .workspace }
    var readingPagesPush: Bool { self == .workspace }
}

enum PageNavigationRole { case root, detail }

extension EnvironmentValues {
    @Entry var pageNavigationPresentation: PageNavigationPresentation = .sheet
}

private struct PageNavigationTitle: ViewModifier {
    @Environment(\.pageNavigationPresentation) private var presentation
    let title: String?
    let preferredDisplayMode: NavigationBarItem.TitleDisplayMode
    let role: PageNavigationRole

    func body(content: Content) -> some View {
        let workspaceMode: NavigationBarItem.TitleDisplayMode = role == .root ? .large : .inline
        content.settingsNavigationTitle(title, displayMode: presentation == .workspace
                                        ? workspaceMode : preferredDisplayMode)
            .workspaceNavigationChrome(titleDisplayMode: workspaceMode)
    }
}

extension View {
    func pageNavigationTitle(_ title: String?, preferredDisplayMode: NavigationBarItem.TitleDisplayMode = .large,
                             role: PageNavigationRole = .detail) -> some View {
        modifier(PageNavigationTitle(title: title, preferredDisplayMode: preferredDisplayMode, role: role))
    }
}

/// A page supplies its search action and holdings. The navigation environment
/// decides whether market search is already provided outside that page.
struct PageMarketSearch: ViewModifier {
    @Environment(\.pageNavigationPresentation) private var presentation
    let filtersHoldings: Bool
    @Binding var query: String
    @Binding var isPresented: Bool
    let holdings: [Holding]
    let onSelect: (MarketSecurityResult) -> Void

    func body(content: Content) -> some View {
        if filtersHoldings {
            content.searchable(text: $query, prompt: L10n.text("搜索持仓"))
        } else if presentation.hasExternalMarketSearch {
            content
        } else {
            content.modifier(ResearchMarketSearch(holdings: holdings, onSelect: onSelect,
                                                 isPresented: $isPresented))
        }
    }
}

struct PageMarketSearchSlot: View {
    @Environment(\.pageNavigationPresentation) private var presentation
    var body: some View {
        if !presentation.hasExternalMarketSearch { ResearchSearchSlot() }
    }
}
