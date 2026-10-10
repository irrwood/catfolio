import SwiftUI
import UIKit

struct PortfolioFloatingFilterSource {
    let bounds: Anchor<CGRect>
    // The bindings still belong to the details card, including its transient
    // performance period and ETF sort. Both presentations operate on that state.
    let menu: AnyView
}

struct PortfolioFloatingFilterPreference: PreferenceKey {
    static var defaultValue: PortfolioFloatingFilterSource? { nil }
    static func reduce(value: inout PortfolioFloatingFilterSource?, nextValue: () -> PortfolioFloatingFilterSource?) {
        value = nextValue() ?? value
    }
}

struct PortfolioFloatingFilterOverlay: ViewModifier {
    func body(content: Content) -> some View {
        content.overlayPreferenceValue(PortfolioFloatingFilterPreference.self) { source in
            GeometryReader { geometry in
                if let source, Self.shouldFloat(sourceFrame: geometry[source.bounds]) {
                    source.menu
                        .accessibilityIdentifier("portfolio-floating-filter")
                        .padding(.top, 10)
                        .padding(.trailing, CatfolioStyle.pageHorizontalInset)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
        }
    }

    static func shouldFloat(sourceFrame: CGRect) -> Bool {
        sourceFrame.height > 0 && sourceFrame.maxY.isFinite && sourceFrame.maxY <= 0
    }
}

struct PortfolioHeaderMaterialControl: ViewModifier {
    func body(content: Content) -> some View {
        content.background(.regularMaterial, in: Circle())
    }

}
