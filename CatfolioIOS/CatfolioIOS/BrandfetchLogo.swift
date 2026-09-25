import SwiftUI
import WebKit

enum BrandfetchLogoURL {
    // Logo API client IDs are public identifiers included in each image URL.
    static let clientID = "1idSx9hVGNTVGELIzRe"

    /// Nil for symbols Brandfetch recently answered with no logo. `dark`
    /// asks for the brand's icon made for dark backgrounds; that is nil too
    /// once Brandfetch has answered it has none, so the caller falls back to
    /// the default icon.
    static func icon(for symbol: String, dark: Bool = false) -> URL? {
        let ticker = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !ticker.isEmpty, ticker != "ETF 其他",
              ticker.range(of: "^[A-Z0-9][A-Z0-9._^-]*$", options: .regularExpression) != nil,
              !BrandfetchMissCache.shared.isMissing(ticker),
              !dark || !BrandfetchMissCache.shared.isMissing(darkMissKey(ticker)) else {
            return nil
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "cdn.brandfetch.io"
        // With fallback/404 a brand that has no dark icon answers 404, not a
        // placeholder; the dark miss is then recorded under its own key.
        components.path = "/ticker/\(ticker)/w/96/h/96\(dark ? "/theme/dark" : "")/fallback/404/icon.png"
        components.queryItems = [URLQueryItem(name: "c", value: clientID)]
        return components.url
    }

    /// The miss-cache key for "no dark icon", separate from "no logo at all".
    static func darkMissKey(_ symbol: String) -> String {
        symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() + "@DARK"
    }

    static func isDark(_ url: URL) -> Bool { url.path.contains("/theme/dark/") }
}

/// Brandfetch requires logos to be hotlinked from an HTML image element and
/// not stored by the app. Every image is still requested from their CDN; the
/// web views share one persistent data store of their own, so WebKit's normal
/// HTTP cache may reuse a response for as long as the CDN's cache headers allow
/// (and not at all if they forbid it). The app itself never saves the image.
struct BrandfetchLogoImage: UIViewRepresentable {
    let url: URL
    let onLoad: () -> Void
    var onMissing: () -> Void = {}

    // Fixed identifier: the same store across launches, apart from any other
    // web content in the app.
    private static let dataStore = WKWebsiteDataStore(
        forIdentifier: UUID(uuidString: "6B1C2F0E-8F4A-4C8E-9C1D-3A5E7B9D2F14")!)

    func makeCoordinator() -> Coordinator { Coordinator(onLoad: onLoad, onMissing: onMissing) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = Self.dataStore
        configuration.userContentController.add(context.coordinator, name: "logoLoaded")
        configuration.userContentController.add(context.coordinator, name: "logoMissing")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.onLoad = onLoad
        context.coordinator.onMissing = onMissing
        guard context.coordinator.currentURL != url else { return }
        context.coordinator.currentURL = url
        context.coordinator.retriedAfterTermination = false
        let source = url.absoluteString.replacingOccurrences(of: "&", with: "&amp;")
        // `onerror` also fires offline; only a failure while online counts as
        // "Brandfetch has no logo" (the URL asks for a 404 in that case).
        let html = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <meta name="referrer" content="origin"><style>
        html,body{margin:0;width:100%;height:100%;background:transparent;overflow:hidden}
        img{display:block;width:100%;height:100%;object-fit:contain}
        </style></head><body><img src="\(source)" onload="window.webkit.messageHandlers.logoLoaded.postMessage(this.src)" onerror="if(navigator.onLine)window.webkit.messageHandlers.logoMissing.postMessage(this.src)"></body></html>
        """
        view.loadHTMLString(html, baseURL: URL(string: "https://catfolio-app.vercel.app/"))
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        // The content controller retains its handlers; release the coordinator.
        view.configuration.userContentController.removeAllScriptMessageHandlers()
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var currentURL: URL?
        var retriedAfterTermination = false
        var onLoad: () -> Void
        var onMissing: () -> Void

        init(onLoad: @escaping () -> Void, onMissing: @escaping () -> Void) {
            self.onLoad = onLoad
            self.onMissing = onMissing
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let source = message.body as? String,
                  source == currentURL?.absoluteString else { return }
            switch message.name {
            case "logoLoaded": onLoad()
            case "logoMissing": onMissing()
            default: break
            }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            guard !retriedAfterTermination else { return }
            retriedAfterTermination = true
            webView.reload()
        }
    }
}
