# Источники

Материалы, на которые опирались при работе с локальной моделью Apple и системными интеграциями.

## Что за модель

- [Apple Intelligence Foundation Language Models](https://machinelearning.apple.com/research/apple-intelligence-foundation-language-models) — исследовательская статья: устройство модели (~3B параметров), обучение, ограничения.
- [Apple Foundation Models Tech Report 2025](https://machinelearning.apple.com/research/apple-foundation-models-tech-report-2025) — техотчёт по обновлённой модели: мультимодальность, языки, качество.
- [Apple Intelligence: поддерживаемые языки](https://support.apple.com/en-us/121115) — официальный список языков (русского и польского нет → роутер отправляет их в облако).
- [Apple newsroom, WWDC26: Apple Intelligence](https://www.apple.com/newsroom/2026/06/apple-unveils-next-generation-of-apple-intelligence-siri-ai-and-more/) — что нового в этом году.

## Документация Foundation Models

- [Generating content and performing tasks with Foundation Models](https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models) — базовое руководство: сессии, промпты, `@Generable`.
- [TN3193: Managing the on-device foundation model's context window](https://developer.apple.com/documentation/technotes/tn3193-managing-the-on-device-foundation-model-s-context-window) — окно 4096 токенов, `tokenCount`, обрезка истории, переиспользование сессий.
- [Analyzing images with multimodal prompting](https://developer.apple.com/documentation/FoundationModels/analyzing-images-with-multimodal-prompting) — картинки как вход (`Attachment`).
- [Expanding generation with tool calling](https://developer.apple.com/documentation/FoundationModels/expanding-generation-with-tool-calling) — инструменты (календарь, контакты, погода и т.д.).
- [Composing dynamic sessions with instructions and profiles](https://developer.apple.com/documentation/FoundationModels/composing-dynamic-sessions-with-instructions-and-profiles) — инструкции, `prewarm`.
- [Supporting languages and locales](https://developer.apple.com/documentation/foundationmodels/supporting-languages-and-locales-with-foundation-models) — `supportsLocale`, проверка языка.
- [Improving the safety of generative model output](https://developer.apple.com/documentation/foundationmodels/improving-the-safety-of-generative-model-output) — guardrails, отказы (идея RefusalDetector).
- [SystemLanguageModel.UseCase.contentTagging](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/usecase/contenttagging) — специализированный режим модели.
- [Adding server-side intelligence with Private Cloud Compute](https://developer.apple.com/documentation/FoundationModels/adding-server-side-intelligence-with-private-cloud-compute) — облачная модель Apple (нужен entitlement, отложено).

## Видео WWDC

- [WWDC26 · What's new in the Foundation Models framework (241)](https://developer.apple.com/videos/play/wwdc2026/241/)
- [WWDC26 · Build with the new Apple Foundation Model on Private Cloud Compute (319)](https://developer.apple.com/videos/play/wwdc2026/319/)
- [WWDC26 · Machine Learning & AI Group Lab (8016)](https://developer.apple.com/videos/play/wwdc2026/8016/)
- [WWDC26 · Coding Intelligence, Machine Learning & AI Group Lab (8121)](https://developer.apple.com/videos/play/wwdc2026/8121/)
- [WWDC25 · Meet the Foundation Models framework (286)](https://developer.apple.com/videos/play/wwdc2025/286/)
- [WWDC25 · Deep dive into the Foundation Models framework (301)](https://developer.apple.com/videos/play/wwdc2025/301/)
- [WWDC25 · Explore prompt design & safety for on-device foundation models (248)](https://developer.apple.com/videos/play/wwdc2025/248/) — принцип «роль и возможности сначала, ограничения один раз».
- [WWDC26 · Apple Intelligence guide](https://developer.apple.com/wwdc26/guides/apple-intelligence/)

## Дизайн

- [HIG: Generative AI](https://developer.apple.com/design/human-interface-guidelines/generative-ai) — как показывать ИИ-функции в интерфейсе.

## Голос

- [WWDC25 · Bring advanced speech-to-text to your app with SpeechAnalyzer (277)](https://developer.apple.com/videos/play/wwdc2025/277/)
- [Bringing advanced speech-to-text capabilities to your app](https://developer.apple.com/documentation/Speech/bringing-advanced-speech-to-text-capabilities-to-your-app)
- [Why your iOS voice agent still hears itself (VoiceProcessingIO)](https://barock.dev/2026/04/22/why-your-ios-voice-agent-still-hears-itself) — порядок настройки эхоподавления.
- [SpeechAnalyzer iOS 26 Swift Guide](https://swiftcrafted.dev/article/speechanalyzer-speechtranscriber-ios-26-swift)
- [iOS 26's SpeechAnalyzer on a live mic: 5 things the docs don't tell you](https://dev.to/simple_memo/ios-26s-speechanalyzer-on-a-live-mic-the-5-things-the-docs-dont-tell-you-2ng5)

## Будильники

- [Scheduling an alarm with AlarmKit](https://developer.apple.com/documentation/alarmkit/scheduling-an-alarm-with-alarmkit)
- [WWDC25 · Wake up to the AlarmKit API (230)](https://developer.apple.com/wwdc25/230)
