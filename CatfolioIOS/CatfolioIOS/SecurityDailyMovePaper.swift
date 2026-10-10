import SwiftUI

enum SecurityDailyMovePresentation {
    /// Suppress only UIKit's modal slide; the paper owns its in-place animation.
    static func withoutSystemTransition(_ action: () -> Void) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction, action)
    }

    static func animate(_ animation: Animation?, _ action: () -> Void) {
        var transaction = Transaction(animation: animation)
        transaction.disablesAnimations = false
        withTransaction(transaction, action)
    }
}

/// What a paper note is about: the latest price move, or one card of the
/// security page explained. The paper, its cover and its motion are the same.
enum SecurityPaperTopic {
    case move(SecurityPriceMoveContext, SecurityDailyMoveStore)
    case card(SecurityCardInsightContext, SecurityCardInsightStore)

    var ticker: String {
        switch self {
        case .move(let context, _): context.ticker
        case .card(let context, _): context.ticker
        }
    }

    var name: String {
        switch self {
        case .move(let context, _): context.name
        case .card(let context, _): context.name
        }
    }

    func key(language: String) -> String {
        switch self {
        case .move(let context, _): context.key(language: language)
        case .card(let context, _): context.key(language: language)
        }
    }

    @MainActor var state: SecurityDailyMoveStore.State? {
        switch self {
        case .move(let context, let store): store.state(context)
        case .card(let context, let store): store.state(context)
        }
    }

    @MainActor func start(force: Bool = false) {
        switch self {
        case .move(let context, let store): store.start(context, force: force)
        case .card(let context, let store): store.start(context, force: force)
        }
    }
}

