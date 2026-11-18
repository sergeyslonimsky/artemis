import Foundation
import Security
import Synchronization

/// Stores provider API keys outside of the SQLite database.
protocol APIKeyStore: Sendable {
    func apiKey(for providerId: String) -> String?
    func setAPIKey(_ key: String, for providerId: String) throws
    func deleteAPIKey(for providerId: String) throws
}

enum APIKeyStoreError: LocalizedError {
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
            return "Keychain error \(status): \(message)"
        }
    }
}

/// Keychain-backed store. Keys are device-only (excluded from backups) and readable after
/// the first unlock so streaming can continue in the background.
struct KeychainAPIKeyStore: APIKeyStore {
    private let service: String

    init(service: String = Bundle.main.bundleIdentifier.map { "\($0).api-keys" } ?? "artemis.api-keys") {
        self.service = service
    }

    func apiKey(for providerId: String) -> String? {
        var query = baseQuery(providerId)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func setAPIKey(_ key: String, for providerId: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try deleteAPIKey(for: providerId)
            return
        }

        let data = Data(trimmed.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(baseQuery(providerId) as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = baseQuery(providerId)
            addQuery.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw APIKeyStoreError.keychain(addStatus) }
        default:
            throw APIKeyStoreError.keychain(updateStatus)
        }
    }

    func deleteAPIKey(for providerId: String) throws {
        let status = SecItemDelete(baseQuery(providerId) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw APIKeyStoreError.keychain(status)
        }
    }

    private func baseQuery(_ providerId: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerId,
        ]
    }
}

/// Volatile store for previews and tests.
final class InMemoryAPIKeyStore: APIKeyStore {
    private let keys = Mutex<[String: String]>([:])

    func apiKey(for providerId: String) -> String? {
        keys.withLock { $0[providerId] }
    }

    func setAPIKey(_ key: String, for providerId: String) throws {
        keys.withLock { $0[providerId] = key }
    }

    func deleteAPIKey(for providerId: String) throws {
        _ = keys.withLock { $0.removeValue(forKey: providerId) }
    }
}
