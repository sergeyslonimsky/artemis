import Foundation
import GRDB
@testable import Artemis

/// A fresh in-memory database with all migrations applied and no Keychain access.
func makeDatabase() throws -> AppDatabase {
    let attachments = FileManager.default.temporaryDirectory
        .appendingPathComponent("artemis-tests-\(UUID().uuidString)", isDirectory: true)
    return try AppDatabase(DatabaseQueue(), attachmentsDirectory: attachments, apiKeys: InMemoryAPIKeyStore())
}

/// A backend that replays scripted events, optionally ending with an error.
struct FakeBackend: ChatBackend {
    var kind: BackendKind = .onDevice
    var events: [LLMEvent]
    var failure: (any Error)?

    var descriptor: BackendDescriptor { BackendDescriptor(kind: kind) }

    func stream(_ turn: ChatTurn) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            if let failure {
                continuation.finish(throwing: failure)
            } else {
                continuation.finish()
            }
        }
    }
}

/// Records the turn a backend was asked to answer.
final class RecordingBackend: ChatBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: ChatTurn?
    let kind: BackendKind

    init(kind: BackendKind) {
        self.kind = kind
    }

    var lastTurn: ChatTurn? { lock.withLock { recorded } }
    var descriptor: BackendDescriptor { BackendDescriptor(kind: kind) }

    func stream(_ turn: ChatTurn) -> AsyncThrowingStream<LLMEvent, Error> {
        lock.withLock { recorded = turn }
        return AsyncThrowingStream { continuation in
            continuation.yield(.content("ok"))
            continuation.finish()
        }
    }
}

func userMessage(_ text: String, attachments: [Artemis.Attachment] = []) -> Message {
    Message(chatId: "chat", role: .user, content: text, attachments: attachments)
}
