import Foundation
import Testing
@testable import Artemis

@Suite("Speakable text")
struct SpeakableTextTests {
    @Test func stripsMarkdown() {
        let markdown = """
            # Weather
            - **Monday**: sunny, see [details](https://example.com)
            Use `brew install`.
            """
        #expect(SpeakableText.clean(markdown) == "Weather. Monday: sunny, see details. Use brew install.")
    }

    @Test func skipsCodeAndTables() {
        let markdown = """
            Here's the code:
            ```swift
            print("hi")
            ```
            | a | b |
            |---|---|
            Done.
            """
        #expect(SpeakableText.clean(markdown) == "Here's the code: (code omitted). Done.")
    }

    @Test func onlyCompleteSentencesWhileStreaming() {
        #expect(SpeakableText.completeSentences(in: "Hello there. How are") == "Hello there.")
        #expect(SpeakableText.completeSentences(in: "No sentence end yet") == "")
    }
}

@Suite("Tool helpers")
struct ToolHelperTests {
    @Test func parsesDatesTheModelSends() throws {
        let timed = try #require(PersonalDataTools.parseDate("2026-11-19T10:30"))
        #expect(timed.hasTime)
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: timed.date)
        #expect(components == DateComponents(year: 2026, month: 11, day: 19, hour: 10, minute: 30))

        #expect(PersonalDataTools.parseDate("2026-11-19T10:30:00Z")?.hasTime == true)
        #expect(PersonalDataTools.parseDate("2026-11-19")?.hasTime == false)
        #expect(PersonalDataTools.parseDate("tomorrow") == nil)
    }

    @Test func instructionsCoverOnlyTheTurnsTools() {
        let weatherOnly = PersonalDataTools.instructions(for: [.weather])
        #expect(weatherOnly.contains("getWeather"))
        #expect(!weatherOnly.contains("draftAlarm"))
        #expect(PersonalDataTools.instructions(for: [.alarms]).contains("never say you set"))
    }

    @MainActor
    @Test func contactActionURLs() {
        let call = ActionDraft(kind: .call, title: "Anna", address: "+48 600 100 200")
        #expect(DraftPerformer.url(for: call)?.absoluteString == "tel:+48600100200")

        let message = ActionDraft(kind: .message, title: "Mike", address: "+1 (555) 010", body: "Running late")
        #expect(DraftPerformer.url(for: message)?.absoluteString == "sms:+1555010&body=Running%20late")

        let email = ActionDraft(kind: .email, title: "Anna", address: "anna@example.com", body: "Hi")
        #expect(DraftPerformer.url(for: email)?.absoluteString == "mailto:anna@example.com?body=Hi")
    }
}

@Suite("Providers")
struct ProviderTests {
    @Test(arguments: [
        ("https://openrouter.ai/api/v1", ProviderKind.openRouter),
        ("https://api.openai.com/v1", .openAI),
        ("https://api.mistral.ai/v1", .mistral),
        ("http://localhost:8080/v1", .custom),
    ])
    func infersKindFromEndpoint(_ url: String, _ kind: ProviderKind) {
        #expect(ProviderKind.infer(fromBaseURL: url) == kind)
    }

    @Test func modelCapabilitiesOverrideKindDefaults() {
        let provider = Provider(
            name: "Gateway", kind: .openRouter, baseUrl: "https://gw.example/v1",
            models: ["text-only", "vision", "unknown"],
            modelCapabilities: ["text-only": ["tools"], "vision": ["image_input", "pdf_input"]]
        )
        #expect(!provider.capabilities(for: "text-only").supportsImages)
        #expect(provider.capabilities(for: "vision").supportsFileParts)
        // Nothing reported: the kind's defaults.
        #expect(provider.capabilities(for: "unknown") == ProviderKind.openRouter.capabilities)
    }

    @Test func modelNames() {
        let name = ModelName("anthropic/claude-sonnet-4.5:free")
        #expect(name.title == "claude-sonnet-4.5")
        #expect(name.vendor == "anthropic")
        #expect(name.isFree)
        #expect(ModelName("gpt-5").vendor == nil)
        #expect(ModelName.label(provider: "OpenRouter", model: nil) == "OpenRouter")
        #expect(ModelName.label(provider: nil, model: "") == nil)
    }

    @Test func presetPromptReplacesTheGeneralOne() {
        let preset = Preset(title: "Translator", systemPrompt: "Translate.")
        #expect(Preset.effectiveSystemPrompt(preset: preset, fallback: "Be brief.") == "Translate.")
        #expect(Preset.effectiveSystemPrompt(preset: Preset(title: "Empty"), fallback: "Be brief.") == "Be brief.")
        #expect(Preset.effectiveSystemPrompt(preset: nil, fallback: "") == nil)
    }

    @Test func textDocumentsIncludeXMLButNotPDF() {
        let xml = Attachment(filename: "a.xml", mime: "application/xml", kind: .document, data: Data("<a/>".utf8))
        let pdf = Attachment(filename: "a.pdf", mime: "application/pdf", kind: .document, data: Data())
        #expect(xml.text == "<a/>")
        #expect(!pdf.isTextDocument)
    }

    @Test func everyToolGroupRoutesBackToItself() {
        for group in ToolGroup.allCases {
            #expect(group.routeReason.toolGroups == [group])
        }
    }
}
