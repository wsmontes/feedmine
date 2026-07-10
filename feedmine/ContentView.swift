import SwiftUI

struct ContentView: View {
    @State private var manager = FeedManager()

    var body: some View {
        RootPagerView()
            .environment(manager)
            .environment(LocaleManager.shared)
    }
}
