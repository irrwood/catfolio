import Foundation

struct IBKRFlexCredentials: Equatable {
    let token: String
    let queryID: String

    init(token: String, queryID: String) throws {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let queryID = queryID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.count >= 6, token.count <= 128, token.allSatisfy(\.isNumber) else {
            throw IBKRFlexError.invalidToken
        }
        guard queryID.count >= 3, queryID.count <= 32, queryID.allSatisfy(\.isNumber) else {
            throw IBKRFlexError.invalidQueryID
        }
        self.token = token
        self.queryID = queryID
    }
}

struct IBKRFlexPosition: Identifiable, Equatable {
    let accountID: String
    let symbol: String
    let name: String
    let currency: String
    let assetCategory: String
    let quantity: Double
    let markPrice: Double?
    let marketValue: Double?
    let averageCost: Double?
    let costBasis: Double?
    let reportDate: String?
    let openDate: String?

    var id: String { "\(accountID):\(assetCategory):\(symbol)" }
}

struct IBKRFlexTransaction: Identifiable, Equatable {
    let accountID: String
    let tradeID: String
    let symbol: String
    let name: String
    let currency: String
    let side: String
    let quantity: Double
    let price: Double
    let tradeDate: String
    let fxRateToBase: Double?
    let realisedProfitLoss: Double?

    var id: String { "\(accountID):\(tradeID)" }
}

struct IBKRFlexSnapshot: Equatable {
    let positions: [IBKRFlexPosition]
    let transactions: [IBKRFlexTransaction]
    let accountCurrencies: [String: String]
    let accountNames: [String: String]
    let reportDate: String?
    var positionAccountIDs: Set<String> = []

    var syncedPositionAccountIDs: Set<String> {
        positionAccountIDs.union(positions.map(\.accountID)).subtracting([""])
    }

    var quoteObservedAt: Date? {
        let digits = String((reportDate ?? "").filter(\.isNumber))
        guard digits.count >= 8 else { return nil }
        return DayDateCodec.date(from: "\(digits.prefix(4))-\(digits.dropFirst(4).prefix(2))-\(digits.dropFirst(6).prefix(2))")
    }

    func csvImportExport() throws -> IBKRFlexCSVExport {
        var warnings: [String] = []
        var rows: [String] = ["Date,Action,Ticker,Quantity,Price,Currency,Name"]

        for position in positions {
            guard position.quantity > 0 else {
                warnings.append(L10n.text("已跳过空头持仓 \(position.symbol)"))
                continue
            }
            let category = position.assetCategory.uppercased()
            guard category.isEmpty || category == "STK" else {
                warnings.append(L10n.text("已跳过不受支持的 \(category) 持仓 \(position.symbol)"))
                continue
            }
            guard let averageCost = position.averageCost, averageCost > 0 else {
                warnings.append(L10n.text("\(position.symbol) 缺少 Cost Basis Price，已跳过"))
                continue
            }
            let date = Self.normalizedDate(position.reportDate ?? reportDate)
            let fields = [
                date,
                "BUY",
                position.symbol,
                String(position.quantity),
                String(averageCost),
                position.currency.isEmpty ? "USD" : position.currency,
                position.name,
            ]
            rows.append(fields.map(Self.csvField).joined(separator: ","))
        }

        guard rows.count > 1, let data = rows.joined(separator: "\n").data(using: .utf8) else {
            throw IBKRFlexError.noImportablePositions(warnings)
        }
        return IBKRFlexCSVExport(data: data, importedPositions: rows.count - 1, warnings: warnings)
    }

    private static func normalizedDate(_ value: String?) -> String {
        let digits = String((value ?? "").filter(\.isNumber))
        if digits.count >= 8 {
            return "\(digits.prefix(4))-\(digits.dropFirst(4).prefix(2))-\(digits.dropFirst(6).prefix(2))"
        }
        return DayDateFormatter.shared.string(from: Date())
    }

