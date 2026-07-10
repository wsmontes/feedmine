import SwiftUI

@main
struct FeedmineApp: App {
    @State private var manager = FeedManager()
    @State private var localeManager = LocaleManager.shared

    var body: some Scene {
        WindowGroup {
            RootPagerView()
                .environment(manager)
                .environment(localeManager)
        }
    }
}
