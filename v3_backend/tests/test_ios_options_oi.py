from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2] / "CatfolioIOS/CatfolioIOS"


def test_oi_distribution():
    source = (ROOT / "OptionsOIView.swift").read_text()
    model = source.split("struct OIContract:", 1)[1].split("actor OptionsOIClient", 1)[0]
    script = 'import Foundation\nenum L10n { static func text(_ value: String) -> String { value } }\nstruct OIContract:' + model + r'''
func contract(_ id: String, _ strike: Double, _ side: String, _ oi: Double) -> OIContract {
    OIContract(details: .init(ticker: id, contract_type: side, expiration_date: "2026-10-01",
        strike_price: strike, shares_per_contract: 100), open_interest: oi)
}
let a = contract("a", 90, "call", 20)
let input = [a, a, contract("b", 100, "call", 20), contract("c", 90, "put", 60)]
let result = OIDistribution(contracts: input)
precondition(result.rows.count == 2)
precondition(result.rows[0].call == 20)
precondition(result.callWalls.map(\.strike) == [90, 100])
precondition(result.putWalls.map(\.strike) == [90])
precondition(result.concentration == 90...100)
let empty = OIDistribution(contracts: [])
precondition(empty.callWalls.isEmpty && empty.putWalls.isEmpty && empty.concentration == nil)
let zero = OIDistribution(contracts: [contract("z", 100, "call", 0)])
precondition(zero.callWalls.isEmpty && zero.concentration == nil)
let invalid = OIDistribution(contracts: [contract("n", 100, "call", .nan), contract("p", -1, "put", 2)])
precondition(invalid.rows.isEmpty)
let concentrated = OIDistribution(contracts: [contract("s", 100, "put", 20)])
precondition(concentrated.concentration == 100...100 && concentrated.callWalls.isEmpty)
let visual = OIPlotGeometry(result, markers: [91, 120, .nan])
precondition(visual.maximum == 60)
precondition(visual.nearest(to: -100)?.strike == 90)
precondition(visual.nearest(to: 1000)?.strike == 100)
precondition(visual.nearest(to: 96)?.call == 20)
precondition(visual.nearest(to: .nan) == nil)
precondition(visual.segments(for: .put).count == 1)
precondition(visual.segments(for: .put)[0].filter { $0.width > 0 }.map(\.strike) == [90])
precondition(visual.segments(for: .call)[0].filter { $0.width > 0 }.allSatisfy { $0.width == 1.0 / 3 })
let sparse = OIDistribution(contracts: [contract("s1", 10, "put", 10), contract("s2", 11, "put", 0),
    contract("s3", 12, "call", 20), contract("s4", 13, "put", 30), contract("s5", 30, "put", 40)])
let sparseGeometry = OIPlotGeometry(sparse)
let segments = sparseGeometry.segments(for: .put)
precondition(segments.count == 3) // absent Put at 12 and the 13–30 data gap
precondition(segments[0].contains { $0.strike == 11 && $0.width == 0 }) // true zero retained
precondition(segments[1].last!.strike < segments[2].first!.strike)
precondition(segments.flatMap { $0 }.allSatisfy { (0...1).contains($0.width) })
precondition(sparse.putWalls.map(\.strike) == [30] && sparse.callWalls.map(\.strike) == [12])
for segment in segments {
    let slopes = OIPlotGeometry.edgeSlopes(segment)
    precondition(slopes.count == segment.count && slopes.allSatisfy(\.isFinite))
    for i in 0..<(segment.count - 1) {
        let a = segment[i], b = segment[i + 1]
        let gap = (b.strike - a.strike) / 3
        let c1 = a.width + slopes[i] * gap, c2 = b.width - slopes[i + 1] * gap
        let bounds = (min(a.width, b.width) - 1e-12)...(max(a.width, b.width) + 1e-12)
        precondition(bounds.contains(c1) && bounds.contains(c2))
    }
}
let smooth = OIPlotGeometry.edgeSlopes([.init(strike: 1, width: 0), .init(strike: 2, width: 0.4),
 .init(strike: 3, width: 1), .init(strike: 4, width: 0.5), .init(strike: 5, width: 0)])
precondition(smooth[1] > 0 && smooth[2] == 0 && smooth[3] < 0) // no artificial feet between monotone samples
var focusRows: [OIContract] = []
for i in 0..<100 {
    let side = i % 2 == 0 ? "put" : "call"
    let oi: Double = i >= 40 && i <= 60 ? 100 : 1
    focusRows.append(contract("f\(i)", Double(i + 1), side, oi))
}
let focusDistribution = OIDistribution(contracts: focusRows)
let focused = OIPlotGeometry(focusDistribution, range: .main)
let full = OIPlotGeometry(focusDistribution, range: .all)
precondition(focused.domain.lowerBound > full.domain.lowerBound && focused.domain.upperBound < full.domain.upperBound)
precondition(focused.maximum == full.maximum)
precondition(focused.outsideFraction > 0 && full.outsideFraction == 0)
precondition(focused.visibleRows.count < full.visibleRows.count)
precondition(focused.nearest(to: -100)?.strike == focused.visibleRows.first?.strike)
precondition(focused.nearest(to: 1e9)?.strike == focused.visibleRows.last?.strike)
precondition((focusDistribution.callWalls + focusDistribution.putWalls).allSatisfy { focused.domain.contains($0.strike) })
let remote = OIPlotGeometry(focusDistribution, range: .main, currentPrice: 1e8)
precondition(remote.domain == focused.domain)
let adjacent = OIPlotGeometry(focusDistribution, range: .main, currentPrice: focused.domain.upperBound)
precondition(adjacent.domain.contains(focused.domain.upperBound))
precondition(OIPriceLabel.text(10.5, locale: Locale(identifier: "en_US")) == "$10.5")
precondition(OIPriceLabel.text(10.4, locale: Locale(identifier: "zh_Hans")) == "$10.4")
let closeStrikes = OIDistribution(contracts: [contract("fraction1", 10.1, "put", 20), contract("fraction2", 10.2, "call", 20)])
let closeGeometry = OIPlotGeometry(closeStrikes, range: .main)
precondition(closeGeometry.rows.count == 2 && closeGeometry.nearest(to: 10.2)?.strike == 10.2)
precondition(OIPriceLabel.text(10.1, locale: .current) != OIPriceLabel.text(10.2, locale: .current))
let singleGeometry = OIPlotGeometry(concentrated)
precondition(singleGeometry.domain.contains(100) && singleGeometry.domain.upperBound > singleGeometry.domain.lowerBound)
precondition(singleGeometry.segments(for: .call).isEmpty)
precondition(OIPlotGeometry(empty).nearest(to: 0) == nil)
for ys in [[0.0, 0, 1, 2, 3], [250.0, 250, 250, 250, 250], [100, 110, 120]] {
    let positions = OIPlotGeometry.labelPositions(ys, height: 250)
    precondition(positions.first! >= 14 && positions.last! <= 236)
    precondition(zip(positions, positions.dropFirst()).allSatisfy { $1 - $0 >= 28 })
}
print("PASS: aggregation, duplicate fills, tied walls, equal-tail range, empty/zero/missing side, invalid numbers")
'''
    script = script.replace('\\\\.strike', '\\.strike')
    subprocess.run(["swift", "-"], input=script, text=True, check=True)


