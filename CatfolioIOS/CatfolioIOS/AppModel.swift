import Foundation
import Observation

/// A manual home refresh reports what actually changed, rather than treating
/// a completed request (or restored presentation cache) as a new quote.
enum PortfolioRefreshResult: Equatable {
    case quotesUpdated
    case portfolioLoaded
    case portfolioLoadedWithoutNewQuotes
    case unchangedQuotes
    case unchangedContent
    case noHeldQuotes
    case failed(retainsData: Bool)

    static func acceptedQuoteCount(before: LocalPortfolioDocument, after: LocalPortfolioDocument) -> Int {
        var previous: [String: Date] = [:]
        for position in before.positions {
            guard let observedAt = position.quoteObservedAt else { continue }
            let key = LocalMarketQuoteKey.make(ticker: position.ticker, currency: position.quoteCurrency)
            previous[key] = max(previous[key] ?? .distantPast, observedAt)
        }
        return Set(after.positions.compactMap { position -> String? in
            let key = LocalMarketQuoteKey.make(ticker: position.ticker, currency: position.quoteCurrency)
            guard let observedAt = position.quoteObservedAt,
                  observedAt > (previous[key] ?? .distantPast) else { return nil }
            return key
        }).count
    }

    static func completed(previous: LocalPortfolioDocument?, loaded: LocalPortfolioDocument,
                          acceptedQuoteCount: Int, refreshedDisclosure: Bool, tracksQuotes: Bool) -> Self {
        if acceptedQuoteCount > 0 { return .quotesUpdated }
        if refreshedDisclosure { return .portfolioLoaded }
        let changed = previous.map { old in
            old.source != loaded.source || old.positions != loaded.positions || old.snapshots != loaded.snapshots
                || old.transactions != loaded.transactions || old.knownAccounts != loaded.knownAccounts
        } ?? (!loaded.positions.isEmpty || !loaded.snapshots.isEmpty || !(loaded.transactions ?? []).isEmpty)
        if changed { return tracksQuotes ? .portfolioLoadedWithoutNewQuotes : .portfolioLoaded }
        return tracksQuotes ? .unchangedQuotes : .unchangedContent
    }
}

// Shared observable state and initialization. Responsibility-specific methods
// live in AppModel+*.swift; all mutations remain on the main actor.
// Members shared by those extensions use module access because Swift private
// access does not cross files. Keep view-facing operations on AppModel.
@Observable
@MainActor
final class AppModel {
    var overview: PortfolioOverview?
    /// Profit already taken in the selected accounts, in USD: the broker's own
    /// result on every sale it reported one for. `.nan` when no sale carries
    /// one, which is not the same as zero profit.
    var realisedProfit: Double = .nan
    /// Sales the broker gave no result for. The figure above is short by
    /// whatever those made or lost, so the reader is told rather than shown a
    /// total that looks complete.
    var realisedProfitGaps = 0
    var portfolioChart: PortfolioChartResponse?
    /// The market session the home figures are from, yyyy-MM-dd. Every date
    /// on the home screen is named from this one value.
    var latestSessionDate: String? {
        portfolioChart?.marketDates.flatMap(DataDayLabel.latestSession(in:))
    }
    var holdings: [Holding] = []
    var holdingDailyChanges: [String: Double] = [:]
    var benchmarkDailyChange: Double?
    var isHoldingDailyChangesLoading = false
    var comparison: ComparisonResponse?
    var returnsAnalytics: ReturnsAnalyticsResponse?
    var isPortfolioLoading = false
    var isReturnsLoading = false
    var isReturnsAnalyticsLoading = false
    var returnsAnalyticsPendingParts: Set<ReturnsAnalyticsPart> = []
    // Keep the error, not its translated snapshot: the home empty state must
    // follow language changes made in Settings without reloading the portfolio.
    var portfolioFailure: Error?
    var portfolioError: String? { portfolioFailure?.localizedDescription }
    var returnsError: String?
    var comparisonWarning: String?
    var analyticsWarning: String?
    // Views read these values; account/mode operations own their writes.
    // Observable backing storage stays module-scoped for the split extensions.
    var activeBroker: BrokerProvider? { storedActiveBroker }
    var storedActiveBroker: BrokerProvider?
    var localSource = "尚未导入"
    var localUpdatedAt: Date?
    var portfolioCachedAt: Date?
    var accounts: [PortfolioAccount] = []
    var selectedAccountKeys: Set<String> { storedSelectedAccountKeys }
    var storedSelectedAccountKeys: Set<String> = []
    var portfolioChartRevision = 0
    var isPortfolioChartLoading = false
    var comparisonRevision = 0
    var returnsAnalyticsRevision = 0
    var isFakeDataMode: Bool { storedFakeDataMode }
    var storedFakeDataMode: Bool
    var isPublicInvestorMode: Bool { storedPublicInvestorMode }
    var storedPublicInvestorMode: Bool
    var publicInvestorSelection: String { storedPublicInvestorSelection }
    var storedPublicInvestorSelection: String
    var publicDisclosureSummary: PublicAccountDisclosure? {
        let rows = document.positions.compactMap(\.publicDisclosure)
        return rows.isEmpty ? nil : PublicAccountDisclosure.combining(rows)
    }
    var fakeDataModeError: String?
    var portfolioRecoveryNotice: String?

