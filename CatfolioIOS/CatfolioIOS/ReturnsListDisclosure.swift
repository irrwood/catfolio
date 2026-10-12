import SwiftUI

/// A detent for the list's tucked-away controls, independent of chart collapse
/// and data loading. Only a drag that starts at the top can open it.
@MainActor @Observable
final class ReturnsListDisclosure {
    static let threshold: CGFloat = 64
    static let maximumTravel: CGFloat = 36
    private(set) var isExpanded = false
    private(set) var isArmed = false
    private(set) var feedbackRevision = 0
    private(set) var pullCorrection: CGFloat = 0
    var contentHeight: CGFloat = 0
    @ObservationIgnored private var isInteracting = false
    @ObservationIgnored private var canReveal = false
    @ObservationIgnored private var clicked = false
    @ObservationIgnored private var canTuck = false

    func begin(at offset: CGFloat) {
        isInteracting = true
        canReveal = !isExpanded && offset <= 1
        canTuck = isExpanded
        clicked = false
        isArmed = false
    }

    func update(offset: CGFloat) {
        let pull = max(0, -offset)
        // Native rubber-banding still owns the finger. Counter its extra
        // travel so the list meets a firm, gradually resisting stop.
        let travel = Self.maximumTravel * pull / (Self.maximumTravel + pull)
        pullCorrection = isExpanded ? 0 : travel - pull
        guard isInteracting, canReveal else { return }
        isArmed = pull >= Self.threshold
        if isArmed, !clicked {
            clicked = true
            feedbackRevision &+= 1
        }
    }

    @discardableResult
    func release(cancelled: Bool = false) -> Bool {
        isInteracting = false
        let opens = isArmed && !cancelled
        isArmed = false
        canReveal = false
        if opens { setExpanded(true) }
        return opens
    }

    /// Once scrolling has carried the entire drawer behind the chart, remove
    /// its space and compensate the offset by exactly the same amount.
    func tuckIfCovered(offset: CGFloat) -> CGFloat? {
        defer { canTuck = false }
        guard canTuck, isExpanded, contentHeight > 0, offset >= contentHeight else { return nil }
        setExpanded(false)
        return offset - contentHeight
    }

    func setExpanded(_ expanded: Bool) {
        isExpanded = expanded
        isArmed = false
        pullCorrection = 0
    }
}

struct ReturnsListDrawer<Content: View>: View {
    let disclosure: ReturnsListDisclosure
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.bottom, 18)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { disclosure.contentHeight = $0 }
            .offset(y: disclosure.isExpanded ? 0 : -disclosure.contentHeight)
            .frame(height: disclosure.isExpanded ? disclosure.contentHeight : 0, alignment: .top)
            .clipped()
            .allowsHitTesting(disclosure.isExpanded)
            .accessibilityHidden(!disclosure.isExpanded)
    }
}
