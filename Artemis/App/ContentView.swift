import AppIntents
import os
import SwiftUI

/// Root: the current chat with the chat list. On iPhone the list is a drawer that slides in from
/// the left; with room for both (iPad, wide windows) it is a sidebar next to the chat.
struct ContentView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    /// A fresh id is a draft: the chat is only stored once its first message is sent.
    @State private var chatId = ContentView.newChatId()
    @State private var isDrawerOpen = false
    @State private var showingSettings = false
    @GestureState private var dragTranslation: CGFloat = 0
    @FocusState private var isComposerFocused: Bool
    /// Bumped when the user starts a new chat, for its haptic.
    @State private var newChatCount = 0
    /// How the current chat was opened from outside the app (Siri, Shortcuts, the share sheet…);
    /// cleared once the chat applied it, so it never runs twice.
    @State private var launch: ChatLaunch?
    /// Shared items already opened: the URL and the fallback check can both report the same one.
    @State private var handledSharedIds: Set<String> = []
    private static let logger = Logger(subsystem: "com.artemis.ios", category: "Launch")

    private static func newChatId() -> String {
        UUID().uuidString.lowercased()
    }

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                splitLayout
            } else {
                drawerLayout
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .sensoryFeedback(.impact(weight: .light), trigger: newChatCount)
        .onAppIntentExecution(AskArtemisIntent.self) { intent in
            open(ChatLaunch(chatId: Self.newChatId(), prompt: intent.question, autoSend: true))
        }
        .onAppIntentExecution(NewChatIntent.self) { _ in
            open(ChatLaunch(chatId: Self.newChatId(), focusComposer: true))
        }
        .onAppIntentExecution(VoiceModeIntent.self) { _ in
            open(ChatLaunch(chatId: Self.newChatId(), voice: true))
        }
        .onOpenURL { url in
            if let id = SharedInbox.itemId(in: url) { openSharedItem(id) }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            // The share extension couldn't open the app; the user opened it soon after.
            if phase == .active, let id = SharedInbox.latestItemId(maxAge: Self.sharedItemLifetime) {
                openSharedItem(id)
            }
        }
        .task { await SharedInbox.removeItems(olderThan: Self.sharedItemLifetime) }
    }

    /// How long a shared item waits for the app to be opened.
    private static let sharedItemLifetime: TimeInterval = 10 * 60

    private var splitLayout: some View {
        NavigationSplitView {
            chatList
        } detail: {
            NavigationStack {
                chatView(onOpenDrawer: nil)
            }
        }
    }

    private func chatView(onOpenDrawer: (() -> Void)?) -> some View {
        ChatView(
            chatId: chatId,
            launch: launch?.chatId == chatId ? launch : nil,
            onLaunchApplied: { launch = nil },
            composerFocus: $isComposerFocused,
            onOpenDrawer: onOpenDrawer,
            onNewChat: startNewChat
        )
        .id(chatId)
    }

    private var chatList: some View {
        DrawerView(
            selectedChatId: chatId,
            onSelectChat: { id in
                chatId = id
                setDrawer(open: false)
            },
            onNewChat: startNewChat,
            onDeleteChat: { id in
                if id == chatId { chatId = Self.newChatId() }
            },
            onOpenSettings: { showingSettings = true }
        )
    }

    private var drawerLayout: some View {
        GeometryReader { geometry in
            let drawerWidth = min(geometry.size.width * 0.82, 340)
            let progress = drawerProgress(width: drawerWidth)

            ZStack(alignment: .leading) {
                NavigationStack {
                    chatView(onOpenDrawer: { setDrawer(open: true) })
                }
                .overlay {
                    Color.black
                        .opacity(0.25 * progress)
                        .ignoresSafeArea()
                        .allowsHitTesting(isDrawerOpen)
                        .onTapGesture { setDrawer(open: false) }
                }
                .overlay(alignment: .leading) {
                    // Edge strip to swipe the drawer open without fighting the chat's scrolling.
                    Color.clear
                        .frame(width: 24)
                        .contentShape(.rect)
                        .gesture(dragGesture(width: drawerWidth))
                        .allowsHitTesting(!isDrawerOpen)
                }
                .offset(x: progress * drawerWidth)

                NavigationStack {
                    chatList
                }
                .frame(width: drawerWidth)
                .overlay(alignment: .trailing) {
                    // The scrim is invisible on black in dark mode; the edge keeps the drawer distinct.
                    Rectangle()
                        .fill(Color.primary.opacity(0.12))
                        .frame(width: 0.5)
                        .ignoresSafeArea()
                }
                .shadow(color: .black.opacity(0.15 * progress), radius: 12, x: 4)
                .offset(x: (progress - 1) * drawerWidth)
                .gesture(dragGesture(width: drawerWidth))
                .accessibilityHidden(!isDrawerOpen)
            }
        }
    }

    private func drawerProgress(width: CGFloat) -> CGFloat {
        let base: CGFloat = isDrawerOpen ? 1 : 0
        return min(max(base + dragTranslation / width, 0), 1)
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .updating($dragTranslation) { value, state, _ in
                state = value.translation.width
            }
            .onEnded { value in
                let predicted = (isDrawerOpen ? width : 0) + value.predictedEndTranslation.width
                setDrawer(open: predicted > width / 2)
            }
    }

    private func setDrawer(open: Bool) {
        if open {
            isComposerFocused = false
        }
        withAnimation(.snappy(duration: 0.3)) {
            isDrawerOpen = open
        }
    }

    private func startNewChat() {
        chatId = Self.newChatId()
        setDrawer(open: false)
        newChatCount += 1
    }

    // MARK: - Launches from outside the app

    /// Its files are converted first; if the user moved on meanwhile (another chat, another
    /// launch), the item is dropped rather than replacing what they're looking at.
    private func openSharedItem(_ id: String) {
        guard handledSharedIds.insert(id).inserted else { return }
        let startingChatId = chatId
        Task {
            do {
                let shared = try await SharedInbox.takeLaunch(id: id, chatId: Self.newChatId())
                if chatId == startingChatId { open(shared) }
            } catch {
                Self.logger.error("Opening a shared item failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func open(_ newLaunch: ChatLaunch) {
        showingSettings = false
        launch = newLaunch
        chatId = newLaunch.chatId
        setDrawer(open: false)
    }
}

#Preview {
    ContentView()
        .environment(\.database, .inMemory())
}
