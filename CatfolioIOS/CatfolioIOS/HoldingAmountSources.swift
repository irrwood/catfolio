import SwiftUI

struct HoldingAmountSourcesCard: View {
    let ticker: String
    @State private var showsSources = false

    var body: some View {
        Button { showsSources = true } label: {
            HoldingDetailActionCardLabel(title: L10n.text("金额来源"),
                subtitle: L10n.text("直接持仓与 ETF 持仓"))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("holding-amount-sources-entry")
        .appSheet(isPresented: $showsSources) {
            HoldingAmountSourcesPage(ticker: ticker)
        }
    }
}

/// Portfolio-scoped amounts, using the same calculation as the merged list.
/// Load only when this child page opens, leaving the stock's zoom path unchanged.
struct HoldingAmountSourcesPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let ticker: String
    private let initialRow: ETFLookThroughRow?
    @State private var row: ETFLookThroughRow?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var retryRevision = 0

    init(ticker: String, initialRow: ETFLookThroughRow? = nil) {
        self.ticker = ticker
        self.initialRow = initialRow
        _row = State(initialValue: initialRow)
        _isLoading = State(initialValue: initialRow == nil)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let row {
                    HoldingAmountSourcesList(row: row)
                } else if isLoading {
                    ProgressView()
                } else if let errorMessage {
                    ContentUnavailableView {
                        Label(L10n.text("暂时无法加载"), systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button(L10n.text("重试")) { retryRevision += 1 }
                    }
                } else {
                    ContentUnavailableView(L10n.text("暂无持仓数据"), systemImage: "tray")
                }
            }
            .navigationTitle(ticker == "ETF 其他" ? L10n.text("ETF 其他") : ticker)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { AppModalDoneButton { dismiss() } }
            }
        }
        .task(id: "\(model.portfolioSource)|\(model.portfolioChartRevision)|\(retryRevision)") {
            guard initialRow == nil else { return }
            isLoading = true
            errorMessage = nil
            do {
                let response = try await model.loadETFLookThrough(basis: .market)
                guard !Task.isCancelled else { return }
                row = response.rows.first { $0.ticker.caseInsensitiveCompare(ticker) == .orderedSame }
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = L10n.message(error.localizedDescription)
            }
            isLoading = false
        }
    }
}

struct HoldingAmountSourcesList: View {
    let row: ETFLookThroughRow

    var body: some View {
        List {
            Section(L10n.text("合并金额")) {
                amountRow("市值", row.totalUSD)
                amountRow("分摊成本", row.allocatedCostUSD)
            }
            Section(L10n.text("金额来源")) {
                if row.directUSD != 0 { amountRow("直接持仓", row.directUSD) }
                ForEach((row.fundMarketValues ?? [:]).keys.sorted(), id: \.self) { fund in
                    amountRow(fund, row.fundMarketValues?[fund])
                }
            }
        }
        .accessibilityIdentifier("holding-amount-sources-list")
    }

    private func amountRow(_ title: String, _ value: Double?) -> some View {
        LabeledContent(L10n.label(title)) {
            Text(value.map { DisplayFormat.money($0, fractionDigits: 2) } ?? "—")
                .appNumber(.body)
        }
    }
}
