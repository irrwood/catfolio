import Foundation
import CryptoKit

enum FakePortfolioGenerator {
    // Types used only by the retired generator below. Its entry point is
    // compile-time unavailable; the active path never receives user data.
    private struct Identity {
        let ticker: String
        let name: String
    }

    private struct AccountIdentity {
        let id: String
        let name: String

        var key: String { "假数据|\(id)" }
    }

    private struct DemoSpec {
        let ticker: String
        let name: String
        let currency: String
        let averageCost: Double
        let quotePrice: Double
        let weight: Double
        let account: Int
        let openedDaysAgo: Int
    }

    private struct DemoAccountSpec {
        let id: String
        let name: String
        let source: String
        let baseCurrency: String
    }

    private static let demoAccounts: [Int: DemoAccountSpec] = [
        1: DemoAccountSpec(
            id: "demo-moomoo-7842",
            name: "Moomoo · 美股账户",
            source: "Moomoo",
            baseCurrency: "USD"
        ),
        2: DemoAccountSpec(
            id: "demo-ibkr-U9483721",
            name: "IBKR · 全球账户",
            source: "IBKR Flex",
            baseCurrency: "GBP"
        ),
        3: DemoAccountSpec(
            id: "demo-212-ISA-5198",
            name: "Trading 212 · ISA",
            source: "Trading 212",
            baseCurrency: "GBP"
        ),
    ]

