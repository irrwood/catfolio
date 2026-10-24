import SwiftUI
import UIKit
import Observation

/// The sidebar's selection is separate from navigation within its detail.
/// Picking another row starts at that row's root, never inside the old stock.
enum WorkspaceSelection: Hashable {
    case page(RootDestination)
    case holding(WorkspaceHoldingDestination)
    case security(MarketSecurityResult)
}

/// The selected row carries its detail payload, including unheld ETF
/// constituents and the aggregate remainder that opens amount sources.
struct WorkspaceHoldingDestination: Hashable {
    let item: PortfolioHoldingListItem

    private var identity: String {
        switch item {
        case .holding: "holding:" + item.id
        case .exposure: "exposure:" + item.id
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.identity == rhs.identity }
    func hash(into hasher: inout Hasher) { hasher.combine(identity) }
}

extension EnvironmentValues {
    // Compatibility for pages not migrated yet; the container remains the
    // single source of presentation policy.
    var isWorkspaceDetail: Bool {
        get { pageNavigationPresentation == .workspace }
        set { pageNavigationPresentation = newValue ? .workspace : .sheet }
    }
}

@MainActor @Observable
final class WorkspaceDetailRouter {
    var path = NavigationPath()

    struct Page: Hashable {
        let id = UUID()
        let view: AnyView
        static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    func open(_ view: AnyView) { path.append(Page(view: view)) }
    func close() { if !path.isEmpty { path.removeLast() } }
}

/// UIKit owns the navigation bar and its scroll-edge title treatment.
/// Tab roots request large titles; pushed pages retain compact titles.
struct WorkspaceNavigationChrome: ViewModifier {
    @Environment(\.pageNavigationPresentation) private var presentation
    var titleDisplayMode: NavigationBarItem.TitleDisplayMode = .inline
    func body(content: Content) -> some View {
        if presentation == .workspace {
            content.navigationBarTitleDisplayMode(titleDisplayMode)
                .toolbarVisibility(.visible, for: .navigationBar)
                .toolbarBackground(.automatic, for: .navigationBar)
        } else { content }
    }
}

extension View {
    func workspaceNavigationChrome(titleDisplayMode: NavigationBarItem.TitleDisplayMode = .inline) -> some View {
        modifier(WorkspaceNavigationChrome(titleDisplayMode: titleDisplayMode))
    }
}

/// Retains phone-specific chart chrome while letting the workspace system
/// toolbar choose its own material and scroll-edge treatment.
private struct AdaptiveNavigationBackground: ViewModifier {
    @Environment(\.pageNavigationPresentation) private var presentation
    var color: Color?
    var visibility: Visibility

    @ViewBuilder func body(content: Content) -> some View {
        if presentation == .workspace {
            content.workspaceNavigationChrome()
        } else if let color {
            content.toolbarBackground(color, for: .navigationBar)
                .toolbarBackground(visibility, for: .navigationBar)
        } else {
            content.toolbarBackground(visibility, for: .navigationBar)
        }
    }
}

extension View {
    func adaptiveNavigationBackground(_ color: Color? = nil,
                                      visibility: Visibility = .visible) -> some View {
        modifier(AdaptiveNavigationBackground(color: color, visibility: visibility))
    }
}

/// Account forms publish their current step title to the system navigation bar.
struct WorkspacePageTitleKey: PreferenceKey {
    static var defaultValue: String = ""
    static func reduce(value: inout String, nextValue: () -> String) {
        let next = nextValue()
        if !next.isEmpty { value = next }
    }
}

/// All subpages share this stack, so SwiftUI supplies the actual Back action.
struct WorkspaceDetailStack<Content: View>: View {
    @State private var router: WorkspaceDetailRouter
    let rootTitleDisplayMode: NavigationBarItem.TitleDisplayMode
    let content: Content

    init(router: WorkspaceDetailRouter? = nil,
         rootTitleDisplayMode: NavigationBarItem.TitleDisplayMode = .inline,
         @ViewBuilder content: () -> Content) {
        _router = State(initialValue: router ?? WorkspaceDetailRouter())
        self.rootTitleDisplayMode = rootTitleDisplayMode
        self.content = content()
    }

