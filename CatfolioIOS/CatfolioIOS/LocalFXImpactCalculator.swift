import Foundation
import CryptoKit
import FoundationModels
import OSLog

/// Reconstructs the currency component of open-position P/L independently for
/// every broker account. Rates are expressed as USD per currency unit; the
/// calculator derives instrument-to-account rates so a GBP account holding a
/// USD stock retains its GBP economic perspective before the result is finally
/// translated to Catfolio's USD storage currency.
struct LocalFXImpactCalculator {
    private struct Lot {
        var quantity: Double
        let date: String
        let currency: String
        let brokerFXRateToAccount: Double?
    }

    private let marketData = LocalMarketDataClient()

    func enrich(
        positions: [LocalPositionRecord],
        transactions: [LocalTransactionRecord]
    ) async -> [LocalPositionRecord] {
        let candidates = positions.filter {
            $0.fxPnl == nil && $0.accountCurrency != nil
        }
        guard !candidates.isEmpty else { return positions }

        let today = DayDateCodec.string(from: Date())
        let transactionStart = transactions.map(\.date).min()
        let positionStart = candidates.compactMap(\.openedDate).min()
        let start = min(transactionStart ?? positionStart ?? today, positionStart ?? transactionStart ?? today)
        let currencies = Set(candidates.flatMap { position in
            [position.currency, position.quoteCurrency, position.accountCurrency ?? ""]
        }.filter { !$0.isEmpty }.map(Self.marketCurrency))
        let symbols = currencies
            .filter { $0 != "USD" }
            .map(Self.yahooFXSymbol)
            .sorted()
        let histories = await marketData.historicalCloses(symbols: symbols, from: start, to: today)

        let transactionsByPosition = Dictionary(grouping: transactions) {
            "\($0.accountKey)|\($0.ticker.uppercased())"
        }
        return positions.map { position in
            if position.fxPnl != nil { return position }
            guard let accountCurrency = position.accountCurrency?.uppercased(),
                  !accountCurrency.isEmpty else {
                return position.withFXResult(
                    value: nil, currency: nil, status: "unavailable",
                    source: "missing_account_currency"
                )
            }

            if Self.marketCurrency(position.quoteCurrency) == Self.marketCurrency(accountCurrency) {
                return position.withFXResult(
                    value: 0, currency: "USD", status: "not_applicable",
                    source: "same_currency"
                )
            }

            let key = "\(position.accountKey)|\(position.ticker.uppercased())"
            let matchingTransactions = transactionsByPosition[key] ?? []
            var (lots, complete) = Self.remainingLots(from: matchingTransactions)
            let tolerance = max(0.0001, abs(position.shares) * 0.001)
            let reconstructedQuantity = lots.reduce(0) { $0 + $1.quantity }
            var status = "reconstructed"
            var source = "historical_daily_fx_fifo"

            if !complete || abs(reconstructedQuantity - position.shares) > tolerance {
                guard let openedDate = position.openedDate else {
                    return position.withFXResult(
                        value: nil, currency: nil, status: "unavailable",
                        source: matchingTransactions.isEmpty
                            ? "missing_trade_history"
                            : "incomplete_trade_history"
                    )
                }
                lots = [Lot(
                    quantity: position.shares,
                    date: openedDate,
                    currency: position.currency,
                    brokerFXRateToAccount: nil
                )]
                status = "estimated"
                source = "opened_date_daily_fx"
            }

            guard let currentInstrumentUSD = Self.usdPerUnit(
                currency: position.quoteCurrency,
                onOrBefore: today,
                histories: histories
            ), let currentAccountUSD = Self.usdPerUnit(
                currency: accountCurrency,
                onOrBefore: today,
                histories: histories
            ), currentAccountUSD > 0 else {
                return position.withFXResult(
                    value: nil, currency: nil, status: "unavailable",
                    source: "missing_current_fx_rate"
                )
            }

            var impactInAccountCurrency = 0.0
            var usedBrokerRate = false
            var usedMarketRate = false
            for lot in lots where lot.quantity > 0 {
                guard Self.marketCurrency(lot.currency) == Self.marketCurrency(position.quoteCurrency) else {
                    return position.withFXResult(
                        value: nil, currency: nil, status: "unavailable",
                        source: "trade_currency_mismatch"
                    )
                }
                let currentInstrumentToAccount = currentInstrumentUSD / currentAccountUSD
                let historicalInstrumentToAccount: Double
                if let brokerRate = lot.brokerFXRateToAccount,
                   brokerRate.isFinite, brokerRate > 0 {
                    // IBKR defines FX Rate to Base as base-currency units per
                    // asset-currency unit, which is exactly the ratio needed here.
                    historicalInstrumentToAccount = brokerRate
                    usedBrokerRate = true
                } else {
                    guard let historicalInstrumentUSD = Self.usdPerUnit(
                        currency: lot.currency,
                        onOrBefore: lot.date,
                        histories: histories
                    ), let historicalAccountUSD = Self.usdPerUnit(
                        currency: accountCurrency,
                        onOrBefore: lot.date,
                        histories: histories
                    ), historicalAccountUSD > 0 else {
                        return position.withFXResult(
                            value: nil, currency: nil, status: "unavailable",
                            source: "missing_historical_fx_rate"
                        )
                    }
                    historicalInstrumentToAccount = historicalInstrumentUSD / historicalAccountUSD
                    usedMarketRate = true
                }
                impactInAccountCurrency += lot.quantity * position.quotePrice
                    * (currentInstrumentToAccount - historicalInstrumentToAccount)
            }
            let impactUSD = impactInAccountCurrency * currentAccountUSD
            guard impactUSD.isFinite else {
                return position.withFXResult(
                    value: nil, currency: nil, status: "unavailable",
                    source: "invalid_fx_result"
                )
            }
            if status == "reconstructed", usedBrokerRate {
                source = usedMarketRate ? "broker_and_daily_fx_fifo" : "broker_trade_fx_fifo"
            }
            return position.withFXResult(
                value: impactUSD,
                currency: "USD",
                status: status,
                source: source
            )
        }
    }