    /// Strong-privacy demo data. None of these positions, weights, prices,
    /// dates, accounts, or return paths are derived from the user's portfolio.
    private static let privateDemoSpecs = [
        // Moomoo · 美股账户
        DemoSpec(ticker: "ADBE", name: "Adobe Inc.", currency: "USD", averageCost: 365.40, quotePrice: 421.75, weight: 0.044, account: 1, openedDaysAgo: 1_040),
        DemoSpec(ticker: "AMD", name: "Advanced Micro Devices, Inc.", currency: "USD", averageCost: 138.70, quotePrice: 174.35, weight: 0.040, account: 1, openedDaysAgo: 845),
        DemoSpec(ticker: "ORCL", name: "Oracle Corporation", currency: "USD", averageCost: 186.30, quotePrice: 248.15, weight: 0.042, account: 1, openedDaysAgo: 720),
        DemoSpec(ticker: "UBER", name: "Uber Technologies, Inc.", currency: "USD", averageCost: 72.65, quotePrice: 92.40, weight: 0.035, account: 1, openedDaysAgo: 655),
        DemoSpec(ticker: "KO", name: "The Coca-Cola Company", currency: "USD", averageCost: 61.20, quotePrice: 70.15, weight: 0.030, account: 1, openedDaysAgo: 590),
        DemoSpec(ticker: "VOO", name: "Vanguard S&P 500 ETF", currency: "USD", averageCost: 529.80, quotePrice: 642.30, weight: 0.055, account: 1, openedDaysAgo: 540),
        DemoSpec(ticker: "0388.HK", name: "Hong Kong Exchanges and Clearing Limited", currency: "HKD", averageCost: 378.60, quotePrice: 456.20, weight: 0.034, account: 1, openedDaysAgo: 235),
        DemoSpec(ticker: "D05.SI", name: "DBS Group Holdings Ltd", currency: "SGD", averageCost: 47.15, quotePrice: 54.30, weight: 0.030, account: 1, openedDaysAgo: 145),

        // IBKR · 全球账户
        DemoSpec(ticker: "COST", name: "Costco Wholesale Corporation", currency: "USD", averageCost: 774.25, quotePrice: 985.60, weight: 0.050, account: 2, openedDaysAgo: 910),
        DemoSpec(ticker: "AMD", name: "Advanced Micro Devices, Inc.", currency: "USD", averageCost: 141.10, quotePrice: 174.35, weight: 0.045, account: 2, openedDaysAgo: 760),
        DemoSpec(ticker: "XOM", name: "Exxon Mobil Corporation", currency: "USD", averageCost: 103.45, quotePrice: 116.20, weight: 0.050, account: 2, openedDaysAgo: 790),
        DemoSpec(ticker: "ORCL", name: "Oracle Corporation", currency: "USD", averageCost: 191.80, quotePrice: 248.15, weight: 0.045, account: 2, openedDaysAgo: 610),
        DemoSpec(ticker: "VOO", name: "Vanguard S&P 500 ETF", currency: "USD", averageCost: 536.20, quotePrice: 642.30, weight: 0.060, account: 2, openedDaysAgo: 500),
        DemoSpec(ticker: "VUAG.L", name: "Vanguard S&P 500 UCITS ETF", currency: "GBP", averageCost: 88.95, quotePrice: 105.40, weight: 0.050, account: 2, openedDaysAgo: 470),
        DemoSpec(ticker: "ASML.AS", name: "ASML Holding N.V.", currency: "EUR", averageCost: 850.20, quotePrice: 1_040.80, weight: 0.040, account: 2, openedDaysAgo: 285),
        DemoSpec(ticker: "SAP.DE", name: "SAP SE", currency: "EUR", averageCost: 221.30, quotePrice: 272.45, weight: 0.040, account: 2, openedDaysAgo: 330),

        // Trading 212 · ISA
        DemoSpec(ticker: "ADBE", name: "Adobe Inc.", currency: "USD", averageCost: 372.80, quotePrice: 421.75, weight: 0.040, account: 3, openedDaysAgo: 820),
        DemoSpec(ticker: "COST", name: "Costco Wholesale Corporation", currency: "USD", averageCost: 801.40, quotePrice: 985.60, weight: 0.045, account: 3, openedDaysAgo: 690),
        DemoSpec(ticker: "AMD", name: "Advanced Micro Devices, Inc.", currency: "USD", averageCost: 145.60, quotePrice: 174.35, weight: 0.040, account: 3, openedDaysAgo: 620),
        DemoSpec(ticker: "KO", name: "The Coca-Cola Company", currency: "USD", averageCost: 62.75, quotePrice: 70.15, weight: 0.030, account: 3, openedDaysAgo: 510),
        DemoSpec(ticker: "VOO", name: "Vanguard S&P 500 ETF", currency: "USD", averageCost: 548.60, quotePrice: 642.30, weight: 0.055, account: 3, openedDaysAgo: 430),
        DemoSpec(ticker: "EQQQ.L", name: "Invesco EQQQ Nasdaq-100 UCITS ETF", currency: "GBX", averageCost: 35_640, quotePrice: 41_280, weight: 0.035, account: 3, openedDaysAgo: 425),
        DemoSpec(ticker: "AZN.L", name: "AstraZeneca PLC", currency: "GBX", averageCost: 10_860, quotePrice: 12_420, weight: 0.035, account: 3, openedDaysAgo: 380),
        DemoSpec(ticker: "ASML.AS", name: "ASML Holding N.V.", currency: "EUR", averageCost: 872.40, quotePrice: 1_040.80, weight: 0.030, account: 3, openedDaysAgo: 240),
    ]

