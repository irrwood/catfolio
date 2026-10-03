import SwiftUI
import UIKit

/// UIKit owns the continuous horizontal offset. SwiftUI only receives a
/// selection after settling, so dragging never diffs or rebuilds the ledger.
struct HistoryPagingView: UIViewControllerRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var selection: HistoryCategory
    /// The tabs, in order. Fixed for the controller's life: a different set
    /// is a different pager (the caller keys the view by it).
    var categories: [HistoryCategory] = HistoryCategory.allCases
    var contentID: AnyHashable
    var page: (HistoryCategory) -> AnyView

    final class Coordinator {
        var selection: HistoryCategory
        var contentID: AnyHashable?
        var environmentID: String?
        init(selection: HistoryCategory) { self.selection = selection }
    }

    func makeCoordinator() -> Coordinator { Coordinator(selection: selection) }

    func makeUIViewController(context: Context) -> HistoryPagingController {
        let controller = HistoryPagingController(selection: selection, categories: categories)
        updateUIViewController(controller, context: context)
        return controller
    }

    func updateUIViewController(_ controller: HistoryPagingController, context: Context) {
        controller.onSelection = {
            context.coordinator.selection = $0
            if selection != $0 { selection = $0 }
        }
        controller.reduceMotion = reduceMotion
        let environment = context.environment
        let environmentID = "\(environment.locale.identifier)|\(environment.colorScheme)|\(environment.dynamicTypeSize)|\(environment.accessibilityReduceMotion)|\(environment.accessibilityReduceTransparency)|\(String(describing: environment.legibilityWeight))"
        // Settling a swipe changes selection, not the ledger. Replacing every
        // hosting root here made every category diff its List after each swipe.
        if context.coordinator.contentID != contentID || context.coordinator.environmentID != environmentID {
            context.coordinator.contentID = contentID
            context.coordinator.environmentID = environmentID
            let height = HistoryCategoryBar.preferredHeight
            controller.updatePages(controller.categories.map {
                AnyView(page($0)
                    .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: height) }
                    .environment(\.self, environment))
            })
        }
        if context.coordinator.selection != selection {
            context.coordinator.selection = selection
            controller.select(selection, animated: !reduceMotion)
        }
    }
}

final class HistoryPagingController: UIViewController, UIScrollViewDelegate {
    let pager = HistoryPagingScrollView()
    let categories: [HistoryCategory]
    let categoryBar: HistoryCategoryBar
    let headerMaterial = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
    private(set) var selection: HistoryCategory
    var onSelection: ((HistoryCategory) -> Void)?
    var reduceMotion = false
    private var hosts: [UIHostingController<AnyView>] = []
    /// The latest content for every page, and the pages showing it. The rest
    /// hold an empty placeholder until they are near: building all five
    /// lists at once is what caught the push animation.
    private var pages: [AnyView] = []
    private var livePages: Set<Int> = []
    private var wakeTask: Task<Void, Never>?
    private var lists: [Int: UIScrollView] = [:]
    private var observations: [Int: NSKeyValueObservation] = [:]
    private var laidOutSize = CGSize.zero
    private var isLayingOutPages = false
    private var requestedIndex: Int?
    private var lastHeaderPosition: HistoryHeaderPosition?
    /// Fades the header material out over its last stretch, so content
    /// scrolling up under the category bar dissolves into it instead of
    /// meeting a hard line along the bar's bottom edge.
    ///
    /// Done by hand here, not by registering the bar as a scroll-edge element:
    /// that stretches the system's blur from the top of the screen down to the
    /// bar, and the large title sitting between the two was blurred with it.
    private let headerFade = CAGradientLayer()
    /// By night the blur is darkened to black rather than the system's grey.
    private let headerShade = UIView()

    private var isDark: Bool { traitCollection.userInterfaceStyle == .dark }

    private func applyHeaderAppearance() {
        headerMaterial.effect = UIBlurEffect(style: isDark ? .systemUltraThinMaterialDark : .systemChromeMaterial)
        headerShade.backgroundColor = isDark ? UIColor.black.withAlphaComponent(0.62) : .clear
        headerShade.frame = headerMaterial.contentView.bounds
    }

