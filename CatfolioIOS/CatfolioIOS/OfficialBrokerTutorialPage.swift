import SwiftUI
import WebKit

/// Official documentation is pushed on the connection's existing navigation stack.
struct OfficialBrokerTutorialPage: View {
    let url: URL
    @State private var isLoading = true
    @State private var failed = false

    var body: some View {
        BrokerTutorialWebView(url: url, isLoading: $isLoading, failed: $failed)
            .overlay {
                if failed {
                    ContentUnavailableView {
                        Label(L10n.text("无法加载教程"), systemImage: "wifi.exclamationmark")
                    } actions: {
                        Link(L10n.text("在浏览器中打开"), destination: url)
                    }
                    .background(Color(uiColor: .systemBackground))
                } else if isLoading {
                    ProgressView()
                }
            }
            .navigationTitle(L10n.text("教程"))
            .navigationBarTitleDisplayMode(.inline)
            .adaptiveNavigationBackground()
            .tint(CatfolioTheme.primaryText)
    }
}

private struct BrokerTutorialWebView: UIViewRepresentable {
    let url: URL
    @Binding var isLoading: Bool
    @Binding var failed: Bool

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.accessibilityIdentifier = "official-broker-tutorial"
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.stopLoading()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: BrokerTutorialWebView
        init(parent: BrokerTutorialWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.failed = false
            parent.isLoading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            finishWithError(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            finishWithError(error)
        }

        private func finishWithError(_ error: Error) {
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            parent.isLoading = false
            parent.failed = true
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
            return nil
        }
    }
}
