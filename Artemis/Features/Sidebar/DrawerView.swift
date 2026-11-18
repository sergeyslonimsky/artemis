import SwiftUI
import os

/// Chat history, search and settings, shown in the slide-in drawer.
struct DrawerView: View {
    let selectedChatId: String
    var onSelectChat: (String) -> Void
    var onNewChat: () -> Void
    var onDeleteChat: (String) -> Void
    var onOpenSettings: () -> Void

    @State private var chats: [Chat] = []
    @State private var searchQuery = ""
    @State private var searchHits: [SearchHit] = []
    @State private var chatToRename: Chat?
    @State private var renameText = ""
    @State private var errorMessage: String?

    @Environment(\.database) private var database
    private let chatService = ChatService.shared
    private static let logger = Logger(subsystem: "com.artemis.ios", category: "DrawerView")

    /// Tapping a row selects its chat; the list highlights the open one.
    private var selection: Binding<String?> {
        Binding(get: { selectedChatId }, set: { id in
            if let id { onSelectChat(id) }
        })
    }

    private var isSearching: Bool {
        !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Lives in a navigation container: the drawer's stack on iPhone, the split view's sidebar on iPad.
    var body: some View {
        List(selection: selection) {
            if isSearching {
                ForEach(searchHits) { hit in
                    chatRow(hit.chat, snippet: hit.snippet)
                }
            } else {
                ForEach(groupedChats, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.chats) { chat in
                            chatRow(chat)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if isSearching && searchHits.isEmpty {
                ContentUnavailableView.search(text: searchQuery)
            } else if !isSearching && chats.isEmpty {
                ContentUnavailableView("No Chats Yet", systemImage: "bubble.left.and.bubble.right",
                                       description: Text("Your conversations will appear here."))
            }
        }
        .navigationTitle("Chats")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchQuery, placement: .navigationBarDrawer(displayMode: .always))
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("New chat", systemImage: "square.and.pencil", action: onNewChat)
            }
            ToolbarItem(placement: .bottomBar) {
                Button("Settings", systemImage: "gearshape", action: onOpenSettings)
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
        }
        .task { await observeChats() }
        .task(id: searchQuery) { await search() }
        .alert("Rename Chat", isPresented: Binding(get: { chatToRename != nil }, set: { if !$0 { chatToRename = nil } }), presenting: chatToRename) { chat in
            TextField("Chat title", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Save") { rename(chat) }
        }
        .errorAlert("Something went wrong", message: $errorMessage)
    }

    // MARK: - Pieces

    private func chatRow(_ chat: Chat, snippet: String = "") -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(chat.title)
                    .lineLimit(1)
                if !snippet.isEmpty {
                    Text(snippet)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if chatService.isRunning(chatId: chat.id) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Answering")
            }
        }
        .tag(chat.id)
        .contextMenu {
            Button("Rename", systemImage: "pencil") {
                renameText = chat.title
                chatToRename = chat
            }
            Button("Delete", systemImage: "trash", role: .destructive) { deleteChat(chat) }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button("Delete", systemImage: "trash", role: .destructive) { deleteChat(chat) }
        }
    }

    // MARK: - Data

    private struct ChatGroup {
        let title: String
        let chats: [Chat]
    }

    /// Today / Yesterday / Previous 7 Days / Previous 30 Days, then by month.
    private var groupedChats: [ChatGroup] {
        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)

        func bucket(for date: Date) -> String {
            if date >= startOfToday { return "Today" }
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: startOfToday).day ?? 0
            switch days {
            case 1: return "Yesterday"
            case 2...7: return "Previous 7 Days"
            case 8...30: return "Previous 30 Days"
            default: return date.formatted(.dateTime.month(.wide).year())
            }
        }

        var groups: [ChatGroup] = []
        for chat in chats {
            let title = bucket(for: chat.updatedAt)
            if let last = groups.last, last.title == title {
                groups[groups.count - 1] = ChatGroup(title: title, chats: last.chats + [chat])
            } else {
                groups.append(ChatGroup(title: title, chats: [chat]))
            }
        }
        return groups
    }

    private func observeChats() async {
        do {
            for try await value in database.observeChats() {
                chats = value
                if isSearching { await search(debounce: false) }
            }
        } catch {
            Self.logger.error("Chats observation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Full-text search after a short pause in typing, off the main thread.
    private func search(debounce: Bool = true) async {
        let query = searchQuery
        guard isSearching else {
            searchHits = []
            return
        }
        if debounce {
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
        }
        let database = database
        let hits = await Task.detached(priority: .userInitiated) {
            (try? database.search(query: query)) ?? []
        }.value
        guard !Task.isCancelled, query == searchQuery else { return }
        searchHits = hits
    }

    private func rename(_ chat: Chat) {
        let title = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        do {
            try database.renameChat(chatId: chat.id, title: title)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteChat(_ chat: Chat) {
        chatService.cancel(chatId: chat.id)
        do {
            try database.deleteChat(id: chat.id)
            onDeleteChat(chat.id)
        } catch {
            Self.logger.error("Failed to delete chat: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }
}
