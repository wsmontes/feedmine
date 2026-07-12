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

                Text(LocalizedStringKey(greeting))
                    .font(engine.font(for: .momentCard))
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 10)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .onAppear { updateGreeting() }
            .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in
                // Refresh time context + greeting text ONLY. Do NOT call
                // engine.refresh() here: it recomputes circadian fonts/cardGap,
                // which reflows every feed card and shifts content the user is
                // reading. Reserved 2-line height keeps this card's own size
                // stable across greeting changes. (Feed is sacred.)
                AppContext.shared.refresh()
                updateGreeting()
            }
        }
    }

    private func updateGreeting() {
        greeting = MomentGreeting.generate(loader: loader)
    }
}
