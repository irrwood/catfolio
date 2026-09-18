import Foundation
import CryptoKit
import FoundationModels
import OSLog

enum LocalServiceKeys {
    static let fmp = "catfolio.fmp.api-key"
    static let massive = "catfolio.massive.api-key"
    static let deepSeek = "catfolio.deepseek.api-key"
    static let openRouter = "catfolio.openrouter.api-key"
    static let finnhub = "catfolio.finnhub.api-key"
    /// Not a secret, so in UserDefaults: which OpenRouter model answers.
    static let openRouterModel = "catfolio.openrouter.model"
    /// OpenRouter's own router, which picks a model for each request.
    static let defaultOpenRouterModel = "openrouter/auto"

    static var openRouterModelID: String {
        let stored = UserDefaults.standard.string(forKey: openRouterModel)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? defaultOpenRouterModel : stored
    }

    static var hasOpenRouterKey: Bool {
        !(KeychainStore.string(for: openRouter)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    static var hasFinnhubKey: Bool {
        !(KeychainStore.string(for: finnhub)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
}

enum LocalServiceError: LocalizedError {
    case missingMarketKey
    case missingMassiveKey
    case missingAIKey
    case missingOpenRouterKey
    case missingCodexConnection
    case appleModelUnavailable(String)
    case noAvailableAIProvider(String)
    case invalidResponse
    case remote(String)
    case noMarketData
    case noHistoricalPrices
    case noSupportedETF

    var errorDescription: String? {
        switch self {
        case .missingMarketKey:
            L10n.text("成交量分析需要行情数据。请在设置中填写 Financial Modeling Prep API Key。")
        case .missingMassiveKey:
            L10n.text("请先在设置中填写 Massive API Key。")
        case .missingAIKey:
            L10n.text("DeepSeek 模式需要 API Key。请在设置中填写，Key 只保存在此 iPhone。")
        case .missingOpenRouterKey:
            L10n.text("OpenRouter 模式需要 API Key。请在设置中填写，Key 只保存在此 iPhone。")
        case .missingCodexConnection:
            L10n.text("请先在设置中连接 ChatGPT Codex。")
        case let .appleModelUnavailable(reason):
            L10n.text("Apple 本地模型暂不可用：\(reason)")
        case let .noAvailableAIProvider(reason):
            L10n.text("当前没有可用的 AI 模型：\(reason)")
        case .invalidResponse:
            L10n.text("第三方服务返回了无法识别的数据")
        case let .remote(message):
            message
        case .noMarketData:
            L10n.text("没有读取到这只证券的历史成交量")
        case .noHistoricalPrices:
            L10n.text("无法读取历史价格，请检查行情 API 设置与网络后重试")
        case .noSupportedETF:
            L10n.text("当前组合中的 ETF 暂无可用持仓快照")
        }
    }
}

enum AIProviderPreference: String, CaseIterable, Identifiable {
    case automatic
    case apple
    case codex
    case deepSeek
    case openRouter

    static let storageKey = "catfolio.ai.provider"

    var id: String { rawValue }

    /// Whether this choice can answer right now, and what to tell the reader
    /// when it can't. `automatic` is ready when any provider it falls back
    /// through is.
    var readiness: (isReady: Bool, message: String) {
        let hasDeepSeekKey = !(KeychainStore.string(for: LocalServiceKeys.deepSeek)?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        switch self {
        case .apple:
            return (LocalAIClient.appleModelStatus.isAvailable, LocalAIClient.appleModelStatus.message)
        case .codex:
            return (CodexOAuthClient.cachedConnected, L10n.text("Codex 尚未连接"))
        case .deepSeek:
            return (hasDeepSeekKey, L10n.text("DeepSeek 模式需要 API Key。请在设置中填写，Key 只保存在此 iPhone。"))
        case .openRouter:
            return (LocalServiceKeys.hasOpenRouterKey, L10n.text("OpenRouter 需要 API Key，请在设置 › 服务商中填写。"))
        case .automatic:
            let ready = LocalAIClient.appleModelStatus.isAvailable || CodexOAuthClient.cachedConnected
                || LocalServiceKeys.hasOpenRouterKey || hasDeepSeekKey
            return (ready, L10n.text("没有可用的 AI：请在设置 › 服务商中连接一个模型。"))
        }
    }

    static var current: AIProviderPreference {
        guard let raw = UserDefaults.standard.string(forKey: storageKey),
              let value = AIProviderPreference(rawValue: raw) else { return .automatic }
        return value
    }

    var title: String {
        switch self {
        case .automatic: L10n.text("自动")
        case .apple: L10n.text("Apple 本地")
        case .codex: "Codex"
        case .deepSeek: "DeepSeek"
        case .openRouter: "OpenRouter"
        }
    }

    var detail: String {
        switch self {
        case .automatic:
            L10n.text("优先使用 Apple 本地模型；不可用时依次使用已连接的 Codex、已填 Key 的 OpenRouter 和 DeepSeek。")
        case .apple:
            L10n.text("组合摘要只在设备上处理，可离线使用；需要 Apple Intelligence 已开启且模型就绪。")
        case .codex:
            L10n.text("在此 iPhone 上登录 ChatGPT，直接使用你的 Codex 订阅进行分析。")
        case .deepSeek:
            L10n.text("组合摘要会直接发送给 DeepSeek，需要 API Key 和网络连接。")
        case .openRouter:
            L10n.text("组合摘要会直接发送给 OpenRouter，由你在设置里选的模型回答；需要 API Key 和网络连接。")
        }
    }
}


enum AppleFoundationModelStatus: Equatable {
    case available
    case requiresNewerOS
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case unknown

    var isAvailable: Bool { self == .available }

    var message: String {
        switch self {
        case .available: L10n.text("Apple 本地模型已就绪")
        case .requiresNewerOS: L10n.text("需要 iOS 26 或更高版本")
        case .deviceNotEligible: L10n.text("这台设备不支持 Apple Intelligence")
        case .appleIntelligenceNotEnabled: L10n.text("请先在系统设置中开启 Apple Intelligence")
        case .modelNotReady: L10n.text("Apple 模型仍在下载或暂未就绪")
        case .unknown: L10n.text("Apple 模型当前不可用")
        }
    }
}


struct PortfolioAttentionDailyBar: Sendable {
    let date: String
    let close: Double
    let high: Double
    let low: Double
    let volume: Double
}

/// Each current holding's value by day; see `LocalMarketDataClient.holdingValueHistory`.
struct HoldingValueHistory: Sendable {
    struct Row: Sendable {
        let dateText: String
        let cost: Double
        /// USD by upper-cased ticker.
        let values: [String: Double]
        /// What the holdings open on this day cost, USD by upper-cased ticker.
        var costs: [String: Double] = [:]

        /// A holding's gain on this day: its value less what it cost.
        func gain(_ ticker: String) -> Double {
            guard let value = values[ticker] else { return 0 }
            return value - (costs[ticker] ?? value)
        }

        var date: Date { DayDateCodec.date(from: dateText) ?? .distantPast }
        var total: Double { values.values.reduce(0, +) }
    }

    let rows: [Row]
    /// What each holding cost, USD by upper-cased ticker.
    let costs: [String: Double]
    let names: [String: String]

    /// Each holding's gain on the latest day: its value then less its cost.
    var gains: [String: Double] {
        guard let last = rows.last else { return [:] }
        var result: [String: Double] = [:]
        for (ticker, value) in last.values {
            result[ticker] = value - (last.costs[ticker] ?? costs[ticker] ?? value)
        }
        return result
    }
}


enum LocalRequestSessions {
    static let ephemeral = URLSession(configuration: .ephemeral)
    static let waiting: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration)
    }()
}


extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

