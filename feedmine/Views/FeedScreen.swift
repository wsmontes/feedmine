import SwiftUI
import SafariServices
import UIKit

struct ArticleRoute: Identifiable {
    let id = UUID()
    let url: URL
}

struct FeedScreen: View {
    @Environment(FeedLoader.self) private var loader
    @State private var selectedArticle: ArticleRoute?
    @State private var appearedItemIDs: Set<String> = []
    @State private var showScrollButton = false
    @State private var showSettings = false
    @State private var showSources = false
    @AppStorage("showDebugBar") private var showDebugBar = true
    @AppStorage("accentColorName") private var accentColorName = "blue"

    private var accentColor: Color {
        switch accentColorName {
        case "indigo": return .indigo
        case "purple": return .purple
        case "pink": return .pink
        case "orange": return .orange
        case "green": return .green
        case "teal": return .teal
        default: return .blue
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if showDebugBar {
                DebugStatusBar()
            }
            ErrorBannerView()
            GreetingHeaderView()
            ReadingStatsView()
            SearchBarView()
            CategoryFilterBar()
            HStack {
                Button {
                    showSources = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.caption)
                        Text("Sources")
                            .font(.caption)
                    }
                    .foregroundStyle(accentColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(accentColor.opacity(0.1))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Spacer()

                LayoutToggleView(showSettings: $showSettings)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            if loader.loadingState == .initial && loader.items.isEmpty {
                SkeletonLoadingView()
            } else if loader.filteredItems.isEmpty && !loader.items.isEmpty {
                EmptyFilterView(category: loader.selectedCategory ?? "selected")
            } else {
                ZStack(alignment: .bottomTrailing) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: loader.layout == .card ? 12 : 1) {
                                ForEach(Array(loader.filteredItems.enumerated()), id: \.element.id) { index, item in
                                    FeedItemView(item: item, index: index) {
                                        if let url = URL(string: item.url) {
                                            selectedArticle = ArticleRoute(url: url)
                                        }
                                    }
                                    .onAppear {
                                        appearedItemIDs.insert(item.id)
                                        showScrollButton = index > 20
                                        Task {
                                            await loader.loadMoreIfNeeded(currentItem: item)
                                        }
                                    }
                                }
                            }
                            .padding(.vertical, 8)
                        }
                        .overlay(alignment: .top) {
                            // Anchor for scroll-to-top
                            Color.clear.frame(height: 0).id("top")
                        }

                        // Floating scroll-to-top button
                        if showScrollButton {
                            Button {
                                let impact = UIImpactFeedbackGenerator(style: .soft)
                                impact.impactOccurred()
                                withAnimation(.easeInOut(duration: 0.5)) {
                                    proxy.scrollTo("top", anchor: .top)
                                }
                                showScrollButton = false
                            } label: {
                                Image(systemName: "arrow.up")
                                    .font(.title3)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.white)
                                    .frame(width: 44, height: 44)
                                    .background(
                                        Circle()
                                            .fill(.blue.opacity(0.9))
                                            .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                                    )
                            }
                            .accessibilityLabel("Scroll to top")
                            .padding(.trailing, 16)
                            .padding(.bottom, 16)
                            .transition(.scale.combined(with: .opacity))
                        }
                    }
                }
            }
        }
        .task {
            await loader.start()
            updateBadge()
        }
        .onChange(of: loader.readItemIDs.count) { _, _ in
            updateBadge()
        }
        .refreshable {
            let impact = UIImpactFeedbackGenerator(style: .medium)
            impact.impactOccurred()
            await loader.refresh()
        }
        .sheet(item: $selectedArticle) { route in
            SafariView(url: route.url)
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheetView()
        }
        .sheet(isPresented: $showSources) {
            SourceManagementView()
        }
        .tint(accentColor)
        .overlay {
            OnboardingTipsView()
        }
    }

    private func updateBadge() {
        let unread = loader.items.count - loader.readItemIDs.count
        Task { @MainActor in
            UIApplication.shared.applicationIconBadgeNumber = max(0, unread)
        }
    }
}

