import Foundation
import Testing
@testable import Artemis

@Suite("Request encoding")
struct LLMRequestTests {
    let image = Artemis.Attachment(filename: "photo.jpg", mime: "image/jpeg", kind: .image, data: Data([0xFF, 0xD8]))
    let pdf = Artemis.Attachment(filename: "doc.pdf", mime: "application/pdf", kind: .document, data: Data("%PDF".utf8))
    let text = Artemis.Attachment(filename: "notes.txt", mime: "text/plain", kind: .document, data: Data("hello".utf8))

    func json(_ request: LLMRequest) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: request.encodeToJSONData()) as? [String: Any])
    }

    func messages(_ body: [String: Any]) -> [[String: Any]] {
        body["messages"] as? [[String: Any]] ?? []
    }

    @Test func systemPromptAndPresetOverride() throws {
        let plain = try json(LLMRequest(model: "m", messages: [userMessage("hi")], systemPrompt: "Be brief."))
        #expect(messages(plain).first?["role"] as? String == "system")
        #expect(messages(plain).first?["content"] as? String == "Be brief.")

        let preset = Preset(title: "Translator", systemPrompt: "Translate.", temperature: 0.2)
        let withPreset = try json(LLMRequest(model: "m", messages: [userMessage("hi")], systemPrompt: "Be brief.", preset: preset))
        #expect(messages(withPreset).first?["content"] as? String == "Translate.")
        #expect(withPreset["temperature"] as? Double == 0.2)
    }

    @Test func streamUsageAndWebSearchFollowCapabilities() throws {
        let mistral = try json(LLMRequest(model: "m", messages: [userMessage("hi")], capabilities: ProviderKind.mistral.capabilities))
        #expect(mistral["stream_options"] == nil)
        #expect(mistral["plugins"] == nil)

        let openRouter = try json(LLMRequest(
            model: "m", messages: [userMessage("hi")], capabilities: ProviderKind.openRouter.capabilities, webSearch: true
        ))
        #expect((openRouter["stream_options"] as? [String: Any])?["include_usage"] as? Bool == true)
        #expect((openRouter["plugins"] as? [[String: Any]])?.first?["id"] as? String == "web")
        #expect(openRouter["stream"] as? Bool == true)
    }

    @Test func attachmentsBecomeContentParts() throws {
        let body = try json(LLMRequest(
            model: "m",
            messages: [userMessage("look", attachments: [image, pdf, text])],
            capabilities: ProviderKind.openRouter.capabilities
        ))
        let parts = try #require(messages(body).last?["content"] as? [[String: Any]])
        #expect(parts.map { $0["type"] as? String } == ["text", "image_url", "file", "text"])
        let imageURL = (parts[1]["image_url"] as? [String: Any])?["url"] as? String
        #expect(imageURL?.hasPrefix("data:image/jpeg;base64,") == true)
        #expect((parts[3]["text"] as? String)?.contains("hello") == true)
    }

    @Test func currentUnsupportedAttachmentFails() {
        let textOnly = ProviderCapabilities(supportsImages: false, supportsFileParts: false, supportsStreamUsage: true)
        let request = LLMRequest(model: "m", messages: [userMessage("look", attachments: [image])], capabilities: textOnly)
        #expect(throws: LLMRequestError.self) { try request.encodeToJSONData() }
    }

    @Test func pastUnsupportedAttachmentBecomesANote() throws {
        let textOnly = ProviderCapabilities(supportsImages: false, supportsFileParts: false, supportsStreamUsage: true)
        let history = [
            userMessage("what's this", attachments: [image]),
            Message(chatId: "chat", role: .assistant, content: "A cat."),
            userMessage("and its name?"),
        ]
        let body = try json(LLMRequest(model: "m", messages: history, capabilities: textOnly))
        let parts = try #require(messages(body).first?["content"] as? [[String: Any]])
        #expect((parts.last?["text"] as? String)?.contains("photo.jpg — not available to this model") == true)
    }

    @Test func pastAttachmentsCanBeDropped() throws {
        var request = LLMRequest(
            model: "m",
            messages: [userMessage("this", attachments: [image]), userMessage("again")],
            capabilities: ProviderKind.openRouter.capabilities
        )
        request.includesPastAttachments = false
        let parts = try #require(messages(try json(request)).first?["content"] as? [[String: Any]])
        #expect(!parts.contains { $0["type"] as? String == "image_url" })
    }
}

/// Serves canned HTTP responses to `LLMClient` through a custom `URLSession`.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var response: (status: Int, body: String) = (200, "")

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (status, body) = Self.response
        let http = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

@Suite("Streaming responses", .serialized)
struct StreamingTests {
    func collect(status: Int = 200, body: String) async throws -> [LLMEvent] {
        StubURLProtocol.response = (status, body)
        let client = LLMClient(baseUrl: "https://example.test/v1", apiKey: "key", session: StubURLProtocol.session())
        var events: [LLMEvent] = []
        for try await event in client.stream(request: LLMRequest(model: "m", messages: [userMessage("hi")])) {
            events.append(event)
        }
        return events
    }

    func chunk(content: String? = nil, reasoning: String? = nil) -> String {
        var delta: [String: String] = [:]
        delta["content"] = content
        delta["reasoning"] = reasoning
        let data = try! JSONSerialization.data(withJSONObject: ["choices": [["delta": delta]]])
        return "data: " + String(decoding: data, as: UTF8.self) + "\n\n"
    }

    @Test func contentReasoningAndUsage() async throws {
        let body = chunk(reasoning: "Thinking")
            + chunk(content: "Hel") + chunk(content: "lo")
            + "data: {\"choices\":[],\"usage\":{\"completion_tokens\":7}}\n\n"
            + "data: [DONE]\n\n"
        let events = try await collect(body: body)

        let contents = events.compactMap { if case .content(let text) = $0 { text } else { nil } }
        let reasoning = events.compactMap { if case .reasoning(let text) = $0 { text } else { nil } }
        #expect(contents.joined() == "Hello")
        #expect(reasoning == ["Thinking"])
        guard case .done(let tokens, let isEstimated, _) = events.last else {
            Issue.record("Missing .done")
            return
        }
        #expect(tokens == 7)
        #expect(!isEstimated)
    }

    @Test func midStreamErrorWithHTTP200() async throws {
        let body = chunk(content: "Par") + "data: {\"error\":{\"message\":\"Upstream rejected the request\"}}\n\n"
        await #expect(throws: LLMError.provider("Upstream rejected the request")) {
            try await collect(body: body)
        }
    }

    @Test func httpErrorBodyIsReadable() async throws {
        await #expect(throws: LLMError.http(status: 400, message: "Model doesn't accept images (HTTP 400)")) {
            try await collect(status: 400, body: #"{"error":{"message":"Model doesn't accept images"}}"#)
        }
    }

    @Test func errorMessageFallbacks() {
        #expect(LLMClient.errorMessage(from: "", status: 502) == "Server returned HTTP 502")
        #expect(LLMClient.errorMessage(from: "Bad gateway", status: 502) == "Bad gateway")
    }
}
