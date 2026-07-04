import SwiftUI

struct MomentCard: View {
    @Environment(FeedLoader.self) private var loader
    @State private var greeting: String = ""
    @State private var engine = CircadianEngine.shared

    var body: some View {
        if !loader.items.isEmpty {
            Text(greeting)
                .font(engine.font(for: .momentCard))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .onAppear { updateGreeting() }
                .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in
                    AppContext.shared.refresh()
                    engine.refresh()
                    updateGreeting()
                }
        }
    }

    private func updateGreeting() {
        greeting = MomentGreeting.generate(loader: loader)
    }
}