// MARK: - Skeleton Loading View

struct SkeletonLoadingView: View {
    @State private var messageIndex = 0

    private let messages = [
        "Brewing coffee...",
        "Scanning the internet...",
        "Reading RSS feeds...",
        "Finding the best stories...",
        "Loading your feed...",
        "Checking sources...",
        "Almost there...",
        "Curating articles...",
        "Tuning antennas...",
        "Gathering news..."
    ]

    var body: some View {
        VStack(spacing: 0) {
            Text(messages[messageIndex])
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.vertical, 16)
                .transition(.opacity.combined(with: .move(edge: .top)))
                .id(messageIndex)

            ScrollView {
                VStack(spacing: 12) {
                    ForEach(0..<6, id: \.self) { _ in
                        SkeletonCardView()
                            .padding(.horizontal, 12)
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .disabled(true)
        .accessibilityLabel("Loading articles")
        .onAppear {
            Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { timer in
                withAnimation(.easeInOut(duration: 0.4)) {
                    messageIndex = (messageIndex + 1) % messages.count
                }
            }
        }
    }
}

struct SkeletonCardView: View {
    @State private var isAnimating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RoundedRectangle(cornerRadius: 12)
                .fill(shimmerGradient)
                .frame(height: 180)

            RoundedRectangle(cornerRadius: 4)
                .fill(shimmerGradient)
                .frame(width: 120, height: 16)
                .padding(.horizontal, 16)
                .padding(.top, 12)

            RoundedRectangle(cornerRadius: 4)
                .fill(shimmerGradient)
                .frame(height: 20)
                .padding(.horizontal, 16)
                .padding(.top, 8)

            RoundedRectangle(cornerRadius: 4)
                .fill(shimmerGradient)
                .frame(width: 200, height: 20)
                .padding(.horizontal, 16)
                .padding(.top, 4)

            RoundedRectangle(cornerRadius: 4)
                .fill(shimmerGradient)
                .frame(height: 40)
                .padding(.horizontal, 16)
                .padding(.top, 4)

            RoundedRectangle(cornerRadius: 4)
                .fill(shimmerGradient)
                .frame(width: 80, height: 12)
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 16)
        }
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                isAnimating = true
            }
        }
        .accessibilityHidden(true)
    }

    private var shimmerGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(.systemGray5),
                Color(.systemGray4),
                Color(.systemGray5)
            ],
            startPoint: isAnimating ? .topTrailing : .topLeading,
            endPoint: isAnimating ? .bottomLeading : .bottomTrailing
        )
    }
}

// MARK: - Layout Toggle

struct LayoutToggleView: View {
    @Environment(FeedLoader.self) private var loader

    @Binding var showSettings: Bool

    var body: some View {
        HStack {
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")

            Spacer()
            HStack(spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        loader.layout = .card
                    }
                } label: {
                    Image(systemName: "rectangle.grid.1x2.fill")
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .foregroundStyle(loader.layout == .card ? .white : .secondary)
                .background(loader.layout == .card ? Color.blue : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel("Card layout")

                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        loader.layout = .list
                    }
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .foregroundStyle(loader.layout == .list ? .white : .secondary)
                .background(loader.layout == .list ? Color.blue : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel("List layout")
            }
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel("Layout switcher")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}

// MARK: - Empty Filter State

struct EmptyFilterView: View {
    let category: String

    var body: some View {
        ContentUnavailableView(
            "No \(category) articles",
            systemImage: "rectangle.stack.fill",
            description: Text("This category has articles in the feed, but they may have been trimmed from the visible buffer. Try scrolling through All first.")
        )
        .padding(.top, 80)
    }
}

// MARK: - SFSafariViewController wrapper with Reader mode

private struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let config = SFSafariViewController.Configuration()
        config.entersReaderIfAvailable = true
        return SFSafariViewController(url: url, configuration: config)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}
