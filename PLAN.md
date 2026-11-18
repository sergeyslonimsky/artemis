# Artemis iOS — план: on-device модель + BYOK-провайдеры

## Цель

Чат-клиент в духе ChatGPT с BYOK-провайдерами (OpenRouter, Mistral, OpenAI и любые OpenAI-compatible `/chat/completions`).
По умолчанию отвечает локальная модель Apple (Foundation Models). В облако (текущий выбранный провайдер/модель)
запрос уходит только когда локальная модель не справится: свежие данные / web search, сложный reasoning, код,
длинный контекст, вложения — и только с разрешения пользователя согласно политике облака.

## Принятые решения

| Вопрос | Решение |
|---|---|
| Deployment target | **iOS 26.0** (без веток `#available`). Требуется Xcode 26 SDK. |
| Язык | Пользователь пишет на английском → поддерживаемая локаль. Проверку `supportsLocale` всё равно делаем (правило роутера). |
| Приватность | Настройка **Cloud policy**: `deny` / `alwaysAsk` / `alwaysAllow` (см. ниже). |
| Web search | **Ничего своего не делаем.** Отдаём запрос провайдеру как есть; если модель/провайдер умеют web search — они сами вызывают свой tool. Удаляем наш `plugins: [web]` и `enableWebSearch`. Роутер лишь распознаёт, что запросу нужны свежие данные, и отправляет его в облако. |

### Cloud policy — семантика

Политика управляет **автоматической** эскалацией (режим Auto). Явные действия пользователя
(режим чата «Cloud», кнопка «Ask cloud» под ответом) считаются согласием.

- `deny` — Auto никогда не уходит в облако. Если правила/классификатор говорят «нужно облако», отвечает локальная
  модель с пометкой «may be inaccurate: needs web/complex reasoning», под ответом — кнопка «Ask cloud».
  При ошибке локальной модели (контекст, guardrail) — сообщение об ошибке + та же кнопка.
- `alwaysAsk` (default) — в чате появляется inline-карточка подтверждения:
  «This request needs the cloud: *fresh information*. [Send to OpenRouter · model] [Answer on-device]».
  Опционально чекбокс «Don't ask again in this chat».
- `alwaysAllow` — эскалация прозрачная, только бейдж и причина на сообщении.

---

## Архитектура

```
ChatService (@MainActor @Observable, orchestrator)
   │   держит per-chat ChatRunState { phase, streamingContent, streamingReasoning, pendingConsent }
   │
   ├── Router ─────────► RouteDecision { target: .onDevice | .cloud(ProviderRef, model), reason: RouteReason }
   │                        1) жёсткие правила (бесплатно)
   │                        2) on-device классификатор (@Generable)
   │                        3) применение CloudPolicy → .proceed / .needsConsent / .deniedFallbackLocal
   │
   └── ChatBackend (protocol)
         stream(ChatTurn) -> AsyncThrowingStream<LLMEvent, Error>
         ├── OpenAICompatibleBackend   — текущий LLMClient + ProviderCapabilities
         └── AppleOnDeviceBackend      — LanguageModelSession, бюджет контекста, snapshot→delta, маппинг ошибок
```

### Новые / изменённые типы

- `ChatBackend` — протокол бэкенда; `ChatTurn` — нормализованный запрос (history, system prompt, preset, attachments).
- `BackendKind`: `.onDevice`, `.cloud`.
- `RouteReason`: `userForcedCloud`, `userForcedLocal`, `freshInformation`, `complexReasoning`, `code`, `longForm`,
  `attachments`, `contextTooLong`, `unsupportedLocale`, `onDeviceUnavailable`, `onDeviceFailed(error)`, `simple`.
- `RoutingMode` (на чат, default из настроек): `.auto`, `.onDevice`, `.cloud`.
- `CloudPolicy`: `.deny`, `.alwaysAsk`, `.alwaysAllow`.
- `ProviderKind`: `.openRouter`, `.mistral`, `.openAI`, `.groq`, `.custom` — шаблоны (base URL, capabilities).
- `ProviderCapabilities`: `supportsImages`, `supportsFileParts`, `supportsUsageInStream` — чтобы не слать
  OpenRouter-специфичные поля провайдерам, которые их не понимают.
- `KeychainStore` — хранение API-ключей (`kSecClassGenericPassword`, service = bundle id, account = provider id).
- `OnDeviceModelStatus` — обёртка над `SystemLanguageModel.default.availability` для UI.

### Роутер (Auto)

1. **Правила → облако** (с причиной):
   - есть **изображения** — всегда в облако (on-device vision/OCR ненадёжен: почерк, мелкий текст, детали);
     PDF/документы — если локальная модель не поддерживает тип;
   - оценка токенов истории + запроса > бюджета on-device (≈ 4096 всего, оставляем ~1000 на ответ);
   - язык запроса (`NLLanguageRecognizer`) не поддерживается `SystemLanguageModel.default.supportsLocale`;
   - on-device модель недоступна.