    private static func csvField(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else { return value }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

struct IBKRFlexCSVExport {
    let data: Data
    let importedPositions: Int
    let warnings: [String]
}

enum IBKRFlexError: LocalizedError {
    case invalidToken
    case invalidQueryID
    case invalidResponse
    case insecureResponseURL
    case http(Int)
    case service(String, String)
    case generationTimedOut
    case noPositions
    case noImportablePositions([String])

    var errorDescription: String? {
        switch self {
        case .invalidToken:
            L10n.text("Flex Token 格式无效")
        case .invalidQueryID:
            L10n.text("Flex Query ID 格式无效")
        case .invalidResponse:
            L10n.text("IBKR Flex 返回了无法识别的数据")
        case .insecureResponseURL:
            L10n.text("IBKR 返回了不安全的报表地址")
        case let .http(code):
            L10n.text("IBKR Flex 请求失败（HTTP \(code)）")
        case let .service(code, message):
            "IBKR Flex \(code)：\(message)"
        case .generationTimedOut:
            L10n.text("IBKR 仍在生成报表。首次同步或时间跨度较长时可能需要几分钟，稍等片刻再试即可。")
        case .noPositions:
            L10n.text("Flex 报表没有 Open Positions；请在 Query 中加入该栏目和 Summary 明细")
        case let .noImportablePositions(warnings):
            warnings.isEmpty ? L10n.text("Flex 报表没有可导入的股票持仓") : warnings.joined(separator: L10n.clauseSeparator)
        }
    }
}

struct IBKRFlexClient {
    private static let sendRequestURL = URL(
        string: "https://ndcdyn.interactivebrokers.com/AccountManagement/FlexWebService/SendRequest"
    )!

    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.httpCookieStorage = nil
            self.session = URLSession(configuration: configuration)
        }
    }

    func fetchOpenPositions(
        credentials: IBKRFlexCredentials,
        onProgress: (@Sendable (Int) -> Void)? = nil
    ) async throws -> IBKRFlexSnapshot {
        let requestURL = try url(
            base: Self.sendRequestURL,
            queryItems: [
                URLQueryItem(name: "t", value: credentials.token),
                URLQueryItem(name: "q", value: credentials.queryID),
                URLQueryItem(name: "v", value: "3"),
            ]
        )
        let envelope = try parseEnvelope(try await data(from: requestURL))
        guard envelope.status.caseInsensitiveCompare("Success") == .orderedSame,
              let referenceCode = envelope.referenceCode,
              let responseURLText = envelope.responseURL,
              let responseURL = URL(string: responseURLText) else {
            throw IBKRFlexError.service(
                envelope.errorCode ?? L10n.text("请求失败"),
                envelope.errorMessage ?? L10n.text("未返回 Reference Code")
            )
        }
        try validate(responseURL: responseURL)

        // IBKR generates the report on demand. A first run over a year of
        // history across four sections routinely takes a minute or more, so
        // the old six-attempt / 11-second budget reported a normal wait as a
        // failure. Back off instead of hammering, and keep waiting for as long
        // as someone would plausibly stand watching a spinner.
        let waits: [Double] = [1.5, 2, 3, 4, 5, 6, 8, 10, 10, 12, 15, 15, 20, 20, 20, 20]
        var elapsed = 0.0
        for wait in waits {
            try await Task.sleep(for: .seconds(wait))
            elapsed += wait
            onProgress?(Int(elapsed))
            let statementURL = try url(
                base: responseURL,
                queryItems: [
                    URLQueryItem(name: "t", value: credentials.token),
                    URLQueryItem(name: "q", value: referenceCode),
                    URLQueryItem(name: "v", value: "3"),
                ]
            )
            let statementData = try await data(from: statementURL)
            if isEnvelope(statementData) {
                let status = try parseEnvelope(statementData)
                if status.errorCode == "1019" { continue }
                throw IBKRFlexError.service(
                    status.errorCode ?? status.status,
                    status.errorMessage ?? L10n.text("报表生成失败")
                )
            }
            return try parseStatement(statementData)
        }
        throw IBKRFlexError.generationTimedOut
    }

    private func data(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("CatfolioIOS/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/xml,text/xml", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw IBKRFlexError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw IBKRFlexError.http(http.statusCode)
        }
        return data
    }

    private func url(base: URL, queryItems: [URLQueryItem]) throws -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.queryItems = queryItems
        guard let result = components?.url else { throw IBKRFlexError.invalidResponse }
        return result
    }

    private func validate(responseURL: URL) throws {
        guard responseURL.scheme == "https", let host = responseURL.host?.lowercased(),
              host == "interactivebrokers.com" || host.hasSuffix(".interactivebrokers.com") else {
            throw IBKRFlexError.insecureResponseURL
        }
    }

    private func isEnvelope(_ data: Data) -> Bool {
        String(data: data.prefix(512), encoding: .utf8)?.contains("FlexStatementResponse") == true
    }

    private func parseEnvelope(_ data: Data) throws -> FlexEnvelope {
        let delegate = FlexEnvelopeParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), !delegate.envelope.status.isEmpty else {
            throw IBKRFlexError.invalidResponse
        }
        return delegate.envelope
    }

    func parseStatement(_ data: Data) throws -> IBKRFlexSnapshot {
        let delegate = FlexStatementParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { throw IBKRFlexError.invalidResponse }
        let snapshot = IBKRFlexSnapshot(
            positions: delegate.positions,
            transactions: delegate.transactions,
            accountCurrencies: delegate.accountCurrencies,
            accountNames: delegate.accountNames,
            reportDate: delegate.reportDate,
            positionAccountIDs: delegate.positionAccountIDs.subtracting(
                delegate.lotAccounts.subtracting(delegate.summaryAccounts))
        )
        // An explicitly empty OpenPositions section is authoritative. A
        // statement with no positions section says nothing about holdings.
        guard !snapshot.syncedPositionAccountIDs.isEmpty else { throw IBKRFlexError.noPositions }
        return snapshot
    }
}

