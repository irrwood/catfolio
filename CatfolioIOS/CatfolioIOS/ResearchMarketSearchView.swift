import SwiftUI
import UIKit

/// Search starts below the large title and follows its content slot until
/// it reaches the toolbar. Query changes stay outside dashboard state.
struct ResearchMarketSearch: ViewModifier {
    let holdings: [Holding]
    let onSelect: (MarketSecurityResult) -> Void
    @Binding var isPresented: Bool
    var pullObserver: ResearchSearchPullToDismiss.Observer? = nil
    @State private var query = ""
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(ChartInteractionStyle.hapticsPreferenceKey) private var hapticsEnabled = true
    @State private var motion = ResearchSearchMotion()
    @State private var placement = ResearchSearchPlacement()
    @State private var resultsTopInset: CGFloat = 0

    static var navigationTitle: String {
        L10n.text("研究")
    }

    func body(content: Content) -> some View {
        let dashboard = content.overlay {
            if isPresented {
                ResearchMarketSearchView(holdings: holdings, onSelect: { result in
                    // Keep the query, loaded results and scroll position under
                    // the detail sheet; selecting only dismisses the keyboard.
                    isFocused = false
                    motion.field?.endEditing(true)
                    onSelect(result)
                }, query: query, onDismiss: dismissSearch, pullObserver: pullObserver,
                   onPull: motion.pull, onPullCancel: motion.cancelPull, onPullDismiss: dismissAfterPull,
                   contentTopInset: resultsTopInset)
                    .transition(.asymmetric(insertion: .opacity,
                                            removal: .opacity.animation(reduceMotion ? nil : .easeOut(duration: 0.2))))
            }
        }
        return Group {
            if #available(iOS 26.0, *) {
                dashboard
                    .environment(\.researchSearchPlacement, placement)
                    .background {
                        ResearchToolbarSearch(query: $query, isPresented: $isPresented,
                                              motion: motion, hapticsEnabled: hapticsEnabled,
                                              onPullDismiss: dismissAfterPull, placement: placement,
                                              onResultsInset: { resultsTopInset = $0 })
                            .frame(width: 0, height: 0)
                    }
                    .toolbar {
                        ToolbarItem(placement: .principal) {
                            // The field replaces the compact title only when
                            // its content slot has scrolled up to this row.
                            Color.clear.frame(width: 1, height: 44)
                        }
                    }
            } else {
                dashboard
                    .searchable(text: $query, isPresented: $isPresented,
                                placement: .navigationBarDrawer(displayMode: .always),
                                prompt: L10n.text("搜索股票、ETF 或公司名"))
                    .searchFocused($isFocused)
            }
        }
        .onAppear { motion.reduceMotion = reduceMotion }
        .onChange(of: reduceMotion) { _, value in motion.reduceMotion = value }
        .onDisappear { motion.reset() }
        .onChange(of: isPresented) { _, presented in
            if !presented {
                motion.presentationEnded()
                query = ""
                isFocused = false
            }
        }
    }

    private func dismissSearch() {
        isFocused = false
        isPresented = false
    }

    private func dismissAfterPull() {
        // No animated transaction here: under one, SwiftUI animates the
        // large title's expansion on its own clock, apart from the field's
        // flight. The results fade through their removal transition instead.
        motion.finishPull { dismissSearch() }
    }
}