    var returnsWarning: String? {
        let values = [comparisonWarning, analyticsWarning]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return values.isEmpty ? nil : values.joined(separator: "\n")
    }

    @ObservationIgnored var document = LocalPortfolioDocument.empty
    @ObservationIgnored var fullDocument = LocalPortfolioDocument.empty
    @ObservationIgnored var portfolioRequestGeneration = 0
    @ObservationIgnored var returnsRequestGeneration = 0
    @ObservationIgnored var returnsAnalyticsRequestGeneration = 0
    @ObservationIgnored var returnsPageRequestGeneration = 0
    @ObservationIgnored var dailyChangesRequestGeneration = 0
    @ObservationIgnored var holdingDailyChangesSignature = ""
    @ObservationIgnored var detailMarketObservations: [PortfolioSource: [String: SecurityMarketObservation]] = [:]
    @ObservationIgnored var detailQuoteGeneration = 0
    @ObservationIgnored var holdingDetailContent: [HoldingDetailContentKey: HoldingDetailCachedContent] = [:]
    @ObservationIgnored var holdingDetailContentOrder: [HoldingDetailContentKey] = []
    @ObservationIgnored var holdingDetailMemoryObserver: NSObjectProtocol?
    /// Each entry holds a page's whole history, volume profile, options and
    /// research; a handful covers going back and forth between holdings.
    static let holdingDetailCacheLimit = 8
    @ObservationIgnored var returnsPageTask: Task<Void, Never>?
    @ObservationIgnored var detailChartTask: Task<Void, Never>?
    @ObservationIgnored var portfolioSourceTask: Task<Void, Never>?
    @ObservationIgnored var portfolioSourceGeneration = 0
    @ObservationIgnored var presentedSource: PortfolioSource?
    @ObservationIgnored var sourcePresentations: [PortfolioSource: SourcePresentation] = [:]
    @ObservationIgnored let modeDefaults: UserDefaults
    @ObservationIgnored let publicInvestorStore: PublicInvestorSimulationStore
    @ObservationIgnored let personalDocumentLoader: @Sendable () async throws -> LocalPortfolioDocument
    @ObservationIgnored let personalDocumentResetter: @Sendable () async throws -> URL?
    @ObservationIgnored let presentationCache: PortfolioPresentationCache
    static let brokerKey = "catfolio.activeBroker"
    static let selectedAccountsKey = "catfolio.selectedAccounts"
    static let selectsAllAccountsKey = "catfolio.selectsAllAccounts"
    static let fakeDataModeKey = "catfolio.fakeDataMode"
    static let fakeSelectedAccountsKey = "catfolio.fakeDataSelectedAccounts"
    static let fakeSelectsAllAccountsKey = "catfolio.fakeDataSelectsAllAccounts"

    init(
        defaults: UserDefaults = .standard,
        publicInvestorStore: PublicInvestorSimulationStore = .shared,
        personalDocumentLoader: @escaping @Sendable () async throws -> LocalPortfolioDocument = {
            try LocalPortfolioStore.shared.load()
        },
        personalDocumentResetter: @escaping @Sendable () async throws -> URL? = {
            try LocalPortfolioStore.shared.resetPortfolio()
        },
        presentationCache: PortfolioPresentationCache = .shared
    ) {
        modeDefaults = defaults
        self.publicInvestorStore = publicInvestorStore
        self.personalDocumentLoader = personalDocumentLoader
        self.personalDocumentResetter = personalDocumentResetter
        self.presentationCache = presentationCache
        storedPublicInvestorSelection = defaults.string(forKey: PublicInvestorPreferences.selectionKey) ?? PublicInvestorPreferences.defaultSelection
        storedFakeDataMode = defaults.bool(forKey: Self.fakeDataModeKey)
        storedPublicInvestorMode = defaults.bool(forKey: PublicInvestorPreferences.enabledKey)
        if isFakeDataMode && isPublicInvestorMode {
            storedFakeDataMode = PublicInvestorPreferences.isDemo(publicInvestorSelection)
            storedPublicInvestorMode = !isFakeDataMode
        }
        if let raw = defaults.string(forKey: Self.brokerKey) {
            storedActiveBroker = BrokerProvider(rawValue: raw)
        }
    }
}
