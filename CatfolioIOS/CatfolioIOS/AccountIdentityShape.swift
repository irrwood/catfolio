import SwiftUI

/// A slightly fuller take on the portfolio-avatar reference. The exponent 2.6
/// opens the corners a little while keeping the sides gently curved.
struct AccountIdentityShape: Shape {
    func path(in rect: CGRect) -> Path {
        guard rect.width > 0, rect.height > 0 else { return Path() }
        return Self.unitPath.applying(CGAffineTransform(
            a: rect.width, b: 0, c: 0, d: rect.height, tx: rect.minX, ty: rect.minY
        ))
    }

    // Cache smooth cubic segments once; resizing the badge only scales the path.
    // Polar coordinates keep finite tangents at the four cardinal points.
    private static let unitPath: Path = {
        let exponent = 2.6
        let segments = 32
        let step = 2 * Double.pi / Double(segments)

        func signedPower(_ value: Double) -> Double {
            value < 0 ? -pow(-value, exponent - 1) : pow(value, exponent - 1)
        }

        func sample(_ angle: Double) -> (point: CGPoint, tangent: CGVector) {
            let x = cos(angle), y = sin(angle)
            let sum = pow(abs(x), exponent) + pow(abs(y), exponent)
            let radius = pow(sum, -1 / exponent)
            let slope = radius * (signedPower(x) * y - signedPower(y) * x) / sum
            return (
                CGPoint(x: 0.5 + radius * x / 2, y: 0.5 + radius * y / 2),
                CGVector(dx: (slope * x - radius * y) / 2,
                         dy: (slope * y + radius * x) / 2)
            )
        }

        var path = Path()
        var start = sample(0)
        path.move(to: start.point)
        for index in 1...segments {
            let end = sample(Double(index) * step)
            path.addCurve(
                to: end.point,
                control1: CGPoint(x: start.point.x + start.tangent.dx * step / 3,
                                  y: start.point.y + start.tangent.dy * step / 3),
                control2: CGPoint(x: end.point.x - end.tangent.dx * step / 3,
                                  y: end.point.y - end.tangent.dy * step / 3)
            )
            start = end
        }
        path.closeSubpath()
        return path
    }()
}
