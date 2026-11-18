import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

public struct ComposerView: View {
    @Binding public var text: String
    @Binding public var attachments: [Attachment]
    public let isBusy: Bool
    public let currentPresetTitle: String?
    public let onSend: () -> Void
    public let onStop: () -> Void
    /// Called when the text field gains focus (a cue that a request is coming).
    public var onFocus: (() -> Void)?

    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var isShowingFileImporter: Bool = false
    @State private var isShowingPhotoPicker: Bool = false
    @State private var isShowingCamera: Bool = false
    @FocusState private var isFocused: Bool

    public init(
        text: Binding<String>,
        attachments: Binding<[Attachment]>,
        isBusy: Bool,
        currentPresetTitle: String? = nil,
        onSend: @escaping () -> Void,
        onStop: @escaping () -> Void,
        onFocus: (() -> Void)? = nil
    ) {
        self._text = text
        self._attachments = attachments
        self.isBusy = isBusy
        self.currentPresetTitle = currentPresetTitle
        self.onSend = onSend
        self.onStop = onStop
        self.onFocus = onFocus
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachments) { att in
                            AttachmentCardView(attachment: att, compact: true) {
                                attachments.removeAll { $0.id == att.id }
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            }
                        }
                    }
                }
            }

            TextField("Ask anything", text: $text, axis: .vertical)
                .lineLimit(1...8)
                .focused($isFocused)
                .padding(.horizontal, 4)

            HStack(spacing: 8) {
                attachMenu

                if let preset = currentPresetTitle, !preset.isEmpty {
                    Label(preset, systemImage: "slider.horizontal.3")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }

                Spacer()

                sendButton
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06))
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
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
        .onChange(of: isFocused) { _, focused in
            if focused { onFocus?() }
        }
        .onChange(of: selectedPhotoItems) { _, items in
            handlePhotoSelection(items)
        }
    }

    private var attachMenu: some View {
        Menu {
            if CameraPicker.isAvailable {
                Button {
                    isShowingCamera = true
                } label: {
                    Label("Camera", systemImage: "camera")
                }
            }
            // A PhotosPicker nested in a Menu never presents; drive it from state instead.
            Button {
                isShowingPhotoPicker = true
            } label: {
                Label("Photos", systemImage: "photo.on.rectangle")
            }
            Button {
                isShowingFileImporter = true
            } label: {
                Label("Files", systemImage: "doc")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 34, height: 34)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.15)))
        }
        .tint(.primary)
        .accessibilityLabel("Attach")
    }

    @ViewBuilder
    private var sendButton: some View {
        if isBusy {
            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                onStop()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color(uiColor: .systemBackground))
                    .frame(width: 34, height: 34)
                    .background(Color.primary, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop")
        } else {
            Button {
                guard canSend else { return }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                onSend()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color(uiColor: .systemBackground))
                    .frame(width: 34, height: 34)
                    .background(canSend ? Color.primary : Color.secondary.opacity(0.35), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel("Send")
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

    private func handleCameraPhoto(_ image: UIImage) {
        Task {
            let attachment = await Task.detached(priority: .userInitiated) { () -> Attachment? in
                guard let data = image.jpegData(compressionQuality: 0.9) else { return nil }
                return try? AttachmentProcessor.imageAttachment(from: data, filename: "photo")
            }.value
            if let attachment {
                attachments.append(attachment)
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
