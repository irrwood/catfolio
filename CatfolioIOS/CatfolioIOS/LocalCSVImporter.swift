import Foundation
import CryptoKit

enum LocalCSVImporter {
    private struct Transaction {
        let date: Date
        let action: String
        let ticker: String
        let quantity: Double
        let price: Double
        let currency: String
        let name: String
        let reference: String?
        let realisedProfitLoss: Double?
        let realisedProfitLossCurrency: String?
        let cashPostings: [DailyTimeWeightedReturn.Cash]?
    }

    static let aliases: [String: [String]] = [
        "total": ["total"],
        "totalCurrency": ["currency total"],
        "netCash": ["net cash amount"],
        "cashCurrency": ["cash currency"],
        "result": ["result", "realised profit loss", "realized profit loss"],
        "resultCurrency": ["currency result", "result currency"],
        "reference": ["id", "reference", "trade id"],
        "date": [
            "date", "trade date", "transaction date", "time", "date time", "datetime",
            "timestamp", "execution time", "executed at", "created at", "closing time",
            "fill time", "filled at",
            "日期", "时间", "交易日期", "交易时间", "成交时间", "日期时间",
        ],
        "action": [
            "action", "type", "transaction type", "side", "direction",
            "操作", "类型", "交易类型", "方向",
        ],
        "ticker": [
            "ticker", "symbol", "instrument", "stock", "isin", "code",
            "代码", "股票代码", "标的代码", "证券代码",
        ],
        "quantity": [
            "quantity", "qty", "shares", "units", "amount", "no of shares",
            "数量", "股数", "成交数量",
        ],
        "price": [
            "price", "price share", "price per share", "trade price", "unit price", "execution price",
            "fill price", "filled price",
            "价格", "每股价格", "成交价", "执行价格",
        ],
        "currency": [
            "currency price share", "price currency", "currency price", "currency", "ccy", "curr",
            "price currency", "货币", "币种", "价格币种",
        ],
        "name": [
            "name", "company", "description", "instrument name", "security name",
            "名称", "公司名称", "证券名称",
        ],
    ]

    static let requiredColumnKeys = ["date", "action", "ticker", "quantity", "price"]

