import SwiftUI

/// Three tiles on how deep the portfolio fell from its high in the range
/// shown, how quickly it came back from the deepest point, and its longest
/// time below a high. Moved unchanged from the former underwater analysis.
struct DrawdownStatistics: View {
    let series: UnderwaterSeries?

    var body: some View {
        let trough = series?.trough
        let recovery = series?.recovery
        let recoveryText: String = {
            guard series != nil else { return "—" }
            guard let trough, trough.drawdown < 0 else { return L10n.text("没有回撤") }
            guard let recovery else { return L10n.text("还没收复") }
            let days = Calendar(identifier: .gregorian).dateComponents([.day], from: trough.date, to: recovery.date).day ?? 0
            return L10n.text("\(days) 天收复")
        }()
        HStack(alignment: .top, spacing: 10) {
            statistic(L10n.text("最大回撤"), series.map { Self.percent($0.maxDrawdown) } ?? "—",
                      trough.map { $0.date.formatted(.dateTime.month(.abbreviated).day()) } ?? "",
                      color: .white)
            statistic(L10n.text("从最深处"), recoveryText,
                      recovery.map { $0.date.formatted(.dateTime.month(.abbreviated).day()) } ?? "", color: .white)
            statistic(L10n.text("最长水下"), series.map { L10n.text("\($0.longestUnderwaterDays) 天") } ?? "—",
                      series.map { $0.daysUnderwater > 0 ? L10n.text("现在已 \($0.daysUnderwater) 天") : L10n.text("现在在高点") } ?? " ",
                      color: .white)
        }
    }

    private func statistic(_ title: String, _ value: String, _ detail: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).appText(.caption, weight: .medium).foregroundStyle(Color.white.opacity(0.65))
            // Reserve the unscaled line height even when a long value must
            // shrink, including at accessibility sizes and before data arrives.
            Text("0")
                .appNumber(.callout, weight: .semibold)
                .hidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .leading) {
                    FinancialText(value).appNumber(.callout, weight: .semibold)
                        .foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.7)
                }
            Text(detail.isEmpty ? " " : detail).appText(.caption).foregroundStyle(Color.white.opacity(0.5)).lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    static func percent(_ fraction: Double) -> String {
        abs(fraction) < 0.00005 ? "0%" : DisplayFormat.percent(fraction * 100)
    }
}
