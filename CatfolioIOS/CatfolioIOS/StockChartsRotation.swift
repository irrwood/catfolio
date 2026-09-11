import Foundation
import Observation
import WebKit

/// The public chart's observations, preserved without Catfolio v2 normalisation.
struct StockChartsRRGResponse: Codable {
    struct Company: Codable, Identifiable {
        let symbol: String
        let name: String
        var id: String { symbol }
    }
    struct Value: Codable {
        let price: Double
        let jdkratio: Double
        let jdkmom: Double
        var quadrant: String {
            jdkratio >= 100 ? (jdkmom >= 100 ? "leading" : "weakening") : (jdkmom >= 100 ? "improving" : "lagging")
        }
    }
    struct Week: Codable, Identifiable {
        let start: String
        let end: String
        let benchmark: Double
        let rrgdata: [String: Value]
        var id: String { end }
        var date: String { String(end.prefix(10)) }
        enum CodingKeys: String, CodingKey { case start, end, benchmark = "$SPX", rrgdata }
    }
    let message: String
    let period: String
    let companies: [Company]
    let rrgdata: [Week]
    static let symbols = ["$INDU", "$COMPQ", "$NYA", "$XAX", "$TSX", "$CDNX"]
    static let sourceURL = URL(string: "https://stockcharts.com/freecharts/rrg/?tailLength=30")!
    static let loadURL = sourceURL

    static func decode(_ data: Data) throws -> Self {
        let result = try JSONDecoder().decode(Self.self, from: data)
        let symbols = Set(Self.symbols)
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.timeZone = TimeZone(identifier: "America/New_York")
        date.dateFormat = "yyyy-MM-dd HH:mm:ss"
        date.isLenient = false
        func validDate(_ value: String) -> Bool {
            date.date(from: value).map { date.string(from: $0) == value } ?? false
        }
        guard result.message == "success", result.period == "W",
              result.companies.count == 7,
              Set(result.companies.map(\.symbol)) == symbols.union(["$SPX"]),
              result.rrgdata.count >= 31, result.rrgdata.count <= 600,
              result.rrgdata.map(\.end) == result.rrgdata.map(\.end).sorted(),
              Set(result.rrgdata.map(\.start)).count == result.rrgdata.count,
              Set(result.rrgdata.map(\.end)).count == result.rrgdata.count,
              result.rrgdata.allSatisfy({ week in
                  validDate(week.start) && validDate(week.end) && week.start <= week.end &&
                  week.benchmark.isFinite && week.benchmark > 0 && Set(week.rrgdata.keys) == symbols &&
                  week.rrgdata.values.allSatisfy { value in
                      value.price.isFinite && value.price > 0 && value.jdkratio.isFinite && value.jdkratio > 0 &&
                      value.jdkmom.isFinite && value.jdkmom > 0
                  }
              }) else { throw CocoaError(.fileReadCorruptFile) }
        return result
    }

    /// Tail length counts intervals: 30 weeks means 31 observations, including now.
    func trail(endingAt index: Int, length: Int = 30) -> [Week] {
        guard rrgdata.indices.contains(index) else { return [] }
        return Array(rrgdata[max(0, index - max(0, length))...index])
    }

    func name(_ symbol: String) -> String {
        guard AppLanguage.currentIdentifier != "en" else { return companies.first { $0.symbol == symbol }?.name ?? symbol }
        switch symbol {
        case "$INDU": return "道琼斯工业指数"
        case "$COMPQ": return "纳斯达克综合指数"
        case "$NYA": return "NYSE 综合指数"
        case "$XAX": return "AMEX 综合指数"
        case "$TSX": return "TSX 综合指数"
        case "$CDNX": return "TSX 创业板指数"
        default: return "S&P 500"
        }
    }
}

