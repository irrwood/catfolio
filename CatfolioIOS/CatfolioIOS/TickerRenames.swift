import Foundation

/// Listings whose exchange code changed. Brokers keep reporting the old code,
/// Yahoo moves the whole history to the new one, and the bundled catalogs
/// were each generated under whichever code was current at the time — the
/// logo export knows `PHNX.L`, the company reference knows `SDLF.L`. Every
/// lookup keyed by ticker goes through `equivalents` so one company keeps
/// one price series, one logo and one catalog entry under either code.
enum TickerRenames {
    /// Former code → current code, both exchange-qualified.
    private static let current: [String: String] = [
        "PHNX.L": "SDLF.L",  // Phoenix Group Holdings → Standard Life plc, 2026
    ]

    private static let former: [String: [String]] = Dictionary(
        grouping: current.keys, by: { current[$0]! })

    /// The code market data is published under today.
    static func currentSymbol(for symbol: String) -> String {
        let key = normalized(symbol)
        return current[key] ?? key
    }

    /// The symbol itself first, then its current code, then former codes.
    static func equivalents(of symbol: String) -> [String] {
        let key = normalized(symbol)
        let now = current[key] ?? key
        return ([key, now] + (former[now] ?? [])).reduce(into: []) { result, code in
            if !result.contains(code) { result.append(code) }
        }
    }

    private static func normalized(_ symbol: String) -> String {
        symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }
}
