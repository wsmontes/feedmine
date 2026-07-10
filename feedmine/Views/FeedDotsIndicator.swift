import SwiftUI

/// Floating page indicator at the bottom (above the mini-player). One colored dot
/// per feed in that feed's accent; the active dot is larger/filled. When more feeds
/// can be created, a trailing "+" dot (in the next free color) marks the creation page.
struct FeedDotsIndicator: View {
    @Environment(FeedManager.self) private var manager

    private var creationIndex: Int? { manager.canCreateMore ? manager.feeds.count : nil }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(manager.feeds.enumerated()), id: \.element.id) { index, instance in
                Circle()
                    .fill(manager.theme(for: instance.descriptor).accent)
                    .frame(width: index == manager.activeIndex ? 10 : 7,
                           height: index == manager.activeIndex ? 10 : 7)
                    .opacity(index == manager.activeIndex ? 1 : 0.45)
                    .onTapGesture { withAnimation { manager.setActive(index) } }
            }
            if let creationIndex {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle((manager.nextFreeFamily?.accent(for: CircadianEngine.shared.period) ?? .gray))
                    .opacity(manager.activeIndex == creationIndex ? 1 : 0.5)
                    .onTapGesture { withAnimation { manager.setActive(creationIndex) } }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.bottom, 96)   // clear the mini-player bar
    }
}