private struct FlexEnvelope {
    var status = ""
    var referenceCode: String?
    var responseURL: String?
    var errorCode: String?
    var errorMessage: String?
}

private final class FlexEnvelopeParser: NSObject, XMLParserDelegate {
    var envelope = FlexEnvelope()
    private var currentElement = ""
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName.lowercased()
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName.lowercased() {
        case "status": envelope.status = value
        case "referencecode": envelope.referenceCode = value
        case "url": envelope.responseURL = value
        case "errorcode": envelope.errorCode = value
        case "errormessage": envelope.errorMessage = value
        default: break
        }
        currentElement = ""
        text = ""
    }
}

private final class FlexStatementParser: NSObject, XMLParserDelegate {
    var positions: [IBKRFlexPosition] = []
    var transactions: [IBKRFlexTransaction] = []
    var accountCurrencies: [String: String] = [:]
    var accountNames: [String: String] = [:]
    var reportDate: String?
    var positionAccountIDs: Set<String> = []
    var lotAccounts: Set<String> = []
    var summaryAccounts: Set<String> = []
    private var currentAccountID = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let attributes = Dictionary(uniqueKeysWithValues: attributeDict.map { ($0.key.lowercased(), $0.value) })
        if elementName.caseInsensitiveCompare("FlexStatement") == .orderedSame {
            currentAccountID = attributes["accountid"] ?? attributes["acctid"] ?? ""
            reportDate = attributes["todate"] ?? attributes["fromdate"] ?? reportDate
            return
        }
        if elementName.caseInsensitiveCompare("OpenPositions") == .orderedSame {
            let id = attributes["accountid"] ?? currentAccountID
            if !id.isEmpty { positionAccountIDs.insert(id) }
            return
        }
        if elementName.caseInsensitiveCompare("AccountInformation") == .orderedSame {
            let accountID = attributes["accountid"] ?? attributes["acctid"] ?? ""
            let baseCurrency = attributes["basecurrency"] ?? attributes["currency"] ?? ""
            let accountName = attributes["accountalias"]
                ?? attributes["accountname"]
                ?? attributes["name"]
            if !accountID.isEmpty, !baseCurrency.isEmpty {
                accountCurrencies[accountID] = baseCurrency.uppercased()
            }
            if !accountID.isEmpty,
               let accountName = accountName?.trimmingCharacters(in: .whitespacesAndNewlines),
               !accountName.isEmpty {
                accountNames[accountID] = accountName
            }
            return
        }
        if elementName.caseInsensitiveCompare("Trade") == .orderedSame {
            parseTrade(attributes)
            return
        }
        if elementName.caseInsensitiveCompare("CashTransaction") == .orderedSame {
            parseCashTransaction(attributes)
            return
        }
        guard elementName.caseInsensitiveCompare("OpenPosition") == .orderedSame else { return }
        let positionAccountID = attributes["accountid"] ?? currentAccountID
        if attributes["levelofdetail"]?.uppercased() == "LOT" {
            lotAccounts.insert(positionAccountID)
            return
        }
        summaryAccounts.insert(positionAccountID)
        let symbol = (attributes["symbol"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let quantity = number(attributes["position"] ?? attributes["quantity"]) ?? 0
        guard !symbol.isEmpty, quantity != 0 else { return }
        let costBasis = number(attributes["costbasismoney"])
        let averageCost = number(attributes["costbasisprice"])
            ?? number(attributes["openprice"])
            ?? costBasis.flatMap { quantity == 0 ? nil : abs($0 / quantity) }
        positions.append(IBKRFlexPosition(
            accountID: positionAccountID.isEmpty ? "IBKR" : positionAccountID,
            symbol: symbol,
            name: attributes["description"] ?? symbol,
            currency: (attributes["currency"] ?? "USD").uppercased(),
            assetCategory: attributes["assetcategory"] ?? attributes["assetclass"] ?? "",
            quantity: quantity,
            markPrice: number(attributes["markprice"] ?? attributes["closeprice"]),
            marketValue: number(attributes["positionvalue"] ?? attributes["value"]),
            averageCost: averageCost,
            costBasis: costBasis,
            reportDate: attributes["reportdate"],
            openDate: normalizedDate(
                attributes["opendatetime"]
                    ?? attributes["holdingperioddatetime"]
            )
        ))
    }

    private func parseTrade(_ attributes: [String: String]) {
        let symbol = (attributes["symbol"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let quantity = abs(number(attributes["quantity"]) ?? 0)
        let price = number(attributes["tradeprice"] ?? attributes["price"]) ?? 0
        let rawSide = (attributes["buysell"] ?? attributes["side"] ?? "").uppercased()
        guard !symbol.isEmpty, quantity > 0, price > 0,
              rawSide == "BUY" || rawSide == "SELL" else { return }
        let rawDate = attributes["tradedate"]
            ?? attributes["datetime"]
            ?? attributes["date/time"]
            ?? attributes["reportdate"]
        guard let tradeDate = normalizedDate(rawDate) else { return }
        let fallbackID = [tradeDate, symbol, rawSide, String(quantity), String(price)].joined(separator: "|")
        transactions.append(IBKRFlexTransaction(
            accountID: attributes["accountid"] ?? "IBKR",
            tradeID: attributes["tradeid"] ?? attributes["transactionid"] ?? fallbackID,
            symbol: symbol.uppercased(),
            name: attributes["description"] ?? symbol,
            currency: (attributes["currency"] ?? "USD").uppercased(),
            side: rawSide,
            quantity: quantity,
            price: price,
            tradeDate: tradeDate,
            fxRateToBase: number(attributes["fxratetobase"]),
            realisedProfitLoss: number(
                attributes["realizedpnl"]
                    ?? attributes["realisedpnl"]
                    ?? attributes["fifopnlrealized"]
            )
        ))
    }

    /// Import posted cash activity from the Flex `Cash Transactions` section.
    /// Interest accrual rows are deliberately not used here: IBKR reverses the
    /// daily accruals when the monthly amount is posted, so importing both
    /// would double count the user's actual interest.
    private func parseCashTransaction(_ attributes: [String: String]) {
        let description = (attributes["description"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let type = (attributes["type"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let code = (attributes["code"] ?? "").uppercased()
        let searchable = "\(description) \(type) \(code)".lowercased()

        let action: String
        let codeParts = Set(code.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        if searchable.contains("interest")
            || !codeParts.isDisjoint(with: ["CINT", "DINT", "INTP", "INTR"]) {
            action = "INTEREST"
        } else if searchable.contains("dividend")
                    || !codeParts.isDisjoint(with: ["DIV", "DIVR", "PIL"]) {
            action = "DIVIDEND"
        } else if searchable.contains("deposit") || codeParts.contains("DEP") {
            action = "DEPOSIT"
        } else if searchable.contains("withdraw") || codeParts.contains("WITH") {
            action = "WITHDRAW"
        } else {
            return
        }

        guard let amount = number(attributes["amount"]), amount != 0 else { return }
        let rawDate = attributes["datetime"]
            ?? attributes["date/time"]
            ?? attributes["date"]
            ?? attributes["reportdate"]
        guard let activityDate = normalizedDate(rawDate) else { return }
        let accountID = attributes["accountid"] ?? "IBKR"
        let currency = (attributes["currency"] ?? accountCurrencies[accountID] ?? "USD").uppercased()
        let symbol = (attributes["symbol"] ?? "CASH").trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackID = [activityDate, action, currency, String(amount), description].joined(separator: "|")

        transactions.append(IBKRFlexTransaction(
            accountID: accountID,
            tradeID: attributes["transactionid"]
                ?? attributes["tradeid"]
                ?? fallbackID,
            symbol: symbol.isEmpty ? "CASH" : symbol.uppercased(),
            name: description.isEmpty ? type : description,
            currency: currency,
            side: action,
            quantity: 1,
            price: amount,
            tradeDate: activityDate,
            fxRateToBase: number(attributes["fxratetobase"]),
            realisedProfitLoss: nil
        ))
    }

    private func normalizedDate(_ value: String?) -> String? {
        let digits = String((value ?? "").filter(\.isNumber))
        guard digits.count >= 8 else { return nil }
        return "\(digits.prefix(4))-\(digits.dropFirst(4).prefix(2))-\(digits.dropFirst(6).prefix(2))"
    }

    private func number(_ value: String?) -> Double? {
        guard let value else { return nil }
        return Double(value.replacingOccurrences(of: ",", with: ""))
    }
}
