import Contacts
import Foundation
import FoundationModels

/// Contacts lookups for the on-device model. Limited access (only contacts the user shared)
/// works the same way, with fewer results.
actor ContactsStore {
    static let shared = ContactsStore()

    struct Person: Sendable {
        var name: String
        var organization: String?
        var phones: [(label: String, value: String)]
        var emails: [(label: String, value: String)]
        var birthday: DateComponents?
        var address: String?
    }

    enum StoreError: LocalizedError {
        case accessDenied

        var errorDescription: String? {
            "Artemis doesn't have access to your contacts. You can allow it in Settings › Privacy & Security › Contacts."
        }
    }

    private let store = CNContactStore()

    func findPeople(named name: String, limit: Int = 5) async throws -> [Person] {
        guard await requestAccess() else { throw StoreError.accessDenied }
        let keys: [any CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactOrganizationNameKey as NSString,
            CNContactPhoneNumbersKey as NSString,
            CNContactEmailAddressesKey as NSString,
            CNContactBirthdayKey as NSString,
            CNContactPostalAddressesKey as NSString,
        ]
        let predicate = CNContact.predicateForContacts(matchingName: name)
        let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keys)
        return contacts.prefix(limit).map { contact in
            Person(
                name: CNContactFormatter.string(from: contact, style: .fullName) ?? contact.organizationName,
                organization: contact.organizationName.isEmpty ? nil : contact.organizationName,
                phones: contact.phoneNumbers.map { (Self.label($0.label), $0.value.stringValue) },
                emails: contact.emailAddresses.map { (Self.label($0.label), $0.value as String) },
                birthday: contact.birthday,
                address: contact.postalAddresses.first.map {
                    CNPostalAddressFormatter.string(from: $0.value, style: .mailingAddress)
                        .replacingOccurrences(of: "\n", with: ", ")
                }
            )
        }
    }

    private func requestAccess() async -> Bool {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized, .limited:
            return true
        case .notDetermined:
            return (try? await store.requestAccess(for: .contacts)) ?? false
        default:
            return false
        }
    }

    private static func label(_ raw: String?) -> String {
        raw.map { CNLabeledValue<NSString>.localizedString(forLabel: $0) } ?? "other"
    }
}

struct FindContactTool: Tool {
    let sink: ToolEventSink

    let name = "findContact"
    let description = "Looks up a person in the user's contacts: phone numbers, emails, birthday and address."

    @Generable
    struct Arguments {
        @Guide(description: "The person's name as the user said it, e.g. \"Anna\" or \"Mike Brown\"")
        var name: String
    }

    func call(arguments: Arguments) async throws -> String {
        sink.send(.started(.contacts))
        let people: [ContactsStore.Person]
        do {
            people = try await ContactsStore.shared.findPeople(named: arguments.name)
        } catch {
            return error.localizedDescription
        }
        guard !people.isEmpty else { return "No contact matches \"\(arguments.name)\"." }

        return people.map { person in
            var lines = ["- \(person.name)" + (person.organization.map { " (\($0))" } ?? "")]
            lines += person.phones.map { "  phone (\($0.label)): \($0.value)" }
            lines += person.emails.map { "  email (\($0.label)): \($0.value)" }
            if let birthday = person.birthday, let month = birthday.month, let day = birthday.day {
                let date = Calendar.current.date(from: DateComponents(year: birthday.year ?? 2000, month: month, day: day))
                let text = date?.formatted(birthday.year == nil ? .dateTime.day().month(.wide) : .dateTime.day().month(.wide).year())
                lines.append("  birthday: \(text ?? "\(month)/\(day)")")
            }
            if let address = person.address { lines.append("  address: \(address)") }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n")
    }
}

struct DraftContactActionTool: Tool {
    let sink: ToolEventSink

    let name = "draftContactAction"
    let description = "Prepares a phone call, text message or email to a contact for the user to confirm. Does not send anything."

    @Generable
    enum ActionKind {
        case call
        case message
        case email
    }

    @Generable
    struct Arguments {
        var kind: ActionKind
        @Guide(description: "The contact's name")
        var name: String
        @Guide(description: "Text of the message or email; empty for calls")
        var text: String
    }

    func call(arguments: Arguments) async throws -> String {
        sink.send(.started(.contacts))
        let person: ContactsStore.Person
        do {
            guard let found = try await ContactsStore.shared.findPeople(named: arguments.name, limit: 1).first else {
                return "No contact matches \"\(arguments.name)\"."
            }
            person = found
        } catch {
            return error.localizedDescription
        }

        let kind: ActionDraft.Kind
        let address: String?
        switch arguments.kind {
        case .call:
            kind = .call
            address = Self.preferredPhone(of: person)
        case .message:
            kind = .message
            address = Self.preferredPhone(of: person)
        case .email:
            kind = .email
            address = person.emails.first?.value
        }
        guard let address else {
            return "\(person.name) has no \(kind == .email ? "email address" : "phone number") in contacts."
        }

        let text = arguments.text.trimmingCharacters(in: .whitespacesAndNewlines)
        sink.send(.drafted(ActionDraft(kind: kind, title: person.name, address: address, body: text.isEmpty ? nil : text)))
        let what = switch kind {
        case .call: "A call to"
        case .email: "An email to"
        default: "A message to"
        }
        return "\(what) \(person.name) (\(address)) is ready. The user confirms it on the card shown with your reply; nothing is sent yet."
    }

    /// Mobile numbers first: they can take both calls and texts.
    private static func preferredPhone(of person: ContactsStore.Person) -> String? {
        let mobile = person.phones.first { $0.label.localizedCaseInsensitiveContains("mobile") || $0.label.localizedCaseInsensitiveContains("iphone") }
        return (mobile ?? person.phones.first)?.value
    }
}