    static func decodedText(from data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) {
            return String(data: data, encoding: .utf16LittleEndian)
        }
        if data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16BigEndian)
        }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1252)
            ?? String(data: data, encoding: .isoLatin1)
    }

    static func columns(in header: [String]) -> [String: Int] {
        let normalized = header.map(normalizeHeader)
        var result: [String: Int] = [:]
        for (key, choices) in aliases {
            // Prefer exact column names. "Result" must never resolve to
            // "Currency (Result)" just because that column occurs first.
            if let exact = choices.compactMap({ normalized.firstIndex(of: normalizeHeader($0)) }).first {
                result[key] = exact
                continue
            }
            for choice in choices {
                let alias = normalizeHeader(choice)
                if let index = normalized.firstIndex(where: { headerMatches($0, alias: alias) }) {
                    result[key] = index
                    break
                }
            }
        }
        return result
    }

    static func headerRowIndex(in records: [[String]]) -> Int? {
        records.prefix(25).enumerated()
            .filter { !$0.element.isEmpty && !isSeparatorDirective($0.element) }
            .max { lhs, rhs in
                columns(in: lhs.element).count < columns(in: rhs.element).count
            }?
            .offset
    }

    static func missingRequiredColumns(in header: [String]) -> [String] {
        let resolved = columns(in: header)
        if resolved["total"] != nil || resolved["netCash"] != nil {
            return ["date", "action"].filter { resolved[$0] == nil }
        }
        return requiredColumnKeys.filter { resolved[$0] == nil }
    }

    /// The ISINs a statement names in its ticker column, each with the
    /// currency it was traded in, for the identity layer to resolve first.
    static func isinRequests(in data: Data) -> [(isin: String, currency: String?)] {
        guard let text = decodedText(from: data)?.replacingOccurrences(of: "\u{feff}", with: "") else { return [] }
        let records = parseRecords(text)
        guard let headerIndex = headerRowIndex(in: records) else { return [] }
        let columns = columns(in: records[headerIndex])
        guard let tickerColumn = columns["ticker"] else { return [] }
        let currencyColumn = columns["currency"]
        return records.dropFirst(headerIndex + 1).compactMap { row in
            guard row.indices.contains(tickerColumn) else { return nil }
            let value = row[tickerColumn].trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard SecurityIdentityResolver.isISIN(value) else { return nil }
            let currency = currencyColumn.flatMap { row.indices.contains($0) ? row[$0].trimmingCharacters(in: .whitespacesAndNewlines) : nil }
            return (value, currency)
        }
    }

    static func parse(
        _ data: Data,
        splitCatalog: StockSplitCatalog? = try? StockSplitCatalog.bundled.get(),
        resolvedISINs: [String: String] = [:]
    ) throws -> ([LocalPositionRecord], [LocalTransactionRecord], CSVImportResult) {
        guard var text = decodedText(from: data) else {
            throw LocalPortfolioError.invalidCSV(L10n.text("文件编码无法识别，请使用 UTF-8 或 UTF-16"))
        }
        text = text.replacingOccurrences(of: "\u{feff}", with: "")
        let records = parseRecords(text)
        guard !records.isEmpty else { throw LocalPortfolioError.invalidCSV(L10n.text("文件为空")) }
        guard let headerIndex = headerRowIndex(in: records) else {
            throw LocalPortfolioError.invalidCSV(L10n.text("没有找到可识别的表头"))
        }
        let header = records[headerIndex]
        // One import is assigned to one selected account. Refuse combined
        // statements instead of silently netting different accounts' trades.
        if let accountColumn = header.firstIndex(where: {
            ["account", "account id", "account number", "账户", "账户编号"].contains(normalizeHeader($0))
        }) {
            let accounts = Set(records.dropFirst(headerIndex + 1).compactMap { row -> String? in
                guard row.indices.contains(accountColumn) else { return nil }
                let value = row[accountColumn].trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            })
            guard accounts.count <= 1 else {
                throw LocalPortfolioError.invalidCSV(L10n.text("CSV 包含多个账户，请按账户拆分后分别导入。"))
            }
        }
        let columns = columns(in: header)
        let missing = missingRequiredColumns(in: header)
        guard missing.isEmpty else {
            throw LocalPortfolioError.invalidCSV(L10n.text("缺少列：\(missing.joined(separator: L10n.listSeparator))"))
        }

        var transactions: [Transaction] = []
        var warnings: [String] = []
        var ledgerIncomplete = false
        var rowOccurrences: [String: Int] = [:]
        for (offset, row) in records.dropFirst(headerIndex + 1).enumerated() {
            do {
                func field(_ name: String) -> String {
                    guard let index = columns[name], row.indices.contains(index) else { return "" }
                    return row[index].trimmingCharacters(in: .whitespacesAndNewlines)
                }
                guard !field("action").isEmpty else { continue }
                let action = normalizedAction(field("action")) ?? "UNSUPPORTED: \(field("action"))"
                let isTrade = action == "BUY" || action == "SELL"
                let statedTicker = field("ticker")
                // An ISIN becomes the listing's ticker, where the identity
                // layer found one; otherwise it stays as it was given.
                let rawTicker = resolvedISINs[statedTicker.uppercased()] ?? statedTicker
                let ticker = rawTicker.isEmpty && !isTrade ? "CASH"
                    : resolvedISINs[statedTicker.uppercased()] ?? Trading212Position.catfolioTicker(rawTicker)
                guard !ticker.isEmpty else { throw LocalPortfolioError.invalidCSV(L10n.text("交易缺少股票代码")) }
                let quantity = isTrade ? abs(try number(field("quantity"))) : 1
                let price = isTrade ? try number(field("price")) : (numericValue(field("total")) ?? numericValue(field("netCash")) ?? numericValue(field("price")) ?? 0)
                var postings: [DailyTimeWeightedReturn.Cash]? = nil
                let locale = Locale(identifier: "en_US_POSIX")
                if let net = Decimal(string: field("netCash").replacingOccurrences(of: ",", with: ""), locale: locale), !field("cashCurrency").isEmpty {
                    postings = [.init(currency: field("cashCurrency").uppercased(), amount: net)]
                } else if let total = Decimal(string: field("total").replacingOccurrences(of: ",", with: ""), locale: locale), !field("totalCurrency").isEmpty {
                    // Total semantics vary across broker exports. Fee-bearing
                    // rows need an explicit signed net cash amount; do not guess
                    // whether a fee column was already included in Total.
                    let hasCharges = header.enumerated().contains { index, name in
                        let key = name.lowercased()
                        let currencyLabel = key.hasPrefix("currency (") || key.hasPrefix("currency currency ") || key.hasSuffix(" currency")
                        guard !currencyLabel, key.contains("fee") || key.contains("tax") || key.contains("commission"),
                              row.indices.contains(index), !row[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
                        guard let amount = numericValue(row[index]), amount.isFinite else { return true }
                        return amount != 0
                    }
                    if !hasCharges {
                        let magnitude = total < 0 ? -total : total
                        let debit = ["BUY", "WITHDRAWAL", "FEE", "TAX"].contains(action)
                        postings = [.init(currency: field("totalCurrency").uppercased(), amount: debit ? -magnitude : magnitude)]
                    }
                }
                let reportedCurrency = field("currency")
                let currency = Trading212Position.currency(
                    reportedCurrency.isEmpty ? nil : reportedCurrency,
                    rawTicker: rawTicker
                )
                let result = action == "SELL" ? numericValue(field("result")) : nil
                let resultCurrency = field("resultCurrency").uppercased()
                let canonical = [field("date"), action, ticker, String(quantity), String(price), currency].joined(separator: "|")
                let digest = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
                rowOccurrences[digest, default: 0] += 1
                if result != nil && resultCurrency.isEmpty {
                    warnings.append(L10n.text("第 \(headerIndex + offset + 2) 行：Result 缺少币种，不计入券商已实现盈亏。"))
                }
                transactions.append(Transaction(
                    date: try date(field("date")),
                    action: action,
                    ticker: ticker,
                    quantity: quantity,
                    price: price,
                    currency: currency.isEmpty ? "USD" : currency,
                    name: field("name"),
                    reference: field("reference").isEmpty ? "csv-\(digest)-\(rowOccurrences[digest]!)" : field("reference"),
                    realisedProfitLoss: result,
                    realisedProfitLossCurrency: resultCurrency.isEmpty ? nil : resultCurrency,
                    cashPostings: postings
                ))
            } catch {
                ledgerIncomplete = true
                warnings.append(L10n.text("第 \(headerIndex + offset + 2) 行：\(error.localizedDescription)"))
            }
        }
        guard !transactions.isEmpty else { throw LocalPortfolioError.invalidCSV(L10n.text("没有有效交易")) }

        struct PositionState {
            var shares = 0.0
            var average = 0.0
            var currency = "USD"
            var name = ""
            var openedDate: Date?
        }
        var states: [String: PositionState] = [:]
        for transaction in transactions.sorted(by: { $0.date < $1.date }) {
            guard transaction.action == "BUY" || transaction.action == "SELL" else { continue }
            let key = "\(transaction.ticker)|\(transaction.currency)"
            let adjustment = splitCatalog.map { $0.adjustment(ticker: transaction.ticker,
                    from: DayDateCodec.string(from: transaction.date)) } ?? 1
            guard let factor = adjustment, factor.isFinite, factor > 0 else {
                throw LocalPortfolioError.invalidCSV(transaction.ticker)
            }
            let quantity = transaction.quantity * factor
            let price = transaction.price / factor
            var state = states[key] ?? PositionState()
            state.currency = transaction.currency
            if !transaction.name.isEmpty { state.name = transaction.name }
            if transaction.action == "BUY" {
                if state.shares <= 0.001 {
                    state.openedDate = transaction.date
                }
                let newShares = state.shares + quantity
                if newShares > 0 {
                    state.average = (state.average * state.shares + price * quantity) / newShares
                }
                state.shares = newShares
            } else {
                guard quantity <= state.shares + max(1e-8, state.shares * 1e-8) else {
                    throw LocalPortfolioError.invalidCSV(L10n.text("\(transaction.ticker) 卖出数量超过可重建持仓，请补齐历史或拆股记录。"))
                }
                state.shares = max(0, state.shares - quantity)
                if state.shares <= 0.001 {
                    state.openedDate = nil
                }
            }
            states[key] = state
        }
        let positions = states.compactMap { key, state -> LocalPositionRecord? in
            let ticker = String(key.split(separator: "|", maxSplits: 1)[0])
            guard state.shares > 0.001 else { return nil }
            return LocalPositionRecord(
                ticker: ticker,
                name: state.name,
                shares: state.shares,
                averageCost: state.average,
                currency: state.currency,
                quotePrice: state.average,
                quoteCurrency: state.currency,
                source: "CSV",
                openedDate: state.openedDate.map { DayDateFormatter.shared.string(from: $0) }
            )
        }.sorted { $0.ticker < $1.ticker }
        let imported = positions.map {
            CSVImportedHolding(ticker: $0.ticker, name: $0.name, shares: $0.shares, averageCost: $0.averageCost, currency: $0.currency)
        }
        let storedTransactions = transactions.map {
            LocalTransactionRecord(
                date: DayDateCodec.string(from: $0.date),
                action: $0.action,
                ticker: $0.ticker,
                quantity: $0.quantity,
                price: $0.price,
                currency: $0.currency,
                source: "CSV",
                accountID: nil,
                accountName: "CSV",
                tradeID: $0.reference,
                entryMethod: "csv",
                realisedProfitLoss: $0.realisedProfitLoss,
                realisedProfitLossCurrency: $0.realisedProfitLossCurrency,
                executedAt: ISO8601DateFormatter().string(from: $0.date),
                cashPostings: ledgerIncomplete ? nil : $0.cashPostings
            )
        }
        return (positions, storedTransactions, CSVImportResult(
            ok: true,
            holdingsCount: positions.count,
            transactionsCount: transactions.count,
            backupCreated: false,
            warnings: warnings,
            holdings: imported
        ))
    }

    private static func number(_ value: String) throws -> Double {
        guard let number = numericValue(value) else {
            throw LocalPortfolioError.invalidCSV(L10n.text("无效数字 \(value)"))
        }
        return number
    }

    private static func date(_ value: String) throws -> Date {
        guard let parsed = parsedDate(value) else {
            throw LocalPortfolioError.invalidCSV(L10n.text("无效日期 \(value)"))
        }
        return parsed
    }

    static func parsedDate(_ value: String) -> Date? {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        for options: ISO8601DateFormatter.Options in [
            [.withInternetDateTime, .withFractionalSeconds],
            [.withInternetDateTime],
        ] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            if let date = formatter.date(from: cleaned) { return date }
        }

        let formats = [
            "yyyy-MM-dd HH:mm:ss.SSSSSS", "yyyy-MM-dd HH:mm:ss.SSS", "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm", "yyyy-MM-dd, HH:mm:ss", "yyyy/MM/dd HH:mm:ss",
            "MM/dd/yyyy HH:mm:ss", "dd/MM/yyyy HH:mm:ss", "dd-MM-yyyy HH:mm:ss",
            "yyyy-MM-dd", "MM/dd/yyyy", "dd/MM/yyyy", "yyyy/MM/dd", "dd-MM-yyyy",
        ]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.isLenient = false
            formatter.dateFormat = format
            if let date = formatter.date(from: cleaned) { return date }
        }
        return nil
    }

    static func numericValue(_ value: String) -> Double? {
        var cleaned = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{00a0}", with: "")
            .replacingOccurrences(of: " ", with: "")
        let negative = cleaned.hasPrefix("(") && cleaned.hasSuffix(")")
        if negative { cleaned = String(cleaned.dropFirst().dropLast()) }
        cleaned = String(cleaned.filter { $0.isNumber || "+-.,eE".contains($0) })

        if let comma = cleaned.lastIndex(of: ","), let dot = cleaned.lastIndex(of: ".") {
            if comma > dot {
                cleaned = cleaned.replacingOccurrences(of: ".", with: "")
                cleaned = cleaned.replacingOccurrences(of: ",", with: ".")
            } else {
                cleaned = cleaned.replacingOccurrences(of: ",", with: "")
            }
        } else if let comma = cleaned.lastIndex(of: ",") {
            let fractionalDigits = cleaned.distance(from: cleaned.index(after: comma), to: cleaned.endIndex)
            if fractionalDigits == 3 && cleaned.filter({ $0 == "," }).count == 1 {
                cleaned.remove(at: comma)
            } else {
                cleaned = cleaned.replacingOccurrences(of: ",", with: ".")
            }
        }
        guard let number = Double(cleaned) else { return nil }
        return negative ? -number : number
    }

    static func normalizedAction(_ value: String) -> String? {
        let action = normalizeHeader(value)
        if action == "deposit" || action == "入金" { return "DEPOSIT" }
        if action == "withdrawal" || action == "withdraw" || action == "出金" { return "WITHDRAWAL" }
        if action.contains("interest") { return "INTEREST" }
        if action == "fee" { return "FEE" }
        if action == "tax" { return "TAX" }
        if action.contains("buy") || action.contains("买入") { return "BUY" }
        if action.contains("sell") || action.contains("卖出") { return "SELL" }
        if action.contains("dividend") || action.contains("股息") || action.contains("红利") {
            return "DIVIDEND"
        }
        return nil
    }

    /// RFC 4180-style records shared by the manual importer and broker CSV
    /// downloads. Keeping the parser local means downloaded statements never
    /// need to leave the iPhone for conversion.
    static func parseRecords(_ text: String, maximumRecords: Int? = nil) -> [[String]] {
        let delimiter = detectedDelimiter(in: text)
        var records: [[String]] = []
        var record: [String] = []
        var field = ""
        var insideQuotes = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "\"" {
                let next = text.index(after: index)
                if insideQuotes, next < text.endIndex, text[next] == "\"" {
                    field.append("\"")
                    index = next
                } else {
                    insideQuotes.toggle()
                }
            } else if character == delimiter, !insideQuotes {
                record.append(field)
                field = ""
            } else if (character == "\n" || character == "\r" || character == "\r\n"), !insideQuotes {
                if character == "\n" || !record.isEmpty || !field.isEmpty {
                    record.append(field)
                    if record.contains(where: { !$0.isEmpty }) { records.append(record) }
                    record = []
                    field = ""
                    if let maximumRecords, records.count >= maximumRecords { break }
                }
            } else {
                field.append(character)
            }
            index = text.index(after: index)
        }
        record.append(field)
        if record.contains(where: { !$0.isEmpty }) { records.append(record) }
        if let first = records.first, isSeparatorDirective(first) {
            records.removeFirst()
        }
        return records
    }

    private static func normalizeHeader(_ value: String) -> String {
        let folded = value
            .replacingOccurrences(of: "\u{feff}", with: "")
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
        let scalars = folded.unicodeScalars.map { scalar -> String in
            CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : " "
        }.joined()
        return scalars.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func headerMatches(_ value: String, alias: String) -> Bool {
        value == alias || value.hasPrefix("\(alias) ") || value.hasSuffix(" \(alias)")
    }

    private static func isSeparatorDirective(_ row: [String]) -> Bool {
        row.joined().trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("sep=")
    }

    private static func detectedDelimiter(in text: String) -> Character {
        let candidates: [Character] = [",", ";", "\t"]
        let lines = String(text.prefix(65_536))
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .prefix(12)

        if let directive = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           directive.hasPrefix("sep="), let separator = directive.last, candidates.contains(separator) {
            return separator
        }

        return candidates.max { lhs, rhs in
            lines.map { delimiterCount(in: String($0), delimiter: lhs) }.max() ?? 0
                < lines.map { delimiterCount(in: String($0), delimiter: rhs) }.max() ?? 0
        } ?? ","
    }

    private static func delimiterCount(in line: String, delimiter: Character) -> Int {
        var insideQuotes = false
        var count = 0
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == "\"" {
                let next = line.index(after: index)
                if insideQuotes, next < line.endIndex, line[next] == "\"" {
                    index = next
                } else {
                    insideQuotes.toggle()
                }
            } else if character == delimiter, !insideQuotes {
                count += 1
            }
            index = line.index(after: index)
        }
        return count
    }
}
