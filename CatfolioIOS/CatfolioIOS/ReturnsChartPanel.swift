import SwiftUI

/// Repeatedly hiding the same row is a new scroll, without changing row IDs.
struct ReturnsSourceScrollRequest: Equatable {
    let id: String
    private let revision = UUID()
}

private enum ReturnsSourceRowSpace: Hashable { case content }

private struct ReturnsSourceRowBottoms: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

extension View {
    /// Measure in the rows' own coordinates, which do not change on scroll.
    func returnsSourceScrollRow(id: String) -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(key: ReturnsSourceRowBottoms.self,
                    value: [id: geometry.frame(in: .named(ReturnsSourceRowSpace.content)).maxY])
            }
        }
    }
}

/// Only the handle writes this state. Scrolling the holdings never changes
/// the chart's position, and dragging does not rebuild its prepared series.
@MainActor @Observable
final class ReturnsChartDisclosure {
    private(set) var progress: CGFloat = 0
    @ObservationIgnored private var dragOrigin: CGFloat = 0

    func beginDrag() { dragOrigin = progress }

    func drag(translation: CGFloat, height: CGFloat) {
        guard height > 0 else { return }
        progress = min(1, max(0, dragOrigin - translation / height))
    }

    func endDrag(translation: CGFloat, velocity: CGFloat, height: CGFloat, cancelled: Bool = false) {
        guard height > 0 else { return }
        let projected = cancelled ? dragOrigin : dragOrigin - (translation + velocity * 0.18) / height
        progress = projected > 0.5 ? 1 : 0
    }

    func toggle() { progress = progress < 0.5 ? 1 : 0 }
}

/// The chart retains its full size while translating through the top edge.
/// The list has its own viewport, with a fixed fade beneath the chart. Neither
/// list scrolling nor the chart's date scrubber participates in disclosure.
enum ReturnsChartPanelSurface {
    case income, losses, page

    var theme: ReturnsSourceChartTheme? {
        switch self {
        case .income: .income
        case .losses: .losses
        case .page: nil
        }
    }
}

