import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass
import CoreImage

/// Shape-preserving cubic interpolation in time, independently for x and y.
/// A shared tangent at each observation keeps joins smooth. Flat intervals and
/// local extrema have zero tangent; harmonic means limit the other tangents so
/// each segment stays within the coordinate ranges of its two observations.
enum RotationTrailCurve {
    struct Segment {
        let start: CGPoint
        let control1: CGPoint
        let control2: CGPoint
        let end: CGPoint

        var path: UIBezierPath {
            let path = UIBezierPath()
            path.move(to: start)
            path.addCurve(to: end, controlPoint1: control1, controlPoint2: control2)
            return path
        }
    }

    static func segments(through points: [CGPoint]) -> [Segment] {
        guard points.count > 1 else { return [] }
        func tangents(_ values: [CGFloat]) -> [CGFloat] {
            let changes = zip(values, values.dropFirst()).map { $1 - $0 }
            var result = Array(repeating: CGFloat.zero, count: values.count)
            result[0] = changes[0]
            result[values.count - 1] = changes[changes.count - 1]
            for i in 1..<(values.count - 1) {
                let before = changes[i - 1], after = changes[i]
                if (before > 0 && after > 0) || (before < 0 && after < 0) {
                    result[i] = 2 * before * after / (before + after)
                }
            }
            return result
        }
        let dx = tangents(points.map(\.x))
        let dy = tangents(points.map(\.y))
        var result: [Segment] = []
        result.reserveCapacity(points.count - 1)
        for i in 0..<(points.count - 1) {
            let start = points[i], end = points[i + 1]
            let control1 = CGPoint(x: start.x + dx[i] / 3, y: start.y + dy[i] / 3)
            let control2 = CGPoint(x: end.x - dx[i + 1] / 3, y: end.y - dy[i + 1] / 3)
            result.append(Segment(start: start, control1: control1, control2: control2, end: end))
        }
        return result
    }
}

/// The rotation pages' greys: the designed light values, with dark ones beside
/// them so the pages follow the system appearance.
enum RotationPalette {
    static let uiCard = dynamic(light: UIColor(white: 0.97, alpha: 1), dark: UIColor(white: 1, alpha: 0.07))
    static let uiCardSelected = dynamic(light: UIColor(white: 0.94, alpha: 1), dark: UIColor(white: 1, alpha: 0.14))
    static let uiControl = dynamic(light: UIColor(white: 240 / 255, alpha: 1), dark: UIColor(white: 1, alpha: 0.12))
    static let card = Color(uiColor: uiCard)
    static let cardSelected = Color(uiColor: uiCardSelected)
    static let control = Color(uiColor: uiControl)

    static func dynamic(light: UIColor, dark: UIColor) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? dark : light }
    }

    /// A paint lifted towards white for a dark ground, keeping its hue.
    static func lifted(_ color: UIColor, by amount: CGFloat = 0.22) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return UIColor(red: r + (1 - r) * amount, green: g + (1 - g) * amount, blue: b + (1 - b) * amount, alpha: a)
    }
}

/// UIKit owns chart rendering and gestures; SwiftUI owns snapshot/selection state.
struct SectorRotationPlot: UIViewRepresentable {
    let snapshot: SectorRotationSnapshot
    @Binding var selected: String?
    @Binding var precise: SectorRotationSnapshot.Sector?

    static func color(_ symbol: String) -> Color { Color(uiColor: SectorRotationChartView.color(symbol)) }
    func makeUIView(context: Context) -> SectorRotationChartView { SectorRotationChartView() }
    func updateUIView(_ view: SectorRotationChartView, context: Context) {
        view.onSelection = { selected = $0 }
        view.onPrecise = { selected = $0.symbol; precise = $0 }
        view.configure(snapshot: snapshot, selected: selected)
    }
}

