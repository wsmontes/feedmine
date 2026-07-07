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
            return String(localized: "Loading your feed...", comment: "Empty state title")
        } else if loader.fetchErrorCount > 0 && loader.totalFetched == 0 {
            return String(localized: "Couldn't load feeds", comment: "Empty state title")
        } else if loader.sources.isEmpty {
            return String(localized: "No sources found", comment: "Empty state title")
        } else {
            return String(localized: "No articles yet", comment: "Empty state title")
        }
    }

    private var description: String {
        if loader.loadingState == .initial {
            return String(localized: "Fetching articles from \(loader.sourceCount) sources.", comment: "Empty state description")
        } else if loader.fetchErrorCount > 0 && loader.totalFetched == 0 {
            return String(localized: "All \(loader.fetchErrorCount) sources failed to load. Check your internet connection and pull to refresh.", comment: "Empty state description")
        } else if loader.sources.isEmpty {
            return String(localized: "Add .opml files to the Resources/Feeds folder in Xcode and rebuild the app.", comment: "Empty state description")
        } else {
            return circadianNoArticlesMessage
        }
    }

    private var circadianNoArticlesMessage: String {
        switch engine.period {
        case .dawn:    return String(localized: "The world's still quiet. Stories are on their way.", comment: "Empty state — dawn")
        case .morning: return String(localized: "Nothing here yet. Good time to add a source?", comment: "Empty state — morning")
        case .afternoon: return String(localized: "All caught up. Quick and clean.", comment: "Empty state — afternoon")
        case .evening: return String(localized: "All caught up. These are worth the slow read — come back soon.", comment: "Empty state — evening")
        case .night:   return String(localized: "All caught up. Sleep well. The news will be here tomorrow.", comment: "Empty state — night")
        }
    }

    private var showActions: Bool {
        loader.loadingState != .initial
    }
}
