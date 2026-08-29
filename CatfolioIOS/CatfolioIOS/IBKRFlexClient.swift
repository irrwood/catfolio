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

    var id: String { "\(accountID):\(assetCategory):\(symbol)" }
}

struct IBKRFlexSnapshot: Equatable {
    let positions: [IBKRFlexPosition]
    let reportDate: String?

    func csvImportExport() throws -> IBKRFlexCSVExport {
        var warnings: [String] = []
        var rows: [String] = ["Date,Action,Ticker,Quantity,Price,Currency,Name"]

        for position in positions {
            guard position.quantity > 0 else {
                warnings.append("已跳过空头持仓 \(position.symbol)")
                continue
            }
            let category = position.assetCategory.uppercased()
            guard category.isEmpty || category == "STK" else {
                warnings.append("已跳过不受支持的 \(category) 持仓 \(position.symbol)")
                continue
            }
            guard let averageCost = position.averageCost, averageCost > 0 else {
                warnings.append("\(position.symbol) 缺少 Cost Basis Price，已跳过")
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
            "Flex Token 格式无效"
        case .invalidQueryID:
            "Flex Query ID 格式无效"
        case .invalidResponse:
            "IBKR Flex 返回了无法识别的数据"
        case .insecureResponseURL:
            "IBKR 返回了不安全的报表地址"
        case let .http(code):
            "IBKR Flex 请求失败（HTTP \(code)）"
        case let .service(code, message):
            "IBKR Flex \(code)：\(message)"
        case .generationTimedOut:
            "IBKR 报表仍在生成，请稍后再试"
        case .noPositions:
            "Flex 报表没有 Open Positions；请在 Query 中加入该栏目和 Summary 明细"
        case let .noImportablePositions(warnings):
            warnings.isEmpty ? "Flex 报表没有可导入的股票持仓" : warnings.joined(separator: "；")
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

    func fetchOpenPositions(credentials: IBKRFlexCredentials) async throws -> IBKRFlexSnapshot {
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
                envelope.errorCode ?? "请求失败",
                envelope.errorMessage ?? "未返回 Reference Code"
            )
        }
        try validate(responseURL: responseURL)

        for attempt in 0..<6 {
            try await Task.sleep(for: .milliseconds(attempt == 0 ? 1_200 : 2_000))
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
                    status.errorMessage ?? "报表生成失败"
                )
            }
            let snapshot = try parseStatement(statementData)
            guard !snapshot.positions.isEmpty else { throw IBKRFlexError.noPositions }
            return snapshot
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

    private func parseStatement(_ data: Data) throws -> IBKRFlexSnapshot {
        let delegate = FlexStatementParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { throw IBKRFlexError.invalidResponse }
        return IBKRFlexSnapshot(positions: delegate.positions, reportDate: delegate.reportDate)
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
    var reportDate: String?

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let attributes = Dictionary(uniqueKeysWithValues: attributeDict.map { ($0.key.lowercased(), $0.value) })
        if elementName.caseInsensitiveCompare("FlexStatement") == .orderedSame {
            reportDate = attributes["todate"] ?? attributes["fromdate"] ?? reportDate
            return
        }
        guard elementName.caseInsensitiveCompare("OpenPosition") == .orderedSame else { return }
        guard attributes["levelofdetail"]?.uppercased() != "LOT" else { return }
        let symbol = (attributes["symbol"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let quantity = number(attributes["position"] ?? attributes["quantity"]) ?? 0
        guard !symbol.isEmpty, quantity != 0 else { return }
        let costBasis = number(attributes["costbasismoney"])
        let averageCost = number(attributes["costbasisprice"])
            ?? number(attributes["openprice"])
            ?? costBasis.flatMap { quantity == 0 ? nil : abs($0 / quantity) }
        positions.append(IBKRFlexPosition(
            accountID: attributes["accountid"] ?? "IBKR",
            symbol: symbol,
            name: attributes["description"] ?? symbol,
            currency: (attributes["currency"] ?? "USD").uppercased(),
            assetCategory: attributes["assetcategory"] ?? attributes["assetclass"] ?? "",
            quantity: quantity,
            markPrice: number(attributes["markprice"] ?? attributes["closeprice"]),
            marketValue: number(attributes["positionvalue"] ?? attributes["value"]),
            averageCost: averageCost,
            costBasis: costBasis,
            reportDate: attributes["reportdate"]
        ))
    }

    private func number(_ value: String?) -> Double? {
        guard let value else { return nil }
        return Double(value.replacingOccurrences(of: ",", with: ""))
    }
}