final class SectorRotationChartView: UIView, UIGestureRecognizerDelegate {
    private(set) var snapshot: SectorRotationSnapshot?
    private(set) var selected: String?
    var onSelection: ((String?) -> Void)?
    var onPrecise: ((SectorRotationSnapshot.Sector) -> Void)?
    private lazy var lightSurface = RotationVectorSurface(dark: false)
    private lazy var darkSurface = RotationVectorSurface(dark: true)
    private var surface: RotationVectorSurface {
        traitCollection.userInterfaceStyle == .dark ? darkSurface : lightSurface
    }
    private(set) var touchLocation: CGPoint?
    private(set) var pressedSymbol: String?
    private(set) var lift: CGFloat = 0
    private var liftTarget: CGFloat = 0
    private var liftVelocity: CGFloat = 0
    private var displayLink: CADisplayLink?
    private var lastFrame: CFTimeInterval = 0
    private let touchFeedback = UIImpactFeedbackGenerator(style: .soft)
    private let tickerFont = UIFont(descriptor: UIFont.systemFont(ofSize: 10, weight: .semibold).fontDescriptor.withDesign(.rounded)!, size: 10)
    private let quadrantFont = UIFont(descriptor: UIFont.systemFont(ofSize: 11, weight: .semibold).fontDescriptor.withDesign(.rounded)!, size: 11)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        clipsToBounds = true
        layer.cornerRadius = 24
        contentMode = .redraw
        isAccessibilityElement = false
        accessibilityIdentifier = "rotation-chart"
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        hold.minimumPressDuration = 0.5
        hold.allowableMovement = 8
        hold.cancelsTouchesInView = false
        hold.delegate = self
        tap.require(toFail: hold)
        addGestureRecognizer(tap)
        addGestureRecognizer(hold)
        let feedback = RotationTouchFeedbackRecognizer()
        feedback.onChange = { [weak self] in self?.updateTouch(at: $0) }
        addGestureRecognizer(feedback)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: SectorRotationChartView, _: UITraitCollection) in
            view.setNeedsDisplay()
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(snapshot: SectorRotationSnapshot, selected: String?) {
        if self.snapshot?.asOf != snapshot.asOf { clearTouch() }
        self.snapshot = snapshot
        self.selected = selected
        setNeedsDisplay()
        rebuildAccessibility()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        rebuildAccessibility()
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { clearTouch() }
    }

    /// Feedback observes touch-down without recognizing a gesture or delaying scrolling.
    func updateTouch(at location: CGPoint?) {
        guard let location, bounds.contains(location) else {
            liftTarget = 0
            if UIAccessibility.isReduceMotionEnabled { clearTouch() }
            else { startFrames() }
            return
        }
        let symbol = nearestSector(at: location)?.symbol
        if symbol != pressedSymbol, symbol != nil {
            touchFeedback.impactOccurred(intensity: 0.55)
        }
        touchLocation = location
        pressedSymbol = symbol
        liftTarget = 1
        if UIAccessibility.isReduceMotionEnabled {
            lift = 1
            setNeedsDisplay()
        } else { startFrames() }
    }

    private func startFrames() {
        guard displayLink == nil, window != nil else { return }
        lastFrame = 0
        let link = CADisplayLink(target: RotationFrameTarget(self), selector: #selector(RotationFrameTarget.step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }
    fileprivate func advanceFrame(_ link: CADisplayLink) {
        let dt = CGFloat(min(1.0 / 30, lastFrame == 0 ? 1.0 / 60 : link.timestamp - lastFrame))
        lastFrame = link.timestamp
        advanceTouchFeedback(by: dt)
    }
    func advanceTouchFeedback(by dt: CGFloat) {
        // A damped spring gives touch-down a small rise and release a soft landing.
        liftVelocity += ((liftTarget - lift) * 340 - liftVelocity * 27) * dt
        lift = min(1.08, max(0, lift + liftVelocity * dt))
        setNeedsDisplay()
        if abs(lift - liftTarget) < 0.002 && abs(liftVelocity) < 0.02 {
            lift = liftTarget
            displayLink?.invalidate(); displayLink = nil
            if liftTarget == 0 { touchLocation = nil; pressedSymbol = nil }
        }
    }
    func clearTouch() {
        displayLink?.invalidate(); displayLink = nil
        touchLocation = nil; pressedSymbol = nil
        lift = 0; liftTarget = 0; liftVelocity = 0
        setNeedsDisplay()
    }

    static func color(_ symbol: String) -> UIColor {
        let paint = sourcePaint(symbol)
        // Deep paints (XLF green, XLB, XLU) sink into a black ground; lift them.
        return RotationPalette.dynamic(light: paint, dark: RotationPalette.lifted(paint))
    }

    private static func sourcePaint(_ symbol: String) -> UIColor {
        // The four primary paths use the exact source paints. Symbols keep their
        // color across dates and quadrants; the remaining sectors use app tokens.
        switch symbol {
        case "XLE": UIColor(red:0.620024,green:0.085957,blue:0.692851,alpha:1)
        case "XLF": UIColor(red:0.117549,green:0.488281,blue:0,alpha:1)
        case "XLV": UIColor(red:1,green:0.864158,blue:0.094389,alpha:1)
        case "XLI": UIColor(red:1,green:0.253305,blue:0.253305,alpha:1)
        case "XLK": UIColor(red:139/255.0,green:92/255.0,blue:246/255.0,alpha:1)
        case "XLY": UIColor(red:67/255.0,green:137/255.0,blue:199/255.0,alpha:1)
        case "XLP": UIColor(CatfolioPalette.coral700)
        case "XLB": UIColor(CatfolioPalette.green900)
        case "XLU": UIColor(CatfolioPalette.blue700)
        case "XLRE": UIColor(CatfolioPalette.magenta700)
        default: UIColor(CatfolioPalette.sky700)
        }
    }
    func point(x: Double, y: Double) -> CGPoint {
        CGPoint(x: 30 + (x + 2.5) / 5 * max(0, bounds.width - 60),
                y: 36 + (2.5 - y) / 5 * max(0, bounds.height - 72))
    }
    func nearestSector(at location: CGPoint) -> SectorRotationSnapshot.Sector? {
        guard let nearest = snapshot?.sectors.min(by: { a, b in
            let pa = point(x: a.x, y: a.y), pb = point(x: b.x, y: b.y)
            return hypot(pa.x-location.x, pa.y-location.y) < hypot(pb.x-location.x, pb.y-location.y)
        }) else { return nil }
        let p = point(x: nearest.x, y: nearest.y)
        return hypot(p.x-location.x, p.y-location.y) <= 22 ? nearest : nil
    }
    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        let symbol = nearestSector(at: recognizer.location(in: self))?.symbol
        onSelection?(symbol == selected ? nil : symbol)
    }
    @objc private func held(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, let sector = nearestSector(at: recognizer.location(in: self)) else { return }
        updateTouch(at: nil)
        onPrecise?(sector)
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // A vertical page pan must not be captured by the chart's tap/hold recognizers.
        other is UIPanGestureRecognizer
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        surface.draw(in: context, bounds: bounds, touch: touchLocation, lift: lift,
                     reduceMotion: UIAccessibility.isReduceMotionEnabled)
        drawQuadrants()
        guard let snapshot else { return }
        // The four labelled sectors show their saved weekly paths by default.
        // Selection adds its path and fades the others so the overview remains readable.
        let trails = snapshot.sectors.filter {
            !$0.trail.isEmpty && (snapshot.labeledSymbols.contains($0.symbol) || $0.symbol == selected)
        }
        for sector in trails.sorted(by: { $0.symbol != selected && $1.symbol == selected }) {
            let emphasis: CGFloat = selected == nil ? 0.85 : (sector.symbol == selected ? 1 : 0.2)
            drawTrail(sector, emphasis: emphasis)
        }
        for sector in snapshot.sectors.sorted(by: { $0.symbol != pressedSymbol && $1.symbol == pressedSymbol }) {
            drawNode(sector, in: context)
        }
        drawLabels(snapshot)
    }
    private func drawNode(_ sector: SectorRotationSnapshot.Sector, in context: CGContext) {
        let anchor = point(x: sector.x, y: sector.y)
        let amount = sector.symbol == pressedSymbol ? lift : 0
        let moves = UIAccessibility.isReduceMotionEnabled ? CGFloat(0) : amount
        let radius = 6.5 * (1 + 0.55 * moves)
        let center = CGPoint(x: anchor.x, y: anchor.y - 6 * moves)
        let circle = CGRect(x: center.x-radius, y: center.y-radius, width: radius*2, height: radius*2)
        let color = Self.color(sector.symbol)
        context.saveGState()
        if sector.symbol == selected || amount > 0 {
            // The locator stays at the real coordinate while the face lifts above it.
            context.setStrokeColor(color.withAlphaComponent(0.45 + amount*0.25).cgColor)
            context.setLineWidth(1)
            context.strokeEllipse(in: CGRect(x:anchor.x-9,y:anchor.y-9,width:18,height:18))
        }
        context.setShadow(offset: CGSize(width: 0, height: 1 + 6*moves), blur: 2 + 7*moves,
                          color: UIColor.black.withAlphaComponent(0.05 + 0.22*amount).cgColor)
        context.setFillColor(color.cgColor)
        context.fillEllipse(in: circle)
        context.setShadow(offset: .zero, blur: 0, color: nil)
        context.addEllipse(in: circle); context.clip()
        // Public Core Graphics overlay blending: light catches the upper face,
        // a darker lower edge gives depth without changing the sector's base color.
        context.setBlendMode(.overlay)
        context.drawLinearGradient(surface.nodeLight,
                                   start: CGPoint(x: circle.minX, y: circle.minY),
                                   end: CGPoint(x: circle.maxX, y: circle.maxY), options: [])
        context.setStrokeColor(UIColor.white.withAlphaComponent(0.4 + 0.25*amount).cgColor)
        context.setLineWidth(0.8)
        context.strokeEllipse(in: circle.insetBy(dx: 0.5, dy: 0.5))
        context.restoreGState()
    }

    private func drawQuadrants() {
        // Figma 261:11625/11627/11631/11632: SF Pro Rounded Semibold,
        // 11pt, 5% tracking, uppercase, with the cap-height box 16pt from the edge.
        let labels: [(String, Bool, Bool, CGFloat, UIColor)] = [
            ("IMPROVING", false, false, 64, UIColor(red:0.620024,green:0.085957,blue:0.692851,alpha:1)),
            ("LEADING", true, false, 49, UIColor(red:0.154230,green:0.635066,blue:0,alpha:1)),
            ("LAGGING", false, true, 51, UIColor(red:0.690280,green:0.044583,blue:0.232422,alpha:1)),
            ("WEAKENING", true, true, 69, UIColor(red:0.569599,green:0.562104,blue:0,alpha:1))
        ].map { label in
            // Brighter on a dark ground, same hue.
            (label.0, label.1, label.2, label.3,
             traitCollection.userInterfaceStyle == .dark ? RotationPalette.lifted(label.4, by: 0.35) : label.4)
        }
        guard let context = UIGraphicsGetCurrentContext() else { return }
        for (label, right, bottom, designWidth, color) in labels {
            let attributes: [NSAttributedString.Key: Any] = [.font: quadrantFont, .kern: 0.55, .foregroundColor: color]
            let text = label as NSString
            let width = text.size(withAttributes: attributes).width
            let capTop: CGFloat = bottom ? bounds.height-23 : 16
            // Normalize SF's platform optical metrics to the Figma cap-height box.
            context.saveGState()
            context.translateBy(x: right ? bounds.width-16-designWidth : 16, y: capTop)
            context.scaleBy(x: designWidth/width, y: 8/quadrantFont.capHeight)
            text.draw(at: CGPoint(x: 0, y: -(quadrantFont.ascender-quadrantFont.capHeight)), withAttributes: attributes)
            context.restoreGState()
        }
    }
    private func drawTrail(_ sector: SectorRotationSnapshot.Sector, emphasis: CGFloat) {
        guard let snapshot else { return }
        let history = sector.trail + [.init(date: snapshot.asOf, x: sector.x, y: sector.y)]
        let positions = history.map { point(x: $0.x, y: $0.y) }
        let segments = RotationTrailCurve.segments(through: positions)
        let color = Self.color(sector.symbol)
        for i in positions.indices {
            let p = positions[i]
            let alpha = emphasis * (0.18 + 0.82 * Double(i + 1) / Double(positions.count))
            if i > 0 {
                let line = segments[i-1].path
                line.lineWidth = sector.symbol == selected ? 1.8 : 1.3; line.lineCapStyle = .round
                color.withAlphaComponent(alpha).setStroke(); line.stroke()
            }
            if i < positions.count-1 {
                let radius = 1.5 + Double(i)*0.2
                color.withAlphaComponent(alpha).setFill()
                UIBezierPath(ovalIn: CGRect(x: p.x-radius, y: p.y-radius, width: radius*2, height: radius*2)).fill()
            }
        }
    }
    private func drawLabels(_ snapshot: SectorRotationSnapshot) {
        let attributes: [NSAttributedString.Key: Any] = [.font: tickerFont, .foregroundColor: CatfolioTheme.primaryTextUIColor]
        var occupied: [CGRect] = []
        let sectors = snapshot.sectors.filter { snapshot.labeledSymbols.contains($0.symbol) || $0.symbol == selected }
        for sector in sectors.sorted(by: { $0.symbol == selected && $1.symbol != selected }) {
            let p = point(x: sector.x, y: sector.y)
            let text = sector.symbol as NSString, size = (sector.symbol as NSString).size(withAttributes: attributes)
            let candidates = [CGPoint(x:p.x,y:p.y+17),CGPoint(x:p.x,y:p.y-17),CGPoint(x:p.x+28,y:p.y),CGPoint(x:p.x-28,y:p.y),CGPoint(x:p.x+24,y:p.y-17),CGPoint(x:p.x-24,y:p.y+17)]
                .map { CGRect(x: $0.x-size.width/2, y: $0.y-size.height/2, width: size.width, height: size.height) }
            let labelRect = candidates.first { candidate in
                bounds.insetBy(dx: 12, dy: 26).contains(candidate) &&
                !occupied.contains(where: { $0.insetBy(dx:-3,dy:-2).intersects(candidate) }) &&
                !snapshot.sectors.contains(where: { other in
                    let center = point(x: other.x, y: other.y)
                    return candidate.insetBy(dx:-7,dy:-7).contains(center)
                })
            } ?? candidates[0]
            text.draw(in: labelRect, withAttributes: attributes)
            occupied.append(labelRect)
        }
    }
    private func rebuildAccessibility() {
        guard let snapshot else { accessibilityElements = []; return }
        accessibilityElements = snapshot.sectors.map { sector in
            let item = RotationAccessiblePoint(accessibilityContainer: self)
            item.accessibilityLabel = "\(sector.displayName) \(sector.symbol), \(sector.displayQuadrant)"
            item.accessibilityValue = String(format: "%+.1f%% / %+.1f%%", sector.relativeTrend*100, sector.relativeMomentum*100)
            item.accessibilityTraits = sector.symbol == selected ? [.button, .selected] : .button
            let p = point(x: sector.x, y: sector.y)
            item.accessibilityFrameInContainerSpace = CGRect(x:p.x-22,y:p.y-22,width:44,height:44)
            item.activate = { [weak self] in self?.onSelection?(self?.selected == sector.symbol ? nil : sector.symbol) }
            item.accessibilityCustomActions = [UIAccessibilityCustomAction(name: L10n.text("精确值"), actionHandler: { [weak self] _ in self?.onPrecise?(sector); return true })]
            return item
        }
    }
}

