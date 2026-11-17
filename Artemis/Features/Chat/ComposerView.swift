import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

public struct ComposerView: View {
    @Binding public var text: String
    @Binding public var attachments: [Attachment]
    public let isBusy: Bool
    public let currentModel: String
    public let currentPresetTitle: String?
    public let onSend: () -> Void
    public let onStop: () -> Void
    public var onSelectModel: (() -> Void)?

    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var isShowingFileImporter: Bool = false
    @State private var isShowingPhotoPicker: Bool = false
    @FocusState private var isFocused: Bool

    public init(
        text: Binding<String>,
        attachments: Binding<[Attachment]>,
        isBusy: Bool,
        currentModel: String,
        currentPresetTitle: String? = nil,
        onSend: @escaping () -> Void,
        onStop: @escaping () -> Void,
        onSelectModel: (() -> Void)? = nil
    ) {
        self._text = text
        self._attachments = attachments
        self.isBusy = isBusy
        self.currentModel = currentModel
        self.currentPresetTitle = currentPresetTitle
        self.onSend = onSend
        self.onStop = onStop
        self.onSelectModel = onSelectModel
    }

    public var body: some View {
        VStack(spacing: 8) {
            // Model and Preset Info Strip
            HStack(spacing: 6) {
                Button {
                    onSelectModel?()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "cpu")
                            .font(.caption2)
                        Text(currentModel.isEmpty ? "Select model" : currentModel)
                            .font(.caption2.weight(.medium))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(Capsule())
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                if let preset = currentPresetTitle, !preset.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.caption2)
                        Text(preset)
                            .font(.caption2.weight(.medium))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(Capsule())
                    .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(.horizontal, 4)

            // Staged Attachments
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachments) { att in
                            AttachmentCardView(attachment: att) {
                                if let idx = attachments.firstIndex(where: { $0.id == att.id }) {
                                    attachments.remove(at: idx)
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }

            // Input Dock
            HStack(alignment: .bottom, spacing: 10) {
                // Attach menu (Photos / Files)
                Menu {
                    // A PhotosPicker nested in a Menu never presents; drive it from state instead.
                    Button {
                        isShowingPhotoPicker = true
                    } label: {
                        Label("Photo Library", systemImage: "photo.on.rectangle")
                    }

                    Button {
                        isShowingFileImporter = true
                    } label: {
                        Label("Files & Documents", systemImage: "doc")
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 4)

                // Text Field
                TextField("Ask anything…", text: $text, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($isFocused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(uiColor: .secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                // Send / Stop button
                if isBusy {
                    Button {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        onStop()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        onSend()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle((text.isEmpty && attachments.isEmpty) ? Color.secondary.opacity(0.3) : Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .disabled(text.isEmpty && attachments.isEmpty)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: Color.black.opacity(0.08), radius: 10, y: -2)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
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
        .onChange(of: selectedPhotoItems) { _, items in
            handlePhotoSelection(items)
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        Task {
            for url in urls {
                let attachment = await Task.detached(priority: .userInitiated) { () -> Attachment? in
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                    guard let data = try? Data(contentsOf: url) else { return nil }
                    return try? AttachmentProcessor.fileAttachment(from: data, filename: url.lastPathComponent)
                }.value
                if let attachment {
                    attachments.append(attachment)
                }
            }
        }
    }

    private func handlePhotoSelection(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        Task {
            for item in items {
                guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                let attachment = await Task.detached(priority: .userInitiated) {
                    try? AttachmentProcessor.imageAttachment(from: data)
                }.value
                if let attachment {
                    attachments.append(attachment)
                }
            }
            selectedPhotoItems.removeAll()
        }
    }
}