2. **Правила → локально**: очень короткие/тривиальные запросы (приветствие, «thanks», переформулируй/переведи
   короткий текст) — экономим вызов классификатора.
   Запросы на **действия на устройстве** (будильник, напоминание, звонок) не эскалируем: облачная модель их тоже
   не выполнит — локальная честно отвечает «не могу» (это прописано в её instructions).
3. **Классификатор** (on-device, guided generation, низкая temperature, короткие instructions, только последний
   запрос + 1–2 предыдущих реплики):
   ```swift
   @Generable struct RouteVerdict {
       @Guide(description: "true if a small offline model cannot answer well")
       var needsCloud: Bool
       var reason: Reason   // freshInformation | complexReasoning | code | longForm | simple
   }
   ```
4. **Политика** (`CloudPolicy`) применяется к итоговому решению «облако».
5. **Автоэскалация по ошибке**: `exceededContextWindowSize`, `guardrailViolation`, `unsupportedLanguageOrLocale`
   от локальной модели → повторный роутинг с `reason = .onDeviceFailed`, снова через политику.

Оценку качества локального ответа «задним числом» не делаем — ненадёжно. Вместо этого кнопка «Ask cloud».

### On-device бэкенд — детали

- Новая `LanguageModelSession` на каждый ход; история восстанавливается из БД (через `Transcript` либо
  компактный пересказ в `instructions`), с обрезкой по бюджету (последние N реплик, старые — выкидываются).
- `streamResponse` отдаёт накопительные снапшоты → считаем дельту относительно предыдущего снапшота и
  эмитим `LLMEvent.content`.
- Статистика: токены — оценка (`isEstimated = true`), длительность — как сейчас.
- Prewarm сессии (`session.prewarm()`) при открытии чата в режиме Auto/On-device.
- ⚠️ Перед реализацией сверить API с актуальной документацией (iOS 26/27: размер окна, поддержка изображений,
  `contextSize`, `Transcript` API).

### Хранилище — миграция `v8_routing`

> `v7_message_status_and_chat_model` (этап 0) уже добавила `messages.seq/status/error` и `chats.provider_id/model` —
> в v8 остаётся только то, что ниже и ещё не сделано.

```sql
-- messages
ALTER TABLE messages ADD COLUMN seq          INTEGER;            -- монотонный порядок внутри чата
ALTER TABLE messages ADD COLUMN backend      TEXT;               -- 'on_device' | 'cloud'
ALTER TABLE messages ADD COLUMN provider_id  TEXT;
ALTER TABLE messages ADD COLUMN model        TEXT;
ALTER TABLE messages ADD COLUMN route_reason TEXT;
ALTER TABLE messages ADD COLUMN status       TEXT NOT NULL DEFAULT 'done'; -- streaming|done|failed|cancelled
ALTER TABLE messages ADD COLUMN error        TEXT;
-- backfill seq по (created_at, rowid); индекс (chat_id, seq)

-- chats
ALTER TABLE chats ADD COLUMN routing_mode TEXT;   -- NULL = из настроек
ALTER TABLE chats ADD COLUMN provider_id  TEXT REFERENCES providers(id) ON DELETE SET NULL;
ALTER TABLE chats ADD COLUMN model        TEXT;

-- settings
ALTER TABLE settings ADD COLUMN routing_mode      TEXT NOT NULL DEFAULT 'auto';
ALTER TABLE settings ADD COLUMN cloud_policy      TEXT NOT NULL DEFAULT 'always_ask';
ALTER TABLE settings ADD COLUMN on_device_enabled INTEGER NOT NULL DEFAULT 1;
ALTER TABLE settings ADD COLUMN on_device_titles  INTEGER NOT NULL DEFAULT 1;
ALTER TABLE settings ADD COLUMN default_model     TEXT;

-- providers
ALTER TABLE providers ADD COLUMN kind TEXT NOT NULL DEFAULT 'custom';
-- api_key: перенос в Keychain, колонка очищается (оставляем пустой для совместимости)
```

---

## UI

### Композер

- Чип маршрута вместо `cpu model`:
  - `✦ Auto · <cloud model>` / `📱 On-device` / `☁️ <Provider> · <model>`.
- Тап → **Route sheet**:
  - сегмент `Auto | On-device | Cloud` (для текущего чата);
  - список облачных моделей (сгруппирован по провайдерам) с **поиском** и **избранным** — это модель для
    эскалации в Auto и основная в Cloud;
  - если on-device недоступна — сегмент On-device disabled с объяснением.
