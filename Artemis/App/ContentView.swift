import SwiftUI

struct ContentView: View {
    @State private var navigationPath = [String]()
    @State private var selectedChatId: String?
    @State private var showingSettings: Bool = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private let database = AppDatabase.shared

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                // iPad / Mac: Split View
                NavigationSplitView {
                    SidebarView(
                        selectedChatId: $selectedChatId,
                        onOpenSettings: { showingSettings = true },
                        onSelectChat: { id in
                            selectedChatId = id
                        }
                    )
                } detail: {
                    if let chatId = selectedChatId {
                        ChatView(chatId: chatId)
                            .id(chatId)
                    } else {
                        emptyStateView
                    }
                }
            } else {
                // iPhone: NavigationStack
                NavigationStack(path: $navigationPath) {
                    SidebarView(
                        selectedChatId: $selectedChatId,
                        onOpenSettings: { showingSettings = true },
                        onSelectChat: { id in
                            navigationPath.append(id)
                        }
                    )
                    .navigationDestination(for: String.self) { chatId in
                        ChatView(chatId: chatId)
                            .id(chatId)
                    }
                }
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles")
                .font(.system(size: 56))
                .foregroundStyle(.tint)

            Text("Artemis")
                .font(.largeTitle.bold())

            Text("Fast, elegant AI chat client")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button {
                if let newChat = try? database.createChat(title: "New Chat") {
                    selectedChatId = newChat.id
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
            } label: {
                Label("Start a conversation", systemImage: "plus")
                    .font(.body.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 8)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
