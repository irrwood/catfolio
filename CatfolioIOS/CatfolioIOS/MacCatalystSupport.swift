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
    /// The share of the split the subpage column keeps, so a security's page
    /// opened beside the page still has room to read.
    static let detailShare: CGFloat = 0.4

    /// The page's width in a split this wide: as wide as it grows, after the
    /// subpage column has its share, and never below its own minimum.
    static func pageWidth(available: CGFloat, maximum: CGFloat) -> CGFloat {
        let detail = max(minimumDetailWidth, (available * detailShare).rounded())
        let page = min(maximum, available - detail)
        return max(min(minimumPageWidth, maximum), page).rounded()
    }
}

/// A sidebar page on the Mac keeps its own width and the column beside it,
/// where subpages open, takes the rest. On the Mac the split is a divider a
/// person can drag, and a preferred width only seeds where it starts: left
/// alone it settled at about half the window, whatever SwiftUI or a
/// preferred width asked for. The page's width is pinned instead (the same
/// minimum and maximum), worked out again whenever the window changes.
/// Set straight on the split view, outside SwiftUI's update, so restoring it
/// cannot start another update; values it already has are left alone.
@MainActor
final class MacSplitWidths {
    weak var split: UISplitViewController? {
        didSet { if split !== oldValue { observeResizing() } }
    }
    let pageWidth: CGFloat

    init(pageWidth: CGFloat) {
        self.pageWidth = pageWidth
    }

    /// SwiftUI reports a new window size before UIKit has resized the split
    /// view, so the width it read then was the old one. A view riding along
    /// inside the split hears each real change of its width instead.
    private func observeResizing() {
        guard let split else { return }
        guard !split.view.subviews.contains(where: { $0 is SplitResizeObserver }) else { return }
        let observer = SplitResizeObserver(frame: split.view.bounds)
        observer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        observer.isUserInteractionEnabled = false
        observer.onResize = { [weak self] in self?.apply() }
        split.view.insertSubview(observer, at: 0)
    }

    func apply() {
        guard let split else { return }
        let available = split.view.bounds.width
        guard available > 0 else { return }
        let page = MacSplitColumns.pageWidth(available: available, maximum: pageWidth)
        if split.preferredSplitBehavior != .tile { split.preferredSplitBehavior = .tile }
        if split.preferredDisplayMode != .oneBesideSecondary { split.preferredDisplayMode = .oneBesideSecondary }
        // Widen the range before narrowing it, so the two never cross.
        if page > split.maximumPrimaryColumnWidth {
            split.maximumPrimaryColumnWidth = page
            split.minimumPrimaryColumnWidth = page
        } else {
            if split.minimumPrimaryColumnWidth != page { split.minimumPrimaryColumnWidth = page }
            if split.maximumPrimaryColumnWidth != page { split.maximumPrimaryColumnWidth = page }
        }
        if split.preferredPrimaryColumnWidth != page { split.preferredPrimaryColumnWidth = page }
        if #available(iOS 26.0, macCatalyst 26.0, *) {
            if split.minimumSecondaryColumnWidth != MacSplitColumns.minimumDetailWidth {
                split.minimumSecondaryColumnWidth = MacSplitColumns.minimumDetailWidth
            }
            let secondary = available - page
            if split.preferredSecondaryColumnWidth != secondary { split.preferredSecondaryColumnWidth = secondary }
        }
        // A changed width does not move the divider until the split lays out.
        if abs(split.primaryColumnWidth - page) > 0.5 {
            split.view.setNeedsLayout()
            split.view.layoutIfNeeded()
        }
    }
}

/// Calls back once the split view it sits in has really changed width.
private final class SplitResizeObserver: UIView {
    var onResize: (() -> Void)?
    private var lastWidth: CGFloat = 0

    override func layoutSubviews() {
        super.layoutSubviews()
        guard abs(bounds.width - lastWidth) > 0.5 else { return }
        lastWidth = bounds.width
        // After this layout pass, not inside it.
        DispatchQueue.main.async { [weak self] in self?.onResize?() }
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
        // The sidebar takes the accent for its selection; the pages keep the
        // ink they have on the phone.
        .tint(.primary)
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
/// point under it is selected, and leaving the plot clears it. Pressing and
/// dragging measures from where the press began to the pointer, as two
/// held fingers do on a touch screen; letting go clears it.
struct MacChartHover: ViewModifier {
    let onMove: (CGPoint) -> Void
    let onEnd: () -> Void
    var onDrag: ((CGPoint, CGPoint) -> Void)?
    var onDragEnd: (() -> Void)?
    @State private var isDragging = false

    func body(content: Content) -> some View {
        if MacPlatform.isMac {
            content
                .onContinuousHover { phase in
                    // While a press measures, the pointer is its end, not a
                    // single day of its own.
                    guard !isDragging else { return }
                    switch phase {
                    case .active(let location): onMove(location)
                    case .ended: onEnd()
                    }
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 3)
                        .onChanged { value in
                            guard let onDrag else { return }
                            isDragging = true
                            onDrag(value.startLocation, value.location)
                        }
                        .onEnded { _ in
                            guard isDragging else { return }
                            isDragging = false
                            onDragEnd?()
                        },
                    including: onDrag == nil ? .subviews : .all
                )
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
            .environment(\.sitsOnMacOverviewCard, true)
            .padding(.vertical, 6)
            // Given a row's height, the card takes all of it, so the two
            // cards of a row end on the same line.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(SettingsTemplate.card, in: shape)
            .clipShape(shape)
    }
}

extension EnvironmentValues {
    /// The Mac Overview's heatmap fills the height its card is given, so it
    /// matches the chart card beside it, rather than its own fixed height.
    @Entry var heatmapFillsHeight = false
    /// Inside a Mac Overview card: the card paints the one card colour, and
    /// what sits on it leaves its own ground off.
    @Entry var sitsOnMacOverviewCard = false
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
