import Foundation

/// Read-only adapter. It never calls a broker, submits an order, alters FX
/// tables or writes the portfolio. The app's split-only Yahoo/cache route is
/// reused so this feature cannot change financial calculations elsewhere.
actor PolicyMarketAdapter {
    func simulationBudget(_ entered: PolicyBudget?, positions data: Data, snapshots: [PolicySecuritySnapshot]) throws -> PolicyBudget? {
        guard let entered else { return nil }
        let positions = try JSONDecoder().decode([LocalPositionRecord].self, from: data)
        let catalog = try CompanyReferenceCatalog.bundled.get()
        var exposure: [String: Double] = [:]
        for position in positions where position.shares != 0 {
            guard position.shares.isFinite, position.shares >= 0, position.quoteCurrency.uppercased() == entered.currency,
                  let entry = catalog.entry(brokerSymbol: position.ticker),
                  let snapshot = snapshots.first(where: { $0.symbol == entry.symbol }), snapshot.issue == nil,
                  let price = snapshot.prices.last?.close, price > 0 else { return nil }
            exposure[snapshot.key, default: 0] += price * position.shares
        }
        return PolicyBudget(nav: entered.nav, currency: entered.currency, existingExposure: exposure)
    }
    func freezePositions(document: PolicyJSON) async throws -> Data {
        let ids = Set(document["accountScope"]["accountIds"].array.map(\.string))
        let ledger = try await LocalPortfolioStore.shared.load()
        guard ledger.isSynthetic != true else { throw PolicyContractError(message: L10n.text("合成组合不能进入真实账户运行或发送至AI服务")) }
        if ledger.accounts.contains(where: { $0.name.hasPrefix("QA 策略验收") }), document["nodes"].array.contains(where: { $0["type"].string == "ai" }) { throw PolicyContractError(message: "QA合成验收账户不发送AI，仅验证公开行情") }
        guard !ids.isEmpty, ids.isSubset(of: Set(ledger.accounts.map(\.id))) else { throw PolicyContractError(message: L10n.text("账户已不存在或未选择；不能自动扩展为全部账户")) }
        let scoped = ledger.scoped(to: ids)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(scoped.positions)
    }
    func capture(document: PolicyJSON, frozenPositions: Data, alreadyCaptured: [PolicySecuritySnapshot], onCapture: @Sendable (PolicySecuritySnapshot) async throws -> Void) async throws -> [PolicySecuritySnapshot] {
        let positions = try JSONDecoder().decode([LocalPositionRecord].self, from: frozenPositions)
        let catalog = try CompanyReferenceCatalog.bundled.get()
        let formatter = ISO8601DateFormatter()
        guard let asOf = formatter.date(from: document["dataPolicy"]["asOf"].string), asOf <= Date.now else { throw PolicyContractError(message: L10n.text("数据截止时间无效或位于未来")) }
        // This adapter has current, snapshot-only listing metadata. It cannot
        // establish what was known on a historical date.
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
        guard utc.isDate(asOf, inSameDayAs: .now) else { throw PolicyContractError(message: L10n.text("当前适配器不提供历史时点可得性。请明确更新数据截止时间为今天；不会自动改动策略。")) }
        let sessions = try PolicyUSSessionCalendar.completedSessions(asOf: asOf)
        guard let end = sessions.last else { throw PolicyContractError(message: L10n.text("截止时间内没有已完成且日历覆盖的交易日")) }
        let start = "2026-01-01"
        let client = LocalMarketDataClient()
        guard let lastSession = sessions.last, let lastDate = DayDateCodec.date(from: lastSession), let allowed = Int(document["dataPolicy"]["maxAgeDays"]["value"].string) else { throw PolicyContractError(message: L10n.text("交易日参考或允许陈旧天数不可用")) }
        let age = utc.dateComponents([.day], from: lastDate, to: utc.startOfDay(for: asOf)).day ?? Int.max
        guard age >= 0, age <= allowed else { throw PolicyContractError(message: L10n.text("市场数据已超出允许的陈旧天数")) }
        var captured = alreadyCaptured
        var seen = Set<String>()
        for position in positions where position.shares > 0 {
            try Task.checkCancellation()
            // A holding this adapter cannot price stays in the run with its
            // reason, rather than stopping the run for everything else: it
            // reaches no indicator, so no step can treat it as passing.
            func unsupported(_ reason: String) async throws {
                let symbol = position.ticker.uppercased()
                let key = "unsupported:" + symbol + "/" + symbol
                guard seen.insert(key).inserted, !captured.contains(where: { $0.key == key }) else { return }
                let snapshot = PolicySecuritySnapshot(securityId: "unsupported:" + symbol, listingId: symbol, symbol: symbol, name: position.name,
                                                      currency: position.quoteCurrency.uppercased(), exchangeMIC: "", prices: [], referenceSessions: sessions,
                                                      source: L10n.text("未取行情"), capturedAt: .now, issue: reason)
                try await onCapture(snapshot)
                captured.append(snapshot)
            }
            guard let entry = catalog.entry(brokerSymbol: position.ticker), entry.market == "US", entry.currency == "USD", position.quoteCurrency.uppercased() == "USD" else {
                try await unsupported(L10n.text("暂不支持：目前只支持美元计价的美股"))
                continue
            }
            let exchange = entry.exchange?.uppercased() ?? ""
            let mic: String
            if exchange.contains("NASDAQ") { mic = "XNAS" }
            else if exchange == "NYSE" || exchange.contains("NEW YORK") { mic = "XNYS" }
            else if exchange.contains("ARCA") || exchange.contains("AMEX") { mic = "ARCX" }
            else {
                try await unsupported(L10n.text("暂不支持：还没有这家交易所的交易日历"))
                continue
            }
            let securityID = "reference:US:" + entry.symbol
            let listingID = mic + ":" + entry.symbol + ":USD"
            let key = securityID + "/" + listingID
            guard seen.insert(key).inserted else { continue }
            if captured.contains(where: { $0.key == key }) { continue }
            let history = await client.historicalCloses(symbols: [entry.symbol], from: start, to: end, dividendAdjusted: false)[entry.symbol] ?? [:]
            try Task.checkCancellation()
            let prices = history.filter { $0.key <= end && $0.value.isFinite && $0.value > 0 }.sorted { $0.key < $1.key }.map { PolicyPricePoint(day: $0.key, close: $0.value) }
            let snapshot = PolicySecuritySnapshot(securityId: securityID, listingId: listingID, symbol: entry.symbol, name: entry.name ?? position.name, currency: "USD", exchangeMIC: mic, prices: prices, referenceSessions: sessions, source: L10n.text("Yahoo 日线 / 本机 split-only 缓存；company_reference \(catalog.generatedOn)；2026计划交易日：\(PolicyUSSessionCalendar.sources)"), capturedAt: .now, issue: prices.last?.day == lastSession ? nil : L10n.text("最新完整日线缺失或落后于计划交易日"))
            try await onCapture(snapshot)
            captured.append(snapshot)
        }
        guard captured.contains(where: { $0.issue == nil || !$0.prices.isEmpty }) else {
            throw PolicyContractError(message: captured.isEmpty ? L10n.text("当前账户没有可分析的持仓") : L10n.text("所选账户里没有能取到行情的美股持仓"))
        }
        return captured
    }
}
