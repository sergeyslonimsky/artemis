import Foundation
import Testing
@testable import Artemis

@Suite("Routing rules")
struct RoutingRulesTests {
    /// English is supported, everything else isn't; a 4K context like the real model.
    let rules = RoutingRules(supportsLanguage: { $0 == .english }, onDeviceContextSize: 4096)

    func context(
        _ text: String,
        mode: RoutingMode = .auto,
        onDeviceUsable: Bool = true,
        hasUnsupportedAttachment: Bool = false,
        attachments: [Artemis.Attachment] = []
    ) -> RouteContext {
        RouteContext(
            message: userMessage(text, attachments: attachments),
            recentHistory: [],
            mode: mode,
            onDeviceUsable: onDeviceUsable,
            hasCloud: true,
            hasUnsupportedAttachment: hasUnsupportedAttachment
        )
    }

    @Test func explicitModesWin() {
        #expect(rules.evaluate(context("What's the news?", mode: .onDevice)) == .onDevice(.userSelectedOnDevice))
        #expect(rules.evaluate(context("hi", mode: .cloud)) == .cloud(.userSelectedCloud))
    }

    @Test func unusableOnDeviceGoesToCloud() {
        #expect(rules.evaluate(context("hello there", onDeviceUsable: false)) == .cloud(.onDeviceUnavailable))
    }

    @Test func unsupportedAttachmentGoesToCloud() {
        #expect(rules.evaluate(context("what is in this file", hasUnsupportedAttachment: true)) == .cloud(.unsupportedAttachment))
    }

    @Test func unsupportedLanguageGoesToCloud() {
        let decision = rules.evaluate(context("Какая сегодня погода в Варшаве и стоит ли брать зонт?"))
        #expect(decision == .cloud(.unsupportedLanguage))
    }

    @Test func shortTextIsNotLanguageChecked() {
        // Too short to detect a language reliably: left to the classifier.
        #expect(rules.evaluate(context("Привет, как дела")) != .cloud(.unsupportedLanguage))
    }

    @Test func longInputGoesToCloud() {
        let long = String(repeating: "This sentence is part of a very long message. ", count: 200)
        #expect(rules.evaluate(context(long)) == .cloud(.longInput))
    }

    @Test(arguments: ["hi", "thanks!", "ok cool", "good morning"])
    func smallTalkStaysOnDevice(_ text: String) {
        #expect(rules.evaluate(context(text)) == .onDevice(.smallTalk))
    }

    @Test(arguments: ["what time is it?", "add 2 and 3", "tell me about the history of Rome"])
    func otherRequestsAreClassified(_ text: String) {
        #expect(rules.evaluate(context(text)) == nil)
    }

    @Test func smallTalkWithAttachmentIsClassified() {
        let image = Artemis.Attachment(filename: "a.jpg", mime: "image/jpeg", kind: .image, data: Data([1]))
        #expect(rules.evaluate(context("hi", attachments: [image])) == nil)
    }

    @Test func cloudAcceptance() {
        let image = Artemis.Attachment(filename: "a.jpg", mime: "image/jpeg", kind: .image, data: Data([1]))
        let pdf = Artemis.Attachment(filename: "a.pdf", mime: "application/pdf", kind: .document, data: Data([1]))
        let text = Artemis.Attachment(filename: "a.txt", mime: "text/plain", kind: .document, data: Data("x".utf8))
        let textOnly = ProviderCapabilities(supportsImages: false, supportsFileParts: false, supportsStreamUsage: true)

        #expect(RoutingRules.accepts(userMessage("", attachments: [text]), textOnly))
        #expect(!RoutingRules.accepts(userMessage("", attachments: [image]), textOnly))
        #expect(!RoutingRules.accepts(userMessage("", attachments: [pdf]), textOnly))
        #expect(RoutingRules.accepts(userMessage("", attachments: [image, pdf]), ProviderKind.openRouter.capabilities))
    }
}

@Suite("Classifier decisions")
struct ClassifierDecisionTests {
    let allTools = Set(ToolGroup.allCases)

    @Test func cloudCategories() {
        for (category, reason) in [
            (RequestCategory.math, RouteReason.math),
            (.freshInformation, .freshInformation),
            (.complexReasoning, .complexReasoning),
            (.code, .code),
            (.longForm, .longForm),
        ] {
            #expect(RequestClassifier.decision(for: category, availableTools: allTools) == .cloud(reason))
        }
    }