struct ReturnsChartPanel<Hero: View, Rows: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(ChartInteractionStyle.hapticsPreferenceKey) private var hapticsEnabled = true
    @State private var disclosure: ReturnsChartDisclosure
    @State private var heroHeight: CGFloat = 0
    @State private var listPosition = ScrollPosition(y: 0)
    @State private var rowBottoms: [String: CGFloat] = [:]
    @State private var rowsHeight: CGFloat = 0
    @State private var viewport = ListViewport()
    @State private var scrollExtent: CGFloat = 0
    @State private var pendingOffset: CGFloat?
    let scrollRequest: ReturnsSourceScrollRequest?
    let listDisclosure: ReturnsListDisclosure?
    let surface: ReturnsChartPanelSurface
    let horizontalInset: CGFloat
    let hero: Hero
    let rows: Rows

    init(disclosure: ReturnsChartDisclosure? = nil,
         scrollRequest: ReturnsSourceScrollRequest? = nil,
         listDisclosure: ReturnsListDisclosure? = nil,
         surface: ReturnsChartPanelSurface = .income,
         horizontalInset: CGFloat = 20,
         @ViewBuilder hero: () -> Hero, @ViewBuilder rows: () -> Rows) {
        _disclosure = State(initialValue: disclosure ?? ReturnsChartDisclosure())
        self.scrollRequest = scrollRequest
        self.listDisclosure = listDisclosure
        self.surface = surface
        self.horizontalInset = horizontalInset
        self.hero = hero()
        self.rows = rows()
    }

    private var visibleHeroHeight: CGFloat { heroHeight * (1 - disclosure.progress) }
    // Add only the space needed for a tapped bottom row to clear the viewport.
    // Retain it during subsequent scrolling so the content offset cannot jump.
    private var bottomPadding: CGFloat {
        let drawerExtent = listDisclosure?.isExpanded == true ? listDisclosure?.contentHeight ?? 0 : 0
        // Even a single holding must let the reader push the drawer back
        // beneath the chart; its temporary space disappears when tucked.
        return max(24, viewport.height + max(scrollExtent, drawerExtent) - rowsHeight - 28)
    }

    private struct ListViewport: Equatable {
        var height: CGFloat = 0
        var maximumOffset: CGFloat = 0
    }

    var body: some View {
        VStack(spacing: 0) {
            hero
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heroHeight = $0 }
                .offset(y: -heroHeight * disclosure.progress)
                .frame(height: heroHeight > 0 ? visibleHeroHeight : nil, alignment: .top)
                .clipped()
                .accessibilityHidden(disclosure.progress == 1)
                .zIndex(1)

            ScrollView {
                rows
                    .coordinateSpace(name: ReturnsSourceRowSpace.content)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rowsHeight = $0 }
                    .padding(.horizontal, horizontalInset)
                    .padding(.top, 28)
                    .padding(.bottom, bottomPadding)
                    .offset(y: listDisclosure?.pullCorrection ?? 0)
            }
            .scrollBounceBehavior(listDisclosure == nil ? .automatic : .always, axes: .vertical)
            .scrollPosition($listPosition)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, offset in
                listDisclosure?.update(offset: offset)
            }
            .onScrollPhaseChange { oldPhase, phase, context in
                guard let listDisclosure else { return }
                let offset = context.geometry.contentOffset.y + context.geometry.contentInsets.top
                if phase == .interacting {
                    listDisclosure.begin(at: offset)
                    listDisclosure.update(offset: offset)
                } else if oldPhase == .interacting {
                    withAnimation(reduceMotion ? nil : .spring(duration: 0.34, bounce: 0.08)) {
                        if listDisclosure.release() { listPosition.scrollTo(y: 0) }
                    }
                }
                if phase == .idle {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        if let target = listDisclosure.tuckIfCovered(offset: offset) {
                            listPosition.scrollTo(y: target)
                        }
                    }
                }
            }
            .onPreferenceChange(ReturnsSourceRowBottoms.self) { rowBottoms = $0 }
            .onScrollGeometryChange(for: ListViewport.self) { geometry in
                ListViewport(height: geometry.containerSize.height,
                    maximumOffset: max(0, geometry.contentSize.height - geometry.containerSize.height
                                       + geometry.contentInsets.bottom))
            } action: { _, value in
                viewport = value
                finishPendingScroll(maximumOffset: value.maximumOffset)
            }
            .onChange(of: scrollRequest) { _, request in
                guard let request else { pendingOffset = nil; return }
                guard let bottom = rowBottoms[request.id] else { return }
                let target = bottom + 28
                scrollExtent = max(scrollExtent, target)
                pendingOffset = target
                finishPendingScroll(maximumOffset: viewport.maximumOffset)
            }
            .scrollIndicators(.hidden)
            .mask(alignment: .top) {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .white], startPoint: .top, endPoint: .bottom)
                        .frame(height: 24)
                    Color.white
                }
                .ignoresSafeArea(edges: .bottom)
            }
        }
        .overlay(alignment: .top) {
            ReturnsChartHandle(isCollapsed: disclosure.progress >= 0.5,
                              color: surface.theme != nil || colorScheme == .dark
                                ? .white.withAlphaComponent(0.2) : .black.withAlphaComponent(0.2),
                              onToggle: { settle { disclosure.toggle() } },
                              onPan: { phase, translation, velocity in
                switch phase {
                case .began:
                    disclosure.beginDrag()
                case .changed:
                    disclosure.drag(translation: translation, height: heroHeight)
                case .ended, .cancelled:
                    settle {
                        disclosure.endDrag(translation: translation, velocity: velocity,
                                           height: heroHeight, cancelled: phase == .cancelled)
                    }
                default: break
                }
            })
            // 32 × 4 paint in the Figma's 28pt gap, with a 44pt touch target.
            .frame(width: 96, height: 44)
            .offset(y: visibleHeroHeight - 16)
            .accessibilityActions {
                if let listDisclosure {
                    Button(L10n.text(listDisclosure.isExpanded ? "收起列表设置与概览" : "展开列表设置与概览")) {
                        settle {
                            listDisclosure.setExpanded(!listDisclosure.isExpanded)
                            listPosition.scrollTo(y: 0)
                        }
                    }
                }
            }
        }
        .sensoryFeedback(.impact(flexibility: .rigid, intensity: 0.8),
                         trigger: listDisclosure?.feedbackRevision ?? 0) { _, _ in hapticsEnabled }
        .background(alignment: .top) {
            if let theme = surface.theme {
                GeometryReader { geometry in
                    let start = max(0, visibleHeroHeight - ReturnsSourceChartStyle.stripHeight)
                    VStack(spacing: 0) {
                        theme.background.frame(height: start)
                        LinearGradient(colors: [.black, theme.footer],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: 407)
                        theme.footer
                            .frame(height: max(0, geometry.size.height - start - 407))
                    }
                }
                .ignoresSafeArea(edges: .bottom)
            }
        }
    }

    private func finishPendingScroll(maximumOffset: CGFloat) {
        guard let target = pendingOffset, maximumOffset >= target - 1 else { return }
        pendingOffset = nil
        // Wait for any extra bottom space to be laid out before scrolling;
        // otherwise the last rows would be clamped before reaching the chart.
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.36)) {
            listPosition.scrollTo(y: target)
        }
    }

    private func settle(_ change: () -> Void) {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.34), change)
    }
}