    static func make() -> LocalPortfolioDocument {
        let targetMarketValueUSD = 93_742.65
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        let positions = privateDemoSpecs.map { spec -> LocalPositionRecord in
            let rate = LocalPortfolioEngine.usdRate(for: spec.currency) ?? 1
            let shares = targetMarketValueUSD * spec.weight / (spec.quotePrice * rate)
            let opened = calendar.date(byAdding: .day, value: -spec.openedDaysAgo, to: now) ?? now
            let account = demoAccounts[spec.account] ?? demoAccounts[1]!
            return LocalPositionRecord(
                ticker: spec.ticker,
                name: spec.name,
                shares: shares,
                averageCost: spec.averageCost,
                currency: spec.currency,
                quotePrice: spec.quotePrice,
                quoteCurrency: spec.currency,
                source: account.source,
                openedDate: DayDateCodec.string(from: opened),
                accountID: account.id,
                accountName: account.name,
                accountCurrency: account.baseCurrency,
                brokerPnl: nil,
                brokerPnlCurrency: nil,
                brokerFxPnl: nil,
                brokerFxPnlCurrency: nil,
                fxPnl: nil,
                fxPnlCurrency: nil,
                fxPnlStatus: "demo_not_applicable",
                fxPnlSource: "private_synthetic_demo"
            )
        }

        let dividendTickers = Set([
            "COST", "XOM", "KO", "VOO", "VUAG.L", "EQQQ.L",
            "AZN.L", "SAP.DE", "0388.HK", "D05.SI",
        ])
        func demoDate(daysAgo: Int) -> String {
            let date = calendar.date(byAdding: .day, value: -daysAgo, to: now) ?? now
            return DayDateCodec.string(from: date)
        }

        var transactions = zip(privateDemoSpecs, positions).flatMap { spec, position -> [LocalTransactionRecord] in
            let account = demoAccounts[spec.account] ?? demoAccounts[1]!
            var rows = [
                LocalTransactionRecord(
                    date: demoDate(daysAgo: spec.openedDaysAgo),
                    action: "BUY",
                    ticker: position.ticker,
                    quantity: position.shares * 0.72,
                    price: position.averageCost * 0.90,
                    currency: position.currency,
                    source: position.source,
                    accountID: position.accountID,
                    accountName: position.accountName,
                    tradeID: "demo-\(spec.account)-\(position.ticker)-buy-1",
                    entryMethod: "demo"
                ),
                LocalTransactionRecord(
                    date: demoDate(daysAgo: max(60, spec.openedDaysAgo / 2)),
                    action: "BUY",
                    ticker: position.ticker,
                    quantity: position.shares * 0.46,
                    price: position.averageCost * 1.15,
                    currency: position.currency,
                    source: position.source,
                    accountID: position.accountID,
                    accountName: position.accountName,
                    tradeID: "demo-\(spec.account)-\(position.ticker)-buy-2",
                    entryMethod: "demo"
                ),
                LocalTransactionRecord(
                    date: demoDate(daysAgo: max(16, spec.openedDaysAgo / 7)),
                    action: "SELL",
                    ticker: position.ticker,
                    quantity: position.shares * 0.18,
                    price: position.quotePrice * 0.94,
                    currency: position.currency,
                    source: position.source,
                    accountID: position.accountID,
                    accountName: position.accountName,
                    tradeID: "demo-\(spec.account)-\(position.ticker)-sell-1",
                    entryMethod: "demo"
                ),
            ]

            if dividendTickers.contains(position.ticker) {
                rows.append(LocalTransactionRecord(
                    date: demoDate(daysAgo: max(12, min(82, spec.openedDaysAgo / 5))),
                    action: "DIVIDEND",
                    ticker: position.ticker,
                    quantity: 1,
                    price: max(7.20, targetMarketValueUSD * spec.weight * 0.0042),
                    currency: account.baseCurrency,
                    source: position.source,
                    accountID: position.accountID,
                    accountName: position.accountName,
                    tradeID: "demo-\(spec.account)-\(position.ticker)-dividend-1",
                    entryMethod: "demo"
                ))
            }
            return rows
        }

        for slot in demoAccounts.keys.sorted() {
            guard let account = demoAccounts[slot] else { continue }
            let interestAmount: Double = switch slot {
            case 1: 27.16
            case 2: 31.84
            default: 18.42
            }
            transactions.append(LocalTransactionRecord(
                date: demoDate(daysAgo: 8 + slot * 3),
                action: "INTEREST",
                ticker: "CASH",
                quantity: 1,
                price: interestAmount,
                currency: account.baseCurrency,
                source: account.source,
                accountID: account.id,
                accountName: account.name,
                tradeID: "demo-\(slot)-cash-interest-1",
                entryMethod: "demo"
            ))
        }

        let accountPositions = Dictionary(grouping: positions, by: \.accountKey)
        let currentAccountTotals = accountPositions.compactMapValues { rows -> LocalAccountSnapshotTotals? in
            guard let totals = try? LocalPortfolioEngine.totals(for: rows) else { return nil }
            return LocalAccountSnapshotTotals(marketValueUSD: totals.marketValue, costUSD: totals.cost)
        }
        let currentTotals = (try? LocalPortfolioEngine.totals(for: positions))
            ?? LocalPortfolioEngine.Totals(cost: 78_410.20, marketValue: targetMarketValueUSD)
        let snapshots = (0..<24).map { index -> LocalPortfolioSnapshotRecord in
            let progress = 0.34 + 0.66 * Double(index) / 23
            let date = calendar.date(byAdding: .month, value: index - 23, to: now) ?? now
            if index == 23 {
                return LocalPortfolioSnapshotRecord(
                    date: DayDateCodec.string(from: date),
                    marketValueUSD: currentTotals.marketValue,
                    costUSD: currentTotals.cost,
                    accountTotals: currentAccountTotals
                )
            }
            let trend = 0.012 + 0.158 * pow(Double(index) / 23, 1.35)
            let wave = sin(Double(index) * 0.83) * 0.024 + cos(Double(index) * 0.37) * 0.011
            let accountTotals = currentAccountTotals.mapValues { totals in
                LocalAccountSnapshotTotals(
                    marketValueUSD: totals.costUSD * progress * (1 + trend + wave),
                    costUSD: totals.costUSD * progress
                )
            }
            return LocalPortfolioSnapshotRecord(
                date: DayDateCodec.string(from: date),
                marketValueUSD: accountTotals.values.reduce(0) { $0 + $1.marketValueUSD },
                costUSD: accountTotals.values.reduce(0) { $0 + $1.costUSD },
                accountTotals: accountTotals
            )
        }

        return LocalPortfolioDocument(
            schemaVersion: 4,
            source: "假数据（Trading 212 + Moomoo + IBKR）",
            updatedAt: calendar.date(byAdding: .minute, value: -37, to: now) ?? now,
            marketDataUpdatedAt: calendar.date(byAdding: .minute, value: -37, to: now) ?? now,
            positions: positions,
            snapshots: snapshots,
            transactions: transactions,
            isSynthetic: true
        )
    }

