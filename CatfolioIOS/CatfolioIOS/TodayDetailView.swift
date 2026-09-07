import SwiftUI

/// The full attribution behind the TODAY figure on the home page.
///
/// Everything here is arithmetic on data the app already holds: each holding's
/// market value and its daily change. Nothing is fetched, and nothing is
/// generated — the summary line is a sort, not a model's opinion, so it cannot
/// be wrong in a way the numbers beside it are not.
struct TodayDetailView: View {
    struct Contribution: Identifiable {
        let holding: Holding
        let changePercent: Double
        let amount: Double

        var id: String { holding.ticker }
    }

    let holdings: [Holding]
    let dailyChanges: [String: Double]
    let benchmarkChange: Double?

    private var contributions: [Contribution] {
        holdings.compactMap { holding in
            let key = holding.ticker.uppercased()
            guard let change = dailyChanges[key] ?? holding.todayChangePercent,
                  change.isFinite, holding.marketValue.isFinite else { return nil }
            // Yesterday's value moved by `change`, so today's move is the part
            // of the current value that the change accounts for.
            let previous = holding.marketValue / (1 + change / 100)
            let amount = holding.marketValue - previous
            guard amount.isFinite else { return nil }
            return Contribution(holding: holding, changePercent: change, amount: amount)
        }
        .sorted { $0.amount > $1.amount }
    }

    private var total: Double { contributions.reduce(0) { $0 + $1.amount } }
    private var gainers: [Contribution] { contributions.filter { $0.amount > 0 } }
    private var losers: [Contribution] { contributions.filter { $0.amount < 0 }.reversed() }
    private var largestMagnitude: Double {
        max(contributions.map { abs($0.amount) }.max() ?? 1, 0.01)
    }

    /// Sum of every move regardless of sign — how much actually happened today,
    /// as opposed to what survived the offsetting.
    private var grossMovement: Double {
        contributions.reduce(0) { $0 + abs($1.amount) }
    }

    /// "X drove N% of today's gain" — derived, not written by a model.
    ///
    /// Measured against the net figure, which is what the headline claims to
    /// explain. When gains and losses nearly cancel, that denominator collapses
    /// and any single holding "explains" several hundred percent of it — so
    /// below a meaningful net, the honest statement is that the day offset
    /// itself, not that one stock drove it.
    private var headline: String? {
        guard !contributions.isEmpty, grossMovement > 0.01 else { return nil }

        // A day is only "driven" if the net is a real share of what moved.
        guard abs(total) >= grossMovement * 0.2 else {
            return "涨跌基本抵消：合计变动 \(DisplayFormat.money(grossMovement, fractionDigits: 0))，净额 \(DisplayFormat.money(total, signed: true, fractionDigits: 2))"
        }

        // The leader has to move the same way the day did.
        let sameDirection = contributions.filter { total >= 0 ? $0.amount > 0 : $0.amount < 0 }
        guard let leader = sameDirection.max(by: { abs($0.amount) < abs($1.amount) }) else { return nil }
        let share = min(100, abs(leader.amount) / abs(total) * 100)
        guard share.isFinite, share >= 15 else { return nil }
        let verb = total >= 0 ? "涨幅" : "跌幅"
        return "\(leader.holding.shortName) 贡献了今日 \(share.formatted(.number.precision(.fractionLength(0))))% 的\(verb)"
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("今日盈亏")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(DisplayFormat.money(total, signed: true, fractionDigits: 2))
                        .font(.largeTitle.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(total >= 0 ? CatfolioTheme.positive : CatfolioTheme.danger)
                        .contentTransition(.numericText(value: total))
                    if let benchmarkChange, benchmarkChange.isFinite {
                        HStack(spacing: 5) {
                            Image(systemName: "chart.line.uptrend.xyaxis")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(CatfolioTheme.accent)
                            Text("S&P 500")
                                .font(.subheadline).foregroundStyle(.secondary)
                            Text(DisplayFormat.percent(benchmarkChange, signed: true))
                                .font(.subheadline.weight(.medium)).monospacedDigit()
                                .foregroundStyle(benchmarkChange >= 0 ? CatfolioTheme.positive : CatfolioTheme.danger)
                        }
                        .padding(.top, 2)
                    }
                    if let headline {
                        Text(headline)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    }
                }
                .padding(.vertical, 6)
            }

            if !gainers.isEmpty {
                Section {
                    ForEach(gainers) { contributionRow($0) }
                } header: {
                    Text("推动上涨 · \(gainers.count) 项")
                }
                .headerProminence(.increased)
            }

            if !losers.isEmpty {
                Section {
                    ForEach(losers) { contributionRow($0) }
                } header: {
                    Text("拖累下跌 · \(losers.count) 项")
                }
                .headerProminence(.increased)
            }

            if contributions.isEmpty {
                Section {
                    ContentUnavailableView(
                        "暂无今日行情",
                        systemImage: "chart.bar.xaxis",
                        description: Text("持仓的当日涨跌还没有读取到。")
                    )
                }
            } else {
                Section {
                    Text("按持仓当前市值和当日涨跌推算，未计入今日的买入卖出。行情为各标的最近可用报价。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("今日")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func contributionRow(_ contribution: Contribution) -> some View {
        let tint = contribution.amount >= 0 ? CatfolioTheme.positive : CatfolioTheme.danger
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(contribution.holding.shortName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(DisplayFormat.money(contribution.amount, signed: true, fractionDigits: 2))
                    .font(.body.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(tint)
            }
            HStack(spacing: 8) {
                // Bars are scaled against the largest single move, so the row
                // shows how much of today this holding actually accounts for.
                GeometryReader { geo in
                    let ratio = abs(contribution.amount) / largestMagnitude
                    Capsule()
                        .fill(tint.opacity(0.85))
                        .frame(width: max(3, geo.size.width * ratio), height: 5)
                }
                .frame(height: 5)
                Text(DisplayFormat.percent(contribution.changePercent, signed: true))
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 62, alignment: .trailing)
            }
        }
        .padding(.vertical, 3)
    }
}
