import SwiftUI

/// The share sheet's Artemis panel: what was shared and what to do with it.
struct ShareView: View {
    @Bindable var model: ShareModel
    let onRequest: (ShareRequest) -> Void
    let onCancel: () -> Void
    let onDone: () -> Void

    @FocusState private var isQuestionFocused: Bool

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Artemis")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        if model.phase == .saved {
                            Button("Done", action: onDone)
                        } else {
                            Button("Cancel", role: .cancel, action: onCancel)
                        }
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView("Preparing…")
        case .failed(let message):
            ContentUnavailableView("Can't Share This", systemImage: "exclamationmark.triangle", description: Text(message))
        case .saved:
            ContentUnavailableView(
                "Ready in Artemis",
                systemImage: "checkmark.circle",
                description: Text("Open Artemis to see the reply.")
            )
        case .ready, .opening:
            choices
        }
    }

    private var choices: some View {
        List {
            Section {
                Label(model.summary, systemImage: model.summarySymbol)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Section {
                ForEach(ShareAction.allCases) { action in
                    Button(action.title, systemImage: action.systemImage) {
                        onRequest(.action(action))
                    }
                }
            }

            Section("Ask About It") {
                HStack(alignment: .bottom) {
                    TextField("Ask anything", text: $model.question, axis: .vertical)
                        .lineLimit(1...5)
                        .focused($isQuestionFocused)
                        .submitLabel(.send)
                        .onSubmit(askQuestion)
                    Button("Send", systemImage: "arrow.up.circle.fill", action: askQuestion)
                        .labelStyle(.iconOnly)
                        .font(.title2)
                        .disabled(trimmedQuestion.isEmpty)
                }
            }

            Section {
                Button("Open in Artemis", systemImage: "arrow.up.forward.app") {
                    onRequest(.attachOnly)
                }
            } footer: {
                Text("Adds it to a new chat without sending anything.")
            }
        }
        .disabled(model.phase == .opening)
    }

    private var trimmedQuestion: String {
        model.question.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func askQuestion() {
        guard !trimmedQuestion.isEmpty else { return }
        onRequest(.question(trimmedQuestion))
    }
}