    private static let usdStocks = [
        Identity(ticker: "ADBE", name: "Adobe Inc."),
        Identity(ticker: "AMD", name: "Advanced Micro Devices, Inc."),
        Identity(ticker: "AMGN", name: "Amgen Inc."),
        Identity(ticker: "BKNG", name: "Booking Holdings Inc."),
        Identity(ticker: "CAT", name: "Caterpillar Inc."),
        Identity(ticker: "COST", name: "Costco Wholesale Corporation"),
        Identity(ticker: "CRM", name: "Salesforce, Inc."),
        Identity(ticker: "CSCO", name: "Cisco Systems, Inc."),
        Identity(ticker: "DIS", name: "The Walt Disney Company"),
        Identity(ticker: "GE", name: "GE Aerospace"),
        Identity(ticker: "HD", name: "The Home Depot, Inc."),
        Identity(ticker: "HON", name: "Honeywell International Inc."),
        Identity(ticker: "IBM", name: "International Business Machines Corporation"),
        Identity(ticker: "INTU", name: "Intuit Inc."),
        Identity(ticker: "ISRG", name: "Intuitive Surgical, Inc."),
        Identity(ticker: "KO", name: "The Coca-Cola Company"),
        Identity(ticker: "LIN", name: "Linde plc"),
        Identity(ticker: "LOW", name: "Lowe's Companies, Inc."),
        Identity(ticker: "MCD", name: "McDonald's Corporation"),
        Identity(ticker: "MU", name: "Micron Technology, Inc."),
        Identity(ticker: "NFLX", name: "Netflix, Inc."),
        Identity(ticker: "NKE", name: "NIKE, Inc."),
        Identity(ticker: "NOW", name: "ServiceNow, Inc."),
        Identity(ticker: "ORCL", name: "Oracle Corporation"),
        Identity(ticker: "PANW", name: "Palo Alto Networks, Inc."),
        Identity(ticker: "PEP", name: "PepsiCo, Inc."),
        Identity(ticker: "PFE", name: "Pfizer Inc."),
        Identity(ticker: "QCOM", name: "QUALCOMM Incorporated"),
        Identity(ticker: "SBUX", name: "Starbucks Corporation"),
        Identity(ticker: "TMO", name: "Thermo Fisher Scientific Inc."),
        Identity(ticker: "TXN", name: "Texas Instruments Incorporated"),
        Identity(ticker: "UBER", name: "Uber Technologies, Inc."),
        Identity(ticker: "UNH", name: "UnitedHealth Group Incorporated"),
        Identity(ticker: "UPS", name: "United Parcel Service, Inc."),
        Identity(ticker: "WMT", name: "Walmart Inc."),
        Identity(ticker: "XOM", name: "Exxon Mobil Corporation"),
    ]

