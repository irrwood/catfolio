import Foundation

/// Debug builds only: market requests fail as a phone without a connection
/// would, so the offline home can be looked at in the simulator, which always
/// shares the Mac's network. On from launch with `--simulate-offline`, or
/// switched while the app runs:
/// `xcrun simctl spawn booted defaults write com.catfolio.ios catfolio.debug.offline -bool YES`
/// `catfolio.debug.slowNetwork` instead holds every request 30 seconds before
/// it fails, as a connection that is there but not getting through would.
enum SimulatedOffline {
    static var isEnabled: Bool {
        #if DEBUG
        LaunchArguments.contains("--simulate-offline")
            || UserDefaults.standard.bool(forKey: "catfolio.debug.offline")
        #else
        false
        #endif
    }

    static var isSlow: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "catfolio.debug.slowNetwork")
        #else
        false
        #endif
    }

    /// For `URLSession.shared`; sessions with their own configuration use
    /// `URLSessionConfiguration.simulatingOffline()`.
    static func install() {
        #if DEBUG
        URLProtocol.registerClass(FailingProtocol.self)
        #endif
    }

    final class FailingProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool {
            SimulatedOffline.isEnabled || SimulatedOffline.isSlow
        }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let delay: TimeInterval = SimulatedOffline.isEnabled ? 0 : 30
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
                client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            }
        }
        override func stopLoading() {}
    }
}

extension URLSessionConfiguration {
    func simulatingOffline() -> URLSessionConfiguration {
        #if DEBUG
        protocolClasses = [SimulatedOffline.FailingProtocol.self] + (protocolClasses ?? [])
        #endif
        return self
    }
}
