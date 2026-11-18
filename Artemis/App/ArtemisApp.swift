import SwiftUI

@main
struct ArtemisApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

extension EnvironmentValues {
    /// The app's database; previews and tests can inject an in-memory one.
    @Entry var database: AppDatabase = .shared
}