    init(selection: HistoryCategory, categories: [HistoryCategory] = HistoryCategory.allCases) {
        let categories = categories.isEmpty ? [.all] : categories
        self.categories = categories
        self.selection = categories.contains(selection) ? selection : categories[0]
        categoryBar = HistoryCategoryBar(categories: categories)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// How far past the category bar the material runs while it fades out.
    static let headerFadeLength: CGFloat = 28

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        pager.delegate = self
        pager.isPagingEnabled = true
        pager.isDirectionalLockEnabled = true
        pager.alwaysBounceHorizontal = true
        pager.showsHorizontalScrollIndicator = false
        pager.showsVerticalScrollIndicator = false
        pager.contentInsetAdjustmentBehavior = .never
        pager.scrollsToTop = false
        pager.accessibilityIdentifier = "history-pager"
        view.addSubview(pager)
        headerMaterial.alpha = 0
        headerMaterial.isUserInteractionEnabled = false
        headerMaterial.accessibilityIdentifier = "history-header-material"
        headerFade.colors = [UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]
        headerMaterial.layer.mask = headerFade
        headerShade.isUserInteractionEnabled = false
        headerShade.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        headerMaterial.contentView.addSubview(headerShade)
        applyHeaderAppearance()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (controller: HistoryPagingController, _: UITraitCollection) in
            controller.applyHeaderAppearance()
            controller.view.setNeedsLayout()
        }
        view.addSubview(headerMaterial)
        view.addSubview(categoryBar)
        categoryBar.onSelect = { [weak self] index in
            guard let self else { return }
            self.select(self.categories[index], animated: !self.reduceMotion)
        }
    }

    func updatePages(_ pages: [AnyView]) {
        loadViewIfNeeded()
        self.pages = pages
        // Only the page being opened is built during the push; its
        // neighbours follow as soon as it has landed.
        livePages.insert(selectedIndex)
        for (index, page) in pages.enumerated() {
            if hosts.indices.contains(index) {
                if livePages.contains(index) { hosts[index].rootView = page }
            } else {
                let host = UIHostingController(rootView: livePages.contains(index) ? page : AnyView(Color.clear))
                host.view.backgroundColor = .clear
                addChild(host)
                pager.addSubview(host.view)
                host.didMove(toParent: self)
                hosts.append(host)
            }
        }
        categoryBar.updateTitles()
        view.setNeedsLayout()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !isLayingOutPages else { return }
        isLayingOutPages = true
        defer { isLayingOutPages = false }
        let size = view.bounds.size
        let oldWidth = laidOutSize.width
        let progress = oldWidth > 0 ? pager.contentOffset.x / oldWidth : CGFloat(selectedIndex)
        pager.frame = view.bounds
        for (index, host) in hosts.enumerated() {
            let frame = CGRect(x: CGFloat(index) * size.width, y: 0,
                               width: size.width, height: size.height)
            if host.view.frame != frame { host.view.frame = frame }
            // Only force layout for content actually crossing the viewport.
            // Offscreen hosting controllers otherwise remeasure entire Lists.
            if livePages.contains(index), abs(CGFloat(index) - pageProgress) < 1 {
                host.view.layoutIfNeeded()
                connectList(at: index)
            }
        }
        pager.contentSize = CGSize(width: size.width * CGFloat(hosts.count), height: size.height)
        if oldWidth != size.width {
            // Rotation preserves the page, including an interactive position.
            pager.contentOffset.x = progress * size.width
        }
        laidOutSize = size
        categoryBar.transform = .identity
        lastHeaderPosition = nil
        categoryBar.frame = CGRect(x: 0, y: view.safeAreaInsets.top, width: size.width,
                                   height: HistoryCategoryBar.preferredHeight)
        // Extend the same material to the physical top edge, underneath (not
        // over) the navigation controller's native title and glass buttons.
        let top = min(0, view.window.map { view.convert($0.bounds, from: $0).minY } ?? 0)
        // By night the blur stops short, fading out by the middle of the
        // category chips, so the black reads as a soft edge, not a band.
        let materialBottom = isDark ? categoryBar.frame.midY : categoryBar.frame.maxY + Self.headerFadeLength
        headerMaterial.frame = CGRect(x: 0, y: top, width: size.width, height: materialBottom - top)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        headerFade.frame = headerMaterial.bounds
        let solidEnd = max(0, headerMaterial.bounds.height - Self.headerFadeLength)
            / max(1, headerMaterial.bounds.height)
        headerFade.locations = [0, NSNumber(value: Double(solidEnd)), 1]
        CATransaction.commit()
        updateHeader()
        categoryBar.setProgress(pageProgress)
        categoryBar.setSelection(selectedIndex)
        observeSelectedList()
    }

    /// Nominate the vertical list before the navigation bar first lays out.
    ///
    /// Without this the bar looks for a scroll view of its own during the push
    /// and finds the horizontal pager, which sits at offset 0 with no top
    /// inset and so reads as "already scrolled" — the large title collapsed
    /// before the page had been seen, then snapped back the first time the
    /// reader dragged down. Laying out here is what gives `connectList` a list
    /// to find this early.
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        view.layoutIfNeeded()
        observeSelectedList()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let back = navigationController?.interactivePopGestureRecognizer {
            pager.panGestureRecognizer.require(toFail: back)
        }
        observeSelectedList()
        scheduleNeighbourPreparation()
    }

    private func scheduleNeighbourPreparation() {
        wakeTask?.cancel()
        wakeTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(160)) } catch { return }
            while let self, !Task.isCancelled {
                let busy = self.requestedIndex != nil || self.pager.isTracking || self.pager.isDecelerating
                    || self.lists.values.contains { $0.isTracking || $0.isDecelerating || $0.isDragging }
                if !busy {
                    // Include layout, not just rootView assignment. Otherwise
                    // SwiftUI postpones the expensive first layout until dragging.
                    self.preparePages(self.neighbourhood(of: self.selectedIndex))
                    return
                }
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        wakeTask?.cancel()
    }

    private func neighbourhood(of index: Int) -> Set<Int> {
        Set([index - 1, index, index + 1].filter { categories.indices.contains($0) })
    }

    /// Gives placeholder pages their content.
    private func wake(_ indices: Set<Int>) {
        let asleep = indices.subtracting(livePages).filter { pages.indices.contains($0) && hosts.indices.contains($0) }
        guard !asleep.isEmpty else { return }
        for index in asleep { hosts[index].rootView = pages[index] }
        livePages.formUnion(asleep)
        view.setNeedsLayout()
    }

    private func preparePages(_ indices: Set<Int>) {
        wake(indices)
        view.layoutIfNeeded()
        for index in indices.sorted() where hosts.indices.contains(index) {
            hosts[index].view.layoutIfNeeded()
            connectList(at: index)
        }
    }

    private var selectedIndex: Int { categories.firstIndex(of: selection) ?? 0 }
    var pageProgress: CGFloat {
        guard pager.bounds.width > 0 else { return CGFloat(selectedIndex) }
        return min(CGFloat(hosts.count - 1), max(0, pager.contentOffset.x / pager.bounds.width))
    }

    func select(_ category: HistoryCategory, animated: Bool) {
        let index = categories.firstIndex(of: category) ?? 0
        preparePages(neighbourhood(of: index))
        let target = CGPoint(x: CGFloat(index) * pager.bounds.width, y: 0)
        // Tapping the current tab during deceleration should return to it,
        // even though the swipe has not committed a different selection yet.
        guard category != selection || requestedIndex != nil
            || abs(pager.contentOffset.x - target.x) > 0.5 else { return }
        guard requestedIndex != index else { return }
        requestedIndex = index
        guard pager.bounds.width > 0 else {
            selection = category
            requestedIndex = nil
            return
        }
        let shouldAnimate = animated && !UIAccessibility.isReduceMotionEnabled
            && abs(pager.contentOffset.x - target.x) > 0.5
        // Native scrolling can be interrupted by another tap or a new drag.
        pager.setContentOffset(target, animated: shouldAnimate)
        if !shouldAnimate { finishPaging() }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isLayingOutPages else { return }
        categoryBar.setProgress(pageProgress)
        updateHeader()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        requestedIndex = nil
        wakeTask?.cancel()
        // Covers a gesture begun before idle preparation has run. No page is
        // created later at the half-way point or during deceleration.
        preparePages(neighbourhood(of: Int(pageProgress.rounded())))
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { finishPaging() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { finishPaging() }
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { finishPaging() }

    private func finishPaging() {
        guard !hosts.isEmpty else { return }
        let index = min(hosts.count - 1, max(0, Int(pageProgress.rounded())))
        requestedIndex = nil
        selection = categories[index]
        for (pageIndex, host) in hosts.enumerated() {
            host.view.accessibilityElementsHidden = pageIndex != index
        }
        categoryBar.setProgress(CGFloat(index))
        categoryBar.setSelection(index)
        observeSelectedList()
        updateHeader()
        onSelection?(selection)
        scheduleNeighbourPreparation()
    }

    private func connectList(at index: Int) {
        guard lists[index] == nil, let list = verticalScrollView(in: hosts[index].view) else { return }
        lists[index] = list
        // These lists are SwiftUI's, but they live in hosting controllers
        // under a UIKit pager, so the style is set on the scroll view itself
        // rather than trusted to reach it through the environment.
        // The pager owns one continuous material for every category. A
        // second native edge effect made each List's header look different.
        if #available(iOS 26.0, *) { list.topEdgeEffect.isHidden = true }
        list.scrollsToTop = index == selectedIndex
        hosts[index].view.accessibilityElementsHidden = index != selectedIndex
        observations[index] = list.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, abs(CGFloat(index) - self.pageProgress) < 1 else { return }
                self.updateHeader()
            }
        }
    }

    private func verticalScrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.verticalScrollView(in: $0) }.first
    }

    private func observeSelectedList() {
        guard let list = lists[selectedIndex] else { return }
        for (index, other) in lists { other.scrollsToTop = index == selectedIndex }

        // Explicitly nominate the vertical list, never the horizontal pager,
        // for the native large title and scroll-edge appearance.
        var controller: UIViewController? = self
        while let current = controller, !(current is UINavigationController) {
            current.setContentScrollView(list, for: .top)
            controller = current.parent
        }
    }

    private func updateHeader() {
        let progress = pageProgress
        let lower = Int(progress.rounded(.down))
        let upper = min(hosts.count - 1, lower + 1)
        func position(at index: Int) -> HistoryHeaderPosition {
            guard let list = lists[index] else { return HistoryHeaderPosition(scrollOffset: 0) }
            return HistoryHeaderPosition(scrollOffset: list.contentOffset.y + list.adjustedContentInset.top)
        }
        let position = HistoryHeaderPosition.interpolated(
            from: position(at: lower), to: position(at: upper), fraction: progress - CGFloat(lower))
        guard position != lastHeaderPosition else { return }
        lastHeaderPosition = position
        categoryBar.transform = CGAffineTransform(translationX: 0, y: position.pullDown)
        headerMaterial.alpha = position.materialOpacity
    }
}

