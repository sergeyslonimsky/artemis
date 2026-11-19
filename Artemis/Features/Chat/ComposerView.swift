import PhotosUI
import SwiftUI

struct ComposerView: View {
    @Binding var text: String
    @Binding var attachments: [Attachment]
    var focus: FocusState<Bool>.Binding
    let isBusy: Bool
    var currentPresetTitle: String?
    let onSend: () -> Void
    let onStop: () -> Void
    /// Called when the text field gains focus (a cue that a request is coming).
    var onFocus: () -> Void = {}
    /// Opens voice mode; shown in place of Send while there's nothing to send.
    var onVoice: (() -> Void)?

    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var isShowingFileImporter = false
    @State private var isShowingPhotoPicker = false
    @State private var isShowingCamera = false
    @State private var isShowingScanner = false
    @State private var dictation = Dictation()
    @State private var dictationError: String?
    /// Bumped by the send, stop and voice buttons for their haptic.
    @State private var primaryTaps = 0
    @State private var attachmentError: String?

    /// Every control in the field is this tall, and so is a single line of text: they line up
    /// whether the field holds one line or several (then they stay at the bottom).
    private static let controlSide: CGFloat = 36
    private static let fieldPadding: CGFloat = 5
    /// The attach button matches a one-line field, padding included.
    private static let attachSide = controlSide + 2 * fieldPadding

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(alignment: .bottom, spacing: 10) {
                attachMenu
                field
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .fileImporter(
            isPresented: $isShowingFileImporter,
            allowedContentTypes: [.pdf, .text, .image, .data],
            allowsMultipleSelection: true
        ) { result in
            handleFileImport(result)
        }
        .photosPicker(
            isPresented: $isShowingPhotoPicker,
            selection: $selectedPhotoItems,
            maxSelectionCount: 5,
            matching: .images
        )
        .fullScreenCover(isPresented: $isShowingCamera) {
            CameraPicker(onCapture: handleCameraPhoto)
                .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $isShowingScanner) {
            DocumentScanner(onScan: handleScannedPages)
                .ignoresSafeArea()
        }
        .onChange(of: focus.wrappedValue) { _, focused in
            if focused { onFocus() }
        }
        .onChange(of: selectedPhotoItems) { _, items in
            handlePhotoSelection(items)
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: primaryTaps)
        .sensoryFeedback(trigger: attachments.count) { old, new in
            new < old ? .impact(weight: .light) : nil
        }
        .errorAlert("Couldn't attach", message: $attachmentError)
    }

