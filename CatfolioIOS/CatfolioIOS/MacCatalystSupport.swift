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

    @MainActor static var usesWorkspace: Bool {
        isMac || UIDevice.current.userInterfaceIdiom == .pad
    }

    /// Wide enough for the sidebar and Overview's two phone-width columns.
    static let minimumWindowSize = CGSize(width: 1000, height: 640)

    @MainActor
    static func configureWindowScenes() {
        guard isMac else { return }
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            scene.sizeRestrictions?.minimumSize = minimumWindowSize
            #if targetEnvironment(macCatalyst)
            scene.titlebar?.titleVisibility = .visible
            scene.titlebar?.toolbarStyle = .unified
            #endif
        }
    }
}

extension EnvironmentValues {
    /// The home chart sits on a white card rather than the blue page.
    @Entry var portfolioChartOnCard = false
}

/// Existing security presenters push onto the workspace's detail stack.
struct MacDetailColumn {
    let open: (AnyView) -> Void
    let close: () -> Void
}

extension EnvironmentValues {
    @Entry var macDetailColumn: MacDetailColumn?
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
