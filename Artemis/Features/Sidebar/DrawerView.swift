import SwiftUI
import os

/// Chat history, search and settings, shown in the slide-in drawer.
public struct DrawerView: View {
    public let selectedChatId: String
    public var onSelectChat: (String) -> Void
    public var onNewChat: () -> Void
    public var onDeleteChat: (String) -> Void
    public var onOpenSettings: () -> Void

    @State private var chats: [Chat] = []
    @State private var searchQuery: String = ""
    @State private var searchHits: [SearchHit] = []
    @State private var chatToRename: Chat?
    @State private var renameText: String = ""

    private let database = AppDatabase.shared
    private let chatService = ChatService.shared
    private static let logger = Logger(subsystem: "com.artemis.ios", category: "DrawerView")

    public init(
        selectedChatId: String,
        onSelectChat: @escaping (String) -> Void,
        onNewChat: @escaping () -> Void,
        onDeleteChat: @escaping (String) -> Void,
        onOpenSettings: @escaping () -> Void
    ) {
        self.selectedChatId = selectedChatId
        self.onSelectChat = onSelectChat
        self.onNewChat = onNewChat
        self.onDeleteChat = onDeleteChat
        self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)

            List {
                if searchQuery.isEmpty {
                    newChatRow
                    ForEach(groupedChats, id: \.title) { group in
                        // Plain rows rather than section headers: those add tall, sticky spacing.
                        Text(group.title)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 14, leading: 20, bottom: 2, trailing: 20))
                        ForEach(group.chats) { chat in
                            chatRow(chat)
                        }
                    }
                } else {
                    ForEach(searchHits) { hit in
                        chatRow(hit.chat, snippet: hit.snippet)
                    }
                    if searchHits.isEmpty {
                        Text("No matches")
                            .foregroundStyle(.secondary)
                            .listRowSeparator(.hidden)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 40)

            Divider()
            settingsButton
        }
        .background(Color(uiColor: .systemBackground))
        .task { await observeChats() }
        .onChange(of: searchQuery) { _, query in
            performSearch(query)
        }
        .alert("Rename Chat", isPresented: Binding(get: { chatToRename != nil }, set: { if !$0 { chatToRename = nil } })) {
            TextField("Chat title", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                if let chat = chatToRename, !renameText.trimmingCharacters(in: .whitespaces).isEmpty {
                    try? database.renameChat(chatId: chat.id, title: renameText)
                }
            }
        }
    }

    // MARK: - Pieces

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search", text: $searchQuery)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
    }

    private var newChatRow: some View {
        Button(action: onNewChat) {
            Label("New chat", systemImage: "square.and.pencil")
                .font(.body.weight(.medium))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
    }

    private func chatRow(_ chat: Chat, snippet: String = "") -> some View {
        let isSelected = chat.id == selectedChatId
        return Button {
            onSelectChat(chat.id)
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(chat.title)
                        .font(.body)
                        .foregroundStyle(.primary)
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
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? Color.secondary.opacity(0.15) : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
        .contextMenu {
            Button {
                renameText = chat.title
                chatToRename = chat
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button(role: .destructive) {
                deleteChat(chat)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                deleteChat(chat)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var settingsButton: some View {
        Button(action: onOpenSettings) {
            HStack(spacing: 12) {
                Image(systemName: "gearshape")
                    .font(.body.weight(.medium))
                    .frame(width: 32, height: 32)
                    .background(Color(uiColor: .secondarySystemBackground), in: Circle())
                Text("Settings")
                    .font(.body.weight(.medium))
                Spacer()
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                if !searchQuery.isEmpty {
                    performSearch(searchQuery)
                }
            }
        } catch {
            Self.logger.error("Chats observation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func deleteChat(_ chat: Chat) {
        chatService.cancel(chatId: chat.id)
        do {
            try database.deleteChat(id: chat.id)
        } catch {
            Self.logger.error("Failed to delete chat: \(error.localizedDescription, privacy: .public)")
        }
        onDeleteChat(chat.id)
    }

    private func performSearch(_ query: String) {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            searchHits = []
            return
        }
        searchHits = (try? database.search(query: query)) ?? []
    }
}