    /// The text field with attachments, the preset in use, dictation and the send button.
    private var field: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(attachments) { attachment in
                            AttachmentCardView(attachment: attachment, compact: true) {
                                attachments.removeAll { $0.id == attachment.id }
                            }
                        }
                    }
                    .padding([.top, .horizontal], 4)
                }
                .scrollIndicators(.hidden)
            }

            if let preset = currentPresetTitle, !preset.isEmpty {
                Label(preset, systemImage: "slider.horizontal.3")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.12), in: .capsule)
                    .padding([.top, .leading], 4)
            }

            HStack(alignment: .bottom, spacing: 4) {
                TextField(dictation.isActive ? "Listening…" : "Ask anything", text: $text, axis: .vertical)
                    .lineLimit(1...8)
                    .focused(focus)
                    .padding(.leading, 10)
                    .padding(.vertical, 6)
                    .frame(minHeight: Self.controlSide)
                    // Typing while dictating would be overwritten by the next recognized words.
                    .disabled(dictation.isActive)

                if !isBusy {
                    dictationButton
                }
                primaryButton
            }
        }
        .padding(Self.fieldPadding)
        .glassEffect(.regular, in: .rect(cornerRadius: 23, style: .continuous))
        .contentShape(.rect)
        .onTapGesture { focus.wrappedValue = true }
    }

    // MARK: - Attach

    private var attachMenu: some View {
        Menu {
            if CameraPicker.isAvailable {
                Button("Camera", systemImage: "camera") { isShowingCamera = true }
            }
            if DocumentScanner.isAvailable {
                Button("Scan Document", systemImage: "doc.viewfinder") { isShowingScanner = true }
            }
            // A PhotosPicker nested in a Menu never presents; drive it from state instead.
            Button("Photos", systemImage: "photo.on.rectangle") { isShowingPhotoPicker = true }
            Button("Files", systemImage: "doc") { isShowingFileImporter = true }
        } label: {
            Image(systemName: "plus")
                .font(.title3.weight(.medium))
                .foregroundStyle(.primary)
                .frame(width: Self.attachSide, height: Self.attachSide)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Attach")
    }

    // MARK: - Dictation

    private var dictationButton: some View {
        Button {
            toggleDictation()
        } label: {
            ZStack {
                if dictation.isActive {
                    Circle()
                        .fill(Color.accentColor.opacity(0.18))
                        .scaleEffect(1 + CGFloat(dictation.level) * 0.5)
                        .animation(.easeOut(duration: 0.1), value: dictation.level)
                }
                Image(systemName: dictation.isActive ? "stop.fill" : "mic")
                    .font(.system(size: dictation.isActive ? 13 : 17, weight: .semibold))
                    .foregroundStyle(dictation.isActive ? Color.accentColor : Color.primary)
            }
            .frame(width: Self.controlSide, height: Self.controlSide)
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(dictation.isActive ? "Stop dictation" : "Dictate")
        .sensoryFeedback(.impact(weight: .light), trigger: dictation.isActive)
        .alert(
            "Dictation isn't available",
            isPresented: Binding(get: { dictationError != nil }, set: { if !$0 { dictationError = nil } }),
            presenting: dictationError
        ) { _ in
            if VoicePreferences.isMicrophoneDenied {
                OpenSettingsButton()
            }
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
        .onChange(of: dictation.state) { _, state in
            if case .failed(let message) = state { dictationError = message }
        }
        .onDisappear {
            Task { await dictation.stop() }
        }
    }

    private func toggleDictation() {
        if dictation.isActive {
            Task { await dictation.stop() }
            return
        }
        // Recognized words go after what's already typed.
        let base = text.trimmingCharacters(in: .whitespacesAndNewlines)
        focus.wrappedValue = false
        Task {
            await dictation.start { recognized in
                text = [base, recognized].filter { !$0.isEmpty }.joined(separator: " ")
            }
        }
    }

    // MARK: - Send, stop, voice

    @ViewBuilder
    private var primaryButton: some View {
        if isBusy {
            primaryCircle("Stop", systemImage: "stop.fill", glyphSize: 13) {
                onStop()
            }
        } else if !canSend, !dictation.isActive, let onVoice {
            primaryCircle("Voice mode", systemImage: "waveform") {
                onVoice()
            }
        } else {
            primaryCircle("Send", systemImage: "arrow.up", isEnabled: canSend) {
                send()
            }
        }
    }

    /// A tinted glass circle of the field's control size; dimmed and inert when disabled.
    private func primaryCircle(
        _ title: LocalizedStringKey,
        systemImage: String,
        glyphSize: CGFloat = 16,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            primaryTaps += 1
            action()
        } label: {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(.system(size: glyphSize, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: Self.controlSide, height: Self.controlSide)
                .glassEffect(.regular.tint(isEnabled ? .accentColor : .secondary.opacity(0.5)).interactive(isEnabled), in: .circle)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }

    /// Sends what's in the field, finishing dictation first so its last words are included.
    private func send() {
        guard dictation.isActive else {
            onSend()
            return
        }
        Task {
            await dictation.stop()
            onSend()
        }
    }

    // MARK: - Attachments

    private func handleFileImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        addAttachments(from: urls) { try await AttachmentProcessor.attachment(fromFileAt: $0) }
    }

    private func handleCameraPhoto(_ image: UIImage) {
        addAttachments(from: [image]) { try await AttachmentProcessor.attachment(fromPhoto: $0) }
    }

    /// Each page becomes its own image: models read the text on it (on-device through OCR).
    private func handleScannedPages(_ pages: [UIImage]) {
        let numbered = Array(pages.enumerated())
        addAttachments(from: numbered) { index, page in
            let name = numbered.count == 1 ? "scan.jpg" : "scan-\(index + 1).jpg"
            var attachment = try await AttachmentProcessor.attachment(fromPhoto: page, filename: name)
            attachment.isScan = true
            return attachment
        }
    }

    private func handlePhotoSelection(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        selectedPhotoItems.removeAll()
        addAttachments(from: items) { item in
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw AttachmentProcessor.ProcessingError.unreadableImage
            }
            return try await AttachmentProcessor.attachment(fromImageData: data)
        }
    }

    /// Converts each source in order; a failure is reported and the rest still attach.
    private func addAttachments<Source: Sendable>(from sources: [Source], _ convert: @escaping (Source) async throws -> Attachment) {
        Task {
            for source in sources {
                do {
                    attachments.append(try await convert(source))
                } catch {
                    attachmentError = error.localizedDescription
                }
            }
        }
    }
}
