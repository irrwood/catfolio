import SwiftUI
import UIKit
import Observation

/// The app's top-level pages, in sidebar and tab-bar order.
enum RootDestination: Hashable, CaseIterable {
    case portfolio
    case returns
    case research
    case assistant
    case settings
    /// The app's settings, a sidebar page of its own on the Mac. On iOS they
    /// are a row on the account page.
    case preferences

    /// The pages in the sidebar and the Go menu. The Mac shows holdings and
    /// returns side by side on one Overview page.
    static var sidebarCases: [RootDestination] {
        MacPlatform.isMac
            ? [.portfolio, .research, .assistant, .settings, .preferences]
            : [.portfolio, .returns, .research, .assistant, .settings]
    }

    /// Where a request for this page lands: returns are part of the Mac's
    /// Overview.
    var resolved: RootDestination {
        switch self {
        case .returns where MacPlatform.isMac: .portfolio
        case .preferences where !MacPlatform.isMac: .settings
        default: self
        }
    }

    var title: String {
        switch self {
        case .portfolio: MacPlatform.isMac ? L10n.text("概览") : L10n.text("持仓")
        case .returns: L10n.text("收益")
        case .research: L10n.text("研究")
        case .settings: L10n.text("账户")
        case .assistant: L10n.text("AI 助手")
        case .preferences: L10n.text("设置")
        }
    }

    /// ⌘1, ⌘2… in the Go menu, in sidebar order.
    var shortcut: KeyEquivalent {
        let index = Self.sidebarCases.firstIndex(of: resolved) ?? 0
        return KeyEquivalent(Character(String(index + 1)))
    }
}

/// Menu commands ask the root for another page through this; the root owns
/// the selection itself.
@MainActor @Observable
final class RootNavigationRequests {
    static let shared = RootNavigationRequests()
    private(set) var requested: RootDestination?
    private(set) var serial = 0

    func open(_ destination: RootDestination) {
        requested = destination
        serial += 1
    }
}

enum MacPlatform {
    /// The Mac build: a sidebar instead of the bottom tab bar, a resizable
    /// window and menu-bar commands.
    static let isMac = ProcessInfo.processInfo.isMacCatalystApp

    /// Wide enough for the sidebar and Overview's two phone-width columns.
    static let minimumWindowSize = CGSize(width: 1000, height: 640)

    @MainActor
    static func configureWindowScenes() {
        guard isMac else { return }
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            scene.sizeRestrictions?.minimumSize = minimumWindowSize
            #if targetEnvironment(macCatalyst)
            scene.titlebar?.titleVisibility = .hidden
            scene.titlebar?.toolbarStyle = .unified
            #endif
        }
    }
}

/// On the Mac the root tabs become a sidebar; iOS keeps its tab bar.
struct MacSidebarTabStyle: ViewModifier {
    func body(content: Content) -> some View {
        if MacPlatform.isMac {
            content.tabViewStyle(.sidebarAdaptable)
        } else {
            content
        }
    }
}

/// How wide a sidebar page grows on the Mac; the column beside it, where
/// its subpages open, takes the rest of the window.
enum MacPageWidth {
    /// A single column of phone-width cards.
    static let standard: CGFloat = 960
    /// The Overview's rows of two cards need more room.
    static let overview: CGFloat = 1320
}

extension EnvironmentValues {
    /// Keeps a Mac split page's columns; see `MacSplitPage`.
    @Entry var macSplitWidths: MacSplitWidths?
    /// The home chart sits on a white card rather than the blue page, so its
    /// market line cannot be white.
    @Entry var portfolioChartOnCard = false
}

/// Shows a page in the right-hand column of the Mac's split pages: the
/// column every subpage, a security's page included, opens in.
struct MacDetailColumn {
    let open: (AnyView) -> Void
    let close: () -> Void
}

extension EnvironmentValues {
    /// Set inside a Mac split page; nil on iOS.
    @Entry var macDetailColumn: MacDetailColumn?
}

/// A sidebar page on the Mac: the page on the left, and on the right a
/// column for what it opens. Links on the page open in that column, and
/// links there go on within it.
enum MacSplitColumns {
    static let minimumPageWidth: CGFloat = 420
    static let minimumDetailWidth: CGFloat = 360
}

/// A sidebar page on the Mac keeps its own width and the column beside it,
/// where subpages open, takes the rest. Left alone the split view holds the
/// page to a sidebar's narrow width, whatever SwiftUI asks for, and falls
/// back to it again as columns change. This sets the widths straight on
/// the split view, outside SwiftUI's update, so restoring them cannot start
/// another update; setting values it already has changes nothing.
@MainActor
final class MacSplitWidths {
    weak var split: UISplitViewController?
    let pageWidth: CGFloat

    init(pageWidth: CGFloat) {
        self.pageWidth = pageWidth
    }