/// Paper Flip Lab: a two-sided cover turns upward around a horizontal spine.
///
/// Main-actor isolated as a whole: its initialisers default to the shared
/// stores, and a default argument is evaluated at the call site, where an
/// isolated `init` alone would not cover it.
@MainActor
struct SecurityDailyMovePaper: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale
    let topic: SecurityPaperTopic
    var logoSymbol: String? = nil
    var sourceFrame: CGRect = .zero

    /// The store is resolved in here rather than as a default argument: a
    /// default is evaluated at the call site, outside this view's isolation.
    init(context: SecurityPriceMoveContext, store: SecurityDailyMoveStore? = nil,
         logoSymbol: String? = nil, sourceFrame: CGRect = .zero) {
        self.topic = .move(context, store ?? .shared)
        self.logoSymbol = logoSymbol
        self.sourceFrame = sourceFrame
    }

    init(card: SecurityCardInsightContext, store: SecurityCardInsightStore? = nil,
         logoSymbol: String? = nil, sourceFrame: CGRect = .zero) {
        self.topic = .card(card, store ?? .shared)
        self.logoSymbol = logoSymbol
        self.sourceFrame = sourceFrame
    }
    @State private var logoColor: Color?
    @State private var closing = false
    @State private var flipProgress: Double = 0
    @State private var entranceProgress: Double = 0
    @State private var hasStartedOpening = false
    @State private var dragOffset: CGFloat = 0
    @State private var dragStart: Double?
    @State private var motionTask: Task<Void, Never>?
    @State private var springTask: Task<Void, Never>?
    @State private var settling = false
    @State private var exitTravel: CGFloat = 600
    @State private var thresholdFeedback = UIImpactFeedbackGenerator(style: .soft)
    @ScaledMetric(relativeTo: .body) private var halfHeight: CGFloat = 225

    var body: some View {
        GeometryReader { geometry in
            let frame = geometry.frame(in: .global)
            let source = CGPoint(x: sourceFrame.midX - frame.minX, y: sourceFrame.midY - frame.minY)
            let visibility = SecurityPaperMotion.visibility(entrance: entranceProgress, offset: dragOffset, travel: exitTravel)
            ZStack {
                SecurityPaperBlur(amount: visibility)
                    .overlay(CatfolioTheme.paperBackdropDim.opacity(visibility))
                    .ignoresSafeArea().allowsHitTesting(false)
                paper
                    .padding(.horizontal, 44)
                    .scaleEffect(reduceMotion ? 1 : 0.12 + 0.88 * entranceProgress)
                    .offset(x: reduceMotion ? 0 : (source.x - geometry.size.width / 2) * (1 - entranceProgress),
                            y: (reduceMotion ? 0 : (source.y - geometry.size.height / 2) * (1 - entranceProgress)) + dragOffset - 20 * entranceProgress)
                    .opacity(min(1, entranceProgress * 2) * min(1, visibility * 4))
                    .contentShape(Rectangle())
                    .gesture(paperDrag)
                    .allowsHitTesting(entranceProgress >= 0.999 && !closing)
                VStack(spacing: 20) {
                    Spacer()
                    Button { close(direction: 1) } label: {
                        Image(systemName: "xmark").font(.body.weight(.medium))
                            .frame(width: 48, height: 48)
                    }
                    .foregroundStyle(CatfolioTheme.primaryText)
                    .modifier(SecurityPaperCloseGlass())
                    .accessibilityLabel(L10n.text("关闭"))
                    .accessibilityIdentifier("daily-move-close")
                    sourceFooter
                }
                .padding(.horizontal, 44).padding(.bottom, 12)
                .opacity(visibility)
                .allowsHitTesting(!closing)
            }
            .onAppear { exitTravel = max(500, geometry.size.height * 0.8) }
        }
        .coordinateSpace(name: "daily-paper-stage")
        .onDisappear {
            springTask?.cancel(); springTask = nil
            motionTask?.cancel(); motionTask = nil
            settling = false
        }
        .presentationBackground(.clear)
        .task(id: topic.key(language: locale.identifier)) {
            topic.start()
            await Task.yield()
            guard !closing, !Task.isCancelled else { return }
            animateMotion(duration: 0.55) { progress in
                entranceProgress = progress
                if progress >= 0.5 && !hasStartedOpening && !closing {
                    hasStartedOpening = true
                    setOpen(true)
                }
            }
        }
    }

    /// Frame-driven motion keeps the blur's actual radius synchronized with the paper.
    private func animateMotion(duration: Double, easeInOut: Bool = false, update: @escaping (Double) -> Void,
                               completion: @escaping () -> Void = {}) {
        motionTask?.cancel()
        if reduceMotion { update(1); completion(); return }
        motionTask = Task { @MainActor in
            let start = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                let t = min(1, (ProcessInfo.processInfo.systemUptime - start) / duration)
                let eased = easeInOut ? SecurityPaperMotion.entranceEase(t) : 1 - pow(1 - t, 3)
                SecurityDailyMovePresentation.animate(nil) { update(eased) }
                if t >= 1 { motionTask = nil; completion(); return }
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            }
        }
    }

    private var paperDrag: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named("daily-paper-stage"))
            .onChanged { value in
                guard !closing else { return }
                if dragStart == nil {
                    springTask?.cancel(); motionTask?.cancel(); settling = false
                    dragStart = flipProgress
                    thresholdFeedback.prepare()
                }
                dragOffset = value.translation.height
                flipProgress = SecurityPaperMotion.fold(start: dragStart ?? 1, offset: dragOffset)
                if SecurityPaperMotion.shouldDismiss(offset: dragOffset) {
                    thresholdFeedback.impactOccurred(intensity: 0.75)
                    close(direction: dragOffset < 0 ? -1 : 1)
                }
            }
            .onEnded { _ in
                guard !closing else { return }
                dragStart = nil
                let startOffset = dragOffset
                setOpen(true)
                animateMotion(duration: 0.3) { progress in dragOffset = startOffset * (1 - progress) }
            }
    }

    private func setOpen(_ open: Bool, velocity: Double = 0, timeScale: Double = 1) {
        springTask?.cancel()
        let target = open ? 1.0 : 0.0
        guard !reduceMotion else { flipProgress = target; settling = false; return }
        settling = true
        springTask = Task { @MainActor in
            var speed = velocity
            let started = ProcessInfo.processInfo.systemUptime
            var last = started
            while !Task.isCancelled {
                let now = ProcessInfo.processInfo.systemUptime
                let dt = min(now - last, 0.032) * timeScale
                last = now
                speed += (100 * (target - flipProgress) - 9.5 * speed) * dt
                let next = min(1.2, max(0, flipProgress + speed * dt))
                let finished = now - started >= 3 / timeScale || (target == 0 && next <= 0)
                    || (abs(target - next) < 0.0005 && abs(speed) < 0.006)
                SecurityDailyMovePresentation.animate(nil) { flipProgress = finished ? target : next }
                if finished { settling = false; springTask = nil; return }
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            }
        }
    }

    private func close(direction: CGFloat) {
        guard !closing else { return }
        closing = true
        dragStart = nil
        springTask?.cancel(); springTask = nil; settling = false
        let startOffset = dragOffset
        let startFold = flipProgress
        animateMotion(duration: 0.34) { progress in
            dragOffset = startOffset + (direction * exitTravel - startOffset) * progress
            if direction > 0 {
                flipProgress = startFold * (1 - min(1, progress * 1.7))
            }
        } completion: {
            SecurityDailyMovePresentation.withoutSystemTransition { dismiss() }
        }
    }

    private var paper: some View {
        ZStack(alignment: .top) {
            // Two offset edges provide thickness, without adding extra content pages.
            ForEach(0..<2) { index in
                UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 20, bottomTrailingRadius: 20, topTrailingRadius: 0)
                    .fill(CatfolioTheme.paperFold)
                    .overlay { UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 20, bottomTrailingRadius: 20, topTrailingRadius: 0).stroke(CatfolioTheme.paperEdge, lineWidth: 0.5) }
                    .frame(height: halfHeight)
                    .modifier(SecurityPaperPlane(amount: reduceMotion ? 1 : flipProgress, upper: false,
                        depth: -1.5 - Double(index) * 0.95, halfHeight: halfHeight))
                    .offset(y: halfHeight)
            }
            noteContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(24)
            .frame(height: halfHeight)
            .background(CatfolioTheme.paper, in: UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 20, bottomTrailingRadius: 20, topTrailingRadius: 0))
            .overlay(alignment: .top) {
                LinearGradient(colors: [CatfolioTheme.paperFoldShade, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 30).allowsHitTesting(false)
            }
            .modifier(SecurityPaperPlane(amount: reduceMotion ? 1 : flipProgress, upper: false,
                depth: 0.95, halfHeight: halfHeight))
            .offset(y: halfHeight)
            .allowsHitTesting(flipProgress > 0.95 && !closing)
            .accessibilityHidden(flipProgress < 0.95)

            SecurityNoteFlipLeaf(progress: reduceMotion ? (flipProgress > 0.5 ? 1 : 0) : flipProgress,
                halfHeight: halfHeight, front: paperCover, back: paperInside)
                .frame(height: halfHeight)
                .offset(y: halfHeight)

        }
        .frame(height: halfHeight * 2, alignment: .top)
        .compositingGroup()
        .shadow(color: .black.opacity(0.13), radius: 16, x: 0, y: 12)
        .font(.system(.body, design: .rounded))
        .foregroundStyle(CatfolioTheme.paperInk)
        .accessibilityIdentifier("daily-move-paper")
    }

    private var coverColor: Color { logoColor ?? AssetBrandColor.fallback(for: logoSymbol ?? topic.ticker) }
    private var coverInk: Color {
        let color = UIColor(coverColor)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &alpha)
        return r * 0.299 + g * 0.587 + b * 0.114 > 0.58 ? .black : .white
    }

    @ViewBuilder private var sourceFooter: some View {
        if case .ready(let note) = topic.state, !note.sources.isEmpty {
            VStack(spacing: 4) {
                ForEach(Array(note.sources.enumerated()), id: \.offset) { _, source in
                    Link(destination: source.url) {
                        Text(L10n.text("来源") + " · " + source.title)
                            .lineLimit(1).frame(maxWidth: .infinity)
                    }
                }
            }
            .font(.system(.caption2, design: .rounded))
            .foregroundStyle(.primary.opacity(0.45))
            .accessibilityIdentifier("daily-move-sources")
        }
    }

    private var paperCover: some View {
        VStack(alignment: .leading, spacing: 18) {
            AssetLogo(ticker: topic.ticker, logoSymbol: logoSymbol, size: 24,
                onBrandColorResolved: { logoColor = $0 })
            Spacer(minLength: 0)
            Text(topic.name)
                .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.6)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .foregroundStyle(coverInk)
        .background(coverColor)
    }

    /// The inside of the cover: what the note is about, above the fold.
    private var insideCaption: String {
        switch topic {
        case .move(let context, _):
            context.isFundIntroduction ? context.name
                : context.name + " · " + SecurityNoteRelativeDate.label(context.endDate, locale: locale)
        case .card(let context, _): context.name
        }
    }

    private var insideTitle: String {
        switch topic {
        case .move(let context, _): context.isFundIntroduction ? L10n.text("基金介绍") : context.noteTitle
        case .card(let context, _): context.cardTitle
        }
    }

    private var insideFigure: String? {
        guard case .move(let context, _) = topic, !context.isFundIntroduction else { return nil }
        return DisplayFormat.percent(context.changePercent)
    }

    private var paperInside: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(insideCaption)
                .font(.caption).foregroundStyle(CatfolioTheme.paperInk.opacity(0.5))
            Spacer(minLength: 0)
            Text(insideTitle)
                .opacity(min(1, max(0, (entranceProgress - 0.75) * 4))).font(.system(.title2, design: .rounded, weight: .medium))
            if let insideFigure {
                Text(insideFigure).font(.system(.largeTitle, design: .rounded))
                    .foregroundStyle(CatfolioTheme.paperInk.opacity(0.25))
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [CatfolioTheme.paper, CatfolioTheme.paperFold], startPoint: .top, endPoint: .bottom))
    }

    @ViewBuilder private var noteContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            switch topic.state {
            case .ready(let note):
                Text(note.text)
                    .lineSpacing(4).lineLimit(14).minimumScaleFactor(0.65)
                    .accessibilityIdentifier("daily-move-text")
            case .failed(let message):
                Text(L10n.message(message))
                Button(L10n.text("重试")) { topic.start(force: true) }.buttonStyle(.bordered)
            case .loading, nil:
                SecurityPaperThinking(ready: entranceProgress >= 1, closing: closing)
            }
        }
    }
}

