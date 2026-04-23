import Foundation
import Network
import Combine

/// Passive monitor for network reachability. Drives the "when offline,
/// auto-fall-back to local Whisper" behavior in `PipelineCoordinator`.
///
/// Uses `NWPathMonitor`, which Apple designed as the modern reachability
/// API (SCNetworkReachability is effectively deprecated). Status updates
/// arrive on a background queue; we republish on the main actor so
/// SwiftUI views can observe without crossing isolation boundaries.
///
/// We deliberately do NOT use `.requiresConnection` heuristics or hit
/// any URL to test — that would either cost latency on every hotkey
/// press, or leak metadata about dictation timing to a probe host.
@MainActor
final class NetworkReachability: ObservableObject {

    static let shared = NetworkReachability()

    /// True when the OS believes there's a usable internet path.
    /// `.satisfied` covers Wi-Fi + wired + cellular + VPN.
    @Published private(set) var isReachable: Bool = true

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.niconuscheler.sprich.netmonitor")

    private init() {
        // Seed with the current path so startup doesn't briefly claim
        // offline before the first pathUpdateHandler fires.
        let initial = monitor.currentPath.status == .satisfied
        self.isReachable = initial

        monitor.pathUpdateHandler = { [weak self] path in
            let reachable = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.isReachable != reachable {
                    self.isReachable = reachable
                    #if DEBUG
                    print("[Sprich] Network reachable: \(reachable)")
                    #endif
                }
            }
        }
        monitor.start(queue: queue)
    }
}
