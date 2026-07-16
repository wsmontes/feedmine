import SwiftUI

enum FeedEmptyMode {
    case noSourcesEnabled
    case fetching(topic: String, fetched: Int, total: Int)
    case noResults(topic: String)
    case generic
}

struct FeedEmptyStateView: View {
    @Environment(FeedLoader.self) private var loader
    @State private var engine = CircadianEngine.shared

    var mode: FeedEmptyMode = .generic

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // Progress spinner during refresh — shows work is happening
            if loader.loadingState == .refreshing {
                ProgressView()
                    .tint(engine.accent)
                    .scaleEffect(1.2)
            }

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

            // Fetching progress
            if case .fetching(let topic, let fetched, let total) = mode {
                HStack(spacing: 4) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Fetched \(fetched) of \(total) sources...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)
            }

            // Action buttons
            if showActions {
                VStack(spacing: 12) {
                    if showOpenFilters {
                        Button {
                            let impact = UIImpactFeedbackGenerator(style: .light)
                            impact.impactOccurred()
                            showFilters = true
                        } label: {
                            HStack {
                                Image(systemName: "line.3.horizontal.decrease")
                                Text("Open Filters")
                            }
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .frame(maxWidth: 200)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(engine.accent)
                        .controlSize(.large)
                    } else {
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
            }

            Spacer()
        }
        .padding(.top, 40)
        .sheet(isPresented: $showFilters) {
            FilterSheetView()
        }
    }

    @State private var showFilters = false

    private var showOpenFilters: Bool {
        if case .noSourcesEnabled = mode { return true }
        return false
    }

    private var iconName: String {
        switch mode {
        case .noSourcesEnabled: return "globe.americas.fill"
        case .fetching: return "magnifyingglass"
        case .noResults: return "tray"
        case .generic:
            if loader.loadingState == .initial {
                return "antenna.radiowaves.left.and.right"
            } else if loader.loadingState == .refreshing {
                return "line.3.horizontal.decrease.circle"
            } else if loader.fetchErrorCount > 0 && loader.totalFetched == 0 {
                return "wifi.slash"
            } else if loader.sources.isEmpty {
                return "folder.badge.questionmark"
            } else {
                return "newspaper.fill"
            }
        }
    }

    private var title: String {
        switch mode {
        case .noSourcesEnabled: return String(localized: "No sources enabled", comment: "Empty state title")
        case .fetching(let topic, _, _): return String(localized: "Searching for \(topic)...", comment: "Empty state title — fetching")
        case .noResults(let topic): return String(localized: "No articles found for \(topic)", comment: "Empty state title — no results")
        case .generic:
            if loader.loadingState == .initial {
                return String(localized: "Loading your feed...", comment: "Empty state title")
            } else if loader.loadingState == .refreshing {
                return String(localized: "Filtering articles...", comment: "Empty state title — filter in progress")
            } else if loader.fetchErrorCount > 0 && loader.totalFetched == 0 {
                return String(localized: "Couldn't load feeds", comment: "Empty state title")
            } else if loader.sources.isEmpty {
                return String(localized: "No sources found", comment: "Empty state title")
            } else {
                return String(localized: "No articles yet", comment: "Empty state title")
            }
        }
    }

    private var description: String {
        switch mode {
        case .noSourcesEnabled:
            return String(localized: "Enable some countries or topics in Filters to start seeing content.", comment: "Empty state description")
        case .fetching(let topic, _, let total):
            return String(localized: "We're fetching the latest articles from \(total) sources in \(topic). They'll appear here as they arrive.", comment: "Empty state description — fetching")
        case .noResults:
            return String(localized: "These sources may not have published recently. Try a different topic or check back later.", comment: "Empty state description — no results")
        case .generic:
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
        loader.loadingState != .initial && loader.loadingState != .refreshing
    }
}
