import SwiftUI

struct DebugStatusBar: View {
    @Environment(FeedLoader.self) private var loader

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 0) {
                Text("\(loader.items.count) visible")
                Text(" · ")
                Text("\(loader.reservoirCount) reservoir")
                Text(" · ")
                Text("\(loader.sourceCount) sources")
                Text(" · ")
                Text("\(loader.opmlFileCount) files")
                if loader.duplicateSourceCount > 0 {
                    Text(" · ")
                    Text("\(loader.duplicateSourceCount) duplicates")
                }
                Text(" · ")
                Text("\(loader.totalFetched) fetched")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            HStack(spacing: 0) {
                Text("\(loader.totalDiscarded) discarded")
                Text(" · ")
                Text("\(loader.fetchErrorCount) fetch errors")
                Text(" · ")
                Text("\(loader.opmlErrorCount) OPML errors")
                Text(" · ")
                statusIndicator
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .background(Color(.systemGray6))
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch loader.loadingState {
        case .idle:
            Text("✓ idle")
        case .initial:
            Text("⏳ initial")
        case .refreshing:
            Text("⟳ refreshing")
        case .loadingMore:
            Text("⏳ loading more")
        }
    }
}
