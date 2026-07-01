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

    var body: some View {
        VStack(spacing: 0) {
            DebugStatusBar()
            SearchBarView()
            CategoryFilterBar()
            LayoutToggleView()

            if loader.loadingState == .initial && loader.items.isEmpty {
                SkeletonLoadingView()
            } else if loader.filteredItems.isEmpty && !loader.items.isEmpty {
                EmptyFilterView(category: loader.selectedCategory ?? "selected")
            } else {
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
                            .onAppear {
                                appearedItemIDs.insert(item.id)
                                Task {
                                    await loader.loadMoreIfNeeded(currentItem: item)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 8)
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

    var body: some View {
        HStack {
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
                .background(
                    loader.layout == .card ?
                    Color.blue : Color.clear
                )
                .clipShape(RoundedRectangle(cornerRadius: 6))

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
                .background(
                    loader.layout == .list ?
                    Color.blue : Color.clear
                )
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 8))
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

// MARK: - SFSafariViewController wrapper

private struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}
