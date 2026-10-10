import SwiftUI

/// Keep the plot's normal width until the labels reach their readable minimum.
/// Tick prices and both on/off-scale costs share one size and one reserved column.
struct SecurityPriceAxisLayout {
    static let defaultWidth: CGFloat = 49
    static let horizontalPadding: CGFloat = 8

    struct Key: Equatable {
        let labels: [String]
        let preferredFontSize: CGFloat
        let minimumFontSize: CGFloat
    }

    let fontSize: CGFloat
    let width: CGFloat

    init(_ key: Key) {
        let minimum = min(key.minimumFontSize, key.preferredFontSize)
        let available = Self.defaultWidth - Self.horizontalPadding
        func widest(at size: CGFloat) -> CGFloat {
            key.labels.map { Typography.numberWidth($0, size: size, weight: .semibold) }.max() ?? 0
        }

        if widest(at: key.preferredFontSize) <= available {
            fontSize = key.preferredFontSize
            width = Self.defaultWidth
        } else if widest(at: minimum) > available {
            fontSize = minimum
            width = ceil(widest(at: minimum) + Self.horizontalPadding)
        } else {
            var lower = minimum
            var upper = key.preferredFontSize
            for _ in 0..<10 {
                let candidate = (lower + upper) / 2
                if widest(at: candidate) <= available { lower = candidate }
                else { upper = candidate }
            }
            fontSize = lower
            width = Self.defaultWidth
        }
    }
}
