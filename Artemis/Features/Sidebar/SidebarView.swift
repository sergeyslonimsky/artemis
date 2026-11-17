import SwiftUI

public struct SidebarView: View {
    @Binding public var selectedChatId: String?
    public var onOpenSettings: () -> Void

    @State private var chats: [Chat] = []
    @State private var searchQuery: String = ""
    @State private var searchHits: [SearchHit] = []
    @State private var isSearching: Bool = false
    @State private var chatToRename: Chat?
    @State private var renameText: String = ""
    @State private var showingRenameAlert: Bool = false

    private let database = AppDatabase.shared
    private let chatService = ChatService.shared

    public init(selectedChatId: Binding<String?>, onOpenSettings: @escaping () -> Void) {
        self._selectedChatId = selectedChatId
        self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
        List(selection: $selectedChatId) {
            if !searchQuery.isEmpty {
                Section("Search Results") {
                    ForEach(searchHits) { hit in
                        NavigationLink(value: hit.chat.id) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(hit.chat.title)
                                    .font(.headline)
                                    .lineLimit(1)
                                if !hit.snippet.isEmpty {
                                    Text(hit.snippet)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            } else {
                Section {
                    ForEach(chats) { chat in
                        NavigationLink(value: chat.id) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(chat.title)
                                        .font(.body)
                                        .lineLimit(1)

                                    Text(timeAgo(chat.updatedAt))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }

                                Spacer()

                                if chatService.isRunning(chatId: chat.id) {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                deleteChat(chat)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .contextMenu {
                            Button {
                                chatToRename = chat
                                renameText = chat.title
                                showingRenameAlert = true
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }

                            Button(role: .destructive) {
                                deleteChat(chat)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $searchQuery, prompt: "Search conversations…")
        .onChange(of: searchQuery) { _, query in
            performSearch(query)
        }
        .navigationTitle("Chats")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: createNewChat) {
                    Image(systemName: "square.and.pencil")
                }
            }
        }
        .alert("Rename Chat", isPresented: $showingRenameAlert) {
            TextField("Chat Title", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                if let chat = chatToRename, !renameText.isEmpty {
                    try? database.renameChat(chatId: chat.id, title: renameText)
                    loadChats()
                }
            }
        }
        .onAppear {
            loadChats()
        }
    }

    private func loadChats() {
        chats = (try? database.fetchChats()) ?? []
    }

    private func createNewChat() {
        do {
            let newChat = try database.createChat(title: "New Chat", source: .placeholder)
            loadChats()
            selectedChatId = newChat.id
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        } catch {
            print("Failed to create chat: \(error)")
        }
    }

    private func deleteChat(_ chat: Chat) {
        try? database.deleteChat(id: chat.id)
        if selectedChatId == chat.id {
            selectedChatId = nil
        }
        loadChats()
    }

    private func performSearch(_ query: String) {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            searchHits = []
            return
        }
        searchHits = (try? database.search(query: query)) ?? []
    }

    private func timeAgo(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
