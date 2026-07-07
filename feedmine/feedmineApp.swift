import SwiftUI

@main
struct FeedmineApp: App {
    @State private var loader = FeedLoader()
    @State private var localeManager = LocaleManager.shared

    var body: some Scene {
        WindowGroup {
            FeedScreen()
                .environment(loader)
                .environment(localeManager)
        }
    }
}