    private static let usdFunds = [
        Identity(ticker: "SPY", name: "SPDR S&P 500 ETF Trust"),
        Identity(ticker: "VOO", name: "Vanguard S&P 500 ETF"),
        Identity(ticker: "IVV", name: "iShares Core S&P 500 ETF"),
    ]

    private static let londonStocks = [
        Identity(ticker: "AZN.L", name: "AstraZeneca PLC"),
        Identity(ticker: "BA.L", name: "BAE Systems plc"),
        Identity(ticker: "BARC.L", name: "Barclays PLC"),
        Identity(ticker: "CPG.L", name: "Compass Group PLC"),
        Identity(ticker: "DGE.L", name: "Diageo plc"),
        Identity(ticker: "GSK.L", name: "GSK plc"),
        Identity(ticker: "HSBA.L", name: "HSBC Holdings plc"),
        Identity(ticker: "LSEG.L", name: "London Stock Exchange Group plc"),
        Identity(ticker: "NG.L", name: "National Grid plc"),
        Identity(ticker: "REL.L", name: "RELX PLC"),
        Identity(ticker: "RIO.L", name: "Rio Tinto plc"),
        Identity(ticker: "SHEL.L", name: "Shell plc"),
        Identity(ticker: "ULVR.L", name: "Unilever PLC"),
        Identity(ticker: "VOD.L", name: "Vodafone Group Plc"),
    ]

    private static let londonFunds = [
        Identity(ticker: "VUAG.L", name: "Vanguard S&P 500 UCITS ETF"),
        Identity(ticker: "VUSA.L", name: "Vanguard S&P 500 UCITS ETF"),
    ]

    private static let londonPenceFunds = [
        Identity(ticker: "EQQQ.L", name: "Invesco EQQQ Nasdaq-100 UCITS ETF"),
    ]

    private static let euroStocks = [
        Identity(ticker: "AIR.PA", name: "Airbus SE"),
        Identity(ticker: "ALV.DE", name: "Allianz SE"),
        Identity(ticker: "ASML.AS", name: "ASML Holding N.V."),
        Identity(ticker: "BAS.DE", name: "BASF SE"),
        Identity(ticker: "BNP.PA", name: "BNP Paribas SA"),
        Identity(ticker: "DTE.DE", name: "Deutsche Telekom AG"),
        Identity(ticker: "MC.PA", name: "LVMH Moet Hennessy Louis Vuitton SE"),
        Identity(ticker: "OR.PA", name: "L'Oreal S.A."),
        Identity(ticker: "SAP.DE", name: "SAP SE"),
        Identity(ticker: "SIE.DE", name: "Siemens AG"),
    ]

    private static let hkdStocks = [
        Identity(ticker: "0388.HK", name: "Hong Kong Exchanges and Clearing Limited"),
        Identity(ticker: "0669.HK", name: "Techtronic Industries Company Limited"),
        Identity(ticker: "1299.HK", name: "AIA Group Limited"),
        Identity(ticker: "2318.HK", name: "Ping An Insurance Group Company of China, Ltd."),
        Identity(ticker: "2388.HK", name: "BOC Hong Kong (Holdings) Limited"),
    ]

