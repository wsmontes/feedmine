import SwiftUI

struct MomentCard: View {
    @Environment(FeedLoader.self) private var loader
    @State private var greeting: String = ""

    private var ctx: AppContext { AppContext.shared }

    var body: some View {
        if loader.loadingState != .initial && !loader.items.isEmpty {
            Text(greeting)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .onAppear { refreshGreeting() }
                .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in
                    refreshGreeting()
                }
        }
    }

    private func refreshGreeting() {
        AppContext.shared.refresh()
        greeting = MomentGreeting.generate()
    }
}
