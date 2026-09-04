import SwiftUI

struct ETFLookThroughView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model

    @State private var basis: ETFLookThroughBasis = .cost
    @State private var response: ETFLookThroughResponse?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchText = ""

    private var filteredRows: [ETFLookThroughRow] {
        guard let rows = response?.rows else { return [] }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return rows }
        return rows.filter { row in
            row.ticker.localizedCaseInsensitiveContains(query)
                || row.name.localizedCaseInsensitiveContains(query)
                || (row.sector?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Spacer()
                        GlassChoiceBar(
                            choices: ETFLookThroughBasis.allCases.map(\.title),
                            selection: Binding(
                                get: { basis.title },
                                set: { title in
                                    basis = ETFLookThroughBasis.allCases.first { $0.title == title } ?? .cost
                                }
                            )
                        )
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }

                if let response {
                    Section("ETF 概览") {
                        LabeledContent("包含 ETF", value: response.etfTickers.joined(separator: " · "))
                        LabeledContent("用于穿透的\(basis.title)", value: DisplayFormat.money(response.etfTotalUSD))
                        LabeledContent("成分覆盖", value: DisplayFormat.percent(response.coveredWeightPercent, signed: false))
                        LabeledContent("底层证券", value: "\(response.constituentCount) 项")

                        if let asOf = response.holdingsAsOf {
                            LabeledContent("持仓日期", value: asOf)
                        }

                        if let source = response.holdingsSource,
                           let urlText = response.holdingsSourceURL,
                           let url = URL(string: urlText) {
                            Link(destination: url) {
                                Label(source, systemImage: "arrow.up.right.square")
                            }
                        }
                    }

                    Section {
                        ForEach(filteredRows) { row in
                            ETFLookThroughRowView(row: row, basis: basis)
                        }
                    } header: {
                        HStack {
                            Text("底层暴露")
                            Spacer()
                            Text("\(filteredRows.count) 项")
                        }
                    } footer: {
                        Text(footerText(for: response))
                    }
                } else if isLoading {
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("正在展开 ETF 底层持仓…")
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if let errorMessage {
                    Section {
                        ContentUnavailableView(
                            "无法读取 ETF 穿透",
                            systemImage: "square.3.layers.3d.slash",
                            description: Text(errorMessage)
                        )
                    }
                }
            }
            .navigationTitle("ETF 穿透")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "搜索股票或行业")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }
                }
            }
            .refreshable { await load() }
            .task { await load() }
            .onChange(of: basis) { _, _ in
                Task { await load() }
            }
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            response = try await model.loadETFLookThrough(basis: basis)
        } catch {
            response = nil
            errorMessage = error.localizedDescription
        }
    }

    private func footerText(for response: ETFLookThroughResponse) -> String {
        let base = "直接持仓始终按当前市值；\(basis.title)按基金权重拆分后加入直接市值。ETF 权重来自 App 内置的官方基金持仓快照。"
        let xs2dAliases = Set(["XS2D", "XS2D.L", "DBPG", "DBPG.DE", "XS2L", "XS2L.MI"])
        guard response.etfTickers.contains(where: { xs2dAliases.contains($0.uppercased()) }) else {
            return base
        }
        return base + " XS2D 是合成日杠杆产品，这里展示标普 500 经济暴露近似；净成本和净市值只分配一次，不会再次乘 2。"
    }
}

private struct ETFLookThroughRowView: View {
    let row: ETFLookThroughRow
    let basis: ETFLookThroughBasis

    private var indirectRatio: Double {
        guard row.totalUSD > 0 else { return 0 }
        return min(max(row.fromETFUSD / row.totalUSD, 0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.ticker)
                        .font(.body.weight(.bold))
                    Text(CompanyNameCatalog.displayName(ticker: row.ticker, fallback: row.name))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(DisplayFormat.money(row.totalUSD))
                        .font(.body.weight(.semibold).monospacedDigit())
                    if row.etfWeightPercent > 0 {
                        Text("ETF 权重 \(DisplayFormat.percent(row.etfWeightPercent, signed: false))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if let sector = row.sector {
                        Text(sector)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            GeometryReader { geometry in
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(CatfolioStyle.blue)
                        .frame(width: geometry.size.width * (1 - indirectRatio))
                    Rectangle()
                        .fill(CatfolioStyle.green)
                        .frame(width: geometry.size.width * indirectRatio)
                }
                .clipShape(Capsule())
            }
            .frame(height: 5)
            .accessibilityHidden(true)

            HStack(spacing: 16) {
                exposureLabel("直接市值", value: row.directUSD, color: CatfolioStyle.blue)
                exposureLabel(basis.title, value: row.fromETFUSD, color: CatfolioStyle.green)
                Spacer()
                if row.fromETFUSD > 0 {
                    Text("间接 \(DisplayFormat.percent(indirectRatio * 100, signed: false))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }

    private func exposureLabel(_ title: String, value: Double, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text("\(title) \(DisplayFormat.money(value))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}