def test_oi_complete_chain_and_vp_template():
    source = (ROOT / "OptionsOIView.swift").read_text()
    vp = (ROOT / "VolumeProfileView.swift").read_text()
    assert 'for timestamp in expirations' in source
    assert 'query2.finance.yahoo.com/v7/finance/options/' in source
    assert 'expirations.count <= 100' in source
    assert 'item.contractSize == "REGULAR"' in source
    assert 'options-oi-yahoo-v1-' in source
    assert 'rateLimitedUntil' in source
    assert 'let shouldRefresh = refreshID != handledRefreshID' in source
    assert 'handledRefreshID = refreshID' in source
    assert 'guard shouldRefresh else { return }' in source
    assert 'guard refreshID > 0' not in source
    assert '.applicationSupportDirectory' in source
    assert 'Massive' not in source
    assert 'oi.rounded() == oi' in source
    assert 'OptionsOIView(symbol: holding.ticker' in vp
    assert 'PriceDistributionSection(title: L10n.text("Volume Profile")' in vp
    assert 'PriceDistributionSection(title: L10n.text("期权持仓墙")' in source
    assert '波动倾向' not in source
    assert 'range: plotRange, currentPrice: price' in source
    assert '.onChange(of: plotRange) { _, _ in selectedStrike = nil }' in source
    assert '.frame(height: 400)' in source
    assert 'Text(" "' not in source
    assert '行权价 USD' not in source
    assert '.currency(code:' not in source
    assert 'geometry.visibleRows' in source
    assert 'clamped: false' in source
    assert '查看全部并列价位' in source


