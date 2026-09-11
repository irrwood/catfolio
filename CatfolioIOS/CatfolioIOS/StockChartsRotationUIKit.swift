import SwiftUI
import UIKit

struct StockChartsRRGPlot: UIViewRepresentable {
    let weeks: [StockChartsRRGResponse.Week]
    @Binding var selected: String?
    func makeUIView(context: Context) -> StockChartsRRGChart { StockChartsRRGChart() }
    func updateUIView(_ view: StockChartsRRGChart, context: Context) {
        view.onSelection = { selected = $0 }
        view.configure(weeks: weeks, selected: selected)
    }
}

/// Uses source coordinates on linear axes around 100. No MAD, tanh, or resampling.
final class StockChartsRRGChart: UIView {
    private(set) var weeks: [StockChartsRRGResponse.Week] = []
    private(set) var selected: String?
    var onSelection: ((String?) -> Void)?
    private let atmosphere = SectorRotationChartView()
    private var nodes: [String: RRGNode] = [:]
    private(set) var xRadius: Double = 2
    private(set) var yRadius: Double = 2
    private var plot: CGRect { bounds.insetBy(dx: 34, dy: 48) }
    private let smallFont = UIFont.systemFont(ofSize: 9, weight: .medium)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        clipsToBounds = true
        layer.cornerRadius = 24
        backgroundColor = .clear
        // Reuse the existing vector atmosphere without giving it a v2 snapshot.
        atmosphere.isUserInteractionEnabled = false
        atmosphere.accessibilityElementsHidden = true
        addSubview(atmosphere)
        for symbol in StockChartsRRGResponse.symbols {
            let node = RRGNode(color: Self.color(symbol))
            node.accessibilityLabel = symbol
            node.accessibilityIdentifier = "stockcharts-point.\(symbol)"
            node.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                self.onSelection?(self.selected == symbol ? nil : symbol)
            }, for: .touchUpInside)
            node.onPress = { [weak self] pressed in
                guard let self, let value = self.weeks.last?.rrgdata[symbol] else { return }
                self.atmosphere.updateTouch(at: pressed ? self.point(value) : nil)
            }
            nodes[symbol] = node
            addSubview(node)
        }
        let tap = UITapGestureRecognizer(target: self, action: #selector(clearSelection(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        addGestureRecognizer(tap)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: StockChartsRRGChart, _: UITraitCollection) in
            view.ink.setNeedsDisplay()
            view.nodes.values.forEach { $0.setNeedsDisplay() }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(weeks: [StockChartsRRGResponse.Week], selected: String?) {
        self.weeks = weeks
        self.selected = selected
        let points = weeks.flatMap { $0.rrgdata.values }
        xRadius = max(2, ceil((points.map { abs($0.jdkratio - 100) }.max() ?? 1) * 1.15 / 2) * 2)
        yRadius = max(2, ceil((points.map { abs($0.jdkmom - 100) }.max() ?? 1) * 1.15))
        setNeedsLayout(); ink.setNeedsDisplay()
    }
    func point(_ value: StockChartsRRGResponse.Value) -> CGPoint {
        CGPoint(x: plot.midX + (value.jdkratio - 100) / xRadius * plot.width / 2,
                y: plot.midY - (value.jdkmom - 100) / yRadius * plot.height / 2)
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        atmosphere.frame = bounds
        ink.frame = bounds
        ink.setNeedsDisplay()
        for (symbol, node) in nodes {
            guard let value = weeks.last?.rrgdata[symbol] else { node.isHidden = true; continue }
            let p = point(value)
            node.isHidden = false
            node.frame = CGRect(x: p.x - 22, y: p.y - 22, width: 44, height: 44)
            node.alpha = selected == nil || selected == symbol ? 1 : 0.3
            node.chosen = selected == symbol
            node.accessibilityValue = String(format: "RS-Ratio %.2f, RS-Momentum %.2f", value.jdkratio, value.jdkmom)
        }
        if let selected, let node = nodes[selected] { bringSubviewToFront(node) }
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { atmosphere.clearTouch() }
    }
    @objc private func clearSelection(_ gesture: UITapGestureRecognizer) { onSelection?(nil) }

    private lazy var ink: RRGInk = {
        let view = RRGInk()
        view.chart = self
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        insertSubview(view, aboveSubview: atmosphere)
        return view
    }()
    fileprivate func drawChart(_ context: CGContext) {
        let grid = UIBezierPath()
        grid.move(to: CGPoint(x: plot.minX, y: plot.midY)); grid.addLine(to: CGPoint(x: plot.maxX, y: plot.midY))
        grid.move(to: CGPoint(x: plot.midX, y: plot.minY)); grid.addLine(to: CGPoint(x: plot.midX, y: plot.maxY))
        UIColor.label.withAlphaComponent(0.18).setStroke(); grid.lineWidth = 0.75; grid.stroke()
        for fraction in [-1.0, -0.5, 0, 0.5, 1] {
            let x = plot.midX + fraction * plot.width / 2
            let y = plot.midY - fraction * plot.height / 2
            let attributes: [NSAttributedString.Key: Any] = [.font: smallFont, .foregroundColor: UIColor.label.withAlphaComponent(0.45)]
            let xt = String(format: "%g", 100 + fraction * xRadius) as NSString
            let yt = String(format: "%g", 100 + fraction * yRadius) as NSString
            xt.draw(at: CGPoint(x: x - xt.size(withAttributes: attributes).width / 2, y: plot.maxY + 4), withAttributes: attributes)
            yt.draw(at: CGPoint(x: 3, y: y - 5), withAttributes: attributes)
        }
        ("JdK RS-Ratio" as NSString).draw(at: CGPoint(x: plot.midX - 29, y: bounds.height - 15), withAttributes: [.font: smallFont, .foregroundColor: UIColor.label.withAlphaComponent(0.5)])
        let momentum = "JdK RS-Momentum" as NSString
        let axisAttributes: [NSAttributedString.Key: Any] = [.font: smallFont, .foregroundColor: UIColor.label.withAlphaComponent(0.5)]
        momentum.draw(at: CGPoint(x: plot.midX - momentum.size(withAttributes: axisAttributes).width / 2, y: 25), withAttributes: axisAttributes)

        var labels: [CGRect] = []
        let order = StockChartsRRGResponse.symbols.sorted { ($0 == selected ? 1 : 0) < ($1 == selected ? 1 : 0) }
        for symbol in order {
            let points = weeks.compactMap { $0.rrgdata[symbol] }.map(point)
            guard let first = points.first, let last = points.last else { continue }
            let emphasis: CGFloat = selected == nil || selected == symbol ? 1 : 0.16
            let color = Self.color(symbol)
            let path = UIBezierPath(); path.move(to: first)
            // Gentle cubic interpolation goes through every weekly observation.
            for i in 1..<points.count {
                let p0 = points[max(0, i-2)], p1 = points[i-1], p2 = points[i], p3 = points[min(points.count-1, i+1)]
                path.addCurve(to: p2,
                    controlPoint1: CGPoint(x: p1.x + (p2.x-p0.x)/8, y: p1.y + (p2.y-p0.y)/8),
                    controlPoint2: CGPoint(x: p2.x - (p3.x-p1.x)/8, y: p2.y - (p3.y-p1.y)/8))
            }
            color.withAlphaComponent(0.7 * emphasis).setStroke()
            path.lineWidth = selected == symbol ? 2.2 : 1.35
            path.lineCapStyle = .round; path.lineJoinStyle = .round; path.stroke()
            for (i, p) in points.dropLast().enumerated() {
                let age = CGFloat(i + 1) / CGFloat(points.count)
                color.withAlphaComponent((0.15 + 0.6 * age) * emphasis).setFill()
                UIBezierPath(ovalIn: CGRect(x: p.x - 1.6, y: p.y - 1.6, width: 3.2, height: 3.2)).fill()
            }
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: color.withAlphaComponent(emphasis)]
            let text = symbol as NSString, size = text.size(withAttributes: attrs)
            var label = CGRect(x: last.x + 9, y: last.y - 7, width: size.width + 4, height: 14)
            if label.maxX > bounds.width - 5 { label.origin.x = last.x - label.width - 9 }
            for offset in [CGFloat(0), -16, 16, -30, 30] {
                let candidate = label.offsetBy(dx: 0, dy: offset)
                if !labels.contains(where: { $0.intersects(candidate) }), bounds.insetBy(dx: 2, dy: 22).contains(candidate) { label = candidate; break }
            }
            labels.append(label)
            UIColor.systemBackground.withAlphaComponent(0.65 * emphasis).setFill()
            UIBezierPath(roundedRect: label.insetBy(dx: -2, dy: -1), cornerRadius: 4).fill()
            text.draw(in: label, withAttributes: attrs)
        }
    }

    static func color(_ symbol: String) -> UIColor {
        switch symbol {
        case "$INDU": return SectorRotationChartView.color("XLF")
        case "$COMPQ": return SectorRotationChartView.color("XLI")
        case "$NYA": return SectorRotationChartView.color("XLK")
        case "$XAX": return SectorRotationChartView.color("XLY")
        case "$TSX": return SectorRotationChartView.color("XLE")
        default:
            let paint = UIColor(red: 0.56, green: 0.39, blue: 0.04, alpha: 1)
            return RotationPalette.dynamic(light: paint, dark: RotationPalette.lifted(paint))
        }
    }
}

