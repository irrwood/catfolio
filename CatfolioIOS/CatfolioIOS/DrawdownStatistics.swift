import SwiftUI

/// Three tiles on how deep the portfolio fell from its high in the range
/// shown, how quickly it came back from the deepest point, and its longest
/// time below a high. Moved unchanged from the former underwater analysis.
struct DrawdownStatistics: View {
    let series: UnderwaterSeries
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let trough = series.trough
        let recovery = series.recovery
        let recoveryText: String = {
            guard let trough, trough.drawdown < 0 else { return L10n.text("没有回撤") }
            guard let recovery else { return L10n.text("还没收复") }
            let days = Calendar(identifier: .gregorian).dateComponents([.day], from: trough.date, to: recovery.date).day ?? 0
            return L10n.text("\(days) 天收复")
        }()
        HStack(alignment: .top, spacing: 10) {
            statistic(L10n.text("最大回撤"), Self.percent(series.maxDrawdown),
                      trough.map { $0.date.formatted(.dateTime.month(.abbreviated).day()) } ?? "",
                      color: series.maxDrawdown < 0 ? CatfolioTheme.loss(for: colorScheme) : .primary)
            statistic(L10n.text("从最深处"), recoveryText,
                      recovery.map { $0.date.formatted(.dateTime.month(.abbreviated).day()) } ?? "", color: .primary)
            statistic(L10n.text("最长水下"), L10n.text("\(series.longestUnderwaterDays) 天"),
                      series.daysUnderwater > 0 ? L10n.text("现在已 \(series.daysUnderwater) 天") : L10n.text("现在在高点"),
                      color: .primary)
        }
    }

    private func statistic(_ title: String, _ value: String, _ detail: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).appText(.caption, weight: .medium).foregroundStyle(.secondary)
            Text(value).appNumber(.callout, weight: .semibold).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.7)
            Text(detail).appText(.caption).foregroundStyle(.tertiary).lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    static func percent(_ fraction: Double) -> String {
        abs(fraction) < 0.00005 ? "0%" : DisplayFormat.percent(fraction * 100)
    }
}
