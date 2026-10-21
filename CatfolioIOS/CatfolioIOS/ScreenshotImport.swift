import Foundation

/// A draft is deliberately text, so missing and uncertain OCR values stay editable.
struct ScreenshotHoldingDraft: Identifiable, Equatable, Sendable {
    var id = UUID()
    var ticker = ""
    var name = ""
    var shares = ""
    var averageCost = ""
    var price = ""
    var currency = ""

    var problem: String? {
        guard ScreenshotImportParser.isTicker(ticker.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()) else {
            return L10n.text("请核对股票代码；港股和 A 股请包含交易所后缀。")
        }
        guard let quantity = ScreenshotImportParser.number(shares), quantity > 0 else {
            return L10n.text("请补全有效的持仓数量。")
        }
        guard let cost = ScreenshotImportParser.number(averageCost), cost >= 0 else {
            return L10n.text("请补全每股成本，不能用市值或盈亏代替。")
        }
        guard let quote = ScreenshotImportParser.number(price), quote > 0 else {
            return L10n.text("请补全截图中的每股现价。")
        }
        guard let rate = LocalPortfolioEngine.usdRate(for: currency.trimmingCharacters(in: .whitespacesAndNewlines)),
              rate.isFinite, rate > 0 else {
            return L10n.text("请核对价格币种，例如 USD、HKD、CNY 或 GBX。")
        }
        guard (quantity * cost * rate).isFinite, (quantity * quote * rate).isFinite else {
            return L10n.text("持仓金额超出可处理范围。")
        }
        return nil
    }
}

struct ScreenshotImportError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum ScreenshotImport {
    static let source = "Screenshot"

    static func positions(_ drafts: [ScreenshotHoldingDraft], accountID: String,
                          accountName: String) throws -> [LocalPositionRecord] {
        guard drafts.count <= 200 else {
            throw ScreenshotImportError(message: L10n.text("单次最多导入 200 项持仓，请分批选择截图。"))
        }
        guard !drafts.isEmpty, !accountID.isEmpty,
              !accountName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ScreenshotImportError(message: L10n.text("请先识别持仓并填写账户名称。"))
        }
        var seen = Set<String>()
        return try drafts.map { draft in
            if let problem = draft.problem { throw ScreenshotImportError(message: problem) }
            let ticker = ScreenshotImportParser.normalizedTicker(draft.ticker)
            guard seen.insert(ticker).inserted else {
                throw ScreenshotImportError(message: L10n.text("截图中有重复股票，请保留一条正确的持仓。"))
            }
            let currency = draft.currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            return LocalPositionRecord(
                ticker: ticker, name: draft.name.isEmpty ? ticker : draft.name,
                shares: ScreenshotImportParser.number(draft.shares)!,
                averageCost: ScreenshotImportParser.number(draft.averageCost)!,
                currency: currency, quotePrice: ScreenshotImportParser.number(draft.price)!,
                quoteCurrency: currency, source: source, openedDate: nil,
                accountID: accountID, accountName: accountName, accountCurrency: currency
            )
        }
    }
}

/// Normalized coordinates, with y measured down from the image's top.
struct ScreenshotTextBox: Sendable {
    let text: String
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    var midX: Double { x + width / 2 }
    var midY: Double { y + height / 2 }
}

/// Conservative table and labelled-card extraction. Never infer shares from
/// market value, or confuse a total cost / return with a per-share cost.
enum ScreenshotImportParser {
    private enum Field: Hashable {
        case ticker, shares, cost, price, currency, valueShares, priceCost, costPrice
    }
    private static let labels: [Field: Set<String>] = [
        .ticker: ["ticker", "symbol", "stock", "股票", "代码", "股票代码", "股票名称", "名称", "名称代码", "名称/代码"],
        .shares: ["shares", "quantity", "qty", "数量", "持仓数量", "持股数量", "持仓股数", "股数"],
        .cost: ["averagecost", "avgcost", "avgprice", "averageprice", "costpershare",
                "成本价", "平均成本", "每股成本", "买入均价", "成本均价"],
        .price: ["price", "lastprice", "currentprice", "marketprice", "现价", "最新价", "当前价"],
        .currency: ["currency", "ccy", "币种", "货币"],
        .valueShares: ["市值/数量", "市值/持仓", "市值/股数", "marketvalue/shares", "value/quantity"],
        .priceCost: ["现价/成本", "现价/成本价", "最新价/成本价", "price/cost"],
        .costPrice: ["成本/现价", "成本价/现价", "cost/price"]
    ]
    private static let reserved = Set(["USD", "GBP", "GBX", "EUR", "HKD", "CNY", "CNH", "CAD",
                                       "AUD", "SGD", "JPY", "ETF", "TOTAL", "P", "L", "P&L",
                                       "BUY", "SELL", "ISA", "NASDAQ", "NYSE", "AMEX",
                                       "CASH", "ACCOUNT", "ASSETS", "HOLDINGS", "PORTFOLIO",
                                       "BALANCE", "PROFIT", "LOSS", "VALUE", "COST", "RETURN", "RETURNS"])