    func apply() {
        guard let split else { return }
        let minimum = min(MacSplitColumns.minimumPageWidth, pageWidth)
        if split.preferredSplitBehavior != .tile { split.preferredSplitBehavior = .tile }
        if split.preferredDisplayMode != .oneBesideSecondary { split.preferredDisplayMode = .oneBesideSecondary }
        if split.minimumPrimaryColumnWidth != minimum { split.minimumPrimaryColumnWidth = minimum }
        if split.maximumPrimaryColumnWidth != pageWidth { split.maximumPrimaryColumnWidth = pageWidth }
        if split.preferredPrimaryColumnWidth != pageWidth { split.preferredPrimaryColumnWidth = pageWidth }
        if #available(iOS 26.0, macCatalyst 26.0, *),
           split.minimumSecondaryColumnWidth != MacSplitColumns.minimumDetailWidth {
            split.minimumSecondaryColumnWidth = MacSplitColumns.minimumDetailWidth
        }
    }
}

struct MacSplitPage<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let pageWidth: CGFloat
    let content: Content
    @State private var page: OpenedPage?
    @State private var widths: MacSplitWidths

    init(pageWidth: CGFloat, @ViewBuilder content: () -> Content) {
        self.pageWidth = pageWidth
        self.content = content()
        _widths = State(initialValue: MacSplitWidths(pageWidth: pageWidth))
    }

    private struct OpenedPage {
        let id = UUID()
        let view: AnyView
    }

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            content
                .navigationDestination(isPresented: Binding(
                    get: { page != nil },
                    set: { if !$0 { page = nil } }
                )) {
                    if let page { page.view.id(page.id) }
                }
                .environment(\.macDetailColumn, MacDetailColumn(
                    open: { page = OpenedPage(view: $0) },
                    close: { page = nil }
                ))
                .environment(\.macSplitWidths, widths)
                // A page opening beside it, a plain link included, or a
                // resized window can squeeze this column: keep it.
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { _ in widths.apply() }
                .navigationSplitViewColumnWidth(min: MacSplitColumns.minimumPageWidth, ideal: pageWidth, max: pageWidth)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            // Empty until the page opens something.
            PortfolioHomePageBackdrop(colorScheme: colorScheme, isPaused: true)
                .ignoresSafeArea()
        }
        .navigationSplitViewStyle(.balanced)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { _ in widths.apply() }
    }
}

/// Tracks the Mac pointer over its content; never hovered on iOS, so touch
/// screens and the iPad keep their own behaviour.
struct MacHover<Content: View>: View {
    @ViewBuilder let content: (Bool) -> Content
    @State private var isHovered = false

    var body: some View {
        content(isHovered)
            .onHover { hovering in
                guard MacPlatform.isMac else { return }
                isHovered = hovering
            }
    }
}

/// A chart follows the Mac pointer the way it follows a held finger: the
/// point under it is selected, and leaving the plot clears it.
struct MacChartHover: ViewModifier {
    let onMove: (CGPoint) -> Void
    let onEnd: () -> Void

    func body(content: Content) -> some View {
        if MacPlatform.isMac {
            content.onContinuousHover { phase in
                switch phase {
                case .active(let location): onMove(location)
                case .ended: onEnd()
                }
            }
        } else {
            content
        }
    }
}

/// A security's page: in the Mac's right-hand column, or as the usual sheet.
struct SecurityDetailSheetOrColumn<Item: Identifiable, Page: View>: ViewModifier {
    @Binding var item: Item?
    let page: (Item, @escaping () -> Void) -> Page
    @Environment(\.macDetailColumn) private var column

    func body(content: Content) -> some View {
        if let column {
            content.onChange(of: item?.id) {
                guard let opened = item else { return }
                column.open(AnyView(page(opened, column.close).securityDetailPushedBackground()))
                // Free to open the same security again.
                item = nil
            }
        } else {
            content.sheet(item: $item) { opened in
                page(opened, { item = nil }).securityDetailSheet()
            }
        }
    }
}

extension View {
    func securityDetail<Item: Identifiable, Page: View>(
        item: Binding<Item?>,
        @ViewBuilder page: @escaping (Item, @escaping () -> Void) -> Page
    ) -> some View {
        modifier(SecurityDetailSheetOrColumn(item: item, page: page))
    }
}

/// Lists a picker's options directly in the menu that holds it.
struct MacInlinePicker: ViewModifier {
    func body(content: Content) -> some View {
        if MacPlatform.isMac {
            content.pickerStyle(.inline)
        } else {
            content
        }
    }
}

/// One section of the Mac's Overview on its own plain white card.
struct MacOverviewCard: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: SettingsTemplate.cardRadius, style: .continuous)
        content
            .padding(.vertical, 6)
            .background(SettingsTemplate.card, in: shape)
            .clipShape(shape)
    }
}

extension View {
    func macOverviewCard() -> some View { modifier(MacOverviewCard()) }
}

struct CatfolioCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandMenu(L10n.text("前往")) {
            ForEach(RootDestination.sidebarCases, id: \.self) { destination in
                Button(destination.title) {
                    RootNavigationRequests.shared.open(destination)
                }
                .keyboardShortcut(destination.shortcut, modifiers: .command)
            }
        }
        CommandGroup(after: .toolbar) {
            Button(L10n.text("刷新")) {
                Task { await model.refreshPortfolio() }
            }
            .keyboardShortcut("r", modifiers: .command)
        }
        CommandGroup(replacing: .appSettings) {
            Button(L10n.text("设置")) {
                RootNavigationRequests.shared.open(.preferences)
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}
