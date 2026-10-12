import SwiftUI
import UIKit

struct PortfolioFloatingFilterSource {
    let bounds: Anchor<CGRect>
    // The bindings still belong to the details card, including its transient
    // performance period and ETF sort. Both presentations operate on that state.
    let title: AnyView
    let menu: AnyView
}

struct PortfolioFloatingFilterPreference: PreferenceKey {
    static var defaultValue: PortfolioFloatingFilterSource? { nil }
    static func reduce(value: inout PortfolioFloatingFilterSource?, nextValue: () -> PortfolioFloatingFilterSource?) {
        value = nextValue() ?? value
    }
}

/// The holdings header's two halves, for the navigation bar once the header
/// itself has scrolled away.
struct PortfolioFloatingHeader {
    let title: AnyView
    let menu: AnyView
}

/// The two toolbar items enter together after the inline header leaves.
/// Animate their appearance without moving the navigation bar or scroll content.
struct PortfolioFloatingHeaderReveal: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isRevealed = false

    func body(content: Content) -> some View {
        content
            .blur(radius: isRevealed || reduceMotion ? 0 : 4)
            .offset(y: isRevealed || reduceMotion ? 0 : 4)
            .opacity(isRevealed ? 1 : 0)
            .task {
                await Task.yield()
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: reduceMotion ? 0.16 : 0.28)) {
                    isRevealed = true
                }
            }
            .onDisappear {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { isRevealed = false }
            }
    }
}

/// Reports whether the holdings header has scrolled above the top of the
/// page. While it has, the page shows the system navigation bar carrying the
/// header's title and sort button, with the system's own edge under it.
struct PortfolioFloatingHeaderReporter: ViewModifier {
    @Binding var header: PortfolioFloatingHeader?

    func body(content: Content) -> some View {
        content.overlayPreferenceValue(PortfolioFloatingFilterPreference.self) { source in
            GeometryReader { geometry in
                let floats = source.map { Self.shouldFloat(sourceFrame: geometry[$0.bounds]) } ?? false
                Color.clear
                    .allowsHitTesting(false)
                    .onChange(of: floats, initial: true) { _, floats in
                        guard floats != (header != nil) else { return }
                        header = floats ? source.map { PortfolioFloatingHeader(title: $0.title, menu: $0.menu) } : nil
                    }
            }
        }
    }

    static func shouldFloat(sourceFrame: CGRect) -> Bool {
        sourceFrame.height > 0 && sourceFrame.maxY.isFinite && sourceFrame.maxY <= 0
    }
}

private struct PortfolioFilterFloatsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True for the copy of the sort button in the navigation bar. Its glass
    /// travels with the label so the whole control can reveal together.
    var portfolioFilterFloats: Bool {
        get { self[PortfolioFilterFloatsKey.self] }
        set { self[PortfolioFilterFloatsKey.self] = newValue }
    }
}

struct PortfolioHeaderMaterialControl: ViewModifier {
    @Environment(\.portfolioFilterFloats) private var inBar

    @ViewBuilder func body(content: Content) -> some View {
        if inBar {
            if #available(iOS 26.0, *) {
                content
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular.interactive(), in: Circle())
            } else {
                content
            }
        } else {
            content.background(.regularMaterial, in: Circle())
        }
    }

}

extension ToolbarContent {
    /// A bar item drawn bare, without the glass the bar puts behind items:
    /// the holdings title reads as the bar's title, not a button.
    @ToolbarContentBuilder
    func withoutSharedBackground() -> some ToolbarContent {
        if #available(iOS 26.0, *) {
            sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}