final class HistoryPagingScrollView: UIScrollView {
    static func shouldBeginPan(startX: CGFloat, velocity: CGPoint) -> Bool {
        startX > 32 && abs(velocity.x) > abs(velocity.y) * 1.25
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === panGestureRecognizer {
            let start = panGestureRecognizer.location(in: self).x - bounds.minX
                - panGestureRecognizer.translation(in: self).x
            guard Self.shouldBeginPan(startX: start, velocity: panGestureRecognizer.velocity(in: self)) else {
                return false
            }
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
}

/// Equal-size category slots share typography and a single moving capsule.
/// Long translations and Dynamic Type scroll rather than changing each slot's shape.
final class HistoryCategoryBar: UIView {
    let scrollView = UIScrollView()
    let pill = UIView()
    private(set) var buttons: [UIButton] = []
    var onSelect: ((Int) -> Void)?
    private var progress: CGFloat = 0
    static var preferredHeight: CGFloat {
        SettingsTemplate.segmentBarHeight(
            forLineHeight: UIFont.preferredFont(forTextStyle: .body).lineHeight
        )
    }

    let categories: [HistoryCategory]

    init(categories: [HistoryCategory] = HistoryCategory.allCases) {
        self.categories = categories
        super.init(frame: .zero)
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.scrollsToTop = false
        scrollView.contentInsetAdjustmentBehavior = .never
        addSubview(scrollView)
        pill.backgroundColor = SettingsTemplate.uiCard
        pill.layer.cornerCurve = .continuous
        pill.isUserInteractionEnabled = false
        pill.accessibilityIdentifier = "history-category-pill"
        scrollView.addSubview(pill)
        for (index, category) in categories.enumerated() {
            let button = UIButton(type: .custom)
            button.accessibilityIdentifier = "history-category-\(category.rawValue.lowercased())"
            button.addAction(UIAction { [weak self] _ in self?.onSelect?(index) }, for: .touchUpInside)
            scrollView.addSubview(button)
            buttons.append(button)
        }
        updateTitles()
        setSelection(0)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updateTitles() {
        let base = UIFont.preferredFont(forTextStyle: .body)
        let descriptor = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
        let font = UIFont(descriptor: descriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.medium]
        ]), size: 0)
        for (index, button) in buttons.enumerated() {
            button.setTitle(L10n.label(categories[index].rawValue), for: .normal)
            button.titleLabel?.font = font
            button.titleLabel?.adjustsFontForContentSizeCategory = true
            button.titleLabel?.numberOfLines = 1
            button.titleLabel?.textAlignment = .center
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        let inset = SettingsTemplate.pageInset
        let chipPadding = SettingsTemplate.segmentHorizontalPadding * 2
        let barPadding = SettingsTemplate.segmentBarVerticalPadding
        let measuredWidth = buttons.map { ceil($0.intrinsicContentSize.width) + chipPadding }.max() ?? 60
        let slotWidth = max(60, measuredWidth, (bounds.width - inset * 2) / CGFloat(buttons.count))
        var x = inset
        for button in buttons {
            button.frame = CGRect(x: x, y: barPadding, width: slotWidth,
                                  height: bounds.height - barPadding * 2)
            x = button.frame.maxX
        }
        scrollView.contentSize = CGSize(width: x + inset, height: bounds.height)
        scrollView.bounces = scrollView.contentSize.width > bounds.width
        updatePill()
    }

    func setProgress(_ value: CGFloat) {
        progress = min(CGFloat(buttons.count - 1), max(0, value))
        updatePill()
    }

    func setSelection(_ index: Int) {
        for (i, button) in buttons.enumerated() {
            button.accessibilityTraits = i == index ? [.button, .selected] : [.button]
        }
    }

    private func updatePill() {
        guard bounds.width > 0 else { return }
        let lower = Int(progress.rounded(.down))
        let upper = min(buttons.count - 1, lower + 1)
        let fraction = progress - CGFloat(lower)
        let a = buttons[lower].frame
        let b = buttons[upper].frame
        pill.frame = CGRect(x: a.minX + (b.minX - a.minX) * fraction, y: a.minY,
                            width: a.width + (b.width - a.width) * fraction, height: a.height)
        pill.layer.cornerRadius = pill.bounds.height / 2
        for (index, button) in buttons.enumerated() {
            let weight = max(0, 1 - abs(progress - CGFloat(index)))
            button.setTitleColor(SettingsTemplate.segmentTitleColor(weight: weight), for: .normal)
        }
        // Follow the selected pill when labels overflow in English or at
        // larger text sizes. Interpolated offsets avoid a second animation.
        guard !scrollView.isTracking, !scrollView.isDecelerating else { return }
        let limit = max(0, scrollView.contentSize.width - bounds.width)
        func offset(for rect: CGRect) -> CGFloat { min(limit, max(0, rect.midX - bounds.width / 2)) }
        scrollView.contentOffset.x = offset(for: a) + (offset(for: b) - offset(for: a)) * fraction
    }
}
