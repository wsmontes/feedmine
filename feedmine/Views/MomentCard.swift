import SwiftUI

struct MomentCard: View {
    @Environment(FeedLoader.self) private var loader
    @State private var greeting: String = ""
    @State private var engine = CircadianEngine.shared

    var body: some View {
        if !loader.items.isEmpty {
            HStack(spacing: 0) {
                // Left border anchor — subtle circadian accent
                RoundedRectangle(cornerRadius: 2)
                    .fill(engine.accent.opacity(0.6))
                    .frame(width: 3)
                    .padding(.vertical, 2)

                Text(greeting)
                    .font(engine.font(for: .momentCard))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 10)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
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