/// Evaluate face visibility on every animation frame, not only at state changes.
struct SecurityNoteFlipLeaf<Front: View, Back: View>: View, Animatable {
    var progress: Double
    let halfHeight: CGFloat
    let front: Front
    let back: Back
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }
    var body: some View {
        let amount = min(1.2, max(0, progress))
        let angle = 90 + 78 * amount
        let camera = -54 + 36 * amount
        let frontVisible = cos((angle + camera) * .pi / 180) > 0
        ZStack {
            front.opacity(frontVisible ? 1 : 0).accessibilityHidden(!frontVisible)
            back.rotation3DEffect(.degrees(180), axis: (x: 1, y: 0, z: 0))
                .opacity(frontVisible ? 0 : 1).accessibilityHidden(frontVisible)
        }
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 20, bottomTrailingRadius: 20, topTrailingRadius: 0))
        .overlay {
            UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 20, bottomTrailingRadius: 20, topTrailingRadius: 0).stroke(CatfolioTheme.paperEdge, lineWidth: 0.5)
        }
        .overlay {
            LinearGradient(colors: [.black.opacity(0.035 + max(0, sin(amount * .pi)) * 0.24), .clear],
                startPoint: .top, endPoint: .bottom)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 20, bottomTrailingRadius: 20, topTrailingRadius: 0)).allowsHitTesting(false)
        }
        .modifier(SecurityPaperPlane(amount: amount, upper: true,
            depth: (1 - min(1, amount)) * 2 * 0.95, halfHeight: halfHeight))
    }
}