    var body: some View {
        let navigation = MacDetailColumn(
            open: { [weak router] in router?.open($0) },
            close: { [weak router] in router?.close() }
        )
        NavigationStack(path: $router.path) {
            content.workspaceNavigationChrome(titleDisplayMode: rootTitleDisplayMode)
                .navigationDestination(for: WorkspaceDetailRouter.Page.self) { page in
                    page.view.securityDetailPushedBackground()
                        .environment(\.pageNavigationPresentation, .workspace)
                        .environment(\.macDetailColumn, navigation)
                        .workspaceNavigationChrome()
                }
        }
        .environment(\.pageNavigationPresentation, .workspace)
        .environment(\.macDetailColumn, navigation)
        // Mac maps navigation items to AppKit toolbar buttons. A primary
        // tint colors their bezels white in dark mode instead of leaving
        // the system toolbar material in control.
        .tint(MacPlatform.isMac ? nil : Color.primary)
    }
}

/// One system split view on Mac and iPad, including the iPad's compact collapse.
struct WorkspaceSplitView<Sidebar: View, Detail: View>: View {
    @State private var visibility: NavigationSplitViewVisibility = .all
    @ViewBuilder let sidebar: Sidebar
    @ViewBuilder let detail: Detail

    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 320, ideal: 400, max: 480)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        // Value destinations are hosted by the split view, outside the detail
        // root's local environment. Keep workspace chrome at that boundary.
        .environment(\.pageNavigationPresentation, .workspace)
    }
}

struct NativeWorkspace: View {
    @Environment(AppModel.self) private var model
    @Binding var tab: RootDestination
    let presentationPreferencesID: String
    let trading212SetupStore: Trading212SetupStore
    @State private var selection: WorkspaceSelection?
    @State private var searchQuery = ""
    @State private var searchPresented = false
    @FocusState private var searchFocused: Bool
    @State private var router = WorkspaceDetailRouter()
    private let requests = RootNavigationRequests.shared

    init(tab: Binding<RootDestination>, presentationPreferencesID: String,
         trading212SetupStore: Trading212SetupStore) {
        _tab = tab
        self.presentationPreferencesID = presentationPreferencesID
        self.trading212SetupStore = trading212SetupStore
        _selection = State(initialValue: .page(tab.wrappedValue))
    }

    var body: some View {
        WorkspaceSplitView {
            List(selection: $selection) {
                if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Section {
                        ForEach(RootDestination.sidebarCases, id: \.self) { destination in
                            NavigationLink(value: WorkspaceSelection.page(destination)) {
                                HStack(spacing: 12) {
                                    Image(destination.sidebarArtwork)
                                        .renderingMode(.template)
                                        .frame(width: 24, height: 24)
                                        .foregroundStyle(CatfolioTheme.primaryText)
                                    Text(destination.title)
                                        .foregroundStyle(CatfolioTheme.primaryText)
                                }
                            }
                            // Keep the native inactive selection monochrome;
                            // do not let its label fall back to the accent tint.
                            .listItemTint(.monochrome)
                            .accessibilityIdentifier("sidebar.page.\(destination)")
                        }
                    }
                }
                if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    PortfolioDetailsCard(holdings: model.holdings, onSelect: { _ in }, isSidebar: true)
                } else {
                    ResearchMarketSearchView(holdings: model.holdings, onSelect: { _ in },
                                             query: searchQuery, onDismiss: { searchQuery = "" },
                                             isSidebar: true)
                }
            }
            .listStyle(.sidebar)
            .contentMargins(.top, 16, for: .scrollContent)
            // Selection ends search focus below. A gesture on the entire List
            // interferes with its native row selection on iPhone Duo.
            // Use the same quiet selection when the sidebar has keyboard
            // focus; keep native selection, focus, and row geometry.
            .tint(Color(uiColor: .tertiarySystemFill))
            .navigationTitle("")
            .searchable(text: $searchQuery, isPresented: $searchPresented,
                        placement: .sidebar, prompt: L10n.text("搜索股票、ETF 或公司名"))
            .searchFocused($searchFocused)
            .accessibilityIdentifier("workspace.sidebar")
        } detail: {
            WorkspaceDetailStack(router: router, rootTitleDisplayMode: rootTitleDisplayMode) {
                detail
            }
            .id(selection)
            .accessibilityIdentifier("workspace.detail")
            .simultaneousGesture(TapGesture().onEnded { searchFocused = false })
        }
        .environment(\.macDetailColumn, MacDetailColumn(
            open: { [weak router] in router?.open($0) },
            close: { [weak router] in router?.close() }
        ))
        .task { await model.loadPortfolioHomeIfNeeded() }
        .onChange(of: selection) { _, value in
            searchFocused = false
            router.path = NavigationPath()
            if case let .page(destination) = value { tab = destination }
        }
        .onChange(of: tab) { _, value in selection = .page(value) }
        .onChange(of: requests.serial) {
            if let requested = requests.requested { selection = .page(requested.resolved) }
        }
    }

    private var rootTitleDisplayMode: NavigationBarItem.TitleDisplayMode {
        if case .page = selection ?? .page(tab) { return .large }
        return .inline
    }

    @ViewBuilder private var detail: some View {
        switch selection ?? .page(tab) {
        case .page(let destination):
            rootPage(destination)
                .navigationTitle(destination.title)
                .workspaceNavigationChrome(titleDisplayMode: .large)
        case .security(let result):
            let holding = result.resolvedHolding(in: model.holdings)
            HoldingDetailView(holding: holding, onClose: {})
                .securityDetailPushedBackground()
                .navigationTitle(holding.ticker)
                .navigationBarTitleDisplayMode(.inline)
        case .holding(let destination):
            if let holding = model.holdings.first(where: { $0.id == destination.item.id })
                ?? destination.item.detailHolding {
                HoldingDetailView(holding: holding, onClose: {})
                    .securityDetailPushedBackground()
                    .navigationTitle(holding.ticker)
                    .navigationBarTitleDisplayMode(.inline)
            } else if case let .exposure(row, _, _, _) = destination.item {
                HoldingAmountSourcesPage(ticker: row.ticker, initialRow: row)
            }
        }
    }

    @ViewBuilder private func rootPage(_ destination: RootDestination) -> some View {
        switch destination {
        case .portfolio: PortfolioView().id(presentationPreferencesID)
        case .returns: ReturnsView().id(presentationPreferencesID)
        case .research: ResearchView().id(presentationPreferencesID)
        case .assistant: AIAssistantPage().id(presentationPreferencesID)
        case .settings:
            SettingsView(presentationPreferencesID: presentationPreferencesID,
                         trading212SetupStore: trading212SetupStore)
        case .preferences: AppSettingsView(isWorkspaceRoot: true)
        }
    }
}

