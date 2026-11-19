import Foundation

/// A place the user named in the settings, e.g. "Gym" at its address.
struct SavedPlace: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var address: String
}

/// The user's places, so "how long to the gym?" has an answer. Stored only on this device.
enum SavedPlaces {
    private static let key = "savedPlaces"
    /// Home and work addresses from the first version of the settings.
    private static let legacyKeys = [("Home", "homeAddress"), ("Work", "workAddress")]

    static func load() -> [SavedPlace] {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: key) {
            return (try? JSONDecoder().decode([SavedPlace].self, from: data)) ?? []
        }
        let migrated = legacyKeys.compactMap { name, legacyKey -> SavedPlace? in
            let address = defaults.string(forKey: legacyKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return address.isEmpty ? nil : SavedPlace(name: name, address: address)
        }
        save(migrated)
        legacyKeys.forEach { defaults.removeObject(forKey: $0.1) }
        return migrated
    }

    static func save(_ places: [SavedPlace]) {
        guard let data = try? JSONEncoder().encode(places) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// The saved place called `name`, ignoring case, accents and a leading "my" ("my gym").
    static func place(named name: String, in places: [SavedPlace]) -> SavedPlace? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = [trimmed, String(trimmed.trimmingPrefix(/(?i)my\s+/))]
        return places.first { place in
            candidates.contains { $0.compare(place.name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        }
    }
}
