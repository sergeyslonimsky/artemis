import SwiftUI

struct ContentView: View {
    @State private var selectedChatId: String?
    @State private var showingSettings: Bool = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    private let database = AppDatabase.shared

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selectedChatId: $selectedChatId) {
                showingSettings = true
            }
        } detail: {
            if let chatId = selectedChatId {
                ChatView(chatId: chatId)
                    .id(chatId)
            } else {
                emptyStateView
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .onAppear {
            ensureInitialChat()
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

    private func ensureInitialChat() {
        if let first = try? database.fetchChats().first {
            selectedChatId = first.id
        }
    }
}

#Preview {
    ContentView()
}
