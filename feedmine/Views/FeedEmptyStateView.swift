import SwiftUI

struct FeedEmptyStateView: View {
    @Environment(FeedLoader.self) private var loader
    @State private var engine = CircadianEngine.shared

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // Icon
            ZStack {
                Circle()
                    .fill(engine.accent.opacity(0.1))
                    .frame(width: 100, height: 100)

                Image(systemName: iconName)
                    .font(.system(size: 40))
                    .foregroundStyle(engine.accent)
            }

            // Title
            Text(title)
                .font(.title3)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)

            // Description
            Text(description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            // Action buttons
            if showActions {
                VStack(spacing: 12) {
                    Button {
                        let impact = UIImpactFeedbackGenerator(style: .light)
                        impact.impactOccurred()
                        Task { await loader.refresh() }
                    } label: {
                        HStack {
                            Image(systemName: "arrow.clockwise")
                            Text("Refresh Now")
                        }
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .frame(maxWidth: 200)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(engine.accent)
                    .controlSize(.large)

                    if loader.disabledSourceIDs.count > 0 {
                        Text("Tip: \(loader.disabledSourceIDs.count) source\(loader.disabledSourceIDs.count == 1 ? " is" : "s are") disabled")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()
        }
        .padding(.top, 40)
    }

    private var iconName: String {
        if loader.loadingState == .initial {
            return "antenna.radiowaves.left.and.right"
        } else if loader.fetchErrorCount > 0 && loader.totalFetched == 0 {
            return "wifi.slash"
        } else if loader.sources.isEmpty {
            return "folder.badge.questionmark"
        } else {
            return "newspaper.fill"
        }
    }

    private var title: String {
        if loader.loadingState == .initial {
            return "Loading your feed..."
        } else if loader.fetchErrorCount > 0 && loader.totalFetched == 0 {
            return "Couldn't load feeds"
        } else if loader.sources.isEmpty {
            return "No sources found"
        } else {
            return "No articles yet"
        }
    }

    private var description: String {
        if loader.loadingState == .initial {
            return "Fetching articles from \(loader.sourceCount) sources."
        } else if loader.fetchErrorCount > 0 && loader.totalFetched == 0 {
            return "All \(loader.fetchErrorCount) sources failed to load. Check your internet connection and pull to refresh."
        } else if loader.sources.isEmpty {
            return "Add .opml files to the Resources/Feeds folder in Xcode and rebuild the app."
        } else {
            return circadianNoArticlesMessage
        }
    }

    private var circadianNoArticlesMessage: String {
        switch engine.period {
        case .dawn:    return "The world's still quiet. Stories are on their way."
        case .morning: return "Nothing here yet. Good time to add a source?"
        case .afternoon: return "All caught up. Quick and clean."
        case .evening: return "All caught up. These are worth the slow read — come back soon."
        case .night:   return "All caught up. Sleep well. The news will be here tomorrow."
        }
    }

    private var showActions: Bool {
        loader.loadingState != .initial
    }
}
