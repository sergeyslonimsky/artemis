import Foundation

/// Where a reply is generated.
enum BackendKind: String, Codable, Sendable {
    case onDevice = "on_device"
    case cloud
}

/// How a chat picks its backend.
enum RoutingMode: String, Codable, Sendable, CaseIterable {
    /// On-device first, escalating to the cloud when needed.
    case auto
    case onDevice = "on_device"
    case cloud
}

/// Whether automatic escalation (Auto mode) may send a request to a cloud provider.
/// Explicit user actions (Cloud mode, "Ask cloud") count as consent and are not affected.
enum CloudPolicy: String, Codable, Sendable, CaseIterable {
    case deny
    case alwaysAsk = "always_ask"
    case alwaysAllow = "always_allow"
}
