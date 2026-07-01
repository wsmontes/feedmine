import SwiftUI

struct ContentView: View {
    @State private var loader = FeedLoader()

    var body: some View {
        FeedScreen()
            .environment(loader)
    }
}
