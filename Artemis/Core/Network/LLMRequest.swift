import Foundation

public struct LLMRequest: Sendable {
    public var model: String
    public var messages: [Message]
    public var systemPrompt: String?
    public var preset: Preset?
    public var enableWebSearch: Bool

    public init(
        model: String,
        messages: [Message],
        systemPrompt: String? = nil,
        preset: Preset? = nil,
        enableWebSearch: Bool = false
    ) {
        self.model = model
        self.messages = messages
        self.systemPrompt = systemPrompt
        self.preset = preset
        self.enableWebSearch = enableWebSearch
    }

    public func encodeToJSONData() throws -> Data {
        var wireMessages: [WireMessage] = []

        let effectiveSystem = preset?.systemPrompt.isEmpty == false ? preset?.systemPrompt : systemPrompt
        if let system = effectiveSystem, !system.isEmpty {
            wireMessages.append(WireMessage(role: "system", content: .text(system)))
        }

        for msg in messages {
            let content: WireContent
            if msg.attachments.isEmpty {
                content = .text(msg.content)
            } else {
                var parts: [WireContentPart] = []
                if !msg.content.isEmpty {
                    parts.append(WireContentPart(type: "text", text: msg.content))
                }
                for att in msg.attachments {
                    if let data = att.data {
                        let base64 = data.base64EncodedString()
                        let dataUrl = "data:\(att.mime);base64,\(base64)"
                        if att.kind == .document {
                            parts.append(WireContentPart(type: "file", file: .init(filename: att.filename, fileData: dataUrl)))
                        } else {
                            parts.append(WireContentPart(type: "image_url", imageUrl: .init(url: dataUrl)))
                        }
                    }
                }
                content = .parts(parts)
            }
            wireMessages.append(WireMessage(role: msg.role.rawValue, content: content))
        }

        let wire = WireRequest(
            model: model,
            messages: wireMessages,
            stream: true,
            streamOptions: .init(includeUsage: true),
            plugins: enableWebSearch ? [.init(id: "web")] : nil,
            temperature: preset?.temperature,
            topP: preset?.topP,
            frequencyPenalty: preset?.frequencyPenalty,
            presencePenalty: preset?.presencePenalty
        )

        return try JSONEncoder().encode(wire)
    }
}

// MARK: - Wire Types
private struct WireRequest: Encodable {
    let model: String
    let messages: [WireMessage]
    let stream: Bool
    let streamOptions: WireStreamOptions?
    let plugins: [WirePlugin]?
    let temperature: Double?
    let topP: Double?
    let frequencyPenalty: Double?
    let presencePenalty: Double?

    enum CodingKeys: String, CodingKey {
        case model, messages, stream
        case streamOptions = "stream_options"
        case plugins
        case temperature
        case topP = "top_p"
        case frequencyPenalty = "frequency_penalty"
        case presencePenalty = "presence_penalty"
    }
}

private struct WireStreamOptions: Encodable {
    let includeUsage: Bool
    enum CodingKeys: String, CodingKey {
        case includeUsage = "include_usage"
    }
}

private struct WirePlugin: Encodable {
    let id: String
}

private struct WireMessage: Encodable {
    let role: String
    let content: WireContent

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        switch content {
        case .text(let str):
            try container.encode(str, forKey: .content)
        case .parts(let parts):
            try container.encode(parts, forKey: .content)
        }
    }

    enum CodingKeys: String, CodingKey {
        case role, content
    }
}

private enum WireContent: Encodable {
    case text(String)
    case parts([WireContentPart])
}

private struct WireContentPart: Encodable {
    let type: String
    var text: String?
    var imageUrl: WireImageURL?
    var file: WireFilePart?

    enum CodingKeys: String, CodingKey {
        case type, text
        case imageUrl = "image_url"
        case file
    }
}

private struct WireImageURL: Encodable {
    let url: String
}

private struct WireFilePart: Encodable {
    let filename: String
    let fileData: String
    enum CodingKeys: String, CodingKey {
        case filename
        case fileData = "file_data"
    }
}