/// Same transform order as the supplied demo: local-normal depth, hinge X,
/// camera X, then perspective. One progress drives both leaves; the hinge stays level.
struct SecurityPaperPlane: GeometryEffect {
    var amount: Double
    let upper: Bool
    let depth: Double
    let halfHeight: CGFloat
    var animatableData: Double {
        get { amount }
        set { amount = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let p = min(1.2, max(0, amount))
        let angle = (90 + (upper ? 78 : -42) * p) * .pi / 180
        let camera = (-54 + 36 * p) * .pi / 180
        let center = Double(size.width) / 2
        let offset = -cos(36 * .pi / 180) * Double(halfHeight) / 2 * (1 - p)
            - max(0, sin(p * .pi)) * 3
        // Return homogeneous screen coordinates. Sampling this affine 3D
        // mapping gives a homography without losing local-Z separation at 90°.
        func project(_ x: Double, _ y: Double) -> (Double, Double, Double) {
            let localX = x - center
            let localY = y * cos(angle) - depth * sin(angle)
            let localZ = y * sin(angle) + depth * cos(angle)
            let cameraY = localY * cos(camera) - localZ * sin(camera)
            let cameraZ = localY * sin(camera) + localZ * cos(camera)
            let denominator = 1 - cameraZ / 1300
            return (center * denominator + localX, cameraY + offset, denominator)
        }
        let o = project(0, 0), x = project(1, 0), y = project(0, 1)
        var t = CATransform3DIdentity
        t.m11 = x.0 - o.0; t.m21 = y.0 - o.0; t.m41 = o.0
        t.m12 = x.1 - o.1; t.m22 = y.1 - o.1; t.m42 = o.1
        t.m14 = x.2 - o.2; t.m24 = y.2 - o.2; t.m44 = o.2
        return ProjectionTransform(t)
    }
}

/// Shared interaction rules: distance, rather than swipe velocity, commits dismissal.
enum SecurityPaperMotion {
    static func entranceEase(_ progress: Double) -> Double {
        let t = min(1, max(0, progress))
        return t * t * t * (t * (6 * t - 15) + 10)
    }
    static func shouldDismiss(offset: CGFloat) -> Bool { offset >= 190 || offset <= -170 }
    static func fold(start: Double, offset: CGFloat) -> Double {
        max(0, min(1.2, start - Double(max(0, offset)) / 145))
    }
    static func visibility(entrance: Double, offset: CGFloat, travel: CGFloat) -> Double {
        min(1, max(0, entrance)) * max(0, 1 - Double(abs(offset) / max(1, travel)))
    }
}

/// Scrub a paused UIKit blur animation so the backdrop clears continuously as the paper leaves.
struct SecurityPaperBlur: UIViewRepresentable {
    var amount: Double
    final class BlurView: UIVisualEffectView {
        private(set) var blurAnimator: UIViewPropertyAnimator?
        private var currentAmount: Double = 0
        init() {
            super.init(effect: nil)
            isUserInteractionEnabled = false
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func setAmount(_ requested: Double) {
            let value = min(1, max(0, requested))
            guard value != currentAmount else { return }
            currentAmount = value
            // Never keep a paused interactive animator alive at either resting endpoint.
            if value == 0 || value == 1 {
                stopAnimator()
                UIView.performWithoutAnimation {
                    effect = value == 0 ? nil : UIBlurEffect(style: .systemUltraThinMaterial)
                }
                return
            }
            if blurAnimator == nil {
                UIView.performWithoutAnimation { effect = nil }
                let animator = UIViewPropertyAnimator(duration: 1, curve: .linear) { [weak self] in
                    self?.effect = UIBlurEffect(style: .systemUltraThinMaterial)
                }
                animator.startAnimation()
                animator.pauseAnimation()
                blurAnimator = animator
            }
            blurAnimator?.fractionComplete = value
        }

        private func stopAnimator() {
            blurAnimator?.stopAnimation(true)
            blurAnimator = nil
        }

        func tearDown() {
            stopAnimator()
            currentAmount = 0
            effect = nil
            layer.removeAllAnimations()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { tearDown() }
        }

        deinit { blurAnimator?.stopAnimation(true) }
    }
    func makeUIView(context: Context) -> BlurView { BlurView() }
    func updateUIView(_ view: BlurView, context: Context) { view.setAmount(amount) }
    static func dismantleUIView(_ view: BlurView, coordinator: ()) { view.tearDown() }
}

private struct SecurityPaperCloseGlass: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: Circle())
        } else {
            content.background(.regularMaterial, in: Circle())
        }
    }
}