/// A single native field keeps focus while moving from the page to the bar.
@available(iOS 26.0, *)
struct ResearchToolbarSearch: UIViewControllerRepresentable {
    @Binding var query: String
    @Binding var isPresented: Bool
    var motion: ResearchSearchMotion
    var hapticsEnabled: Bool
    var onPullDismiss: () -> Void
    var placement: ResearchSearchPlacement
    var onResultsInset: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(query: $query, isPresented: $isPresented) }

    func makeUIViewController(context: Context) -> PositionController {
        let controller = PositionController(placement: placement)
        let field = controller.field
        motion.field = field.movingContent
        field.searchBar.delegate = context.coordinator
        field.onCancel = { [weak field, weak coordinator = context.coordinator] in
            guard let field else { return }
            coordinator?.cancel(field.searchBar)
        }
        return controller
    }

    func updateUIViewController(_ controller: PositionController, context: Context) {
        let field = controller.field
        controller.onResultsInset = onResultsInset
        context.coordinator.query = $query
        context.coordinator.isPresented = $isPresented
        motion.field = field.movingContent
        field.pullObserver.hapticsEnabled = hapticsEnabled
        field.pullObserver.onPull = motion.pull
        field.pullObserver.onPullCancel = motion.cancelPull
        field.pullObserver.onDismiss = onPullDismiss
        field.searchBar.placeholder = L10n.text("搜索股票、ETF 或公司名")
        field.cancelButton.accessibilityLabel = L10n.text("取消")
        let displayedQuery = isPresented ? query : ""
        if field.searchBar.text != displayedQuery { field.searchBar.text = displayedQuery }
        controller.setPresented(isPresented)
    }

    static func dismantleUIViewController(_ controller: PositionController, coordinator: Coordinator) {
        let field = controller.field
        field.searchBar.delegate = nil
        field.onCancel = nil
        field.searchBar.resignFirstResponder()
        controller.detach()
    }

    final class Coordinator: NSObject, UISearchBarDelegate {
        var query: Binding<String>
        var isPresented: Binding<Bool>

        init(query: Binding<String>, isPresented: Binding<Bool>) {
            self.query = query
            self.isPresented = isPresented
        }

        func searchBarTextDidBeginEditing(_ searchBar: UISearchBar) {
            isPresented.wrappedValue = true
        }

        func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
            // Keyboard dismissal can deliver the last editing value after
            // cancellation; it must not refill the resting search field.
            guard isPresented.wrappedValue else { return }
            if query.wrappedValue != searchText { query.wrappedValue = searchText }
        }

        func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
            cancel(searchBar)
        }

        func cancel(_ searchBar: UISearchBar) {
            searchBar.resignFirstResponder()
            searchBar.text = ""
            query.wrappedValue = ""
            isPresented.wrappedValue = false
        }

        func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
            searchBar.resignFirstResponder()
        }
    }

    final class Field: UIView, UIGestureRecognizerDelegate {
        // Scroll positioning owns the outer frame. The child moves
        // independently, so a layout pass cannot reset a held pull.
        let movingContent = UIView()
        let searchBar = UISearchBar()
        let pullObserver = ResearchSearchPullToDismiss.Observer()
        let cancelButton = UIButton(configuration: .glass())
        var onCancel: (() -> Void)?
        private(set) var isPresented = false
        private var isPinned = false
        /// Inline search uses the page's panel material. Floating above the
        /// page, whether pinned or editing, uses the system's liquid glass.
        private let panel = UIHostingController(rootView: SearchPanel())
        /// Brightens the resting panel under a finger.
        private let pressHighlight = UIView()
        private let press = UILongPressGestureRecognizer()
        private let glass = UIVisualEffectView()

        override init(frame: CGRect) {
            super.init(frame: frame)
            addGestureRecognizer(pullObserver)
            pullObserver.isEnabled = false
            addSubview(movingContent)
            panel.view.backgroundColor = .clear
            panel.safeAreaRegions = []
            glass.accessibilityIdentifier = "research.search.glass"
            for surface in [panel.view!, glass, pressHighlight] {
                surface.isUserInteractionEnabled = false
                surface.clipsToBounds = true
                movingContent.addSubview(surface)
            }
            pressHighlight.alpha = 0
            // Watches the touch without taking it from the text field.
            press.minimumPressDuration = 0
            press.cancelsTouchesInView = false
            press.delaysTouchesBegan = false
            press.delegate = self
            press.addTarget(self, action: #selector(pressChanged))
            addGestureRecognizer(press)
            searchBar.searchBarStyle = .minimal
            searchBar.autocapitalizationType = .none
            searchBar.autocorrectionType = .no
            searchBar.accessibilityIdentifier = "research.search.bar"
            searchBar.setImage(UIImage(named: "SearchIcon"), for: .search, state: .normal)
            searchBar.setSearchFieldBackgroundImage(UIImage(), for: .normal)
            movingContent.addSubview(searchBar)
            cancelButton.setImage(UIImage(systemName: "xmark"), for: .normal)
            cancelButton.tintColor = .label
            cancelButton.accessibilityIdentifier = "research.search.cancel"
            cancelButton.accessibilityLabel = L10n.text("取消")
            cancelButton.isHidden = true
            cancelButton.alpha = 0
            cancelButton.transform = Self.cancelHiddenTransform
            cancelButton.addAction(UIAction { [weak self] _ in self?.onCancel?() }, for: .touchUpInside)
            movingContent.addSubview(cancelButton)
            applyPressStyle()
            registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
                (self: Self, _: UITraitCollection) in self.applyPressStyle()
            }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        private static let cancelHiddenTransform = CGAffineTransform(translationX: 18, y: 0).scaledBy(x: 0.4, y: 0.4)

        override func layoutSubviews() {
            super.layoutSubviews()
            movingContent.bounds = bounds
            movingContent.center = CGPoint(x: bounds.midX, y: bounds.midY)
            let cancelWidth: CGFloat = isPresented ? 52 : 0
            searchBar.frame = CGRect(x: -8, y: -6, width: bounds.width + 16 - cancelWidth, height: bounds.height + 12)
            // The transform scales the button in place; keep its frame
            // assignment off the transformed geometry.
            cancelButton.bounds = CGRect(x: 0, y: 0, width: 44, height: 44)
            cancelButton.center = CGPoint(x: bounds.width - 22, y: 22)
            searchBar.layoutIfNeeded()
            let textField = searchBar.searchTextField
            let surfaceFrame = textField.convert(textField.bounds, to: movingContent)
            for surface in [panel.view!, glass, pressHighlight] {
                surface.frame = surfaceFrame
                surface.layer.cornerRadius = surfaceFrame.height / 2
            }
        }

        private func applyPressStyle() {
            let dark = traitCollection.userInterfaceStyle == .dark
            pressHighlight.backgroundColor = UIColor.white.withAlphaComponent(dark ? 0.08 : 0.6)
        }

        @objc private func pressChanged() {
            let pressed = !isPresented && (press.state == .began || press.state == .changed)
                && bounds.contains(press.location(in: self))
            guard (pressHighlight.alpha > 0.5) != pressed else { return }
            let reduceMotion = UIAccessibility.isReduceMotionEnabled
            UIView.animate(withDuration: reduceMotion ? 0 : (pressed ? 0.12 : 0.25), delay: 0,
                           options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.pressHighlight.alpha = pressed ? 1 : 0
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        func setPinned(_ pinned: Bool) {
            guard isPinned != pinned else { return }
            isPinned = pinned
            UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.2,
                           delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.updateSurface()
            }
        }

        private func updateSurface() {
            let usesGlass = isPresented || isPinned
            guard usesGlass != (glass.effect != nil) else { return }
            // Keep the live effect when editing begins or ends while pinned.
            // Animate the effect itself rather than fading its view's alpha.
            glass.effect = usesGlass ? UIGlassEffect(style: .regular) : nil
            panel.view.alpha = usesGlass ? 0 : 1
        }

        func setPresented(_ presented: Bool, animated: Bool = false) {
            pullObserver.isEnabled = presented
            guard isPresented != presented else { return }
            isPresented = presented
            if !presented { searchBar.resignFirstResponder() }
            cancelButton.isHidden = false
            let changes = {
                self.updateSurface()
                self.pressHighlight.alpha = 0
                self.cancelButton.alpha = presented ? 1 : 0
                self.cancelButton.transform = presented ? .identity : Self.cancelHiddenTransform
                self.setNeedsLayout()
                self.layoutIfNeeded()
            }
            let finish = { (_: Bool) in
                if self.isPresented == presented { self.cancelButton.isHidden = !presented }
            }
            guard animated else {
                UIView.performWithoutAnimation(changes)
                finish(true)
                return
            }
            UIView.animate(withDuration: ResearchToolbarSearch.flightDuration, delay: 0,
                           usingSpringWithDamping: 0.86, initialSpringVelocity: 0,
                           options: [.beginFromCurrentState, .allowUserInteraction],
                           animations: changes, completion: finish)
        }
    }

    /// `ContentPanelMaterial` as a capsule, following the reader's
    /// transparency and contrast settings like every other panel.
    struct SearchPanel: View {
        @Environment(\.colorScheme) private var colorScheme
        @Environment(\.colorSchemeContrast) private var contrast
        @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

        var body: some View {
            ContentPanelMaterial(colorScheme: colorScheme, isOpaque: reduceTransparency,
                                 increasedContrast: contrast == .increased, cornerRadius: 999)
                .ignoresSafeArea()
        }
    }

    /// Opening and closing share one spring for the flight, the glass and
    /// the cancel button.
    static let flightDuration: TimeInterval = 0.5
}

/// One system blur over the still-mounted dashboard. No full-page raster blur
/// or opaque results-page fill is needed while the query is empty.
struct ResearchSearchBackdrop: UIViewRepresentable {
    var reduceTransparency: Bool

    func makeUIView(context: Context) -> UIVisualEffectView {
        let view = UIVisualEffectView()
        view.accessibilityIdentifier = "research.search.backdrop"
        return view
    }

    func updateUIView(_ view: UIVisualEffectView, context: Context) {
        if reduceTransparency {
            if view.effect != nil { view.effect = nil }
        } else if view.effect == nil {
            view.effect = UIBlurEffect(style: .systemUltraThinMaterial)
        }
        view.backgroundColor = reduceTransparency ? UIColor(SettingsTemplate.pageBackground) : .clear
    }
}

/// Results sit over the still-mounted dashboard, below the system search bar.
struct ResearchMarketSearchView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage(ChartInteractionStyle.hapticsPreferenceKey) private var hapticsEnabled = true
    let holdings: [Holding]
    let onSelect: (MarketSecurityResult) -> Void
    let query: String
    let onDismiss: () -> Void
    var pullObserver: ResearchSearchPullToDismiss.Observer? = nil
    var onPull: (CGFloat) -> Void = { _ in }
    var onPullCancel: () -> Void = {}
    var onPullDismiss: (() -> Void)? = nil
    /// Pushes the results below the field. Only the content moves: the
    /// backdrop keeps touching the top edge so it blurs under the bar too.
    var contentTopInset: CGFloat = 0
    @State private var searchResults: [MarketSecurityResult] = []
    /// The query `searchResults` answer, so a stale list is not mistaken
    /// for an empty one while the next search runs.
    @State private var searchedQuery = ""
    /// Whether the directory has more matches than `searchResults` shows.
    @State private var hasMoreSearchResults = false
    /// A query the reader asked to see more of, and how many rows it shows.
    /// Any other query starts from one page, so a keystroke never builds
    /// more rows than a screen holds.
    @State private var expandedSearch: ExpandedSearch?
    private struct ExpandedSearch: Equatable { let query: String; let limit: Int }
    private static let searchPageSize = 15
    private static let searchPageStep = 25
    private var searchLimit: Int {
        expandedSearch.flatMap { $0.query == searchText ? $0.limit : nil } ?? Self.searchPageSize
    }

    private var searchText: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Group {
            if searchText.isEmpty {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onDismiss)
            } else {
                SettingsPage(bottomInset: 20, pageBackground: .clear) {
                    if searchedQuery == searchText {
                        searchResultsSection
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.top, 20)
                    }
                }
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .padding(.top, contentTopInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .gesture(ResearchSearchPullToDismiss(hapticsEnabled: hapticsEnabled,
                                            onDismiss: onPullDismiss ?? onDismiss,
                                            onPull: onPull, onPullCancel: onPullCancel, observer: pullObserver))
        .background {
            ResearchSearchBackdrop(reduceTransparency: reduceTransparency)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape, onDismiss)
        .task(id: "\(searchLimit)|\(searchText)") { await searchMarket() }
    }

    private var searchResultsSection: some View {
        Group {
            SettingsSection(L10n.text("证券")) {
                if searchResults.isEmpty {
                    SettingsRowContainer {
                        Text(L10n.text("没有找到匹配的证券"))
                            .appText(.subheading)
                            .foregroundStyle(SettingsTemplate.secondaryText)
                    }
                } else {
                    ForEach(searchResults) { result in
                        Button { onSelect(result) } label: {
                            SettingsRowContainer { searchRow(result) }
                        }
                        .buttonStyle(SettingsRowButtonStyle())
                        .accessibilityIdentifier("research.search.\(result.ticker)")
                    }
                    if hasMoreSearchResults {
                        Button {
                            expandedSearch = ExpandedSearch(query: searchText,
                                                            limit: searchLimit + Self.searchPageStep)
                        } label: {
                            SettingsRowContainer {
                                Text(L10n.text("显示更多"))
                                    .appText(.subheading)
                                    .foregroundStyle(SettingsTemplate.secondaryText)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .buttonStyle(SettingsRowButtonStyle())
                        .accessibilityIdentifier("research.search.more")
                    }
                }
            }
        }
    }

    private func heldHolding(_ ticker: String) -> Holding? {
        holdings.first { $0.ticker.caseInsensitiveCompare(ticker) == .orderedSame }
    }

    private func searchRow(_ result: MarketSecurityResult) -> some View {
        let held = heldHolding(result.ticker)
        return HStack(spacing: SettingsTemplate.iconSpacing) {
            AssetLogo(ticker: result.ticker, logoSymbol: held?.logoSymbol ?? result.ticker, size: SettingsTemplate.iconSize)
            VStack(alignment: .leading, spacing: SettingsTemplate.subtitleSpacing) {
                HStack(spacing: 6) {
                    Text(result.ticker)
                        .appText(.subheading)
                        .lineLimit(1)
                    if held != nil {
                        Text(L10n.text("已持有"))
                            .appText(.caption, weight: .semibold)
                            .foregroundStyle(SettingsTemplate.secondaryText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(.primary.opacity(0.07)))
                    }
                }
                Text(held?.shortName ?? CompanyNameCatalog.displayName(ticker: result.ticker, fallback: result.name))
                    .appText(.label)
                    .foregroundStyle(SettingsTemplate.secondaryText)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                if dynamicTypeSize.isAccessibilitySize {
                    Text(result.venue)
                        .appText(.label)
                        .foregroundStyle(SettingsTemplate.secondaryText)
                }
            }
            Spacer(minLength: 8)
            if !dynamicTypeSize.isAccessibilitySize {
                Text(result.venue)
                    .appText(.label)
                    .foregroundStyle(SettingsTemplate.secondaryText)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            SettingsChevron()
        }
        .contentShape(Rectangle())
    }

    /// Off the main thread: the directory holds some twenty thousand
    /// securities, and its first use decodes it.
    @MainActor private func searchMarket() async {
        let text = searchText
        guard !text.isEmpty else {
            searchResults = []
            searchedQuery = ""
            hasMoreSearchResults = false
            expandedSearch = nil
            return
        }
        let limit = searchLimit
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled else { return }
        let worker = Task.detached(priority: .userInitiated) { () -> [MarketSecurityResult] in
            guard let catalog = try? CompanyReferenceCatalog.bundled.get() else { return [] }
            // One past the page says whether "more" has anything to show.
            return MarketSecurityResult.search(text, in: catalog, limit: limit + 1,
                                               shouldCancel: { Task.isCancelled })
        }
        let results = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard !Task.isCancelled, text == searchText, limit == searchLimit else { return }
        let applying = CompanyReferenceCatalog.searchSignposter.beginInterval("search.apply")
        searchResults = Array(results.prefix(limit))
        hasMoreSearchResults = results.count > limit
        searchedQuery = text
        CompanyReferenceCatalog.searchSignposter.endInterval("search.apply", applying)
    }

}

/// Observe the pull without taking touches from result buttons or the native
/// scroll view. A gesture must start at the top; scrolling back through results
/// cannot turn into a dismissal halfway through the same drag.
struct ResearchSearchPullToDismiss: UIGestureRecognizerRepresentable {
    let hapticsEnabled: Bool
    let onDismiss: () -> Void
    let onPull: (CGFloat) -> Void
    let onPullCancel: () -> Void
    let observer: Observer

    init(hapticsEnabled: Bool, onDismiss: @escaping () -> Void,
         onPull: @escaping (CGFloat) -> Void = { _ in }, onPullCancel: @escaping () -> Void = {},
         observer: Observer? = nil) {
        self.hapticsEnabled = hapticsEnabled
        self.onDismiss = onDismiss
        self.onPull = onPull
        self.onPullCancel = onPullCancel
        self.observer = observer ?? Observer()
        self.observer.hapticsEnabled = hapticsEnabled
        self.observer.onDismiss = onDismiss
        self.observer.onPull = onPull
        self.observer.onPullCancel = onPullCancel
    }

    func makeUIGestureRecognizer(context: Context) -> Observer {
        updateUIGestureRecognizer(observer, context: context)
        return observer
    }

    func updateUIGestureRecognizer(_ observer: Observer, context: Context) {
        observer.hapticsEnabled = hapticsEnabled
        observer.onDismiss = onDismiss
        observer.onPull = onPull
        observer.onPullCancel = onPullCancel
    }

    final class Observer: UIGestureRecognizer {
        static let threshold = ResearchSearchPullGeometry.threshold
        var hapticsEnabled = true
        var onDismiss: () -> Void = {}
        var onPull: (CGFloat) -> Void = { _ in }
        var onPullCancel: () -> Void = {}
        private(set) var isArmed = false
        private var clicked = false
        private var feedback: UIImpactFeedbackGenerator?
        private var start: CGPoint?

        init(feedback: UIImpactFeedbackGenerator? = nil) {
            self.feedback = feedback
            super.init(target: nil, action: nil)
            name = "research.search.pull-to-dismiss"
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            guard touches.count == 1, start == nil, let touch = touches.first else {
                endTouch(cancelled: true)
                return
            }
            beginTouch(at: touch.location(in: view?.window), in: touch.view)
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            guard let touch = touches.first else { return }
            moveTouch(to: touch.location(in: view?.window))
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { endTouch() }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { endTouch(cancelled: true) }

        func beginTouch(at point: CGPoint, in touchedView: UIView?) {
            var ancestor = touchedView
            while let candidate = ancestor {
                if let scroll = candidate as? UIScrollView, scroll.isScrollEnabled {
                    guard scroll.contentOffset.y + scroll.adjustedContentInset.top <= 1,
                          !scroll.isDecelerating else { endTouch(cancelled: true); return }
                    break
                }
                ancestor = candidate.superview
            }
            start = point
            isArmed = false
            clicked = false
            if hapticsEnabled { impactFeedback.prepare() }
        }

        func moveTouch(to point: CGPoint) {
            guard let start else { return }
            let dx = point.x - start.x
            let dy = point.y - start.y
            // Once the reader scrolls up or sideways, leave that gesture alone.
            if dy < -10 || (abs(dx) > 10 && abs(dx) > dy) { endTouch(cancelled: true); return }
            onPull(max(0, dy))
            isArmed = dy >= Self.threshold && dy > abs(dx) * 1.3
            if isArmed && !clicked {
                clicked = true
                if hapticsEnabled { impactFeedback.impactOccurred(intensity: 0.7) }
            }
        }

        private var impactFeedback: UIImpactFeedbackGenerator {
            if let feedback { return feedback }
            let generator = UIImpactFeedbackGenerator(style: .rigid)
            feedback = generator
            return generator
        }

        func endTouch(cancelled: Bool = false) {
            let wasTracking = start != nil
            let shouldDismiss = wasTracking && isArmed && !cancelled
            start = nil
            isArmed = false
            clicked = false
            state = .failed
            if shouldDismiss { onDismiss() }
            else if wasTracking { onPullCancel() }
        }

        override func reset() {
            super.reset()
            start = nil
            isArmed = false
            clicked = false
        }

        override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
        override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    }
}