    @Test func toolCategoriesStayOnDevice() {
        #expect(RequestClassifier.decision(for: .personalData, availableTools: allTools) == .onDevice(.personalData))
        #expect(RequestClassifier.decision(for: .weather, availableTools: allTools) == .onDevice(.weather))
        #expect(RequestClassifier.decision(for: .health, availableTools: allTools) == .onDevice(.health))
        #expect(RequestClassifier.decision(for: .alarm, availableTools: allTools) == .onDevice(.alarm))
    }

    @Test func disabledWeatherAndPlacesFallBackToTheWeb() {
        #expect(RequestClassifier.decision(for: .weather, availableTools: []) == .cloud(.freshInformation))
        #expect(RequestClassifier.decision(for: .places, availableTools: []) == .cloud(.freshInformation))
    }

    @Test func travelUsesLocation() {
        #expect(RequestClassifier.decision(for: .travel, availableTools: allTools) == .onDevice(.travel))
        #expect(RouteReason.travel.toolGroups == [.places])
        #expect(RouteReason.travel.keepsDataOnDevice)
        // Without location there's no starting point: maps on the web can still help.
        #expect(RequestClassifier.decision(for: .travel, availableTools: []) == .cloud(.freshInformation))
    }

    @Test func leaveAlarmAddsTheAlarmTools() {
        #expect(RequestClassifier.decision(for: .leaveAlarm, availableTools: allTools) == .onDevice(.travelAlarm))
        #expect(RouteReason.travelAlarm.toolGroups == [.places, .alarms])
        #expect(RouteReason.travelAlarm.keepsDataOnDevice)
        #expect(RequestClassifier.decision(for: .leaveAlarm, availableTools: [.alarms]) == .onDevice(.alarm))
    }

    @Test func disabledPersonalToolsStayOnDevice() {
        // The cloud can't see the user's data either; the on-device model explains.
        #expect(RequestClassifier.decision(for: .personalData, availableTools: []) == .onDevice(.deviceAction))
        #expect(RequestClassifier.decision(for: .contacts, availableTools: []) == .onDevice(.deviceAction))
    }
}

@Suite("Route reasons")
struct RouteReasonTests {
    @Test func toolGroupsPerReason() {
        #expect(RouteReason.personalData.toolGroups == [.schedule])
        #expect(RouteReason.weather.toolGroups == [.weather])
        #expect(RouteReason.userSelectedOnDevice.toolGroups == Set(ToolGroup.allCases))
        #expect(RouteReason.simple.toolGroups.isEmpty)
        // Kept on-device although the cloud was preferred: every tool may help.
        #expect(RouteReason.freshInformation.toolGroups == Set(ToolGroup.allCases))
    }

    @Test func privateReasonsKeepDataOnDevice() {
        for reason in [RouteReason.personalData, .contacts, .alarm, .places, .health] {
            #expect(reason.keepsDataOnDevice)
            #expect(!reason.prefersCloud)
        }
        #expect(!RouteReason.weather.keepsDataOnDevice)
    }
}

@Suite("Cloud policy")
struct CloudPolicyTests {
    let cloud = RouteDecision.cloud(.freshInformation)
    let local = RouteDecision.onDevice(.simple)

    @Test func onDeviceDecisionsAreUntouched() {
        for policy in [CloudPolicy.alwaysAsk, .alwaysAllow, .deny] {
            #expect(policy.apply(to: local, mode: .auto, chatAllowsCloud: false) == .proceed(local))
        }
    }

    @Test func explicitModesBypassThePolicy() {
        #expect(CloudPolicy.deny.apply(to: cloud, mode: .cloud, chatAllowsCloud: false) == .proceed(cloud))
    }

    @Test func autoMode() {
        #expect(CloudPolicy.alwaysAllow.apply(to: cloud, mode: .auto, chatAllowsCloud: false) == .proceed(cloud))
        #expect(CloudPolicy.alwaysAsk.apply(to: cloud, mode: .auto, chatAllowsCloud: false) == .needsConsent(.freshInformation))
        #expect(CloudPolicy.alwaysAsk.apply(to: cloud, mode: .auto, chatAllowsCloud: true) == .proceed(cloud))
        #expect(CloudPolicy.deny.apply(to: cloud, mode: .auto, chatAllowsCloud: true) == .keepOnDevice(.freshInformation))
    }
}