    private static func remainingLots(
        from transactions: [LocalTransactionRecord]
    ) -> (lots: [Lot], complete: Bool) {
        var lots: [Lot] = []
        var complete = true
        for transaction in transactions.sorted(by: {
            if $0.date == $1.date { return ($0.tradeID ?? "") < ($1.tradeID ?? "") }
            return $0.date < $1.date
        }) {
            let quantity = abs(transaction.quantity)
            guard quantity > 0 else { continue }
            switch transaction.action.uppercased() {
            case "BUY":
                lots.append(Lot(
                    quantity: quantity,
                    date: transaction.date,
                    currency: transaction.currency,
                    brokerFXRateToAccount: transaction.brokerFXRate
                ))
            case "SELL":
                var remaining = quantity
                while remaining > 0.0000001, !lots.isEmpty {
                    let consumed = min(remaining, lots[0].quantity)
                    lots[0].quantity -= consumed
                    remaining -= consumed
                    if lots[0].quantity <= 0.0000001 { lots.removeFirst() }
                }
                if remaining > 0.0000001 { complete = false }
            default:
                continue
            }
        }
        return (lots, complete)
    }

    private static func marketCurrency(_ currency: String) -> String {
        currency.uppercased() == "GBX" ? "GBP" : currency.uppercased()
    }

    private static func yahooFXSymbol(_ currency: String) -> String {
        "\(currency.uppercased())USD=X"
    }

    private static func usdPerUnit(
        currency: String,
        onOrBefore date: String,
        histories: [String: [String: Double]]
    ) -> Double? {
        let original = currency.uppercased()
        let normalized = marketCurrency(original)
        if normalized == "USD" { return original == "GBX" ? 0.01 : 1 }
        let symbol = yahooFXSymbol(normalized)
        guard let value = histories[symbol]?
            .filter({ $0.key <= date })
            .max(by: { $0.key < $1.key })?
            .value,
              value.isFinite, value > 0 else { return nil }
        return original == "GBX" ? value / 100 : value
    }
}
