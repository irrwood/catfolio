import Foundation

/// A listing identity, not a company identifier. Never guess the venue of a
/// bare number unless the caller has already established a CNY listing.
struct ChinaSecurity: Equatable, Sendable {
    let code: String
    let shanghai: Bool

    init?(_ symbol: String, currency: String? = nil) {
        let value = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        var code = value
        var venue: Bool?
        for (prefix, sh) in [("SH.", true), ("SZ.", false), ("SH", true), ("SZ", false)] where value.hasPrefix(prefix) {
            code = String(value.dropFirst(prefix.count)); venue = sh; break
        }
        for (suffix, sh) in [(".SS", true), (".SH", true), (".SZ", false)] where value.hasSuffix(suffix) {
            code = String(value.dropLast(suffix.count)); venue = sh; break
        }
        guard code.count == 6, code.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        if venue == nil {
            guard currency?.uppercased() == "CNY" else { return nil }
            if code.hasPrefix("6") || code.hasPrefix("5") { venue = true }
            if code.hasPrefix("00") || code.hasPrefix("30") || code.hasPrefix("15") || code.hasPrefix("16") { venue = false }
        }
        guard let venue else { return nil }
        // First release: Shanghai/Shenzhen stocks and exchange-traded funds.
        // In particular, 000001.SH is an index, not Ping An Bank.
        guard venue ? (code.hasPrefix("6") || code.hasPrefix("5"))
            : ["00", "30", "15", "16"].contains(where: code.hasPrefix) else { return nil }
        self.code = code
        shanghai = venue
    }

    var ticker: String { code + (shanghai ? ".SS" : ".SZ") }
    var longbridgeSymbol: String { code + (shanghai ? ".SH" : ".SZ") }
    var eastmoneyID: String { "\(shanghai ? 1 : 0).\(code)" }
    var isFund: Bool { code.hasPrefix("5") || code.hasPrefix("15") || code.hasPrefix("16") }
    static let timeZone = TimeZone(identifier: "Asia/Shanghai")!

    static func date(_ text: String, format: String = "yyyy-MM-dd") -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        formatter.isLenient = false
        guard let date = formatter.date(from: text), formatter.string(from: date) == text else { return nil }
        return date
    }

    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

enum ChinaMarketSource: String, CaseIterable, Identifiable, Sendable {
    case automatic, longbridge, akshare
    static let preferenceKey = "catfolio.china-market.source"
    static var current: Self { Self(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "") ?? .automatic }
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: L10n.text("自动")
        case .longbridge: "Longbridge"
        case .akshare: L10n.text("AKShare 来源")
        }
    }
    func providers(hasLongbridge: Bool) -> [Self] {
        switch self {
        case .automatic: hasLongbridge ? [.longbridge, .akshare] : [.akshare]
        default: [self]
        }
    }
}

/// A request/page belongs to the selected provider and credential revision.
/// The revision contains no credential material.
struct ChinaMarketConfiguration: Hashable, Sendable {
    static let revisionKey = "catfolio.china-market.credentials-revision"
    let source: ChinaMarketSource
    let credentialsRevision: String
    static var current: Self {
        .init(source: .current, credentialsRevision: UserDefaults.standard.string(forKey: revisionKey) ?? "")
    }
    static func credentialsChanged() {
        UserDefaults.standard.set(UUID().uuidString, forKey: revisionKey)
    }
    static func scope(ticker: String, currency: String?) -> Self? {
        ChinaSecurity(ticker, currency: currency) == nil ? nil : current
    }
}

struct ChinaMarketQuote: Sendable {
    let price: Double
    let previousClose: Double
    let observedAt: Date
    var changePercent: Double { (price / previousClose - 1) * 100 }
}

struct ChinaMarketAttribution: Equatable, Sendable {
    let source: ChinaMarketSource
    let observedAt: Date?
    let cached: Bool
}

actor ChinaMarketStatus {
    static let shared = ChinaMarketStatus()
    private var values: [String: ChinaMarketAttribution] = [:]
    func record(_ symbol: String, source: ChinaMarketSource, observedAt: Date?, cached: Bool = false) {
        values[symbol] = .init(source: source, observedAt: observedAt, cached: cached)
    }
    func value(for symbol: String) -> ChinaMarketAttribution? { values[symbol] }
}

enum ChinaMarketError: LocalizedError {
    case invalidData, noData, missingCredentials, rejected(Int), http(Int), timeout
    var errorDescription: String? {
        switch self {
        case .invalidData: L10n.text("A 股数据格式或证券身份无法确认")
        case .noData: L10n.text("暂无可用的 A 股行情，请稍后重试")
        case .missingCredentials: L10n.text("请在设置 → 服务商 → A 股行情中配置长桥凭据")
        case .rejected(let code): L10n.text("长桥请求失败（\(code)），请检查凭据与 OpenAPI 行情权限")
        case .http(let code): L10n.text("公开行情请求失败（\(code)），请稍后重试")
        case .timeout: L10n.text("A 股行情请求超时，请稍后重试")
        }
    }
}
