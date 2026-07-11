import SwiftUI

struct MomentCard: View {
    @Environment(FeedLoader.self) private var loader
    @State private var greeting: String = ""
    @State private var engine = CircadianEngine.shared
    @State private var timer: Timer?

    var body: some View {
        if !loader.items.isEmpty {
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(engine.accent.opacity(0.6))
                    .frame(width: 3)
                    .padding(.vertical, 2)

                Text(LocalizedStringKey(greeting))
                    .font(engine.font(for: .momentCard))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 10)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .onAppear {
                updateGreeting()
                // Manual timer so we can stop it on disappear — the declarative
                // Timer.publish autoconnect runs even when scrolled off-screen.
                timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
                    AppContext.shared.refresh()
                    engine.refresh()
                    updateGreeting()
                }
            }
            .onDisappear {
                timer?.invalidate()
                timer = nil
            }
        }
    }

    private func updateGreeting() {
        greeting = MomentGreeting.generate(loader: loader)
    }
}