/// Loading animation lives only in this small text view and stops as soon as
/// an answer arrives, dismissal begins, or the view leaves the hierarchy.
private struct SecurityPaperThinking: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let ready: Bool
    let closing: Bool
    @State private var visibleCharacters = 0
    @State private var shimmerStart = Date()
    private var label: String { L10n.text("正在思考") }
    private var renderedText: AttributedString {
        var result = AttributedString(label)
        let cut = result.index(result.startIndex, offsetByCharacters: min(visibleCharacters, label.count))
        result[cut..<result.endIndex].foregroundColor = .clear
        return result
    }

    var body: some View {
        Text(renderedText)
            .foregroundStyle(CatfolioTheme.paperInk.opacity(0.45))
            .overlay {
                if visibleCharacters == label.count && ready && !closing && !reduceMotion {
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                        GeometryReader { geometry in
                            let phase = timeline.date.timeIntervalSince(shimmerStart)
                                .truncatingRemainder(dividingBy: 1.6) / 1.6
                            LinearGradient(colors: [.clear, CatfolioTheme.paperShine, .clear],
                                           startPoint: .leading, endPoint: .trailing)
                                .frame(width: geometry.size.width * 0.65)
                                .offset(x: geometry.size.width * (-0.65 + 2.3 * phase))
                        }
                        .mask(Text(label))
                    }
                    .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .accessibilityLabel(label)
            .accessibilityIdentifier("daily-move-thinking")
            .task(id: "\(ready)|\(closing)|\(reduceMotion)|\(label)") {
                guard !closing else { return }
                visibleCharacters = 0
                guard ready else { return }
                if reduceMotion { visibleCharacters = label.count; return }
                while visibleCharacters < label.count {
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    guard !Task.isCancelled else { return }
                    if visibleCharacters + 1 == label.count { shimmerStart = Date() }
                    visibleCharacters += 1
                }
            }
    }
}