struct StockChartsRRGCapture: Codable {
    let capturedAt: String
    let response: StockChartsRRGResponse
    static func decode(_ data: Data) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: data)
        _ = try StockChartsRRGResponse.decode(JSONEncoder().encode(value.response))
        guard ISO8601DateFormatter().date(from: value.capturedAt) != nil else { throw CocoaError(.fileReadCorruptFile) }
        return value
    }
}

/// Loads the public page normally and reads the data that page receives. No private
/// API credential, copied authentication token, or estimated JdK formula is used.
@MainActor @Observable
final class StockChartsRRGStore: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private(set) var capture: StockChartsRRGCapture?
    private(set) var isLoading = false
    private(set) var failed = false
    private(set) var webView: WKWebView?
    @ObservationIgnored private var timeout: Task<Void, Never>?
    @ObservationIgnored private let cacheURL: URL

    init(cacheURL: URL? = nil) {
        self.cacheURL = cacheURL ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("stockcharts-rrg-reference.json")
        super.init()
        let local = [Bundle.main.url(forResource: "stockcharts_rrg_reference", withExtension: "json"), self.cacheURL]
            .compactMap { $0 }.compactMap { try? StockChartsRRGCapture.decode(Data(contentsOf: $0)) }
        capture = local.max { ($0.response.rrgdata.last?.end ?? "") < ($1.response.rrgdata.last?.end ?? "") }
    }

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        failed = false
        let controller = WKUserContentController()
        controller.add(self, name: "rrgObservation")
        controller.addUserScript(WKUserScript(source: Self.observerScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController = controller
        let browser = WKWebView(frame: .zero, configuration: config)
        browser.navigationDelegate = self
        webView = browser
        browser.load(URLRequest(url: StockChartsRRGResponse.loadURL))
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            self?.failed = true
            self?.cancel()
        }
    }

    func accept(_ data: Data, now: Date = Date()) throws {
        let response = try StockChartsRRGResponse.decode(data)
        guard let newest = response.rrgdata.last?.end,
              newest >= (capture?.response.rrgdata.last?.end ?? "") else { throw CocoaError(.fileReadCorruptFile) }
        let value = StockChartsRRGCapture(capturedAt: ISO8601DateFormatter().string(from: now), response: response)
        capture = value
        failed = false
        try? JSONEncoder().encode(value).write(to: cacheURL, options: .atomic)
    }

    func cancel() {
        timeout?.cancel(); timeout = nil
        webView?.stopLoading()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "rrgObservation")
        webView?.navigationDelegate = nil
        webView = nil
        isLoading = false
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.host == "stockcharts.com",
              let body = message.body as? String, let data = body.data(using: .utf8), data.count < 2_000_000 else { return }
        do { try accept(data); cancel() }
        catch { failed = true; cancel() }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failed = true; cancel()
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed = true; cancel()
    }

    private static let observerScript = #"""
    (() => {
      const accepts = input => {
        try {
          const u = new URL(input, location.href);
          return u.origin === 'https://stockcharts.com' && u.pathname === '/d-rrg/rrg'
            && u.searchParams.get('cmd') === 'getrrgdata2'
            && u.searchParams.get('b') === '$SPX' && u.searchParams.get('p') === 'w';
        } catch (_) { return false; }
      };
      const send = body => {
        if (typeof body === 'string' && body.length < 2000000)
          window.webkit.messageHandlers.rrgObservation.postMessage(body);
      };
      const open = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function(method, url) {
        if (accepts(url)) this.addEventListener('load', () => {
          if (this.status === 200) send(this.responseType === 'json' ? JSON.stringify(this.response) : this.responseText);
        }, {once: true});
        return open.apply(this, arguments);
      };
      const fetch = window.fetch;
      window.fetch = function(input) {
        const result = fetch.apply(this, arguments);
        if (accepts(typeof input === 'string' ? input : input.url))
          result.then(r => { if (r.ok) r.clone().text().then(send); }).catch(() => {});
        return result;
      };
    })();
    """#
}
