import SwiftUI

/// Root: the current chat with a history drawer that slides in from the left.
struct ContentView: View {
    /// A fresh id is a draft: the chat is only stored once its first message is sent.
    @State private var chatId = ContentView.newChatId()
    @State private var isDrawerOpen = false
    @State private var showingSettings = false
    @GestureState private var dragTranslation: CGFloat = 0

    private static func newChatId() -> String {
        UUID().uuidString.lowercased()
    }

    var body: some View {
        GeometryReader { geometry in
            let drawerWidth = min(geometry.size.width * 0.82, 340)
            let progress = drawerProgress(width: drawerWidth)

            ZStack(alignment: .leading) {
                NavigationStack {
                    ChatView(
                        chatId: chatId,
                        onOpenDrawer: { setDrawer(open: true) },
                        onNewChat: startNewChat
                    )
                    .id(chatId)
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
                        .contentShape(Rectangle())
                        .gesture(dragGesture(width: drawerWidth))
                        .allowsHitTesting(!isDrawerOpen)
                }
                .offset(x: progress * drawerWidth)

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
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
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
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        withAnimation(.snappy(duration: 0.3)) {
            isDrawerOpen = open
        }
    }

    private func startNewChat() {
        chatId = Self.newChatId()
        setDrawer(open: false)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

#Preview {
    ContentView()
}