- Тоглов Web/Think нет (решение по web search: полагаемся на провайдера).

### Лента сообщений

- Футер ответа: бейдж `📱 On-device` или `☁️ OpenRouter · model`. Тап по бейджу → popover с причиной роутинга.
- У локальных ответов кнопка **«Ask cloud»** (перегенерировать этот ответ через облачную модель).
- Фазы стрима: `Choosing model…` (роутинг) → `Thinking…` → контент.
- **Consent card** (политика `alwaysAsk`): причина + `[Send to <Provider · model>]` `[Answer on-device]`
  + «Don't ask again in this chat».
- Сообщения со `status = failed` показывают ошибку (из БД) + `Retry` / `Ask cloud`.

### Настройки

1. **On-device model**
   - статус: Available / Device not eligible / Turn on Apple Intelligence (ссылка в Settings) / Model downloading;
   - тумблер «Use on-device model»;
   - Default mode: Auto / On-device / Cloud;
   - **Cloud policy**: Deny / Always ask / Always allow (с подписью, что это влияет только на автоматическую эскалацию);
   - «Generate chat titles on-device».
2. **Cloud providers**
   - «Add provider» → выбор шаблона (OpenRouter, Mistral, OpenAI, Groq, Custom) → предзаполненный URL;
   - ключ в Keychain; Test & Fetch Models; выбор default модели;
   - default provider + model для эскалации.
3. **Prompts** — system prompt, пресеты (CRUD), default preset.
4. Убрать нерабочий «Debug Mode (Headers)» (или реализовать позже).

---

## Этапы

### Этап 0 — Фундамент и баги ✅

- [x] `project.yml`: `deploymentTarget: "26.0"`, проект перегенерирован (XcodeGen).
- [x] **New Chat не открывался:** `Chat.Columns` брали имена из `CodingKeys` (camelCase), а колонки в БД snake_case →
      INSERT/ORDER BY падали молча. Колонки всех моделей теперь заданы явно.
- [x] **Вложения:** байты читаются с диска при сборке запроса (`fetchMessages(includeAttachmentData:)`).
- [x] **Regenerate:** `ChatService.regenerate` удаляет ответ и генерирует заново без повторной вставки user-сообщения.
- [x] **Гонка cancel/send:** каждый прогон имеет `token`; завершение старого прогона не трогает новый.
- [x] **Streaming state в сервисе:** `ChatService.runs` (`ChatRunState`), генерация в `ReplyJob` вне MainActor;
      `ChatView` только наблюдает. Уход из чата не прерывает и не теряет стрим.
- [x] **Статус и ошибки в БД:** `messages.status` (`streaming|done|failed|cancelled`) + `error`; прерванные при
      перезапуске стримы помечаются `failed`.
- [x] **Порядок сообщений:** `messages.seq` (миграция с backfill), `deleteMessagesFrom` по `seq`.
- [x] **Keychain** (`APIKeyStore` / `KeychainAPIKeyStore`, `AfterFirstUnlockThisDeviceOnly`); старые ключи
      автоматически переносятся из `providers.api_key`.
- [x] **Реактивность:** GRDB `ValueObservation` для списка чатов, чата, сообщений, провайдеров.
- [x] **Выбор модели на чат** сохраняется (`chats.provider_id`, `chats.model`).
- [x] **Вложения:** `AttachmentProcessor` — любой формат фото → JPEG ≤ 2048px, MIME через UTType;
      файлы удаляются вместе с чатом/сообщениями; PhotosPicker вынесен из `Menu` (там он не открывался).
- [x] Удалены `enableWebSearch` / `plugins` из `LLMRequest`.
- [x] Обработка mid-stream `{"error": …}` в SSE.
- [x] Перф: форматтеры через `Text(_:format:)`; при стриме Markdown перепарсивается только хвостовой блок
      (`StreamingMarkdownView`).
- Проверено в симуляторе на mock OpenAI-сервере: создание чата, стрим, автозаголовок, regenerate, ошибка
  провайдера, Stop, уход/возврат во время стрима, отправка HEIC-фото, удаление чата с файлами, миграция ключа.

### Этап 1 — Абстракция бэкендов и метаданные ✅

- [x] Протокол `ChatBackend` + `ChatTurn` + `BackendDescriptor`; `OpenAICompatibleBackend` поверх `LLMClient`.
      `ReplyJob` и `AutoTitlingService` работают только через `ChatBackend`.
- [x] `ProviderKind` (openrouter / openai / mistral / groq / custom) + `ProviderCapabilities`
      (`supportsImages`, `supportsFileParts`, `supportsStreamUsage`); kind выводится из base URL
      (при миграции и при сохранении провайдера). Явный выбор шаблона — этап 4.
