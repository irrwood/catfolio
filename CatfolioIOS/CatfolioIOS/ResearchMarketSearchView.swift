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
                    .overlay {
                        ResearchToolbarSearch(query: $query, isPresented: $isPresented,
                                              motion: motion, hapticsEnabled: hapticsEnabled,
                                              onPullDismiss: dismissAfterPull, placement: placement,
                                              onResultsInset: { resultsTopInset = $0 })
                            // The field travels inside this page overlay
                            // during navigation, above the dashboard's surface.
                            .allowsHitTesting(false)
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
        var canReceiveTouches: () -> Bool = { true }
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

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            // Navigation can change before the next placement/layout callback.
            guard canReceiveTouches() else { return nil }
            return super.hitTest(point, with: event)
        }

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
    var isSidebar = false
    @State var searchModel = SecuritySearchModel()

    private var request: SecuritySearchModel.Request {
        searchModel.request(query: query, holdings: holdings)
    }
    private var searchText: String { request.query }
    private var displayedResults: [MarketSecurityResult] { searchModel.results(for: request) }

    var body: some View {
        Group {
            if isSidebar { sidebarResults }
            else { overlayResults }
        }
        .task(id: request) { await searchModel.search(request) }
        .task(id: searchModel.quoteRequest(for: request)) {
            await searchModel.loadQuotes(searchModel.quoteRequest(for: request))
        }
    }

    private var sidebarResults: some View {
        Section {
            ForEach(displayedResults) { result in
                NavigationLink(value: WorkspaceSelection.security(result)) {
                    let entry = WatchlistEntry(holding: result.resolvedHolding(in: holdings))
                    SidebarSecuritySearchRow(result: result, entry: entry,
                        quote: searchModel.quote(for: result, holdings: holdings),
                        isHeld: heldHolding(result.ticker) != nil)
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                .listRowSeparator(.visible)
                .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                .accessibilityIdentifier("workspace.search.\(result.ticker)")
            }
            if searchModel.searchedQuery != searchText {
                ProgressView().frame(maxWidth: .infinity)
            } else if displayedResults.isEmpty {
                Text(L10n.text("没有找到匹配的证券"))
                    .foregroundStyle(.secondary)
            }
            if searchModel.searchedQuery == searchText && searchModel.hasMore {
                Button(L10n.text("显示更多")) {
                    searchModel.loadMore(for: searchText)
                }
                .accessibilityIdentifier("workspace.search.more")
            }
        }
    }

    private var overlayResults: some View {
        Group {
            if searchText.isEmpty {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onDismiss)
            } else {
                SettingsPage(bottomInset: 20, pageBackground: .clear) {
                    if searchModel.searchedQuery == searchText {
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
    }

    private var searchResultsSection: some View {
        LazyVStack(spacing: 0) {
            if displayedResults.isEmpty {
                Text(L10n.text("没有找到匹配的证券"))
                    .appText(.subheading)
                    .foregroundStyle(SettingsTemplate.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 20)
                    .padding(.horizontal, SettingsTemplate.pageInset)
            } else {
                ForEach(displayedResults) { result in
                    Button { onSelect(result) } label: {
                        searchRow(result)
                            .padding(.vertical, SettingsTemplate.rowVerticalPadding)
                            .padding(.horizontal, SettingsTemplate.pageInset)
                            .frame(maxWidth: .infinity, minHeight: SettingsTemplate.rowMinHeight,
                                   alignment: .leading)
                            .contentShape(Rectangle())
                            .researchLayoutFrame("phone-search.button.\(result.id)")
                    }
                    .buttonStyle(SettingsRowButtonStyle())
                    .accessibilityIdentifier("research.search.\(result.ticker)")
                    ContentPanelSeparator()
                        .padding(.horizontal, SettingsTemplate.pageInset)
                }
                if searchModel.hasMore {
                    Button { searchModel.loadMore(for: searchText) } label: {
                        Text(L10n.text("显示更多"))
                            .appText(.subheading)
                            .foregroundStyle(SettingsTemplate.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, SettingsTemplate.rowVerticalPadding)
                            .padding(.horizontal, SettingsTemplate.pageInset)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(SettingsRowButtonStyle())
                    .accessibilityIdentifier("research.search.more")
                }
            }
        }
        // The page supplies an inset; put it inside each button so its
        // pressed background and hit area span the full viewport.
        .padding(.horizontal, -SettingsTemplate.pageInset)
    }

    private func heldHolding(_ ticker: String) -> Holding? {
        holdings.first { $0.ticker.caseInsensitiveCompare(ticker) == .orderedSame }
    }

    private func searchRow(_ result: MarketSecurityResult) -> some View {
        PhoneSecuritySearchRow(result: result,
            entry: SecuritySearchModel.entry(for: result, holdings: holdings),
            quote: searchModel.quote(for: result, holdings: holdings),
            isHeld: heldHolding(result.ticker) != nil)
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