/// Weak display-link target lets an off-screen chart deallocate during a press.
private final class RotationFrameTarget: NSObject {
    weak var chart: SectorRotationChartView?
    init(_ chart: SectorRotationChartView) { self.chart = chart }
    @objc func step(_ link: CADisplayLink) {
        guard let chart else { link.invalidate(); return }
        chart.advanceFrame(link)
    }
}

/// Remains possible until touch-up; it cannot win against the page's pan or tap.
final class RotationTouchFeedbackRecognizer: UIGestureRecognizer {
    var onChange: ((CGPoint?) -> Void)?
    private var origin: CGPoint?
    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }
    convenience init() { self.init(target: nil, action: nil) }
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard touches.count == 1, origin == nil, let point = touches.first?.location(in: view) else {
            finish(); return
        }
        origin = point
        onChange?(point)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let point = touches.first?.location(in: view), let origin else { return }
        if abs(point.y-origin.y) > 8 && abs(point.y-origin.y) > abs(point.x-origin.x) {
            finish() // Vertical movement belongs to the page immediately.
        } else { onChange?(point) }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { finish() }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { finish() }
    override func reset() { super.reset(); origin = nil; onChange?(nil) }
    private func finish() { onChange?(nil); state = .failed }
}

/// Figma's atmosphere is generated once from its ellipse/blur values; every dot
/// remains a live resolution-independent path, never part of a background PNG.
private final class RotationVectorSurface {
    private let atmosphere: UIImage
    private let labelGlazes: UIImage
    let nodeLight = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        UIColor.white.withAlphaComponent(0.55).cgColor,
        UIColor.white.withAlphaComponent(0.06).cgColor,
        UIColor.black.withAlphaComponent(0.22).cgColor
    ] as CFArray, locations: [0, 0.45, 1])!

    private let dark: Bool

    init(dark: Bool) {
        self.dark = dark
        atmosphere = Self.makeAtmosphere(dark: dark)
        labelGlazes = Self.makeAtmosphere(dark: dark, glazesOnly: true)
    }

    func draw(in context: CGContext, bounds: CGRect, touch: CGPoint?, lift: CGFloat, reduceMotion: Bool) {
        atmosphere.draw(in: bounds)
        let sx = bounds.width/370, sy = bounds.height/246
        let dots = CGMutablePath(), lights = CGMutablePath(), shadows = CGMutablePath()
        for row in 0..<25 {
            for column in 0..<37 {
                let anchor = CGPoint(x: (7.5 + CGFloat(column)*10)*sx, y: (8 + CGFloat(row)*10)*sy)
                let distance = touch.map { hypot(anchor.x-$0.x, anchor.y-$0.y) } ?? 1000
                let influence = pow(max(0, 1-distance/48), 2) * lift
                let movement = reduceMotion ? 0 : influence
                let radius = 1.5 * min(sx, sy) * (1 + 1.35*movement)
                let center = CGPoint(x: anchor.x, y: anchor.y - 4*movement)
                let dot = CGRect(x:center.x-radius,y:center.y-radius,width:radius*2,height:radius*2)
                dots.addEllipse(in: dot)
                if influence > 0.025 {
                    shadows.addEllipse(in: dot.offsetBy(dx: 0, dy: 2.5*movement))
                    lights.addEllipse(in: dot.insetBy(dx:radius*0.2,dy:radius*0.2).offsetBy(dx:-radius*0.15,dy:-radius*0.3))
                }
            }
        }
        context.saveGState()
        context.setFillColor(UIColor.black.withAlphaComponent(0.10*lift).cgColor)
        context.addPath(shadows); context.fillPath()
        if dark {
            // Overlaying black on a black ground draws nothing; the grid is a
            // faint light dot instead.
            context.setFillColor(UIColor.white.withAlphaComponent(0.10).cgColor)
            context.addPath(dots); context.fillPath()
            context.setBlendMode(.overlay)
        } else {
            context.setBlendMode(.overlay)
            context.setFillColor(UIColor.black.cgColor)
            context.addPath(dots); context.fillPath()
        }
        context.setFillColor(UIColor.white.withAlphaComponent(0.75*lift).cgColor)
        context.addPath(lights); context.fillPath()
        context.restoreGState()
        // Figma places these two blurred patches above the dot overlay.
        labelGlazes.draw(in: bounds)
    }

    private static func makeAtmosphere(dark: Bool, glazesOnly: Bool = false) -> UIImage {
        // 261:2024 is the white base; 261:2034 is an alpha mask, not a blue fill.
        // Paints: 2026, 2035, 11640, 2036, 2037, 11641; glazes: 11634, 11642.
        let padding: CGFloat = 256
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.preferredRange = .standard
        let size = CGSize(width: 370+padding*2, height: 246+padding*2)
        // Figma blends these paints in sRGB. Core Image's default linear-gamma
        // working space made the same RGB/opacity values look washed out.
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let ciContext = CIContext(options: [.cacheIntermediates: false, .workingColorSpace: srgb, .outputColorSpace: srgb])
        func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> UIColor {
            UIColor(red: CGFloat((hex>>16)&255)/255, green: CGFloat((hex>>8)&255)/255,
                    blue: CGFloat(hex&255)/255, alpha: alpha)
        }
        // At night the same paints glow from a near-black ground: colours at
        // about half strength, and the white highlights nearly gone, since a
        // white patch on black reads as a grey smudge rather than light.
        func tone(_ color: UIColor) -> UIColor {
            // Label glazes have their own night paints and opacity below.
            guard dark, !glazesOnly else { return color }
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            let neutral = r > 0.99 && g > 0.99 && b > 0.99
            return color.withAlphaComponent(a * (neutral ? 0.10 : 0.5))
        }
        let base: UIColor = glazesOnly ? .clear : (dark ? UIColor(white: 0.06, alpha: 1) : .white)
        var result = CIImage(color: CIColor(color: base)).cropped(to: CGRect(origin: .zero, size: size))
        let layers: [(CGRect, [UIColor], [CGFloat], CGPoint, CGPoint, Double)] = [
            (.init(x:129,y:83,width:326,height:326), [rgb(0xFFFA5A),rgb(0xFFFA5A),rgb(0xF1FFAC)], [0,0.537406,1], .init(x:322,y:301), .init(x:292,y:83), 54.55),
            (.init(x:-131,y:-171,width:343,height:343), [rgb(0xE235FF,0.54)], [0], .zero,.zero,54.55),
            (.init(x:117,y:-22,width:109,height:109), [.white], [0], .zero,.zero,54.55),
            (.init(x:-121,y:146,width:241,height:241), [rgb(0xE93620,0.5)], [0], .zero,.zero,54.55),
            (.init(x:126,y:-239,width:394,height:394), [rgb(0x47FF2A,0.6),rgb(0xC9FF97,0.6)], [0,1], .init(x:357,y:-42),.init(x:278.5,y:198.5),54.55),
            (.init(x:130,y:72,width:109,height:109), [UIColor.white.withAlphaComponent(0.5)], [0], .zero,.zero,25),
            // Pastel glazes wash out the dark corners and compete with the labels.
            // Use a faint tint matching each quadrant on the night surface.
            (.init(x:-2,y:208,width:72,height:41), [dark ? rgb(0xE93620,0.16) : rgb(0xF59FA5)], [0], .zero,.zero,10),
            (.init(x:0,y:0,width:90,height:38), [dark ? rgb(0xE235FF,0.16) : rgb(0xEF93FE)], [0], .zero,.zero,10)
        ]
        for (rect, colors, stops, start, end, blur) in (glazesOnly ? Array(layers.suffix(2)) : Array(layers.prefix(6))) {
            let source = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
                let c = renderer.cgContext
                c.translateBy(x: padding, y: padding)
                c.addEllipse(in: rect)
                let colors = colors.map(tone)
                if colors.count == 1 { c.setFillColor(colors[0].cgColor); c.fillPath() }
                else {
                    c.clip()
                    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors.map(\.cgColor) as CFArray, locations: stops)!
                    c.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation,.drawsAfterEndLocation])
                }
            }
            if let image = CIImage(image: source) {
                result = image.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blur]).composited(over: result)
            }
        }
        let crop = CGRect(x:padding,y:padding,width:370,height:246)
        guard let rendered = ciContext.createCGImage(result, from: crop) else { return UIImage() }
        return UIImage(cgImage: rendered)
    }
}

