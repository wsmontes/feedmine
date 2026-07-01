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

    var body: some View {
        VStack(spacing: 0) {
            if showDebugBar {
                DebugStatusBar()
            }
            ErrorBannerView()
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
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.blue.opacity(0.1))
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
                                    Group {
                                        if loader.layout == .card {
                                            FeedItemCardView(
                                                item: item,
                                                isRead: loader.isRead(item.id),
                                                isBookmarked: loader.isBookmarked(item.id),
                                                onBookmark: { loader.toggleBookmark(item.id) }
                                            )
                                            .padding(.horizontal, 12)
                                        } else {
                                            FeedItemRowView(
                                                item: item,
                                                isRead: loader.isRead(item.id),
                                                isBookmarked: loader.isBookmarked(item.id)
                                            )
                                            Divider()
                                        }
                                    }
                                    .id(item.id)
                                    .scrollTransition(.animated(.spring(duration: 0.4))) { content, phase in
                                        content
                                            .opacity(phase == .identity ? 1 : 0.5)
                                            .scaleEffect(phase == .identity ? 1 : 0.95)
                                    }
                                    .onTapGesture {
                                        let impact = UIImpactFeedbackGenerator(style: .light)
                                        impact.impactOccurred()
                                        loader.markAsRead(item.id)
                                        if let url = URL(string: item.url) {
                                            selectedArticle = ArticleRoute(url: url)
                                        }
                                    }
                                    .contextMenu {
                                        Button {
                                            loader.toggleBookmark(item.id)
                                        } label: {
                                            Label(
                                                loader.isBookmarked(item.id) ? "Remove Bookmark" : "Bookmark",
                                                systemImage: loader.isBookmarked(item.id) ? "bookmark.slash" : "bookmark"
                                            )
                                        }
                                        Button {
                                            UIPasteboard.general.url = URL(string: item.url)
                                        } label: {
                                            Label("Copy Link", systemImage: "doc.on.doc")
                                        }
                                        ShareLink(item: URL(string: item.url) ?? URL(string: "https://feedmine.app")!) {
                                            Label("Share", systemImage: "square.and.arrow.up")
                                        }
                                    }
                                    .swipeActions(edge: .leading) {
                                        Button {
                                            let impact = UIImpactFeedbackGenerator(style: .medium)
                                            impact.impactOccurred()
                                            loader.markAsRead(item.id)
                                        } label: {
                                            Label(
                                                loader.isRead(item.id) ? "Unread" : "Read",
                                                systemImage: loader.isRead(item.id) ? "eye.slash" : "eye"
                                            )
                                        }
                                        .tint(loader.isRead(item.id) ? .gray : .green)
                                    }
                                    .swipeActions(edge: .trailing) {
                                        Button {
                                            let impact = UIImpactFeedbackGenerator(style: .medium)
                                            impact.impactOccurred()
                                            loader.toggleBookmark(item.id)
                                        } label: {
                                            Label(
                                                loader.isBookmarked(item.id) ? "Remove" : "Save",
                                                systemImage: loader.isBookmarked(item.id) ? "bookmark.slash.fill" : "bookmark.fill"
                                            )
                                        }
                                        .tint(.yellow)
                                    }
                                    .accessibilityElement(children: .combine)
                                    .accessibilityLabel("\(item.title) from \(item.sourceTitle)")
                                    .accessibilityAddTraits(loader.isRead(item.id) ? [] : .isHeader)
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
    }
}

// MARK: - Skeleton Loading View

struct SkeletonLoadingView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(0..<6, id: \.self) { _ in
                    SkeletonCardView()
                        .padding(.horizontal, 12)
                }
            }
            .padding(.vertical, 8)
        }
        .disabled(true)
        .accessibilityLabel("Loading articles")
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