    static func isTicker(_ text: String) -> Bool {
        let value = normalizedTicker(text)
        guard !reserved.contains(value), field(value) == nil else { return false }
        return value.range(of: #"^(?:[A-Z][A-Z0-9]{0,9}(?:[.-][A-Z]{1,4})?|[0-9]{4,6}\.(?:HK|SS|SZ|BJ))$"#,
                           options: .regularExpression) != nil
    }

    static func normalizedTicker(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if value.hasPrefix("US.") { value.removeFirst(3) }
        if value.hasSuffix(".US") { value.removeLast(3) }
        if value.hasPrefix("HK."), value.dropFirst(3).allSatisfy(\.isNumber) {
            value = String(value.dropFirst(3)) + ".HK"
        }
        if value.hasSuffix(".HK") {
            let digits = value.dropLast(3)
            if (1...6).contains(digits.count), digits.allSatisfy(\.isNumber),
               let code = Int(digits), code > 0 {
                value = String(format: "%04d.HK", code)
            }
        }
        if value.hasSuffix(".SH") { value = String(value.dropLast(3)) + ".SS" }
        return value
    }

    static func number(_ raw: String) -> Double? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{2212}", with: "-")
        // Currency marks are allowed, percentages, suffix multipliers and OCR
        // substitutions are not. Commas must form valid thousands groups.
        for prefix in ["US$", "HK$", "CN¥", "$", "£", "€", "¥"] where value.hasPrefix(prefix) {
            value.removeFirst(prefix.count)
            break
        }
        value = value.trimmingCharacters(in: .whitespaces)
        guard value.range(of: #"^[+-]?(?:[0-9]+|[0-9]{1,3}(?:,[0-9]{3})+)(?:\.[0-9]+)?$"#,
                          options: .regularExpression) != nil,
              let number = Double(value.replacingOccurrences(of: ",", with: "")), number.isFinite else { return nil }
        return number
    }

    static func parse(_ boxes: [ScreenshotTextBox]) -> [ScreenshotHoldingDraft] {
        let rows = groupedRows(boxes)
        if let paired = pairedTable(rows) { return applyingCurrency(paired, boxes: boxes) }
        var columns: [(Field, Double)] = []
        var result: [ScreenshotHoldingDraft] = []
        var card: ScreenshotHoldingDraft?
        var cardColumns: [(Field, Double)] = []
        for row in rows {
            let headers = headerFields(row)
            if headers.count >= 2, headers.contains(where: { $0.0 == .ticker }),
               headers.contains(where: { $0.0 == .shares || $0.0 == .cost }) {
                if let card { result.append(card) }
                card = nil
                columns = headers
                continue
            }
            if !columns.isEmpty {
                var cells: [Field: [ScreenshotTextBox]] = [:]
                for box in row {
                    guard let nearest = columns.min(by: { abs($0.1 - box.midX) < abs($1.1 - box.midX) }) else { continue }
                    cells[nearest.0, default: []].append(box)
                }
                let tickerBoxes = cells[.ticker] ?? []
                if let symbol = tickerBoxes.first(where: { isRecognizedTicker($0.text) })?.text {
                    var draft = ScreenshotHoldingDraft(ticker: symbol.uppercased())
                    draft.shares = numericCell(cells[.shares])
                    draft.averageCost = numericCell(cells[.cost])
                    draft.price = numericCell(cells[.price])
                    draft.currency = currency(in: cells[.currency] ?? row)
                    result.append(draft)
                }
                continue
            }
            if card != nil, !cardColumns.isEmpty, headers.isEmpty,
               row.contains(where: { number($0.text) != nil }) {
                for (field, center) in cardColumns {
                    let values = row.filter { box in
                        cardColumns.min(by: { abs($0.1 - box.midX) < abs($1.1 - box.midX) })?.1 == center
                    }
                    assign(numericCell(values), to: field, draft: &card!)
                    if card?.currency.isEmpty == true { card?.currency = currency(in: values) }
                }
                cardColumns = []
                continue
            }
            // Cards: a symbol heading followed by explicit label/value rows.
            if headers.isEmpty, let symbol = row.first(where: { isRecognizedTicker($0.text) })?.text {
                if let card { result.append(card) }
                card = ScreenshotHoldingDraft(ticker: symbol.uppercased(), currency: currency(in: row))
                cardColumns = []
            } else if card != nil {
                if headers.count >= 2, !row.contains(where: { number($0.text) != nil }) {
                    cardColumns = headers
                    continue
                }
                for (field, center) in headers {
                    let values = row.filter { $0.midX > center && Self.field($0.text) == nil }
                    let value = numericCell(values)
                    switch field {
                    case .shares: card?.shares = value
                    case .cost: card?.averageCost = value
                    case .price: card?.price = value
                    case .currency: card?.currency = currency(in: values)
                    default: break
                    }
                    if card?.currency.isEmpty == true { card?.currency = currency(in: values) }
                }
            }
        }
        if let card { result.append(card) }
        // A single, explicit currency marker applies to the screenshot; a "$"
        // alone does not distinguish US, HK, Canadian or Australian dollars.
        return applyingCurrency(result, boxes: boxes)
    }

    private static func applyingCurrency(_ drafts: [ScreenshotHoldingDraft],
                                         boxes: [ScreenshotTextBox]) -> [ScreenshotHoldingDraft] {
        var result = drafts
        for index in result.indices { result[index].ticker = normalizedTicker(result[index].ticker) }
        let currencies = Set(boxes.map { currency(in: [$0]) }.filter { !$0.isEmpty })
        if currencies.count == 1, let currency = currencies.first {
            for index in result.indices where result[index].currency.isEmpty { result[index].currency = currency }
        }
        return result
    }

    /// Some broker tables explicitly stack market value / shares and price /
    /// cost in two lines. The slash order is evidence; do not guess it from
    /// whichever number happens to be larger.
    private static func pairedTable(_ rows: [[ScreenshotTextBox]]) -> [ScreenshotHoldingDraft]? {
        guard let headerIndex = rows.firstIndex(where: { row in
            let fields = headerFields(row).map(\.0)
            return fields.contains(.ticker) && fields.contains(.valueShares)
                && (fields.contains(.priceCost) || fields.contains(.costPrice))
        }) else { return nil }
        let columns = headerFields(rows[headerIndex])
        func cells(_ row: [ScreenshotTextBox], _ field: Field) -> [ScreenshotTextBox] {
            row.filter { box in
                columns.min(by: { abs($0.1 - box.midX) < abs($1.1 - box.midX) })?.0 == field
            }
        }
        let dataRows = rows.dropFirst(headerIndex + 1).filter {
            !numericCell(cells($0, .valueShares)).isEmpty
        }
        var result: [ScreenshotHoldingDraft] = []
        var index = dataRows.startIndex
        while index < dataRows.endIndex {
            let top = dataRows[index]
            let next = dataRows.index(after: index)
            guard next < dataRows.endIndex else {
                // A cropped last row can still be reviewed, without inventing
                // its missing second line.
                if let ticker = cells(top, .ticker).first(where: { isRecognizedTicker($0.text) })?.text {
                    result.append(ScreenshotHoldingDraft(ticker: ticker, currency: currency(in: top)))
                }
                break
            }
            let bottom = dataRows[next]
            let adjacent = (bottom.first?.midY ?? 1) - (top.first?.midY ?? 0)
                <= max(top.first?.height ?? 0, bottom.first?.height ?? 0) * 2.5
            let symbols = (cells(top, .ticker) + cells(bottom, .ticker))
                .filter { isRecognizedTicker($0.text) }
            if symbols.count == 1, adjacent {
                var draft = ScreenshotHoldingDraft(ticker: symbols[0].text,
                    shares: numericCell(cells(bottom, .valueShares)), currency: currency(in: top + bottom))
                let priceFirst = columns.contains { $0.0 == .priceCost }
                let field: Field = priceFirst ? .priceCost : .costPrice
                draft.price = numericCell(cells(priceFirst ? top : bottom, field))
                draft.averageCost = numericCell(cells(priceFirst ? bottom : top, field))
                result.append(draft)
                index = dataRows.index(after: next)
            } else {
                // A different layout must not combine two different stocks.
                if let ticker = cells(top, .ticker).first(where: { isRecognizedTicker($0.text) })?.text {
                    result.append(ScreenshotHoldingDraft(ticker: ticker, currency: currency(in: top)))
                }
                index = next
            }
        }
        return result
    }

    private static func assign(_ value: String, to field: Field, draft: inout ScreenshotHoldingDraft) {
        switch field {
        case .shares: draft.shares = value
        case .cost: draft.averageCost = value
        case .price: draft.price = value
        default: break
        }
    }

    private static func isRecognizedTicker(_ text: String) -> Bool {
        // Prose such as "Account" must not become a US ticker automatically.
        text == text.uppercased() && isTicker(text)
    }

    private static func numericCell(_ boxes: [ScreenshotTextBox]?) -> String {
        let values = (boxes ?? []).filter { number($0.text) != nil }
        return values.count == 1 ? values[0].text : ""
    }

    private static func currency(in boxes: [ScreenshotTextBox]) -> String {
        let codes = boxes.compactMap { box -> String? in
            let text = box.text.uppercased().trimmingCharacters(in: .whitespaces)
            if reserved.contains(text), LocalPortfolioEngine.usdRate(for: text) != nil { return text }
            if text.hasPrefix("US$") { return "USD" }
            if text.hasPrefix("HK$") { return "HKD" }
            if text.hasPrefix("£") { return "GBP" }
            if text.hasPrefix("€") { return "EUR" }
            return nil
        }
        let unique = Set(codes)
        return unique.count == 1 ? unique.first! : ""
    }

    private static func field(_ text: String) -> Field? {
        let key = text.lowercased().filter { !$0.isWhitespace && !".:：".contains($0) }
        return labels.first(where: { $0.value.contains(key) })?.key
    }

    private static func headerFields(_ row: [ScreenshotTextBox]) -> [(Field, Double)] {
        var result: [(Field, Double)] = []
        var index = 0
        while index < row.count {
            var matched = false
            for count in stride(from: min(3, row.count - index), through: 1, by: -1) {
                let part = Array(row[index..<(index + count)])
                if let field = field(part.map(\.text).joined(separator: " ")) {
                    result.append((field, (part[0].x + part.last!.x + part.last!.width) / 2))
                    index += count
                    matched = true
                    break
                }
            }
            if !matched { index += 1 }
        }
        return result
    }

    private static func groupedRows(_ boxes: [ScreenshotTextBox]) -> [[ScreenshotTextBox]] {
        var rows: [[ScreenshotTextBox]] = []
        for box in boxes.sorted(by: { $0.midY < $1.midY }) {
            if let last = rows.last, let anchor = last.first,
               abs(box.midY - anchor.midY) <= min(box.height, anchor.height) * 0.6 {
                rows[rows.count - 1].append(box)
            } else { rows.append([box]) }
        }
        return rows.map { $0.sorted { $0.x < $1.x } }
    }
}

