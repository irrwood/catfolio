import SwiftUI
import UIKit

/// UIKit owns the continuous horizontal offset. SwiftUI only receives a
/// selection after settling, so dragging never diffs or rebuilds the ledger.
struct HistoryPagingView: UIViewControllerRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var selection: HistoryCategory
    var page: (HistoryCategory) -> AnyView

    final class Coordinator {
        var selection: HistoryCategory
        init(selection: HistoryCategory) { self.selection = selection }
    }

    func makeCoordinator() -> Coordinator { Coordinator(selection: selection) }

    func makeUIViewController(context: Context) -> HistoryPagingController {
        let controller = HistoryPagingController(selection: selection)
        updateUIViewController(controller, context: context)
        return controller
    }

    func updateUIViewController(_ controller: HistoryPagingController, context: Context) {
        controller.onSelection = {
            context.coordinator.selection = $0
            if selection != $0 { selection = $0 }
        }
        controller.reduceMotion = reduceMotion
        let height = HistoryCategoryBar.preferredHeight
        controller.updatePages(HistoryCategory.allCases.map {
            AnyView(page($0)
                .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: height) }
                .environment(\.self, context.environment))
        })
        if context.coordinator.selection != selection {
            context.coordinator.selection = selection
            controller.select(selection, animated: !reduceMotion)
        }
    }
}

final class HistoryPagingController: UIViewController, UIScrollViewDelegate {
    let pager = HistoryPagingScrollView()
    let categoryBar = HistoryCategoryBar()
    let headerMaterial = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
    private(set) var selection: HistoryCategory
    var onSelection: ((HistoryCategory) -> Void)?
    var reduceMotion = false
    private var hosts: [UIHostingController<AnyView>] = []
    private var lists: [Int: UIScrollView] = [:]
    private var observations: [Int: NSKeyValueObservation] = [:]
    private var laidOutSize = CGSize.zero
    private var isLayingOutPages = false
    private var requestedIndex: Int?
    /// Fades the header material out over its last stretch, so content
    /// scrolling up under the category bar dissolves into it instead of
    /// meeting a hard line along the bar's bottom edge.
    ///
    /// Done by hand here, not by registering the bar as a scroll-edge element:
    /// that stretches the system's blur from the top of the screen down to the
    /// bar, and the large title sitting between the two was blurred with it.
    private let headerFade = CAGradientLayer()

    init(selection: HistoryCategory) {
        self.selection = selection
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
        view.addSubview(headerMaterial)
        view.addSubview(categoryBar)
        categoryBar.onSelect = { [weak self] index in
            guard let self else { return }
            self.select(HistoryCategory.allCases[index], animated: !self.reduceMotion)
        }
    }

    func updatePages(_ pages: [AnyView]) {
        loadViewIfNeeded()
        for (index, page) in pages.enumerated() {
            if hosts.indices.contains(index) {
                hosts[index].rootView = page
            } else {
                let host = UIHostingController(rootView: page)
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
            host.view.frame = CGRect(x: CGFloat(index) * size.width, y: 0,
                                     width: size.width, height: size.height)
            host.view.layoutIfNeeded()
            connectList(at: index)
        }
        pager.contentSize = CGSize(width: size.width * CGFloat(hosts.count), height: size.height)
        if oldWidth != size.width {
            // Rotation preserves the page, including an interactive position.
            pager.contentOffset.x = progress * size.width
        }
        laidOutSize = size
        categoryBar.transform = .identity
        categoryBar.frame = CGRect(x: 0, y: view.safeAreaInsets.top, width: size.width,
                                   height: HistoryCategoryBar.preferredHeight)
        // Extend the same material to the physical top edge, underneath (not
        // over) the navigation controller's native title and glass buttons.
        let top = min(0, view.window.map { view.convert($0.bounds, from: $0).minY } ?? 0)
        headerMaterial.frame = CGRect(x: 0, y: top, width: size.width,
                                      height: categoryBar.frame.maxY - top + Self.headerFadeLength)
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
    }

    private var selectedIndex: Int { HistoryCategory.allCases.firstIndex(of: selection) ?? 0 }
    var pageProgress: CGFloat {
        guard pager.bounds.width > 0 else { return CGFloat(selectedIndex) }
        return min(CGFloat(hosts.count - 1), max(0, pager.contentOffset.x / pager.bounds.width))
    }

    func select(_ category: HistoryCategory, animated: Bool) {
        let index = HistoryCategory.allCases.firstIndex(of: category) ?? 0
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
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        requestedIndex = nil
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
        selection = HistoryCategory.allCases[index]
        for (pageIndex, host) in hosts.enumerated() {
            host.view.accessibilityElementsHidden = pageIndex != index
        }
        categoryBar.setProgress(CGFloat(index))
        categoryBar.setSelection(index)
        observeSelectedList()
        updateHeader()
        onSelection?(selection)
    }

    private func connectList(at index: Int) {
        guard lists[index] == nil, let list = verticalScrollView(in: hosts[index].view) else { return }
        lists[index] = list
        // These lists are SwiftUI's, but they live in hosting controllers
        // under a UIKit pager, so the style is set on the scroll view itself
        // rather than trusted to reach it through the environment.
        list.applySoftTopScrollEdge()
        list.scrollsToTop = index == selectedIndex
        hosts[index].view.accessibilityElementsHidden = index != selectedIndex
        observations[index] = list.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, index == self.selectedIndex else { return }
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
        guard let list = lists[selectedIndex] else { return }
        let position = HistoryHeaderPosition(scrollOffset: list.contentOffset.y + list.adjustedContentInset.top)
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

/// The pill interpolates between the actual text widths on every scroll
/// frame, including a cancelled drag. No independent header animation.
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

    override init(frame: CGRect) {
        super.init(frame: frame)
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.scrollsToTop = false
        scrollView.contentInsetAdjustmentBehavior = .never
        addSubview(scrollView)
        pill.backgroundColor = SettingsTemplate.uiCard
        pill.isUserInteractionEnabled = false
        pill.accessibilityIdentifier = "history-category-pill"
        scrollView.addSubview(pill)
        for (index, category) in HistoryCategory.allCases.enumerated() {
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
            button.setTitle(L10n.label(HistoryCategory.allCases[index].rawValue), for: .normal)
            button.titleLabel?.font = font
            button.titleLabel?.adjustsFontForContentSizeCategory = true
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        let inset = SettingsTemplate.pageInset
        let chipPadding = SettingsTemplate.segmentHorizontalPadding * 2
        let barPadding = SettingsTemplate.segmentBarVerticalPadding
        let widths = buttons.map { max(60, ceil($0.intrinsicContentSize.width) + chipPadding) }
        let extra = max(0, bounds.width - inset * 2 - widths.reduce(0, +)) / CGFloat(buttons.count)
        var x = inset
        for (index, button) in buttons.enumerated() {
            button.frame = CGRect(x: x, y: barPadding, width: widths[index] + extra,
                                  height: bounds.height - barPadding * 2)
            x = button.frame.maxX
        }
        scrollView.contentSize = CGSize(width: x + inset, height: bounds.height)
        scrollView.bounces = scrollView.contentSize.width > bounds.width
        updatePill()
    }

    func setProgress(_ value: CGFloat) {
        progress = min(CGFloat(buttons.count - 1), max(0, value))
        layoutIfNeeded()
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
