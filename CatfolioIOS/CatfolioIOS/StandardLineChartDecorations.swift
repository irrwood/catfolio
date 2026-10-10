import SwiftUI
import UIKit

struct StandardLineChartGlassGuide: View {
    let tint: Color

    @ViewBuilder
    var body: some View {
        let shape = Capsule()
        let guide = Color.clear

        if #available(iOS 26.0, *) {
            guide
                .glassEffect(.clear.tint(tint.opacity(0.34)), in: shape)
                .overlay {
                    shape
                        .fill(Color.white.opacity(0.05))
                }
        } else {
            guide
                .background(.ultraThinMaterial, in: shape)
                .overlay {
                    shape
                        .fill(tint.opacity(0.16))
                }
                .overlay {
                    shape
                        .stroke(Color.white.opacity(0.28), lineWidth: 0.35)
                }
        }
    }
}

struct StandardLineChartGlassSelectionPoint: View {
    let color: Color
    let diameter: CGFloat

    @ViewBuilder
    var body: some View {
        let shape = Circle()
        let point = shape
            .fill(color.opacity(0.12))
            .frame(width: diameter, height: diameter)

        if #available(iOS 26.0, *) {
            point
                .glassEffect(.clear.tint(color.opacity(0.30)), in: shape)
                .overlay {
                    shape
                        .strokeBorder(Color.white.opacity(0.38), lineWidth: 0.5)
                        .padding(0.5)
                }
        } else {
            point
                .background(.ultraThinMaterial, in: shape)
                .overlay {
                    shape
                        .fill(color.opacity(0.18))
                }
                .overlay {
                    shape
                        .strokeBorder(Color.white.opacity(0.42), lineWidth: 0.55)
                }
        }
    }
}

struct StandardLineChartDateBubble: View {
    let label: String

    var body: some View {
        let content = Text(label)
            .font(Typography.number(.caption, weight: .semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: 28)

        if #available(iOS 26.0, *) {
            content
                .glassEffect(.clear, in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                }
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                }
        }
    }
}

struct StandardLineChartPlainEndpoint: View {
    let color: Color
    let radius: CGFloat

    var body: some View {
        let ringWidth = max(2.2, radius * 0.44)
        ZStack {
            Circle()
                .fill(Color.black)
                .blendMode(.destinationOut)

            Circle()
                .strokeBorder(color, lineWidth: ringWidth)
        }
        .frame(width: radius * 2, height: radius * 2)
        .accessibilityHidden(true)
    }
}

struct StandardLineChartGlassEndpoint: View {
    let color: Color
    let radius: CGFloat
    var isDimmed = false

    @ViewBuilder
    var body: some View {
        let shape = Circle()
        let diameter = radius * 2
        let ringWidth = max(2.1, radius * 0.42)

        if isDimmed {
            shape
                .strokeBorder(color.opacity(0.30), lineWidth: 1.35)
                .frame(width: diameter, height: diameter)
        } else {
            ZStack {
                shape
                    .stroke(color.opacity(0.28), lineWidth: ringWidth + 2.5)
                    .blur(radius: radius * 0.55)

                shape
                    .fill(Color(uiColor: .systemBackground))

                shape
                    .strokeBorder(color, lineWidth: ringWidth)

                shape
                    .strokeBorder(Color.white.opacity(0.34), lineWidth: 0.65)
                    .padding(ringWidth * 0.34)
            }
            .frame(width: diameter, height: diameter)
            .shadow(color: color.opacity(0.22), radius: radius * 0.9)
        }
    }
}

/// Quadratic fillets with a shared horizontal radius keep stacked boundaries
/// ordered: all layers use the same positive interpolation weights and dates.
/// Rounding is opt-in and does not change source values or the selection readout.
enum StandardLineChartRoundedPath {
    static func make(_ points: [CGPoint], radius: CGFloat) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard radius > 0, points.count > 2 else {
            for point in points.dropFirst() { path.addLine(to: point) }
            return path
        }
        for index in 1..<(points.count - 1) {
            let previous = points[index - 1], vertex = points[index], next = points[index + 1]
            let left = vertex.x - previous.x, right = next.x - vertex.x
            guard left > 0, right > 0 else { path.addLine(to: vertex); continue }
            let width = min(radius, min(left, right) / 2)
            let entry = CGPoint(x: vertex.x - width,
                                y: vertex.y + (previous.y - vertex.y) * width / left)
            let exit = CGPoint(x: vertex.x + width,
                               y: vertex.y + (next.y - vertex.y) * width / right)
            path.addLine(to: entry)
            path.addQuadCurve(to: exit, control: vertex)
        }
        path.addLine(to: points[points.count - 1])
        return path
    }
}