private final class RotationAccessiblePoint: UIAccessibilityElement {
    var activate: (() -> Void)?
    override func accessibilityActivate() -> Bool { activate?(); return true }
}

struct SectorRotationTimeline: UIViewRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let index: Int
    let dates: [String]
    var centersSelection = false
    var isPlaying = false
    var onInteraction: () -> Void = {}
    let onSelection: (Int) -> Void
    func makeUIView(context: Context) -> SectorRotationTimelineControl { SectorRotationTimelineControl() }
    func updateUIView(_ view: SectorRotationTimelineControl, context: Context) {
        view.dates = dates
        view.centersSelection = centersSelection
        view.reducesMotion = reduceMotion
        view.isPlaying = isPlaying
        view.index = index
        view.onInteraction = onInteraction
        view.onSelection = onSelection
    }
}

/// A date ruler that moves beneath a fixed, centered playhead.
final class SectorRotationTimelineControl: UIControl, UIGestureRecognizerDelegate {
    private static let tickSpacing: CGFloat = 9
    private(set) var position: CGFloat = 0
    private var dragStart: CGFloat?
    private var displayLink: CADisplayLink?
    private var lastFrame: CFTimeInterval = 0
    private var motion: (start: CGFloat, target: CGFloat, duration: TimeInterval, elapsed: TimeInterval, selectsDates: Bool)?
    private var updatingSelection = false
    var selectionFeedback = UISelectionFeedbackGenerator()
    var isAnimating: Bool { motion != nil }
    var reducesMotion = UIAccessibility.isReduceMotionEnabled {
        didSet { if reducesMotion && !oldValue { cancelScrubbing() } }
    }
    var isPlaying = false {
        didSet { if isPlaying && !oldValue { cancelScrubbing() } }
    }
    var centersSelection = false { didSet { setNeedsDisplay() } }
    var index = 0 {
        didSet {
            guard oldValue != index else { return }
            if dragStart == nil && !updatingSelection {
                move(to: CGFloat(index), duration: 0.22, selectsDates: false)
            }
            setNeedsDisplay()
            updateAccessibility()
        }
    }
    var dates: [String] = [] { didSet { setNeedsDisplay(); updateAccessibility() } }
    var onInteraction: (() -> Void)?
    var onSelection: ((Int) -> Void)?
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentMode = .redraw
        clipsToBounds = true
        isAccessibilityElement = true
        accessibilityTraits = .adjustable
        accessibilityLabel = L10n.text("回看日期")
        accessibilityIdentifier = "rotation-timeline"
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.delegate = self
        addGestureRecognizer(tap); addGestureRecognizer(pan)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: SectorRotationTimelineControl, _: UITraitCollection) in
            view.setNeedsDisplay()
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ rect: CGRect) {
        guard !dates.isEmpty else { return }
        if !centersSelection {
            let selectedTick = Int((Double(index) / Double(max(1, dates.count - 1)) * 38).rounded())
            for tick in 0..<39 {
                let x = CGFloat(tick) / 38 * max(0, bounds.width - 4)
                (tick == selectedTick ? UIColor.label : RotationPalette.uiControl).setFill()
                UIBezierPath(roundedRect: CGRect(x: x, y: 0, width: 4, height: bounds.height), cornerRadius: 2).fill()
            }
            return
        }
        let radius = Int(ceil(bounds.width / (2 * Self.tickSpacing))) + 1
        let first = max(0, Int(position) - radius)
        let last = min(dates.count - 1, Int(position) + radius)
        guard first <= last else { return }
        for tick in first...last {
            let x = bounds.midX + (CGFloat(tick) - position) * Self.tickSpacing
            // Matching edge fades leave the page background untouched.
            let fade = edgeOpacity(at: x)
            UIColor.label.withAlphaComponent(0.16 * fade).setFill()
            UIBezierPath(roundedRect: CGRect(x: x - 2, y: 0, width: 4, height: bounds.height), cornerRadius: 2).fill()
        }
        UIColor.label.setFill()
        UIBezierPath(roundedRect: CGRect(x: bounds.midX - 2, y: 0, width: 4, height: bounds.height), cornerRadius: 2).fill()
    }
    func edgeOpacity(at x: CGFloat) -> CGFloat {
        min(1, max(0, (min(x, bounds.width - x) - 50) / 108))
    }
    func index(at x: CGFloat) -> Int {
        if !centersSelection {
            let fraction = min(1, max(0, (x - 2) / max(1, bounds.width - 4)))
            return Int((fraction * CGFloat(max(0, dates.count - 1))).rounded())
        }
        return clampedIndex(Int((position + (x - bounds.midX) / Self.tickSpacing).rounded()))
    }
    private func clampedIndex(_ value: Int) -> Int {
        min(max(0, dates.count - 1), max(0, value))
    }
    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        guard !dates.isEmpty else { return }
        onInteraction?()
        let value = index(at: recognizer.location(in: self).x)
        if centersSelection {
            selectionFeedback.prepare()
            move(to: CGFloat(value), duration: 0.24, selectsDates: true)
        } else { select(value) }
    }
    @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
        if !centersSelection {
            guard !dates.isEmpty else { return }
            onInteraction?()
            select(index(at: recognizer.location(in: self).x))
            return
        }
        switch recognizer.state {
        case .began:
            beginScrubbing()
            scrub(translation: recognizer.translation(in: self).x)
        case .changed:
            scrub(translation: recognizer.translation(in: self).x)
        case .ended:
            scrub(translation: recognizer.translation(in: self).x)
            endScrubbing(velocity: recognizer.velocity(in: self).x)
        case .cancelled, .failed:
            endScrubbing()
        default: break
        }
    }
    func beginScrubbing() {
        guard !dates.isEmpty else { return }
        stopAnimation()
        dragStart = position
        selectionFeedback.prepare()
        onInteraction?()
    }
    func scrub(translation: CGFloat) {
        guard let dragStart else { return }
        position = min(CGFloat(max(0, dates.count - 1)), max(0, dragStart - translation / Self.tickSpacing))
        let value = clampedIndex(Int(position.rounded()))
        if value != index { select(value, feedback: true) }
        setNeedsDisplay()
    }
    func endScrubbing(velocity: CGFloat = 0) {
        guard dragStart != nil else { return }
        dragStart = nil
        // A short, bounded coast, followed by an exact stop on a trading day.
        let travel = reducesMotion ? 0 : min(24, max(-24, velocity * 0.16 / Self.tickSpacing))
        let target = CGFloat(clampedIndex(Int((position - travel).rounded())))
        let duration = min(0.45, 0.18 + Double(abs(target - position)) * 0.018)
        move(to: target, duration: duration, selectsDates: true)
    }
    private func cancelScrubbing() {
        dragStart = nil
        stopAnimation()
        position = CGFloat(index)
        setNeedsDisplay()
    }
    private func move(to target: CGFloat, duration: TimeInterval, selectsDates: Bool) {
        stopAnimation()
        guard centersSelection, !reducesMotion, window != nil, abs(target - position) > 0.001 else {
            position = target
            if selectsDates, Int(target) != index { select(Int(target), feedback: true) }
            setNeedsDisplay()
            return
        }
        motion = (position, target, duration, 0, selectsDates)
        let link = CADisplayLink(target: RotationTimelineFrameTarget(self), selector: #selector(RotationTimelineFrameTarget.step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }
    fileprivate func advanceFrame(_ link: CADisplayLink) {
        let dt = lastFrame == 0 ? link.duration : link.timestamp - lastFrame
        lastFrame = link.timestamp
        advanceAnimation(by: dt)
    }
    func advanceAnimation(by delta: TimeInterval) {
        guard var motion else { return }
        motion.elapsed += max(0, delta)
        let progress = min(1, motion.elapsed / motion.duration)
        let eased = 1 - pow(1 - progress, 3)
        position = motion.start + (motion.target - motion.start) * CGFloat(eased)
        self.motion = motion
        if motion.selectsDates {
            let value = clampedIndex(Int(position.rounded()))
            if value != index { select(value, feedback: true) }
        }
        setNeedsDisplay()
        if progress == 1 { stopAnimation() }
    }
    private func stopAnimation() {
        displayLink?.invalidate()
        displayLink = nil
        motion = nil
        lastFrame = 0
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { cancelScrubbing() }
    }
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: self)
        return abs(velocity.x) > abs(velocity.y)
    }
    override func accessibilityIncrement() { change(by: 1) }
    override func accessibilityDecrement() { change(by: -1) }
    private func change(by amount: Int) {
        guard !dates.isEmpty else { return }
        onInteraction?()
        cancelScrubbing()
        select(clampedIndex(index + amount), feedback: true)
        position = CGFloat(index)
    }
    private func select(_ value: Int, feedback: Bool = false) {
        let changed = value != index
        updatingSelection = true
        index = value
        updatingSelection = false
        if changed && feedback && centersSelection {
            selectionFeedback.selectionChanged()
            selectionFeedback.prepare()
        }
        onSelection?(value)
        sendActions(for: .valueChanged)
    }
    private func updateAccessibility() {
        accessibilityValue = dates.indices.contains(index) ? dates[index] : nil
    }
}

private final class RotationTimelineFrameTarget: NSObject {
    weak var timeline: SectorRotationTimelineControl?
    init(_ timeline: SectorRotationTimelineControl) { self.timeline = timeline }
    @objc func step(_ link: CADisplayLink) {
        guard let timeline else { link.invalidate(); return }
        timeline.advanceFrame(link)
    }
}