extension StockChartsRRGChart: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        !(touch.view is UIControl)
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
}

private final class RRGInk: UIView {
    weak var chart: StockChartsRRGChart?
    override func draw(_ rect: CGRect) {
        if let context = UIGraphicsGetCurrentContext() { chart?.drawChart(context) }
    }
}

private final class RRGNode: UIControl {
    let color: UIColor
    var onPress: ((Bool) -> Void)?
    var chosen = false { didSet { setNeedsDisplay() } }
    override var isHighlighted: Bool {
        didSet {
            onPress?(isHighlighted)
            let target = isHighlighted && !UIAccessibility.isReduceMotionEnabled ? CGAffineTransform(translationX: 0, y: -4).scaledBy(x: 1.25, y: 1.25) : .identity
            UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) { self.transform = target }
        }
    }
    init(color: UIColor) {
        self.color = color
        super.init(frame: .zero)
        backgroundColor = .clear
        isAccessibilityElement = true
        accessibilityTraits = .button
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ rect: CGRect) {
        guard let c = UIGraphicsGetCurrentContext() else { return }
        let dot = CGRect(x: 15.5, y: 15.5, width: 13, height: 13)
        if chosen {
            color.withAlphaComponent(0.2).setFill(); UIBezierPath(ovalIn: dot.insetBy(dx: -5, dy: -5)).fill()
        }
        color.setFill(); UIBezierPath(ovalIn: dot).fill()
        c.saveGState(); c.addEllipse(in: dot); c.clip(); c.setBlendMode(.overlay)
        if let light = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [UIColor.white.cgColor, UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.3).cgColor] as CFArray, locations: [0, 0.5, 1]) {
            c.drawLinearGradient(light, start: CGPoint(x: 18, y: 15), end: CGPoint(x: 25, y: 30), options: [])
        }
        c.restoreGState()
        UIColor.white.withAlphaComponent(0.8).setStroke(); UIBezierPath(ovalIn: dot).stroke()
    }
    override func accessibilityActivate() -> Bool { sendActions(for: .touchUpInside); return true }
}
