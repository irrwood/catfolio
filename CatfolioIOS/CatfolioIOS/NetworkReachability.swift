import Foundation
import Network
import Observation

/// Whether the phone has a network path right now. A pull to refresh without
/// one answers at once, instead of holding the page down while requests wait
/// for a connection that is not there.
@MainActor @Observable
final class NetworkReachability {
    static let shared = NetworkReachability()

    private(set) var hasPath = true
    @ObservationIgnored private let monitor = NWPathMonitor()

    var isOffline: Bool { !hasPath || SimulatedOffline.isEnabled }

    private init() {
        monitor.pathUpdateHandler = { path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in NetworkReachability.shared.hasPath = satisfied }
        }
        monitor.start(queue: DispatchQueue(label: "com.catfolio.ios.reachability"))
    }
}