- [x] `LLMRequest` учитывает capabilities: `stream_options` только где поддерживается; текстовые документы
      встраиваются как текст (работает у всех); бинарные файлы/картинки без поддержки → понятная ошибка до запроса.
- [x] Миграция `v8_routing`: `messages.backend/provider_id/model/route_reason`, `chats.routing_mode`,
      `settings.default_model/routing_mode/cloud_policy/on_device_enabled/on_device_titles`, `providers.kind`.
      Типы `BackendKind`, `RoutingMode`, `CloudPolicy`.
- [x] Метаданные пишутся в плейсхолдер ответа при старте генерации.
- [x] Бейдж бэкенда под ответом (`☁︎ Provider · model` / `On-device`).
- Проверено на mock-сервере: метаданные в БД, бейдж, отсутствие `stream_options` для `mistral`.
  Не проверено вживую: ветки вложений по capabilities (покрыть тестами на этапе 5).

### Этап 2 — On-device бэкенд ✅

- [x] Deployment target поднят до **iOS 27.2**: картинки (`Attachment`, 27.0) и файлы (`DataAttachmentRepresentable`, 27.2)
      на вход локальной модели, `LanguageModelError`, `contextSize`/`tokenCount`.
- [x] `OnDeviceModelStatus` (available / deviceNotEligible / appleIntelligenceNotEnabled / modelNotReady) + prewarm.
- [x] `AppleOnDeviceBackend`: сессия из `Transcript` на каждый ход; бюджет контекста через `tokenCount`
      (fallback-оценка, где он недоступен — например, Simulator), обрезка самых старых сообщений;
      snapshot→delta, reasoning из transcript entries, токены из `usage`; ошибки → `OnDeviceError`.
- [x] Пикер модели: «Apple Intelligence» (режим чата `on_device`); выбор облачной модели → `cloud`.
      Auto до роутера: облако, если выбран провайдер, иначе on-device.
- [x] Автозаголовки on-device (облако — только если сам ответ был облачным); служебные запросы без персоны
      (`ChatTurn.usesAssistantPersona`).
- [x] Instructions on-device явно перечисляют ограничения (нет интернета, нет действий на устройстве, нет памяти
      между чатами) + текущая дата; модель должна признавать неуверенность вместо выдумки.
- [x] Settings → «On-device model»: статус, «Use on-device model», «Generate chat titles on-device».
- Проверено на iPhone 16e (iOS 27.2): чат, стрим, фото, файл, Stop/Regenerate, автозаголовок.
  ⚠️ Simulator не поддерживает инференс Foundation Models (`operationNotAllowed: Simulator is not supported`) —
  on-device тестируем только на устройстве.

### Этап 3 — Роутер и политика облака

- [ ] `Router`: правила → классификатор (`@Generable RouteVerdict`) → `CloudPolicy`.
- [ ] Автоэскалация по ошибкам on-device.
- [ ] Consent card (`alwaysAsk`), поведение `deny` (локальный ответ + пометка), `alwaysAllow`.
- [ ] Кнопка «Ask cloud» под локальными ответами.
- [ ] Фаза `Choosing model…`; причина роутинга в popover бейджа.
- DoD: Auto-режим работает для всех трёх политик; причины видны пользователю.

### Этап 4 — UI и настройки

- [ ] Route sheet (сегмент режима + модели с поиском и избранным).
- [ ] Новая структура Settings (On-device / Cloud providers / Prompts).
- [ ] Шаблоны провайдеров в «Add provider».
- [ ] UI пресетов и system prompt.
- DoD: все возможности доступны из интерфейса, без мёртвых настроек.

### Этап 5 — Тесты

- [ ] Тестовый таргет в `project.yml`.
- [ ] Router (правила, политика, эскалация) с фейковым классификатором.
- [ ] Сборка запроса (`LLMRequest` encoding, capabilities), SSE-парсер (включая mid-stream error).
- [ ] Миграции (in-memory DB), `seq`/`deleteMessagesFrom`, Keychain-обёртка (через протокол).
- [ ] Фейковый `ChatBackend` для `ChatService`.

---

## Риски и открытые вопросы

- **Качество классификатора** 3B-модели: если будет ошибаться — сместить баланс в сторону правил,
  добавить few-shot примеры в instructions, логировать решения (debug-режим) для настройки.
- **Окно контекста ~4K**: длинные чаты в Auto будут почти всегда уходить в облако; позже можно добавить
  on-device саммари старой части истории.
- **Изображения на on-device**: зависят от версии iOS/API — проверить; до тех пор вложения → облако.
- **Различия провайдеров**: формат reasoning (`reasoning` / `reasoning_content`), `stream_options`, `file`-parts —
  закрываем через `ProviderCapabilities`, не через if-ы по имени провайдера.