private extension RootDestination {
    var sidebarArtwork: String {
        switch self {
        case .portfolio: RootTabArtwork.portfolio.unselected
        case .returns: RootTabArtwork.returns.unselected
        case .research: RootTabArtwork.research.unselected
        case .assistant: RootTabArtwork.assistant.unselected
        case .settings: RootTabArtwork.settings.unselected
        case .preferences: "AccountSettings"
        }
    }
}

/// Reading pages push in the workspace and retain their phone sheet behaviour.
/// Editing forms and pickers continue to use appSheet on every platform.
private struct WorkspacePagePresentation<Page: View>: ViewModifier {
    @Environment(\.pageNavigationPresentation) private var presentation
    @Environment(\.macDetailColumn) private var navigation
    @Binding var isPresented: Bool
    var onDismiss: (() -> Void)?
    @ViewBuilder let page: () -> Page

    func body(content: Content) -> some View {
        if presentation.readingPagesPush {
            content.navigationDestination(isPresented: $isPresented) {
                page().environment(\.pageNavigationPresentation, .workspace)
                    .environment(\.macDetailColumn, navigation)
                    .workspaceNavigationChrome()
            }
            .onChange(of: isPresented) { old, new in
                if old && !new { onDismiss?() }
            }
        } else {
            content.appSheet(isPresented: $isPresented, onDismiss: onDismiss, content: page)
        }
    }
}

private struct WorkspaceItemPresentation<Item: Identifiable, Page: View>: ViewModifier {
    @Environment(\.pageNavigationPresentation) private var presentation
    @Environment(\.macDetailColumn) private var navigation
    @Binding var item: Item?
    var onDismiss: (() -> Void)?
    @ViewBuilder let page: (Item) -> Page

    func body(content: Content) -> some View {
        if presentation.readingPagesPush {
            content.navigationDestination(item: Binding(
                get: { item?.id }, set: { if $0 == nil { item = nil } }
            )) { _ in
                if let item { page(item).environment(\.pageNavigationPresentation, .workspace)
                    .environment(\.macDetailColumn, navigation)
                    .workspaceNavigationChrome() }
            }
            .onChange(of: item?.id) { old, new in
                if old != nil && new == nil { onDismiss?() }
            }
        } else {
            content.appSheet(item: $item, onDismiss: onDismiss, content: page)
        }
    }
}

extension View {
    func workspacePage<Page: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil,
                                   @ViewBuilder content: @escaping () -> Page) -> some View {
        modifier(WorkspacePagePresentation(isPresented: isPresented, onDismiss: onDismiss, page: content))
    }

    func workspacePage<Item: Identifiable, Page: View>(item: Binding<Item?>, onDismiss: (() -> Void)? = nil,
                                                       @ViewBuilder content: @escaping (Item) -> Page) -> some View {
        modifier(WorkspaceItemPresentation(item: item, onDismiss: onDismiss, page: content))
    }
}

/// A sheet owns a stack; a pushed page reuses the workspace's stack.
struct DetailPageNavigation<Content: View>: View {
    @Environment(\.pageNavigationPresentation) private var presentation
    @ViewBuilder let content: Content

    var body: some View {
        if presentation.readingPagesPush { content }
        else { NavigationStack { content } }
    }
}
