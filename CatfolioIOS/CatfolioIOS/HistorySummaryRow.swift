import SwiftUI

enum HistorySummaryLayout {
    static let detailSpacing: CGFloat = 8
}

/// Shared by every History category: Figma 625:22109's 24-point icon,
/// 17-point label, 15-point value and the settings row's 20/16 padding.
struct HistorySummaryRow: View {
    let title: String
    var icon: SettingsIconSource? = nil
    let value: String
    var valueColor: Color = CatfolioTheme.primaryText

    var body: some View {
        SettingsRowContainer {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: SettingsTemplate.iconSpacing) {
                    HistorySummaryLabel(title: title, icon: icon).fixedSize()
                    Spacer(minLength: 0)
                    amount.fixedSize()
                }
                VStack(alignment: .leading, spacing: HistorySummaryLayout.detailSpacing) {
                    HistorySummaryLabel(title: title, icon: icon)
                    amount
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var amount: some View {
        FinancialText(value)
            .appNumber(.callout, weight: .semibold)
            .foregroundStyle(valueColor)
    }
}

struct HistorySummaryLabel: View {
    let title: String
    var icon: SettingsIconSource? = nil

    var body: some View {
        HStack(spacing: SettingsTemplate.iconSpacing) {
            if let icon { SettingsRowIcon(icon) }
            Text(title).appText(.subheading, weight: .medium)
        }
        .foregroundStyle(CatfolioTheme.primaryText)
    }
}

/// The amount's own sign supplies the operator between currencies, avoiding
/// double signs such as "+ +£20" or "+ -£20". The first amount stays signed.
struct HistoryCurrencyAmountTerm {
    let operation: String?
    let amount: String

    init(_ value: String, isFirst: Bool) {
        guard !isFirst else {
            operation = nil
            amount = value
            return
        }
        if let sign = value.first, ["+", "-", "−"].contains(sign) {
            operation = String(sign)
            amount = String(value.dropFirst())
        } else {
            operation = "+"
            amount = value
        }
    }
}

/// Keep each amount intact, with an 8-point gap around its arithmetic sign.
/// The sign wraps together with the currency that follows it.
struct HistoryCurrencyAmounts: View {
    let values: [String]

    var body: some View {
        HistoryCurrencyAmountLayout {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                let term = HistoryCurrencyAmountTerm(value, isFirst: index == 0)
                HStack(spacing: HistorySummaryLayout.detailSpacing) {
                    if let operation = term.operation { Text(verbatim: operation) }
                    FinancialText(term.amount).lineLimit(1).minimumScaleFactor(0.6)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: value))
            }
        }
        .appNumber(.callout, weight: .semibold)
        .foregroundStyle(SettingsTemplate.secondaryText)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct HistoryCurrencyAmountLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = arrange(width: bounds.width, subviews: subviews)
        for (index, frame) in layout.frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                                 proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        let gap = HistorySummaryLayout.detailSpacing
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0
        for view in subviews {
            let ideal = view.sizeThatFits(.unspecified)
            let size = ideal.width > width
                ? view.sizeThatFits(ProposedViewSize(width: width, height: nil)) : ideal
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + gap
                rowHeight = 0
            }
            frames.append(CGRect(x: x, y: y, width: size.width, height: size.height))
            maxX = max(maxX, x + size.width)
            rowHeight = max(rowHeight, size.height)
            x += size.width + gap
        }
        return (CGSize(width: width.isFinite ? width : maxX, height: y + rowHeight), frames)
    }
}
