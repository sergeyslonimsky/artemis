import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "sparkles")
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)
                
                Text("Artemis")
                    .font(.largeTitle.bold())
                
                Text("Fast, elegant AI chat client")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .navigationTitle("Artemis")
        }
    }
}

#Preview {
    ContentView()
}