/// A native control confines both tap and pan to the handle. Window-space
/// translation stays stable while the control itself moves with the chart.
struct ReturnsChartHandle: UIViewRepresentable {
    var isCollapsed: Bool
    var color: UIColor
    var onToggle: () -> Void
    var onPan: (UIGestureRecognizer.State, CGFloat, CGFloat) -> Void

    func makeUIView(context: Context) -> Control { Control() }

    func updateUIView(_ view: Control, context: Context) {
        view.onToggle = onToggle
        view.onPan = onPan
        view.tintColor = color
        view.accessibilityLabel = L10n.text(isCollapsed ? "展开图表" : "收起图表")
        view.accessibilityHint = L10n.text("上下拖动把手或轻点以展开、收起图表")
    }

    final class Control: UIControl {
        var onToggle: (() -> Void)?
        var onPan: ((UIGestureRecognizer.State, CGFloat, CGFloat) -> Void)?
        private let capsule = UIView()

        override init(frame: CGRect) {
            super.init(frame: frame)
            capsule.backgroundColor = .white.withAlphaComponent(0.2)
            capsule.layer.cornerRadius = 2
            capsule.isUserInteractionEnabled = false
            addSubview(capsule)
            addTarget(self, action: #selector(toggle), for: .touchUpInside)
            addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(pan(_:))))
            isAccessibilityElement = true
            accessibilityTraits = .button
            accessibilityIdentifier = "returns-chart-handle"
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func tintColorDidChange() {
            super.tintColorDidChange()
            capsule.backgroundColor = tintColor
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            // Extend the touch target into the range strip's bottom padding,
            // never into the first holding row's scroll/tap target.
            capsule.frame = CGRect(x: bounds.midX - 16, y: bounds.midY + 6, width: 32, height: 4)
        }

        @objc private func toggle() { onToggle?() }

        @objc func pan(_ recognizer: UIPanGestureRecognizer) {
            onPan?(recognizer.state, recognizer.translation(in: window).y, recognizer.velocity(in: window).y)
        }

        override func accessibilityActivate() -> Bool {
            onToggle?()
            return true
        }
    }
}