    private static let regionalStocks: [String: [Identity]] = [
        "CAD": [
            Identity(ticker: "CNQ.TO", name: "Canadian Natural Resources Limited"),
            Identity(ticker: "RY.TO", name: "Royal Bank of Canada"),
            Identity(ticker: "SHOP.TO", name: "Shopify Inc."),
        ],
        "AUD": [
            Identity(ticker: "BHP.AX", name: "BHP Group Limited"),
            Identity(ticker: "CSL.AX", name: "CSL Limited"),
            Identity(ticker: "WES.AX", name: "Wesfarmers Limited"),
        ],
        "JPY": [
            Identity(ticker: "6758.T", name: "Sony Group Corporation"),
            Identity(ticker: "6861.T", name: "Keyence Corporation"),
            Identity(ticker: "7203.T", name: "Toyota Motor Corporation"),
        ],
        "SGD": [
            Identity(ticker: "C6L.SI", name: "Singapore Airlines Limited"),
            Identity(ticker: "D05.SI", name: "DBS Group Holdings Ltd"),
            Identity(ticker: "O39.SI", name: "Oversea-Chinese Banking Corporation Limited"),
        ],
    ]

    @available(*, unavailable, message: "Privacy-unsafe: use the independent make() demo instead")
    private static func makeObfuscatedLegacy(from source: LocalPortfolioDocument) -> LocalPortfolioDocument {
        guard !source.positions.isEmpty else { return source }

        let signature = source.positions
            .map { $0.ticker.uppercased() }
            .sorted()
            .joined(separator: "|")
        let valueFactor = factor("portfolio:\(signature)", low: 0.72, high: 1.48)
        let dateOffset = -Int(factor("date:\(signature)", low: 11, high: 44))

        let originalAccounts = Set(source.positions.map(\.accountKey)).sorted()
        let accounts = Dictionary(uniqueKeysWithValues: originalAccounts.enumerated().map { index, key in
            (key, AccountIdentity(id: "demo-\(index + 1)", name: "演示账户 \(index + 1)"))
        })
        let identities = identityMap(for: source.positions)

        let positions = source.positions.map { position -> LocalPositionRecord in
            let originalTicker = position.ticker.uppercased()
            let identity = identities[originalTicker]
                ?? Identity(ticker: "CF\(identities.count + 1)", name: "Catfolio Sample Holding")
            let priceFactor = factor("price:\(originalTicker)", low: 0.74, high: 1.34)
            let shareFactor = valueFactor / priceFactor
            let account = accounts[position.accountKey]
            return LocalPositionRecord(
                ticker: identity.ticker,
                name: identity.name,
                shares: position.shares * shareFactor,
                averageCost: position.averageCost * priceFactor,
                currency: position.currency,
                quotePrice: position.quotePrice * priceFactor,
                quoteCurrency: position.quoteCurrency,
                source: "假数据",
                openedDate: shifted(position.openedDate, by: dateOffset),
                accountID: account?.id ?? "demo-1",
                accountName: account?.name ?? "演示账户 1",
                accountCurrency: position.accountCurrency,
                brokerPnl: position.brokerPnl.map { $0 * valueFactor },
                brokerPnlCurrency: position.brokerPnlCurrency,
                brokerFxPnl: position.brokerFxPnl.map { $0 * valueFactor },
                brokerFxPnlCurrency: position.brokerFxPnlCurrency,
                fxPnl: position.fxPnl.map { $0 * valueFactor },
                fxPnlCurrency: position.fxPnlCurrency,
                fxPnlStatus: position.fxPnlStatus,
                fxPnlSource: position.fxPnl == nil ? nil : "generated_fake_data"
            )
        }

        let snapshots = source.snapshots.map { snapshot in
            let accountTotals = snapshot.accountTotals.map { totals in
                Dictionary(uniqueKeysWithValues: totals.compactMap { key, value in
                    accounts[key].map { account in
                        (account.key, LocalAccountSnapshotTotals(
                            marketValueUSD: value.marketValueUSD * valueFactor,
                            costUSD: value.costUSD * valueFactor
                        ))
                    }
                })
            }
            return LocalPortfolioSnapshotRecord(
                date: shifted(snapshot.date, by: dateOffset) ?? snapshot.date,
                marketValueUSD: snapshot.marketValueUSD * valueFactor,
                costUSD: snapshot.costUSD * valueFactor,
                accountTotals: accountTotals
            )
        }

        let transactions = source.transactions?.compactMap { transaction -> LocalTransactionRecord? in
            let originalTicker = transaction.ticker.uppercased()
            guard let identity = identities[originalTicker] else { return nil }
            let priceFactor = factor("price:\(originalTicker)", low: 0.74, high: 1.34)
            let shareFactor = valueFactor / priceFactor
            let account = accounts[transaction.accountKey]
            return LocalTransactionRecord(
                date: shifted(transaction.date, by: dateOffset) ?? transaction.date,
                action: transaction.action,
                ticker: identity.ticker,
                quantity: transaction.quantity * shareFactor,
                price: transaction.price * priceFactor,
                currency: transaction.currency,
                source: "假数据",
                accountID: account?.id ?? "demo-1",
                accountName: account?.name ?? "演示账户 1",
                tradeID: nil,
                brokerFXRate: transaction.brokerFXRate.map {
                    $0 * factor("fx:\(originalTicker)", low: 0.985, high: 1.015)
                },
                entryMethod: transaction.entryMethod,
                realisedProfitLoss: transaction.realisedProfitLoss.map { $0 * valueFactor },
                realisedProfitLossCurrency: transaction.realisedProfitLossCurrency
            )
        }

        return LocalPortfolioDocument(
            schemaVersion: source.schemaVersion,
            source: "假数据（本机脱敏）",
            updatedAt: Calendar(identifier: .gregorian).date(
                byAdding: .day,
                value: dateOffset,
                to: source.updatedAt
            ) ?? source.updatedAt,
            marketDataUpdatedAt: source.marketDataUpdatedAt.flatMap {
                Calendar(identifier: .gregorian).date(
                    byAdding: .day,
                    value: dateOffset,
                    to: $0
                )
            },
            positions: positions,
            snapshots: snapshots,
            transactions: transactions,
            isSynthetic: true
        )
    }