extension LocalPortfolioStore {
    /// One actor operation: validate, back up, then upsert snapshot quantities.
    /// Re-reading a screenshot never adds its shares a second time.
    func importScreenshot(_ drafts: [ScreenshotHoldingDraft], accountID: String,
                          accountName: String, updating: Bool) throws -> LocalPortfolioDocument {
        let incoming = try ScreenshotImport.positions(drafts, accountID: accountID, accountName: accountName)
        let previous = try load()
        let key = "\(ScreenshotImport.source)|\(accountID)"
        let exists = previous.accounts.contains { $0.id == key }
        guard updating == exists else {
            throw ScreenshotImportError(message: L10n.text("账户已发生变化，请关闭后重新导入。"))
        }
        let tickers = Set(incoming.map(\.ticker))
        let retained = previous.positions.filter { $0.accountKey == key && !tickers.contains($0.ticker.uppercased()) }
        _ = try backupPortfolio(reason: "before-screenshot")
        return try replace(positions: retained + incoming, source: ScreenshotImport.source,
                           replacingAccountsOnly: true)
    }
}

extension AppModel {
    func importScreenshot(_ drafts: [ScreenshotHoldingDraft], accountID: String,
                          accountName: String, updating: Bool) async throws {
        guard !isFakeDataMode && !isPublicInvestorMode else {
            throw ScreenshotImportError(message: L10n.text("请切换到个人组合后导入持仓。"))
        }
        invalidateInFlightRequests()
        let saved = try await LocalPortfolioStore.shared.importScreenshot(
            drafts, accountID: accountID, accountName: accountName, updating: updating)
        try await apply(activeDocument(from: saved))
    }
}