def test_yahoo_transport_and_cache():
    source = (ROOT / "OptionsOIView.swift").read_text().split("struct OptionsOIView: View", 1)[0]
    source = source.replace("import SwiftUI", "import Foundation").replace("import Charts", "")
    script = source + '\nenum L10n { static func text(_ value: String) -> String { value } }\n' + r'''
enum LocalServiceError: LocalizedError {
    case remote(String), invalidResponse
    var errorDescription: String? {
        switch self { case .remote(let text): return text; case .invalidResponse: return "invalid" }
    }
}
final class YahooStub: URLProtocol {
    static var mode = "ok"
    static var requested: [URL] = []
    static let first = Int(Calendar(identifier: .gregorian).startOfDay(for: Date()).timeIntervalSince1970) + 86400
    static let second = first + 2 * 86400
    static let distant = first + 120 * 86400
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    static func contract(_ expiry: Int, side: String, strike: Int, oi: Any) -> [String: Any] {
        let code = String(YahooOIResponse.expiryDay(expiry).replacingOccurrences(of: "-", with: "").suffix(6))
        return ["contractSymbol": "TEST" + code + side + String(format: "%08d", strike * 1000),
                "strike": strike, "expiration": expiry, "openInterest": oi,
                "contractSize": "REGULAR", "currency": "USD"]
    }
    override func startLoading() {
        let url = request.url!
        Self.requested.append(url)
        precondition(request.value(forHTTPHeaderField: "Authorization") == nil)
        var code = 200
        var bytes = Data()
        if Self.mode == "limited" {
            code = 429
        } else if url.host == "fc.yahoo.com" {
            code = 404
        } else if url.path.contains("getcrumb") {
            bytes = Data("fixture-crumb".utf8)
        } else {
            let dateQuery = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "date" }?.value
            let expiry = dateQuery.flatMap(Int.init) ?? Self.first
            let oi: Any = Self.mode == "missing" && expiry == Self.second ? NSNull() : 20
            var options: [[String: Any]] = [[
                "expirationDate": expiry,
                "calls": [Self.contract(expiry, side: "C", strike: 100, oi: oi)],
                "puts": [Self.contract(expiry, side: "P", strike: 90, oi: 30)]
            ]]
            if Self.mode == "wrongExpiry" && expiry == Self.second { options = [] }
            let payload: [String: Any] = ["optionChain": ["error": NSNull(), "result": [[
                "underlyingSymbol": "TEST",
                "expirationDates": [Self.first, Self.second, Self.distant],
                "options": options
            ]]]]
            bytes = try! JSONSerialization.data(withJSONObject: payload)
        }
        let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: ["Retry-After": "600"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: bytes)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
// Yahoo's expiry date must not move to the previous day in New York.
precondition(YahooOIResponse.expiryDay(1788912000) == "2026-09-09")
let malformed = YahooOIResponse.Contract(contractSymbol: "TEST260910C00100000",
    strike: 100, expiration: 1788912000, openInterest: 5, contractSize: "REGULAR", currency: "USD")
do {
    _ = try YahooOIResponse.normalize(.init(expirationDate: 1788912000, calls: [malformed], puts: []), symbol: "TEST")
    fatalError("Wrong contract expiry accepted")
} catch {}
let configuration = URLSessionConfiguration.ephemeral
configuration.protocolClasses = [YahooStub.self]
let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: folder) }
let client = OptionsOIClient(session: URLSession(configuration: configuration), cacheDirectory: folder)
let snapshot = try await client.fetch(symbol: "TEST", days: 7)
precondition(snapshot.contracts.count == 4)
precondition(Set(snapshot.contracts.map { $0.details.expiration_date }).count == 2)
precondition(YahooStub.requested.count == 4) // cookie, crumb, inventory/first expiry, second expiry
let cached = await client.cached(symbol: "TEST", days: 7)
precondition(cached?.fetchedAt == snapshot.fetchedAt)
let cachedRequestCount = YahooStub.requested.count
let reopened = OptionsOIClient(session: URLSession(configuration: configuration), cacheDirectory: folder)
for _ in 0..<3 {
    let restored = await reopened.cached(symbol: "TEST", days: 7)
    precondition(restored?.fetchedAt == snapshot.fetchedAt)
}
let otherRange = await reopened.cached(symbol: "TEST", days: 90)
precondition(otherRange == nil)
precondition(YahooStub.requested.count == cachedRequestCount)
for mode in ["missing", "wrongExpiry"] {
    YahooStub.mode = mode
    do { _ = try await client.fetch(symbol: "TEST", days: 7); fatalError("Partial chain accepted") } catch {}
    let preserved = await client.cached(symbol: "TEST", days: 7)
    precondition(preserved?.fetchedAt == snapshot.fetchedAt)
}
YahooStub.mode = "limited"
do { _ = try await client.fetch(symbol: "TEST", days: 7); fatalError("429 accepted") } catch {}
let count = YahooStub.requested.count
do { _ = try await client.fetch(symbol: "TEST", days: 7); fatalError("Cooldown ignored") } catch {}
precondition(YahooStub.requested.count == count)
let preserved = await client.cached(symbol: "TEST", days: 7)
precondition(preserved?.fetchedAt == snapshot.fetchedAt)
print("PASS: Yahoo multi-expiry, UTC dates, identity, missing OI/expiry, atomic cache, 429 cooldown, no API key")
'''
    subprocess.run(["swift", "-"], input=script, text=True, check=True)


if __name__ == "__main__":
    test_oi_distribution()
    test_oi_complete_chain_and_vp_template()
    test_yahoo_transport_and_cache()
    print("PASS: complete chain safeguards and shared VP section")
