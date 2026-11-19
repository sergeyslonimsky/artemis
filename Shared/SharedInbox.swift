import Foundation

// Compiled into the app and the share extension.

/// What the share extension hands to the app: a request and the files it is about.
struct SharedItem: Codable, Sendable {
    var id: String
    var createdAt: Date
    /// What to ask about the files; empty to only attach them.
    var prompt: String
    /// Send right away, or leave the prompt and files in the composer.
    var autoSend: Bool
    /// Names of the files stored next to the manifest, in the order they were shared.
    var filenames: [String]
}

/// A folder per shared item in the App Group container. The extension stages the files first and
/// writes the manifest last, so an item without one is unfinished and never picked up. The id of
/// the latest finished item is also kept in the group's defaults, so the app finds it without
/// listing the folder.
enum SharedInbox {
    static let urlScheme = "artemis"
    private static let urlHost = "shared"
    private static let manifestName = "item.json"
    private static let latestIdKey = "latestSharedItemId"
    private static let latestDateKey = "latestSharedItemDate"

    enum InboxError: LocalizedError {
        case unavailable
        case missingItem

        var errorDescription: String? {
            switch self {
            case .unavailable: "Artemis's shared storage isn't available."
            case .missingItem: "The shared item is gone."
            }
        }
    }

    /// `group.<app bundle id>`, written into each target's Info.plist at build time.
    private static let appGroup = Bundle.main.object(forInfoDictionaryKey: "ArtemisAppGroup") as? String

    static let directory: URL? = appGroup
        .flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
        .map { $0.appending(path: "Inbox", directoryHint: .isDirectory) }

    private static var defaults: UserDefaults? {
        appGroup.flatMap(UserDefaults.init(suiteName:))
    }

    static func folder(for id: String) throws -> URL {
        guard let directory else { throw InboxError.unavailable }
        return directory.appending(path: id, directoryHint: .isDirectory)
    }

    // MARK: - Writing (the extension)

    /// A new, empty folder to stage shared files in.
    static func makeFolder(id: String = UUID().uuidString.lowercased()) throws -> (id: String, url: URL) {
        let url = try folder(for: id)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return (id, url)
    }

    /// Completes a staged item: from now on the app can pick it up.
    static func commit(_ item: SharedItem) throws {
        let data = try JSONEncoder().encode(item)
        try data.write(to: try folder(for: item.id).appending(path: manifestName), options: .atomic)
        defaults?.set(item.id, forKey: latestIdKey)
        defaults?.set(item.createdAt, forKey: latestDateKey)
    }

    static func url(for id: String) -> URL {
        var components = URLComponents()
        components.scheme = urlScheme
        components.host = urlHost
        components.path = "/" + id
        // Always valid: a scheme, a host and a UUID path.
        return components.url!
    }

    // MARK: - Reading (the app)

    /// The item id in a URL made by `url(for:)`.
    static func itemId(in url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == urlScheme, components.host == urlHost else { return nil }
        let id = components.path.trimmingPrefix("/")
        return id.isEmpty ? nil : String(id)
    }

    static func item(id: String) throws -> (item: SharedItem, folder: URL) {
        let folder = try folder(for: id)
        guard let data = try? Data(contentsOf: folder.appending(path: manifestName)) else {
            throw InboxError.missingItem
        }
        return (try JSONDecoder().decode(SharedItem.self, from: data), folder)
    }

    /// The latest item if it's younger than `maxAge` and not opened yet: the extension couldn't
    /// open the app and the user opened it themselves.
    static func latestItemId(maxAge: TimeInterval) -> String? {
        guard let id = defaults?.string(forKey: latestIdKey),
              let date = defaults?.object(forKey: latestDateKey) as? Date,
              -date.timeIntervalSinceNow < maxAge else { return nil }
        return id
    }

    static func remove(id: String) {
        if defaults?.string(forKey: latestIdKey) == id {
            defaults?.removeObject(forKey: latestIdKey)
        }
        guard let folder = try? folder(for: id) else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    /// Deletes items nobody opened and folders an extension never finished.
    @concurrent
    static func removeItems(olderThan maxAge: TimeInterval) async {
        guard let directory,
              let folders = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey]) else {
            return
        }
        for folder in folders {
            let created = (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            if -created.timeIntervalSinceNow > maxAge {
                try? FileManager.default.removeItem(at: folder)
            }
        }
    }
}