    private static func identityMap(for positions: [LocalPositionRecord]) -> [String: Identity] {
        var result: [String: Identity] = [:]
        var used = Set<String>()
        let uniquePositions = Dictionary(grouping: positions, by: { $0.ticker.uppercased() })
            .compactMap { _, values in values.first }
            .sorted { $0.ticker.uppercased() < $1.ticker.uppercased() }

        for (index, position) in uniquePositions.enumerated() {
            let original = position.ticker.uppercased()
            let pool = identityPool(for: position)
            let start = Int(stableHash("identity:\(original)") % UInt64(max(1, pool.count)))
            let identity = (0..<pool.count)
                .map { pool[(start + $0) % pool.count] }
                .first { !used.contains($0.ticker) && $0.ticker.uppercased() != original }
                ?? Identity(ticker: "CF\(index + 1)", name: "Catfolio Sample Holding \(index + 1)")
            result[original] = identity
            used.insert(identity.ticker)
        }
        return result
    }

    private static func identityPool(for position: LocalPositionRecord) -> [Identity] {
        let currency = position.currency.uppercased()
        let name = position.name.uppercased()
        let isFund = name.contains("ETF") || name.contains("UCITS") || name.contains("FUND")
        if currency == "GBP" { return isFund ? londonFunds : londonStocks }
        if currency == "GBX" { return isFund ? londonPenceFunds : londonStocks }
        if currency == "EUR" { return euroStocks }
        if currency == "HKD" { return hkdStocks }
        if let regional = regionalStocks[currency] { return regional }
        return isFund ? usdFunds : usdStocks
    }

    private static func stableHash(_ value: String) -> UInt64 {
        value.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { hash, byte in
            (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }

    private static func factor(_ key: String, low: Double, high: Double) -> Double {
        let unit = Double(stableHash(key) % 1_000_000) / 999_999
        return low + (high - low) * unit
    }

    private static func shifted(_ value: String?, by days: Int) -> String? {
        guard let value, let date = DayDateCodec.date(from: value) else { return value }
        let shifted = Calendar(identifier: .gregorian).date(byAdding: .day, value: days, to: date) ?? date
        return DayDateCodec.string(from: shifted)
    }
}
