import Foundation

/// Daily GBP reference rates, for valuing a foreign-currency position in
/// sterling on the day it was bought.
///
/// Rates read `1 GBP = rate units of the quote currency`, so a foreign amount
/// becomes sterling by dividing. The package states that direction itself
/// rather than leaving it to be inferred from a field name, and this reader
/// refuses to load one that states anything else — getting the direction
/// backwards is the kind of mistake that produces plausible numbers.
struct GBPFXRates: Decodable, Sendable {
    /// How close the rate is to the day that was asked for.
    enum Match: Sendable {
        /// The ECB published a rate on exactly that date.
        case exact
        /// The date had no observation — a weekend, a holiday — and this is
        /// the most recent published rate before it, `daysBack` days earlier.
        case carriedForward(daysBack: Int)
    }

    struct Quote: Sendable {
        let rate: Double
        let match: Match
        let date: String
    }

    let schemaVersion: Int
    let baseCurrency: String
    let direction: String
    let nonObservationDayPolicy: String
    let lookupPolicy: String
    let status: String
    let source: String
    /// Currencies the package names but has no series for. Kept so a caller
    /// can tell "no rate exists" from "this currency was never covered".
    let unsupportedCurrencies: [String]
    /// One shared axis, ascending. Every series is parallel to it.
    let dates: [String]
    /// Currency to rate per date; nil where that currency has no observation
    /// on that date, which is preserved rather than filled.
    let rates: [String: [Double?]]

    private var indexByDate: [String: Int] = [:]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, baseCurrency, direction, nonObservationDayPolicy
        case lookupPolicy, status, source, unsupportedCurrencies, dates, rates
    }

    enum RatesError: Error { case missingResource, invalidPackage }

    static let bundled = Result { try load() }

    static func load(bundle: Bundle = .main) throws -> Self {
        guard let url = bundle.url(forResource: "gbp_fx_daily", withExtension: "json") else {
            throw RatesError.missingResource
        }
        return try decode(Data(contentsOf: url))
    }

    static func decode(_ data: Data) throws -> Self {
        var package = try JSONDecoder().decode(Self.self, from: data)
        package.indexByDate = Dictionary(
            uniqueKeysWithValues: package.dates.enumerated().map { ($0.element, $0.offset) }
        )
        guard package.schemaVersion == 1,
              package.baseCurrency == "GBP",
              package.direction.hasPrefix("GBP_TO_QUOTE"),
              package.nonObservationDayPolicy == "OMIT_NO_FORWARD_FILL",
              package.status == "VERIFIED",
              !package.dates.isEmpty,
              package.dates == package.dates.sorted(),
              package.rates.values.allSatisfy({ $0.count == package.dates.count })
        else { throw RatesError.invalidPackage }
        return package
    }

    /// The rate to use for a currency on a given day.
    ///
    /// Sterling is 1 by definition and pence is a hundredth of it; neither is
    /// in the series and neither needs to be.
    ///
    /// The package omits non-observation days rather than filling them, which
    /// is the right thing for a rate series to do and the wrong thing for a
    /// caller to inherit: a contract note dated on a Saturday still has to be
    /// valued. So a missing day walks backwards to the most recent published
    /// rate, up to `limit` days, and says how far it had to go. It never
    /// walks forward — a rate published after the trade was not knowable at
    /// the time.
    func quote(currency: String, on date: String, within limit: Int = 7) -> Quote? {
        let code = currency.uppercased()
        if code == "GBP" { return Quote(rate: 1, match: .exact, date: date) }
        if code == "GBX" || code == "GBp" { return Quote(rate: 100, match: .exact, date: date) }

        guard let series = rates[code] else { return nil }

        // An exact hit is the common case: markets trade on the days the ECB
        // publishes on.
        if let position = indexByDate[date], let rate = series[position] {
            return Quote(rate: rate, match: .exact, date: date)
        }

        // Otherwise find where the date would sit and step back from there.
        var position = dates.firstIndex { $0 > date } ?? dates.count
        var stepped = 0
        while position > 0, stepped <= limit {
            position -= 1
            stepped += 1
            if let rate = series[position] {
                return Quote(
                    rate: rate,
                    match: .carriedForward(daysBack: stepped),
                    date: dates[position]
                )
            }
        }
        return nil
    }

    /// A foreign amount in sterling on a given day.
    func sterling(_ amount: Double, currency: String, on date: String) -> (value: Double, match: Match)? {
        guard let quote = quote(currency: currency, on: date), quote.rate > 0 else { return nil }
        return (amount / quote.rate, quote.match)
    }

    /// The most recent day the package has a rate for this currency.
    func latestDate(currency: String) -> String? {
        let code = currency.uppercased()
        if code == "GBP" || code == "GBX" { return dates.last }
        guard let series = rates[code] else { return nil }
        for index in stride(from: series.count - 1, through: 0, by: -1) where series[index] != nil {
            return dates[index]
        }
        return nil
    }
}
