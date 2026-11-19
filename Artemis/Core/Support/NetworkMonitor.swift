import Network
import Observation

/// Whether the device has an internet connection; without one, cloud models can't be reached.
@MainActor
@Observable
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    private(set) var isOnline = true

    private init() {
        Task {
            for await path in NWPathMonitor() {
                isOnline = path.status == .satisfied
            }
        }
    }
}
